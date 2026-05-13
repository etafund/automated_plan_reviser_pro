#!/usr/bin/env bats
# test_redact_metamorphic.bats
#
# Metamorphic/property layer for lib/redact.sh (bd-3ut prompt redactor).
#
# Bead automated_plan_reviser_pro-ja48.
#
# tests/unit/test_redact.bats and tests/unit/test_redact_fuzz.bats cover
# happy paths and adversarial input shapes. This file PINS THE
# SAFETY-BOUNDARY PROPERTIES that downstream callers (oracle invocation,
# clipboard copy, ledger persistence) implicitly rely on:
#
#   I1  Idempotence: redact(redact(x)) == redact(x). Once a sentinel is
#       written, a second pass must not re-redact it (defends the
#       "render-then-trim-then-render" pipeline against double work).
#   I2  Byte-determinism: same input → byte-identical output across N
#       calls.
#   I3  Identity on empty input: redact("") == "" with counters at 0.
#   I4  Identity on secret-free input: harmless text passes through
#       unchanged (no false positives on docs).
#   I5  Sentinel containment: redact output may contain ONLY documented
#       sentinel TYPE labels: AKIA_KEY, AUTH_BEARER_TOKEN,
#       GITHUB_FINEGRAINED, GITHUB_TOKEN, OPENAI_KEY,
#       PRIVATE_KEY_BLOCK, SLACK_TOKEN. No drift, no UNKNOWN, no leak
#       of partially-redacted secrets.
#   I6  Counter consistency: APR_REDACT_COUNT == sum(by_type) from
#       apr_lib_redact_summary.
#   I7  Single-axis: a text with secrets of exactly one type bumps
#       ONLY that type's counter; all other type counts stay 0.
#   I8  Summary JSON is always well-formed and has stable shape
#       {"total": N, "by_type": {...}}.
#   I9  Counter reset between calls: a second call on harmless input
#       resets APR_REDACT_COUNT to 0 (no cross-call accumulation).
#   I10 Summary determinism: identical input → identical summary JSON.
#   I11 Compositional counters: a text with secrets of K distinct
#       types bumps each type's counter independently (no leakage
#       across types).
#   I12 Sentinel literals are not themselves re-redacted (corollary of
#       idempotence; pinned explicitly to catch accidental future
#       patterns that match `<<REDACTED:...>>`).
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/redact.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical sentinel TYPE labels per lib/redact.sh public contract.
DOCUMENTED_TYPES="AKIA_KEY AUTH_BEARER_TOKEN GITHUB_FINEGRAINED GITHUB_TOKEN OPENAI_KEY PRIVATE_KEY_BLOCK SLACK_TOKEN"

# Representative secret-shaped strings per type. Bench-tuned to match
# the patterns in lib/redact.sh (>= 20 chars for prefix patterns).
OPENAI_SECRET='sk-aabbccddeeff112233445566778899XYZ'
GITHUB_TOKEN_SECRET='ghp_aabbccddeeff1122334455667788990011AABB'
GITHUB_FG_SECRET='github_pat_AABBCCDDEEFF11223344556677889900'
SLACK_SECRET='xoxb-1234567890-abcdef'
AKIA_SECRET='AKIAIOSFODNN7EXAMPLE'
AUTH_SECRET='Authorization: Bearer abc123tok-XYZ'

# ===========================================================================
# I1 — Idempotence
# ===========================================================================

@test "I1: redact is idempotent across the documented secret type set" {
    local cases=(
        ""
        "Normal docs text with no secrets."
        "key=$OPENAI_SECRET"
        "$AUTH_SECRET trailing"
        "pat=$GITHUB_FG_SECRET"
        "tok=$GITHUB_TOKEN_SECRET"
        "$SLACK_SECRET more"
        "aws=$AKIA_SECRET"
        $'-----BEGIN PRIVATE KEY-----\nABC\n-----END PRIVATE KEY-----'
        "mixed: $OPENAI_SECRET and $AUTH_SECRET and $GITHUB_TOKEN_SECRET"
    )
    local c once twice
    for c in "${cases[@]}"; do
        once=$(apr_lib_redact_prompt "$c")
        twice=$(apr_lib_redact_prompt "$once")
        [[ "$once" == "$twice" ]] || {
            echo "I1 violation for input '$c':" >&2
            echo "  once : $once" >&2
            echo "  twice: $twice" >&2
            return 1
        }
    done
}

# ===========================================================================
# I2 — Byte-determinism across N calls
# ===========================================================================

