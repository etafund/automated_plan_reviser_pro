#!/usr/bin/env bash
# lib/cache.sh - APR file-metadata cache (bd-1aw)
#
# Memoizes expensive per-file lookups (sha256, byte size) so commands
# that read the same file multiple times in one process (`apr lint`
# followed by `apr render` followed by `apr run`) don't repeat the hash
# computation, and so a queue runner invoking many rounds doesn't
# rehash the README/spec/impl on every iteration.
#
# Two layers:
#
#   1) In-process cache (always on). Uses an associative array keyed by
#      <absolute_path>|<mtime>|<size>. The (mtime,size) suffix is the
#      invalidation token — if the file is rewritten, the key changes
#      and we naturally recompute.
#
#   2) Optional on-disk cache under `<project_root>/.apr/cache/`.
#      Enabled by passing `1` for `<persist>` to the wrappers, or by
#      setting `APR_CACHE_PERSIST=1` in the environment.
#
# Both layers honor `APR_NO_CACHE=1` (set it and every lookup
# recomputes; nothing is written).
#
# Determinism guarantee
# ---------------------
# Cached and uncached paths produce byte-identical output. The cache
# never lies; on key mismatch it recomputes via the canonical helpers
# in lib/manifest.sh.
#
# Public API
# ----------
#   apr_lib_cache_init [<project_root>]
#       Reset the in-process cache and (re)point the on-disk cache.
#       Safe to call multiple times.
#
#   apr_lib_cache_clear
#       Drop all in-process entries. On-disk files are untouched.
#
#   apr_lib_cache_sha256_file <path> [<persist>=0]
#       Echo the lowercase hex sha256 of <path>. Cache miss recomputes
#       via apr_lib_manifest_sha256.
#
#   apr_lib_cache_size_file <path> [<persist>=0]
#       Echo the byte size of <path>. Cache miss recomputes via
#       apr_lib_manifest_size.
#
#   apr_lib_cache_stats
#       Echo a one-line JSON summary of the in-process cache counters:
#       {"hits":N,"misses":N,"recompute_invalidated":N}

