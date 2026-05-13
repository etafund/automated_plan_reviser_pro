#!/usr/bin/env bats
# test_v18_provider_adapter_pipeline_conformance.bats
#
# Pins the v18 provider adapter and plan pipeline robot surfaces against the
# JSON envelope, provider-result, and plan-artifact contracts.

load '../helpers/test_helper'

setup() {
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/provider-adapter-pipeline-conformance.py"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "provider adapter pipeline conformance script not present at $SCRIPT"
    fi
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "python3-jsonschema not installed"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
}

run_provider_pipeline_conformance() {
    run_with_artifacts python3 "$SCRIPT" --json
}

@test "v18 provider adapter pipeline conformance: emits a passing robot envelope" {
    run_provider_pipeline_conformance
    [[ "$status" -eq 0 ]] || {
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.coverage.must_score == 1.0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 provider adapter pipeline conformance: every MUST case is tested" {
    run_provider_pipeline_conformance
    [[ "$status" -eq 0 ]]

    local must tested passing
    must=$(jq -r '.data.coverage.must_clauses' "$ARTIFACT_DIR/stdout.log")
    tested=$(jq -r '.data.coverage.tested' "$ARTIFACT_DIR/stdout.log")
    passing=$(jq -r '.data.coverage.passing' "$ARTIFACT_DIR/stdout.log")

    [[ "$must" -ge 11 ]]
    [[ "$must" == "$tested" ]]
    [[ "$must" == "$passing" ]]
    jq -e '[.data.cases[] | .status == "pass"] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 provider adapter pipeline conformance: schema-sensitive cases are present" {
    run_provider_pipeline_conformance
    [[ "$status" -eq 0 ]]

    jq -e '[.data.cases[]
            | select(.id == "deepseek_success_provider_result"
                     or .id == "xai_success_provider_result"
                     or .id == "deepseek_raw_reasoning_rejected")
            | .provider_result_validated == true] | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.cases[] | select(.id == "plan_artifact_fixture_schema")] | length == 1' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 provider adapter pipeline conformance: success is stdout-only JSON" {
    run_provider_pipeline_conformance
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
}
