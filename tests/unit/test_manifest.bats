#!/usr/bin/env bats
# test_manifest.bats - Unit tests for lib/manifest.sh (bd-phj)
#
# Tests the manifest helpers that compute file hashes / sizes / basenames
# and render the prompt manifest section in text and JSON form.
#
# Tests:
#   - apr_lib_manifest_sha256
#   - apr_lib_manifest_size
#   - apr_lib_manifest_basename
#   - apr_lib_manifest_is_valid_reason
#   - apr_lib_manifest_json_escape
#   - apr_lib_manifest_entry_json
#   - apr_lib_manifest_render_json (stable sort + bracket framing)
#   - apr_lib_manifest_render_text (sections, sorting, skipped block)
#   - apr_lib_manifest_hash_text (well-known hashes)
#   - byte-determinism: identical inputs → identical outputs

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # Source the lib directly rather than going through apr.
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/manifest.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical sha256 of the empty byte string.
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# =============================================================================
# apr_lib_manifest_sha256
# =============================================================================

@test "manifest_sha256: known content yields known hash" {
    local f="$BATS_TEST_TMPDIR/hello.txt"
    printf 'hello world' > "$f"   # canonical "hello world" sha256

    run apr_lib_manifest_sha256 "$f"
    assert_success
    assert_output "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
}

@test "manifest_sha256: empty file yields empty-string sha256" {
    local f="$BATS_TEST_TMPDIR/empty.txt"
    : > "$f"

    run apr_lib_manifest_sha256 "$f"
    assert_success
    assert_output "$EMPTY_SHA256"
}

@test "manifest_sha256: missing path emits empty-sha and returns 1" {
    run apr_lib_manifest_sha256 "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -eq 1 ]
    assert_output "$EMPTY_SHA256"
}

@test "manifest_sha256: empty argument returns 1" {
    run apr_lib_manifest_sha256 ""
    [ "$status" -eq 1 ]
}

@test "manifest_sha256: no trailing newline in output" {
    local f="$BATS_TEST_TMPDIR/x"
    printf 'x' > "$f"
    local out
    out=$(apr_lib_manifest_sha256 "$f")
    # Output must be exactly 64 hex chars, no extra bytes.
    [ "${#out}" -eq 64 ]
    [[ "$out" =~ ^[0-9a-f]{64}$ ]]
}

# =============================================================================
# apr_lib_manifest_size
# =============================================================================

@test "manifest_size: byte size matches content length" {
    local f="$BATS_TEST_TMPDIR/sized.txt"
    printf 'abcdefghij' > "$f"   # 10 bytes

    run apr_lib_manifest_size "$f"
    assert_success
    assert_output "10"
}

@test "manifest_size: empty file emits 0" {
    local f="$BATS_TEST_TMPDIR/empty.txt"
    : > "$f"
    run apr_lib_manifest_size "$f"
    assert_success
    assert_output "0"
}

@test "manifest_size: missing path emits 0 and returns 1" {
    run apr_lib_manifest_size "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 1 ]
    assert_output "0"
}

@test "manifest_size: large content reports exact bytes" {
    local f="$BATS_TEST_TMPDIR/big.bin"
    # 4096 bytes of 'x' (head/yes pipeline trips SIGPIPE; do it with printf+repeat).
    local chunk='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'  # 64
    : > "$f"
    local i
    for ((i=0; i<64; i++)); do
        printf '%s' "$chunk" >> "$f"
    done
    run apr_lib_manifest_size "$f"
    assert_success
    assert_output "4096"
}

# =============================================================================
# apr_lib_manifest_basename
# =============================================================================

@test "manifest_basename: relative path" {
    run apr_lib_manifest_basename "docs/schemas/run-ledger.schema.json"
    assert_success
    assert_output "run-ledger.schema.json"
}

@test "manifest_basename: absolute path -> basename only" {
    run apr_lib_manifest_basename "/etc/passwd"
    assert_success
    assert_output "passwd"
}

