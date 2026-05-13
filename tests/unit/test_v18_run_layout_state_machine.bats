#!/usr/bin/env bats
# test_v18_run_layout_state_machine.bats - Unit tests for v18 Run State Machine and Layout

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/run-state-machine.py"
    chmod +x "$SCRIPT_PATH"
    export TEST_APR_DIR="$TEST_DIR/.apr"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Initialize a run creates correct directory layout and initial event" {
    run python3 "$SCRIPT_PATH" --action init --run-dir "$TEST_APR_DIR" --json
    assert_success
    assert_output --partial '"run_id":'
    assert_output --partial '"run_dir":'
    
    local run_dir=$(echo "$output" | jq -r '.data.run_dir')
    
    # Check layout
    [ -d "$run_dir/inputs" ]
    [ -d "$run_dir/provider_requests" ]
    [ -d "$run_dir/provider_results" ]
    [ -d "$run_dir/evidence" ]
    [ -d "$run_dir/normalized_plans" ]
    [ -d "$run_dir/comparison" ]
    [ -d "$run_dir/synthesis" ]
    [ -d "$run_dir/traceability" ]
    [ -d "$run_dir/reports" ]
    [ -d "$run_dir/logs" ]
    
    # Check events
    [ -f "$run_dir/events.jsonl" ]
    grep -q "run_lifecycle" "$run_dir/events.jsonl"
}

@test "Append an event and read status" {
    # Init run
    run python3 "$SCRIPT_PATH" --action init --run-dir "$TEST_APR_DIR" --json
    local run_dir=$(echo "$output" | jq -r '.data.run_dir')
    
    # Append event
    run python3 "$SCRIPT_PATH" --action event --run-dir "$run_dir" --stage first_plan --event-action start --outcome running --json
    assert_success
    
    # Read status
    run python3 "$SCRIPT_PATH" --action status --run-dir "$run_dir" --json
    assert_success
    assert_output --partial '"first_plan": {'
    assert_output --partial '"outcome": "running"'
}

@test "Fail on invalid outcome stage" {
    run python3 "$SCRIPT_PATH" --action init --run-dir "$TEST_APR_DIR" --json
    local run_dir=$(echo "$output" | jq -r '.data.run_dir')
    
    run python3 "$SCRIPT_PATH" --action event --run-dir "$run_dir" --stage first_plan --event-action start --outcome invalid_outcome --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"error_code": "state_machine_error"'
}

@test "Crash simulation - trailing incomplete JSON line does not corrupt status reading" {
    run python3 "$SCRIPT_PATH" --action init --run-dir "$TEST_APR_DIR" --json
    local run_dir=$(echo "$output" | jq -r '.data.run_dir')
    
    run python3 "$SCRIPT_PATH" --action event --run-dir "$run_dir" --stage first_plan --event-action start --outcome running --json
    
    # Corrupt last line
    echo '{"schema_version": "run_event.v1", "timestamp": "2026-05-12T00:00:00Z"' >> "$run_dir/events.jsonl"
    
    run python3 "$SCRIPT_PATH" --action status --run-dir "$run_dir" --json
    assert_success
    assert_output --partial '"first_plan": {'
    assert_output --partial '"outcome": "running"'
}
