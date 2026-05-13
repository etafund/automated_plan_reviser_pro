#!/usr/bin/env bats
# test_cache.bats - Unit tests for lib/cache.sh (bd-1aw)
#
# Validates:
#   - basic hit/miss for sha256 and size
#   - invalidation when file mtime or size changes
#   - APR_NO_CACHE=1 bypass
#   - on-disk cache (write + reload via fresh init)
#   - cache returns byte-identical output to the uncached helpers
#   - stats counters track hits/misses

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/cache.sh"
    apr_lib_cache_init "$BATS_TEST_TMPDIR"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical sha256s used.
SHA_HELLO_WORLD="c0535e4be2b79ffd93291305436bf889314e4a3faec05ecffcbb7df31ad9e51a"
SHA_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# =============================================================================
# sha256: hit / miss
# =============================================================================

@test "sha256: first call is a miss, returns correct hash" {
    printf 'Hello world!' > "$BATS_TEST_TMPDIR/r.md"
    run apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md"
    assert_success
    assert_output "$SHA_HELLO_WORLD"
}

@test "sha256: second call is a hit, returns same hash" {
    printf 'Hello world!' > "$BATS_TEST_TMPDIR/r.md"
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    # 2 calls -> 1 miss + 1 hit.
    local stats
    stats=$(apr_lib_cache_stats)
    [[ "$stats" == *'"hits":1'* ]]
    [[ "$stats" == *'"misses":1'* ]]
}

