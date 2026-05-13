#!/usr/bin/env bats
# test_lint_contract.bats
#
# Bead automated_plan_reviser_pro-grs9 — conformance harness for the
# `apr lint` / `apr robot lint` surface against the bd-3tj error contract.
#
# Pins the three-layer contract for every failure class lint can produce:
#
#   1. Process exit code        (per apr_exit_code_for_code mapping)
#   2. Robot JSON envelope      ({ ok:false, code, data, hint?, meta:{v,ts} })
#   3. Human stderr error tag   (APR_ERROR_CODE=<code> on stderr)
#
# Complements tests/integration/test_error_contract.bats (which covers
# `apr run` / `apr robot run` / `apr robot validate`).
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Contract assertions (mirrored from test_error_contract.bats so the lint
# suite is self-contained and breakages here don't cascade)
# ---------------------------------------------------------------------------

assert_exit() {
    local want="$1"
    [[ "$status" -eq "$want" ]] || {
        echo "exit code mismatch: want=$want got=$status" >&2
        echo "--- stdout ---" >&2; cat "$ARTIFACT_DIR/stdout.log" >&2
        echo "--- stderr ---" >&2; cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

assert_error_tag() {
    local want="$1"
    grep -Fq "APR_ERROR_CODE=$want" "$ARTIFACT_DIR/stderr.log" || {
        echo "missing 'APR_ERROR_CODE=$want' in stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

assert_robot_envelope() {
    local want_ok="$1" want_code="$2"
    local json="$ARTIFACT_DIR/stdout.log"

    jq -e . "$json" >/dev/null || { echo "stdout is not JSON:" >&2; cat "$json" >&2; return 1; }

    local got_ok got_code
    got_ok=$(jq -r '.ok' "$json")
    got_code=$(jq -r '.code' "$json")
    [[ "$got_ok" == "$want_ok" ]] || {
        echo "ok mismatch: want=$want_ok got=$got_ok" >&2; cat "$json" >&2; return 1
    }
    [[ "$got_code" == "$want_code" ]] || {
        echo "code mismatch: want=$want_code got=$got_code" >&2; cat "$json" >&2; return 1
    }

    jq -e '.meta.v | type == "string" and length > 0'  "$json" >/dev/null
    jq -e '.meta.ts | type == "string" and length > 0' "$json" >/dev/null
    jq -e '.data | type == "object"' "$json" >/dev/null

    if [[ "$want_ok" == "false" ]]; then
        jq -e '.hint | type == "string" and length > 0' "$json" >/dev/null
    fi
}

# Full three-layer assertion for robot invocations.
assert_robot_failure() {
    local code="$1" exit_class="$2"
    assert_exit "$exit_class"
    assert_robot_envelope "false" "$code"
    assert_error_tag "$code"
}

# Two-layer assertion for human invocations (no JSON envelope expected).
assert_human_failure() {
    local code="$1" exit_class="$2"
    assert_exit "$exit_class"
    assert_error_tag "$code"
    # Stdout must NOT contain a robot envelope on the human path.
    if grep -Fq '"meta"' "$ARTIFACT_DIR/stdout.log"; then
        echo "human stdout unexpectedly contains a robot envelope:" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Workflow fixtures
# ---------------------------------------------------------------------------

install_workflow_valid() {
    cd "$TEST_PROJECT"
    mkdir -p .apr/workflows .apr/rounds/default
    cat > .apr/config.yaml <<'YAML'
default_workflow: default
YAML
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Valid workflow for lint conformance
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
  Read the attached README.md and SPECIFICATION.md, then provide feedback.
template_with_impl: |
  Read the attached README.md and SPECIFICATION.md, then provide feedback.
YAML
    cat > README.md       <<<'# Lint test README'
    cat > SPECIFICATION.md <<<'# Lint test SPEC'
}

install_workflow_placeholder() {
    install_workflow_valid
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Workflow with placeholder leak (intentional)
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
  {{README}}
template_with_impl: |
  {{README}}
YAML
}

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
  readme: nope-readme.md
  spec: nope-spec.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
  Read attached docs.
YAML
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true
    log_test_start "${BATS_TEST_NAME}"
    cd "$TEST_PROJECT"
}

teardown() {
    [[ -d "$TEST_PROJECT/.apr" ]] && save_artifact "$TEST_PROJECT/.apr" "apr_dir"
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# Robot mode: full three-layer assertions
# ===========================================================================

@test "lint contract: robot lint in fresh dir → not_configured (exit 4)" {
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    assert_robot_failure "not_configured" 4
    jq -e '.data.valid == false'           "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.errors | length > 0'      "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.errors[0].code == "not_configured"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "lint contract: robot lint with placeholder leak → validation_failed (exit 4)" {
    install_workflow_placeholder
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    assert_robot_failure "validation_failed" 4

    # The structured error must surface the placeholder cause AND a
    # remediation hint with the documented bypass.
    jq -e '.data.errors | map(.code) | index("prompt_qc_failed") != null' \
        "$ARTIFACT_DIR/stdout.log" >/dev/null

    local hits
    hits=$(jq -r '.data.errors[] | select(.code == "prompt_qc_failed") | .hint' "$ARTIFACT_DIR/stdout.log")
    grep -Fq "APR_ALLOW_CURLY_PLACEHOLDERS=1" <<<"$hits" || {
        echo "expected bypass hint in placeholder error:" >&2
        echo "$hits" >&2
        return 1
    }
}

@test "lint contract: robot lint with missing documents → validation_failed (exit 4)" {
    install_workflow_missing_docs
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    assert_robot_failure "validation_failed" 4

    # Error messages must enumerate the missing-doc cause for both
    # readme and spec so the user sees both at once.
    local messages
    messages=$(jq -r '.data.errors[].message' "$ARTIFACT_DIR/stdout.log")
    grep -qi 'readme'  <<<"$messages" || { echo "no readme error: $messages" >&2; return 1; }
    grep -qi 'spec'    <<<"$messages" || { echo "no spec error: $messages" >&2; return 1; }
}

@test "lint contract: robot lint with valid workflow → ok (exit 0)" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    assert_exit 0
    assert_robot_envelope "true" "ok"

    # The "ok" envelope MUST report .data.valid=true and an empty errors array.
    jq -e '.data.valid == true'        "$ARTIFACT_DIR/stdout.log" >/dev/null
    jq -e '.data.errors | length == 0' "$ARTIFACT_DIR/stdout.log" >/dev/null

    # No APR_ERROR_CODE tag on success.
    if grep -Fq 'APR_ERROR_CODE=' "$ARTIFACT_DIR/stderr.log"; then
        echo "successful lint must not emit APR_ERROR_CODE tag:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi
}

@test "lint contract: robot lint without round arg is still valid (round optional)" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" robot lint
    # Note: contract is that robot lint may accept missing round (defaults
    # to no round-context check); the call should not emit usage_error.
    # If the engine evolves to require a round, switch this to:
    #     assert_robot_failure "usage_error" 2
    # The behavior on commit 595af44 is "ok" without a round arg.
    assert_exit 0
    assert_robot_envelope "true" "ok"
}

@test "lint contract: robot lint with --round and positional conflict → usage_error (exit 2)" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" robot lint --round 1 2
    assert_robot_failure "usage_error" 2

    # The robot envelope must enumerate the offending argument so callers
    # can self-correct without parsing the human hint string.
    jq -e '.data.argument == "round"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

# ===========================================================================
# Human mode: two-layer assertions (exit class + stderr tag, no JSON)
# ===========================================================================

@test "lint contract: human lint in fresh dir → APR_ERROR_CODE=not_configured + exit 4" {
    run_with_artifacts "$APR_SCRIPT" lint 1
    assert_human_failure "not_configured" 4
    grep -Fq "not_configured" "$ARTIFACT_DIR/stderr.log"
}

@test "lint contract: human lint with placeholder leak → APR_ERROR_CODE=validation_failed + exit 4" {
    install_workflow_placeholder
    run_with_artifacts "$APR_SCRIPT" lint 1
    assert_human_failure "validation_failed" 4

    # The human stderr must include the placeholder explanation and the
    # bypass hint so users can self-rescue.
    grep -Fq "unexpanded placeholders"          "$ARTIFACT_DIR/stderr.log"
    grep -Fq "APR_ALLOW_CURLY_PLACEHOLDERS=1"   "$ARTIFACT_DIR/stderr.log"
}

@test "lint contract: human lint with missing documents → APR_ERROR_CODE=validation_failed + exit 4" {
    install_workflow_missing_docs
    run_with_artifacts "$APR_SCRIPT" lint 1
    assert_human_failure "validation_failed" 4
    grep -qi "readme" "$ARTIFACT_DIR/stderr.log"
    grep -qi "spec"   "$ARTIFACT_DIR/stderr.log"
}

@test "lint contract: human lint with valid workflow → exit 0, no error tag" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" lint 1
    assert_exit 0
    if grep -Fq 'APR_ERROR_CODE=' "$ARTIFACT_DIR/stderr.log"; then
        echo "successful human lint must not emit APR_ERROR_CODE tag:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi
    grep -Fq "Lint passed" "$ARTIFACT_DIR/stderr.log"
}

@test "lint contract: human lint with too many args → APR_ERROR_CODE=usage_error + exit 2" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" lint 1 2 3
    assert_human_failure "usage_error" 2
    grep -Fq "Too many arguments" "$ARTIFACT_DIR/stderr.log"
}

@test "lint contract: human lint with --round + positional conflict → APR_ERROR_CODE=usage_error + exit 2" {
    install_workflow_valid
    run_with_artifacts "$APR_SCRIPT" lint --round 1 2
    assert_human_failure "usage_error" 2
    grep -Fq "Conflicting" "$ARTIFACT_DIR/stderr.log"
}

# ===========================================================================
# Cross-surface agreement (human ⟷ robot must report the same .code)
# ===========================================================================
#
# This is the load-bearing conformance property: for the same input, the
# code chosen by the human path (encoded in APR_ERROR_CODE=<code>) MUST
# equal the code chosen by the robot path (encoded in .code). If those
# ever diverge, downstream automation that parses one but not the other
# silently breaks.

@test "lint contract: human .code matches robot .code for not_configured" {
    # Same TEST_PROJECT, run both surfaces, extract the code from each,
    # compare.
    run_with_artifacts "$APR_SCRIPT" lint 1
    local human_code
    human_code=$(grep -oE 'APR_ERROR_CODE=[a-z_]+' "$ARTIFACT_DIR/stderr.log" | head -1 | cut -d= -f2)

    rm -rf "$TEST_PROJECT"/.apr 2>/dev/null || true
    local robot_dir="$ARTIFACT_DIR/robot"
    mkdir -p "$robot_dir"
    "$APR_SCRIPT" robot lint 1 >"$robot_dir/stdout.json" 2>"$robot_dir/stderr.log" || true
    local robot_code
    robot_code=$(jq -r '.code' "$robot_dir/stdout.json")

    [[ "$human_code" == "$robot_code" ]] || {
        echo "code drift: human='$human_code' robot='$robot_code'" >&2
        return 1
    }
    [[ "$human_code" == "not_configured" ]]
}

@test "lint contract: human .code matches robot .code for validation_failed (placeholder leak)" {
    install_workflow_placeholder

    run_with_artifacts "$APR_SCRIPT" lint 1
    local human_code
    human_code=$(grep -oE 'APR_ERROR_CODE=[a-z_]+' "$ARTIFACT_DIR/stderr.log" | head -1 | cut -d= -f2)

    local robot_dir="$ARTIFACT_DIR/robot"
    mkdir -p "$robot_dir"
    "$APR_SCRIPT" robot lint 1 >"$robot_dir/stdout.json" 2>"$robot_dir/stderr.log" || true
    local robot_code
    robot_code=$(jq -r '.code' "$robot_dir/stdout.json")

    [[ "$human_code" == "$robot_code" ]] || {
        echo "code drift: human='$human_code' robot='$robot_code'" >&2
        return 1
    }
    [[ "$human_code" == "validation_failed" ]]
}

@test "lint contract: human exit class matches robot exit class for every failure mode" {
    # For each fixture, run both surfaces and assert that the *exit
    # codes* agree exactly. This is one step stronger than just code
    # agreement: it pins apr_exit_code_for_code's mapping at the CLI
    # boundary on both paths.

    declare -A fixtures=(
        [empty]="not_configured"
        [placeholder]="validation_failed"
        [missing_docs]="validation_failed"
    )

    local case want_code human_rc robot_rc
    for case in empty placeholder missing_docs; do
        want_code="${fixtures[$case]}"

        rm -rf "$TEST_PROJECT"/.apr  2>/dev/null || true
        rm -f  "$TEST_PROJECT"/*.md  2>/dev/null || true
        case "$case" in
            empty)        : ;; # leave bare
            placeholder)  install_workflow_placeholder ;;
            missing_docs) install_workflow_missing_docs ;;
        esac

        # `set -e` is on inside bats tests; non-zero exits abort the
        # test before we can capture the code. Disable around the
        # capture pair, then restore.
        set +e
        "$APR_SCRIPT" lint 1       >/dev/null 2>&1; human_rc=$?
        "$APR_SCRIPT" robot lint 1 >/dev/null 2>&1; robot_rc=$?
        set -e

        [[ "$human_rc" -eq "$robot_rc" ]] || {
            echo "[$case] exit-class drift: human=$human_rc robot=$robot_rc (want code=$want_code)" >&2
            return 1
        }
    done
}

# ===========================================================================
# Stream discipline (G1/G2 from the UX QA matrix, scoped to lint)
# ===========================================================================

@test "lint contract: human lint writes diagnostics to stderr only (stdout empty on failure)" {
    install_workflow_placeholder
    run_with_artifacts "$APR_SCRIPT" lint 1
    [[ "$status" -ne 0 ]]
    [[ ! -s "$ARTIFACT_DIR/stdout.log" ]] || {
        echo "human lint failure leaked content to stdout:" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
}

@test "lint contract: robot lint writes JSON to stdout only (stderr only the tag)" {
    install_workflow_placeholder
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    [[ "$status" -ne 0 ]]

    # stdout is parseable JSON.
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null

    # stderr contains exactly the APR_ERROR_CODE tag (and possibly
    # nothing else). It must NOT contain a JSON envelope.
    if grep -Fq '"meta"' "$ARTIFACT_DIR/stderr.log"; then
        echo "robot stderr unexpectedly contains a JSON envelope:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    fi
    grep -qE '^APR_ERROR_CODE=' "$ARTIFACT_DIR/stderr.log"
}
