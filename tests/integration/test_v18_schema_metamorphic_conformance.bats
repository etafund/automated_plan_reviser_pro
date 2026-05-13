#!/usr/bin/env bats
# test_v18_schema_metamorphic_conformance.bats
#
# Bead automated_plan_reviser_pro-9rr7 — BATS wrapper for the v18 schema
# metamorphic conformance harness. The Python script owns mutation generation;
# this file pins its robot envelope, MR coverage floors, and stream discipline.

load '../helpers/test_helper'

MIN_FIXTURE_CASES=50
MIN_MUTATION_CASES=700
MIN_MUST_CLAUSES=750

setup() {
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/schema-metamorphic-conformance.py"

    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "schema metamorphic conformance script not present at $SCRIPT"
    fi
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        skip "python3-jsonschema not installed"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
}

run_schema_metamorphic() {
    if [[ -z "${ARTIFACT_DIR:-}" ]]; then
        echo "run_schema_metamorphic: start_test_artifacts must be called first" >&2
        return 99
    fi
    {
        printf '%q ' python3 "$SCRIPT" --json
        printf '\n'
    } > "$ARTIFACT_DIR/cmdline.txt"

    status=0
    python3 "$SCRIPT" --json > "$ARTIFACT_DIR/stdout.log" 2> "$ARTIFACT_DIR/stderr.log" || status=$?

    # The metamorphic report is intentionally large. Do not export it into
    # BATS' output/stdout/stderr variables; that can exceed ARG_MAX for later
    # jq/date/mkdir invocations in the same test process.
    output=""
    stdout=""
    stderr=""
    export status output stdout stderr
}

@test "v18 schema metamorphic: --json exits 0 and emits a valid envelope" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]] || {
        echo "schema metamorphic harness exited non-zero ($status):" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.meta.tool == "schema-metamorphic-conformance"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema metamorphic: every generated MUST relation passes" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]

    local must passing tested divergent
    must=$(jq -r '.data.coverage.must_clauses' "$ARTIFACT_DIR/stdout.log")
    passing=$(jq -r '.data.coverage.passing' "$ARTIFACT_DIR/stdout.log")
    tested=$(jq -r '.data.coverage.tested' "$ARTIFACT_DIR/stdout.log")
    divergent=$(jq -r '.data.coverage.divergent' "$ARTIFACT_DIR/stdout.log")

    [[ "$must" == "$passing" ]] || {
        echo "metamorphic pass count drift: must=$must passing=$passing" >&2
        jq '.data.coverage' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
    [[ "$must" == "$tested" ]]
    [[ "$divergent" == "0" ]]
    [[ "$must" -ge "$MIN_MUST_CLAUSES" ]]
    jq -e '.data.coverage.score == 1.0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema metamorphic: fixture and mutation coverage cannot collapse" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]

    local fixture_cases mutation_cases
    fixture_cases=$(jq -r '.data.coverage.fixture_cases' "$ARTIFACT_DIR/stdout.log")
    mutation_cases=$(jq -r '.data.coverage.mutation_cases' "$ARTIFACT_DIR/stdout.log")

    [[ "$fixture_cases" -ge "$MIN_FIXTURE_CASES" ]] || {
        echo "fixture_cases below floor: $fixture_cases < $MIN_FIXTURE_CASES" >&2
        return 1
    }
    [[ "$mutation_cases" -ge "$MIN_MUTATION_CASES" ]] || {
        echo "mutation_cases below floor: $mutation_cases < $MIN_MUTATION_CASES" >&2
        return 1
    }

    jq -e '(.data.original_fixture_cases | length) == .data.coverage.fixture_cases' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '(.data.metamorphic_cases | length) == .data.coverage.mutation_cases' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema metamorphic: every documented MR has passing coverage" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]

    local relations=(
        "MR-SV-CONST"
        "MR-TOP-ENUM-CONST"
        "MR-TOP-TYPE"
    )

    local relation
    for relation in "${relations[@]}"; do
        local count
        count=$(jq -r --arg relation "$relation" \
            '.data.coverage.relation_counts[$relation] // 0' \
            "$ARTIFACT_DIR/stdout.log")
        [[ "$count" -gt 0 ]] || {
            echo "missing metamorphic relation coverage for $relation" >&2
            jq '.data.coverage.relation_counts' "$ARTIFACT_DIR/stdout.log" >&2
            return 1
        }
    done

    jq -e '[.data.metamorphic_cases[]
            | (.status == "pass"
               and (.relation_id | startswith("MR-"))
               and (.mutated_path | startswith("/"))
               and (.validation_error | type == "string"))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema metamorphic: relation matrix scores stay above the MR cutoff" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]

    jq -e '[.data.relation_matrix[]
            | (.id | startswith("MR-"))
              and (.score >= 2.0)
              and (.fault_sensitivity >= 1)
              and (.independence >= 1)
              and (.cost >= 1)]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 schema metamorphic: schema_version perturbation covers every fixture" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]

    local fixtures version_mutations
    fixtures=$(jq -r '.data.coverage.fixture_cases' "$ARTIFACT_DIR/stdout.log")
    version_mutations=$(jq -r '.data.coverage.relation_counts["MR-SV-CONST"]' \
        "$ARTIFACT_DIR/stdout.log")
    [[ "$fixtures" == "$version_mutations" ]] || {
        echo "schema_version mutation coverage drift: fixtures=$fixtures mutations=$version_mutations" >&2
        return 1
    }
}

@test "v18 schema metamorphic: success is stdout-only JSON" {
    run_schema_metamorphic
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "schema metamorphic harness leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
}
