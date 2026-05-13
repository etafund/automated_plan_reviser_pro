#!/usr/bin/env bats
# test_v18_xai_deepseek_adapters.bats - Unit tests for xAI and DeepSeek API adapters

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/xai-deepseek-adapters.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "xAI adapter: check fail (missing key)" {
    unset XAI_API_KEY
    run python3 "$SCRIPT_PATH" --provider xai --action check --json
    assert_success
    assert_output --partial '"available": false'
    assert_output --partial '"api_key_status": "missing"'
}

@test "xAI adapter: check success" {
    export XAI_API_KEY="sk-test"
    run python3 "$SCRIPT_PATH" --provider xai --action check --json
    assert_success
    assert_output --partial '"available": true'
}

@test "xAI adapter: invoke success" {
    export XAI_API_KEY="sk-test"
    echo "test prompt" > prompt.txt
    run python3 "$SCRIPT_PATH" --provider xai --action invoke --prompt prompt.txt --json
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"model": "grok-4.3"'
}

@test "DeepSeek adapter: check success" {
    export DEEPSEEK_API_KEY="sk-test"
    run python3 "$SCRIPT_PATH" --provider deepseek --action check --json
    assert_success
    assert_output --partial '"available": true'
}

@test "DeepSeek adapter: invoke success" {
    export DEEPSEEK_API_KEY="sk-test"
    echo "test prompt" > prompt.txt
    run python3 "$SCRIPT_PATH" --provider deepseek --action invoke --prompt prompt.txt --json
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"model": "deepseek-v4-pro"'
    assert_output --partial '"thinking_enabled": true'
}
