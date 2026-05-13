#!/usr/bin/env bats
# test_v18_provider_adapters.bats
#
# Bead automated_plan_reviser_pro-v18-provider-mock-integration-tests-11f0
#
# Mock integration tests for the v18 provider adapter scripts shipped
# in commits b3ecbf0 (xai+deepseek), c8386d8 (claude+codex CLI), and
# 5bdade3 (provider adapters epic z0a):
#
#   PLAN/.../scripts/xai-deepseek-adapters.py
#   PLAN/.../scripts/claude-codex-adapters.py
#
# Both emit the v18 JSON envelope (`schema_version: json_envelope.v1`)
# from the same family as the readiness commands tested in nmet.
#
# Why this file exists:
#   - tests/unit/test_v18_claude_codex_adapters.bats has 4 happy-path
#     tests, no envelope-shape pinning, no binary-missing coverage.
#   - There is NO test file for xai-deepseek-adapters.py at all.
#   - The 11f0 bead asks for "deterministic mock coverage of every
#     adapter and provider-readiness path" before live cutover.
#
# Pinned contract (per adapter response):
#   - envelope shape: schema_version == json_envelope.v1, ok ∈ {true,false},
#     data is object, meta carries tool name + bundle_version, errors[]
#     and warnings[] are arrays
#   - provider_result family (xai/deepseek): scenario maps to error_code
#     per FAILURE_SCENARIOS; success path emits a provider_result with
#     provider_slot, model, evidence policy, redaction_actions[]
#   - CLI family (claude/codex): check/invoke/intake actions; binary
#     absence surfaces as adapter_failed error
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
    XAI_DEEPSEEK="$BUNDLE_DIR/scripts/xai-deepseek-adapters.py"
    CLAUDE_CODEX="$BUNDLE_DIR/scripts/claude-codex-adapters.py"

    if [[ ! -f "$XAI_DEEPSEEK" || ! -f "$CLAUDE_CODEX" ]]; then
        skip "v18 adapter scripts not present under $BUNDLE_DIR"
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
# Envelope assertions
# ---------------------------------------------------------------------------

# assert_envelope <path-to-json> <ok: true|false>
assert_envelope() {
    local json="$1" want_ok="$2"

    jq -e . "$json" >/dev/null || { echo "not JSON:" >&2; cat "$json" >&2; return 1; }
    jq -e '.schema_version == "json_envelope.v1"' "$json" >/dev/null || {
        echo "schema_version drift in $json:" >&2
        jq -r '.schema_version // "<missing>"' "$json" >&2
        return 1
    }
    jq -e --argjson want "$want_ok" '.ok == $want' "$json" >/dev/null || {
        echo "ok mismatch in $json: want=$want_ok got=$(jq '.ok' "$json")" >&2
        return 1
    }
    jq -e '.data | type == "object"' "$json" >/dev/null
    jq -e '.meta | type == "object" and (has("bundle_version"))' "$json" >/dev/null
    jq -e '.errors | type == "array"' "$json" >/dev/null
    jq -e '.warnings | type == "array"' "$json" >/dev/null
}

# ===========================================================================
# xai-deepseek-adapters: success path
# ===========================================================================

