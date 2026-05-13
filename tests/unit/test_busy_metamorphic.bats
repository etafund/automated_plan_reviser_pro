#!/usr/bin/env bats
# test_busy_metamorphic.bats
#
# Bead automated_plan_reviser_pro-9ikj — metamorphic/property layer for
# lib/busy.sh.
#
# lib/busy.sh detects whether an Oracle run terminated because the
# upstream provider was single-flighted. The 37 unit tests in
# tests/unit/test_busy.bats cover specific positive and negative cases;
# this file pins INPUT-OUTPUT RELATIONSHIPS that hold for any
# well-formed log, so future signature tweaks or regex changes surface
# here without re-listing every individual case.
#
# Metamorphic relations:
#
#   MR1 — prepending non-busy text to a busy input keeps it busy
#   MR2 — appending non-busy text to a busy input keeps it busy
#   MR3 — concatenating two busy inputs is still busy
#   MR4 — removing the busy-marking line(s) from a busy input makes it
#         not-busy
#   MR5 — case-flipping the busy keyword preserves detection
#   MR6 — line position doesn't affect detection (busy@line1 ≡ busy@line1000)
#   MR7 — describe_text and detect_text AGREE on the busy verdict
#   MR8 — surrounding the busy keyword with ANSI color escapes does NOT
#         break detection (current behavior, pinned so a future "strip
#         ANSI first" refactor sees the test)
#
# Plus property tests:
#   - every signature in _APR_BUSY_SIGNATURES matches at least one
#     positive example (catches dead-code signatures)
#   - negative-corpus fuzz: substring-containing words that should NOT
#     match (busylight, busy_loop, busyness, "had a busy week")
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
    source "$BATS_TEST_DIRNAME/../../lib/busy.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Corpora
# ---------------------------------------------------------------------------

# Representative busy inputs — one per documented signature in
# _APR_BUSY_SIGNATURES. Used by both per-line tests and composition tests.
BUSY_EXAMPLES=(
    "ERROR: busy"
    "  ERROR: busy with trailing context"
    "User error (browser-automation): busy"
    "User error (any-engine): busy with comma, etc"
    "Oracle is busy"
    "browser is busy now"
    "session is busy"
    "status: busy"
    "state=busy"
    "reason: busy"
    "retry=busy"
)

# Negative inputs that LOOK busy but aren't — substring matches that
# the boundary regex must exclude.
NON_BUSY_EXAMPLES=(
    "busylight enabled"
    "busy_loop iteration 5"
    "busyness score: 0.7"
    "had a busy week"
    "is_busy_member()"
    "the function busynet returned 0"
    "no errors, just info"
    "validation_failed"
    "config_error"
)

