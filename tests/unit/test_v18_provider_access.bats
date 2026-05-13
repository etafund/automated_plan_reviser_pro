#!/usr/bin/env bats
# test_v18_provider_access.bats - Unit tests for v18 Provider Access Policy Enforcement

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/enforce-access-policy.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Allow oracle_browser_remote for chatgpt_pro_first_plan" {
    run python3 "$SCRIPT_PATH" --route chatgpt_pro_first_plan --access-path oracle_browser_remote --json
    assert_success
    assert_output --partial '"decision": "ALLOWED"'
}

@test "Prohibit openai_api for chatgpt_pro_first_plan" {
    run python3 "$SCRIPT_PATH" --route chatgpt_pro_first_plan --access-path openai_api --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"blocked_reason": "provider_access_prohibited"'
}

@test "Allow codex_cli_subscription for codex_intake without formal_first_plan" {
    run python3 "$SCRIPT_PATH" --route codex_intake --access-path codex_cli_subscription --json
    assert_success
    assert_output --partial '"decision": "ALLOWED"'
}

@test "Prohibit codex_cli_subscription for codex_intake if formal_first_plan is requested" {
    run python3 "$SCRIPT_PATH" --route codex_intake --access-path codex_cli_subscription --formal-first-plan --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"error_code": "policy_violation"'
}

@test "Allow deepseek_official_api for deepseek_v4_pro_reasoning_search" {
    run python3 "$SCRIPT_PATH" --route deepseek_v4_pro_reasoning_search --access-path deepseek_official_api --json
    assert_success
    assert_output --partial '"decision": "ALLOWED"'
}

@test "Prohibit missing routes" {
    run python3 "$SCRIPT_PATH" --route non_existent_route --access-path oracle_browser_remote --json
    assert_success
    assert_output --partial '"ok": false'
}
