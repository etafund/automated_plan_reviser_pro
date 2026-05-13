#!/usr/bin/env bats
# test_errors.bats
#
# Bead automated_plan_reviser_pro-lyop — unit + conformance suite for
# lib/errors.sh, the canonical home of APR's error taxonomy.
#
# Why this file exists:
#   - apr/cli + lib code reference these taxonomy helpers everywhere.
#   - Until now they were exercised only transitively through CLI tests,
#     which means a refactor inside lib/errors.sh could quietly drop a
#     branch and still pass the higher-level suites.
#   - This file pins every public function directly AND asserts a
#     conformance layer across helpers ("the set of codes is closed":
#     emit ↔ is_error_code ↔ exit_class ↔ meaning ↔ table).
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # Source lib/errors.sh directly so we exercise the real functions.
    # Don't pre-set the EXIT_* constants — several tests rely on the
    # default fallbacks inside apr_exit_code_for_code, and a few
    # explicitly override.
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/errors.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# The documented taxonomy, frozen here. If lib/errors.sh adds/removes a
# code, this list MUST be updated — and any caller that depends on the
# old set will surface as a failure in this file.
# ---------------------------------------------------------------------------

DOCUMENTED_CODES=(
    ok
    usage_error
    not_configured
    config_error
    validation_failed
    dependency_missing
    busy
    network_error
    update_error
    attachment_mismatch
    not_implemented
    internal_error
)

# Documented exit-class mapping (mirrors apr_exit_code_for_code with the
# default EXIT_* fallbacks; explicit env overrides are exercised below).
DOCUMENTED_EXITS=(
    "ok=0"
    "usage_error=2"
    "dependency_missing=3"
    "not_configured=4"
    "config_error=4"
    "validation_failed=4"
    "attachment_mismatch=4"
    "network_error=10"
    "update_error=11"
    "busy=12"
    "not_implemented=1"
    "internal_error=1"
)

# ===========================================================================
# apr_error_codes
# ===========================================================================

@test "apr_error_codes: emits exactly the documented set, one per line" {
    run apr_error_codes
    [[ "$status" -eq 0 ]]

    # Capture into an array for stable comparison.
    local -a got
    mapfile -t got <<<"$output"

    [[ "${#got[@]}" -eq "${#DOCUMENTED_CODES[@]}" ]] || {
        echo "code count drift: want=${#DOCUMENTED_CODES[@]} got=${#got[@]}" >&2
        echo "documented:" >&2; printf '  %s\n' "${DOCUMENTED_CODES[@]}" >&2
        echo "got:"        >&2; printf '  %s\n' "${got[@]}"               >&2
        return 1
    }

    local i
    for i in "${!DOCUMENTED_CODES[@]}"; do
        [[ "${got[$i]}" == "${DOCUMENTED_CODES[$i]}" ]] || {
            echo "drift at position $i: want='${DOCUMENTED_CODES[$i]}' got='${got[$i]}'" >&2
            return 1
        }
    done
}

# ===========================================================================
# apr_is_error_code
# ===========================================================================

@test "apr_is_error_code: accepts every documented code" {
    local code
    for code in "${DOCUMENTED_CODES[@]}"; do
        apr_is_error_code "$code" || {
            echo "apr_is_error_code rejected documented code '$code'" >&2
            return 1
        }
    done
}

@test "apr_is_error_code: rejects unknown / empty / whitespace codes" {
    local bogus
    for bogus in "definitely-not" "" " " "OK" "Usage_Error" "" "okok"; do
        if apr_is_error_code "$bogus"; then
            echo "apr_is_error_code wrongly accepted '$bogus'" >&2
            return 1
        fi
    done
}

# ===========================================================================
# apr_error_code_meaning
# ===========================================================================

@test "apr_error_code_meaning: emits a non-empty single line per documented code" {
    local code meaning
    for code in "${DOCUMENTED_CODES[@]}"; do
        meaning=$(apr_error_code_meaning "$code")
        [[ -n "$meaning" ]] || {
            echo "empty meaning for '$code'" >&2
            return 1
        }
        # Single line: no embedded newlines (the table renderer relies
        # on this).
        if [[ "$meaning" == *$'\n'* ]]; then
            echo "multi-line meaning for '$code': $meaning" >&2
            return 1
        fi
    done
}