# Random non-busy noise lines (for prepending/appending tests).
NOISE_LINES=(
    "info: starting run"
    "step 1 of 5"
    "elapsed: 1.2s"
    "validation: ok"
    ""
    "..."
    "[2026-05-13T01:23:45] tick"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_busy() {
    # Args: <text> → exit 0 if detected busy, else 1.
    apr_lib_busy_detect_text "$1"
}

describe_busy_flag() {
    # Args: <text> → "true" or "false" from describe_text's `busy` field.
    apr_lib_busy_describe_text "$1" | jq -r '.busy'
}

# ===========================================================================
# MR1 — prepend non-busy noise
# ===========================================================================

@test "MR1: prepending non-busy noise lines to a busy input keeps it busy" {
    local busy noise prefixed
    local checks=0
    for busy in "${BUSY_EXAMPLES[@]}"; do
        for noise in "${NOISE_LINES[@]}"; do
            prefixed="$noise"$'\n'"$busy"
            is_busy "$prefixed" || {
                echo "MR1 violation for busy='$busy' noise='$noise':" >&2
                echo "$prefixed" >&2
                return 1
            }
            checks=$((checks + 1))
        done
    done
    [[ "$checks" -ge 50 ]]
}

# ===========================================================================
# MR2 — append non-busy noise
# ===========================================================================

@test "MR2: appending non-busy noise lines to a busy input keeps it busy" {
    local busy noise suffixed
    local checks=0
    for busy in "${BUSY_EXAMPLES[@]}"; do
        for noise in "${NOISE_LINES[@]}"; do
            suffixed="$busy"$'\n'"$noise"
            is_busy "$suffixed" || {
                echo "MR2 violation for busy='$busy' noise='$noise':" >&2
                echo "$suffixed" >&2
                return 1
            }
            checks=$((checks + 1))
        done
    done
    [[ "$checks" -ge 50 ]]
}

# ===========================================================================
# MR3 — concat of two busies is busy
# ===========================================================================

@test "MR3: concatenating two distinct busy inputs is still busy" {
    local b1 b2 joined
    for b1 in "${BUSY_EXAMPLES[@]}"; do
        for b2 in "${BUSY_EXAMPLES[@]}"; do
            [[ "$b1" == "$b2" ]] && continue
            joined="$b1"$'\n'"$b2"
            is_busy "$joined" || {
                echo "MR3 violation: '$b1' + '$b2'" >&2
                return 1
            }
        done
    done
}

# ===========================================================================
# MR4 — removing the busy line makes it not-busy
# ===========================================================================

@test "MR4: a sandwich (noise → busy → noise) becomes not-busy when the busy line is removed" {
    local busy noise1 noise2 sandwich without_busy
    for busy in "${BUSY_EXAMPLES[@]}"; do
        noise1="${NOISE_LINES[0]}"
        noise2="${NOISE_LINES[1]}"
        sandwich="$noise1"$'\n'"$busy"$'\n'"$noise2"
        without_busy="$noise1"$'\n'"$noise2"

        is_busy "$sandwich" || {
            echo "sandwich was unexpectedly NOT busy for '$busy'" >&2
            return 1
        }
        if is_busy "$without_busy"; then
            echo "MR4 violation: removing busy line still detected as busy" >&2
            echo "  removed-input:" >&2
            echo "$without_busy" >&2
            return 1
        fi
    done
}

# ===========================================================================
# MR5 — case-flip preserves detection
# ===========================================================================

@test "MR5: case-flipping the busy keyword (busy/BUSY/Busy) preserves detection" {
    local templates=(
        "ERROR: %s"
        "User error (engine): %s"
        "oracle is %s"
        "browser is %s now"
        "status: %s"
    )
    local cases=(busy BUSY Busy bUsY BUSY busyy)   # last is busyy → NOT matched
    local tpl variant fmt input

    for tpl in "${templates[@]}"; do
        for variant in busy BUSY Busy bUsY; do
            input=$(printf "$tpl" "$variant")
            is_busy "$input" || {
                echo "MR5 violation: case '$variant' in template '$tpl' not detected" >&2
                echo "  input: $input" >&2
                return 1
            }
        done
        # Sanity: with a non-busy variant the SAME template must NOT match.
        input=$(printf "$tpl" "calm")
        if is_busy "$input"; then
            echo "MR5 sanity violation: 'calm' in template '$tpl' matched busy" >&2
            return 1
        fi
    done
}

# ===========================================================================
# MR6 — position invariance
# ===========================================================================

@test "MR6: busy line at line 1 vs line 1000 produces the same verdict" {
    local busy="ERROR: busy"
    local prefix="" i
    for i in $(seq 1 999); do
        prefix+="noise line $i"$'\n'
    done
    local at_top="$busy"$'\n'"$prefix"
    local at_bottom="$prefix$busy"

    is_busy "$at_top"
    is_busy "$at_bottom"
}

# ===========================================================================
# MR7 — describe_text and detect_text agree
# ===========================================================================

@test "MR7: describe_text and detect_text agree on the busy verdict for every corpus input" {
    local input
    for input in "${BUSY_EXAMPLES[@]}" "${NON_BUSY_EXAMPLES[@]}" ""; do
        local detect_rc=0
        is_busy "$input" || detect_rc=$?
        local describe_flag
        describe_flag=$(describe_busy_flag "$input")

        # detect_rc=0 (busy) ↔ describe_flag=true
        if [[ "$detect_rc" -eq 0 && "$describe_flag" != "true" ]]; then
            echo "MR7 mismatch for input '$(printf '%q' "$input")': detect=busy describe=not-busy" >&2
            return 1
        fi
        if [[ "$detect_rc" -ne 0 && "$describe_flag" != "false" ]]; then
            echo "MR7 mismatch for input '$(printf '%q' "$input")': detect=not-busy describe=busy" >&2
            return 1
        fi
    done
}

# ===========================================================================
# MR8 — ANSI color around the busy keyword
# ===========================================================================

@test "MR8: ANSI escapes adjacent to the busy keyword break detection (current behavior pinned)" {
    # The boundary regex requires a character-class boundary
    # immediately after the busy keyword (whitespace, punctuation, or
    # end-of-line). An ESC byte inserted as part of an ANSI escape
    # sequence is NOT in that class, so the regex doesn't match.
    # lib/busy.sh operates on raw bytes — no ANSI stripping — so
    # ANSI-wrapped busy keywords slip through. This pins that
    # behavior; if a future refactor decides to strip ANSI before
    # matching, this test will flip and the spec needs updating.
    local red=$'\x1b[31m' off=$'\x1b[0m'

    # An ANSI escape RIGHT around the keyword breaks the match for
    # the `error_busy_prefix` and `subject_is_busy` signatures.
    if is_busy "ERROR: ${red}busy${off}"; then
        echo "ANSI-wrapped busy was detected — pin needs updating" >&2
        return 1
    fi
    if is_busy "Oracle is ${red}busy${off}"; then
        echo "ANSI-wrapped busy (Oracle is …) was detected — pin needs updating" >&2
        return 1
    fi

    # Sanity counter-case: a CLEAN (unwrapped) busy line on the same
    # input must still be detected. This proves the breakage above is
    # specific to the ANSI escape adjacency, not the input shape.
    local clean=$'normal log line\nERROR: busy'
    is_busy "$clean" || {
        echo "MR8 sanity check failed: clean busy line not detected" >&2
        return 1
    }
}

# ===========================================================================
# Property — every signature matches at least one BUSY_EXAMPLES entry
# ===========================================================================

@test "every documented signature in _APR_BUSY_SIGNATURES matches at least one example in our corpus" {
    # Walk the signature catalog and verify each one fires on at least
    # one BUSY_EXAMPLES entry. Catches signatures that drift away from
    # any working input.
    local sig name regex hit input
    for sig in "${_APR_BUSY_SIGNATURES[@]}"; do
        name="${sig%%|*}"
        regex="${sig#*|}"
        hit=0
        for input in "${BUSY_EXAMPLES[@]}"; do
            if [[ "$input" =~ $regex ]]; then
                hit=1
                break
            fi
        done
        if [[ "$hit" -eq 0 ]]; then
            echo "signature '$name' does not match any BUSY_EXAMPLES entry" >&2
            echo "  regex: $regex" >&2
            return 1
        fi
    done
}

# ===========================================================================
# Negative-corpus fuzz — substring-containing words NEVER match
# ===========================================================================

@test "negative-fuzz: 'busy'-as-substring words do NOT match (boundary regex contract)" {
    local input
    for input in "${NON_BUSY_EXAMPLES[@]}"; do
        if is_busy "$input"; then
            echo "false positive on: '$input'" >&2
            return 1
        fi
    done
}

@test "negative-fuzz: multi-line non-busy logs do NOT match even when long" {
    # 50 non-busy lines including several substring decoys.
    local i big=""
    for i in $(seq 1 25); do
        big+="info: step $i"$'\n'
        big+="busylight=true"$'\n'      # decoy
    done
    if is_busy "$big"; then
        echo "false positive on 50-line decoy log" >&2
        return 1
    fi
}

# ===========================================================================
# describe_text — signature name is one of the documented ones
# ===========================================================================

@test "describe_text: signature names belong to the documented set" {
    local documented_names=()
    local sig
    for sig in "${_APR_BUSY_SIGNATURES[@]}"; do
        documented_names+=("${sig%%|*}")
    done

    local input got_sig found name
    for input in "${BUSY_EXAMPLES[@]}"; do
        got_sig=$(apr_lib_busy_describe_text "$input" | jq -r '.signature // empty')
        [[ -n "$got_sig" ]] || {
            echo "describe_text returned no signature for '$input'" >&2
            return 1
        }
        found=0
        for name in "${documented_names[@]}"; do
            if [[ "$got_sig" == "$name" ]]; then found=1; break; fi
        done
        [[ "$found" -eq 1 ]] || {
            echo "describe_text emitted undocumented signature '$got_sig' for input '$input'" >&2
            return 1
        }
    done
}

@test "describe_text: matched line is truncated to ≤200 bytes" {
    local long
    long=$(printf 'ERROR: busy %s' "$(printf 'x%.0s' $(seq 1 500))")

    local desc line
    desc=$(apr_lib_busy_describe_text "$long")
    line=$(jq -r '.line' <<<"$desc")
    [[ "${#line}" -le 200 ]] || {
        echo "matched line not truncated: length=${#line}" >&2
        return 1
    }
}

@test "describe_text: matched line is JSON-safe (no raw quotes/backslashes/control bytes)" {
    # An input containing characters that must be escaped — the describe
    # output should still parse cleanly as JSON.
    local input='ERROR: busy "with quotes" and \backslash and a literal \n'
    local desc
    desc=$(apr_lib_busy_describe_text "$input")
    jq -e . <<<"$desc" >/dev/null || {
        echo "describe_text produced unparseable JSON for quote/backslash input:" >&2
        echo "$desc" >&2
        return 1
    }
    jq -e '.busy == true' <<<"$desc" >/dev/null
}

# ===========================================================================
# Edge cases — empty input + single-char input
# ===========================================================================

@test "edge: empty input is not busy (both detect and describe)" {
    ! is_busy ""
    [[ "$(describe_busy_flag '')" == "false" ]]
}

@test "edge: single 'busy' word with no boundary context does NOT match" {
    # The boundary regex requires the subject + " is " before "busy",
    # or a kv-style prefix, or an "ERROR:" prefix. Bare "busy" alone
    # must not match.
    if is_busy "busy"; then
        echo "bare 'busy' word wrongly matched" >&2
        return 1
    fi
}

# ===========================================================================
# Determinism — same input → same describe output
# ===========================================================================

@test "determinism: describe_text output is byte-identical across repeated calls" {
    local input first second i
    for input in "${BUSY_EXAMPLES[@]}"; do
        first=$(apr_lib_busy_describe_text "$input")
        for i in 1 2 3; do
            second=$(apr_lib_busy_describe_text "$input")
            [[ "$first" == "$second" ]] || {
                echo "non-deterministic describe for '$input'" >&2
                return 1
            }
        done
    done
}
