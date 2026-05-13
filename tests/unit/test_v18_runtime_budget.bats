#!/usr/bin/env bats
# test_v18_runtime_budget.bats - Unit tests for v18 Runtime Budget and Progress

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/enforce-runtime-budget.py"
    chmod +x "$SCRIPT_PATH"
    export BUDGET_FILE="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/runtime-budget.json"
    export PROGRESS_FILE="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/run-progress.json"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Run within budget is allowed" {
    run python3 "$SCRIPT_PATH" --budget "$BUDGET_FILE" --progress "$PROGRESS_FILE" --elapsed-minutes 10 --total-cost-usd 1.5 --json
    assert_success
    assert_output --partial '"ok": true'
    assert_output --partial '"budget_ok": true'
}

@test "Run exceeding wall budget is blocked" {
    run python3 "$SCRIPT_PATH" --budget "$BUDGET_FILE" --progress "$PROGRESS_FILE" --elapsed-minutes 200 --total-cost-usd 1.5 --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"error_code": "budget_exceeded"'
    assert_output --partial 'Runtime exceeded wall budget'
}

@test "Run exceeding cost budget is blocked" {
    run python3 "$SCRIPT_PATH" --budget "$BUDGET_FILE" --progress "$PROGRESS_FILE" --elapsed-minutes 10 --total-cost-usd 60.0 --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'Runtime exceeded cost budget'
}

@test "Progress percent is calculated correctly" {
    run python3 "$SCRIPT_PATH" --budget "$BUDGET_FILE" --progress "$PROGRESS_FILE" --json
    assert_success
    # completed: brief_lint, source_baseline, route_plan (3)
    # total: 3 + oracle_remote_smoke, first_plan, independent_review, quorum, compare, synthesis, handoff (7) = 10
    # 3/10 = 30%
    assert_output --partial '"progress_percent": 30'
}

@test "Missing files result in error" {
    run python3 "$SCRIPT_PATH" --budget "non-existent" --progress "$PROGRESS_FILE" --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'Budget file not found'
}
