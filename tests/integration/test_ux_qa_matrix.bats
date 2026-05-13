#!/usr/bin/env bats
# test_ux_qa_matrix.bats
#
# Bead automated_plan_reviser_pro-ulu.11 — UX QA Matrix + Visual Regression
#
# Mechanical enforcement of the rows in tests/UX_QA_MATRIX.md that can be
# checked from a non-interactive subprocess. Rows that can only be eyeballed
# (gum spinners, color palette on real terminals) are documented in the
# matrix as "manual" and are out of scope here.
#
# Categories asserted:
#   G  - Global stream / color / gum / tag / exit-class invariants
#   L  - Layout-mode invariants (--compact vs --desktop equivalence)
#   C  - Per-command stdout/stderr/exit shape
#   R  - Robot envelope contract on a representative cross-section
#
# Test names are prefixed `ux: <category>NN ...` so the matrix and the
# bats output line up 1:1 when grepping.
#
# Every test drops a timestamped artifact directory under
# tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# scrub_meta - strip non-deterministic fields (.meta.ts, .meta.v) so two
# robot envelopes can be diffed byte-for-byte.
scrub_meta() {
    jq -S 'walk(if type == "object" and has("meta") then .meta = {} else . end)'
}

# assert_no_ansi - fail if file contains any CSI escape sequence.
assert_no_ansi() {
    local f="$1"
    # ESC ('\033') followed by '['. Use perl for portable byte-level grep.
    if perl -ne 'exit 0 if /\x1b\[/; END { exit 1 }' "$f" 2>/dev/null; then
        echo "ANSI escape sequence found in $f:" >&2
        cat -v "$f" | head -5 >&2
        return 1
    fi
}