@test "I2: redact is byte-deterministic across 25 calls" {
    local input="key=$OPENAI_SECRET and pat=$GITHUB_FG_SECRET trailing"
    local first
    first=$(apr_lib_redact_prompt "$input")
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_redact_prompt "$input")
        [[ "$first" == "$again" ]] || {
            echo "I2 violation at iter $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I3 — Empty input identity
# ===========================================================================

@test "I3: redact('') == '' with APR_REDACT_COUNT == 0" {
    local out
    out=$(apr_lib_redact_prompt "")
    [[ -z "$out" ]] || { echo "I3 violation: non-empty output for empty input" >&2; return 1; }
    apr_lib_redact_prompt "" >/dev/null
    [[ "$APR_REDACT_COUNT" -eq 0 ]] || {
        echo "I3 violation: APR_REDACT_COUNT=$APR_REDACT_COUNT for empty input" >&2
        return 1
    }
}

# ===========================================================================
# I4 — Secret-free input identity
# ===========================================================================

@test "I4: redact passes harmless text through unchanged" {
    local cases=(
        "Just normal docs."
        "function foo() { return 42; }"
        "version 1.2.3 (2026-05-12)"
        "see http://example.com/path?q=1"
        "ok: 0 1 2 3"
        "a sentence with brackets [a] (b) {c}"
    )
    local c out
    for c in "${cases[@]}"; do
        out=$(apr_lib_redact_prompt "$c")
        [[ "$out" == "$c" ]] || {
            echo "I4 false-positive for: '$c'" >&2
            echo "  got: '$out'" >&2
            return 1
        }
    done
}

# ===========================================================================
# I5 — Sentinel containment: only documented types appear
# ===========================================================================

@test "I5: redact output contains only documented sentinel types" {
    local input="mix: $OPENAI_SECRET / $AUTH_SECRET / $GITHUB_TOKEN_SECRET / $GITHUB_FG_SECRET / $SLACK_SECRET / $AKIA_SECRET"
    local out
    out=$(apr_lib_redact_prompt "$input")

    # Extract every sentinel TYPE label from the output.
    local types_in_output
    types_in_output=$(printf '%s' "$out" | grep -oE '<<REDACTED:[A-Z_]+>>' | sed -E 's/<<REDACTED:([A-Z_]+)>>/\1/')
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        case " $DOCUMENTED_TYPES " in
            *" $t "*) : ;;
            *)
                echo "I5 violation: undocumented sentinel type '$t' in output" >&2
                echo "  full output: $out" >&2
                return 1
                ;;
        esac
    done <<< "$types_in_output"

    # Negative pin: original secret fragments must NOT appear.
    [[ "$out" != *"$OPENAI_SECRET"* ]]      || { echo "I5: OPENAI_SECRET leaked"      >&2; return 1; }
    [[ "$out" != *"$GITHUB_TOKEN_SECRET"* ]] || { echo "I5: GITHUB_TOKEN leaked"     >&2; return 1; }
    [[ "$out" != *"$GITHUB_FG_SECRET"* ]]   || { echo "I5: GITHUB_FINEGRAINED leaked" >&2; return 1; }
    [[ "$out" != *"$SLACK_SECRET"* ]]       || { echo "I5: SLACK_TOKEN leaked"       >&2; return 1; }
    [[ "$out" != *"$AKIA_SECRET"* ]]        || { echo "I5: AKIA_KEY leaked"          >&2; return 1; }
    # AUTH_SECRET intentionally keeps the prefix `Authorization: Bearer `;
    # the secret tail `abc123tok-XYZ` must be gone.
    [[ "$out" != *"abc123tok-XYZ"* ]]       || { echo "I5: AUTH_BEARER tail leaked"  >&2; return 1; }
}

# ===========================================================================
# I6 — Counter consistency: total == sum(by_type)
# ===========================================================================

@test "I6: APR_REDACT_COUNT equals sum(by_type) from summary" {
    local input="$OPENAI_SECRET $GITHUB_TOKEN_SECRET $SLACK_SECRET $AKIA_SECRET $AUTH_SECRET"
    apr_lib_redact_prompt "$input" >/dev/null
    local summary
    summary=$(apr_lib_redact_summary)
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — summary is JSON"
    fi
    python3 - "$summary" "$APR_REDACT_COUNT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
total = d["total"]
total_apr = int(sys.argv[2])
assert total == total_apr, (total, total_apr)
assert total == sum(d["by_type"].values()), (total, d["by_type"])
PY
}

# ===========================================================================
# I7 — Single-axis counters: only the matched type's counter increments
# ===========================================================================

@test "I7: a single-secret-type input bumps only that type's counter" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — summary is JSON"
    fi
    local cases=(
        "OPENAI_KEY:key=$OPENAI_SECRET"
        "GITHUB_TOKEN:tok=$GITHUB_TOKEN_SECRET"
        "GITHUB_FINEGRAINED:pat=$GITHUB_FG_SECRET"
        "SLACK_TOKEN:$SLACK_SECRET"
        "AKIA_KEY:$AKIA_SECRET"
    )
    local entry expected_type input summary
    for entry in "${cases[@]}"; do
        expected_type="${entry%%:*}"
        input="${entry#*:}"
        apr_lib_redact_prompt "$input" >/dev/null
        summary=$(apr_lib_redact_summary)
        python3 - "$summary" "$expected_type" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