@test "sha256: cached output is byte-identical to uncached" {
    printf 'some content for hashing' > "$BATS_TEST_TMPDIR/r.md"
    local cached uncached
    cached=$(apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md")
    uncached=$(APR_NO_CACHE=1 apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md")
    [ "$cached" = "$uncached" ]
    [ "${#cached}" -eq 64 ]
}

@test "sha256: empty file returns empty-string sha256" {
    : > "$BATS_TEST_TMPDIR/empty"
    run apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/empty"
    assert_success
    assert_output "$SHA_EMPTY"
}

@test "sha256: missing file falls back to canonical helper" {
    run apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/no-such"
    # Missing file: helper emits empty-sha and returns 1.
    [ "$status" -eq 1 ]
    assert_output "$SHA_EMPTY"
}

# =============================================================================
# size: hit / miss
# =============================================================================

@test "size: first call returns exact byte count" {
    printf 'abcde' > "$BATS_TEST_TMPDIR/r.md"
    run apr_lib_cache_size_file "$BATS_TEST_TMPDIR/r.md"
    assert_success
    assert_output "5"
}

@test "size: cached output matches uncached" {
    printf 'abcdefghij' > "$BATS_TEST_TMPDIR/r.md"
    local cached uncached
    cached=$(apr_lib_cache_size_file "$BATS_TEST_TMPDIR/r.md")
    uncached=$(APR_NO_CACHE=1 apr_lib_cache_size_file "$BATS_TEST_TMPDIR/r.md")
    [ "$cached" = "$uncached" ]
    [ "$cached" = "10" ]
}

# =============================================================================
# Invalidation: mtime / size changes
# =============================================================================

@test "invalidation: file rewrite with different content triggers miss" {
    local f="$BATS_TEST_TMPDIR/r.md"
    printf 'first' > "$f"
    # Call without $() so counter updates land in this shell.
    apr_lib_cache_sha256_file "$f" > "$BATS_TEST_TMPDIR/sha1"
    sleep 1.1
    printf 'second-and-longer' > "$f"
    apr_lib_cache_sha256_file "$f" > "$BATS_TEST_TMPDIR/sha2"
    local sha1 sha2
    sha1=$(cat "$BATS_TEST_TMPDIR/sha1")
    sha2=$(cat "$BATS_TEST_TMPDIR/sha2")
    [ "$sha1" != "$sha2" ]
    local stats
    stats=$(apr_lib_cache_stats)
    # Two distinct keys → both are misses (no hits yet because each was
    # the first lookup for its own (mtime,size)).
    [[ "$stats" == *'"misses":2'* ]]
}

@test "invalidation: re-lookup after rewrite is a hit on the NEW content" {
    local f="$BATS_TEST_TMPDIR/r.md"
    printf 'first' > "$f"
    apr_lib_cache_sha256_file "$f" >/dev/null
    sleep 1.1
    printf 'second-content' > "$f"
    apr_lib_cache_sha256_file "$f" >/dev/null  # miss (new key)
    apr_lib_cache_sha256_file "$f" >/dev/null  # hit on new key
    local stats
    stats=$(apr_lib_cache_stats)
    # 3 calls -> 2 distinct keys -> 2 misses + 1 hit.
    [[ "$stats" == *'"hits":1'* ]]
    [[ "$stats" == *'"misses":2'* ]]
}

# =============================================================================
# APR_NO_CACHE bypass
# =============================================================================

@test "APR_NO_CACHE: skips both in-process and disk cache" {
    printf 'content' > "$BATS_TEST_TMPDIR/r.md"
    APR_NO_CACHE=1 apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    APR_NO_CACHE=1 apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    local stats
    stats=$(apr_lib_cache_stats)
    # Stats should remain at zero — bypass never touches counters.
    [[ "$stats" == *'"hits":0'* ]]
    [[ "$stats" == *'"misses":0'* ]]
}

# =============================================================================
# On-disk persistence
# =============================================================================

@test "persist: sha256 cached on disk and reloaded after clear" {
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        skip "no sha256 tool available"
    fi
    printf 'persistable' > "$BATS_TEST_TMPDIR/r.md"
    # Direct call (not $()) so disk-write side-effect lands.
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" 1 > "$BATS_TEST_TMPDIR/sha_a"
    # Disk file exists.
    local disk_count
    disk_count=$(find "$BATS_TEST_TMPDIR/.apr/cache/sha" -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$disk_count" -ge 1 ]
    # Drop the in-process cache and re-fetch — should match.
    apr_lib_cache_clear
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" 1 > "$BATS_TEST_TMPDIR/sha_b"
    [ "$(cat "$BATS_TEST_TMPDIR/sha_a")" = "$(cat "$BATS_TEST_TMPDIR/sha_b")" ]
    # And after clear, the in-process counters show a hit on the disk-loaded value.
    local stats
    stats=$(apr_lib_cache_stats)
    [[ "$stats" == *'"hits":1'* ]]
}

@test "persist: size cached on disk and reloaded" {
    printf '12345abcde' > "$BATS_TEST_TMPDIR/r.md"
    local s_a
    s_a=$(apr_lib_cache_size_file "$BATS_TEST_TMPDIR/r.md" 1)
    apr_lib_cache_clear
    local s_b
    s_b=$(apr_lib_cache_size_file "$BATS_TEST_TMPDIR/r.md" 1)
    [ "$s_a" = "$s_b" ]
    [ "$s_a" = "10" ]
}

@test "persist: disk cache is invalidated by file change (key includes mtime,size)" {
    local f="$BATS_TEST_TMPDIR/r.md"
    printf 'before' > "$f"
    local sha_a
    sha_a=$(apr_lib_cache_sha256_file "$f" 1)
    apr_lib_cache_clear
    sleep 1.1
    printf 'after-changed' > "$f"
    local sha_b
    sha_b=$(apr_lib_cache_sha256_file "$f" 1)
    [ "$sha_a" != "$sha_b" ]
    # `after-changed` is 13 bytes; verify the new hash matches a fresh helper call.
    local fresh
    fresh=$(APR_NO_CACHE=1 apr_lib_cache_sha256_file "$f")
    [ "$sha_b" = "$fresh" ]
}

# =============================================================================
# init / clear lifecycle
# =============================================================================

@test "init: clearing resets all counters" {
    printf 'x' > "$BATS_TEST_TMPDIR/r.md"
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    apr_lib_cache_sha256_file "$BATS_TEST_TMPDIR/r.md" >/dev/null
    apr_lib_cache_clear
    local stats
    stats=$(apr_lib_cache_stats)
    [[ "$stats" == *'"hits":0'* ]]
    [[ "$stats" == *'"misses":0'* ]]
}

@test "stats: well-formed JSON" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_cache_stats)
    python3 -c "
import json
d = json.loads('''$out''')
assert set(d.keys()) == {'hits', 'misses', 'recompute_invalidated'}
assert all(isinstance(v, int) for v in d.values())
"
}
