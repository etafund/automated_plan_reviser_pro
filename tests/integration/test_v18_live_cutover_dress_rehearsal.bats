#!/usr/bin/env bats
# Pins the opt-in v18 live cutover dress rehearsal contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/live-cutover-dress-rehearsal.py"
    LIVE_LOG_ROOT="$TEST_DIR/v18-live-logs"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "live cutover dress rehearsal script not present at $SCRIPT"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

run_dress_rehearsal() {
    run_with_artifacts python3 "$SCRIPT" --json --log-root "$LIVE_LOG_ROOT" "$@"
}

@test "v18 live cutover: dry run with approval emits passing non-live envelope" {
    run_dress_rehearsal --approval-id APR-LIVE-TEST-001
    [[ "$status" -eq 0 ]] || {
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_execution == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_mock_discriminator == "DRY_RUN_NOT_LIVE"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.approval.approval_id == "APR-LIVE-TEST-001"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.checklist.minimum_release_gate == "phase_5_balanced_live_dress_rehearsal"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.artifact_index.redaction_boundary_ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.browser.evidence[] | .stores_sensitive_material == false] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.environment.tokens.ORACLE_REMOTE_TOKEN.value == null' "$ARTIFACT_DIR/stdout.log" >/dev/null

    local log_bundle
    log_bundle=$(jq -r '.data.log_bundle' "$ARTIFACT_DIR/stdout.log")
    [[ -f "$log_bundle/rehearsal-report.json" ]]
    [[ -f "$log_bundle/environment.redacted.json" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "v18 live cutover: missing approval blocks before live route readiness" {
    run_dress_rehearsal
    [[ "$status" -ne 0 ]]

    jq -e '.ok == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.errors | map(.error_code) | index("live_cutover_approval_missing")) != null' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_execution == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_mock_discriminator == "DRY_RUN_NOT_LIVE"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "v18 live cutover: execute-live requires explicit environment and does not call smoke when blocked" {
    unset APR_V18_LIVE_CUTOVER
    unset ORACLE_REMOTE_HOST
    unset ORACLE_REMOTE_POOL
    unset ORACLE_REMOTE_TOKEN
    unset ORACLE_REMOTE_TOKENS

    run_dress_rehearsal --approval-id APR-LIVE-TEST-002 --execute-live
    [[ "$status" -ne 0 ]]

    jq -e '.ok == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_execution == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_mock_discriminator == "LIVE_EXECUTION_REQUESTED"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.errors | map(.error_code) | index("live_cutover_env_not_set")) != null' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.errors | map(.error_code) | index("live_cutover_remote_not_configured")) != null' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_smoke.attempted == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.live_smoke.blocked_before_provider_call == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "v18 live cutover: success is stdout-only JSON and never persists token values" {
    ORACLE_REMOTE_HOST=remote.example:9333 \
    ORACLE_REMOTE_TOKEN=super-secret-token \
        run_dress_rehearsal --approval-id APR-LIVE-TEST-003
    [[ "$status" -eq 0 ]]

    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    ! grep -Fq 'super-secret-token' "$ARTIFACT_DIR/stdout.log"

    local log_bundle
    log_bundle=$(jq -r '.data.log_bundle' "$ARTIFACT_DIR/stdout.log")
    ! grep -R -Fq 'super-secret-token' "$log_bundle"
    jq -e '.ORACLE_REMOTE_HOST == "remote.example:9333"' "$log_bundle/environment.redacted.json" >/dev/null
    jq -e '.tokens.ORACLE_REMOTE_TOKEN.present == true' "$log_bundle/environment.redacted.json" >/dev/null
    jq -e '.tokens.ORACLE_REMOTE_TOKEN.value == "<redacted>"' "$log_bundle/environment.redacted.json" >/dev/null
}
