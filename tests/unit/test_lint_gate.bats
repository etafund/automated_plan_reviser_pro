#!/usr/bin/env bats
# test_lint_gate.bats - Tests for bd-35i: lint gates apr run + apr robot run
#
# Validates the gate behavior that prevents apr from invoking Oracle on
# obviously broken workflows. Combines bd-9fl's lint plumbing with the
# bd-30c/bd-2lc validator primitives:
#   - Fatal lint errors block the run, surface remediation, and emit a
#     non-zero exit code aligned with the bd-3tj taxonomy.
#   - Warnings pass by default but block in strict mode
#     (APR_FAIL_ON_WARN=1 or --fail-on-warn).
#   - --no-lint is the explicit, noisy bypass.
#
# Tests target the internal functions (run_lint_gate, robot_lint_gate,
# lint_collect_findings, lint_result_code) so they remain decoupled from
# Oracle availability.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # Real lib dir so apr_lib_validate_* / apr_lib_manifest_* load.
    export APR_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    load_apr_functions
    setup_test_workflow
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# run_lint_gate: happy path
# =============================================================================

@test "run_lint_gate: clean workflow returns 0 with no findings" {
    cd "$TEST_PROJECT" || return 1
    run_lint_gate "1" "default" "false"
    [ "$?" -eq 0 ]
}

# =============================================================================
# run_lint_gate: blocks on fatal config errors
# =============================================================================

@test "run_lint_gate: missing readme path -> non-zero exit with config_error" {
    cd "$TEST_PROJECT" || return 1
    # Corrupt the workflow yaml: blank out the readme path.
    sed -i 's|readme: README.md|readme: ""|' ".apr/workflows/default.yaml"
    local rc=0
    run_lint_gate "1" "default" "false" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "run_lint_gate: nonexistent workflow blocks with non-zero exit" {
    cd "$TEST_PROJECT" || return 1
    local rc=0
    run_lint_gate "1" "no-such-workflow" "false" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "run_lint_gate: missing required doc file blocks" {
    cd "$TEST_PROJECT" || return 1
    rm -f README.md
    local rc=0
    run_lint_gate "1" "default" "false" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

# =============================================================================
# Warnings pass by default
# =============================================================================

@test "run_lint_gate: prior round missing emits warning, does NOT block" {
    cd "$TEST_PROJECT" || return 1
    # Round 2 with no round_1 output -> warning but gate passes.
    run_lint_gate "2" "default" "false"
    [ "$?" -eq 0 ]
}

# =============================================================================
# Strict mode (APR_FAIL_ON_WARN=1): warnings promote to fatal
# =============================================================================

@test "run_lint_gate: strict mode (APR_FAIL_ON_WARN=1) blocks when warnings exist" {
    cd "$TEST_PROJECT" || return 1
    # Round 2 missing round_1 generates a warning; strict mode should fail.
    local rc=0
    APR_FAIL_ON_WARN=1 run_lint_gate "2" "default" "false" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}

@test "run_lint_gate: strict mode does NOT block when only no findings at all" {
    cd "$TEST_PROJECT" || return 1
    # Round 1 with full workflow -> no warnings, no errors -> passes even strict.
    local rc=0
    APR_FAIL_ON_WARN=1 run_lint_gate "1" "default" "false" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
}

# =============================================================================
# robot_lint_gate: returns structured failure on errors
# =============================================================================

@test "robot_lint_gate: clean workflow returns 0 (no output)" {
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    robot_lint_gate "1" "default" "false"
    [ "$?" -eq 0 ]
}

@test "robot_lint_gate: missing readme emits robot JSON failure" {
    cd "$TEST_PROJECT" || return 1
    sed -i 's|readme: README.md|readme: ""|' ".apr/workflows/default.yaml"
    ROBOT_COMPACT=true
    local out rc=0
    out=$(robot_lint_gate "1" "default" "false") || rc=$?
    [ "$rc" -ne 0 ]
    # Output should be a JSON envelope with ok:false.
    [[ "$out" == *'"ok":false'* ]]
}

# =============================================================================
# lint_collect_findings: strict-mode finalization runs at end
# =============================================================================

@test "lint_collect_findings: strict mode promotes warnings to errors" {
    cd "$TEST_PROJECT" || return 1
    APR_FAIL_ON_WARN=1 lint_collect_findings "2" "default" "false"
    # In strict mode, warnings copy into errors bucket so has_errors fires.
    apr_lib_validate_has_errors && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "lint_collect_findings: non-strict keeps warnings out of errors bucket" {
    cd "$TEST_PROJECT" || return 1
    lint_collect_findings "2" "default" "false"
    # has_warnings (count > 0) but no errors.
    [ "$(apr_lib_validate_warning_count)" -gt 0 ]
    apr_lib_validate_has_errors && status=0 || status=$?
    [ "$status" -ne 0 ]
}
