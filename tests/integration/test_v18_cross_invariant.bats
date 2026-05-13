#!/usr/bin/env bats
# test_v18_cross_invariant.bats
#
# Bead automated_plan_reviser_pro-s8ge — BATS wrapper for
# PLAN/.../scripts/schema-cross-invariant-conformance.py (shipped in
# commit ed0addf).
#
# The Python script is the source of truth for "do the v18 schemas
# agree on cross-cutting invariants" — provider routing slots covered
# by both access and reasoning policy, source baselines matching
# source trust ledger, prompt context referencing the manifest, etc.
# It already runs and reports a structured envelope; this wrapper pins
# its public contract so any drift surfaces in CI without re-running
# the script manually.
#
# Pinned:
#   - envelope shape (json_envelope.v1)
#   - MUST clause pass count (== `must_clauses` == `passing`)
#   - per-area invariant_cases coverage (every documented area present
#     with at least one case)
#   - schema_cases coverage (>= 8 schemas exercised)
#   - exit-code contract (0 iff all-pass; non-zero otherwise)
#   - stream discipline (JSON on stdout only; stderr silent on success)
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/schema-cross-invariant-conformance.py"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "cross-invariant script not present at $SCRIPT"
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
# Helpers
# ---------------------------------------------------------------------------

# Documented invariant areas. If schema-cross-invariant-cases.json adds
# or drops an area, this list MUST be updated — and any place that
# relies on the old set surfaces as a failure here.
DOCUMENTED_AREAS=(
    "browser evidence"
    "provider policy"
    "provider routing"
    "review quorum"
    "serialization"
    "source and prompt"
    "source trust"
    "stage gating"
)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "v18 cross-invariant: --json invocation exits 0 and emits a valid envelope" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]] || {
        echo "script exited non-zero ($status):" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }

    # Envelope shape per docs/schema-cross-invariant-conformance.md.
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null

    local schema_v
    schema_v=$(jq -r '.schema_version // empty' "$ARTIFACT_DIR/stdout.log")
    [[ "$schema_v" == "json_envelope.v1" ]] || {
        echo "schema_version drift: want=json_envelope.v1 got=$schema_v" >&2
        return 1
    }

    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data | type == "object"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 cross-invariant: all MUST clauses currently pass (must_clauses == passing)" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    local must passing
    must=$(jq -r '.data.coverage.must_clauses' "$ARTIFACT_DIR/stdout.log")
    passing=$(jq -r '.data.coverage.passing' "$ARTIFACT_DIR/stdout.log")

    [[ "$must" == "$passing" ]] || {
        echo "must vs passing drift: must=$must passing=$passing" >&2
        jq '.data.coverage' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
    # Sanity: at least 20 MUST clauses today (24 at the time of writing).
    [[ "$must" -ge 20 ]] || {
        echo "must_clauses count suspiciously low: $must" >&2
        return 1
    }
}

@test "v18 cross-invariant: zero divergent cases and score == 1.0" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    jq -e '.data.coverage.divergent == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.coverage.score == 1.0'   "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 cross-invariant: every documented invariant area has at least one case" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    local missing=()
    local area
    for area in "${DOCUMENTED_AREAS[@]}"; do
        local matches
        matches=$(jq -r --arg a "$area" \
            '[.data.invariant_cases[] | select(.area == $a)] | length' \
            "$ARTIFACT_DIR/stdout.log")
        if [[ "$matches" == "0" ]]; then
            missing+=("$area")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo "invariant areas with zero cases:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        echo "areas observed:" >&2
        jq -r '[.data.invariant_cases[].area] | unique[]' \
            "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    fi
}

@test "v18 cross-invariant: every invariant case has the documented shape" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    # Every case must carry these keys; refactors that rename them
    # silently break downstream tooling that filters on requirement_level.
    jq -e '[.data.invariant_cases[]
            | (has("case_id") and has("area") and has("description")
               and has("requirement_level") and has("status"))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null || {
        echo "invariant_case shape drift:" >&2
        jq '.data.invariant_cases[0]' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    # Every requirement_level must be either MUST or SHOULD.
    jq -e '[.data.invariant_cases[].requirement_level]
            | all(. == "MUST" or . == "SHOULD")' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 cross-invariant: schema_cases exercises ≥ 8 schemas with fixture hashes" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    local n
    n=$(jq '.data.schema_cases | length' "$ARTIFACT_DIR/stdout.log")
    [[ "$n" -ge 8 ]] || {
        echo "schema_cases count suspiciously low: $n" >&2
        return 1
    }

    # Every entry carries a fixture_sha256 starting with "sha256:" so
    # downstream consumers can pin provenance.
    jq -e '[.data.schema_cases[]
            | (.fixture_sha256 // "" | startswith("sha256:"))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 cross-invariant: bundle_version stays in sync with the v18 tag" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.meta.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 cross-invariant: stdout-only stream discipline on success" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "cross-invariant script leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

@test "v18 cross-invariant: case_matrix path is reported and resolvable" {
    run_with_artifacts python3 "$SCRIPT" --json
    [[ "$status" -eq 0 ]]

    local relpath
    relpath=$(jq -r '.data.case_matrix' "$ARTIFACT_DIR/stdout.log")
    [[ -n "$relpath" && "$relpath" != "null" ]]

    # Resolve against the reported checked_root (the script's bundle root).
    local root
    root=$(jq -r '.data.checked_root' "$ARTIFACT_DIR/stdout.log")
    [[ -f "$root/$relpath" ]] || {
        echo "case_matrix path '$relpath' does not exist under '$root'" >&2
        return 1
    }
}

@test "v18 cross-invariant: --root flag is honored (non-existent root → non-zero exit)" {
    run_with_artifacts python3 "$SCRIPT" --json --root /definitely/not/a/path
    [[ "$status" -ne 0 ]] || {
        echo "expected non-zero exit when --root is bogus" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

@test "v18 cross-invariant: human-mode (no --json) also exits 0 on full pass" {
    run_with_artifacts python3 "$SCRIPT"
    [[ "$status" -eq 0 ]] || {
        echo "human-mode exit drift: got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}
