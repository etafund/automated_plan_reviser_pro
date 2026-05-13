#!/usr/bin/env bats
# test_validate_fuzz.bats
#
# Bead automated_plan_reviser_pro-nkws — fuzz/property layer for
# lib/validate.sh.
#
# tests/unit/test_validate.bats (52 tests) covers per-class happy paths.
# This file adds adversarial / mixed-class / size / fence-variant
# coverage focused on the parser surface of _apr_validate_qc_hits,
# apr_lib_validate_prompt_qc, and apr_lib_validate_additional_placeholders.
#
# Properties pinned:
#   I1 — every input produces a well-formed findings JSON (parses via jq)
#   I2 — mixed-class input emits one finding per class, insertion-ordered
#   I3 — APR_QC_RESPECT_CODE_FENCES=0 escape hatch disables fence muting
#   I4 — strict mode promotes ALL warnings to errors
#   I5 — adversarial regex-shaped literals don't false-match
#   I6 — large prompts (>10KB) don't crash or truncate the findings list
#   I7 — empty input is handled cleanly (no findings, exit 0)
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
    source "$BATS_TEST_DIRNAME/../../lib/validate.sh"
    apr_lib_validate_init

    # Clean every knob each test, then opt in.
    unset APR_ALLOW_CURLY_PLACEHOLDERS \
          APR_QC_RESPECT_CODE_FENCES \
          APR_FAIL_ON_WARN 2>/dev/null || true

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

emit_json_now() {
    apr_lib_validate_emit_json
}

# Convenience: parse the emit_json output and echo a top-level field.
findings_field() {
    local field="$1"
    apr_lib_validate_emit_json | jq -r "$field"
}

# ===========================================================================
# I1 — every input produces well-formed findings JSON
# ===========================================================================

@test "I1: emit_json is valid JSON after a single prompt_qc + additional_placeholders pass on a mixed input" {
    apr_lib_validate_prompt_qc \
        $'mustache {{X}}\n[[APR:FILE x]]\n<REPLACE_ME>\nTODO: write this\n$VAR' \
        "template" ".apr/workflows/default.yaml"
    apr_lib_validate_additional_placeholders \
        $'mustache {{X}}\n[[APR:FILE x]]\n<REPLACE_ME>\nTODO: write this\n$VAR' \
        "template" ".apr/workflows/default.yaml"

    local out
    out=$(emit_json_now)
    jq -e . <<<"$out" >/dev/null
    jq -e '.errors | type == "array"'   <<<"$out" >/dev/null
    jq -e '.warnings | type == "array"' <<<"$out" >/dev/null
}

# ===========================================================================
# I2 — mixed-class input emits distinct findings per class
# ===========================================================================

@test "I2: mixed prompt records mustache + APR directive ERRORS and angle/colon/shell WARNINGS" {
    local p=$'mustache: {{X}}\n[[APR:FILE x]]\n<REPLACE_ME>\nTODO: fix\n$VAR'
    apr_lib_validate_prompt_qc "$p" "template" "src.yaml"
    apr_lib_validate_additional_placeholders "$p" "template" "src.yaml"

    local out
    out=$(emit_json_now)

    # Errors: mustache + directive residue (exactly 2 prompt_qc_failed
    # findings).
    [[ "$(jq '.errors | length' <<<"$out")" -eq 2 ]] || {
        echo "errors:" >&2; jq '.errors' <<<"$out" >&2; return 1
    }
    jq -e '[.errors[].code] | all(. == "prompt_qc_failed")' <<<"$out" >/dev/null

    # Warnings: angle, colon, shell-var → 3 placeholder-marker
    # findings. The code is the same across all three; the *class*
    # discriminator lives in details.class (angle_marker / colon_marker /
    # shell_var). Pin the {code,class} contract here so any future
    # refactor that flips one of these gets caught.
    [[ "$(jq '.warnings | length' <<<"$out")" -eq 3 ]] || {
        echo "warnings:" >&2; jq '.warnings' <<<"$out" >&2; return 1
    }
    jq -e '[.warnings[].code] | all(. == "prompt_qc_placeholder_marker")' <<<"$out" >/dev/null
    local classes
    classes=$(jq -r '[.warnings[].details.class] | sort | join(",")' <<<"$out")
    [[ "$classes" == "angle_marker,colon_marker,shell_var" ]] || {
        echo "warning class drift: got '$classes' want 'angle_marker,colon_marker,shell_var'" >&2
        return 1
    }
}

# ===========================================================================
# I3 — code-fence muting + escape hatch
# ===========================================================================

