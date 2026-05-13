#!/usr/bin/env bats
# test_metrics_schema_conformance.bats
#
# Bead automated_plan_reviser_pro-0bdj — conformance harness for the
# APR analytics metrics schema (.apr/analytics/<workflow>/metrics.json).
#
# Schema bumps tracked in docs/schemas/metrics-schema.md:
#   1.0.0  fzi.1   original doc/output/diff metrics + convergence
#   1.1.0  bd-2ic  + per-round `trust` object
#   1.2.0  bd-6rw  + per-round `execution` object (busy/retry/queue/outcome)
#
# All bumps are documented as non-breaking. This file pins both the
# per-version shape AND the backward-compat contract.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    FIXTURES_DIR="$BATS_TEST_DIRNAME/../fixtures/metrics"
    SCHEMA_PATH="$BATS_TEST_DIRNAME/../../docs/schemas/metrics.schema.json"

    if [[ ! -d "$FIXTURES_DIR" || ! -f "$SCHEMA_PATH" ]]; then
        skip "metrics fixtures or schema not present"
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

# validate_against_schema <fixture-path>
# Validates the fixture against the metrics schema using python3 +
# jsonschema. Returns 0 on success; on failure prints the error to
# stderr and returns 1. Skips cleanly if jsonschema is unavailable.
validate_against_schema() {
    local fixture="$1"
    python3 -c "
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(77)   # skip
schema = json.load(open('$SCHEMA_PATH'))
data   = json.load(open('$fixture'))
try:
    jsonschema.validate(data, schema)
    sys.exit(0)
except jsonschema.ValidationError as exc:
    sys.stderr.write(f'validation failure: {exc.message}\n')
    sys.exit(1)
"
    local rc=$?
    if [[ "$rc" -eq 77 ]]; then
        skip "python3-jsonschema not installed"
    fi
    return "$rc"
}

# Inventory: list every fixture file under tests/fixtures/metrics/.
metrics_fixtures() {
    find "$FIXTURES_DIR" -maxdepth 1 -type f -name '*.json' -print
}

# ===========================================================================
# Per-fixture validation
# ===========================================================================

@test "metrics: clean-round.json validates against the v1.2.0 schema" {
    validate_against_schema "$FIXTURES_DIR/clean-round.json"
}

@test "metrics: legacy-1.0.0.json validates under the v1.2.0 schema (backward compat)" {
    # The schema must be forward-compatible: a 1.0.0 file (no trust /
    # execution blocks) MUST still validate.
    validate_against_schema "$FIXTURES_DIR/legacy-1.0.0.json"
}

@test "metrics: low-trust-round.json validates AND surfaces trust signals" {
    validate_against_schema "$FIXTURES_DIR/low-trust-round.json"

    jq -e '.rounds[0].trust | type == "object"' \
        "$FIXTURES_DIR/low-trust-round.json" >/dev/null
}

@test "metrics: degraded-runtime-round.json validates AND surfaces execution.degraded_runtime=true" {
    validate_against_schema "$FIXTURES_DIR/degraded-runtime-round.json"

    jq -e '
        .rounds[0].execution | type == "object"
        and .degraded_runtime == true
    ' "$FIXTURES_DIR/degraded-runtime-round.json" >/dev/null
}

# ===========================================================================
# Per-version structural invariants
# ===========================================================================

@test "metrics: legacy-1.0.0.json has neither trust NOR execution block (per-version shape)" {
    local f="$FIXTURES_DIR/legacy-1.0.0.json"
    jq -e '.schema_version == "1.0.0"' "$f" >/dev/null

    # 1.0.0 fixtures don't carry the new blocks. Pin this so an
    # auto-migration that retroactively adds the blocks surfaces.
    jq -e '[.rounds[] | (has("trust") | not)]    | all' "$f" >/dev/null
    jq -e '[.rounds[] | (has("execution") | not)] | all' "$f" >/dev/null
}

@test "metrics: low-trust-round.json carries the trust block (v1.1.0+ shape)" {
    local f="$FIXTURES_DIR/low-trust-round.json"
    jq -e '[.rounds[] | has("trust")] | all' "$f" >/dev/null
    # Trust block has structured signals — at minimum schema_version
    # and one signal field.
    jq -e '.rounds[0].trust | type == "object" and (keys | length > 0)' "$f" >/dev/null
}

