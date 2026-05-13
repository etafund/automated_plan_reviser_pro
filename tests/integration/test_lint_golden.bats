#!/usr/bin/env bats
# test_lint_golden.bats
#
# Bead automated_plan_reviser_pro-pvmh — golden-artifact baselines for
# `apr lint` (human) and `apr robot lint`.
#
# Complements tests/integration/test_lint_contract.bats (grs9), which
# pins the three-layer contract (exit / .code / stderr tag) but does
# NOT pin the actual output text. A small refactor that subtly changes
# a hint string or reorders the errors[] array would pass the contract
# suite but might break downstream automation that parses the output.
# This file freezes byte-exact baselines so any drift surfaces as an
# inspectable golden diff.
#
# Update workflow:
#   UPDATE_GOLDEN=1 tests/lib/bats-core/bin/bats \
#       tests/integration/test_lint_golden.bats
# regenerates every baseline. Reviewers see the diff in the PR.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

GOLDEN_ROOT() {
    echo "$BATS_TEST_DIRNAME/../fixtures/lint_goldens"
}

# scrub_human <in> <out>  - normalize the human-mode lint stderr.
# Replaces non-deterministic absolute paths (the per-test TEST_PROJECT
# tempdir) with a stable placeholder so the golden is reproducible.
scrub_human() {
    local in="$1" out="$2"
    sed "s#$TEST_PROJECT#<TEST_PROJECT>#g" "$in" > "$out"
}