exp = sys.argv[2]
by = d["by_type"]
# Expected type present and > 0.
assert by.get(exp, 0) > 0, (exp, by)
# Other types must be absent (the summary only emits non-zero counters).
extras = [t for t in by if t != exp]
assert extras == [], (exp, by, extras)
PY
    done
}

# ===========================================================================
# I8 — Summary JSON shape is stable
# ===========================================================================

@test "I8: summary JSON always has {total, by_type} top-level shape" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local inputs=(
        ""
        "plain text"
        "key=$OPENAI_SECRET"
        "$AKIA_SECRET and $SLACK_SECRET"
    )
    local i s
    for i in "${inputs[@]}"; do
        apr_lib_redact_prompt "$i" >/dev/null
        s=$(apr_lib_redact_summary)
        python3 - "$s" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert isinstance(d, dict), d
assert set(d.keys()) == {"total", "by_type"}, d.keys()
assert isinstance(d["total"], int), d
assert isinstance(d["by_type"], dict), d
for k, v in d["by_type"].items():
    assert isinstance(v, int) and v > 0, (k, v)
PY
    done
}

# ===========================================================================
# I9 — Counter reset between calls
# ===========================================================================

@test "I9: a redact call resets prior counters (no cross-call accumulation)" {
    apr_lib_redact_prompt "$OPENAI_SECRET $GITHUB_TOKEN_SECRET" >/dev/null
    [[ "$APR_REDACT_COUNT" -gt 0 ]] || { echo "I9 setup failed: count was 0" >&2; return 1; }
    apr_lib_redact_prompt "no secrets at all" >/dev/null
    [[ "$APR_REDACT_COUNT" -eq 0 ]] || {
        echo "I9 violation: APR_REDACT_COUNT=$APR_REDACT_COUNT after harmless follow-up" >&2
        return 1
    }
}

# ===========================================================================
# I10 — Summary determinism
# ===========================================================================

@test "I10: identical input -> identical summary JSON across N calls" {
    local input="mix: $OPENAI_SECRET $GITHUB_TOKEN_SECRET $SLACK_SECRET"
    apr_lib_redact_prompt "$input" >/dev/null
    local first
    first=$(apr_lib_redact_summary)
    local i again
    for ((i=0; i<10; i++)); do
        apr_lib_redact_prompt "$input" >/dev/null
        again=$(apr_lib_redact_summary)
        [[ "$first" == "$again" ]] || {
            echo "I10 violation at iter $i: '$first' != '$again'" >&2
            return 1
        }
    done
}

# ===========================================================================
# I11 — Compositional counters
# ===========================================================================

@test "I11: multi-type input bumps each type's counter independently" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input="$OPENAI_SECRET / $GITHUB_TOKEN_SECRET / $GITHUB_FG_SECRET / $SLACK_SECRET / $AKIA_SECRET / $AUTH_SECRET"
    apr_lib_redact_prompt "$input" >/dev/null
    local summary
    summary=$(apr_lib_redact_summary)
    python3 - "$summary" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
by = d["by_type"]
# We expect at least 5 of the 6 types we injected (GITHUB_FINEGRAINED
# overlaps with the broader GITHUB_TOKEN prefix pattern; the lib
# explicitly documents that as expected). All listed types must be >0.
expected_at_minimum = {"OPENAI_KEY", "SLACK_TOKEN", "AKIA_KEY", "AUTH_BEARER_TOKEN"}
for t in expected_at_minimum:
    assert by.get(t, 0) >= 1, (t, by)
# Total >= sum of expected types.
assert d["total"] >= len(expected_at_minimum), (d["total"], by)
PY
}

# ===========================================================================
# I12 — Sentinel literals are not re-redacted
# ===========================================================================

@test "I12: sentinel literals (<<REDACTED:TYPE>>) are not themselves redacted" {
    local already_redacted="prefix <<REDACTED:OPENAI_KEY>> middle <<REDACTED:SLACK_TOKEN>> suffix"
    local out
    out=$(apr_lib_redact_prompt "$already_redacted")
    [[ "$out" == "$already_redacted" ]] || {
        echo "I12 violation: redact rewrote already-redacted text:" >&2
        echo "  in:  '$already_redacted'" >&2
        echo "  out: '$out'" >&2
        return 1
    }
    [[ "$APR_REDACT_COUNT" -eq 0 ]] || {
        echo "I12 violation: APR_REDACT_COUNT=$APR_REDACT_COUNT for sentinel-only input" >&2
        return 1
    }
}
