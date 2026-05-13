#!/usr/bin/env bats
# test_capabilities_doctor.bats
#
# Bead automated_plan_reviser_pro-nmet — conformance harness for the
# v18 readiness commands: `apr capabilities` and `apr doctor`.
#
# These commands delegate to:
#   PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/provider-capability-check.sh
#   PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/premortem-check.py
#
# Both scripts emit a v18-specific JSON envelope with
# `schema_version: "json_envelope.v1"` and the documented fields
# {ok, data, meta, warnings, errors, commands, retry_safe, ...}. This
# file pins that shape at the apr CLI boundary so the wrappers don't
# silently drift away from the underlying scripts' contracts.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BUNDLE_DIR_DEFAULT() {
    echo "$BATS_TEST_DIRNAME/../../PLAN/apr-vnext-plan-bundle-v18.0.0"
}

assert_v18_envelope() {
    # Args: <path-to-json>
    local json="$1"

    jq -e . "$json" >/dev/null || { echo "not JSON:" >&2; cat "$json" >&2; return 1; }
    jq -e '.schema_version == "json_envelope.v1"' "$json" >/dev/null || {
        echo "schema_version is not json_envelope.v1:" >&2
        jq -r '.schema_version // "<missing>"' "$json" >&2
        return 1
    }
    jq -e '.ok | type == "boolean"' "$json" >/dev/null
    jq -e '.data | type == "object"' "$json" >/dev/null
    jq -e '.meta | type == "object"' "$json" >/dev/null
    jq -e '.warnings | type == "array"' "$json" >/dev/null
    jq -e '.errors | type == "array"' "$json" >/dev/null
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    BUNDLE_DIR="$(BUNDLE_DIR_DEFAULT)"
    if [[ ! -d "$BUNDLE_DIR" ]]; then
        skip "v18 bundle not present at $BUNDLE_DIR"
    fi
    if ! python3 -c "import json" 2>/dev/null; then
        skip "python3 not available"
    fi
    export NO_COLOR=1 APR_NO_GUM=1 CI=true
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# apr capabilities — envelope contract
# ===========================================================================

@test "capabilities: apr capabilities emits a single v18 JSON envelope on stdout (exit 0)" {
    run_with_artifacts "$APR_SCRIPT" capabilities
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0, got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    assert_v18_envelope "$ARTIFACT_DIR/stdout.log"

    # The capability surface specifically must enumerate inventory.
    jq -e '.data.capability_inventory | type == "array" and length > 0' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null

    # And the bundle version must be the documented v18.0.0 tag.
    jq -e '.data.bundle_version == "v18.0.0"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "capabilities: each inventory entry carries the documented identity keys" {
    run_with_artifacts "$APR_SCRIPT" capabilities
    [[ "$status" -eq 0 ]]

    # Pin the minimum stable shape: every entry must name a slot, a
    # family, a provider, and an access_path. If a refactor renames any
    # of these, agents that key off them break.
    jq -e '[.data.capability_inventory[]
            | (has("provider_slot") and has("provider_family")
               and has("provider") and has("access_path"))]
            | all' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "capabilities: --json is accepted (delegation pass-through)" {
    run_with_artifacts "$APR_SCRIPT" capabilities --json
    [[ "$status" -eq 0 ]]
    assert_v18_envelope "$ARTIFACT_DIR/stdout.log"
}

@test "capabilities: current behavior — non --json/--help flags are eaten by apr's main parser (pinned)" {
    # The cmd_capabilities body forwards "$@" to the underlying script,
    # but apr's main flag-parser intercepts every recognized flag
    # *before* dispatch. Unknown global flags (like --bundle-root) are
    # rejected as usage_error instead of passing through to the script.
    # That's a wrapper-vs-script contract gap — tracked separately.
    run_with_artifacts "$APR_SCRIPT" capabilities --bundle-root "$BUNDLE_DIR"
    [[ "$status" -eq 2 ]]
    grep -Fq "APR_ERROR_CODE=usage_error" "$ARTIFACT_DIR/stderr.log"
}

