#!/usr/bin/env bats
# test_run_ledger_schema_conformance.bats
#
# Conformance harness for docs/schemas/run-ledger.schema.json
# (apr_run_ledger.v1 — the canonical per-round provenance record
# emitted by lib/ledger.sh).
#
# Bead automated_plan_reviser_pro-yhvq.
#
# Pinned behavior:
#   - The schema parses as JSON Schema 2020-12 with the documented
#     top-level meta shape (additionalProperties=false, required
#     fields, state enum).
#   - Every fixture under tests/fixtures/run_ledger/valid/ validates
#     green (positive corpus: minimal-started, full-finished-ok,
#     failed-busy, canceled — covers every state in the enum).
#   - Every fixture under tests/fixtures/run_ledger/invalid/ is
#     rejected (negative corpus, 14 failure modes — missing top-level
#     required, wrong schema_version const, additionalProperties leak,
#     malformed prompt_hash sha256, state enum violation, file-entry
#     missing sha, file-entry inclusion_reason enum violation, round
#     minimum violation, oracle missing required, outcome
#     additionalProperties leak, execution counter below minimum,
#     state/outcome inconsistency).
#   - Pinned spot checks: state enum, prompt_hash shape,
#     additionalProperties on top level + sub-objects.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging
# contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    FIXTURES_DIR="$BATS_TEST_DIRNAME/../fixtures/run_ledger"
    SCHEMA_PATH="$BATS_TEST_DIRNAME/../../docs/schemas/run-ledger.schema.json"
    export FIXTURES_DIR SCHEMA_PATH

    if [[ ! -f "$SCHEMA_PATH" ]]; then
        skip "run-ledger.schema.json not present"
    fi
    if [[ ! -d "$FIXTURES_DIR/valid" || ! -d "$FIXTURES_DIR/invalid" ]]; then
        skip "run_ledger fixtures missing"
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — schema validation requires it"
    fi
    if ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
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

validate_ledger() {
    local fixture="$1"
    python3 - "$SCHEMA_PATH" "$fixture" <<'PY'
import json, sys
import jsonschema
schema_path, fixture_path = sys.argv[1], sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
with open(fixture_path) as f:
    data = json.load(f)
try:
    jsonschema.validate(data, schema)
    sys.exit(0)
except jsonschema.ValidationError as exc:
    sys.stderr.write(f"validation failure: {exc.message}\n")
    sys.exit(1)
PY
}

# ===========================================================================
# Schema integrity
# ===========================================================================

@test "schema parses as a JSON Schema 2020-12 document with the documented meta shape" {
    python3 - "$SCHEMA_PATH" <<'PY'
import json, sys
import jsonschema
with open(sys.argv[1]) as f:
    schema = json.load(f)
assert schema.get("$schema", "").endswith("2020-12/schema"), schema.get("$schema")
assert schema.get("$id", "").endswith("run-ledger.schema.json"), schema.get("$id")
assert schema.get("type") == "object"
assert schema.get("additionalProperties") is False
# Top-level required set per v1.
required = set(schema.get("required", []))
assert required >= {
    "schema_version", "workflow", "round", "slug", "run_id",
    "started_at", "state", "files", "prompt_hash", "oracle",
    "outcome", "execution",
}, required
# State enum is the documented closed set.
state_enum = set(schema["properties"]["state"]["enum"])
assert state_enum == {"started", "finished", "failed", "canceled"}, state_enum
# Schema_version const is the documented v1 string.
assert schema["properties"]["schema_version"]["const"] == "apr_run_ledger.v1"
# Sub-schema integrity for nested required objects.
for sub, want in [
    ("oracle",    {"engine", "model"}),
    ("outcome",   {"ok", "code"}),
    ("execution", {"retries_count", "busy_wait_count", "busy_wait_total_ms"}),
]:
    sub_req = set(schema["properties"][sub]["required"])
    assert sub_req >= want, (sub, sub_req, want)
# Self-validate the schema document.
jsonschema.Draft202012Validator.check_schema(schema)
PY
}

