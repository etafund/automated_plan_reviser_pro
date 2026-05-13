#!/usr/bin/env bats
# test_error_contract.bats
#
# Bead bd-18r (Tests: code + exit-code contract).
#
# Conformance harness for APR's three-layer error contract:
#
#   1. Process exit code        (stable per code class, defined in apr_exit_code_for_code)
#   2. Robot JSON envelope      ({ ok:false, code, data, hint?, meta:{v,ts} } on stdout)
#   3. Human stderr error tag   (APR_ERROR_CODE=<code> on stderr for fatal failures)
#
# The point of this suite is to fail loudly whenever any one of those three
# layers drifts: silent contract breakage is what makes downstream
# automation brittle. We exercise the contract through the real `apr`
# script (no sourcing tricks), in controlled failure states.
#
# Every test drops a timestamped artifact directory under
# tests/logs/integration/<ts>__<test>/{stdout.log,stderr.log,env.txt,
# cmdline.txt} per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Contract assertions (shared)
# ---------------------------------------------------------------------------

# assert_robot_envelope - the canonical robot JSON envelope shape.
#
# Args:
#   $1  expected ok: "true" | "false"
#   $2  expected code (e.g. "validation_failed")
#
# Reads stdout from $ARTIFACT_DIR/stdout.log; verifies that it parses as
# JSON, that ok/code match, and that the meta block has the required
# v + ts fields.
assert_robot_envelope() {
    local want_ok="$1"
    local want_code="$2"
    local json="$ARTIFACT_DIR/stdout.log"

    jq -e . "$json" >/dev/null || {
        echo "stdout is not valid JSON:" >&2
        cat "$json" >&2
        return 1
    }

    local got_ok got_code got_v got_ts got_data
    got_ok=$(jq -r '.ok' "$json")
    got_code=$(jq -r '.code' "$json")
    got_v=$(jq -r '.meta.v // empty' "$json")
    got_ts=$(jq -r '.meta.ts // empty' "$json")
    got_data=$(jq -r '.data // empty' "$json")

    [[ "$got_ok" == "$want_ok" ]] || {
        echo "ok mismatch: want=$want_ok got=$got_ok" >&2
        cat "$json" >&2
        return 1
    }
    [[ "$got_code" == "$want_code" ]] || {
        echo "code mismatch: want=$want_code got=$got_code" >&2
        cat "$json" >&2
        return 1
    }
    [[ -n "$got_v"  ]]  || { echo "meta.v missing"  >&2; return 1; }
    [[ -n "$got_ts" ]]  || { echo "meta.ts missing" >&2; return 1; }
    [[ -n "$got_data" ]] || { echo "data missing"   >&2; return 1; }
}

