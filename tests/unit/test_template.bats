#!/usr/bin/env bats
# test_template.bats - Unit tests for lib/template.sh (bd-1mf)
#
# Validates the safe template directive engine specified in bd-2nq:
#   - five allowlisted TYPEs (FILE, SHA, SIZE, EXCERPT, LIT)
#   - parser correctness (single directive, multiple per line, multi-line text)
#   - path safety (absolute, traversal, missing, unreadable)
#   - byte determinism (FILE preserves bytes incl. trailing newline)
#   - error context globals are populated on failure
#   - verbose-mode logging stays on stderr and never leaks contents

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/template.sh"
    PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$PROJECT_ROOT"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical sha256s used in tests.
SHA_HELLO_WORLD="c0535e4be2b79ffd93291305436bf889314e4a3faec05ecffcbb7df31ad9e51a"   # sha256("Hello world!")
SHA_HELLO_CAP="185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969"     # sha256("Hello")
SHA_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# =============================================================================
# Trivial / empty inputs
# =============================================================================

@test "expand: empty input returns success and empty output" {
    run apr_lib_template_expand ""
    assert_success
    assert_output ""
}

@test "expand: text with no directives is returned verbatim" {
    run apr_lib_template_expand "hello world"
    assert_success
    assert_output "hello world"
}

@test "expand: multi-line text with no directives is preserved" {
    local input
    input=$'line1\nline2\nline3'
    run apr_lib_template_expand "$input"
    assert_success
    assert_output "$input"
}

# =============================================================================
# FILE directive
# =============================================================================

@test "FILE: inlines file contents" {
    printf 'Hello world!' > "$PROJECT_ROOT/README.md"
    run apr_lib_template_expand "[[APR:FILE README.md]]" "$PROJECT_ROOT"
    assert_success
    assert_output "Hello world!"
}

@test "FILE: surrounding text is preserved" {
    printf 'X' > "$PROJECT_ROOT/x.txt"
    run apr_lib_template_expand "before [[APR:FILE x.txt]] after" "$PROJECT_ROOT"
    assert_success
    assert_output "before X after"
}

@test "FILE: preserves trailing newline of source" {
    printf 'one\ntwo\n' > "$PROJECT_ROOT/a.txt"
    local out
    out=$(apr_lib_template_expand "[[APR:FILE a.txt]]" "$PROJECT_ROOT")
    [ "$out" = $'one\ntwo' ]   # command substitution strips trailing \n, so verify line content
    # Now verify the engine actually emitted the trailing newline before $()
    # by checking byte count via a second probe.
    local probe="$BATS_TEST_TMPDIR/probe.out"
    apr_lib_template_expand "[[APR:FILE a.txt]]" "$PROJECT_ROOT" > "$probe"
    [ "$(wc -c < "$probe" | tr -d '[:space:]')" = "8" ]   # "one\ntwo\n" = 8 bytes
}

@test "FILE: directive on its own line keeps surrounding newlines" {
    printf 'BODY' > "$PROJECT_ROOT/r.md"
    local input
    input=$'pre\n[[APR:FILE r.md]]\npost'
    run apr_lib_template_expand "$input" "$PROJECT_ROOT"
    assert_success
    assert_output "$(printf 'pre\nBODY\npost')"
}

@test "FILE: missing file -> file_not_found" {
    # NOTE: don't use `run` — it forks a subshell so error globals are lost.
    apr_lib_template_expand "[[APR:FILE nope.md]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "file_not_found" ]
    [ "$APR_TEMPLATE_ERROR_TYPE" = "FILE" ]
}

@test "FILE: bad args (no path) -> bad_args" {
    apr_lib_template_expand "[[APR:FILE]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "bad_args" ]
}

@test "FILE: absolute path without opt-in -> absolute_path_blocked" {
    apr_lib_template_expand "[[APR:FILE /etc/passwd]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "absolute_path_blocked" ]
}

