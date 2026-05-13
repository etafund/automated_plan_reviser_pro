#!/usr/bin/env bats
# test_v18_prompt_cli.bats - Unit tests for apr prompts CLI commands

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr prompts compile shows compiled prompt info" {
    run "${PROJECT_ROOT}/apr" prompts compile --route chatgpt_pro_first_plan --json
    assert_success
    assert_output --partial '"route": "chatgpt_pro_first_plan"'
    assert_output --partial '"prompt_hash":'
}

@test "apr prompts lint validates baseline and trust" {
    local baseline="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/source-baseline.json"
    run "${PROJECT_ROOT}/apr" prompts lint --baseline "$baseline" --json
    assert_success
    assert_output --partial '"checked": ['
    assert_output --partial '"baseline"'
}

@test "apr help shows prompts command" {
    mkdir -p .apr
    run "${PROJECT_ROOT}/apr" help
    assert_success
    assert_output --partial "prompts <cmd>"
    rm -rf .apr
}
