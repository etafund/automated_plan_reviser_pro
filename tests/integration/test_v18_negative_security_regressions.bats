#!/usr/bin/env bats
# Pins v18 negative/security regressions for unsafe shortcut rejection.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/negative-security-regression.py"
    NEGATIVE_LOG_ROOT="$TEST_DIR/v18-negative-logs"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "negative security regression script not present at $SCRIPT"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

run_negative_security() {
    run_with_artifacts python3 "$SCRIPT" --json --log-root "$NEGATIVE_LOG_ROOT" "$@"
}

@test "v18 negative/security: all unsafe shortcut fixtures fail closed" {
    run_negative_security
    [[ "$status" -eq 0 ]] || {
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.case_count >= 10' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.negative_rejected == .data.case_count' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.coverage.must_clauses == .data.coverage.passing' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.coverage.score == 1' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.cases[] | .status == "pass" and .actual_decision == "rejected" and (.actual_error_code | type == "string")] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "v18 negative/security: named scenarios keep stable error codes" {
    run_negative_security
    [[ "$status" -eq 0 ]]

    local cases=(
        "api_substitution_provider_result api_substitution_prohibited"
        "codex_formal_first_plan codex_formal_plan_misuse"
        "unverified_browser_evidence browser_evidence_unverified"
        "deepseek_search_disabled deepseek_search_trace_missing"
        "deepseek_raw_reasoning_leak raw_reasoning_persisted"
        "artifact_secret_leak artifact_redaction_boundary_broken"
        "source_provider_instruction prompt_injection_not_quarantined"
        "toon_authoritative_contract toon_tru_authoritative_state"
        "route_readiness_circular_synthesis circular_synthesis_readiness"
        "synthesis_missing_traceability synthesis_without_quorum_or_traceability"
    )

    local entry scenario want
    for entry in "${cases[@]}"; do
        read -r scenario want <<<"$entry"
        jq -e --arg scenario "$scenario" --arg want "$want" '
            any(.data.cases[];
                .scenario_id == $scenario
                and .expected_error_code == $want
                and .actual_error_code == $want
                and .blocked_reason != null
                and (.human_message | type == "string" and length > 0)
            )
        ' "$ARTIFACT_DIR/stdout.log" >/dev/null || {
            echo "scenario drift: $scenario expected $want" >&2
            jq '.data.cases[] | select(.scenario_id == "'"$scenario"'")' "$ARTIFACT_DIR/stdout.log" >&2
            return 1
        }
    done
}

@test "v18 negative/security: single-scenario mode logs rerun metadata" {
    run_negative_security --scenario unverified_browser_evidence
    [[ "$status" -eq 0 ]]

    jq -e '.data.case_count == 1' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.cases[0].scenario_id == "unverified_browser_evidence"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.cases[0].actual_error_code == "browser_evidence_unverified"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.cases[0].rerun_command | contains("--scenario unverified_browser_evidence")' "$ARTIFACT_DIR/stdout.log" >/dev/null

    local log_bundle case_log
    log_bundle="$(jq -r '.data.log_bundle' "$ARTIFACT_DIR/stdout.log")"
    case_log="$(jq -r '.data.cases[0].artifact_paths.case_log' "$ARTIFACT_DIR/stdout.log")"
    [[ -f "$log_bundle/negative-security-report.json" ]]
    [[ -f "$case_log" ]]
    jq -e '.scenario_id == "unverified_browser_evidence"' "$case_log" >/dev/null
    jq -e '.expected_error_code == .actual_error_code' "$case_log" >/dev/null
}

@test "v18 negative/security: unknown scenario fails before reporting false success" {
    run_negative_security --scenario does_not_exist
    [[ "$status" -ne 0 ]]

    jq -e '.ok == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.errors | map(.error_code) | index("unknown_scenario")) != null' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.case_count == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}