@test "FILE: traversal without opt-in -> traversal_blocked" {
    apr_lib_template_expand "[[APR:FILE ../etc/passwd]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "traversal_blocked" ]
}

@test "FILE: allow_traversal opt-in permits parent file" {
    printf 'sibling' > "$BATS_TEST_TMPDIR/sibling.txt"
    run apr_lib_template_expand "[[APR:FILE ../sibling.txt]]" "$PROJECT_ROOT" 1
    assert_success
    assert_output "sibling"
}

# =============================================================================
# SHA directive
# =============================================================================

@test "SHA: emits 64-char lowercase hex" {
    printf 'Hello world!' > "$PROJECT_ROOT/r.md"
    run apr_lib_template_expand "[[APR:SHA r.md]]" "$PROJECT_ROOT"
    assert_success
    assert_output "$SHA_HELLO_WORLD"
}

@test "SHA: empty file -> empty-byte-string sha" {
    : > "$PROJECT_ROOT/empty"
    run apr_lib_template_expand "[[APR:SHA empty]]" "$PROJECT_ROOT"
    assert_success
    assert_output "$SHA_EMPTY"
}

@test "SHA: missing file -> file_not_found" {
    apr_lib_template_expand "[[APR:SHA missing]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "file_not_found" ]
}

# =============================================================================
# SIZE directive
# =============================================================================

@test "SIZE: emits exact byte count" {
    printf '12345' > "$PROJECT_ROOT/r.md"
    run apr_lib_template_expand "[[APR:SIZE r.md]]" "$PROJECT_ROOT"
    assert_success
    assert_output "5"
}

@test "SIZE: empty file -> 0" {
    : > "$PROJECT_ROOT/empty"
    run apr_lib_template_expand "[[APR:SIZE empty]]" "$PROJECT_ROOT"
    assert_success
    assert_output "0"
}

# =============================================================================
# EXCERPT directive
# =============================================================================

@test "EXCERPT: first N bytes of file" {
    printf 'abcdefghij' > "$PROJECT_ROOT/r.md"
    run apr_lib_template_expand "[[APR:EXCERPT r.md 4]]" "$PROJECT_ROOT"
    assert_success
    assert_output "abcd"
}

@test "EXCERPT: file shorter than N returns whole file (no error)" {
    printf 'hi' > "$PROJECT_ROOT/r.md"
    run apr_lib_template_expand "[[APR:EXCERPT r.md 99]]" "$PROJECT_ROOT"
    assert_success
    assert_output "hi"
}

@test "EXCERPT: bad N (non-integer) -> bad_arg_excerpt_n" {
    printf 'x' > "$PROJECT_ROOT/r.md"
    apr_lib_template_expand "[[APR:EXCERPT r.md abc]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "bad_arg_excerpt_n" ]
}

@test "EXCERPT: N=0 -> bad_arg_excerpt_n (must be positive)" {
    printf 'x' > "$PROJECT_ROOT/r.md"
    apr_lib_template_expand "[[APR:EXCERPT r.md 0]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "bad_arg_excerpt_n" ]
}

@test "EXCERPT: missing args -> bad_args" {
    apr_lib_template_expand "[[APR:EXCERPT r.md]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "bad_args" ]
}

# =============================================================================
# LIT directive
# =============================================================================

@test "LIT: returns raw argument text" {
    run apr_lib_template_expand "[[APR:LIT hi there]]"
    assert_success
    assert_output "hi there"
}

@test "LIT: protects nested-looking directive syntax" {
    # The spec promises [[APR:LIT [[APR:FILE README.md]]]] turns into the
    # literal [[APR:FILE README.md]] (engine does not rescan its output).
    run apr_lib_template_expand "[[APR:LIT [[APR:FILE README.md]]]]"
    assert_success
    # The parser stops at the FIRST `]]` it sees, so what LIT receives is
    # "[[APR:FILE README.md". That's the documented behavior for v1.
    assert_output --partial "[[APR:FILE README.md"
}

