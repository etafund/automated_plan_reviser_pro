#!/usr/bin/env bats
# test_v18_contract_roundtrip.bats
#
# Bead automated_plan_reviser_pro-srhk — round-trip + required-field-drop
# conformance harness for the v18 schema corpus.
#
# tests/v18_contract_smoke.py already asserts "fixtures pass; negative
# fixtures fail". This file adds two property-based layers on top:
#
#   - Round-trip: every positive fixture survives canonical serialize →
#     re-parse → re-validate without loss or invention.
#   - Required-drop: dropping each `required` property from a fixture
#     must cause validation to fail (catches schemas that declare
#     `required` but accept missing fields in practice).
#
# The actual work happens in tests/v18_contract_roundtrip.py. This BATS
# file is a thin wrapper that:
#   - skips if jsonschema or the v18 bundle is unavailable (CI-portable)
#   - runs the harness and asserts overall PASS
#   - inspects the JSON summary on stdout to surface per-fixture detail
#     into BATS' artifact dir on failure
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    HARNESS="$BATS_TEST_DIRNAME/../v18_contract_roundtrip.py"
    BUNDLE="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"

    if [[ ! -d "$BUNDLE" ]]; then
        skip "v18 bundle not present at $BUNDLE"
    fi
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "python3-jsonschema not installed"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "v18 round-trip: every positive fixture parses, canonicalizes, and re-validates" {
    # Run from repo root so the harness's relative paths resolve.
    run_with_artifacts python3 "$HARNESS"

    # Stash the JSON summary regardless of outcome so failures are
    # debuggable from artifacts alone.
    if jq -e . < "$ARTIFACT_DIR/stdout.log" > "$ARTIFACT_DIR/summary.json" 2>/dev/null; then
        cp -- "$ARTIFACT_DIR/summary.json" "$ARTIFACT_DIR/summary.json.bak" 2>/dev/null || true
    fi

    if [[ "$status" -ne 0 ]]; then
        echo "round-trip harness reported failures:" >&2
        # Show only fixtures with non-passing roundtrip or any
        # required-drop failure.
        jq -r '
            .fixtures[]
            | select(.roundtrip.passed == false or
                     ((.required_drop.results // [])
                        | any(.applicable == true and .rejected != true)))
            | .fixture
            ' "$ARTIFACT_DIR/stdout.log" >&2 || true
        echo "--- last 30 stderr lines ---" >&2
        tail -30 "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi

    # Sanity-check the summary shape so later tests can rely on it.
    jq -e '.passed == true'                       "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.round_trip_failures == 0'             "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.required_drop_failures == 0'          "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.fixture_count >= 5'                   "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 round-trip: at least the documented core schemas are exercised" {
    # Run the harness and parse its summary so we can assert which
    # fixtures got covered. This guards against the harness silently
    # losing fixtures (e.g. via a bundle reorganization).
    run_with_artifacts python3 "$HARNESS"
    [[ "$status" -eq 0 ]]

    # Core schemas the user-facing v18 contract surface depends on. The
    # provider-result family is exercised through its concrete provider
    # variants; we require at least the chatgpt + gemini exemplars.
    local must_cover=(
        "fixtures/provider-result.chatgpt.json"
        "fixtures/provider-result.gemini.json"
        "fixtures/chatgpt-pro-evidence.json"
        "fixtures/run-progress.json"
        "fixtures/source-baseline.json"
        "fixtures/source-trust.json"
    )

    local missing=()
    local f
    for f in "${must_cover[@]}"; do
        local matched
        matched=$(jq -r --arg f "$f" '.fixtures[] | select(.fixture == $f) | .fixture' \
            "$ARTIFACT_DIR/stdout.log")
        if [[ -z "$matched" ]]; then
            missing+=("$f")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "round-trip harness did not exercise these core fixtures:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        echo "all fixtures the harness saw:" >&2
        jq -r '.fixtures[].fixture' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    fi
}

@test "v18 round-trip: schemas with a 'required' array enforce every listed key" {
    # The harness records the count of required keys it actually tried
    # to drop and the count that produced a validation failure. The two
    # MUST agree for every applicable fixture (an applicable key is one
    # present in the fixture's top level).
    run_with_artifacts python3 "$HARNESS"
    [[ "$status" -eq 0 ]]

    # Aggregate counts across all fixtures.
    local checked rejected
    checked=$(jq '[
        .fixtures[].required_drop.results[]?
        | select(.applicable == true)
    ] | length' "$ARTIFACT_DIR/stdout.log")
    rejected=$(jq '[
        .fixtures[].required_drop.results[]?
        | select(.applicable == true and .rejected == true)
    ] | length' "$ARTIFACT_DIR/stdout.log")

    [[ "$checked" == "$rejected" ]] || {
        echo "required-drop coverage: $rejected/$checked required keys actually rejected" >&2
        jq '[
            .fixtures[]
            | {fixture, leaky_keys: (.required_drop.results // []
                | map(select(.applicable == true and .rejected != true) | .key))}
            | select(.leaky_keys | length > 0)
        ]' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    # And we should have actually checked a nontrivial number of keys
    # (guards against a harness regression where it silently runs zero
    # required-drop checks).
    [[ "$checked" -ge 10 ]] || {
        echo "required-drop check count suspiciously low: $checked" >&2
        return 1
    }
}

@test "v18 round-trip: stdout summary is valid JSON with the documented shape" {
    run_with_artifacts python3 "$HARNESS"
    [[ "$status" -eq 0 ]]

    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null

    # Top-level keys.
    jq -e '.timestamp | type == "string"'              "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.fixture_count | type == "number"'          "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.fixtures | type == "array"'                "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.round_trip_failures | type == "number"'    "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.required_drop_failures | type == "number"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.fixtures_without_schema | type == "number"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.passed | type == "boolean"'                "$ARTIFACT_DIR/stdout.log" >/dev/null

    # Per-fixture shape (when schema match exists).
    jq -e '[.fixtures[] | select(.schema != null) | .roundtrip.phase]
            | all(. == "roundtrip")' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 round-trip: harness writes a timestamped log to tests/logs/v18/contracts/" {
    local logs_dir
    logs_dir="$BATS_TEST_DIRNAME/../logs/v18/contracts"
    local before
    before=$(find "$logs_dir" -name 'roundtrip_*.log' 2>/dev/null | wc -l)

    run_with_artifacts python3 "$HARNESS"
    [[ "$status" -eq 0 ]]

    local after
    after=$(find "$logs_dir" -name 'roundtrip_*.log' 2>/dev/null | wc -l)
    [[ "$after" -gt "$before" ]] || {
        echo "harness did not create a new roundtrip log under $logs_dir" >&2
        ls "$logs_dir" 2>&1 >&2 || true
        return 1
    }
}
