#!/usr/bin/env bats
# test_queue_events_schema_conformance.bats
#
# Conformance harness for docs/schemas/queue-events.schema.json
# (apr_queue_event.v1 — the append-only event log per bd-29w / queue
# state derivation).
#
# Bead automated_plan_reviser_pro-yqdh.
#
# Pinned behavior:
#   - The schema itself parses as JSON Schema 2020-12.
#   - Every fixture under tests/fixtures/queue_events/valid/ validates
#     green (positive corpus, one per documented event kind).
#   - Every fixture under tests/fixtures/queue_events/invalid/ is
#     REJECTED with a specific reason recorded in the artifact log
#     (negative corpus, one per failure mode).
#   - Adding a new event kind / required field must be threaded through
#     the schema + fixtures + this test together — drift surfaces as a
#     test failure.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging
# contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    FIXTURES_DIR="$BATS_TEST_DIRNAME/../fixtures/queue_events"
    SCHEMA_PATH="$BATS_TEST_DIRNAME/../../docs/schemas/queue-events.schema.json"
    export FIXTURES_DIR SCHEMA_PATH

    if [[ ! -f "$SCHEMA_PATH" ]]; then
        skip "queue-events.schema.json not present"
    fi
    if [[ ! -d "$FIXTURES_DIR/valid" || ! -d "$FIXTURES_DIR/invalid" ]]; then
        skip "queue_events fixtures missing"
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

# validate_event <fixture-path>
# Returns 0 if the fixture is valid per the schema; 1 otherwise (and
# writes the validation error to stderr).
validate_event() {
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

@test "schema parses as a JSON Schema 2020-12 document with the expected meta-fields" {
    python3 - "$SCHEMA_PATH" <<'PY'
import json, sys
import jsonschema
schema_path = sys.argv[1]
with open(schema_path) as f:
    schema = json.load(f)
# Meta integrity — these are load-bearing for the v1 contract.
assert schema.get("$schema", "").endswith("2020-12/schema"), schema.get("$schema")
assert schema.get("$id", "").endswith("queue-events.schema.json"), schema.get("$id")
assert schema.get("type") == "object", schema.get("type")
assert schema.get("additionalProperties") is False, schema.get("additionalProperties")
# Required top-level fields per v1.
required = set(schema.get("required", []))
assert required >= {"schema_version", "ts", "event", "entry_id", "workflow"}, required
# Event enum is the documented closed set.
event_enum = set(schema["properties"]["event"]["enum"])
assert event_enum == {"enqueue", "start", "finish", "fail", "cancel"}, event_enum
# Cross-validate the meta-schema itself; jsonschema raises if the
# schema document is structurally invalid.
jsonschema.Draft202012Validator.check_schema(schema)
PY
}

# ===========================================================================
# Positive corpus: every documented event kind validates green
# ===========================================================================

@test "valid corpus: every fixture under tests/fixtures/queue_events/valid/ validates green" {
    local fixture
    local count=0
    while IFS= read -r fixture; do
        count=$(( count + 1 ))
        if ! validate_event "$fixture"; then
            echo "POSITIVE corpus violation: $fixture should validate but did not" >&2
            return 1
        fi
    done < <(find "$FIXTURES_DIR/valid" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [[ "$count" -ge 5 ]] || {
        echo "Positive corpus has only $count fixtures; expected >=5 (one per event kind)" >&2
        return 1
    }
}

@test "valid corpus covers every event kind in the documented enum" {
    python3 - "$SCHEMA_PATH" "$FIXTURES_DIR/valid" <<'PY'
import glob, json, os, sys
schema_path, valid_dir = sys.argv[1], sys.argv[2]
with open(schema_path) as f:
    schema = json.load(f)
event_enum = set(schema["properties"]["event"]["enum"])
seen = set()
for path in glob.glob(os.path.join(valid_dir, "*.json")):
    with open(path) as f:
        seen.add(json.load(f).get("event"))
missing = event_enum - seen
extras  = seen - event_enum
assert not missing, f"positive corpus does not exercise event kinds: {missing}"
assert not extras,  f"positive corpus has undocumented event kinds: {extras}"
PY
}

# ===========================================================================
# Negative corpus: every fixture is rejected (with reason recorded)
# ===========================================================================

@test "invalid corpus: every fixture under tests/fixtures/queue_events/invalid/ is rejected by the schema" {
    local fixture
    local count=0
    while IFS= read -r fixture; do
        count=$(( count + 1 ))
        if validate_event "$fixture" 2>/dev/null; then
            echo "NEGATIVE corpus violation: $fixture should be rejected but validated green" >&2
            return 1
        fi
        # Record the rejection reason in the artifact log for debuggability.
        local reason
        reason=$(validate_event "$fixture" 2>&1 1>/dev/null || true)
        log_test_step check "reject $(basename "$fixture"): $reason"
    done < <(find "$FIXTURES_DIR/invalid" -maxdepth 1 -type f -name '*.json' | LC_ALL=C sort)
    [[ "$count" -ge 8 ]] || {
        echo "Negative corpus has only $count fixtures; expected >=8 (one per failure mode)" >&2
        return 1
    }
}

# ===========================================================================
# Pinned-rule spot checks (defense-in-depth — catch silent meta drift)
# ===========================================================================

@test "schema rejects 'enqueue' events that omit 'round'" {
    local f="$FIXTURES_DIR/invalid/04_enqueue_missing_round.json"
    [[ -f "$f" ]] || skip "fixture missing"
    ! validate_event "$f" 2>/dev/null
}

@test "schema rejects 'finish' events that omit 'exit_code'" {
    local f="$FIXTURES_DIR/invalid/06_finish_missing_exit_code.json"
    [[ -f "$f" ]] || skip "fixture missing"
    ! validate_event "$f" 2>/dev/null
}

@test "schema rejects events with additionalProperties=false leaks" {
    local f="$FIXTURES_DIR/invalid/08_additional_property.json"
    [[ -f "$f" ]] || skip "fixture missing"
    ! validate_event "$f" 2>/dev/null
}

@test "schema rejects stderr_digest values that aren't a 64-hex sha256" {
    local f="$FIXTURES_DIR/invalid/09_malformed_stderr_digest.json"
    [[ -f "$f" ]] || skip "fixture missing"
    ! validate_event "$f" 2>/dev/null
}
