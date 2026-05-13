#!/usr/bin/env bats
# test_size.bats - Tests for lib/size.sh (bd-rvq)
#
# Validates the prompt-size estimation primitives:
#   - apr_lib_size_total
#   - apr_lib_size_breakdown
#   - apr_lib_size_check_budget
#   - apr_lib_size_policy_resolve

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/size.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# apr_lib_size_total
# =============================================================================

@test "size_total: empty input -> 0" {
    run apr_lib_size_total ""
    assert_success
    assert_output "0"
}

@test "size_total: ascii content -> byte count" {
    run apr_lib_size_total "hello world"
    assert_success
    assert_output "11"
}

@test "size_total: multi-line counts newlines" {
    local input
    input=$'line1\nline2\nline3'
    run apr_lib_size_total "$input"
    assert_success
    # 5 + 1 + 5 + 1 + 5 = 17
    assert_output "17"
}

@test "size_total: deterministic" {
    local out1 out2
    out1=$(apr_lib_size_total "sample text payload")
    out2=$(apr_lib_size_total "sample text payload")
    [ "$out1" = "$out2" ]
}

# =============================================================================
# apr_lib_size_breakdown
# =============================================================================

@test "size_breakdown: empty everything -> zeros + empty files[]" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_size_breakdown "" "")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['total_bytes'] == 0
assert d['manifest_bytes'] == 0
assert d['template_bytes'] == 0
assert d['files_total_bytes'] == 0
assert d['files'] == []
"
}

@test "size_breakdown: manifest+template only -> sum + empty files[]" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_size_breakdown "MANIFEST" "TEMPLATE_BODY")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['manifest_bytes'] == 8
assert d['template_bytes'] == 13
assert d['total_bytes'] == 21
assert d['files'] == []
"
}

@test "size_breakdown: includes per-file entries with bytes" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    printf '12345'      > "$BATS_TEST_TMPDIR/a.md"   # 5 bytes
    printf '12345678'   > "$BATS_TEST_TMPDIR/b.md"   # 8 bytes
    local out
    out=$(apr_lib_size_breakdown "M" "T" "$BATS_TEST_TMPDIR/a.md" "$BATS_TEST_TMPDIR/b.md")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['manifest_bytes'] == 1
assert d['template_bytes'] == 1
assert d['total_bytes'] == 2
assert d['files_total_bytes'] == 13
assert len(d['files']) == 2
assert {f['basename']: f['bytes'] for f in d['files']} == {'a.md': 5, 'b.md': 8}
"
}

@test "size_breakdown: missing file -> bytes 0, no error" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_size_breakdown "M" "T" "$BATS_TEST_TMPDIR/no-such.md")
    python3 -c "
import json
d = json.loads('''$out''')
assert len(d['files']) == 1
assert d['files'][0]['bytes'] == 0
assert d['files_total_bytes'] == 0
"
}

@test "size_breakdown: files[] sorted stably by path" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    printf 'x' > "$BATS_TEST_TMPDIR/Z.md"
    printf 'x' > "$BATS_TEST_TMPDIR/A.md"
    printf 'x' > "$BATS_TEST_TMPDIR/M.md"
    # Pass in non-sorted order.
    local out
    out=$(apr_lib_size_breakdown "" "" \
        "$BATS_TEST_TMPDIR/Z.md" "$BATS_TEST_TMPDIR/A.md" "$BATS_TEST_TMPDIR/M.md")
    python3 -c "
import json
d = json.loads('''$out''')
basenames = [f['basename'] for f in d['files']]
assert basenames == ['A.md', 'M.md', 'Z.md'], basenames
"
}

@test "size_breakdown: deterministic across calls" {
    printf 'data' > "$BATS_TEST_TMPDIR/a.md"
    local out1 out2
    out1=$(apr_lib_size_breakdown "M" "T" "$BATS_TEST_TMPDIR/a.md")
    out2=$(apr_lib_size_breakdown "M" "T" "$BATS_TEST_TMPDIR/a.md")
    [ "$out1" = "$out2" ]
}

@test "size_breakdown: well-formed JSON (round-trips)" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_size_breakdown "M\"with quotes\"" "T")
    python3 -c "import json; json.loads('''$out''')"
}

# =============================================================================
# apr_lib_size_check_budget
# =============================================================================

@test "check_budget: bytes under budget -> rc=0" {
    apr_lib_size_check_budget 100 1000 && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "check_budget: bytes equal budget -> rc=0 (boundary)" {
    apr_lib_size_check_budget 1000 1000 && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "check_budget: bytes over budget -> rc=1" {
    apr_lib_size_check_budget 2000 1000 && status=0 || status=$?
    [ "$status" -eq 1 ]
}

@test "check_budget: budget=0 disables -> always rc=0" {
    apr_lib_size_check_budget 999999 0 && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "check_budget: env override (APR_MAX_PROMPT_BYTES) honored when no arg" {
    APR_MAX_PROMPT_BYTES=50 apr_lib_size_check_budget 100 && status=0 || status=$?
    [ "$status" -eq 1 ]
}

@test "check_budget: explicit arg overrides env" {
    APR_MAX_PROMPT_BYTES=50 apr_lib_size_check_budget 100 1000 && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "check_budget: non-numeric bytes -> rc=0 (no false positive)" {
    apr_lib_size_check_budget "not-a-number" 1000 && status=0 || status=$?
    [ "$status" -eq 0 ]
}

# =============================================================================
# apr_lib_size_policy_resolve
# =============================================================================

@test "policy_resolve: under warn -> ok" {
    run apr_lib_size_policy_resolve 100 1000 500
    assert_success
    assert_output "ok"
}

@test "policy_resolve: between warn and budget -> warn" {
    run apr_lib_size_policy_resolve 600 1000 500
    assert_success
    assert_output "warn"
}

@test "policy_resolve: over budget -> over_budget" {
    run apr_lib_size_policy_resolve 2000 1000 500
    assert_success
    assert_output "over_budget"
}

@test "policy_resolve: budget=0 disables over_budget classification" {
    run apr_lib_size_policy_resolve 999999 0 500
    assert_success
    # warn fires because 999999 > 500.
    assert_output "warn"
}

@test "policy_resolve: warn=0 disables warn classification" {
    run apr_lib_size_policy_resolve 600 1000 0
    assert_success
    assert_output "ok"
}

@test "policy_resolve: defaults pulled from env vars" {
    APR_MAX_PROMPT_BYTES=200 APR_PROMPT_WARN_BYTES=100 \
        run apr_lib_size_policy_resolve 150
    assert_success
    assert_output "warn"
}

@test "policy_resolve: non-numeric bytes -> ok" {
    run apr_lib_size_policy_resolve "garbage" 100 50
    assert_success
    assert_output "ok"
}