# ===========================================================================
# Positive corpus — every state in the enum exercised
# ===========================================================================

@test "valid corpus: every fixture under valid/ validates green" {
    local fixture
    local count=0
    while IFS= read -r fixture; do
        count=$(( count + 1 ))
        if ! validate_ledger "$fixture"; then
            echo "POSITIVE corpus violation: $fixture should validate" >&2
            return 1
        fi
    done < <(find "$FIXTURES_DIR/valid" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [[ "$count" -ge 4 ]] || {
        echo "Positive corpus has only $count fixtures; expected >=4 (one per state)" >&2
        return 1
    }
}

@test "valid corpus covers every state in the documented enum" {
    python3 - "$SCHEMA_PATH" "$FIXTURES_DIR/valid" <<'PY'
import glob, json, os, sys
with open(sys.argv[1]) as f:
    schema = json.load(f)
state_enum = set(schema["properties"]["state"]["enum"])
seen = set()
for path in glob.glob(os.path.join(sys.argv[2], "*.json")):
    with open(path) as f:
        seen.add(json.load(f).get("state"))
missing = state_enum - seen
extras  = seen - state_enum
assert not missing, f"positive corpus does not exercise states: {missing}"
assert not extras,  f"positive corpus has undocumented states: {extras}"
PY
}

# ===========================================================================
# Negative corpus — every failure mode rejected
# ===========================================================================

@test "invalid corpus: every fixture under invalid/ is rejected by the schema" {
    local fixture
    local count=0
    while IFS= read -r fixture; do
        count=$(( count + 1 ))
        if validate_ledger "$fixture" 2>/dev/null; then
            echo "NEGATIVE corpus violation: $fixture should be rejected but validated green" >&2
            return 1
        fi
        local reason
        reason=$(validate_ledger "$fixture" 2>&1 1>/dev/null || true)
        log_test_step check "reject $(basename "$fixture"): $reason"
    done < <(find "$FIXTURES_DIR/invalid" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [[ "$count" -ge 8 ]] || {
        echo "Negative corpus has only $count fixtures; expected >=8 failure modes" >&2
        return 1
    }
}

# ===========================================================================
# Pinned-rule spot checks (defense-in-depth)
# ===========================================================================

@test "schema rejects ledgers with state outside the documented enum" {
    local f="$FIXTURES_DIR/invalid/05_invalid_state_enum.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "state-enum spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects ledgers whose prompt_hash isn't 64-hex sha256" {
    local f="$FIXTURES_DIR/invalid/04_malformed_prompt_hash.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "prompt_hash spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects top-level additionalProperties leaks" {
    local f="$FIXTURES_DIR/invalid/03_additional_property.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "additionalProperties spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects outcome sub-object additionalProperties leaks" {
    local f="$FIXTURES_DIR/invalid/10_outcome_additional_property.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "outcome additionalProperties spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects finished ledgers whose outcome is not ok" {
    local f="$FIXTURES_DIR/invalid/12_finished_outcome_not_ok.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "finished outcome consistency spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects failed ledgers whose outcome claims ok" {
    local f="$FIXTURES_DIR/invalid/13_failed_outcome_ok.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "failed outcome consistency spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects canceled ledgers whose outcome claims ok" {
    local f="$FIXTURES_DIR/invalid/14_canceled_outcome_ok.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "canceled outcome consistency spot check: should be rejected" >&2
        return 1
    fi
}

@test "schema rejects files[].inclusion_reason outside the documented enum" {
    local f="$FIXTURES_DIR/invalid/07_file_inclusion_enum.json"
    [[ -f "$f" ]] || skip "fixture missing"
    if validate_ledger "$f" 2>/dev/null; then
        echo "files.inclusion_reason spot check: should be rejected" >&2
        return 1
    fi
}
