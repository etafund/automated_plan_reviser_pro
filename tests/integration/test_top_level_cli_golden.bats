#!/usr/bin/env bats
# test_top_level_cli_golden.bats
#
# Bead automated_plan_reviser_pro-i125 — golden-artifact baselines for
# the top-level user-facing CLI surfaces.
#
# Complements:
#   tests/integration/test_ux_qa_matrix.bats   (grep-level contract)
#   tests/integration/test_lint_golden.bats    (pvmh — lint goldens)
#   tests/integration/test_robot_golden.bats   (l7zu — robot envelopes)
#
# A subtle wording change in `apr --help` — renaming a flag, dropping
# a command from the documented list, rewording an exit-code description
# — would slip past the existing grep-level matrix while breaking
# agents that parse the output. This file freezes byte-exact baselines.
#
# Update workflow:
#   UPDATE_GOLDEN=1 tests/lib/bats-core/bin/bats \
#       tests/integration/test_top_level_cli_golden.bats
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

GOLDEN_ROOT() {
    echo "$BATS_TEST_DIRNAME/../fixtures/top_level_goldens"
}

scrub_stream() {
    # Args: <in> <out>
    # Normalize the captured stream so the golden is reproducible:
    #   - apr writes a leading version banner; replace the embedded
    #     semver with <VERSION> so a v1.2.2 → v1.2.3 bump doesn't
    #     blow up every golden in the same PR.
    local in="$1" out="$2"
    sed -E 's/(APR v)[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*/\1<VERSION>/g; s/(apr version )[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*/\1<VERSION>/g' "$in" > "$out"
}

golden_compare() {
    # Args: <name> <stream: stdout|stderr>
    local name="$1" stream="$2"
    local golden="$(GOLDEN_ROOT)/${name}.${stream}.txt"
    local actual_raw="$ARTIFACT_DIR/${stream}.log"
    local actual="$ARTIFACT_DIR/${name}.${stream}.scrubbed.txt"
    scrub_stream "$actual_raw" "$actual"

    if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
        mkdir -p "$(dirname "$golden")"
        cp -- "$actual" "$golden"
        echo "[update-golden] wrote $golden" >&2
        return 0
    fi

    [[ -f "$golden" ]] || {
        echo "missing golden: $golden" >&2
        echo "refresh with: UPDATE_GOLDEN=1 bats $BATS_TEST_FILENAME" >&2
        return 1
    }

    if ! diff -u "$golden" "$actual" > "$ARTIFACT_DIR/${name}.${stream}.diff" 2>&1; then
        echo "golden diff for $name (stream=$stream):" >&2
        cat "$ARTIFACT_DIR/${name}.${stream}.diff" >&2
        echo "refresh with: UPDATE_GOLDEN=1 bats $BATS_TEST_FILENAME" >&2
        return 1
    fi
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
# Goldens
# ===========================================================================

@test "golden: apr --help — stderr help body is byte-stable (modulo version)" {
    run_with_artifacts "$APR_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    # apr --help is routed to stderr (human surface).
    [[ ! -s "$ARTIFACT_DIR/stdout.log" ]]
    golden_compare "apr_help_long" "stderr"
}

@test "golden: apr --version — single-line stdout output (modulo version)" {
    run_with_artifacts "$APR_SCRIPT" --version
    [[ "$status" -eq 0 ]]
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
    golden_compare "apr_version" "stdout"
}

@test "golden: apr -V — short version flag matches --version exactly" {
    run_with_artifacts "$APR_SCRIPT" -V
    [[ "$status" -eq 0 ]]
    # Compare the scrubbed -V output against the --version golden
    # directly (no separate golden file: -V is documented as an alias).
    local actual="$ARTIFACT_DIR/v_short.txt"
    scrub_stream "$ARTIFACT_DIR/stdout.log" "$actual"
    diff -u "$(GOLDEN_ROOT)/apr_version.stdout.txt" "$actual" || return 1
}

@test "golden: apr -h — short help flag matches --help exactly" {
    run_with_artifacts "$APR_SCRIPT" -h
    [[ "$status" -eq 0 ]]
    local actual="$ARTIFACT_DIR/h_short.txt"
    scrub_stream "$ARTIFACT_DIR/stderr.log" "$actual"
    diff -u "$(GOLDEN_ROOT)/apr_help_long.stderr.txt" "$actual" || return 1
}

# ===========================================================================
# Structural invariants on the goldens themselves
# ===========================================================================

@test "golden: --help short summary advertises the core command set" {
    # The dispatcher case-statement in apr's main() is the source of
    # truth for commands. The short --help summary lists the
    # user-facing top-level commands; we pin the core set (the ones
    # that have been in the help for the entire ulu epic).
    local golden="$(GOLDEN_ROOT)/apr_help_long.stderr.txt"
    local cmds=(run setup status attach list history show backfill stats dashboard)
    local missing=()
    local c
    for c in "${cmds[@]}"; do
        grep -Eq "\\b$c\\b" "$golden" || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "commands not advertised in --help golden:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "golden: --help short summary points at 'apr help --detailed' for full docs" {
    # The short summary explicitly tells users where to find the long
    # help. Pin that footer so a refactor that moves it doesn't leave
    # users stranded.
    local golden="$(GOLDEN_ROOT)/apr_help_long.stderr.txt"
    grep -Fq "apr help --detailed" "$golden" || {
        echo "short --help golden does not point to the detailed help" >&2
        return 1
    }
}

@test "golden: --version golden is a single semver line in 'apr version <VERSION>' shape" {
    local golden="$(GOLDEN_ROOT)/apr_version.stdout.txt"
    # Exactly one line.
    [[ "$(wc -l < "$golden")" -eq 1 ]]
    # The line is the scrubbed canonical shape.
    grep -Eq '^apr version <VERSION>$' "$golden" || {
        echo "--version golden drift: $(cat "$golden")" >&2
        return 1
    }
}

@test "golden: --help golden has the documented SYNOPSIS/COMMANDS structure" {
    local golden="$(GOLDEN_ROOT)/apr_help_long.stderr.txt"
    grep -Eq '^SYNOPSIS$' "$golden" || { echo "missing SYNOPSIS section" >&2; return 1; }
    grep -Eq '^COMMANDS$' "$golden" || { echo "missing COMMANDS section" >&2; return 1; }
    grep -Eq '^APR v<VERSION>$' "$golden" || { echo "missing version banner" >&2; return 1; }
}