@test "LIT: regression bd-r3lo — `*` is NOT glob-expanded against CWD" {
    # OrangeGorge's repro: prior to the fix, an unquoted `$body_trimmed`
    # in the tokenizer made `*` glob-match the project root's filenames.
    # `set -f` around the array assignment shuts this down.
    local out
    out=$(apr_lib_template_expand "[[APR:LIT punctuation * ( ) ]]" "$PROJECT_ROOT" 0 0 0)
    [ "$out" = "punctuation * ( )" ]
}

@test "LIT: regression bd-r3lo — `?` is NOT glob-expanded" {
    # Single-char glob '?'. Touch a file so '?' would match if globbing leaked.
    touch "$PROJECT_ROOT/A"
    local out
    out=$(apr_lib_template_expand "[[APR:LIT before ? after]]" "$PROJECT_ROOT" 0 0 0)
    [ "$out" = "before ? after" ]
}

@test "LIT: regression bd-r3lo — `[abc]` bracket class is NOT glob-expanded" {
    touch "$PROJECT_ROOT/a" "$PROJECT_ROOT/b" "$PROJECT_ROOT/c"
    local out
    out=$(apr_lib_template_expand "[[APR:LIT pre [abc] post]]" "$PROJECT_ROOT" 0 0 0)
    [ "$out" = "pre [abc] post" ]
}

# =============================================================================
# Parser: unknown TYPE, unterminated, multiple directives
# =============================================================================

@test "parser: unknown TYPE -> unknown_type with allowlist hint" {
    apr_lib_template_expand "[[APR:NOPE x]]" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "unknown_type" ]
    [ "$APR_TEMPLATE_ERROR_TYPE" = "NOPE" ]
    [[ "$APR_TEMPLATE_ERROR_MESSAGE" == *"FILE"* ]]
    [[ "$APR_TEMPLATE_ERROR_MESSAGE" == *"SHA"* ]]
}

@test "parser: lowercase 'file' is rejected (TYPEs are uppercase)" {
    apr_lib_template_expand "[[APR:file README.md]]" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "unknown_type" ]
}

@test "parser: unterminated directive -> unterminated_directive" {
    local input
    input=$'leading [[APR:FILE r.md\nstill no close'
    apr_lib_template_expand "$input" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "unterminated_directive" ]
    [ "$APR_TEMPLATE_ERROR_LINE" = "1" ]
}

@test "parser: empty body -> bad_args" {
    apr_lib_template_expand "[[APR:]]" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "bad_args" ]
}

@test "parser: multiple directives on one line all expand" {
    printf 'A' > "$PROJECT_ROOT/a.txt"
    printf 'B' > "$PROJECT_ROOT/b.txt"
    run apr_lib_template_expand "[[APR:FILE a.txt]] mid [[APR:FILE b.txt]]" "$PROJECT_ROOT"
    assert_success
    assert_output "A mid B"
}

@test "parser: directives across multiple lines are independent" {
    printf 'A' > "$PROJECT_ROOT/a.txt"
    printf 'B' > "$PROJECT_ROOT/b.txt"
    local input
    input=$'before\n[[APR:FILE a.txt]]\nmiddle\n[[APR:FILE b.txt]]\nafter'
    run apr_lib_template_expand "$input" "$PROJECT_ROOT"
    assert_success
    assert_output "$(printf 'before\nA\nmiddle\nB\nafter')"
}

@test "parser: error on second line reports line=2" {
    printf 'A' > "$PROJECT_ROOT/a.txt"
    local input
    input=$'[[APR:FILE a.txt]]\n[[APR:NOPE x]]'
    apr_lib_template_expand "$input" "$PROJECT_ROOT" >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -ne 0 ]
    [ "$APR_TEMPLATE_ERROR_REASON" = "unknown_type" ]
    [ "$APR_TEMPLATE_ERROR_LINE" = "2" ]
}