@test "manifest_basename: trailing slash stripped" {
    run apr_lib_manifest_basename "foo/bar/"
    assert_success
    assert_output "bar"
}

@test "manifest_basename: bare filename" {
    run apr_lib_manifest_basename "README.md"
    assert_success
    assert_output "README.md"
}

@test "manifest_basename: empty input -> empty output" {
    run apr_lib_manifest_basename ""
    assert_success
    assert_output ""
}

# =============================================================================
# apr_lib_manifest_is_valid_reason
# =============================================================================

@test "is_valid_reason: accepts required" {
    run apr_lib_manifest_is_valid_reason "required"
    assert_success
}

@test "is_valid_reason: accepts optional" {
    run apr_lib_manifest_is_valid_reason "optional"
    assert_success
}

@test "is_valid_reason: accepts impl_every_n" {
    run apr_lib_manifest_is_valid_reason "impl_every_n"
    assert_success
}

@test "is_valid_reason: accepts skipped" {
    run apr_lib_manifest_is_valid_reason "skipped"
    assert_success
}

@test "is_valid_reason: rejects unknown" {
    run apr_lib_manifest_is_valid_reason "REQUIRED"
    [ "$status" -ne 0 ]
}

@test "is_valid_reason: rejects empty" {
    run apr_lib_manifest_is_valid_reason ""
    [ "$status" -ne 0 ]
}

# =============================================================================
# apr_lib_manifest_json_escape
# =============================================================================

@test "json_escape: passes through plain text" {
    run apr_lib_manifest_json_escape "hello"
    assert_success
    assert_output "hello"
}

@test "json_escape: backslash" {
    run apr_lib_manifest_json_escape 'a\b'
    assert_success
    assert_output 'a\\b'
}

@test "json_escape: double quote" {
    run apr_lib_manifest_json_escape 'a"b'
    assert_success
    assert_output 'a\"b'
}

@test "json_escape: newline" {
    local input
    input=$'line1\nline2'
    run apr_lib_manifest_json_escape "$input"
    assert_success
    assert_output 'line1\nline2'
}

@test "json_escape: tab" {
    local input
    input=$'a\tb'
    run apr_lib_manifest_json_escape "$input"
    assert_success
    assert_output 'a\tb'
}

# =============================================================================
# apr_lib_manifest_entry_json
# =============================================================================

@test "entry_json: contains all required keys for present file" {
    local f="$BATS_TEST_TMPDIR/foo.md"
    printf 'abc' > "$f"

    run apr_lib_manifest_entry_json "$f" "required"
    assert_success
    assert_output --partial '"basename":"foo.md"'
    assert_output --partial '"bytes":3'
    assert_output --partial '"inclusion_reason":"required"'
    # ba7816... is sha256("abc")
    assert_output --partial '"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"'
}

@test "entry_json: omits skipped_reason when not provided" {
    local f="$BATS_TEST_TMPDIR/x"
    printf '' > "$f"
    run apr_lib_manifest_entry_json "$f" "required"
    assert_success
    refute_output --partial "skipped_reason"
}

@test "entry_json: includes skipped_reason when provided" {
    run apr_lib_manifest_entry_json "$BATS_TEST_TMPDIR/missing" "skipped" "not-due-yet"
    assert_success
    assert_output --partial '"inclusion_reason":"skipped"'
    assert_output --partial '"skipped_reason":"not-due-yet"'
    assert_output --partial '"bytes":0'
    assert_output --partial "\"sha256\":\"$EMPTY_SHA256\""
}

# =============================================================================
# apr_lib_manifest_render_json
# =============================================================================

@test "render_json: empty input -> []" {
    run apr_lib_manifest_render_json
    assert_success
    assert_output "[]"
}

