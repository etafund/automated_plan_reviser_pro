#!/usr/bin/env bats
# Pins the v18 mock E2E profile runner contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/mock-e2e-profiles.py"
    E2E_LOG_ROOT="$TEST_DIR/v18-e2e-logs"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "mock E2E profile script not present at $SCRIPT"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

run_mock_e2e() {
    run_with_artifacts python3 "$SCRIPT" --json --log-root "$E2E_LOG_ROOT" "$@"
}

@test "v18 mock E2E: all profiles complete and emit one JSON envelope" {
    run_mock_e2e
    [[ "$status" -eq 0 ]] || {
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.profile_count == 3' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.profiles_passed == 3' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.coverage.score == 1' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.profiles[] | .status == "pass" and (.commands | length) >= 10] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "v18 mock E2E: profiles keep distinct route shapes" {
    run_mock_e2e
    [[ "$status" -eq 0 ]]

    jq -e '
      (.data.profiles[] | select(.profile == "fast") | .route.required_slots) == ["codex_thinking_fast_draft"]
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '
      (.data.profiles[] | select(.profile == "balanced") | .route.required_slots | index("chatgpt_pro_synthesis")) != null
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '
      (.data.profiles[] | select(.profile == "audit") | .route.required_slots | length) >= 6
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 mock E2E: artifact summaries cover source, prompt, providers, synthesis, traceability, and logs" {
    run_mock_e2e --profile balanced
    [[ "$status" -eq 0 ]]

    jq -e '.data.profile_count == 1 and .data.profiles[0].profile == "balanced"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '
      [.data.profiles[0].artifacts[].kind] as $k
      | ($k | index("source_baseline")) != null
      and ($k | index("prompt_context")) != null
      and ($k | index("provider_result")) != null
      and ($k | index("browser_evidence")) != null
      and ($k | index("plan_ir")) != null
      and ($k | index("synthesis")) != null
      and ($k | index("traceability")) != null
      and ($k | index("review_packet")) != null
      and ($k | index("artifact_index")) != null
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.profiles[0].artifacts[] | .sha256 | startswith("sha256:")] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null

    local log_bundle event_log
    log_bundle="$(jq -r '.data.profiles[0].log_bundle' "$ARTIFACT_DIR/stdout.log")"
    event_log="$(jq -r '.data.profiles[0].event_log' "$ARTIFACT_DIR/stdout.log")"
    [[ -f "$log_bundle/profile-summary.json" ]]
    [[ -f "$log_bundle/command-transcript.json" ]]
    [[ -f "$event_log" ]]
    [[ "$(wc -l < "$event_log" | tr -d ' ')" -ge 10 ]]
}

@test "v18 mock E2E: single profile mode emits rerun command and fixture project" {
    run_mock_e2e --profile audit
    [[ "$status" -eq 0 ]]

    jq -e '.data.profiles[0].rerun_command | contains("--profile audit")' "$ARTIFACT_DIR/stdout.log" >/dev/null
    local fixture_project
    fixture_project="$(jq -r '.data.profiles[0].fixture_project.project_root' "$ARTIFACT_DIR/stdout.log")"
    [[ -f "$fixture_project/README.md" ]]
    [[ -f "$fixture_project/SPECIFICATION.md" ]]
    [[ -f "$fixture_project/docs/implementation.md" ]]
    [[ -f "$fixture_project/.apr/config.yaml" ]]
}