# =============================================================================
# Determinism
# =============================================================================

@test "determinism: same template + files -> byte-identical output" {
    printf 'Hello world!' > "$PROJECT_ROOT/r.md"
    local out1 out2
    out1=$(apr_lib_template_expand "[[APR:FILE r.md]] [[APR:SHA r.md]] [[APR:SIZE r.md]]" "$PROJECT_ROOT")
    out2=$(apr_lib_template_expand "[[APR:FILE r.md]] [[APR:SHA r.md]] [[APR:SIZE r.md]]" "$PROJECT_ROOT")
    [ "$out1" = "$out2" ]
}

@test "determinism: re-running yields same prompt_hash" {
    printf 'Hello' > "$PROJECT_ROOT/r.md"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/manifest.sh"
    local out1 out2 h1 h2
    out1=$(apr_lib_template_expand "prefix [[APR:SHA r.md]] suffix" "$PROJECT_ROOT")
    out2=$(apr_lib_template_expand "prefix [[APR:SHA r.md]] suffix" "$PROJECT_ROOT")
    h1=$(apr_lib_manifest_hash_text "$out1")
    h2=$(apr_lib_manifest_hash_text "$out2")
    [ "$h1" = "$h2" ]
    # And the SHA should match the well-known sha256("Hello")
    [[ "$out1" == *"$SHA_HELLO_CAP"* ]]
}

# =============================================================================
# Verbose mode
# =============================================================================

@test "verbose: emits expansion log lines to stderr; output unchanged" {
    printf 'BODY' > "$PROJECT_ROOT/r.md"
    local out err
    err=$(apr_lib_template_expand "[[APR:FILE r.md]]" "$PROJECT_ROOT" 0 0 1 2>&1 >/dev/null)
    out=$(apr_lib_template_expand "[[APR:FILE r.md]]" "$PROJECT_ROOT" 0 0 1 2>/dev/null)
    [ "$out" = "BODY" ]
    [[ "$err" == *"template: expanded [[APR:FILE"* ]]
    # Verbose log MUST NOT contain the file contents themselves.
    [[ "$err" != *"BODY"* ]]
}

@test "verbose: SHA log shows truncated hash only" {
    printf 'Hello world!' > "$PROJECT_ROOT/r.md"
    local err
    err=$(apr_lib_template_expand "[[APR:SHA r.md]]" "$PROJECT_ROOT" 0 0 1 2>&1 >/dev/null)
    [[ "$err" == *"c0535e4b..."* ]]
    # Full 64-char hash must NOT appear in the verbose log.
    [[ "$err" != *"$SHA_HELLO_WORLD"* ]]
}

# =============================================================================
# Error globals are cleared on success
# =============================================================================

@test "error globals: cleared on successful expansion" {
    printf 'X' > "$PROJECT_ROOT/r.md"
    # Trigger an error first.
    apr_lib_template_expand "[[APR:NOPE]]" "$PROJECT_ROOT" >/dev/null 2>&1 || true
    [ -n "$APR_TEMPLATE_ERROR_REASON" ]
    # Now run a clean expansion; globals should be empty. Direct call (not
    # `run`) so the globals survive into this test.
    local out
    out=$(apr_lib_template_expand "[[APR:FILE r.md]]" "$PROJECT_ROOT" 2>/dev/null)
    # Re-run in current shell context to reset globals here.
    apr_lib_template_expand "[[APR:FILE r.md]]" "$PROJECT_ROOT" >/dev/null 2>&1
    [ "$out" = "X" ]
    [ -z "$APR_TEMPLATE_ERROR_REASON" ]
    [ -z "$APR_TEMPLATE_ERROR_LINE" ]
    [ -z "$APR_TEMPLATE_ERROR_TYPE" ]
}
