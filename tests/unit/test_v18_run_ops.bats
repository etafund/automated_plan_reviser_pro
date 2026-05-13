#!/usr/bin/env bats
# test_v18_run_ops.bats - Unit tests for apr run status/report/resume/retry commands

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    mkdir -p .apr/workflows
    echo "default_workflow: default" > .apr/config.yaml
    echo "test" > README.md
    echo "test" > SPEC.md
    cat > .apr/workflows/default.yaml <<EOF
readme: README.md
spec: SPEC.md
implementation: apr
model: gpt-4
output_dir: rounds
EOF
    # Init a run dir
    run python3 "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/run-state-machine.py" --action init --run-dir .apr --json
    export RUN_DIR=$(echo "$output" | jq -r '.data.run_dir')
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr run status returns current run state" {
    run "${PROJECT_ROOT}/apr" run status --run-dir "$RUN_DIR" --json
    assert_success
    assert_output --partial '"last_action": "initialized"'
}

@test "apr run report generates a run report" {
    run "${PROJECT_ROOT}/apr" run report --run-dir "$RUN_DIR" --json
    assert_success
    assert_output --partial '"report_version": "v1"'
    [ -f "$RUN_DIR/reports/run_report.json" ]
}

@test "apr run resume suggests next steps" {
    run "${PROJECT_ROOT}/apr" run resume --run-dir "$RUN_DIR" --json
    assert_success
    assert_output --partial '"action": "resume"'
}

@test "apr run retry suggests rerunning" {
    run "${PROJECT_ROOT}/apr" run retry --run-dir "$RUN_DIR" --json
    assert_success
    assert_output --partial '"action": "retry"'
}

@test "apr run <number> still works (backward compatibility)" {
    # This might fail because it tries to call Oracle, so we just check usage or error
    run "${PROJECT_ROOT}/apr" run 1 --dry-run
    assert_success
    assert_output --partial "Round 1"
}