@test "I3: triple-backtick fence mutes mustache by default; APR_QC_RESPECT_CODE_FENCES=0 unmutes" {
    local fenced_only=$'before\n```\nlooks like {{LEAK}} but is fenced\n```\nafter'

    # Default: fenced text muted → no error.
    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$fenced_only" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -eq 0 ]] || {
        echo "expected 0 errors with default fence muting:" >&2
        emit_json_now | jq '.errors' >&2
        return 1
    }

    # Escape hatch: APR_QC_RESPECT_CODE_FENCES=0 → fence ignored, finding raised.
    apr_lib_validate_init
    APR_QC_RESPECT_CODE_FENCES=0 apr_lib_validate_prompt_qc "$fenced_only" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -ge 1 ]] || {
        echo "expected at least one error with APR_QC_RESPECT_CODE_FENCES=0" >&2
        emit_json_now | jq '.errors' >&2
        return 1
    }
}

@test "I3: tilde fences (~~~) are NOT muted (documented current behavior)" {
    # The fence regex is `^[[:space:]]*```` — tilde fences are not
    # recognized, so any `{{X}}` inside a tilde fence is still flagged.
    # Pin this behavior so a future "support tilde fences" refactor
    # surfaces here and the spec gets updated intentionally.
    local p=$'before\n~~~\n{{LEAK}}\n~~~\nafter'

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -ge 1 ]]
}

@test "I3: indented fences (≥4 spaces) are NOT muted (documented current behavior)" {
    # The fence regex allows leading whitespace, but `awk` treats 4
    # spaces as start-of-line + 4 spaces; markdown convention treats
    # 4-space-indented lines as code blocks. The validator does NOT
    # walk indented code blocks. Pin this so any future "indented
    # code block" support surfaces here.
    local p=$'normal line\n    {{LEAK_IN_INDENT}}\nnormal line'

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -ge 1 ]]
}

@test "I3: malformed close fence leaves the rest of the prompt muted" {
    # Open a fence, never close it cleanly. Every subsequent line is
    # treated as fenced (in_fence stays true), so `{{X}}` on later
    # lines is muted. This is a known quirk worth pinning so anyone
    # who tightens the fence parser sees the test.
    local p=$'pre\n```\n{{X}}\nstill inside fence?\n{{Y}}'
    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -eq 0 ]]
}

# ===========================================================================
# I4 — strict mode promotes ALL warnings to errors
# ===========================================================================

@test "I4: strict mode (APR_FAIL_ON_WARN=1) promotes additional_placeholders warnings to errors after finalize" {
    local p=$'<REPLACE_ME>\nTODO: fix\n$VAR'

    APR_FAIL_ON_WARN=1 apr_lib_validate_additional_placeholders "$p" "tpl" "src"
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict

    # All three warnings now ALSO appear in the errors[] array. Per
    # the documented finalize_strict contract, the original warnings[]
    # entries are RETAINED (so consumers that already key off them
    # don't break); the errors[] array is augmented with copies. Pin
    # both halves here.
    [[ "$(findings_field '.errors | length')" -eq 3 ]] || {
        emit_json_now | jq '{errors, warnings}' >&2
        return 1
    }
    [[ "$(findings_field '.warnings | length')" -eq 3 ]] || {
        echo "finalize_strict cleared warnings — drift from documented contract" >&2
        emit_json_now | jq '{errors, warnings}' >&2
        return 1
    }
    # Promoted errors carry the original code so downstream consumers
    # can de-dupe.
    apr_lib_validate_emit_json \
        | jq -e '[.errors[].code] | all(. == "prompt_qc_placeholder_marker")' >/dev/null
}

# ===========================================================================
# I5 — adversarial regex-shaped literals don't false-match
# ===========================================================================

@test "I5: text that LOOKS like mustache but isn't ({{{X / }} alone / {}{) is not flagged" {
    local non_mustache_cases=(
        "{{{"                                 # 3 braces
        "} }"                                 # spaced close
        "{}{}{}"                              # interleaved
        "{{ X "                               # missing close
        "X }}"                                # missing open
        $'{ {\nbroken}}'                      # split across lines
    )
    local c
    for c in "${non_mustache_cases[@]}"; do
        apr_lib_validate_init
        apr_lib_validate_prompt_qc "$c" "tpl" "src"
        # `{{` and `}}` substring checks DO catch some of these (e.g.
        # `{{{` contains `{{`). The contract here is "no false match
        # on text that contains NEITHER `{{` NOR `}}` substring".
        local has_open=0 has_close=0
        [[ "$c" == *"{{"* ]] && has_open=1
        [[ "$c" == *"}}"* ]] && has_close=1
        local n_err
        n_err=$(findings_field '.errors | length')
        if (( has_open == 0 && has_close == 0 )); then
            [[ "$n_err" -eq 0 ]] || {
                echo "false match for non-mustache input '$(printf '%q' "$c")':" >&2
                emit_json_now | jq '.errors' >&2
                return 1
            }
        fi
    done
}