@test "apr_error_code_meaning: unknown code falls back to 'Unknown APR error code'" {
    # `run` invokes the command in a subshell that doesn't always see
    # functions sourced in setup() (bats BW01 warning). Call directly.
    local out
    out=$(apr_error_code_meaning "definitely-not-a-code")
    [[ "$out" == "Unknown APR error code" ]] || {
        echo "got: '$out'" >&2
        return 1
    }
}

# ===========================================================================
# apr_exit_code_for_code
# ===========================================================================

@test "apr_exit_code_for_code: maps every documented code per the frozen table" {
    local pair code want got
    for pair in "${DOCUMENTED_EXITS[@]}"; do
        code="${pair%%=*}"
        want="${pair##*=}"
        got=$(apr_exit_code_for_code "$code")
        [[ "$got" == "$want" ]] || {
            echo "exit-class drift: code='$code' want=$want got=$got" >&2
            return 1
        }
    done
}

@test "apr_exit_code_for_code: respects EXIT_* env overrides" {
    # The function reads EXIT_USAGE_ERROR, EXIT_CONFIG_ERROR, etc. via
    # `${EXIT_*:-default}` — set them and the mapping must follow.
    EXIT_USAGE_ERROR=42 \
    EXIT_CONFIG_ERROR=43 \
    EXIT_BUSY_ERROR=44 \
        bash -c "
            source '$BATS_TEST_DIRNAME/../../lib/errors.sh'
            apr_exit_code_for_code usage_error
            apr_exit_code_for_code config_error
            apr_exit_code_for_code busy
        " > "$ARTIFACT_DIR/overrides.out"

    local -a got
    mapfile -t got < "$ARTIFACT_DIR/overrides.out"
    [[ "${got[0]}" -eq 42 ]] || { echo "usage_error override not honored: ${got[0]}" >&2; return 1; }
    [[ "${got[1]}" -eq 43 ]] || { echo "config_error override not honored: ${got[1]}" >&2; return 1; }
    [[ "${got[2]}" -eq 44 ]] || { echo "busy override not honored: ${got[2]}" >&2; return 1; }
}

@test "apr_exit_code_for_code: unknown code falls back to partial-failure (1)" {
    run apr_exit_code_for_code "definitely-not-a-code"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "1" ]]
}

@test "apr_exit_code_for_code: every emitted code maps to a numeric exit" {
    local code mapped
    while IFS= read -r code; do
        mapped=$(apr_exit_code_for_code "$code")
        [[ "$mapped" =~ ^[0-9]+$ ]] || {
            echo "code '$code' produced non-numeric exit '$mapped'" >&2
            return 1
        }
    done < <(apr_error_codes)
}

# ===========================================================================
# apr_error_code_table
# ===========================================================================

@test "apr_error_code_table: emits exactly one tab-separated row per documented code" {
    local table
    table=$(apr_error_code_table)

    local -a rows
    mapfile -t rows <<<"$table"
    [[ "${#rows[@]}" -eq "${#DOCUMENTED_CODES[@]}" ]] || {
        echo "row count drift: want=${#DOCUMENTED_CODES[@]} got=${#rows[@]}" >&2
        return 1
    }

    local row code exit meaning
    for row in "${rows[@]}"; do
        # Exactly two tabs ⇒ 3 columns.
        local tab_count
        tab_count=$(awk -F'\t' '{print NF-1}' <<<"$row")
        [[ "$tab_count" -eq 2 ]] || {
            echo "row has $tab_count tabs (want 2): '$row'" >&2
            return 1
        }
        code=$(cut -f1 <<<"$row")
        exit=$(cut -f2 <<<"$row")
        meaning=$(cut -f3 <<<"$row")
        apr_is_error_code "$code"                     || { echo "table code '$code' is not a documented code" >&2; return 1; }
        [[ "$exit" =~ ^[0-9]+$ ]]                     || { echo "table exit '$exit' for '$code' not numeric"   >&2; return 1; }
        [[ -n "$meaning" ]]                           || { echo "table meaning for '$code' is empty"            >&2; return 1; }
        # Each column should agree with the per-function output.
        [[ "$exit"    == "$(apr_exit_code_for_code "$code")"   ]] || { echo "exit mismatch for '$code'"    >&2; return 1; }
        [[ "$meaning" == "$(apr_error_code_meaning "$code")"   ]] || { echo "meaning mismatch for '$code'" >&2; return 1; }
    done
}

