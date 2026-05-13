#!/usr/bin/env bats
# test_cache_fuzz.bats
#
# Bead automated_plan_reviser_pro-w58y — fuzz/property layer for
# lib/cache.sh.
#
# lib/cache.sh has 15 happy-path unit tests in tests/unit/test_cache.bats.
# This file adds a property-based layer covering:
#
#   - hit/miss equivalence (cached value byte-identical to canonical)
#   - mutation invalidation under several distinct mutation classes
#   - disk persistence across in-process clears
#   - stats counter monotonicity
#   - large-file paths
#   - missing-path fallback
#   - a known sharp edge: same mtime + same size + different content
#     (mtime-collision)
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/cache.sh"

    # Each test gets a fresh project root + cache state.
    FIXTURE_ROOT="$TEST_DIR/cache_fuzz"
    mkdir -p "$FIXTURE_ROOT"
    apr_lib_cache_init "$FIXTURE_ROOT"

    # Reset every knob test setup might leak.
    unset APR_NO_CACHE APR_CACHE_PERSIST 2>/dev/null || true

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse a single counter out of apr_lib_cache_stats.
stat_field() {
    local field="$1"
    apr_lib_cache_stats | jq -r ".$field"
}

# Bash `$(cmd)` runs in a SUBSHELL — any mutation to globals (the
# cache associative array, hit/miss counters) inside `cmd` is lost
# when the subshell exits. For tests that need to OBSERVE counter
# updates or expect the in-process cache to be populated for later
# calls, we capture via a tempfile + redirect (no subshell).
capture_sha() {
    # Args: <out-var> <path> [<persist>]
    local _out="$1" _path="$2" _persist="${3:-0}"
    local _tmp="$ARTIFACT_DIR/sha_$RANDOM.out"
    if [[ "$_persist" == "1" ]]; then
        APR_CACHE_PERSIST=1 apr_lib_cache_sha256_file "$_path" > "$_tmp"
    else
        apr_lib_cache_sha256_file "$_path" > "$_tmp"
    fi
    printf -v "$_out" '%s' "$(< "$_tmp")"
}

capture_size() {
    local _out="$1" _path="$2"
    local _tmp="$ARTIFACT_DIR/size_$RANDOM.out"
    apr_lib_cache_size_file "$_path" > "$_tmp"
    printf -v "$_out" '%s' "$(< "$_tmp")"
}

# ===========================================================================
# I1 — hit/uncached equivalence
# ===========================================================================

@test "I1: cached sha256 is byte-identical to uncached, across many distinct contents" {
    local i
    for i in 1 2 3 4 5; do
        local f="$FIXTURE_ROOT/file_$i.txt"
        printf 'distinct content number %d\n' "$i" > "$f"

        local first cached
        APR_NO_CACHE=1 first=$(apr_lib_cache_sha256_file "$f")
        cached=$(apr_lib_cache_sha256_file "$f")
        [[ "$first" == "$cached" ]] || {
            echo "drift on $f: uncached=$first cached=$cached" >&2
            return 1
        }
    done
}

@test "I1: cached size is byte-identical to uncached, across files of distinct sizes" {
    local size
    for size in 1 10 100 1000; do
        local f="$FIXTURE_ROOT/size_${size}.bin"
        head -c "$size" /dev/urandom > "$f" || dd if=/dev/zero of="$f" bs=1 count="$size" 2>/dev/null
        local first cached
        APR_NO_CACHE=1 first=$(apr_lib_cache_size_file "$f")
        cached=$(apr_lib_cache_size_file "$f")
        [[ "$first" == "$cached" ]]
        [[ "$first" == "$size" ]]
    done
}

# ===========================================================================
# I2 — mutation invalidation (content change → next call recomputes)
# ===========================================================================

@test "I2: rewriting a file with different content makes the next call a miss + new value" {
    local f="$FIXTURE_ROOT/mutating.txt"
    printf 'original content\n' > "$f"

    local before after
    capture_sha before "$f"          # state-preserving capture
    apr_lib_cache_size_file "$f" >/dev/null   # warm size, no subshell

    # Mutate (different bytes + different size for clarity).
    sleep 1   # ensure mtime ticks (1-sec resolution on some filesystems)
    printf 'completely different and longer content\n' > "$f"

    local misses_before misses_after
    misses_before=$(stat_field misses)

    capture_sha after "$f"

    [[ "$before" != "$after" ]] || {
        echo "cache did not detect content mutation" >&2
        return 1
    }
    misses_after=$(stat_field misses)
    [[ "$misses_after" -gt "$misses_before" ]] || {
        echo "miss counter did not tick on invalidation: $misses_before → $misses_after" >&2
        return 1
    }
}

# ===========================================================================
# I3 — mtime-only mutation invalidates (touch without content change)
# ===========================================================================

