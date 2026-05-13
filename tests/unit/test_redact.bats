#!/usr/bin/env bats
# test_redact.bats - Tests for lib/redact.sh (bd-3ut)
#
# Validates the prompt redaction layer:
#   - apr_lib_redact_prompt (typed sentinels per pattern class)
#   - apr_lib_redact_summary (compact JSON of redaction counts)
#
# Pattern classes covered: AKIA_KEY, AUTH_BEARER_TOKEN,
# GITHUB_FINEGRAINED, GITHUB_TOKEN, OPENAI_KEY, PRIVATE_KEY_BLOCK,
# SLACK_TOKEN.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/redact.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Pass-through (no redactions)
# =============================================================================

@test "redact: plain text passes through unchanged" {
    local out
    out=$(apr_lib_redact_prompt "Normal docs text. Some code: foo(bar).")
    [ "$out" = "Normal docs text. Some code: foo(bar)." ]
    [ "$APR_REDACT_COUNT" = "0" ]
}

@test "redact: empty input -> empty output, count 0" {
    local out
    out=$(apr_lib_redact_prompt "")
    [ -z "$out" ]
    [ "$APR_REDACT_COUNT" = "0" ]
}

@test "redact: apr_lib_redact_prompt works under set -u via command substitution" {
    run bash -lc 'set -euo pipefail; source lib/redact.sh; out=$(apr_lib_redact_prompt "clean"); printf "%s\n" "$out"'
    [ "$status" -eq 0 ]
    [ "$output" = "clean" ]
}

# =============================================================================
# OPENAI_KEY (sk-...)
# =============================================================================

@test "redact: OpenAI sk- key -> <<REDACTED:OPENAI_KEY>>" {
    # NOTE: don't use $() to capture — that's a subshell and would
    # discard APR_REDACT_COUNT. Route output through a tempfile so the
    # counter increment lands in this shell.
    apr_lib_redact_prompt "key=sk-aabbccddeeff112233445566778899XYZABC use it" \
        > "$BATS_TEST_TMPDIR/out"
    local out
    out=$(cat "$BATS_TEST_TMPDIR/out")
    [[ "$out" == *"<<REDACTED:OPENAI_KEY>>"* ]]
    [[ "$out" != *"aabbccddeeff"* ]]
    [ "$APR_REDACT_COUNT" = "1" ]
}

@test "redact: assign API preserves output and counters in caller shell" {
    local prompt="key=sk-aabbccddeeff112233445566778899XYZABC use it"

    apr_lib_redact_prompt_assign prompt "$prompt"

    [[ "$prompt" == *"<<REDACTED:OPENAI_KEY>>"* ]]
    [[ "$prompt" != *"aabbccddeeff"* ]]
    [ "$APR_REDACT_COUNT" = "1" ]
}

@test "redact: 'sk-' too short -> NOT redacted" {
    local out
    out=$(apr_lib_redact_prompt "ref: sk-ab")
    [[ "$out" == *"sk-ab"* ]]
    [ "$APR_REDACT_COUNT" = "0" ]
}

# =============================================================================
# GITHUB_TOKEN (ghp_/gho_/ghu_/ghs_/ghr_)
# =============================================================================

@test "redact: GitHub ghp_ token -> GITHUB_TOKEN sentinel" {
    apr_lib_redact_prompt "PAT: ghp_aabbccddeeff1122334455667788990011AABB" \
        > "$BATS_TEST_TMPDIR/out"
    local out
    out=$(cat "$BATS_TEST_TMPDIR/out")
    [[ "$out" == *"<<REDACTED:GITHUB_TOKEN>>"* ]]
    [ "$APR_REDACT_COUNT" = "1" ]
}

@test "redact: GitHub ghs_ short-lived token redacted" {
    local out
    out=$(apr_lib_redact_prompt "PAT: ghs_abcdefghij1234567890ABCDEF")
    [[ "$out" == *"<<REDACTED:GITHUB_TOKEN>>"* ]]
}

# =============================================================================
# GITHUB_FINEGRAINED (github_pat_...)
# =============================================================================

@test "redact: github_pat_ token -> GITHUB_FINEGRAINED sentinel" {
    local out
    out=$(apr_lib_redact_prompt "token=github_pat_AABBCCDDEEFF11223344556677889900")
    [[ "$out" == *"<<REDACTED:GITHUB_FINEGRAINED>>"* ]]
}

# =============================================================================
# SLACK_TOKEN (xox[bpars]-...)
# =============================================================================

@test "redact: Slack xoxb- token -> SLACK_TOKEN sentinel" {
    local out
    out=$(apr_lib_redact_prompt "slack=xoxb-1234567890-abcdef")
    [[ "$out" == *"<<REDACTED:SLACK_TOKEN>>"* ]]
    [[ "$out" != *"1234567890"* ]]
}

