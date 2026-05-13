#!/usr/bin/env bats
# test_v18_replay_eval.bats - Unit tests for v18 Replay and Evaluation Harness

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/v18-replay-eval.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Replay from provider result fixture" {
    local fixture="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-result.chatgpt.json"
    run python3 "$SCRIPT_PATH" --input "$fixture" --json
    assert_success
    assert_output --partial '"stage": "normalization"'
    assert_output --partial '"stage": "eval"'
}

@test "Replay from run directory" {
    # Initialize a mock run directory using state machine script
    local run_dir="$TEST_DIR/run-demo"
    python3 "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/run-state-machine.py" --action init --run-dir "$TEST_DIR"
    
    # run-state-machine.py init prints data to stdout, we need to extract it or just point to the directory
    # the init command creates $TEST_DIR/runs/planning/<run_id>
    local actual_run_dir=$(ls -d "$TEST_DIR/runs/planning/run-"*)
    
    run python3 "$SCRIPT_PATH" --input "$actual_run_dir" --json
    assert_success
    assert_output --partial '"stage": "state_reconstruction"'
}

@test "Fail on missing input" {
    run python3 "$SCRIPT_PATH" --input "non-existent" --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'replay_failed'
}