@test "I3: touching the file invalidates the cache (key includes mtime)" {
    local f="$FIXTURE_ROOT/touchy.txt"
    printf 'same content\n' > "$f"

    apr_lib_cache_sha256_file "$f" >/dev/null
    local misses_before
    misses_before=$(stat_field misses)

    # Touch with a future mtime.
    sleep 1
    touch "$f"

    apr_lib_cache_sha256_file "$f" >/dev/null
    local misses_after
    misses_after=$(stat_field misses)

    [[ "$misses_after" -gt "$misses_before" ]] || {
        echo "touch did NOT invalidate cache:" >&2
        apr_lib_cache_stats >&2
        return 1
    }
}

# ===========================================================================
# I4 — known sharp edge: same mtime + same size + different content
# ===========================================================================
#
# The cache key is "<abs-path>|<mtime>|<size>". If a file is replaced
# with content of identical size AND the replacement happens within the
# same mtime tick, the cache key collides. This is a real edge case
# (atomic-swap-via-rename within a 1-second window), worth pinning so
# that we know the behavior.

@test "I4: same-path+same-mtime+same-size+different-content keeps the OLD cached value (known sharp edge)" {
    local f="$FIXTURE_ROOT/colliding.txt"
    printf 'aaaaaaaaaa\n' > "$f"   # 11 bytes

    # First call populates the cache. `capture_sha` runs in the parent
    # shell so the in-process cache is preserved for the second call.
    local original
    capture_sha original "$f"

    # Get current mtime, replace content with same length and DIFFERENT
    # bytes, then forcibly reset mtime back to the original epoch.
    local orig_mtime
    orig_mtime=$(stat -c '%Y' -- "$f" 2>/dev/null || stat -f '%m' -- "$f" 2>/dev/null)
    printf 'bbbbbbbbbb\n' > "$f"
    touch -d "@$orig_mtime" -- "$f" 2>/dev/null \
        || touch -t "$(date -r "$orig_mtime" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$f" 2>/dev/null \
        || skip "touch -d/-t not supported on this host"

    # Now query the cache — key is identical, value returns the OLD sha.
    local cached
    capture_sha cached "$f"

    # And the canonical helper (bypasses cache) computes the NEW sha.
    local canonical
    canonical=$(apr_lib_manifest_sha256 "$f")

    [[ "$cached" == "$original" ]] || {
        echo "cache did not return the cached (stale) value:" >&2
        echo "  original=$original cached=$cached canonical=$canonical" >&2
        return 1
    }
    [[ "$canonical" != "$original" ]] || {
        echo "canonical helper did not reflect content change:" >&2
        echo "  original=$original canonical=$canonical" >&2
        return 1
    }
}

# ===========================================================================
# I5 — APR_NO_CACHE=1 bypasses both layers
# ===========================================================================

@test "I5: APR_NO_CACHE=1 — every call is a miss (in-process counters never tick)" {
    local f="$FIXTURE_ROOT/nocache.txt"
    printf 'content\n' > "$f"

    local hits_before misses_before
    hits_before=$(stat_field hits)
    misses_before=$(stat_field misses)

    APR_NO_CACHE=1 apr_lib_cache_sha256_file "$f" >/dev/null
    APR_NO_CACHE=1 apr_lib_cache_sha256_file "$f" >/dev/null
    APR_NO_CACHE=1 apr_lib_cache_sha256_file "$f" >/dev/null

    local hits_after misses_after
    hits_after=$(stat_field hits)
    misses_after=$(stat_field misses)

    [[ "$hits_after" -eq "$hits_before" ]] || {
        echo "APR_NO_CACHE incremented hits: $hits_before → $hits_after" >&2
        return 1
    }
    [[ "$misses_after" -eq "$misses_before" ]] || {
        echo "APR_NO_CACHE incremented misses: $misses_before → $misses_after" >&2
        return 1
    }
}

# ===========================================================================
# I6 — disk persistence across in-process clears
# ===========================================================================

@test "I6: APR_CACHE_PERSIST=1 — disk cache survives clear+re-source" {
    local f="$FIXTURE_ROOT/persist.txt"
    printf 'persistent content\n' > "$f"

    # Populate disk cache. capture_sha runs in the parent shell so the
    # in-process cache is also populated.
    local first
    capture_sha first "$f" 1

    # Clear in-process; the disk file at $FIXTURE_ROOT/.apr/cache/...
    # should still be there.
    apr_lib_cache_clear
    # Re-init points to the same disk dir.
    apr_lib_cache_init "$FIXTURE_ROOT"

    local after
    capture_sha after "$f" 1
    [[ "$first" == "$after" ]]

    # And it counted as a HIT (disk cache loaded into in-process).
    [[ "$(stat_field hits)" -ge 1 ]] || {
        echo "expected disk hit after clear+re-init:" >&2
        apr_lib_cache_stats >&2
        return 1
    }
}

