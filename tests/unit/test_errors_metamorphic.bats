#!/usr/bin/env bats
# test_errors_metamorphic.bats
#
# Metamorphic/property layer for lib/errors.sh (APR error taxonomy).
#
# tests/unit/test_errors.bats covers happy-path behavior for individual
# helpers. This file pins TAXONOMY-WIDE INVARIANTS so future tweaks
# (adding/removing codes, renaming, exit-code rewiring) can't silently
# break the stable robot/human contract that bd-3tj/bd-18r depend on.
#
# Invariants pinned:
#   I1  Totality of `apr_is_error_code` over `apr_error_codes`:
#       every code emitted by apr_error_codes is recognized.
#   I2  Negative space: random non-code strings are rejected.
#   I3  Every documented code has a non-fallback human meaning.
#   I4  Every documented code has a well-formed integer exit code
#       drawn from the canonical set {0,1,2,3,4,10,11,12}.
#   I5  `apr_error_codes` is byte-deterministic across N calls.
#   I6  `apr_error_code_table` is byte-deterministic across N calls.
#   I7  `apr_error_code_table` row count == `apr_error_codes` count
#       AND row[i] starts with codes[i] (order-preserving join).
#   I8  Each table row has exactly 3 tab-separated, non-empty fields:
#       code, exit_code, meaning.
#   I9  `apr_emit_error_code_tag` is byte-deterministic and obeys the
#       documented `APR_ERROR_CODE=<code>` shape on stderr.
#   I10 `apr_fail` with a valid code emits the matching tag to stderr
#       AND returns the documented exit code for that code.
#   I11 `apr_fail` with an unknown code falls back to `internal_error`
#       (tag emitted == internal_error, return == 1).
#   I12 Env overrides for exit codes (EXIT_USAGE_ERROR etc.) flow
#       through `apr_exit_code_for_code` without changing the code set.
#   I13 Permutation invariance: `apr_is_error_code` results are
#       independent of call order — shuffling the code list doesn't
#       change accept/reject decisions.
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/errors.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical exit-code set documented in the SPEC error taxonomy.
# I4 pins these as the only legal exit codes the taxonomy emits.
CANONICAL_EXIT_SET="0 1 2 3 4 10 11 12"

_assert_in_set() {
    # _assert_in_set <needle> <space-separated-haystack>
    local needle="$1" haystack="$2" tok
    for tok in $haystack; do
        [[ "$tok" == "$needle" ]] && return 0
    done
    return 1
}

# ===========================================================================
# I1 — every code in apr_error_codes is accepted by apr_is_error_code
# ===========================================================================

@test "I1: apr_is_error_code accepts every code emitted by apr_error_codes" {
    local code rc
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        rc=0
        apr_is_error_code "$code" || rc=$?
        [[ $rc -eq 0 ]] || {
            echo "I1 violation: '$code' not accepted by apr_is_error_code" >&2
            return 1
        }
    done < <(apr_error_codes)
}

# ===========================================================================
# I2 — negative space: random unknown strings are rejected
# ===========================================================================

@test "I2: apr_is_error_code rejects non-code strings" {
    local bogus rc
    local -a bogus_cases=(
        ""
        "OK"
        "Success"
        "unknown"
        "usage error"
        "BUSY"
        "ok "
        " ok"
        "0"
        "1"
        "fatal"
        "ENONET"
        "ack_complete"
        "apr-error-code"
    )
    for bogus in "${bogus_cases[@]}"; do
        rc=0
        apr_is_error_code "$bogus" || rc=$?
        [[ $rc -ne 0 ]] || {
            echo "I2 violation: '$bogus' was accepted as an error code" >&2
            return 1
        }
    done
}

# ===========================================================================
# I3 — every code has a non-fallback human meaning
# ===========================================================================

@test "I3: every code in apr_error_codes has a specific human meaning (not fallback)" {
    local code meaning
    local fallback="Unknown APR error code"
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        meaning=$(apr_error_code_meaning "$code")
        [[ -n "$meaning" ]] || { echo "I3 violation: '$code' has empty meaning" >&2; return 1; }
        [[ "$meaning" != "$fallback" ]] || {
            echo "I3 violation: '$code' returns the fallback meaning '$fallback'" >&2
            return 1
        }
    done < <(apr_error_codes)
}

# ===========================================================================
# I4 — every code has a well-formed exit code drawn from {0,1,2,3,4,10,11,12}
# ===========================================================================

