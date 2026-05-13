#!/usr/bin/env bats
# test_secret_scan.bats - Tests for bd-1eq apr_lib_validate_secret_scan
#
# Detection-only counterpart to bd-3ut's redaction layer. Records one
# `secret_detected` warning per match (with line number + redacted
# snippet + class) so operators get a clear pre-run signal.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/validate.sh"
    apr_lib_validate_init
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Pass-through (no matches)
# =============================================================================

@test "secret_scan: plain text -> no findings" {
    apr_lib_validate_secret_scan "Normal docs text. No tokens here."
    [ "$(apr_lib_validate_warning_count)" = "0" ]
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "secret_scan: empty input -> no findings" {
    apr_lib_validate_secret_scan ""
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

# =============================================================================
# Pattern classes
# =============================================================================

@test "secret_scan: OpenAI sk- key detected with class=OPENAI_KEY" {
    apr_lib_validate_secret_scan "key=sk-aabbccddeeff112233445566778899XYZABC in line"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [ "${_APR_VALIDATE_WARN_CODE[0]}" = "secret_detected" ]
    [[ "${_APR_VALIDATE_WARN_MSG[0]}" == *"OPENAI_KEY"* ]]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"OPENAI_KEY"'* ]]
}

@test "secret_scan: GitHub ghp_ token detected" {
    apr_lib_validate_secret_scan "PAT: ghp_aabbccddeeff1122334455667788990011AABB"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"GITHUB_TOKEN"'* ]]
}

@test "secret_scan: github_pat_ fine-grained token detected" {
    apr_lib_validate_secret_scan "x=github_pat_AABBCCDDEEFF11223344556677889900"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"GITHUB_FINEGRAINED"'* ]]
}

@test "secret_scan: Slack xoxb- token detected" {
    apr_lib_validate_secret_scan "slack=xoxb-1234567890-abcdef"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"SLACK_TOKEN"'* ]]
}

@test "secret_scan: AWS AKIA key detected" {
    apr_lib_validate_secret_scan "AWS_KEY=AKIAIOSFODNN7EXAMPLE here"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"AKIA_KEY"'* ]]
}

@test "secret_scan: Authorization Bearer header detected" {
    apr_lib_validate_secret_scan "Authorization: Bearer abc123tok-value rest"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"AUTH_BEARER_TOKEN"'* ]]
}

@test "secret_scan: PRIVATE KEY block detected" {
    local input
    input=$'header\n-----BEGIN RSA PRIVATE KEY-----\nMII...payload\n-----END RSA PRIVATE KEY-----\nfooter'
    apr_lib_validate_secret_scan "$input"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"class":"PRIVATE_KEY_BLOCK"'* ]]
}

# =============================================================================
# False-positive guards
# =============================================================================

@test "secret_scan: 'sk-' too short -> NOT flagged" {
    apr_lib_validate_secret_scan "see sk-ab"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "secret_scan: AKIA fewer chars -> NOT flagged" {
    apr_lib_validate_secret_scan "AKIA123"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

# =============================================================================
# Line numbering + redacted snippet
# =============================================================================

@test "secret_scan: hit on line N reports line=N" {
    local input
    input=$'line one\nline two\nkey=sk-aabbccddeeff112233445566778899XYZABC\nline four'
    apr_lib_validate_secret_scan "$input" "spec.md"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *'"line":3'* ]]
    [ "${_APR_VALIDATE_WARN_SOURCE[0]}" = "spec.md:3" ]
}

@test "secret_scan: redacted snippet substitutes the secret with sentinel" {
    apr_lib_validate_secret_scan "key=sk-aabbccddeeff112233445566778899XYZABC use it"
    local details="${_APR_VALIDATE_WARN_DETAILS[0]}"
    [[ "$details" == *"<<OPENAI_KEY>>"* ]]
    [[ "$details" != *"aabbccddeeff112233"* ]]
}

# =============================================================================
# Code-fence awareness
# =============================================================================

@test "secret_scan: secret inside code fence is IGNORED by default" {
    local input
    input=$'doc text\n```\nkey=sk-aabbccddeeff112233445566778899XYZABC\n```\nmore'
    apr_lib_validate_secret_scan "$input"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "secret_scan: APR_QC_RESPECT_CODE_FENCES=0 flags fenced secret" {
    local input
    input=$'```\nkey=sk-aabbccddeeff112233445566778899XYZABC\n```'
    APR_QC_RESPECT_CODE_FENCES=0 apr_lib_validate_secret_scan "$input"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
}

@test "secret_scan: strict mode disables fence leniency automatically" {
    local input
    input=$'```\nkey=sk-aabbccddeeff112233445566778899XYZABC\n```'
    APR_FAIL_ON_WARN=1 apr_lib_validate_secret_scan "$input"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
}

# =============================================================================
# Strict mode promotion
# =============================================================================

@test "secret_scan: strict mode promotes warning to error via finalize_strict" {
    APR_FAIL_ON_WARN=1 apr_lib_validate_secret_scan \
        "key=sk-aabbccddeeff112233445566778899XYZABC"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [[ "${_APR_VALIDATE_ERR_CODE[0]}" = "secret_detected" ]]
}

# =============================================================================
# Multi-class scan
# =============================================================================

@test "secret_scan: three distinct secret classes -> three findings" {
    local input
    input=$'OAI=sk-aabbccddeeff112233445566778899\nGH=ghp_aabbccddeeff1122334455667788XX\nAWS=AKIAIOSFODNN7EXAMPLE'
    apr_lib_validate_secret_scan "$input"
    [ "$(apr_lib_validate_warning_count)" = "3" ]
}

@test "secret_scan: details JSON is well-formed" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_validate_secret_scan "k=sk-aabbccddeeff112233445566778899XYZABC"
    local details="${_APR_VALIDATE_WARN_DETAILS[0]}"
    python3 -c "
import json
d = json.loads('''$details''')
assert d['class'] == 'OPENAI_KEY'
assert d['line'] == 1
assert '<<OPENAI_KEY>>' in d['redacted_snippet']
"
}

# =============================================================================
# source_prefix arg
# =============================================================================

@test "secret_scan: source_prefix arg appends :line_no" {
    apr_lib_validate_secret_scan "key=sk-aabbccddeeff112233445566778899XYZ" "prompt" "/path/to/spec.md"
    [ "${_APR_VALIDATE_WARN_SOURCE[0]}" = "/path/to/spec.md:1" ]
}

# =============================================================================
# Hint string mentions actionable remediations
# =============================================================================

@test "secret_scan: hint string mentions env var + redaction mode" {
    apr_lib_validate_secret_scan "key=sk-aabbccddeeff112233445566778899XYZABC"
    [[ "${_APR_VALIDATE_WARN_HINT[0]}" == *"env var"* ]]
    [[ "${_APR_VALIDATE_WARN_HINT[0]}" == *"APR_REDACT=1"* ]]
    [[ "${_APR_VALIDATE_WARN_HINT[0]}" == *"APR_FAIL_ON_WARN=1"* ]]
}
