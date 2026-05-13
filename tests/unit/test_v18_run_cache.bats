#!/usr/bin/env bats
# test_v18_run_cache.bats - Unit tests for v18 Run Cache and Idempotency

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/manage-run-cache.py"
    chmod +x "$SCRIPT_PATH"
    export BASELINE_FILE="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/source-baseline.json"
    export MANIFEST_FILE="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/prompt-manifest.json"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Generate cache key from fixed inputs" {
    run python3 "$SCRIPT_PATH" --action get-key --baseline "$BASELINE_FILE" --manifest "$MANIFEST_FILE" --stage first_plan --profile balanced --json
    assert_success
    assert_output --partial '"cache_key": "cache-'
    
    local key1=$(echo "$output" | jq -r '.data.cache_key')
    
    run python3 "$SCRIPT_PATH" --action get-key --baseline "$BASELINE_FILE" --manifest "$MANIFEST_FILE" --stage first_plan --profile balanced --json
    assert_success
    local key2=$(echo "$output" | jq -r '.data.cache_key')
    
    [ "$key1" == "$key2" ]
}

@test "Cache miss when no results exist" {
    local run_dir="$TEST_DIR/run-miss"
    mkdir -p "$run_dir/provider_results"
    
    run python3 "$SCRIPT_PATH" --action check --run-dir "$run_dir" --stage first_plan --json
    assert_success
    assert_output --partial '"hit": false'
}

@test "Cache hit when result artifact exists" {
    local run_dir="$TEST_DIR/run-hit"
    mkdir -p "$run_dir/provider_results"
    echo '{"stage": "first_plan", "status": "success"}' > "$run_dir/provider_results/res.json"
    
    run python3 "$SCRIPT_PATH" --action check --run-dir "$run_dir" --stage first_plan --json
    assert_success
    assert_output --partial '"hit": true'
    assert_output --partial '"artifact":'
}

@test "Fails on missing required arguments" {
    run python3 "$SCRIPT_PATH" --action get-key --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"error_code": "cache_error"'
}
