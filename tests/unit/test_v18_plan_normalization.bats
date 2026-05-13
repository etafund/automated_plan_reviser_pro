#!/usr/bin/env bats
# test_v18_plan_normalization.bats - Unit tests for v18 Plan IR Normalization Ladder

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/normalize-plan-ir.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Normalize ChatGPT provider result to minimal Plan IR" {
    run python3 "$SCRIPT_PATH" "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-result.chatgpt.json" --stage minimal --json
    assert_success
    assert_output --partial '"schema_version": "plan_artifact.v1"'
    assert_output --partial '"stage": "minimal_plan_ir"'
    assert_output --partial '"plan_id": "provider-result-demo-chatgpt_pro_first_plan-plan"'
}

@test "Normalize Gemini provider result to full Plan IR" {
    run python3 "$SCRIPT_PATH" "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-result.gemini.json" --stage full --json
    assert_failure
    assert_output --partial '"ok": false'
    assert_output --partial '"stage": "full_plan_ir"'
    assert_output --partial '"warning_id": "WARN-MOCKED-ENRICHMENT"'
    assert_output --partial '"error_code": "mocked_enrichment_not_export_ready"'
}

@test "Normalize Claude provider result refuses mocked bead_export_ready Plan IR" {
    run python3 "$SCRIPT_PATH" "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-result.claude.json" --stage export --json
    assert_failure
    assert_output --partial '"stage": "bead_export_ready"'
    assert_output --partial '"blocked_reason": "mocked_enrichment_not_export_ready"'
}

@test "Fixture-forced export emits non-empty bead_export_ready Plan IR" {
    run env APR_V18_FORCE_FIXTURES=1 python3 "$SCRIPT_PATH" "${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-result.claude.json" --stage export --json
    assert_success
    assert_output --partial '"stage": "bead_export_ready"'
    assert_output --partial '"warning_id": "WARN-FIXTURE-ENRICHMENT"'
    assert_output --partial '"plan_items": ['
}

@test "Malformed provider output yields warnings and fails safely" {
    local bad_fixture="$TEST_DIR/malformed.json"
    echo '{"provider_slot": "test_slot"}' > "$bad_fixture"
    run python3 "$SCRIPT_PATH" "$bad_fixture" --json
    assert_failure
    assert_output --partial '"warning_id": "WARN-NO-TEXT-SHA"'
    assert_output --partial '"error_code": "mocked_enrichment_not_export_ready"'
}

@test "Invalid JSON yields error code normalization_failed" {
    local bad_fixture="$TEST_DIR/invalid.json"
    echo 'not json' > "$bad_fixture"
    run python3 "$SCRIPT_PATH" "$bad_fixture" --json
    assert_failure
    assert_output --partial '"error_code": "normalization_failed"'
    assert_output --partial '"ok": false'
}
