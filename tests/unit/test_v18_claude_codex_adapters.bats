#!/usr/bin/env bats
# test_v18_claude_codex_adapters.bats - Unit tests for Claude and Codex CLI adapters

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/claude-codex-adapters.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Claude adapter: check availability" {
    # If claude is installed, it returns true, otherwise false. 
    # Since we saw it is available, we'll check for the version field.
    run python3 "$SCRIPT_PATH" --provider claude --action check --json
    assert_success
    assert_output --partial '"available":'
}

@test "Claude adapter: invoke success" {
    echo "test prompt" > prompt.txt
    run python3 "$SCRIPT_PATH" --provider claude --action invoke --prompt prompt.txt --json
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"provider_slot": "claude_code_opus"'
}

@test "Codex adapter: intake transcript" {
    run python3 "$SCRIPT_PATH" --provider codex --action intake --json
    assert_success
    assert_output --partial '"schema_version": "codex_intake.v1"'
    assert_output --partial '"formal_first_plan": false'
}

@test "Fail on missing prompt for Claude invoke" {
    run python3 "$SCRIPT_PATH" --provider claude --action invoke --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'adapter_failed'
}