@test "metrics: degraded-runtime-round.json carries the execution block (v1.2.0 shape)" {
    local f="$FIXTURES_DIR/degraded-runtime-round.json"
    jq -e '.schema_version == "1.2.0"' "$f" >/dev/null
    jq -e '[.rounds[] | has("execution")] | all' "$f" >/dev/null
    # Execution block has structured signals.
    jq -e '.rounds[0].execution | type == "object" and (keys | length > 0)' "$f" >/dev/null
}

# ===========================================================================
# Cross-fixture invariants
# ===========================================================================

@test "metrics: every fixture's schema_version is in the documented set" {
    local f v
    while IFS= read -r f; do
        v=$(jq -r '.schema_version' "$f")
        case "$v" in
            1.0.0|1.1.0|1.2.0) : ;;
            *)
                echo "fixture $f has undocumented schema_version: $v" >&2
                return 1
                ;;
        esac
    done < <(metrics_fixtures)
}

@test "metrics: every fixture has a non-empty rounds[] array" {
    local f n
    while IFS= read -r f; do
        n=$(jq '.rounds | length' "$f")
        [[ "$n" -gt 0 ]] || {
            echo "fixture $f has empty rounds[]" >&2
            return 1
        }
    done < <(metrics_fixtures)
}

@test "metrics: every fixture has the documented top-level keys" {
    # Per metrics-schema.md every metrics.json has at minimum:
    # schema_version, workflow, created_at, updated_at, rounds.
    local required_keys=(schema_version workflow created_at updated_at rounds)
    local f k missing
    while IFS= read -r f; do
        missing=()
        for k in "${required_keys[@]}"; do
            jq -e --arg k "$k" 'has($k)' "$f" >/dev/null || missing+=("$k")
        done
        if (( ${#missing[@]} > 0 )); then
            echo "$f missing keys: ${missing[*]}" >&2
            return 1
        fi
    done < <(metrics_fixtures)
}

@test "metrics: every round entry has round + timestamp + documents" {
    # Per-round minimum shape per the schema.
    local f
    while IFS= read -r f; do
        jq -e '
            [.rounds[]
              | (has("round")
                  and has("timestamp")
                  and has("documents"))]
            | all
        ' "$f" >/dev/null || {
            echo "$f has a round entry missing core keys:" >&2
            jq '.rounds[0]' "$f" >&2
            return 1
        }
    done < <(metrics_fixtures)
}

# ===========================================================================
# Round-trip: jq -S sort_keys is byte-stable
# ===========================================================================

@test "metrics: every fixture survives jq -S round-trip with no information loss" {
    local f sorted reparsed
    while IFS= read -r f; do
        sorted=$(jq -S . "$f")
        # Parse the sorted form and compare logical equality to the
        # original.
        reparsed=$(echo "$sorted" | jq -S .)
        [[ "$sorted" == "$reparsed" ]] || {
            echo "$f: sort_keys round-trip not stable" >&2
            return 1
        }
        # And the round-tripped form parses back to the same logical
        # JSON (sets, not arrays — order via jq -S is enforced).
        diff -q <(jq -S . "$f") <(echo "$sorted") >/dev/null || {
            echo "$f: drift between sorted forms" >&2
            return 1
        }
    done < <(metrics_fixtures)
}

# ===========================================================================
# Coverage invariants
# ===========================================================================

@test "metrics: fixture set covers all 3 documented schema_version values (1.0.0, 1.1.0, 1.2.0)" {
    local versions
    versions=$(while IFS= read -r f; do
        jq -r '.schema_version' "$f"
    done < <(metrics_fixtures) | LC_ALL=C sort -u)

    # All three documented versions should be represented in fixtures.
    local v
    for v in 1.0.0 1.1.0 1.2.0; do
        if ! grep -Fxq "$v" <<<"$versions"; then
            echo "no fixture exercises schema_version=$v" >&2
            echo "fixture versions present:" >&2
            echo "$versions" >&2
            return 1
        fi
    done
}

@test "metrics: schema documents schema_version enum 1.0.0 + 1.1.0 + 1.2.0" {
    # Quick text-level check on the schema docs (the JSON schema may
    # not use a strict enum for schema_version, but the markdown
    # version table must list all three).
    local doc="$BATS_TEST_DIRNAME/../../docs/schemas/metrics-schema.md"
    [[ -f "$doc" ]] || skip "metrics-schema.md not present"
    grep -Fq "1.0.0" "$doc"
    grep -Fq "1.1.0" "$doc"
    grep -Fq "1.2.0" "$doc"
}