@test "I6: disk cache is invalidated when the file changes between sessions" {
    local f="$FIXTURE_ROOT/persist_invalidate.txt"
    printf 'v1\n' > "$f"

    local v1
    v1=$(APR_CACHE_PERSIST=1 apr_lib_cache_sha256_file "$f")

    apr_lib_cache_clear
    apr_lib_cache_init "$FIXTURE_ROOT"

    sleep 1
    printf 'v2 different content\n' > "$f"

    local v2
    v2=$(APR_CACHE_PERSIST=1 apr_lib_cache_sha256_file "$f")
    [[ "$v1" != "$v2" ]]
}

# ===========================================================================
# I7 — stats counter monotonicity
# ===========================================================================

@test "I7: hits + misses are monotonically non-decreasing across operations" {
    local f="$FIXTURE_ROOT/monotone.txt"
    printf 'x\n' > "$f"

    local prev_h prev_m h m
    prev_h=$(stat_field hits)
    prev_m=$(stat_field misses)

    local i
    for i in $(seq 1 10); do
        apr_lib_cache_sha256_file "$f" >/dev/null
        h=$(stat_field hits)
        m=$(stat_field misses)
        [[ "$h" -ge "$prev_h" ]] || { echo "hits decreased: $prev_h → $h" >&2; return 1; }
        [[ "$m" -ge "$prev_m" ]] || { echo "misses decreased: $prev_m → $m" >&2; return 1; }
        prev_h="$h"; prev_m="$m"
    done

    # At minimum: 1 miss (first call) + 9 hits.
    [[ "$m" -ge 1 ]]
    [[ "$h" -ge 9 ]]
}

@test "I7: apr_lib_cache_stats always emits {hits, misses, recompute_invalidated} as numbers" {
    local out
    out=$(apr_lib_cache_stats)
    jq -e '
        .hits | type == "number" and . >= 0
    ' <<<"$out" >/dev/null
    jq -e '
        .misses | type == "number" and . >= 0
    ' <<<"$out" >/dev/null
    jq -e '
        .recompute_invalidated | type == "number" and . >= 0
    ' <<<"$out" >/dev/null
}

# ===========================================================================
# I8 — large file paths
# ===========================================================================

@test "I8: 1MB file hashes correctly and caches stably" {
    local f="$FIXTURE_ROOT/big.bin"
    head -c 1048576 /dev/urandom > "$f" \
        || dd if=/dev/zero of="$f" bs=4096 count=256 2>/dev/null

    local first cached
    APR_NO_CACHE=1 first=$(apr_lib_cache_sha256_file "$f")
    [[ "$first" =~ ^[0-9a-f]{64}$ ]]
    cached=$(apr_lib_cache_sha256_file "$f")
    [[ "$cached" == "$first" ]]

    # And size matches actual bytes.
    [[ "$(apr_lib_cache_size_file "$f")" -eq 1048576 ]]
}

# ===========================================================================
# I9 — missing/empty path falls back cleanly
# ===========================================================================

@test "I9: missing path returns canonical empty-sha and a non-zero exit" {
    local fake="$FIXTURE_ROOT/does/not/exist.txt"
    local rc=0
    local out
    out=$(apr_lib_cache_sha256_file "$fake") || rc=$?
    # apr_lib_manifest_sha256 emits the empty-string sha on missing
    # input. Pin that contract.
    [[ "$out" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]]
    [[ "$rc" -ne 0 ]]
}

@test "I9: missing path size returns 0 with non-zero exit" {
    local fake="$FIXTURE_ROOT/also/missing.txt"
    local rc=0 out
    out=$(apr_lib_cache_size_file "$fake") || rc=$?
    [[ "$out" == "0" ]]
    [[ "$rc" -ne 0 ]]
}

# ===========================================================================
# Cross-property: clear() resets all in-process state
# ===========================================================================

@test "clear: resets hits/misses/in-process maps to zero" {
    local f="$FIXTURE_ROOT/cleared.txt"
    printf 'x\n' > "$f"

    apr_lib_cache_sha256_file "$f" >/dev/null
    apr_lib_cache_sha256_file "$f" >/dev/null
    [[ "$(stat_field hits)" -ge 1 ]]

    apr_lib_cache_clear
    [[ "$(stat_field hits)" -eq 0 ]]
    [[ "$(stat_field misses)" -eq 0 ]]
    [[ "$(stat_field recompute_invalidated)" -eq 0 ]]
}

# ===========================================================================
# Determinism: same file → same sha, repeated calls byte-identical
# ===========================================================================

@test "determinism: 100 repeated lookups on the same file all return the identical sha" {
    local f="$FIXTURE_ROOT/determ.txt"
    printf 'deterministic\n' > "$f"

    local baseline current i
    baseline=$(apr_lib_cache_sha256_file "$f")
    for i in $(seq 1 100); do
        current=$(apr_lib_cache_sha256_file "$f")
        [[ "$current" == "$baseline" ]] || {
            echo "drift at iteration $i: $current vs $baseline" >&2
            return 1
        }
    done
}
