#!/usr/bin/env bats
# test_robot_golden.bats
#
# Bead automated_plan_reviser_pro-l7zu — golden-artifact baselines for
# the apr robot envelope surfaces that downstream automation parses:
# status, workflows, history, help, and init.
#
# Complements:
#   tests/integration/test_robot.bats        (contract / key-presence)
#   tests/integration/test_lint_golden.bats  (pvmh — robot lint goldens)
#
# A subtle drift in any of these envelopes (e.g. renaming a `data.*`
# key, reordering an array, changing a hint string) would slip past
# the existing contract tests but would absolutely break agents that
# parse the output by exact field name. This file freezes byte-exact
# baselines so those changes surface as inspectable diffs.
#
# Update workflow:
#   UPDATE_GOLDEN=1 tests/lib/bats-core/bin/bats \
#       tests/integration/test_robot_golden.bats
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

GOLDEN_ROOT() {
    echo "$BATS_TEST_DIRNAME/../fixtures/robot_goldens"
}

# scrub_robot <in> <out>
# Normalize the robot JSON envelope so it is reproducible:
#   - meta.{ts,v} stripped via jq
#   - absolute TEST_PROJECT path → <TEST_PROJECT>
#   - data.apr_home (host-specific) → <APR_HOME>
#   - any HOME prefix → <HOME>
#   - keys sorted via jq -S
scrub_robot() {
    local in="$1" out="$2"
    jq -S '
        (if (.meta // null) then .meta = (.meta | del(.ts, .v)) else . end)
        | walk(
            if type == "string" then
                gsub("'"$TEST_PROJECT"'"; "<TEST_PROJECT>")
                | gsub("'"$HOME"'"; "<HOME>")
            else .
            end
          )
        | (if (.data // null) and (.data.apr_home // null) then
            .data.apr_home = "<APR_HOME>"
          else . end)
    ' "$in" > "$out"
}

# golden_compare_robot <name>
golden_compare_robot() {
    local name="$1"
    local golden="$(GOLDEN_ROOT)/${name}.json"
    local actual_raw="$ARTIFACT_DIR/stdout.log"
    local actual="$ARTIFACT_DIR/${name}.scrubbed.json"
    scrub_robot "$actual_raw" "$actual"

    if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
        mkdir -p "$(dirname "$golden")"
        cp -- "$actual" "$golden"
        echo "[update-golden] wrote $golden" >&2
        return 0
    fi

    [[ -f "$golden" ]] || {
        echo "missing golden: $golden" >&2
        echo "refresh with: UPDATE_GOLDEN=1 bats tests/integration/test_robot_golden.bats" >&2
        return 1
    }

    if ! diff -u "$golden" "$actual" > "$ARTIFACT_DIR/${name}.diff" 2>&1; then
        echo "robot golden diff for $name:" >&2
        cat "$ARTIFACT_DIR/${name}.diff" >&2
        echo "refresh with: UPDATE_GOLDEN=1 bats tests/integration/test_robot_golden.bats" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Workflow fixture helpers
# ---------------------------------------------------------------------------

install_workflow() {
    cd "$TEST_PROJECT"
    mkdir -p .apr/workflows .apr/rounds/default
    cat > .apr/config.yaml <<'YAML'
default_workflow: default
YAML
    cat > .apr/workflows/default.yaml <<'YAML'
name: default
description: Golden-test workflow
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
# robot status — configured + unconfigured
# ===========================================================================

@test "golden: robot status (unconfigured) — full envelope shape pinned" {
    run_with_artifacts "$APR_SCRIPT" robot status
    [[ "$status" -eq 0 ]]
    golden_compare_robot "status_unconfigured"
}

@test "golden: robot status (configured with one workflow) — envelope reflects it" {
    install_workflow
    run_with_artifacts "$APR_SCRIPT" robot status
    [[ "$status" -eq 0 ]]
    golden_compare_robot "status_configured"
}

# ===========================================================================
# robot workflows — empty + populated
# ===========================================================================

@test "golden: robot workflows (no .apr) → not_configured envelope" {
    run_with_artifacts "$APR_SCRIPT" robot workflows
    [[ "$status" -eq 4 ]]
    golden_compare_robot "workflows_empty"
}

@test "golden: robot workflows (one workflow) — emits the workflow entry" {
    install_workflow
    run_with_artifacts "$APR_SCRIPT" robot workflows
    [[ "$status" -eq 0 ]]
    golden_compare_robot "workflows_populated"
}

# ===========================================================================
# robot history — configured, no rounds yet
# ===========================================================================

@test "golden: robot history (configured, no rounds) — empty rounds envelope" {
    install_workflow
    run_with_artifacts "$APR_SCRIPT" robot history
    # robot history returns validation_failed when no rounds dir exists,
    # ok when it does but is empty. With install_workflow we created
    # .apr/rounds/default, so the envelope should be ok with empty rounds.
    golden_compare_robot "history_empty"
}

# ===========================================================================
# robot help — documented command list (stable contract for agents)
# ===========================================================================

@test "golden: robot help — full command/options envelope" {
    run_with_artifacts "$APR_SCRIPT" robot help
    [[ "$status" -eq 0 ]]
    golden_compare_robot "help"
}

# ===========================================================================
# robot init — fresh dir
# ===========================================================================

@test "golden: robot init — fresh dir creates config and reports ok" {
    run_with_artifacts "$APR_SCRIPT" robot init
    [[ "$status" -eq 0 ]]
    golden_compare_robot "init_fresh"
    # Side effect: .apr/ exists after init.
    [[ -d "$TEST_PROJECT/.apr" ]]
}

# ===========================================================================
# Structural invariants on the goldens themselves
# ===========================================================================

@test "golden: every .json golden is valid JSON with envelope shape" {
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        jq -e . "$f" >/dev/null || { echo "$f is not JSON" >&2; return 1; }
        # Every robot envelope must have ok/code/data.
        jq -e '.ok | type == "boolean"'             "$f" >/dev/null
        jq -e '.code | type == "string" and length > 0' "$f" >/dev/null
        jq -e '.data | type == "object"'            "$f" >/dev/null
    done < <(find "$root" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

@test "golden: no golden leaks an unscrubbed absolute tempdir path" {
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        if grep -Eq '/tmp/apr_test\.[A-Za-z0-9]+' "$f"; then
            echo "golden $f contains an unscrubbed tempdir path:" >&2
            grep -E '/tmp/apr_test\.[A-Za-z0-9]+' "$f" >&2
            return 1
        fi
    done < <(find "$root" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

@test "golden: no golden leaks an unscrubbed user home path" {
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        if grep -Eq '/home/[^"<]+' "$f"; then
            echo "golden $f contains an unscrubbed home path:" >&2
            grep -E '/home/[^"<]+' "$f" >&2
            return 1
        fi
    done < <(find "$root" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

@test "golden: every committed golden has a meta block that survives sort_keys round-trip" {
    # Round-trip the golden through `jq -S` (sort keys) and assert the
    # output is byte-identical. If a future generator writes keys in a
    # different order, this surfaces it.
    local root="$(GOLDEN_ROOT)"
    local f
    while IFS= read -r -d '' f; do
        local resorted="$ARTIFACT_DIR/resorted_$(basename "$f")"
        jq -S . "$f" > "$resorted"
        diff -q "$f" "$resorted" > /dev/null || {
            echo "$f is not sort_keys-stable:" >&2
            diff -u "$f" "$resorted" >&2
            return 1
        }
    done < <(find "$root" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}
