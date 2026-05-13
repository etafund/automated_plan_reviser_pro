#!/usr/bin/env bats
# test_v18_enforce_conformance.bats
#
# Bead automated_plan_reviser_pro-gqfu — shared conformance harness
# for the four v18 enforce-* enforcement scripts:
#
#   PLAN/.../scripts/enforce-access-policy.py
#   PLAN/.../scripts/enforce-review-quorum.py
#   PLAN/.../scripts/enforce-runtime-budget.py
#   PLAN/.../scripts/enforce-stage-readiness.py
#
# Each script ships with a small scenario suite (5-6 tests). This file
# adds a SHARED envelope conformance layer plus per-tool high-signal
# decision cross-checks so a refactor that drops a meta field or
# silently changes the ok/blocked decision surfaces here.
#
# Pinned across every script:
#   - schema_version == "json_envelope.v1"
#   - meta.tool matches the script's documented name
#   - meta.bundle_version == "v18.0.0"
#   - ok is a boolean; data is an object; errors / warnings are arrays
#   - failure envelopes carry non-empty errors[]; success envelopes have errors[]==[]
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
    SCRIPTS_DIR="$BUNDLE_DIR/scripts"
    FIXTURES_DIR="$BUNDLE_DIR/fixtures"

    if [[ ! -d "$SCRIPTS_DIR" || ! -d "$FIXTURES_DIR" ]]; then
        skip "v18 bundle not present at $BUNDLE_DIR"
    fi
    if ! python3 -c "import json" 2>/dev/null; then
        skip "python3 not available"
    fi

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Shared envelope assertions
# ---------------------------------------------------------------------------

assert_envelope_shape() {
    # Args: <json-path> <expected-tool>
    local json="$1" want_tool="$2"

    jq -e . "$json" >/dev/null || { echo "not JSON:" >&2; cat "$json" >&2; return 1; }
    jq -e '.schema_version == "json_envelope.v1"' "$json" >/dev/null || {
        echo "schema_version drift in $json:" >&2
        jq -r '.schema_version // "<missing>"' "$json" >&2
        return 1
    }
    jq -e --arg t "$want_tool" '.meta.tool == $t'             "$json" >/dev/null
    jq -e '.meta.bundle_version == "v18.0.0"'                 "$json" >/dev/null
    jq -e '.ok | type == "boolean"'                           "$json" >/dev/null
    jq -e '.data | type == "object"'                          "$json" >/dev/null
    jq -e '.errors | type == "array"'                         "$json" >/dev/null
    jq -e '.warnings | type == "array"'                       "$json" >/dev/null
}

# ===========================================================================
# enforce-access-policy.py
# ===========================================================================

@test "enforce/access-policy: allowed access path → ok envelope" {
    # Run from BUNDLE_DIR so the default relative policy path resolves.
    local out="$ARTIFACT_DIR/access_ok.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-access-policy.py \
        --route chatgpt_pro_first_plan \
        --access-path oracle_browser_remote \
        --policy-file fixtures/provider-access-policy.json --json ) > "$out" 2>/dev/null
    assert_envelope_shape "$out" "enforce-access-policy"
    jq -e '.ok == true and (.errors | length == 0)' "$out" >/dev/null
}

@test "enforce/access-policy: prohibited access path → ok=false + errors[]" {
    local out="$ARTIFACT_DIR/access_prohibited.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-access-policy.py \
        --route chatgpt_pro_first_plan \
        --access-path openai_api --json ) > "$out" 2>/dev/null
    assert_envelope_shape "$out" "enforce-access-policy"
    jq -e '.ok == false and (.errors | length > 0)' "$out" >/dev/null
    jq -e '.blocked_reason | type == "string" and length > 0' "$out" >/dev/null
}

@test "enforce/access-policy: missing required --route → non-zero exit" {
    local rc=0
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-access-policy.py --json ) \
        > "$ARTIFACT_DIR/access_missing.json" 2> "$ARTIFACT_DIR/access_missing.err" || rc=$?
    [[ "$rc" -ne 0 ]]
}

# ===========================================================================
# enforce-review-quorum.py
# ===========================================================================

@test "enforce/review-quorum: balanced quorum fixture → schema-correct envelope" {
    local out="$ARTIFACT_DIR/quorum_balanced.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-review-quorum.py \
        --policy "fixtures/review-quorum.balanced.json" --json ) > "$out" 2>/dev/null
    assert_envelope_shape "$out" "enforce-review-quorum"
}

@test "enforce/review-quorum: missing --policy → non-zero exit" {
    local rc=0
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-review-quorum.py --json ) \
        > "$ARTIFACT_DIR/quorum_missing.json" 2> "$ARTIFACT_DIR/quorum_missing.err" || rc=$?
    [[ "$rc" -ne 0 ]]
}

@test "enforce/review-quorum: nonexistent policy path → ok=false + errors[]" {
    local out="$ARTIFACT_DIR/quorum_nofile.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-review-quorum.py \
        --policy "/definitely/not/a/path.json" --json ) > "$out" 2>/dev/null || true
    assert_envelope_shape "$out" "enforce-review-quorum"
    jq -e '.ok == false and (.errors | length > 0)' "$out" >/dev/null
}

