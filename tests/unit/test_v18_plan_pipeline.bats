#!/usr/bin/env bats
# test_v18_plan_pipeline.bats - Unit tests for apr plan pipeline commands

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr plan fanout returns success" {
    run "${PROJECT_ROOT}/apr" plan fanout --json
    assert_success
    assert_output --partial '"stage": "fanout"'
}

@test "apr plan normalize returns success" {
    run "${PROJECT_ROOT}/apr" plan normalize --json
    assert_success
    assert_output --partial '"stage": "normalize"'
}

@test "apr plan compare returns success" {
    run "${PROJECT_ROOT}/apr" plan compare --json
    assert_success
    assert_output --partial '"stage": "compare"'
    assert_output --partial '"comparison_artifact"'
}

@test "apr plan synthesize returns success" {
    run "${PROJECT_ROOT}/apr" plan synthesize --json
    assert_success
    assert_output --partial '"stage": "synthesize"'
    assert_output --partial '"synthesis_artifact"'
}

@test "apr plan compare is not canned 5/1 output" {
    run "${PROJECT_ROOT}/apr" plan compare --json
    assert_success
    refute_output --partial '"agreements": 5'
    refute_output --partial '"contradictions": 1'
}

@test "apr plan export-beads still works" {
    local plan="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/plan-artifact.json"
    run "${PROJECT_ROOT}/apr" plan export-beads --plan "$plan" --dry-run --json
    assert_success
    assert_output --partial '"status": "proposed"'
}
