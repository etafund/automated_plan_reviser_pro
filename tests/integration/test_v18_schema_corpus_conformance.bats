#!/usr/bin/env bats
# test_v18_schema_corpus_conformance.bats
#
# Bead automated_plan_reviser_pro-v18-final-integration-pass-c5ud.1
# pins PLAN/.../scripts/schema-corpus-conformance.py into the integration
# suite so final v18 readiness cannot silently lose schema/fixture coverage.
#
# The harness owns corpus semantics; this wrapper checks the public contract:
# robot envelope shape, full MUST pass coverage, nontrivial schema/fixture
# counts, negative-fixture rejection, exemption accounting, and stream hygiene.

load '../helpers/test_helper'

MIN_SCHEMA_CASES=37
MIN_FIXTURE_CASES=72
MIN_EXEMPTION_CASES=5
MIN_MUST_CLAUSES=100

setup() {
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/schema-corpus-conformance.py"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "schema corpus conformance script not present at $SCRIPT"
    fi
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "python3-jsonschema not installed"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
}

run_schema_corpus() {
    run_with_artifacts python3 "$SCRIPT" --json
}

@test "v18 schema corpus: --json invocation exits 0 and emits a valid envelope" {
    run_schema_corpus
    [[ "$status" -eq 0 ]] || {
        echo "schema corpus harness exited non-zero ($status):" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.meta.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema corpus: every MUST clause is tested and passing" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]

    local must passing tested divergent
    must=$(jq -r '.data.coverage.must_clauses' "$ARTIFACT_DIR/stdout.log")
    passing=$(jq -r '.data.coverage.passing' "$ARTIFACT_DIR/stdout.log")
    tested=$(jq -r '.data.coverage.tested' "$ARTIFACT_DIR/stdout.log")
    divergent=$(jq -r '.data.coverage.divergent' "$ARTIFACT_DIR/stdout.log")

    [[ "$must" == "$passing" ]] || {
        echo "MUST coverage drift: must=$must passing=$passing" >&2
        jq '.data.coverage' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
    [[ "$must" == "$tested" ]]
    [[ "$divergent" == "0" ]]
    jq -e '.data.coverage.score == 1.0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ "$must" -ge "$MIN_MUST_CLAUSES" ]]
}

@test "v18 schema corpus: schema, fixture, and exemption coverage cannot collapse" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]

    local schema_cases fixture_cases exemption_cases
    schema_cases=$(jq -r '.data.coverage.schema_cases' "$ARTIFACT_DIR/stdout.log")
    fixture_cases=$(jq -r '.data.coverage.fixture_cases' "$ARTIFACT_DIR/stdout.log")
    exemption_cases=$(jq -r '.data.coverage.exemption_cases' "$ARTIFACT_DIR/stdout.log")

    [[ "$schema_cases" -ge "$MIN_SCHEMA_CASES" ]] || {
        echo "schema_cases below floor: $schema_cases < $MIN_SCHEMA_CASES" >&2
        return 1
    }
    [[ "$fixture_cases" -ge "$MIN_FIXTURE_CASES" ]] || {
        echo "fixture_cases below floor: $fixture_cases < $MIN_FIXTURE_CASES" >&2
        return 1
    }
    [[ "$exemption_cases" -ge "$MIN_EXEMPTION_CASES" ]] || {
        echo "exemption_cases below floor: $exemption_cases < $MIN_EXEMPTION_CASES" >&2
        return 1
    }

    jq -e '(.data.schema_cases | length) == .data.coverage.schema_cases' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.data.fixture_cases | length) == .data.coverage.fixture_cases' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.data.exemption_cases | length) == .data.coverage.exemption_cases' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema corpus: every contract schema passes and carries provenance" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]

    jq -e '[.data.schema_cases[]
            | (.status == "pass"
               and (.schema | endswith(".schema.json"))
               and (.schema_version | type == "string")
               and (.schema_sha256 | startswith("sha256:")))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null || {
        echo "schema case shape/status drift:" >&2
        jq '[.data.schema_cases[]
             | select(.status != "pass"
                      or (.schema_sha256 | startswith("sha256:") | not))]' \
            "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

@test "v18 schema corpus: negative fixtures are rejected by their mapped schemas" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]

    local negative_count
    negative_count=$(jq '[.data.fixture_cases[] | select(.expect_valid == false and (.schema? != null))] | length' \
        "$ARTIFACT_DIR/stdout.log")
    [[ "$negative_count" -ge 5 ]] || {
        echo "negative fixture coverage suspiciously low: $negative_count" >&2
        return 1
    }

    jq -e '[.data.fixture_cases[]
            | select(.expect_valid == false and (.schema? != null))
            | (.status == "pass" and .negative_rejected == true)]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null || {
        echo "negative fixtures not rejected as expected:" >&2
        jq '[.data.fixture_cases[]
             | select(.expect_valid == false
                      and (.schema? != null)
                      and (.status != "pass" or .negative_rejected != true))]' \
            "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

@test "v18 schema corpus: unmapped fixture exemptions are explicit and passing" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]

    jq -e '.data.exemptions_path == "fixtures/conformance/schema-corpus-exemptions.json"' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '[.data.exemption_cases[]
            | (.status == "pass"
               and (.fixture | type == "string")
               and (.schema_version | type == "string")
               and (.reason | type == "string")
               and (.reason | length > 0))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema corpus: success is stdout-only JSON" {
    run_schema_corpus
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "schema corpus harness leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
}