@test "I4: every code maps to a canonical integer exit code" {
    local code ec
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        ec=$(apr_exit_code_for_code "$code")
        [[ "$ec" =~ ^[0-9]+$ ]] || {
            echo "I4 violation: '$code' -> non-integer exit code '$ec'" >&2
            return 1
        }
        _assert_in_set "$ec" "$CANONICAL_EXIT_SET" || {
            echo "I4 violation: '$code' -> exit '$ec' not in {$CANONICAL_EXIT_SET}" >&2
            return 1
        }
    done < <(apr_error_codes)
}

# ===========================================================================
# I5 — apr_error_codes is byte-deterministic across N calls
# ===========================================================================

@test "I5: apr_error_codes is byte-deterministic across 25 calls" {
    local first
    first=$(apr_error_codes)
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_error_codes)
        [[ "$first" == "$again" ]] || {
            echo "I5 violation at iteration $i" >&2
            diff <(printf '%s' "$first") <(printf '%s' "$again") >&2 || true
            return 1
        }
    done
}

# ===========================================================================
# I6 — apr_error_code_table is byte-deterministic across N calls
# ===========================================================================

@test "I6: apr_error_code_table is byte-deterministic across 25 calls" {
    local first
    first=$(apr_error_code_table)
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_error_code_table)
        [[ "$first" == "$again" ]] || {
            echo "I6 violation at iteration $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I7 — table row count + order matches apr_error_codes (no orphans, no drift)
# ===========================================================================

@test "I7: apr_error_code_table is an order-preserving join of apr_error_codes" {
    local -a codes=() rows=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        codes+=("$line")
    done < <(apr_error_codes)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        rows+=("$line")
    done < <(apr_error_code_table)

    [[ ${#codes[@]} -gt 0 ]]
    [[ ${#codes[@]} -eq ${#rows[@]} ]] || {
        echo "I7 violation: codes=${#codes[@]} rows=${#rows[@]}" >&2
        return 1
    }

    local i row_code
    for ((i=0; i<${#codes[@]}; i++)); do
        row_code="${rows[$i]%%$'\t'*}"
        [[ "$row_code" == "${codes[$i]}" ]] || {
            echo "I7 violation at row $i: code='${codes[$i]}' row_code='$row_code'" >&2
            echo "  full row: ${rows[$i]}" >&2
            return 1
        }
    done
}

# ===========================================================================
# I8 — each row has exactly 3 tab-separated non-empty fields
# ===========================================================================

@test "I8: each apr_error_code_table row has 3 non-empty tab-separated fields" {
    local row code ec meaning
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        # Count tabs.
        local tabs="${row//[^$'\t']/}"
        [[ ${#tabs} -eq 2 ]] || {
            echo "I8 violation: row has ${#tabs} tabs (want 2): '$row'" >&2
            return 1
        }
        IFS=$'\t' read -r code ec meaning <<< "$row"
        [[ -n "$code" ]]    || { echo "I8 violation: empty code in '$row'"    >&2; return 1; }
        [[ -n "$ec" ]]      || { echo "I8 violation: empty exit in '$row'"    >&2; return 1; }
        [[ -n "$meaning" ]] || { echo "I8 violation: empty meaning in '$row'" >&2; return 1; }
        [[ "$ec" =~ ^[0-9]+$ ]] || {
            echo "I8 violation: non-integer exit '$ec' in '$row'" >&2
            return 1
        }
    done < <(apr_error_code_table)
}

# ===========================================================================
# I9 — emit_error_code_tag is byte-deterministic + honors documented shape
# ===========================================================================

@test "I9: apr_emit_error_code_tag is deterministic and matches APR_ERROR_CODE=<code> shape" {
    local code first again i
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        # Capture stderr.
        first=$(apr_emit_error_code_tag "$code" 2>&1 1>/dev/null)
        [[ "$first" == "APR_ERROR_CODE=$code" ]] || {
            echo "I9 violation: shape for '$code' was '$first'" >&2
            return 1
        }
        for ((i=0; i<5; i++)); do
            again=$(apr_emit_error_code_tag "$code" 2>&1 1>/dev/null)
            [[ "$again" == "$first" ]] || {
                echo "I9 violation: non-deterministic for '$code' at iter $i" >&2
                return 1
            }
        done
    done < <(apr_error_codes)
}

# ===========================================================================
# I10 — apr_fail with valid code: tag on stderr + matching exit code
# ===========================================================================

@test "I10: apr_fail emits the matching tag and returns the documented exit code" {
    local code expected_exit stderr_capture rc
    while IFS= read -r code; do
        [[ -z "$code" ]] && continue
        expected_exit=$(apr_exit_code_for_code "$code")
        # apr_fail prints human messages + emits the tag; capture stderr,
        # discard stdout, observe return code.
        rc=0
        stderr_capture=$(apr_fail "$code" "test message for $code" "" 2>&1 1>/dev/null) || rc=$?
        [[ "$rc" == "$expected_exit" ]] || {
            echo "I10 violation: code='$code' rc=$rc expected=$expected_exit" >&2
            return 1
        }
        [[ "$stderr_capture" == *"APR_ERROR_CODE=$code"* ]] || {
            echo "I10 violation: code='$code' missing tag in stderr:" >&2
            printf '%s\n' "$stderr_capture" >&2
            return 1
        }
    done < <(apr_error_codes)
}

# ===========================================================================
# I11 — apr_fail with unknown code falls back to internal_error
# ===========================================================================

@test "I11: apr_fail falls back to internal_error for an unknown code" {
    local stderr_capture rc=0
    stderr_capture=$(apr_fail "not_a_real_code_xyz" "boom" "" 2>&1 1>/dev/null) || rc=$?
    [[ "$rc" -eq 1 ]] || {
        echo "I11 violation: rc=$rc expected=1 (internal_error)" >&2
        return 1
    }
    [[ "$stderr_capture" == *"APR_ERROR_CODE=internal_error"* ]] || {
        echo "I11 violation: stderr missing internal_error tag:" >&2
        printf '%s\n' "$stderr_capture" >&2
        return 1
    }
    # Negative: must NOT emit a tag for the unknown code.
    [[ "$stderr_capture" != *"APR_ERROR_CODE=not_a_real_code_xyz"* ]] || {
        echo "I11 violation: unknown code leaked into tag" >&2
        return 1
    }
}

# ===========================================================================
# I12 — env overrides flow through; code set is unchanged
# ===========================================================================

@test "I12: EXIT_* env overrides flow through apr_exit_code_for_code" {
    # Pick a code whose mapping ONLY depends on EXIT_USAGE_ERROR.
    local base_exit
    base_exit=$(apr_exit_code_for_code "usage_error")
    [[ "$base_exit" == "2" ]] || skip "default usage_error exit no longer 2; spec drift?"

    local overridden
    overridden=$(EXIT_USAGE_ERROR=42 apr_exit_code_for_code "usage_error")
    [[ "$overridden" == "42" ]] || {
        echo "I12 violation: override produced '$overridden' instead of 42" >&2
        return 1
    }

    # And the code set must not change shape due to env overrides.
    local before after
    before=$(apr_error_codes)
    after=$(EXIT_USAGE_ERROR=42 apr_error_codes)
    [[ "$before" == "$after" ]] || {
        echo "I12 violation: code list changed under env override" >&2
        return 1
    }
}

# ===========================================================================
# I13 — apr_is_error_code is permutation-invariant
# ===========================================================================

@test "I13: shuffling the code list does not change apr_is_error_code accept/reject decisions" {
    local -a codes=()
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        codes+=("$line")
    done < <(apr_error_codes)

    # Capture accept/reject decisions in original order.
    local -A decision_original=()
    local c rc
    for c in "${codes[@]}"; do
        rc=0
        apr_is_error_code "$c" || rc=$?
        decision_original["$c"]="$rc"
    done

    # Shuffle (LC_ALL=C sort -R if available; else reverse).
    local -a shuffled=()
    if printf '%s\n' "${codes[@]}" | LC_ALL=C sort -R >/dev/null 2>&1; then
        while IFS= read -r c; do shuffled+=("$c"); done < <(printf '%s\n' "${codes[@]}" | LC_ALL=C sort -R)
    else
        local i
        for ((i=${#codes[@]}-1; i>=0; i--)); do shuffled+=("${codes[$i]}"); done
    fi

    # Verify decisions match in shuffled order.
    local rc2
    for c in "${shuffled[@]}"; do
        rc2=0
        apr_is_error_code "$c" || rc2=$?
        [[ "$rc2" == "${decision_original[$c]}" ]] || {
            echo "I13 violation: '$c' rc=$rc2 vs original ${decision_original[$c]}" >&2
            return 1
        }
    done
}
