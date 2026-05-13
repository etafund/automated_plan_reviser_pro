#!/usr/bin/env bats
# test_v18_oracle_browser_integration.bats - Unit tests for Oracle browser route integration

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/oracle-browser-integration.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Acquire browser lease" {
    run python3 "$SCRIPT_PATH" --action acquire-lease --route chatgpt_pro_first_plan --json
    assert_success
    assert_output --partial '"status": "acquired"'
    assert_output --partial '"lease_id":'
}

@test "Verify evidence success" {
    local evidence="$TEST_DIR/evidence.json"
    echo '{"evidence_id": "test-ev", "mode_verified": true, "verified_before_prompt_submit": true}' > "$evidence"
    run python3 "$SCRIPT_PATH" --action verify-evidence --evidence "$evidence" --json
    assert_success
    assert_output --partial '"verified": true'
    assert_output --partial '"confidence": "high"'
}

@test "Verify evidence fail (missing mode)" {
    local evidence="$TEST_DIR/evidence.json"
    echo '{"evidence_id": "test-ev", "mode_verified": false, "verified_before_prompt_submit": true}' > "$evidence"
    run python3 "$SCRIPT_PATH" --action verify-evidence --evidence "$evidence" --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'verification failed'
}

@test "Record result" {
    run python3 "$SCRIPT_PATH" --action record-result --json
    assert_success
    assert_output --partial '"recorded": true'
}