# Guard against double-sourcing.
if [[ "${_APR_LIB_CACHE_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_CACHE_LOADED=1

_APR_LIB_CACHE_DIR_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_CACHE_DIR_SELF/manifest.sh"

# In-process maps (associative arrays).
# Keys: "<abs-path>|<mtime>|<size>"
declare -A _APR_CACHE_SHA=()
declare -A _APR_CACHE_SIZE=()
# Counters.
_APR_CACHE_HITS=0
_APR_CACHE_MISSES=0
_APR_CACHE_RECOMPUTE_INVALIDATED=0

# On-disk cache root (relative to project root). Set in init.
_APR_CACHE_DISK_DIR=""

# -----------------------------------------------------------------------------
# apr_lib_cache_init [<project_root>]
# -----------------------------------------------------------------------------
apr_lib_cache_init() {
    local project_root="${1:-.}"
    apr_lib_cache_clear
    _APR_CACHE_DISK_DIR="$project_root/.apr/cache"
}

# -----------------------------------------------------------------------------
# apr_lib_cache_clear
# -----------------------------------------------------------------------------
apr_lib_cache_clear() {
    # Use `unset` + `declare -gA` instead of `_APR_CACHE_SHA=()` because
    # the unqualified form re-creates the variable as an INDEXED array
    # when invoked inside a function, even if the global was declared
    # associative. `declare -gA` re-asserts the type at function scope.
    unset _APR_CACHE_SHA _APR_CACHE_SIZE
    declare -gA _APR_CACHE_SHA=()
    declare -gA _APR_CACHE_SIZE=()
    _APR_CACHE_HITS=0
    _APR_CACHE_MISSES=0
    _APR_CACHE_RECOMPUTE_INVALIDATED=0
}

# -----------------------------------------------------------------------------
# Internal: compute the invalidation key for <path>.
# Echo "<abs-path>|<mtime-epoch>|<size>"
# Echo empty string on stat failure.
# -----------------------------------------------------------------------------
_apr_cache_key() {
    local path="$1"
    local abs mtime size
    abs=$(cd -- "$(dirname -- "$path")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename -- "$path")")
    if [[ -z "$abs" || ! -e "$abs" ]]; then
        printf ''
        return 1
    fi
    # Linux GNU stat first; macOS BSD stat second.
    mtime=$(stat -c '%Y' -- "$abs" 2>/dev/null || stat -f '%m' -- "$abs" 2>/dev/null || printf '0')
    size=$(stat -c '%s'  -- "$abs" 2>/dev/null || stat -f '%z' -- "$abs" 2>/dev/null || printf '0')
    printf '%s|%s|%s' "$abs" "$mtime" "$size"
}

# -----------------------------------------------------------------------------
# Internal: on-disk cache helpers.
# -----------------------------------------------------------------------------
_apr_cache_disk_path() {
    # Hash the key to keep filenames sane.
    local kind="$1" key="$2"
    local h
    h=$(printf '%s' "$key" | (sha256sum 2>/dev/null || shasum -a 256 2>/dev/null) | awk '{print $1}')
    printf '%s/%s/%s' "$_APR_CACHE_DISK_DIR" "$kind" "$h"
}

_apr_cache_disk_read() {
    local kind="$1" key="$2" out=""
    [[ -z "$_APR_CACHE_DISK_DIR" ]] && return 1
    local f
    f=$(_apr_cache_disk_path "$kind" "$key")
    [[ -r "$f" ]] || return 1
    out=$(cat -- "$f" 2>/dev/null) || return 1
    printf '%s' "$out"
    return 0
}

_apr_cache_disk_write() {
    local kind="$1" key="$2" value="$3"
    [[ -z "$_APR_CACHE_DISK_DIR" ]] && return 0
    local f dir
    f=$(_apr_cache_disk_path "$kind" "$key")
    dir=$(dirname -- "$f")
    mkdir -p -- "$dir" 2>/dev/null || return 1
    printf '%s' "$value" > "$f.tmp.$$" 2>/dev/null || return 1
    mv -f -- "$f.tmp.$$" "$f" 2>/dev/null || { rm -f -- "$f.tmp.$$" 2>/dev/null; return 1; }
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_cache_sha256_file <path> [<persist>]
# -----------------------------------------------------------------------------
apr_lib_cache_sha256_file() {
    local path="${1:?path required}"
    local persist="${2:-${APR_CACHE_PERSIST:-0}}"

    if [[ "${APR_NO_CACHE:-0}" == "1" ]]; then
        apr_lib_manifest_sha256 "$path"
        return $?
    fi

    local key
    key=$(_apr_cache_key "$path")
    if [[ -z "$key" ]]; then
        # File missing: defer to canonical helper (it will emit empty-sha).
        apr_lib_manifest_sha256 "$path"
        return $?
    fi

    # In-process hit?
    if [[ -n "${_APR_CACHE_SHA[$key]+set}" ]]; then
        _APR_CACHE_HITS=$(( _APR_CACHE_HITS + 1 ))
        printf '%s' "${_APR_CACHE_SHA[$key]}"
        return 0
    fi

    # On-disk hit?
    if [[ "$persist" == "1" ]]; then
        local cached
        if cached=$(_apr_cache_disk_read sha "$key"); then
            if [[ "$cached" =~ ^[0-9a-f]{64}$ ]]; then
                _APR_CACHE_SHA[$key]="$cached"
                _APR_CACHE_HITS=$(( _APR_CACHE_HITS + 1 ))
                printf '%s' "$cached"
                return 0
            fi
        fi
    fi

    _APR_CACHE_MISSES=$(( _APR_CACHE_MISSES + 1 ))
    local sha
    sha=$(apr_lib_manifest_sha256 "$path")
    local rc=$?
    if [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        _APR_CACHE_SHA[$key]="$sha"
        if [[ "$persist" == "1" ]]; then
            _apr_cache_disk_write sha "$key" "$sha" || true
        fi
    fi
    printf '%s' "$sha"
    return $rc
}

# -----------------------------------------------------------------------------
# apr_lib_cache_size_file <path> [<persist>]
# -----------------------------------------------------------------------------
apr_lib_cache_size_file() {
    local path="${1:?path required}"
    local persist="${2:-${APR_CACHE_PERSIST:-0}}"

    if [[ "${APR_NO_CACHE:-0}" == "1" ]]; then
        apr_lib_manifest_size "$path"
        return $?
    fi

    local key
    key=$(_apr_cache_key "$path")
    if [[ -z "$key" ]]; then
        apr_lib_manifest_size "$path"
        return $?
    fi

    if [[ -n "${_APR_CACHE_SIZE[$key]+set}" ]]; then
        _APR_CACHE_HITS=$(( _APR_CACHE_HITS + 1 ))
        printf '%s' "${_APR_CACHE_SIZE[$key]}"
        return 0
    fi

    if [[ "$persist" == "1" ]]; then
        local cached
        if cached=$(_apr_cache_disk_read size "$key"); then
            if [[ "$cached" =~ ^[0-9]+$ ]]; then
                _APR_CACHE_SIZE[$key]="$cached"
                _APR_CACHE_HITS=$(( _APR_CACHE_HITS + 1 ))
                printf '%s' "$cached"
                return 0
            fi
        fi
    fi

    _APR_CACHE_MISSES=$(( _APR_CACHE_MISSES + 1 ))
    local size
    size=$(apr_lib_manifest_size "$path")
    local rc=$?
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        _APR_CACHE_SIZE[$key]="$size"
        if [[ "$persist" == "1" ]]; then
            _apr_cache_disk_write size "$key" "$size" || true
        fi
    fi
    printf '%s' "$size"
    return $rc
}

# -----------------------------------------------------------------------------
# apr_lib_cache_stats
# -----------------------------------------------------------------------------
apr_lib_cache_stats() {
    printf '{"hits":%s,"misses":%s,"recompute_invalidated":%s}' \
        "$_APR_CACHE_HITS" "$_APR_CACHE_MISSES" "$_APR_CACHE_RECOMPUTE_INVALIDATED"
}