# scrub_robot <in> <out>  - normalize the robot-mode JSON envelope.
# Strips meta.{v,ts} and rewrites absolute paths under TEST_PROJECT.
scrub_robot() {
    local in="$1" out="$2"
    jq -S '
        .meta = (.meta // {} | del(.ts, .v))
        | walk(if type == "string" then gsub("'"$TEST_PROJECT"'"; "<TEST_PROJECT>") else . end)
    ' "$in" > "$out"
}

# golden_compare_human <name>  - diff scrubbed human stderr vs the
# golden, or refresh under UPDATE_GOLDEN=1.
golden_compare_human() {
    local name="$1"
    local golden="$(GOLDEN_ROOT)/${name}.human.stderr.txt"
    local actual_raw="$ARTIFACT_DIR/stderr.log"
    local actual="$ARTIFACT_DIR/${name}.human.scrubbed.txt"
    scrub_human "$actual_raw" "$actual"

    if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
        mkdir -p "$(dirname "$golden")"
        cp -- "$actual" "$golden"
        echo "[update-golden] wrote $golden" >&2
        return 0
    fi

    [[ -f "$golden" ]] || {
        echo "missing golden: $golden" >&2
        echo "refresh with: UPDATE_GOLDEN=1 bats tests/integration/test_lint_golden.bats" >&2
        return 1
    }
    diff -u "$golden" "$actual" > "$ARTIFACT_DIR/${name}.human.diff" 2>&1 || {
        echo "human golden diff for $name:" >&2
        cat "$ARTIFACT_DIR/${name}.human.diff" >&2
        return 1
    }
}

# golden_compare_robot <name>
golden_compare_robot() {
    local name="$1"
    local golden="$(GOLDEN_ROOT)/${name}.robot.json"
    local actual_raw="$ARTIFACT_DIR/stdout.log"
    local actual="$ARTIFACT_DIR/${name}.robot.scrubbed.json"
    scrub_robot "$actual_raw" "$actual"

    if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
        mkdir -p "$(dirname "$golden")"
        cp -- "$actual" "$golden"
        echo "[update-golden] wrote $golden" >&2
        return 0
    fi

    [[ -f "$golden" ]] || {
        echo "missing golden: $golden" >&2
        return 1
    }
    diff -u "$golden" "$actual" > "$ARTIFACT_DIR/${name}.robot.diff" 2>&1 || {
        echo "robot golden diff for $name:" >&2
        cat "$ARTIFACT_DIR/${name}.robot.diff" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# Workflow fixtures (kept inline so the golden test file is self-contained)
# ---------------------------------------------------------------------------

install_workflow_healthy() {
    cd "$TEST_PROJECT"
    mkdir -p .apr/workflows .apr/rounds/default
    cat > .apr/config.yaml <<'YAML'
default_workflow: default
YAML
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
  Read the attached README.md and SPECIFICATION.md.
YAML
    printf '# r\n' > README.md
    printf '# s\n' > SPECIFICATION.md
}

install_workflow_placeholder_leak() {
    install_workflow_healthy
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/default
template: |
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
documents:
  readme: nope-README.md
  spec: nope-SPECIFICATION.md
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
    export NO_COLOR=1 APR_NO_GUM=1 CI=true
    log_test_start "${BATS_TEST_NAME}"
    cd "$TEST_PROJECT"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# Human-mode goldens
# ===========================================================================

@test "golden: human lint healthy workflow → 'Lint passed' (exit 0)" {
    install_workflow_healthy
    run_with_artifacts "$APR_SCRIPT" lint 1
    [[ "$status" -eq 0 ]]
    golden_compare_human "healthy"
}

@test "golden: human lint placeholder leak → validation_failed (exit 4)" {
    install_workflow_placeholder_leak
    run_with_artifacts "$APR_SCRIPT" lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_human "placeholder_leak"
}

@test "golden: human lint missing docs → validation_failed (exit 4)" {
    install_workflow_missing_docs
    run_with_artifacts "$APR_SCRIPT" lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_human "missing_docs"
}

@test "golden: human lint in fresh dir → not_configured (exit 4)" {
    # No .apr/ at all.
    run_with_artifacts "$APR_SCRIPT" lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_human "not_configured"
}

@test "golden: human lint with conflicting --round → usage_error (exit 2)" {
    install_workflow_healthy
    run_with_artifacts "$APR_SCRIPT" lint --round 1 2
    [[ "$status" -eq 2 ]]
    golden_compare_human "round_conflict"
}

# ===========================================================================
# Robot-mode goldens
# ===========================================================================

@test "golden: robot lint healthy workflow → ok envelope (exit 0)" {
    install_workflow_healthy
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    [[ "$status" -eq 0 ]]
    golden_compare_robot "healthy"
}

@test "golden: robot lint placeholder leak → validation_failed envelope" {
    install_workflow_placeholder_leak
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_robot "placeholder_leak"
}

@test "golden: robot lint missing docs → validation_failed envelope" {
    install_workflow_missing_docs
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_robot "missing_docs"
}

@test "golden: robot lint in fresh dir → not_configured envelope" {
    run_with_artifacts "$APR_SCRIPT" robot lint 1
    [[ "$status" -eq 4 ]]
    golden_compare_robot "not_configured"
}

@test "golden: robot lint with conflicting --round → usage_error envelope" {
    install_workflow_healthy
    run_with_artifacts "$APR_SCRIPT" robot lint --round 1 2
    [[ "$status" -eq 2 ]]
    golden_compare_robot "round_conflict"
}

# ===========================================================================
# Structural invariants on the goldens themselves
# ===========================================================================

@test "golden: every .human.stderr.txt has a sibling .robot.json (and vice versa)" {
    local root
    root="$(GOLDEN_ROOT)"

    local missing_robot=() missing_human=()
    local f base
    while IFS= read -r -d '' f; do
        base="${f##*/}"
        base="${base%.human.stderr.txt}"
        [[ -f "$root/$base.robot.json" ]] || missing_robot+=("$base")
    done < <(find "$root" -maxdepth 1 -type f -name '*.human.stderr.txt' -print0 2>/dev/null)

    while IFS= read -r -d '' f; do
        base="${f##*/}"
        base="${base%.robot.json}"
        [[ -f "$root/$base.human.stderr.txt" ]] || missing_human+=("$base")
    done < <(find "$root" -maxdepth 1 -type f -name '*.robot.json' -print0 2>/dev/null)

    if (( ${#missing_robot[@]} + ${#missing_human[@]} > 0 )); then
        echo "human goldens missing robot counterparts:" >&2
        printf '  %s\n' "${missing_robot[@]}" >&2
        echo "robot goldens missing human counterparts:" >&2
        printf '  %s\n' "${missing_human[@]}" >&2
        return 1
    fi
}

@test "golden: every robot.json is valid JSON with the expected shape" {
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        jq -e . "$f" >/dev/null || {
            echo "golden $f is not valid JSON" >&2
            return 1
        }
        # Every robot envelope must have ok/code/data/meta.
        jq -e '.ok | type == "boolean"' "$f" >/dev/null
        jq -e '.code | type == "string" and length > 0' "$f" >/dev/null
        jq -e '.data | type == "object"' "$f" >/dev/null
        jq -e '.meta | type == "object"' "$f" >/dev/null
    done < <(find "$root" -maxdepth 1 -type f -name '*.robot.json' -print0 2>/dev/null)
}

@test "golden: no .human.stderr.txt golden leaks a TEST_PROJECT absolute path" {
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        # The scrubber rewrites $TEST_PROJECT → <TEST_PROJECT>, so any
        # `/tmp/apr_test.*` substring is a scrub miss.
        if grep -Eq '/tmp/apr_test\.[A-Za-z0-9]+' "$f"; then
            echo "golden $f contains an unscrubbed tempdir path:" >&2
            grep -E '/tmp/apr_test\.[A-Za-z0-9]+' "$f" >&2
            return 1
        fi
    done < <(find "$root" -maxdepth 1 -type f -name '*.human.stderr.txt' -print0 2>/dev/null)
}
