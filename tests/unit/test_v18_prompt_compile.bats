#!/usr/bin/env bats
# test_v18_prompt_compile.bats - Unit tests for v18 Prompt Context Compilers

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/compile-prompt.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Compile ChatGPT Pro prompt" {
    run python3 "$SCRIPT_PATH" --route chatgpt_pro_first_plan --json
    assert_success
    assert_output --partial '"route": "chatgpt_pro_first_plan"'
    assert_output --partial "Use ChatGPT Pro / latest Pro model"
    assert_output --partial "sha256:"
}

@test "Compile Gemini Deep Think prompt" {
    run python3 "$SCRIPT_PATH" --route gemini_deep_think --json
    assert_success
    assert_output --partial '"route": "gemini_deep_think"'
    assert_output --partial "Select Deep Think"
    assert_output --partial "sha256:"
}

@test "Compile Claude Code prompt" {
    run python3 "$SCRIPT_PATH" --route claude_code_opus --json
    assert_success
    assert_output --partial '"route": "claude_code_opus"'
    assert_output --partial "Use Claude Opus 4.7"
}

@test "Compile Codex Intake prompt" {
    run python3 "$SCRIPT_PATH" --route codex_intake --json
    assert_success
    assert_output --partial '"route": "codex_intake"'
    assert_output --partial "Use Codex CLI with user subscription"
}

@test "Compile DeepSeek prompt" {
    run python3 "$SCRIPT_PATH" --route deepseek_v4_pro_reasoning_search --json
    assert_success
    assert_output --partial '"route": "deepseek_v4_pro_reasoning_search"'
    assert_output --partial "Set thinking.type=enabled and reasoning_effort=max"
}

@test "Compile xAI Grok prompt" {
    run python3 "$SCRIPT_PATH" --route xai_grok_reasoning --json
    assert_success
    assert_output --partial '"route": "xai_grok_reasoning"'
    assert_output --partial "Use grok-4.3 with reasoning_effort=high"
}

@test "Fail on unknown route" {
    run python3 "$SCRIPT_PATH" --route unknown_route --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial '"error_code": "compilation_failed"'
}

@test "Deterministic prompt hash given fixed inputs" {
    local baseline="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/source-baseline.json"
    local manifest="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/prompt-manifest.json"
    
    run python3 "$SCRIPT_PATH" --route chatgpt_pro_first_plan --baseline "$baseline" --manifest "$manifest" --json
    assert_success
    local first_hash=$(echo "$output" | jq -r '.data.prompt_hash')
    
    run python3 "$SCRIPT_PATH" --route chatgpt_pro_first_plan --baseline "$baseline" --manifest "$manifest" --json
    assert_success
    local second_hash=$(echo "$output" | jq -r '.data.prompt_hash')
    
    [[ "$first_hash" == "$second_hash" ]]
}