# ===========================================================================
# apr_emit_error_code_tag
# ===========================================================================

@test "apr_emit_error_code_tag: writes APR_ERROR_CODE=<code> to stderr" {
    apr_emit_error_code_tag "usage_error" 2>"$ARTIFACT_DIR/tag.err" >"$ARTIFACT_DIR/tag.out"
    [[ ! -s "$ARTIFACT_DIR/tag.out" ]] || {
        echo "tag leaked to stdout: $(cat "$ARTIFACT_DIR/tag.out")" >&2
        return 1
    }
    grep -Fxq "APR_ERROR_CODE=usage_error" "$ARTIFACT_DIR/tag.err"
}

@test "apr_emit_error_code_tag: defaults to internal_error when called with no args" {
    apr_emit_error_code_tag 2>"$ARTIFACT_DIR/tag.err"
    grep -Fxq "APR_ERROR_CODE=internal_error" "$ARTIFACT_DIR/tag.err"
}

# ===========================================================================
# apr_error_human_message
# ===========================================================================

@test "apr_error_human_message: error/info/unknown levels each write to stderr" {
    apr_error_human_message error "an error happened" 2>"$ARTIFACT_DIR/lvl.err"
    grep -Fq "an error happened" "$ARTIFACT_DIR/lvl.err"

    apr_error_human_message info "some info" 2>>"$ARTIFACT_DIR/lvl.err"
    grep -Fq "some info" "$ARTIFACT_DIR/lvl.err"

    apr_error_human_message bogus "fallback path" 2>>"$ARTIFACT_DIR/lvl.err"
    grep -Fq "fallback path" "$ARTIFACT_DIR/lvl.err"
}

@test "apr_error_human_message: uses print_error / print_info when those exist" {
    # Define stubs that mark which branch was taken; apr_error_human_message
    # detects them via `declare -F`.
    print_error() { printf 'STUB_ERR:%s\n' "$1" >&2; }
    print_info()  { printf 'STUB_INFO:%s\n' "$1" >&2; }

    apr_error_human_message error "via stub" 2>"$ARTIFACT_DIR/stub.err"
    apr_error_human_message info  "via stub" 2>>"$ARTIFACT_DIR/stub.err"

    grep -Fxq "STUB_ERR:via stub"  "$ARTIFACT_DIR/stub.err"
    grep -Fxq "STUB_INFO:via stub" "$ARTIFACT_DIR/stub.err"
}

# ===========================================================================
# apr_fail (sourced mode)
# ===========================================================================
# apr_fail returns (instead of `exit`-ing) when sourced. The check is
# `[[ "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" != "$0" ]]`. Inside bats
# we *are* sourced, so apr_fail will return — exactly what we need to
# exercise the mapping.

@test "apr_fail: known code → returns mapped exit class + writes tag" {
    set +e
    apr_fail "usage_error" "bad input" "try --help" \
        > "$ARTIFACT_DIR/fail.out" 2> "$ARTIFACT_DIR/fail.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 2 ]] || {
        echo "apr_fail usage_error returned $rc, want 2" >&2
        cat "$ARTIFACT_DIR/fail.err" >&2
        return 1
    }
    grep -Fq "bad input"   "$ARTIFACT_DIR/fail.err"
    grep -Fq "try --help"  "$ARTIFACT_DIR/fail.err"
    grep -Fxq "APR_ERROR_CODE=usage_error" "$ARTIFACT_DIR/fail.err"
    # No stdout leakage.
    [[ ! -s "$ARTIFACT_DIR/fail.out" ]]
}

@test "apr_fail: unknown code is normalized to internal_error (exit 1)" {
    set +e
    apr_fail "definitely-not-a-code" "boom" \
        > "$ARTIFACT_DIR/u.out" 2> "$ARTIFACT_DIR/u.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 1 ]] || {
        echo "apr_fail with unknown code returned $rc, want 1 (partial_failure)" >&2
        return 1
    }
    grep -Fxq "APR_ERROR_CODE=internal_error" "$ARTIFACT_DIR/u.err"
}

@test "apr_fail: empty code defaults to internal_error" {
    set +e
    apr_fail "" "boom" >/dev/null 2> "$ARTIFACT_DIR/empty.err"
    local rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -Fxq "APR_ERROR_CODE=internal_error" "$ARTIFACT_DIR/empty.err"
}