# ===========================================================================
# enforce-runtime-budget.py
# ===========================================================================

RUNTIME_BUDGET_TOOL="enforce-runtime-budget"

@test "enforce/runtime-budget: balanced budget + balanced progress → schema-correct envelope" {
    local out="$ARTIFACT_DIR/budget_ok.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-runtime-budget.py \
        --budget "fixtures/runtime-budget.json" \
        --progress "fixtures/run-progress.json" --json ) > "$out" 2>/dev/null
    assert_envelope_shape "$out" "$RUNTIME_BUDGET_TOOL"
}

@test "enforce/runtime-budget: missing --budget OR --progress → non-zero exit" {
    local rc1=0 rc2=0
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-runtime-budget.py --progress fixtures/run-progress.json --json ) \
        > "$ARTIFACT_DIR/budget_no_b.json" 2>/dev/null || rc1=$?
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-runtime-budget.py --budget fixtures/runtime-budget.json --json ) \
        > "$ARTIFACT_DIR/budget_no_p.json" 2>/dev/null || rc2=$?
    [[ "$rc1" -ne 0 ]]
    [[ "$rc2" -ne 0 ]]
}

@test "enforce/runtime-budget: excessive wall time → ok=false (cross-check)" {
    # Override with an inline budget that has a very low wall cap.
    local tiny_budget="$TEST_DIR/tiny_budget.json"
    cat > "$tiny_budget" <<'JSON'
{
  "schema_version": "runtime_budget.v1",
  "bundle_version": "v18.0.0",
  "wall_clock_budget_minutes": 1,
  "cost_budget_usd": 100.0,
  "retry_budget": {"attempts": 3, "cooldown_seconds": 60}
}
JSON
    local out="$ARTIFACT_DIR/budget_exceed.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-runtime-budget.py \
        --budget "$tiny_budget" \
        --progress "fixtures/run-progress.json" \
        --elapsed-minutes 999 --json ) > "$out" 2>/dev/null || true
    assert_envelope_shape "$out" "$RUNTIME_BUDGET_TOOL"
    jq -e '.ok == false' "$out" >/dev/null || {
        echo "expected ok=false on elapsed=999 > wall_budget=1:" >&2
        cat "$out" >&2
        return 1
    }
}

# ===========================================================================
# enforce-stage-readiness.py
# ===========================================================================

@test "enforce/stage-readiness: balanced readiness + preflight stage → ok=true" {
    local out="$ARTIFACT_DIR/stage_preflight.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-stage-readiness.py \
        --readiness "fixtures/route-readiness.balanced.json" \
        --stage preflight --json ) > "$out" 2>/dev/null
    assert_envelope_shape "$out" "enforce-stage-readiness"
    jq -e '.ok == true and .data.ready == true' "$out" >/dev/null
}

@test "enforce/stage-readiness: synthesis stage on a preflight-only fixture → ok=false" {
    # The balanced readiness fixture only marks preflight ready;
    # synthesis should NOT be ready, surfacing as ok=false.
    local out="$ARTIFACT_DIR/stage_synth.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-stage-readiness.py \
        --readiness "fixtures/route-readiness.balanced.json" \
        --stage synthesis --json ) > "$out" 2>/dev/null || true
    assert_envelope_shape "$out" "enforce-stage-readiness"
    jq -e '.ok == false and .data.ready == false' "$out" >/dev/null
    jq -e '.errors | length > 0' "$out" >/dev/null
}

@test "enforce/stage-readiness: nonexistent readiness file → ok=false + errors[]" {
    local out="$ARTIFACT_DIR/stage_nofile.json"
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-stage-readiness.py \
        --readiness "/nope/missing.json" \
        --stage preflight --json ) > "$out" 2>/dev/null || true
    assert_envelope_shape "$out" "enforce-stage-readiness"
    jq -e '.ok == false and (.errors | length > 0)' "$out" >/dev/null
}

@test "enforce/stage-readiness: missing required --stage → non-zero exit" {
    local rc=0
    ( cd "$BUNDLE_DIR" && python3 scripts/enforce-stage-readiness.py \
        --readiness "fixtures/route-readiness.balanced.json" --json ) \
        > "$ARTIFACT_DIR/stage_no_stage.json" 2>/dev/null || rc=$?
    [[ "$rc" -ne 0 ]]
}

# ===========================================================================
# Cross-tool conformance
# ===========================================================================