@test "adapters/xai-deepseek: deepseek --scenario success emits ok envelope with provider_result" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider deepseek --scenario success --json
    [[ "$status" -eq 0 ]]
    assert_envelope "$ARTIFACT_DIR/stdout.log" true

    # Provider identity propagates into data.
    jq -e '.data.provider == "deepseek"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.scenario == "success"'  "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.provider_slot == "deepseek_v4_pro_reasoning_search"' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null

    # provider_result carries the v18 schema fields.
    jq -e '
        .data.provider_result.schema_version == "provider_result.v1"
        and .data.provider_result.status == "success"
        and (.data.provider_result.redaction_actions | type == "array")
        and (.data.provider_result.evidence == null)
        and .data.provider_result.reasoning_effort_verified == true
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: xai --scenario success has reasoning_effort=high and no search trace" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --scenario success --json
    [[ "$status" -eq 0 ]]
    assert_envelope "$ARTIFACT_DIR/stdout.log" true

    jq -e '
        .data.provider == "xai"
        and .data.provider_result.reasoning_effort == "high"
        and (.data.provider_result | has("search_enabled") | not)
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: deepseek success records citations + search_enabled" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider deepseek --scenario success --json
    [[ "$status" -eq 0 ]]
    jq -e '
        .data.provider_result.search_enabled == true
        and .data.provider_result.search_tool_name == "apr_web_search"
        and .data.provider_result.citation_count >= 1
        and (.data.provider_result.citations | type == "array")
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

# ===========================================================================
# xai-deepseek-adapters: FAILURE_SCENARIOS (table-driven)
# ===========================================================================

@test "adapters/xai-deepseek: every documented failure scenario maps to the right error_code" {
    # FAILURE_SCENARIOS from xai-deepseek-adapters.py (lines ~49-56).
    # Drift here surfaces as a test failure with the offending scenario.
    # Some scenarios are provider-specific:
    #   search_disabled / missing_citations apply only to DeepSeek (the
    #   xai variant is correctly rejected by the harness as
    #   "invalid_scenario"); the table below enumerates the matrix of
    #   (provider, scenario) → expected error_code pairs.
    local cases=(
        "xai auth_failure auth_missing"
        "xai rate_limit rate_limited"
        "xai model_unavailable model_unavailable"
        "xai raw_reasoning_leak raw_reasoning_leak"
        "deepseek auth_failure auth_missing"
        "deepseek rate_limit rate_limited"
        "deepseek model_unavailable model_unavailable"
        "deepseek search_disabled search_disabled"
        "deepseek missing_citations missing_citations"
        "deepseek raw_reasoning_leak raw_reasoning_leak"
    )

    local entry provider scenario want
    local checks=0
    for entry in "${cases[@]}"; do
        read -r provider scenario want <<<"$entry"
        local out="$ARTIFACT_DIR/${provider}_${scenario}.json"
        python3 "$XAI_DEEPSEEK" --provider "$provider" --scenario "$scenario" --json \
            > "$out" 2>"$ARTIFACT_DIR/${provider}_${scenario}.err" || true
        jq -e . "$out" >/dev/null || {
            echo "[$provider/$scenario] not valid JSON" >&2
            cat "$out" >&2
            return 1
        }
        jq -e --arg want "$want" \
            '.ok == false and (.errors[0].error_code == $want)' "$out" >/dev/null || {
            echo "[$provider/$scenario] envelope drift (want error_code=$want):" >&2
            jq '{ok, errors}' "$out" >&2
            return 1
        }
        assert_envelope "$out" false
        checks=$((checks + 1))
    done
    [[ "$checks" -eq 10 ]]
}