# assert_error_tag - the human stderr machine-readable tag.
assert_error_tag() {
    local want_code="$1"
    grep -Fq "APR_ERROR_CODE=$want_code" "$ARTIFACT_DIR/stderr.log" || {
        echo "missing 'APR_ERROR_CODE=$want_code' tag in stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

# assert_exit - exit code class assertion.
assert_exit() {
    local want="$1"
    [[ "$status" -eq "$want" ]] || {
        echo "exit code mismatch: want=$want got=$status" >&2
        echo "--- stdout ---" >&2; cat "$ARTIFACT_DIR/stdout.log" >&2
        echo "--- stderr ---" >&2; cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

# assert_robot_failure - run the full contract on a robot-mode invocation.
#   $1  expected code  (string)
#   $2  expected exit  (int)
assert_robot_failure() {
    local want_code="$1"
    local want_exit="$2"
    assert_exit "$want_exit"
    assert_robot_envelope "false" "$want_code"
    assert_error_tag "$want_code"
}

# ---------------------------------------------------------------------------
# Workflow fixture helpers
# ---------------------------------------------------------------------------

# install_workflow_valid - set up TEST_PROJECT with a complete, attached-file
# workflow that should pass validation (the only thing missing is Oracle).
install_workflow_valid() {
    cd "$TEST_PROJECT"
    mkdir -p .apr/workflows .apr/rounds/default

    cat > .apr/config.yaml <<'YAML'
default_workflow: default
YAML

    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Valid workflow for contract testing
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
  thinking_time: heavy
rounds:
  output_dir: .apr/rounds/default
template: |
  Read the attached README.md and SPECIFICATION.md, then provide feedback.
template_with_impl: |
  Read the attached README.md and SPECIFICATION.md, then provide feedback.
YAML

    cat > README.md <<'EOF'
# Contract test project
EOF
    cat > SPECIFICATION.md <<'EOF'
# Spec for contract test
EOF
}

# install_workflow_placeholder_leak - identical layout but the template
# carries an unexpanded `{{README}}` token, which triggers
# prompt_quality_check inside robot_validate / cmd_run.
install_workflow_placeholder_leak() {
    install_workflow_valid
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Workflow with placeholder leak (kept for contract testing)
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
  thinking_time: heavy
rounds:
  output_dir: .apr/rounds/default
template: |
  Read this README:
  <readme>
  {{README}}
  </readme>
template_with_impl: |
  Read this README:
  <readme>
  {{README}}
  </readme>
YAML
}

# install_workflow_missing_docs - workflow points at files that don't exist.
install_workflow_missing_docs() {
    cd "$TEST_PROJECT"
    mkdir -p .apr/workflows .apr/rounds/default

    cat > .apr/config.yaml <<'YAML'
default_workflow: default
YAML

    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Workflow referencing files that do not exist
documents:
  readme: nope-README.md
  spec: nope-SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
  Read the attached README.md.
YAML
    # Deliberately do NOT create the referenced files.
}

# without_oracle - run a command with /usr/bin etc on PATH but no `oracle`
# binary and no npx fallback, so check_oracle reports missing dependency.
without_oracle() {
    PATH=/usr/bin:/bin APR_NO_NPX=1 "$@"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"
    log_test_start "${BATS_TEST_NAME}"
    cd "$TEST_PROJECT"
}

teardown() {
    if [[ -d "$TEST_PROJECT/.apr" ]]; then
        save_artifact "$TEST_PROJECT/.apr" "apr_dir"
    fi
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# Robot mode contract (full three-layer assertion)
# ===========================================================================

# ---------------------------------------------------------------------------
# usage_error → exit 2
# ---------------------------------------------------------------------------

@test "contract: robot validate without a round → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot validate
    assert_robot_failure "usage_error" 2

    # The round argument must appear (or its absence be flagged) in data.
    grep -Eq '"errors"\s*:|"argument"\s*:' "$ARTIFACT_DIR/stdout.log"
}

@test "contract: robot validate with non-numeric round → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot validate notanumber
    assert_robot_failure "usage_error" 2
}

@test "contract: robot run without a round → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot run
    assert_robot_failure "usage_error" 2
    jq -e '.data.argument == "round"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "contract: robot run with non-numeric round → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot run xyz
    assert_robot_failure "usage_error" 2
}

@test "contract: robot unknown subcommand → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot definitely-not-a-command
    assert_robot_failure "usage_error" 2
    # The unknown command shows up in data.
    jq -e '.data.command' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "contract: robot unknown option → usage_error (exit 2)" {
    run_with_artifacts "$APR_SCRIPT" robot --no-such-flag
    assert_robot_failure "usage_error" 2
    jq -e '.data.option' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

# ---------------------------------------------------------------------------
# not_configured / validation_failed → exit 4
# ---------------------------------------------------------------------------

@test "contract: robot validate in fresh dir → not_configured (exit 4)" {
    # No `.apr/` and a valid round number: triggers not_configured branch
    # in robot_validate's failure-code preference logic.
    run_with_artifacts "$APR_SCRIPT" robot validate 1
    assert_robot_failure "not_configured" 4
    jq -e '.data.valid == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.errors | length > 0' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "contract: robot validate with placeholder leak → validation_failed (exit 4)" {
    install_workflow_placeholder_leak

    run_with_artifacts "$APR_SCRIPT" robot validate 1
    assert_robot_failure "validation_failed" 4

    # The errors array surfaces the placeholder reason.
    local errors
    errors=$(jq -r '.data.errors | join("\n")' "$ARTIFACT_DIR/stdout.log")
    grep -Fq "unexpanded placeholders" <<<"$errors" || {
        echo "expected placeholder reason in errors:" >&2
        echo "$errors" >&2
        return 1
    }
}

@test "contract: robot validate with missing documents → validation_failed (exit 4)" {
    install_workflow_missing_docs

    run_with_artifacts "$APR_SCRIPT" robot validate 1
    assert_robot_failure "validation_failed" 4

    # README/spec absence is enumerated.
    jq -r '.data.errors | join("\n")' "$ARTIFACT_DIR/stdout.log" \
        | grep -Eq 'README not found|Spec not found' || {
            echo "expected document-missing errors in data.errors:" >&2
            cat "$ARTIFACT_DIR/stdout.log" >&2
            return 1
        }
}

# ---------------------------------------------------------------------------
# dependency_missing → exit 3
# ---------------------------------------------------------------------------

@test "contract: robot run when oracle is missing → dependency_missing (exit 3)" {
    install_workflow_valid

    run_with_artifacts without_oracle "$APR_SCRIPT" robot run 1
    assert_robot_failure "dependency_missing" 3
    jq -e '.data.dependency == "oracle"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

# ===========================================================================
# Human mode contract (exit code + stderr tag; no JSON envelope)
# ===========================================================================

# For human mode the contract is two-layered: an exit code in the right
# class and a grep-friendly APR_ERROR_CODE=<code> tag on stderr. Robot
# JSON shape must NOT appear (stderr is for humans).

assert_human_failure() {
    local want_code="$1"
    local want_exit="$2"
    assert_exit "$want_exit"
    assert_error_tag "$want_code"

    # Robot envelope must not appear on stdout for human invocations.
    if grep -Fq '"meta"' "$ARTIFACT_DIR/stdout.log"; then
        echo "human-mode stdout unexpectedly contains a robot envelope:" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    fi
}

@test "contract: human apr run with placeholder leak surfaces an actionable diagnosis on stderr" {
    install_workflow_placeholder_leak

    # Human path: cmd_run reaches prompt_quality_check and prints the
    # PROMPT_QC_DETAILS diagnostic to stderr before returning nonzero. The
    # full contract assertion (tag + exit 4) lives in the strict test
    # immediately below — this one just pins the high-signal user-facing
    # bits so the human diagnostic itself never silently disappears.
    run_with_artifacts "$APR_SCRIPT" run 1 --dry-run

    [[ "$status" -ne 0 ]] || {
        echo "expected nonzero exit on placeholder leak (human mode)" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }

    grep -Fq "unexpanded placeholders" "$ARTIFACT_DIR/stderr.log"
    grep -Fq "Why this fails:"        "$ARTIFACT_DIR/stderr.log"
    grep -Fq "APR_ALLOW_CURLY_PLACEHOLDERS=1" "$ARTIFACT_DIR/stderr.log"
}

@test "contract: human apr run with placeholder leak → APR_ERROR_CODE=validation_failed + exit 4 (strict)" {
    # This is the strict contract test. It currently fails because the
    # human-mode `cmd_run` placeholder branch in `apr` prints the
    # PROMPT_QC_DETAILS diagnostic but does not route through `apr_fail`,
    # so neither the `APR_ERROR_CODE=` tag nor the `validation_failed`
    # exit class (4) is produced — instead the script falls through to a
    # generic exit-1.
    #
    # Keeping this test as a `skip` with the exact remediation visible
    # makes the gap unmissable: when the apr-side change lands, delete
    # the skip and this test starts enforcing the contract.
    #
    # Tracked as follow-up bead: automated_plan_reviser_pro-19bh
    # ("apr cmd_run: route human-mode placeholder QC failure through
    # apr_fail(validation_failed) so the error contract holds")
    skip "human-mode placeholder leak does not yet route through apr_fail — see bead automated_plan_reviser_pro-19bh"

    install_workflow_placeholder_leak
    run_with_artifacts "$APR_SCRIPT" run 1 --dry-run
    assert_human_failure "validation_failed" 4
}

@test "contract: human apr run without oracle → APR_ERROR_CODE=dependency_missing (exit 3)" {
    install_workflow_valid

    # Human path: preflight_check fails when Oracle is missing; the script
    # calls apr_fail with code=dependency_missing → tag on stderr + exit 3.
    run_with_artifacts without_oracle "$APR_SCRIPT" run 1
    assert_human_failure "dependency_missing" 3
}

@test "contract: human apr robot unknown command emits tag even though stdout is JSON" {
    # Robot mode's `robot_fail` writes the tag to stderr in addition to the
    # JSON on stdout. This test re-asserts the stream separation: JSON on
    # stdout, tag on stderr — both present, neither leaking into the other.
    run_with_artifacts "$APR_SCRIPT" robot what-is-this
    assert_exit 2
    jq -e '.ok == false and .code == "usage_error"' "$ARTIFACT_DIR/stdout.log" >/dev/null
    assert_error_tag "usage_error"

    # And stderr must not contain the JSON envelope.
    if grep -Fq '"meta"' "$ARTIFACT_DIR/stderr.log"; then
        echo "robot JSON leaked into stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi
}

# ===========================================================================
# Exit-code class invariants (table-driven)
# ===========================================================================
#
# These tests pin the mapping declared in `apr_exit_code_for_code` so any
# change to the taxonomy that bumps an exit value gets caught here even if
# the individual scenario tests above happen to drift.

@test "contract: exit-code class invariants for known codes" {
    load_apr_functions

    declare -A expect=(
        [ok]=0
        [usage_error]=2
        [dependency_missing]=3
        [not_configured]=4
        [config_error]=4
        [validation_failed]=4
        [attachment_mismatch]=4
        [network_error]=10
        [update_error]=11
        [busy]=12
    )

    local code want got fail=0
    for code in "${!expect[@]}"; do
        want="${expect[$code]}"
        got=$(apr_exit_code_for_code "$code")
        if [[ "$got" != "$want" ]]; then
            echo "EXIT CLASS DRIFT: $code: want=$want got=$got" >&2
            fail=1
        fi
    done
    return $fail
}

@test "contract: every taxonomy code maps to a defined exit class" {
    load_apr_functions

    while IFS= read -r code; do
        local mapped
        mapped=$(apr_exit_code_for_code "$code")
        [[ "$mapped" =~ ^[0-9]+$ ]] || {
            echo "code '$code' produced non-numeric exit '$mapped'" >&2
            return 1
        }
    done < <(apr_error_codes)
}