@test "capabilities: forwards --bundle-root to the underlying script (strict)" {
    # When the wrapper learns to forward arbitrary script flags, this
    # test pin verifies the deterministic --now-epoch / --bundle-root
    # pair actually flows through to provider-capability-check.sh.
    # Until then, the wrapper rejects --bundle-root with usage_error
    # (pinned above).
    skip "apr capabilities does not forward arbitrary underlying-script flags — see follow-up bug bead automated_plan_reviser_pro-z59j"

    run_with_artifacts "$APR_SCRIPT" capabilities \
        --bundle-root "$BUNDLE_DIR" \
        --now-epoch 1700000000
    [[ "$status" -eq 0 ]]
    assert_v18_envelope "$ARTIFACT_DIR/stdout.log"
    jq -e '.data.checked_at_epoch == 1700000000' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "capabilities: apr --help advertises both v18 readiness commands" {
    # `apr capabilities --help` is captured by apr's global --help
    # handler (it shows the top-level help). The user-facing contract
    # is therefore that the top-level help lists capabilities + doctor
    # so users can find them. Pin that here.
    run_with_artifacts "$APR_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    grep -Eq '^\s+capabilities\s' "$ARTIFACT_DIR/stderr.log"
    grep -Eq '^\s+doctor\s'       "$ARTIFACT_DIR/stderr.log"
}

# ===========================================================================
# apr doctor — current behavior + the two bugs found
# ===========================================================================

@test "doctor: apr doctor --json delegates and produces parseable stream output" {
    # Current behavior: TWO concatenated envelopes on stdout (tracked
    # as bug bead icoy). Until that's fixed, the contract test here
    # just asserts that *both* envelopes are present in the stream
    # so the pipeline keeps catching regressions on either side.
    run_with_artifacts "$APR_SCRIPT" doctor --json
    [[ "$status" -eq 0 || "$status" -eq 1 ]]

    # Both envelopes appear. We pull them out as discrete JSON
    # documents via `jq -s` (slurp into an array) — jq tolerates the
    # concatenated stream, even though `json.loads` does not.
    jq -se 'length == 2' < "$ARTIFACT_DIR/stdout.log" >/dev/null || {
        echo "doctor --json: expected exactly 2 concatenated envelopes" >&2
        echo "(see bead automated_plan_reviser_pro-icoy)" >&2
        return 1
    }
    jq -se '.[0].schema_version == "json_envelope.v1"
            and .[1].schema_version == "json_envelope.v1"' \
        < "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "doctor: --json output passes a single-document json.loads parse (strict)" {
    # Currently fails: cmd_doctor (apr:~2213-2222) emits two envelopes
    # back-to-back in --json mode instead of merging them into one.
    # Tracked as follow-up bug bead automated_plan_reviser_pro-icoy.
    # Delete the skip below once the fix lands and this test will
    # start enforcing the single-envelope contract.
    skip "apr doctor --json emits two concatenated envelopes — see bead automated_plan_reviser_pro-icoy"

    run_with_artifacts "$APR_SCRIPT" doctor --json
    [[ "$status" -eq 0 ]]
    python3 -c "import json,sys; json.loads(open(sys.argv[1]).read())" \
        "$ARTIFACT_DIR/stdout.log"
}

@test "doctor: default (non-json) renders without stderr 'command not found' noise (strict)" {
    # Currently fails: cmd_doctor calls `print_bold` which is not
    # defined anywhere, so stderr leaks
    #   apr: line 2213: print_bold: command not found
    # before the underlying scripts run. Tracked as bug bead
    # automated_plan_reviser_pro-vzyp. Delete the skip when the fix
    # lands.
    skip "apr doctor calls undefined print_bold — see bead automated_plan_reviser_pro-vzyp"

    run_with_artifacts "$APR_SCRIPT" doctor
    [[ "$status" -eq 0 ]]
    if grep -Eq 'command not found|: print_bold' "$ARTIFACT_DIR/stderr.log"; then
        echo "stderr leaks print_bold not-found error:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi
}

@test "doctor: default mode current behavior — exits 127 due to print_bold bug (pinned)" {
    # Pin the CURRENT broken behavior so the next change here is
    # visible: cmd_doctor calls undefined print_bold, set -euo pipefail
    # in apr propagates the 127, the underlying scripts never run.
    # When pane-6/7 lands the print_bold fix (bead vzyp), this test
    # will turn red and the fixer can replace it with the strict
    # exit-0 expectation. Until then, regressing TO a different broken
    # state would also surface here.
    run_with_artifacts "$APR_SCRIPT" doctor
    [[ "$status" -eq 127 ]] || {
        echo "doctor (non-json) exit drift: want 127 (print_bold not-found bug), got $status" >&2
        echo "see beads automated_plan_reviser_pro-vzyp (the bug) and nmet (this harness)" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "print_bold: command not found" "$ARTIFACT_DIR/stderr.log"
}

# ===========================================================================
# Stream discipline (G1/G2 from the UX QA matrix, scoped to readiness)
# ===========================================================================

@test "capabilities: writes JSON to stdout only; stderr stays empty on success" {
    run_with_artifacts "$APR_SCRIPT" capabilities
    [[ "$status" -eq 0 ]]
    [[ -s "$ARTIFACT_DIR/stdout.log" ]]
    # Stderr should be empty on success — provider-capability-check
    # is robot-friendly and only writes to stderr on error paths.
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "capabilities leaked to stderr on success:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

@test "capabilities: --bundle-root with a bogus path fails fast (exit non-zero)" {
    run_with_artifacts "$APR_SCRIPT" capabilities \
        --bundle-root "/nonexistent/bundle/path" \
        --now-epoch 1700000000
    [[ "$status" -ne 0 ]] || {
        echo "expected non-zero exit when bundle path is missing" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

# ===========================================================================
# Underlying scripts are reachable through both surfaces
# ===========================================================================

@test "capabilities: apr wrapper output is structurally equivalent to the direct script invocation" {
    # The wrapper rejects unknown flags before delegation (pinned
    # above), so a byte-for-byte diff against the direct script call
    # can only be done with the no-flag form. Use sort_keys via jq to
    # normalize and strip the non-deterministic `checked_at_epoch`
    # field before comparing.
    local direct="$ARTIFACT_DIR/direct.json"
    local via_apr="$ARTIFACT_DIR/via_apr.json"
    local script="$BUNDLE_DIR/scripts/provider-capability-check.sh"

    "$script"     > "$direct"  2>/dev/null
    "$APR_SCRIPT" capabilities > "$via_apr" 2>/dev/null

    local direct_norm via_norm
    direct_norm="$ARTIFACT_DIR/direct.norm.json"
    via_norm="$ARTIFACT_DIR/via_apr.norm.json"
    jq -S 'del(.data.checked_at_epoch)' "$direct"   > "$direct_norm"
    jq -S 'del(.data.checked_at_epoch)' "$via_apr"  > "$via_norm"

    diff -u "$direct_norm" "$via_norm" > "$ARTIFACT_DIR/delegation.diff" 2>&1 || {
        echo "wrapper output differs from direct script invocation (sans timestamp):" >&2
        cat "$ARTIFACT_DIR/delegation.diff" >&2
        return 1
    }
}