@test "adapters/xai-deepseek: provider-scenario mismatch returns invalid_scenario (not a silent pass)" {
    # The harness rejects deepseek-specific scenarios on the xai
    # provider with a structured invalid_scenario error rather than
    # silently treating it as success or returning a generic failure.
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --scenario missing_citations --json
    [[ "$status" -ne 0 ]]
    jq -e '
        .ok == false
        and .errors[0].error_code == "invalid_scenario"
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: failure envelope keeps provider_result with status=failed" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --scenario rate_limit --json
    [[ "$status" -ne 0 ]]
    jq -e '
        .ok == false
        and .data.provider_result.status == "failed"
        and (.data.provider_result | has("provider_slot"))
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: --check-env demands the api_key_env var to be set" {
    # Force the env var to be empty/absent; the script should mark
    # api_key_present == false and report a failing envelope.
    XAI_API_KEY= run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --check-env --json
    [[ "$status" -ne 0 ]]
    jq -e '.data.api_key_present == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: --validate-fixtures returns an ok envelope (positive + negative fixtures honored)" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --validate-fixtures --json
    [[ "$status" -eq 0 ]]
    assert_envelope "$ARTIFACT_DIR/stdout.log" true
    jq -e '
        .data.negative_fixture_rejected == true
        and .data.json_envelope_contract == "validated"
        and .data.must_score == 1.0
        and (.data.validated_fixtures | length >= 3)
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/xai-deepseek: --output writes the provider_result artifact to disk" {
    local artifact="$ARTIFACT_DIR/provider_result.json"
    run_with_artifacts python3 "$XAI_DEEPSEEK" \
        --provider deepseek --scenario success --output "$artifact" --json
    [[ "$status" -eq 0 ]]
    [[ -f "$artifact" ]] || {
        echo "expected --output file at $artifact" >&2
        ls "$ARTIFACT_DIR" >&2
        return 1
    }
    jq -e '
        .schema_version == "provider_result.v1"
        and .provider_slot == "deepseek_v4_pro_reasoning_search"
    ' "$artifact" >/dev/null
}

# ===========================================================================
# claude-codex-adapters: check / invoke / intake
# ===========================================================================

@test "adapters/claude-codex: claude --action check emits a valid envelope (binary present or not)" {
    # Whether or not `claude` is installed on the host, the response
    # must be a well-formed envelope; data.available reflects reality.
    run_with_artifacts python3 "$CLAUDE_CODEX" --provider claude --action check --json
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.schema_version == "json_envelope.v1"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.available | type == "boolean"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/claude-codex: claude check with PATH stripped surfaces adapter_failed (binary missing)" {
    # Use a system-only PATH that keeps python3 reachable but strips
    # any user-installed claude/codex from ~/.local/bin. The subshell
    # scoping prevents the PATH change from leaking into bats teardown.
    local out="$ARTIFACT_DIR/claude_no_path.json"
    ( PATH="/usr/bin:/bin"; hash -r; python3 "$CLAUDE_CODEX" \
            --provider claude --action check --json ) \
        > "$out" 2>/dev/null
    # NOTE: the --json mode currently exits 0 even on adapter errors
    # (tracked as bug bead 80p0). Assert envelope contents directly;
    # the strict exit-code expectation is pinned below behind a skip.
    jq -e '
        .ok == false
        and .data.available == false
        and (.errors | length > 0)
        and (.errors[0].error_code == "adapter_failed")
    ' "$out" >/dev/null
}

@test "adapters/claude-codex: codex check with PATH stripped surfaces adapter_failed" {
    local out="$ARTIFACT_DIR/codex_no_path.json"
    ( PATH="/usr/bin:/bin"; hash -r; python3 "$CLAUDE_CODEX" \
            --provider codex --action check --json ) \
        > "$out" 2>/dev/null
    jq -e '
        .data.available == false
        and (.errors[0].error_code == "adapter_failed")
    ' "$out" >/dev/null
}