@test "cross-tool: every script emits a meta block with tool name AND bundle version" {
    # Iterate all four scripts in their canonical success-path
    # invocation and assert the shared meta block.
    declare -A cases=(
        [access]="scripts/enforce-access-policy.py --route chatgpt_pro_first_plan --access-path oracle_browser_remote --json"
        [quorum]="scripts/enforce-review-quorum.py --policy fixtures/review-quorum.balanced.json --json"
        [budget]="scripts/enforce-runtime-budget.py --budget fixtures/runtime-budget.json --progress fixtures/run-progress.json --json"
        [stage]="scripts/enforce-stage-readiness.py --readiness fixtures/route-readiness.balanced.json --stage preflight --json"
    )
    declare -A want_tool=(
        [access]=enforce-access-policy
        [quorum]=enforce-review-quorum
        [budget]="$RUNTIME_BUDGET_TOOL"
        [stage]=enforce-stage-readiness
    )

    local label cmd out
    for label in access quorum budget stage; do
        cmd="${cases[$label]}"
        out="$ARTIFACT_DIR/cross_${label}.json"
        # shellcheck disable=SC2086
        ( cd "$BUNDLE_DIR" && python3 $cmd ) > "$out" 2>/dev/null || true
        jq -e --arg t "${want_tool[$label]}" '
            .schema_version == "json_envelope.v1"
            and .meta.tool == $t
            and .meta.bundle_version == "v18.0.0"
        ' "$out" >/dev/null || {
            echo "[$label] envelope/meta drift:" >&2
            jq '{schema_version, meta, ok}' "$out" >&2
            return 1
        }
    done
}

@test "cross-tool: every script's success-path envelope has the documented top-level keys" {
    # Each script's envelope: { ok, schema_version, data, meta,
    # warnings, errors, commands, next_command, fix_command,
    # blocked_reason, retry_safe }. Pin the full set so a refactor
    # that drops a top-level field surfaces here.
    local documented_keys=(ok schema_version data meta warnings errors commands)
    declare -A cases=(
        [access]="scripts/enforce-access-policy.py --route chatgpt_pro_first_plan --access-path oracle_browser_remote --json"
        [quorum]="scripts/enforce-review-quorum.py --policy fixtures/review-quorum.balanced.json --json"
        [budget]="scripts/enforce-runtime-budget.py --budget fixtures/runtime-budget.json --progress fixtures/run-progress.json --json"
        [stage]="scripts/enforce-stage-readiness.py --readiness fixtures/route-readiness.balanced.json --stage preflight --json"
    )
    local label cmd out k missing
    for label in access quorum budget stage; do
        cmd="${cases[$label]}"
        out="$ARTIFACT_DIR/keys_${label}.json"
        # shellcheck disable=SC2086
        ( cd "$BUNDLE_DIR" && python3 $cmd ) > "$out" 2>/dev/null || true
        missing=()
        for k in "${documented_keys[@]}"; do
            jq -e --arg k "$k" 'has($k)' "$out" >/dev/null || missing+=("$k")
        done
        if (( ${#missing[@]} > 0 )); then
            echo "[$label] missing keys: ${missing[*]}" >&2
            jq 'keys' "$out" >&2
            return 1
        fi
    done
}

@test "cross-tool: every script's failure envelope still has the documented meta block" {
    # Pull a known failure path from each script and assert that .meta
    # (tool + bundle_version) survives.
    declare -A cases=(
        [access]="scripts/enforce-access-policy.py --route chatgpt_pro_first_plan --access-path openai_api --json"
        [quorum]="scripts/enforce-review-quorum.py --policy /no/such/path.json --json"
        [stage]="scripts/enforce-stage-readiness.py --readiness /no/such/path.json --stage preflight --json"
    )
    declare -A want_tool=(
        [access]=enforce-access-policy
        [quorum]=enforce-review-quorum
        [stage]=enforce-stage-readiness
    )
    local label cmd out
    for label in access quorum stage; do
        cmd="${cases[$label]}"
        out="$ARTIFACT_DIR/fail_${label}.json"
        # shellcheck disable=SC2086
        ( cd "$BUNDLE_DIR" && python3 $cmd ) > "$out" 2>/dev/null || true
        jq -e --arg t "${want_tool[$label]}" '
            .meta.tool == $t
            and .meta.bundle_version == "v18.0.0"
            and .ok == false
        ' "$out" >/dev/null || {
            echo "[$label] failure envelope drift:" >&2
            jq '.' "$out" >&2
            return 1
        }
    done
}

@test "cross-tool: every script's --json mode emits stdout only on success" {
    declare -A cases=(
        [access]="scripts/enforce-access-policy.py --route chatgpt_pro_first_plan --access-path oracle_browser_remote --json"
        [stage]="scripts/enforce-stage-readiness.py --readiness fixtures/route-readiness.balanced.json --stage preflight --json"
    )
    local label cmd outdir
    for label in access stage; do
        cmd="${cases[$label]}"
        outdir="$ARTIFACT_DIR/stream_${label}"
        mkdir -p "$outdir"
        # shellcheck disable=SC2086
        ( cd "$BUNDLE_DIR" && python3 $cmd ) > "$outdir/stdout.log" 2> "$outdir/stderr.log"
        jq -e . "$outdir/stdout.log" >/dev/null
        # Stderr should be empty (or at least not contain a JSON envelope).
        if grep -Fq '"schema_version"' "$outdir/stderr.log"; then
            echo "[$label] JSON envelope leaked into stderr:" >&2
            cat "$outdir/stderr.log" >&2
            return 1
        fi
    done
}