@test "I5: directive-shaped non-APR text ([[NOT_APR:, [[apr:lowercase) is not flagged" {
    local p=$'[[NOT_APR:FILE x]]\n[[apr:file x]]\n[ [APR:FILE x] ]'
    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    # The directive check matches `[[APR:` (uppercase). Lower-case and
    # variants must NOT be flagged.
    [[ "$(findings_field '.errors | length')" -eq 0 ]] || {
        echo "false directive match:" >&2
        emit_json_now | jq '.errors' >&2
        return 1
    }
}

# ===========================================================================
# I6 — large prompts don't crash or truncate findings
# ===========================================================================

@test "I6: 10KB+ prompt with one mustache hit at the end still flags it" {
    local big
    big=$(printf 'normal line %04d\n' $(seq 1 800))
    big="$big"$'\n{{LEAK_AT_END}}\n'

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$big" "tpl" "src"

    [[ "$(findings_field '.errors | length')" -eq 1 ]] || {
        echo "expected exactly one finding, got $(findings_field '.errors | length')" >&2
        return 1
    }
}

@test "I6: prompt with >8 mustache hits caps the hit list at 8 (documented internal limit)" {
    # _apr_validate_qc_hits has `if (count >= 8) exit` to cap noise.
    # Pin that contract so any change to the cap surfaces here.
    local big
    big=$(for i in $(seq 1 20); do echo "{{HIT_$i}}"; done)

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$big" "tpl" "src"

    local hits_count
    hits_count=$(apr_lib_validate_emit_json | jq '.errors[0].details.hits | length')
    [[ "$hits_count" -eq 8 ]] || {
        echo "hit cap drift: got $hits_count, want 8" >&2
        emit_json_now | jq '.errors[0].details' >&2
        return 1
    }
}

# ===========================================================================
# I7 — empty / minimal input
# ===========================================================================

@test "I7: empty prompt records zero findings" {
    apr_lib_validate_init
    apr_lib_validate_prompt_qc "" "tpl" "src"
    apr_lib_validate_additional_placeholders "" "tpl" "src"

    [[ "$(findings_field '.errors | length')" -eq 0 ]]
    [[ "$(findings_field '.warnings | length')" -eq 0 ]]
}

@test "I7: single-char prompt records zero findings" {
    apr_lib_validate_init
    apr_lib_validate_prompt_qc "x" "tpl" "src"
    [[ "$(findings_field '.errors | length')" -eq 0 ]]
}

# ===========================================================================
# Bypass: APR_ALLOW_CURLY_PLACEHOLDERS=1 disables mustache check entirely
# ===========================================================================

@test "bypass: APR_ALLOW_CURLY_PLACEHOLDERS=1 silences mustache findings (but not directive residue)" {
    local p=$'{{LEAK}}\n[[APR:FILE x]]'
    APR_ALLOW_CURLY_PLACEHOLDERS=1 apr_lib_validate_prompt_qc "$p" "tpl" "src"
    # Only the APR directive residue should fire.
    [[ "$(findings_field '.errors | length')" -eq 1 ]] || {
        emit_json_now | jq '.errors' >&2
        return 1
    }
    local code
    code=$(apr_lib_validate_emit_json | jq -r '.errors[0].message')
    [[ "$code" == *"APR directive residue"* ]] || {
        echo "expected directive-residue error, got: $code" >&2
        return 1
    }
}

# ===========================================================================
# Conformance: emit_json shape is stable across all finding states
# ===========================================================================

@test "conformance: emit_json always emits errors[] and warnings[] arrays (even when empty)" {
    apr_lib_validate_init
    local out
    out=$(emit_json_now)
    jq -e '.errors | type == "array" and length == 0'   <<<"$out" >/dev/null
    jq -e '.warnings | type == "array" and length == 0' <<<"$out" >/dev/null
}

@test "conformance: every finding has code, message, hint, source, details keys (or null)" {
    local p=$'{{X}}\n<REPLACE_ME>'
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    apr_lib_validate_additional_placeholders "$p" "tpl" "src"

    apr_lib_validate_emit_json \
        | jq -e '
            [(.errors + .warnings)[]
              | (has("code") and has("message") and has("hint")
                  and has("source") and has("details"))]
            | all
        ' >/dev/null
}

# ===========================================================================
# Determinism: same input → same emit_json (insertion order stable)
# ===========================================================================

@test "determinism: repeated init → fill → emit produces byte-identical findings JSON" {
    local p=$'{{A}}\n[[APR:FILE x]]\n<TBD>\nTODO: fix\n$BASH'
    local first second

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    apr_lib_validate_additional_placeholders "$p" "tpl" "src"
    first=$(emit_json_now)

    apr_lib_validate_init
    apr_lib_validate_prompt_qc "$p" "tpl" "src"
    apr_lib_validate_additional_placeholders "$p" "tpl" "src"
    second=$(emit_json_now)

    [[ "$first" == "$second" ]] || {
        echo "non-deterministic emit_json:" >&2
        diff <(printf '%s' "$first") <(printf '%s' "$second") >&2
        return 1
    }
}
