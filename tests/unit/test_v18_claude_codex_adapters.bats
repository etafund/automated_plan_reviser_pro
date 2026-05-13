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
    local output_file="$TEST_DIR/claude-output.txt"
    APR_CLAUDE_INVOKE_CMD="python3 -c \"import sys; print('claude saw: '+sys.stdin.read().strip())\"" \
        run python3 "$SCRIPT_PATH" --provider claude --action invoke --prompt prompt.txt --output "$output_file" --json
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"provider_slot": "claude_code_opus"'
    [[ -f "$output_file" ]]
    grep -Fq 'claude saw: test prompt' "$output_file"
}

@test "Codex adapter: intake transcript" {
    run python3 "$SCRIPT_PATH" --provider codex --action intake --json
    assert_success
    assert_output --partial '"schema_version": "codex_intake.v1"'
    assert_output --partial '"formal_first_plan": false'
}

@test "Codex adapter: invoke reads prompt and calls configured CLI" {
    echo "codex prompt" > prompt.txt
    local output_file="$TEST_DIR/codex-output.txt"
    APR_CODEX_INVOKE_CMD="python3 -c \"import sys; print('codex saw: '+sys.stdin.read().strip())\"" \
        run python3 "$SCRIPT_PATH" --provider codex --action invoke --prompt prompt.txt --output "$output_file" --json
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"provider_slot": "codex_thinking_fast_draft"'
    [[ -f "$output_file" ]]
    grep -Fq 'codex saw: codex prompt' "$output_file"
}

@test "Fail on missing prompt for Claude invoke" {
    run python3 "$SCRIPT_PATH" --provider claude --action invoke --json
    assert_failure
    assert_output --partial '"ok": false'
    assert_output --partial 'adapter_failed'
}