# assert_valid_robot_envelope - structure assertions per matrix §4.
#
# Args: $1=path-to-json $2=expected-ok ("true"|"false") $3=expected-code
assert_valid_robot_envelope() {
    local json="$1" want_ok="$2" want_code="$3"

    jq -e '.ok | type == "boolean"' "$json" >/dev/null
    jq -e '.code | type == "string" and length > 0' "$json" >/dev/null
    jq -e '.data | type == "object"' "$json" >/dev/null
    jq -e '.meta.v | type == "string" and length > 0' "$json" >/dev/null
    jq -e '.meta.ts | type == "string" and length > 0' "$json" >/dev/null

    [[ "$(jq -r '.ok' "$json")"   == "$want_ok"   ]] || {
        echo "ok mismatch: want=$want_ok got=$(jq -r '.ok' "$json")" >&2
        return 1
    }
    [[ "$(jq -r '.code' "$json")" == "$want_code" ]] || {
        echo "code mismatch: want=$want_code got=$(jq -r '.code' "$json")" >&2
        return 1
    }

    # If this is a failure envelope, .hint should be present.
    if [[ "$want_ok" == "false" ]]; then
        jq -e '.hint | type == "string" and length > 0' "$json" >/dev/null || {
            echo "failure envelope missing .hint" >&2
            cat "$json" >&2
            return 1
        }
    fi
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    # The harness MUST always run with deterministic flags. Each test can
    # opt back in by exporting otherwise.
    export NO_COLOR=1
    export APR_NO_GUM=1
    export CI=true
    unset APR_LAYOUT 2>/dev/null || true

    log_test_start "${BATS_TEST_NAME}"
    cd "$TEST_PROJECT"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =====================================================================
# G — Global invariants
# =====================================================================

@test "ux: G1 apr --help routes human output to stderr (stdout empty)" {
    run_with_artifacts "$APR_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    [[ ! -s "$ARTIFACT_DIR/stdout.log" ]] || {
        echo "stdout was non-empty for --help:" >&2
        head -10 "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    }
    [[ -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "ux: G1 apr list (unconfigured) routes human output to stderr only" {
    run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]
    [[ ! -s "$ARTIFACT_DIR/stdout.log" ]]
    [[ -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "ux: G2 apr --version writes the version line on stdout (stderr empty)" {
    run_with_artifacts "$APR_SCRIPT" --version
    [[ "$status" -eq 0 ]]
    grep -Eq '^apr version [0-9]+\.[0-9]+\.[0-9]+' "$ARTIFACT_DIR/stdout.log"
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]] || {
        echo "stderr was non-empty for --version:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

@test "ux: G2 apr robot help puts JSON on stdout and nothing on stderr" {
    run_with_artifacts "$APR_SCRIPT" robot help
    [[ "$status" -eq 0 ]]
    jq -e . "$ARTIFACT_DIR/stdout.log" >/dev/null
    [[ ! -s "$ARTIFACT_DIR/stderr.log" ]]
}

@test "ux: G3 NO_COLOR=1 strips ANSI from apr --help" {
    run_with_artifacts "$APR_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    assert_no_ansi "$ARTIFACT_DIR/stdout.log"
    assert_no_ansi "$ARTIFACT_DIR/stderr.log"
}

@test "ux: G3 NO_COLOR=1 strips ANSI from apr list (unconfigured)" {
    run_with_artifacts "$APR_SCRIPT" list
    assert_no_ansi "$ARTIFACT_DIR/stdout.log"
    assert_no_ansi "$ARTIFACT_DIR/stderr.log"
}

@test "ux: G3 NO_COLOR=1 strips ANSI from a robot-mode error envelope" {
    run_with_artifacts "$APR_SCRIPT" robot validate
    [[ "$status" -eq 2 ]]
    assert_no_ansi "$ARTIFACT_DIR/stdout.log"
    assert_no_ansi "$ARTIFACT_DIR/stderr.log"
}

@test "ux: G4 APR_NO_GUM=1 leaves no gum decorations in help output" {
    # `gum` writes cursor-position escapes even with NO_COLOR set; the
    # APR_NO_GUM=1 setup in `setup` should bypass gum entirely so the
    # output is plain text.
    run_with_artifacts "$APR_SCRIPT" --help
    assert_no_ansi "$ARTIFACT_DIR/stderr.log"
}

@test "ux: G6 fatal usage error emits APR_ERROR_CODE on stderr" {
    run_with_artifacts "$APR_SCRIPT" robot definitely-not-a-command
    [[ "$status" -eq 2 ]]
    grep -Fq "APR_ERROR_CODE=usage_error" "$ARTIFACT_DIR/stderr.log"
}

@test "ux: G7 exit codes match documented taxonomy" {
    # Pin the four exit-code classes most surfaced by interactive use.
    # Network/update/busy classes are covered by their dedicated suites.
    run_with_artifacts "$APR_SCRIPT" --version
    [[ "$status" -eq 0 ]]

    run_with_artifacts "$APR_SCRIPT" robot definitely-not-a-command
    [[ "$status" -eq 2 ]]

    PATH=/usr/bin:/bin APR_NO_NPX=1 \
        run_with_artifacts "$APR_SCRIPT" robot run 1
    # Stripped PATH + APR_NO_NPX disables the npx fallback so the
    # dependency check actually fails. Exit 3 = EXIT_DEPENDENCY_ERROR.
    [[ "$status" -eq 3 ]]

    run_with_artifacts "$APR_SCRIPT" robot validate 1
    # No .apr/ in TEST_PROJECT → not_configured → exit 4 (config class).
    [[ "$status" -eq 4 ]]
}

# =====================================================================
# L — Layout-mode invariants
# =====================================================================

@test "ux: L1 --compact selects compact layout and runs list successfully" {
    run_with_artifacts "$APR_SCRIPT" --compact list
    [[ "$status" -eq 0 ]]
}

@test "ux: L2 --desktop selects desktop layout and runs list successfully" {
    run_with_artifacts "$APR_SCRIPT" --desktop list
    [[ "$status" -eq 0 ]]
}

@test "ux: L4 --layout zigzag fails with usage_error + exit 2" {
    run_with_artifacts "$APR_SCRIPT" --layout zigzag list
    [[ "$status" -eq 2 ]]
    grep -Fq "APR_ERROR_CODE=usage_error" "$ARTIFACT_DIR/stderr.log"
}

@test "ux: L5 robot help is byte-identical between --compact and --desktop (modulo .meta)" {
    local compact_dir="$ARTIFACT_DIR/compact"
    local desktop_dir="$ARTIFACT_DIR/desktop"
    mkdir -p "$compact_dir" "$desktop_dir"

    "$APR_SCRIPT" --compact robot help > "$compact_dir/stdout.json" 2> "$compact_dir/stderr.log"
    "$APR_SCRIPT" --desktop robot help > "$desktop_dir/stdout.json" 2> "$desktop_dir/stderr.log"

    # Stderr must be empty in both cases (robot mode).
    [[ ! -s "$compact_dir/stderr.log" ]]
    [[ ! -s "$desktop_dir/stderr.log" ]]

    local compact_scrubbed desktop_scrubbed
    compact_scrubbed="$compact_dir/scrubbed.json"
    desktop_scrubbed="$desktop_dir/scrubbed.json"
    scrub_meta < "$compact_dir/stdout.json" > "$compact_scrubbed"
    scrub_meta < "$desktop_dir/stdout.json" > "$desktop_scrubbed"

    diff -u "$compact_scrubbed" "$desktop_scrubbed" || {
        echo "robot help diverges between layouts (post-meta scrub)" >&2
        return 1
    }
}

@test "ux: L5 robot status (unconfigured) is byte-identical between layouts" {
    local compact_dir="$ARTIFACT_DIR/compact"
    local desktop_dir="$ARTIFACT_DIR/desktop"
    mkdir -p "$compact_dir" "$desktop_dir"

    "$APR_SCRIPT" --compact robot status > "$compact_dir/stdout.json" 2>/dev/null
    "$APR_SCRIPT" --desktop robot status > "$desktop_dir/stdout.json" 2>/dev/null

    scrub_meta < "$compact_dir/stdout.json" > "$compact_dir/scrubbed.json"
    scrub_meta < "$desktop_dir/stdout.json" > "$desktop_dir/scrubbed.json"

    diff -u "$compact_dir/scrubbed.json" "$desktop_dir/scrubbed.json" || return 1
}

@test "ux: L6 --help lists every documented top-level command in both layouts" {
    # The set of advertised commands must not silently drop between layouts.
    local cmds=(run setup status attach list history show backfill update help diff integrate stats dashboard robot)

    local layout
    for layout in compact desktop; do
        local out="$ARTIFACT_DIR/help_${layout}.txt"
        "$APR_SCRIPT" "--$layout" --help 2> "$out" 1> /dev/null || true

        local cmd
        for cmd in "${cmds[@]}"; do
            grep -Eq "^\s+$cmd\b" "$out" || {
                echo "help in $layout mode missing command '$cmd':" >&2
                cat "$out" >&2
                return 1
            }
        done
    done
}

# =====================================================================
# C — Per-command shape
# =====================================================================

@test "ux: C-version stdout matches 'apr version <semver>' exactly" {
    run_with_artifacts "$APR_SCRIPT" --version
    [[ "$status" -eq 0 ]]
    # Single line, semver-shaped.
    [[ "$(wc -l < "$ARTIFACT_DIR/stdout.log")" -eq 1 ]]
    grep -Eq '^apr version [0-9]+\.[0-9]+\.[0-9]+([-.A-Za-z0-9]+)?$' "$ARTIFACT_DIR/stdout.log"
}

@test "ux: C-help advertises all the documented exit codes" {
    run_with_artifacts "$APR_SCRIPT" --help
    [[ "$status" -eq 0 ]]
    local codes=(
        "0   Success"
        "1   Partial failure"
        "2   Usage error"
        "3   Dependency error"
        "4   Configuration error"
        "10  Network error"
        "11  Update error"
        "12  Busy"
    )
    local line
    for line in "${codes[@]}"; do
        grep -Fq "$line" "$ARTIFACT_DIR/stderr.log" || {
            echo "help missing exit-code row: '$line'" >&2
            return 1
        }
    done
}

@test "ux: C-help advertises the APR_ERROR_CODE tag convention" {
    run_with_artifacts "$APR_SCRIPT" --help
    grep -Fq "APR_ERROR_CODE=" "$ARTIFACT_DIR/stderr.log"
}

@test "ux: C-list (unconfigured) directs the user toward 'apr setup'" {
    run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]
    grep -Fq "apr setup" "$ARTIFACT_DIR/stderr.log"
}

# =====================================================================
# R — Robot envelope contract
# =====================================================================

@test "ux: R envelope: robot help is a valid ok envelope" {
    run_with_artifacts "$APR_SCRIPT" robot help
    [[ "$status" -eq 0 ]]
    assert_valid_robot_envelope "$ARTIFACT_DIR/stdout.log" "true" "ok"
    # And it documents the commands.
    jq -e '.data.commands | type == "object"' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "ux: R envelope: robot status (unconfigured) is a valid ok envelope with configured=false" {
    run_with_artifacts "$APR_SCRIPT" robot status
    [[ "$status" -eq 0 ]]
    assert_valid_robot_envelope "$ARTIFACT_DIR/stdout.log" "true" "ok"
    jq -e '.data.configured == false' "$ARTIFACT_DIR/stdout.log" >/dev/null
}

@test "ux: R envelope: robot validate (no round) is a valid usage_error envelope" {
    run_with_artifacts "$APR_SCRIPT" robot validate
    [[ "$status" -eq 2 ]]
    assert_valid_robot_envelope "$ARTIFACT_DIR/stdout.log" "false" "usage_error"
}

@test "ux: R envelope: robot validate 1 (no .apr) is a valid not_configured envelope" {
    run_with_artifacts "$APR_SCRIPT" robot validate 1
    [[ "$status" -eq 4 ]]
    assert_valid_robot_envelope "$ARTIFACT_DIR/stdout.log" "false" "not_configured"
}

@test "ux: R envelope: robot run 1 (no oracle) is a valid dependency_missing envelope" {
    PATH=/usr/bin:/bin APR_NO_NPX=1 \
        run_with_artifacts "$APR_SCRIPT" robot run 1
    [[ "$status" -eq 3 ]]
    assert_valid_robot_envelope "$ARTIFACT_DIR/stdout.log" "false" "dependency_missing"
}

@test "ux: R envelope: meta.v matches the on-disk VERSION file" {
    local expected
    expected=$(grep -m1 '^VERSION=' "$APR_SCRIPT" | sed -E 's/.*"([^"]+)".*/\1/')

    run_with_artifacts "$APR_SCRIPT" robot help
    [[ "$status" -eq 0 ]]
    local got
    got=$(jq -r '.meta.v' "$ARTIFACT_DIR/stdout.log")
    [[ "$got" == "$expected" ]] || {
        echo "meta.v drift: want=$expected got=$got" >&2
        return 1
    }
}

@test "ux: R envelope: meta.ts is an RFC3339 UTC timestamp" {
    run_with_artifacts "$APR_SCRIPT" robot help
    local ts
    ts=$(jq -r '.meta.ts' "$ARTIFACT_DIR/stdout.log")
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        echo "meta.ts is not RFC3339 UTC: '$ts'" >&2
        return 1
    }
}
