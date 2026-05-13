#!/usr/bin/env bats
# test_v18_stage_readiness.bats - Unit tests for v18 Stage Readiness Engine

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/enforce-stage-readiness.py"
    chmod +x "$SCRIPT_PATH"
    export READINESS="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/route-readiness.balanced.json"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Preflight is ready" {
    run python3 "$SCRIPT_PATH" --readiness "$READINESS" --stage preflight --json
    assert_success
    assert_output --partial '"ready": true'
}

@test "Synthesis is not ready from preflight scope" {
    run python3 "$SCRIPT_PATH" --readiness "$READINESS" --stage synthesis --json
    assert_failure
    assert_output --partial '"ok": false'
    assert_output --partial '"ready": false'
    assert_output --partial 'Scope is preflight-only'
}

@test "first_plan_prompt_submission is ready" {
    run python3 "$SCRIPT_PATH" --readiness "$READINESS" --stage first_plan_prompt_submission --json
    assert_success
    assert_output --partial '"ready": true'
}

@test "synthesis_prompt_submission is not ready and blocked" {
    run python3 "$SCRIPT_PATH" --readiness "$READINESS" --stage synthesis_prompt_submission --json
    assert_failure
    assert_output --partial '"ok": false'
    assert_output --partial '"ready": false'
    assert_output --partial '"error_code": "stage_not_ready"'
    assert_output --partial 'normalized_provider_results'
}

@test "Circular synthesis is rejected" {
    local bad_readiness="$TEST_DIR/bad_readiness.json"
    cat > "$bad_readiness" << 'EOF'
{
    "stage_readiness": {
        "synthesis_prompt_submission": {
            "ready": false
        }
    },
    "synthesis_prompt_blocked_until_evidence_for": [
        "chatgpt_pro_synthesis"
    ]
}
EOF

    run python3 "$SCRIPT_PATH" --readiness "$bad_readiness" --stage synthesis_prompt_submission --json
    assert_failure
    assert_output --partial '"ok": false'
    assert_output --partial '"ready": false'
    assert_output --partial 'Circular synthesis condition detected'
}
