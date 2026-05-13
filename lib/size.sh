#!/usr/bin/env bash
# lib/size.sh - APR prompt-size estimation primitives (bd-rvq)
#
# Computes the byte size of the final assembled prompt before Oracle
# is invoked, so operators can detect oversize bundles early and apply
# a deterministic policy (warn / strict / auto-trim).
#
# This module is estimation + budget-check only. The apr-side policy
# enforcement and the trimming strategy are tracked separately (see
# bd-rvq follow-on). Keeping size logic in lib/ means apr lint, apr
# render, apr run, and apr robot validate/run all agree byte-for-byte
# on what "the bundle's size" means.
#
# Public API
# ----------
#   apr_lib_size_total <text>
#       Echo the byte count of <text>. Deterministic; uses wc -c which
#       counts bytes (not codepoints) on every POSIX system.
#
#   apr_lib_size_breakdown <manifest_text> <template_text> <file_path>...
#       Echo a compact JSON object with:
#           total_bytes
#           manifest_bytes
#           template_bytes
#           files: [{path, basename, bytes}, ...]
#       (files[] sums into a `files_total_bytes` field for convenience.)
#       Used by render/dry-run paths to surface "where the bytes went."
#
#   apr_lib_size_check_budget <bytes> <budget>
#       Return 0 if bytes <= budget, 1 if over. budget=0 disables.
#       Echoes nothing.
#
#   apr_lib_size_policy_resolve <bytes> [<budget>] [<warn_threshold>]
#       Echo one of: "ok" / "warn" / "over_budget".
#       - bytes > budget AND budget > 0 -> "over_budget"
#       - bytes > warn_threshold (>0)   -> "warn"
#       - otherwise                     -> "ok"
#
# Defaults are pulled from env vars when args are empty:
#   APR_MAX_PROMPT_BYTES         (default 200000 -- conservative for inline
#                                 paste; matches AGENTS.md guidance)
#   APR_PROMPT_WARN_BYTES        (default 150000)
#
# These defaults reflect AGENTS.md note: "Inline pasting works
# consistently for documents up to ~200KB."

# Guard against double-sourcing.
if [[ "${_APR_LIB_SIZE_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_SIZE_LOADED=1

_APR_LIB_SIZE_DIR_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_SIZE_DIR_SELF/manifest.sh"

# Defaults (operator-overrideable).
_APR_SIZE_DEFAULT_MAX_BYTES=200000
_APR_SIZE_DEFAULT_WARN_BYTES=150000

# -----------------------------------------------------------------------------
# apr_lib_size_total <text>
# -----------------------------------------------------------------------------
apr_lib_size_total() {
    local text="${1-}"
    if [[ -z "$text" ]]; then
        printf '0'
        return 0
    fi
    local n
    n=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# -----------------------------------------------------------------------------
# apr_lib_size_breakdown <manifest_text> <template_text> <file_paths...>
#
# Emit a compact JSON object with the size breakdown for a prompt
# bundle. Useful for `apr render --show-manifest` JSON output and for
# the eventual ledger artifact.
#
# Determinism: files[] is stable-sorted by path (LC_ALL=C) so the JSON
# is byte-identical across runs.
# -----------------------------------------------------------------------------
apr_lib_size_breakdown() {
    local manifest="${1-}"
    local template="${2-}"
    shift 2 2>/dev/null || true

    local manifest_bytes template_bytes
    manifest_bytes=$(apr_lib_size_total "$manifest")
    template_bytes=$(apr_lib_size_total "$template")

    # Per-file sizes (use cache when available via apr_lib_manifest_size,
    # which already handles missing files gracefully).
    local files_json="[]"
    local files_total=0
    if [[ "$#" -gt 0 ]]; then
        # Sort paths stably.
        local sorted
        sorted=$(printf '%s\n' "$@" | LC_ALL=C sort)
        local entries=()
        local p basename bytes
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            basename=$(apr_lib_manifest_basename "$p")
            # apr_lib_manifest_size emits "0" on missing files AND
            # returns rc=1; capture stdout only, treat any rc, and
            # validate the result is a non-negative integer.
            bytes=$(apr_lib_manifest_size "$p" 2>/dev/null) || true
            [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
            files_total=$(( files_total + bytes ))
            local p_esc b_esc
            p_esc=$(apr_lib_manifest_json_escape "$p")
            b_esc=$(apr_lib_manifest_json_escape "$basename")
            entries+=("$(printf '{"path":"%s","basename":"%s","bytes":%s}' "$p_esc" "$b_esc" "$bytes")")
        done <<< "$sorted"
        local i first=1
        files_json="["
        for i in "${!entries[@]}"; do
            if [[ $first -eq 0 ]]; then files_json+=","; fi
            first=0
            files_json+="${entries[$i]}"
        done
        files_json+="]"
    fi

    local total=$(( manifest_bytes + template_bytes ))
    # Note: in many flows the included files are ALREADY part of
    # template/manifest expansion (template directives, manifest preamble).
    # We report files_total_bytes separately so callers can see the raw
    # corpus size, but `total` is just manifest+template — the actual
    # bytes that would be passed to oracle -p.
    printf '{"total_bytes":%s,"manifest_bytes":%s,"template_bytes":%s,"files_total_bytes":%s,"files":%s}' \
        "$total" "$manifest_bytes" "$template_bytes" "$files_total" "$files_json"
}

# -----------------------------------------------------------------------------
# apr_lib_size_check_budget <bytes> [<budget>]
#
# Return 0 if bytes <= budget; return 1 if over budget. budget=0
# disables the check (always returns 0). budget defaults to
# APR_MAX_PROMPT_BYTES env var or 200000.
# -----------------------------------------------------------------------------
apr_lib_size_check_budget() {
    local bytes="${1:-0}"
    local budget="${2-}"
    if [[ -z "$budget" ]]; then
        budget="${APR_MAX_PROMPT_BYTES:-$_APR_SIZE_DEFAULT_MAX_BYTES}"
    fi
    [[ "$bytes"  =~ ^[0-9]+$ ]] || return 0
    [[ "$budget" =~ ^[0-9]+$ ]] || return 0
    if [[ "$budget" -eq 0 ]]; then
        return 0
    fi
    if [[ "$bytes" -le "$budget" ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# apr_lib_size_policy_resolve <bytes> [<budget>] [<warn_threshold>]
#
# Echo one of "ok" / "warn" / "over_budget". budget defaults to
# APR_MAX_PROMPT_BYTES (or constant); warn_threshold defaults to
# APR_PROMPT_WARN_BYTES (or constant). Passing budget=0 or
# warn=0 disables that respective check.
# -----------------------------------------------------------------------------
apr_lib_size_policy_resolve() {
    local bytes="${1:-0}"
    local budget="${2-}"
    local warn="${3-}"
    if [[ -z "$budget" ]]; then
        budget="${APR_MAX_PROMPT_BYTES:-$_APR_SIZE_DEFAULT_MAX_BYTES}"
    fi
    if [[ -z "$warn" ]]; then
        warn="${APR_PROMPT_WARN_BYTES:-$_APR_SIZE_DEFAULT_WARN_BYTES}"
    fi
    [[ "$bytes"  =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=0
    [[ "$warn"   =~ ^[0-9]+$ ]] || warn=0

    if [[ "$budget" -gt 0 && "$bytes" -gt "$budget" ]]; then
        printf 'over_budget'
        return 0
    fi
    if [[ "$warn" -gt 0 && "$bytes" -gt "$warn" ]]; then
        printf 'warn'
        return 0
    fi
    printf 'ok'
    return 0
}
