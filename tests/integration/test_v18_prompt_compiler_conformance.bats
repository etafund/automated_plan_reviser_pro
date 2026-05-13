#!/usr/bin/env bats
# test_v18_prompt_compiler_conformance.bats
#
# Bead automated_plan_reviser_pro-ufc.2 — BATS wrapper for
# PLAN/.../scripts/prompt-compiler-conformance.py. The Python harness owns
# route/policy comparisons; this wrapper pins the robot surface, coverage
# floors, deterministic route outputs, and stdout/stderr discipline.

load '../helpers/test_helper'

MIN_ROUTE_CASES=6

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    BUNDLE_DIR="$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
    SCRIPT="$BUNDLE_DIR/scripts/prompt-compiler-conformance.py"

    if [[ ! -f "$SCRIPT" ]]; then
        skip "prompt compiler conformance script not present at $SCRIPT"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

run_prompt_compiler_conformance() {
    run_with_artifacts python3 "$SCRIPT" --json
}

@test "v18 prompt compiler conformance: --json exits 0 and emits a valid envelope" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]] || {
        echo "prompt compiler conformance exited non-zero ($status):" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }

    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.ok == true' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.meta.tool == "prompt-compiler-conformance"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 prompt compiler conformance: every declared route case passes" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]]

    local must passing tested divergent
    must=$(jq -r '.data.coverage.must_clauses' "$ARTIFACT_DIR/stdout.log")
    passing=$(jq -r '.data.coverage.passing' "$ARTIFACT_DIR/stdout.log")
    tested=$(jq -r '.data.coverage.tested' "$ARTIFACT_DIR/stdout.log")
    divergent=$(jq -r '.data.coverage.divergent' "$ARTIFACT_DIR/stdout.log")

    [[ "$must" == "$passing" ]] || {
        echo "MUST route coverage drift: must=$must passing=$passing" >&2
        jq '.data.coverage' "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
    [[ "$must" == "$tested" ]]
    [[ "$divergent" == "0" ]]
    [[ "$must" -ge "$MIN_ROUTE_CASES" ]]
    jq -e '.data.coverage.score == 1.0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "v18 prompt compiler conformance: route slots match the balanced route fixture" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]]

    local root route_fixture expected actual
    root=$(jq -r '.data.checked_root' "$ARTIFACT_DIR/stdout.log")
    route_fixture="$root/fixtures/provider-route.balanced.json"
    expected=$(jq -r '[.routes[].slot] | sort | @json' "$route_fixture")
    actual=$(jq -r '[.data.route_slots[]] | sort | @json' "$ARTIFACT_DIR/stdout.log")

    [[ "$actual" == "$expected" ]] || {
        echo "route slot coverage drift:" >&2
        echo "expected=$expected" >&2
        echo "actual=$actual" >&2
        return 1
    }
}

@test "v18 prompt compiler conformance: every case has policy rules and stable hashes" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]]

    jq -e '[.data.cases[]
            | (.status == "pass"
               and .ok == true
               and (.policy_key | type == "string")
               and (.policy_key | length > 0)
               and (.provider_rule_count >= 1)
               and (.prompt_hash | test("^sha256:[0-9a-f]{64}$"))
               and (.stdout_sha256 | test("^sha256:[0-9a-f]{64}$"))
               and (.stderr_sha256 | test("^sha256:[0-9a-f]{64}$")))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null || {
        echo "prompt compiler case shape drift:" >&2
        jq '[.data.cases[]
             | select(.status != "pass"
                      or .ok != true
                      or .provider_rule_count < 1
                      or (.prompt_hash | test("^sha256:[0-9a-f]{64}$") | not))]' \
            "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

@test "v18 prompt compiler conformance: fixtures are reported and resolvable" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]]

    local root rel
    root=$(jq -r '.data.checked_root' "$ARTIFACT_DIR/stdout.log")
    for rel in $(jq -r '.data.fixtures[]' "$ARTIFACT_DIR/stdout.log"); do
        [[ -f "$root/$rel" ]] || {
            echo "reported fixture missing: $rel" >&2
            return 1
        }
    done
}

@test "v18 prompt compiler conformance: success is stdout-only JSON" {
    run_prompt_compiler_conformance
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "prompt compiler conformance leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
}