# =============================================================================
# AKIA_KEY (AWS access key id)
# =============================================================================

@test "redact: AWS AKIA key -> AKIA_KEY sentinel" {
    local out
    out=$(apr_lib_redact_prompt "k=AKIAIOSFODNN7EXAMPLE here")
    [[ "$out" == *"<<REDACTED:AKIA_KEY>>"* ]]
    [[ "$out" != *"AKIAIOSFODNN7EXAMPLE"* ]]
}

@test "redact: AKIA-ish but wrong length -> NOT redacted" {
    local out
    out=$(apr_lib_redact_prompt "AKIA123")
    [[ "$out" == *"AKIA123"* ]]
    [ "$APR_REDACT_COUNT" = "0" ]
}

# =============================================================================
# AUTH_BEARER_TOKEN (Authorization: Bearer ...)
# =============================================================================

@test "redact: Authorization Bearer header -> AUTH_BEARER_TOKEN sentinel" {
    local out
    out=$(apr_lib_redact_prompt "Authorization: Bearer abc123tok-XYZ rest")
    [[ "$out" == *"<<REDACTED:AUTH_BEARER_TOKEN>>"* ]]
    [[ "$out" != *"abc123tok"* ]]
}

# =============================================================================
# PRIVATE_KEY_BLOCK (multi-line)
# =============================================================================

@test "redact: RSA private key block replaced with single sentinel line" {
    local input
    input="header
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEA...
some more bytes
-----END RSA PRIVATE KEY-----
footer"
    local out
    out=$(apr_lib_redact_prompt "$input")
    [[ "$out" == *"<<REDACTED:PRIVATE_KEY_BLOCK>>"* ]]
    [[ "$out" != *"MIIEogIBAAKCAQEA"* ]]
    [[ "$out" == *"header"* ]]
    [[ "$out" == *"footer"* ]]
}

@test "redact: OPENSSH/EC private key block also matched" {
    local input
    input="-----BEGIN OPENSSH PRIVATE KEY-----
secret payload
-----END OPENSSH PRIVATE KEY-----"
    local out
    out=$(apr_lib_redact_prompt "$input")
    [[ "$out" == *"<<REDACTED:PRIVATE_KEY_BLOCK>>"* ]]
    [[ "$out" != *"secret payload"* ]]
}

# =============================================================================
# Multi-secret + summary
# =============================================================================

@test "redact: multiple distinct secrets -> correct per-type counts" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input="OPENAI=sk-aabbccddeeff112233445566778899XYZABC
GH=ghp_aabbccddeeff112233445566778899AABB
SLK=xoxb-1234567890-abcdef
AWS=AKIAIOSFODNN7EXAMPLE
Authorization: Bearer secret-token-value rest"
    apr_lib_redact_prompt "$input" > /dev/null
    [ "$APR_REDACT_COUNT" = "5" ]
    local summary
    summary=$(apr_lib_redact_summary)
    python3 -c "
import json
d = json.loads('''$summary''')
assert d['total'] == 5, d
bt = d['by_type']
assert bt['OPENAI_KEY'] == 1
assert bt['GITHUB_TOKEN'] == 1
assert bt['SLACK_TOKEN'] == 1
assert bt['AKIA_KEY'] == 1
assert bt['AUTH_BEARER_TOKEN'] == 1
"
}

@test "redact: summary excludes zero-count types from by_type map" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_redact_prompt "key=sk-aabbccddeeff112233445566778899" > /dev/null
    local summary
    summary=$(apr_lib_redact_summary)
    python3 -c "
import json
d = json.loads('''$summary''')
assert d['total'] == 1
assert list(d['by_type'].keys()) == ['OPENAI_KEY']
"
}

# =============================================================================
# Determinism
# =============================================================================

@test "redact: byte-deterministic across calls" {
    local input
    input="alpha sk-aabbccddeeff112233445566778899XYZABC beta AKIAIOSFODNN7EXAMPLE gamma"
    local out1 out2
    out1=$(apr_lib_redact_prompt "$input")
    out2=$(apr_lib_redact_prompt "$input")
    [ "$out1" = "$out2" ]
}

# =============================================================================
# Counter reset
# =============================================================================

@test "redact: counters reset on each call" {
    apr_lib_redact_prompt "sk-aabbccddeeff112233445566778899XYZ" > /dev/null
    [ "$APR_REDACT_COUNT" = "1" ]
    apr_lib_redact_prompt "no secrets here" > /dev/null
    [ "$APR_REDACT_COUNT" = "0" ]
}

# =============================================================================
# Empty-after-redact JSON shape
# =============================================================================

@test "redact: summary on clean input -> total 0, empty by_type" {
    apr_lib_redact_prompt "clean docs" > /dev/null
    local summary
    summary=$(apr_lib_redact_summary)
    [ "$summary" = '{"total":0,"by_type":{}}' ]
}