@test "render_json: stable sort by path (LC_ALL=C)" {
    local d="$BATS_TEST_TMPDIR/d"
    mkdir -p "$d"
    : > "$d/SPEC.md"
    : > "$d/README.md"
    : > "$d/Zoo.md"

    # Provide in random order.
    run apr_lib_manifest_render_json \
        "$d/Zoo.md|optional|" \
        "$d/SPEC.md|required|" \
        "$d/README.md|required|"
    assert_success

    # In LC_ALL=C sort, uppercase letters come in ASCII order:
    # README.md, SPEC.md, Zoo.md   (R < S < Z)
    local first
    first=$(printf '%s' "$output" | awk -F'"path":"' 'NR==1 {sub(/".*/,"",$2); print $2}')
    # Just verify the order by checking the order of basenames.
    local idx_r idx_s idx_z
    idx_r=$(printf '%s' "$output" | grep -bo '"basename":"README.md"' | head -1 | cut -d: -f1)
    idx_s=$(printf '%s' "$output" | grep -bo '"basename":"SPEC.md"'   | head -1 | cut -d: -f1)
    idx_z=$(printf '%s' "$output" | grep -bo '"basename":"Zoo.md"'    | head -1 | cut -d: -f1)
    [ "$idx_r" -lt "$idx_s" ]
    [ "$idx_s" -lt "$idx_z" ]
}

@test "render_json: deterministic across invocations" {
    local f="$BATS_TEST_TMPDIR/a.md"
    printf 'content' > "$f"
    local out1 out2
    out1=$(apr_lib_manifest_render_json "$f|required|")
    out2=$(apr_lib_manifest_render_json "$f|required|")
    [ "$out1" = "$out2" ]
}

@test "render_json: well-formed JSON (parses with python)" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/a.md"
    printf 'hi' > "$f"
    local out
    out=$(apr_lib_manifest_render_json "$f|required|" "missing|skipped|not-due-yet")
    python3 -c "import json,sys; json.loads('''$out''')"
}

# =============================================================================
# apr_lib_manifest_render_text
# =============================================================================

@test "render_text: empty input -> banner-only" {
    run apr_lib_manifest_render_text
    assert_success
    assert_output --partial "[APR Manifest]"
    assert_output --partial "No files configured."
}

@test "render_text: included section appears with sha + size" {
    local f="$BATS_TEST_TMPDIR/included.md"
    printf 'data' > "$f"
    run apr_lib_manifest_render_text "$f|required|"
    assert_success
    assert_output --partial "Included files:"
    assert_output --partial "  included.md"
    assert_output --partial "size:   4 bytes"
    # sha256("data") = 3a6eb079...
    assert_output --partial "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7"
}

@test "render_text: skipped section appears with reason" {
    run apr_lib_manifest_render_text "missing/x.md|skipped|not-due-yet"
    assert_success
    assert_output --partial "Skipped files:"
    assert_output --partial "  x.md"
    assert_output --partial "reason: skipped (not-due-yet)"
}

@test "render_text: deterministic" {
    local f="$BATS_TEST_TMPDIR/a.md"
    printf 'x' > "$f"
    local out1 out2
    out1=$(apr_lib_manifest_render_text "$f|required|")
    out2=$(apr_lib_manifest_render_text "$f|required|")
    [ "$out1" = "$out2" ]
}

# =============================================================================
# apr_lib_manifest_hash_text
# =============================================================================

@test "hash_text: known string yields known sha256" {
    run apr_lib_manifest_hash_text "hello world"
    assert_success
    assert_output "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
}

@test "hash_text: empty string yields empty-string sha256" {
    run apr_lib_manifest_hash_text ""
    assert_success
    assert_output "$EMPTY_SHA256"
}

@test "hash_text: deterministic" {
    local out1 out2
    out1=$(apr_lib_manifest_hash_text "deterministic")
    out2=$(apr_lib_manifest_hash_text "deterministic")
    [ "$out1" = "$out2" ]
    [ "${#out1}" -eq 64 ]
}