@test "apr_fail: no hint argument → no info line emitted" {
    set +e
    apr_fail "config_error" "bad workflow" 2> "$ARTIFACT_DIR/nohint.err" >/dev/null
    local rc=$?
    set -e
    [[ "$rc" -eq 4 ]]
    grep -Fq "bad workflow" "$ARTIFACT_DIR/nohint.err"
    # No info-style prefix should appear since we passed no hint.
    if grep -Fq "[apr] info:" "$ARTIFACT_DIR/nohint.err"; then
        echo "apr_fail emitted an info line for an empty hint" >&2
        cat "$ARTIFACT_DIR/nohint.err" >&2
        return 1
    fi
}

@test "apr_fail: exits 1 for not_implemented / internal_error (partial-failure class)" {
    set +e
    apr_fail "not_implemented" "soon"  >/dev/null 2>/dev/null; local rc_ni=$?
    apr_fail "internal_error" "oops"   >/dev/null 2>/dev/null; local rc_ie=$?
    set -e
    [[ "$rc_ni" -eq 1 ]]
    [[ "$rc_ie" -eq 1 ]]
}

# ===========================================================================
# Conformance: pairs of helpers must agree
# ===========================================================================

@test "conformance: apr_is_error_code accepts every code apr_error_codes emits" {
    local code
    while IFS= read -r code; do
        apr_is_error_code "$code" || {
            echo "code '$code' is emitted but rejected by apr_is_error_code" >&2
            return 1
        }
    done < <(apr_error_codes)
}

@test "conformance: every emitted code has a non-default meaning" {
    local code meaning
    while IFS= read -r code; do
        meaning=$(apr_error_code_meaning "$code")
        [[ "$meaning" != "Unknown APR error code" ]] || {
            echo "code '$code' resolves to the unknown-fallback meaning" >&2
            return 1
        }
    done < <(apr_error_codes)
}

@test "conformance: documented set (this file) matches apr_error_codes output" {
    # If this fails, either lib/errors.sh added/removed a code, or this
    # test file is stale. Updating DOCUMENTED_CODES at the top of the
    # file is the intended fix.
    local -a emitted
    mapfile -t emitted < <(apr_error_codes)
    [[ "${#emitted[@]}" -eq "${#DOCUMENTED_CODES[@]}" ]] || {
        echo "size mismatch: emitted=${#emitted[@]} documented=${#DOCUMENTED_CODES[@]}" >&2
        return 1
    }
    local i
    for i in "${!emitted[@]}"; do
        [[ "${emitted[$i]}" == "${DOCUMENTED_CODES[$i]}" ]]
    done
}

@test "conformance: integration test suites do not reference an unknown code" {
    # Grep the integration suites for `APR_ERROR_CODE=<code>` and
    # `.code == "<code>"` references and confirm every code is in the
    # documented set. This catches typos and drift between the
    # taxonomy and the suites that pin it (test_error_contract.bats,
    # test_ux_qa_matrix.bats, test_lint_contract.bats).
    local int_dir
    int_dir="$BATS_TEST_DIRNAME/../integration"

    # Collect referenced codes from a known set of stable patterns.
    # `set -e` is on; tolerate a non-matching grep with `|| true`.
    local refs=""
    refs+=$(grep -rhoE -- 'APR_ERROR_CODE=[a-z_]+' "$int_dir" 2>/dev/null \
                | sed 's/^APR_ERROR_CODE=//' || true)
    refs+=$'\n'
    refs+=$(grep -rhoE -- '"code"[[:space:]]*:[[:space:]]*"[a-z_]+"' "$int_dir" 2>/dev/null \
                | grep -oE '"[a-z_]+"$' | tr -d '"' || true)
    # Dedupe.
    refs=$(printf '%s\n' "$refs" | sort -u)

    local unknown=()
    local ref
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        # Strip leading APR_ERROR_CODE= if present.
        ref="${ref#APR_ERROR_CODE=}"
        if ! apr_is_error_code "$ref"; then
            unknown+=("$ref")
        fi
    done <<<"$refs"

    if (( ${#unknown[@]} > 0 )); then
        echo "integration suites reference codes not in apr_error_codes:" >&2
        printf '  %s\n' "${unknown[@]}" >&2
        return 1
    fi
}