@test "adapters/claude-codex: claude invoke with --prompt succeeds and labels the provider_slot" {
    local prompt="$TEST_DIR/prompt.txt"
    printf 'test prompt\n' > "$prompt"
    run_with_artifacts python3 "$CLAUDE_CODEX" \
        --provider claude --action invoke --prompt "$prompt" --json
    [[ "$status" -eq 0 ]]
    jq -e '
        .ok == true
        and .data.status == "success"
        and .data.provider_slot == "claude_code_opus"
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/claude-codex: claude invoke without --prompt fails (envelope ok=false)" {
    # Current behavior: the adapter raises ValueError, catches it, and
    # emits an envelope with ok=false and errors[0].error_code ==
    # adapter_failed. Note that --json mode currently exits 0 even on
    # error (tracked as bug 80p0); the strict exit-code expectation
    # is pinned in the next test behind a skip.
    run_with_artifacts python3 "$CLAUDE_CODEX" --provider claude --action invoke --json
    jq -e '
        .ok == false
        and (.errors[0].error_code == "adapter_failed")
        and (.errors[0].message | test("--prompt is required"))
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/claude-codex: --json mode exit code reflects ok=false (strict)" {
    # Currently fails: claude-codex-adapters.py prints the failure
    # envelope but still exits 0 when --json is passed. Tracked as
    # follow-up bug bead automated_plan_reviser_pro-80p0. Deleting
    # the skip below once the fix lands is the natural acceptance
    # signal.
    skip "claude-codex-adapters.py --json mode does not honor ok=false in exit code — see bead automated_plan_reviser_pro-80p0"

    run_with_artifacts python3 "$CLAUDE_CODEX" --provider claude --action invoke --json
    [[ "$status" -ne 0 ]]
    jq -e '.ok == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters/claude-codex: codex intake records 'not formal_first_plan' policy" {
    # Per v18 policy, Codex output cannot satisfy formal-first-plan
    # gates. The adapter must encode this in data.formal_first_plan.
    run_with_artifacts python3 "$CLAUDE_CODEX" --provider codex --action intake --json
    [[ "$status" -eq 0 ]]
    jq -e '
        .ok == true
        and .data.formal_first_plan == false
        and .data.eligible_for_synthesis == false
        and .data.schema_version == "codex_intake.v1"
    ' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

# ===========================================================================
# Cross-adapter conformance
# ===========================================================================

@test "adapters: every adapter emits meta.bundle_version == v18.0.0" {
    local out
    for cmd in \
        "$XAI_DEEPSEEK --provider deepseek --scenario success --json" \
        "$XAI_DEEPSEEK --provider xai --scenario success --json" \
        "$CLAUDE_CODEX --provider claude --action check --json" \
        "$CLAUDE_CODEX --provider codex --action intake --json"
    do
        out="$ARTIFACT_DIR/$(printf '%s' "$cmd" | md5sum | cut -c1-8).json"
        # shellcheck disable=SC2086
        python3 $cmd > "$out" 2>/dev/null || true
        jq -e '.meta.bundle_version == "v18.0.0"' "$out" >/dev/null || {
            echo "bundle_version drift in: $cmd" >&2
            jq '.meta' "$out" >&2
            return 1
        }
    done
}

@test "adapters: every adapter's tool name matches the documented value" {
    local out
    out="$ARTIFACT_DIR/xai_tool.json"
    python3 "$XAI_DEEPSEEK" --provider xai --scenario success --json > "$out" 2>/dev/null
    jq -e '.meta.tool == "xai-deepseek-adapters"' "$out" >/dev/null

    out="$ARTIFACT_DIR/cc_tool.json"
    python3 "$CLAUDE_CODEX" --provider claude --action check --json > "$out" 2>/dev/null
    jq -e '.meta.tool == "claude-codex-adapters"' "$out" >/dev/null
}

@test "adapters: stream discipline — --json mode emits to stdout only" {
    # On success, stderr must be silent in --json mode for both adapters.
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --scenario success --json
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "xai-deepseek leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }

    run_with_artifacts python3 "$CLAUDE_CODEX" --provider codex --action intake --json
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "adapters: success envelopes carry zero errors AND zero warnings by default" {
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider deepseek --scenario success --json
    jq -e '.errors | length == 0'   "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.warnings | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "adapters: failure envelopes never drop the meta block (regression guard)" {
    # The error path must keep emitting the {tool, bundle_version}
    # meta block so downstream automation can route on the source.
    run_with_artifacts python3 "$XAI_DEEPSEEK" --provider xai --scenario rate_limit --json
    [[ "$status" -ne 0 ]]
    jq -e '.meta.tool == "xai-deepseek-adapters" and .meta.bundle_version == "v18.0.0"' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null
}
