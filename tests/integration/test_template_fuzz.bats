#!/usr/bin/env bats
# test_template_fuzz.bats
#
# Bead automated_plan_reviser_pro-jrxn — fuzz / property suite for the
# lib/template.sh directive parser.
#
# tests/unit/test_template.bats covers each directive in isolation.
# tests/integration/test_template_golden.bats freezes happy-path
# expansions byte-for-byte. This file picks up the remaining failure
# class — *adversarial* and *malformed* templates — and asserts that no
# input, well-formed or otherwise, can:
#
#   - crash the bash interpreter (I1)
#   - produce an undocumented error reason on failure (I2)
#   - leave half-expanded `[[APR:` text in the success output (I3)
#   - leak `{{...}}` placeholder syntax into the success output (I4)
#   - read an absolute or `..`-traversal path without explicit opt-in (I5)
#   - produce non-deterministic output for the same input (I6)
#   - re-expand LIT bodies (I7)
#
# Inputs come from two sources:
#   1. A categorized hand-curated corpus (one entry per failure mode +
#      one per safety guard) — readable and easy to extend.
#   2. A deterministic grammar generator (fixed seed) that combines
#      legal/illegal directive shapes around random text bodies.
#
# All inputs go through every applicable invariant.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Reason taxonomy (must stay in sync with lib/template.sh)
# ---------------------------------------------------------------------------

DOCUMENTED_REASONS=(
    absolute_path_blocked
    bad_arg_excerpt_n
    bad_args
    close_marker_in_path
    empty_path
    file_not_found
    file_unreadable
    symlink_traversal_blocked
    traversal_blocked
    unknown_type
    unterminated_directive
)

is_documented_reason() {
    local r="$1"
    local known
    for known in "${DOCUMENTED_REASONS[@]}"; do
        [[ "$r" == "$known" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    PROJECT_ROOT="$TEST_DIR/template_project"
    mkdir -p "$PROJECT_ROOT/docs"
    # Small, byte-deterministic source documents so SHA/SIZE outputs are
    # stable across machines.
    printf 'readme line one\nreadme line two\n' > "$PROJECT_ROOT/docs/readme.md"
    printf 'spec body\n'                          > "$PROJECT_ROOT/docs/spec.md"
    printf 'binary-ish: \x01\x02hello\n'          > "$PROJECT_ROOT/docs/bin.md"
    export PROJECT_ROOT

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/template.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Property driver
# ---------------------------------------------------------------------------
#
# run_input <label> <expected: ok|fail|either> <input> [<expected_reason>]
#
# Runs apr_lib_template_expand against the input under the default safety
# settings (no traversal, no absolute, non-verbose) and asserts the
# invariants applicable to the outcome.
#
# expected = ok      → must succeed; I3 + I4 + I7 enforced
# expected = fail    → must fail; I2 enforced; expected_reason optional
# expected = either  → outcome not constrained; only I1 + I2 enforced
#
# I1 (no crash) is always enforced via the rc-is-integer guard below.
# I6 (determinism) is verified in a dedicated @test against the full corpus.

run_input() {
    local label="$1"
    local expected="$2"
    local input="$3"
    local want_reason="${4:-}"

    local actual="$ARTIFACT_DIR/${label//[^A-Za-z0-9_]/_}.out"
    local err="$ARTIFACT_DIR/${label//[^A-Za-z0-9_]/_}.err"

    set +e
    apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 \
        > "$actual" 2> "$err"
    local rc=$?
    set -e

    # I1: rc must be an integer (proxy for "shell didn't crash"). With
    # `set -e` disabled above, even a non-zero rc from a builtin or
    # path-fail surfaces here as a number — the only way to fail I1 is
    # for the call itself to crash the shell, which would short-circuit
    # this entire test.
    [[ "$rc" =~ ^[0-9]+$ ]] || {
        echo "I1: rc not numeric for '$label': rc='$rc'" >&2
        return 1
    }

    case "$expected" in
        ok)
            if [[ "$rc" -ne 0 ]]; then
                echo "[$label] expected ok, got rc=$rc; reason='$APR_TEMPLATE_ERROR_REASON'" >&2
                echo "--- stderr ---" >&2; cat "$err" >&2
                echo "--- output ---" >&2; cat "$actual" >&2
                return 1
            fi
            # I3: no half-expanded directive marker remains. LIT inputs
            # deliberately *embed* directive-shaped literals; the
            # invariant is "no UNHANDLED `[[APR:` survives", which we
            # can't tell apart from a legitimate LIT body, so skip I3
            # when the input asked for LIT verbatim text.
            if [[ "$input" != *"[[APR:LIT"* ]]; then
                if grep -Fq '[[APR:' "$actual"; then
                    echo "[$label] I3 violation: '[[APR:' left in successful output:" >&2
                    cat "$actual" >&2
                    return 1
                fi
            fi
            # I4: no `{{` / `}}` placeholder syntax.
            if grep -Fq -e '{{' -e '}}' "$actual"; then
                echo "[$label] I4 violation: mustache placeholder in output:" >&2
                cat "$actual" >&2
                return 1
            fi
            ;;
        fail)
            if [[ "$rc" -eq 0 ]]; then
                echo "[$label] expected failure, got rc=0:" >&2
                cat "$actual" >&2
                return 1
            fi
            # I2: failure must carry a documented reason.
            is_documented_reason "$APR_TEMPLATE_ERROR_REASON" || {
                echo "[$label] I2 violation: undocumented reason '$APR_TEMPLATE_ERROR_REASON'" >&2
                return 1
            }
            if [[ -n "$want_reason" && "$APR_TEMPLATE_ERROR_REASON" != "$want_reason" ]]; then
                echo "[$label] reason mismatch: want='$want_reason' got='$APR_TEMPLATE_ERROR_REASON'" >&2
                return 1
            fi
            ;;
        either)
            if [[ "$rc" -ne 0 ]]; then
                is_documented_reason "$APR_TEMPLATE_ERROR_REASON" || {
                    echo "[$label] I2 violation under 'either': undocumented reason '$APR_TEMPLATE_ERROR_REASON'" >&2
                    return 1
                }
            fi
            ;;
        *)
            echo "[$label] unknown expectation: $expected" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Hand-curated adversarial corpus
# ---------------------------------------------------------------------------
#
# Layout: each entry is "label::expected::reason_or_empty::input".
# Inputs may contain newlines (encoded as $'\n').
#
# The function below emits one entry per line on stdout so individual
# @tests can iterate without re-typing the corpus.

emit_corpus() {
    # ---- Legal (must succeed) ----
    printf 'legal_plain::ok::::%s\n' "no directives at all, just plain text"
    printf 'legal_file::ok::::%s\n' "before [[APR:FILE docs/readme.md]] after"
    printf 'legal_sha::ok::::%s\n' "sha=[[APR:SHA docs/readme.md]]"
    printf 'legal_size::ok::::%s\n' "size=[[APR:SIZE docs/spec.md]] bytes"
    printf 'legal_excerpt_small::ok::::%s\n' "[[APR:EXCERPT docs/readme.md 5]]"
    printf 'legal_excerpt_huge_n::ok::::%s\n' "[[APR:EXCERPT docs/readme.md 99999]]"
    printf 'legal_lit::ok::::%s\n' "[[APR:LIT literal body here]]"
    printf 'legal_lit_protects_inner::ok::::%s\n' "[[APR:LIT [[APR:FILE evil.md]]]]"
    printf 'legal_multiple_inline::ok::::%s\n' "a=[[APR:SIZE docs/readme.md]] b=[[APR:SIZE docs/spec.md]]"
    printf 'legal_multiline::ok::::%s\n' "line1\nline2 [[APR:SIZE docs/readme.md]]\nline3"

    # ---- Parser errors (unterminated / bad args / unknown TYPE) ----
    printf 'fail_unterminated::fail::unterminated_directive::%s\n' "before [[APR:FILE docs/readme.md without close marker"
    printf 'fail_unterminated_at_eof::fail::unterminated_directive::%s\n' "[[APR:"
    printf 'fail_unknown_type::fail::unknown_type::%s\n' "[[APR:EXEC rm -rf /]]"
    printf 'fail_unknown_type_lowercase::fail::unknown_type::%s\n' "[[APR:file docs/readme.md]]"
    printf 'fail_unknown_type_mixedcase::fail::unknown_type::%s\n' "[[APR:File docs/readme.md]]"
    printf 'fail_unknown_type_numeric::fail::unknown_type::%s\n' "[[APR:42 some-arg]]"
    printf 'fail_empty_body::fail::bad_args::%s\n' "[[APR:]]"
    printf 'fail_file_no_arg::fail::bad_args::%s\n' "[[APR:FILE]]"
    printf 'fail_sha_no_arg::fail::bad_args::%s\n' "[[APR:SHA]]"
    printf 'fail_size_no_arg::fail::bad_args::%s\n' "[[APR:SIZE]]"
    printf 'fail_excerpt_no_args::fail::bad_args::%s\n' "[[APR:EXCERPT]]"
    printf 'fail_excerpt_one_arg::fail::bad_args::%s\n' "[[APR:EXCERPT docs/readme.md]]"
    printf 'fail_excerpt_bad_n::fail::bad_arg_excerpt_n::%s\n' "[[APR:EXCERPT docs/readme.md NaN]]"
    printf 'fail_excerpt_zero_n::fail::bad_arg_excerpt_n::%s\n' "[[APR:EXCERPT docs/readme.md 0]]"
    printf 'fail_excerpt_neg_n::fail::bad_arg_excerpt_n::%s\n' "[[APR:EXCERPT docs/readme.md -1]]"

    # ---- Path safety guards (must reject by default) ----
    printf 'fail_absolute_path::fail::absolute_path_blocked::%s\n' "[[APR:FILE /etc/passwd]]"
    printf 'fail_absolute_path_sha::fail::absolute_path_blocked::%s\n' "[[APR:SHA /etc/passwd]]"
    printf 'fail_traversal_dotdot::fail::traversal_blocked::%s\n' "[[APR:FILE ../../etc/passwd]]"
    printf 'fail_traversal_in_middle::fail::traversal_blocked::%s\n' "[[APR:FILE docs/../../etc/passwd]]"
    printf 'fail_traversal_size::fail::traversal_blocked::%s\n' "[[APR:SIZE ../../../shadow]]"
    printf 'fail_missing_file::fail::file_not_found::%s\n' "[[APR:FILE docs/nope.md]]"
    printf 'fail_missing_excerpt::fail::file_not_found::%s\n' "[[APR:EXCERPT docs/nope.md 10]]"
    # Whitespace-only arg collapses to zero arg tokens → bad_args (the
    # `empty_path` reason is reachable only via direct calls into the
    # path validator and is therefore excluded from the corpus-coverage
    # check below).
    printf 'fail_whitespace_only_arg::fail::bad_args::%s\n' "[[APR:FILE  ]]"

    # ---- Stress / edge cases (outcome not constrained, but no crash) ----
    printf 'edge_just_brackets::either::::%s\n' "[[[[]]]]"
    printf 'edge_nested_open::either::::%s\n' "[[APR:[[APR:FILE x]]"
    printf 'edge_binary_in_arg::either::::%s\n' "[[APR:FILE docs/bin.md]]"
    printf 'edge_lots_of_close_markers::either::::%s\n' "[[APR:FILE x]]]]]]]]"
    printf 'edge_directive_within_xml::ok::::%s\n' "<readme>[[APR:FILE docs/readme.md]]</readme>"
    printf 'edge_only_close_markers::either::::%s\n' "]] ]] ]]"
    printf 'edge_directive_at_eof_no_newline::ok::::%s\n' "before [[APR:SIZE docs/readme.md]]"
    printf 'edge_repeated_directive::ok::::%s\n' "[[APR:SIZE docs/readme.md]][[APR:SIZE docs/readme.md]][[APR:SIZE docs/readme.md]]"

    # ---- Byte-noise (random-looking; must not crash) ----
    # The parser splits on `]]` so a stray `]]` inside an arg can never
    # reach the path validator's `close_marker_in_path` branch through
    # template syntax. The parser instead terminates the directive at
    # the first `]]` and the remainder becomes trailing text. We pin
    # that early-termination behavior here:
    printf 'noise_ctrl_chars::either::::%s\n' "$(printf 'a\x01\x02\x03\x04[[APR:FILE docs/readme.md]]\x05\x06')"
    printf 'noise_long_args::either::::%s\n' "[[APR:FILE $(printf 'a%.0s' $(seq 1 200))]]"
    printf 'noise_close_marker_in_arg::fail::file_not_found::%s\n' "[[APR:FILE docs/has]]inside]]"
}

# ---------------------------------------------------------------------------
# Grammar-based generator (deterministic, no randomness)
# ---------------------------------------------------------------------------
#
# Produce a stable set of templates from a small recursive grammar:
#
#   template := piece+
#   piece    := text | directive | malformed
#   text     := one of a fixed corpus of literal fragments
#   directive:= FILE | SHA | SIZE | EXCERPT | LIT | UNKNOWN
#
# Rotation through fixed lists keeps the output byte-stable across runs
# (no $RANDOM, no /dev/urandom). The harness still treats every
# generated template as a fuzz input: each one is fed through run_input.

emit_grammar_inputs() {
    local pieces=(
        "intro: "
        "context "
        "trailer "
        ""
        "section A "
        " --- "
    )
    local directives=(
        "[[APR:FILE docs/readme.md]]"
        "[[APR:FILE docs/spec.md]]"
        "[[APR:SHA docs/readme.md]]"
        "[[APR:SIZE docs/readme.md]]"
        "[[APR:EXCERPT docs/spec.md 4]]"
        "[[APR:LIT inner literal]]"
        "[[APR:LIT [[APR:FILE ignored.md]]]]"
        "[[APR:UNKNOWN garbage]]"
        "[[APR:FILE ../../etc/passwd]]"
        "[[APR:FILE /etc/passwd]]"
        "[[APR:FILE docs/nope.md]]"
        "[[APR:EXCERPT docs/readme.md notanumber]]"
        "[[APR:"
    )
    local idx=0
    local p_count=${#pieces[@]}
    local d_count=${#directives[@]}

    # 30 templates; iterate p_count × d_count combinations modulo each.
    local i
    for ((i = 0; i < 30; i++)); do
        local p1="${pieces[$((i % p_count))]}"
        local d1="${directives[$((i % d_count))]}"
        local d2="${directives[$(((i + 3) % d_count))]}"
        local p2="${pieces[$(((i + 2) % p_count))]}"
        idx=$((idx + 1))
        # Emit "label::either::::<template>" — outcome not constrained
        # for generated inputs because the combination of legal +
        # illegal directives can resolve either way; what matters is no
        # crash and that any error has a documented reason.
        printf 'grammar_%02d::either::::%s\n' "$idx" "$p1$d1$p2$d2"
    done
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "fuzz: hand-curated corpus — every entry satisfies its invariants" {
    local line label expected reason input
    local count=0 failed=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='::' read -r label _ expected _ reason _ input <<<"$line"
        # split on '::' loses the trailing input bytes if they contain '::';
        # use cut as a robust fallback.
        label=$(   printf '%s' "$line" | awk -F'::' '{print $1}')
        expected=$(printf '%s' "$line" | awk -F'::' '{print $2}')
        reason=$(  printf '%s' "$line" | awk -F'::' '{print $3}')
        input=$(   printf '%s' "$line" | awk -F'::' '{for(i=4;i<=NF;i++){printf("%s%s",$i,(i<NF?"::":""))}}')
        # Decode `\n` literals to actual newlines.
        input=$(printf '%b' "$input")
        count=$((count + 1))
        if ! run_input "$label" "$expected" "$input" "$reason"; then
            failed=$((failed + 1))
        fi
    done < <(emit_corpus)

    if (( failed > 0 )); then
        echo "fuzz corpus: $failed / $count entries failed invariants" >&2
        return 1
    fi
    echo "fuzz corpus: $count entries passed every applicable invariant" >&2
}

@test "fuzz: grammar-generated templates — no crashes, any error has a documented reason" {
    local line label expected reason input
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        label=$(   printf '%s' "$line" | awk -F'::' '{print $1}')
        expected=$(printf '%s' "$line" | awk -F'::' '{print $2}')
        reason=$(  printf '%s' "$line" | awk -F'::' '{print $3}')
        input=$(   printf '%s' "$line" | awk -F'::' '{for(i=4;i<=NF;i++){printf("%s%s",$i,(i<NF?"::":""))}}')
        count=$((count + 1))
        run_input "$label" "$expected" "$input" "$reason"
    done < <(emit_grammar_inputs)
    [[ "$count" -ge 30 ]]
}

@test "fuzz: I5 — opt-in flags do unlock the absolute-path branch (negative-of-negative)" {
    # Belt-and-braces: the path-safety invariant is "rejected *without*
    # explicit opt-in". To prove the guard is doing real work (rather
    # than blocking unconditionally), point at a real file through a
    # ../ path and verify the opt-in flag accepts it.

    # Create a sibling file outside PROJECT_ROOT.
    local outside="$TEST_DIR/outside.md"
    printf 'i live outside\n' > "$outside"
    # ../outside.md is reachable from PROJECT_ROOT via traversal.
    local input="[[APR:FILE ../outside.md]]"

    set +e
    apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 \
        >"$ARTIFACT_DIR/no_optin.out" 2>"$ARTIFACT_DIR/no_optin.err"
    local rc_default=$?
    local reason_default="$APR_TEMPLATE_ERROR_REASON"

    apr_lib_template_expand "$input" "$PROJECT_ROOT" 1 0 0 \
        >"$ARTIFACT_DIR/with_optin.out" 2>"$ARTIFACT_DIR/with_optin.err"
    local rc_optin=$?
    set -e

    # Default → traversal blocked.
    [[ "$rc_default" -ne 0 ]]
    [[ "$reason_default" == "traversal_blocked" ]] || {
        echo "expected traversal_blocked, got '$reason_default'" >&2
        return 1
    }

    # Opt-in → success, content inlined.
    [[ "$rc_optin" -eq 0 ]] || {
        echo "opt-in path read still failed: rc=$rc_optin" >&2
        cat "$ARTIFACT_DIR/with_optin.err" >&2
        return 1
    }
    grep -Fq 'i live outside' "$ARTIFACT_DIR/with_optin.out"
}

@test "fuzz: I5 — absolute paths likewise unlock under allow_absolute opt-in" {
    # Drop a file *inside* PROJECT_ROOT so the symlink/realpath
    # confinement check (which is gated by allow_traversal, not
    # allow_absolute) is satisfied; allow_absolute alone then proves
    # the leading-slash policy specifically.
    local inside="$PROJECT_ROOT/docs/inside.md"
    printf 'absolute body inside\n' > "$inside"
    local input="[[APR:FILE ${inside}]]"

    set +e
    apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 \
        >"$ARTIFACT_DIR/abs_no.out" 2>/dev/null
    local rc_default=$?
    local reason_default="$APR_TEMPLATE_ERROR_REASON"

    apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 1 0 \
        >"$ARTIFACT_DIR/abs_yes.out" 2>/dev/null
    local rc_optin=$?
    set -e

    [[ "$rc_default" -ne 0 && "$reason_default" == "absolute_path_blocked" ]] || {
        echo "default path did not block absolute: rc=$rc_default reason=$reason_default" >&2
        return 1
    }
    [[ "$rc_optin" -eq 0 ]] || {
        echo "allow_absolute=1 did not unlock the read: rc=$rc_optin reason=$APR_TEMPLATE_ERROR_REASON" >&2
        return 1
    }
    grep -Fq 'absolute body inside' "$ARTIFACT_DIR/abs_yes.out"
}

@test "fuzz: I6 — every corpus + grammar input is deterministic across two runs" {
    # Concatenate both input sources; for each, expand twice and diff.
    local mismatches=0
    local source
    for source in emit_corpus emit_grammar_inputs; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local label input
            label=$(printf '%s' "$line" | awk -F'::' '{print $1}')
            input=$(printf '%s' "$line" | awk -F'::' '{for(i=4;i<=NF;i++){printf("%s%s",$i,(i<NF?"::":""))}}')
            input=$(printf '%b' "$input")

            local out1="$ARTIFACT_DIR/${label//[^A-Za-z0-9_]/_}.run1"
            local out2="$ARTIFACT_DIR/${label//[^A-Za-z0-9_]/_}.run2"

            set +e
            apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 >"$out1" 2>/dev/null
            local r1=$?
            local reason1="$APR_TEMPLATE_ERROR_REASON"
            apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 >"$out2" 2>/dev/null
            local r2=$?
            local reason2="$APR_TEMPLATE_ERROR_REASON"
            set -e

            if [[ "$r1" -ne "$r2" || "$reason1" != "$reason2" ]]; then
                echo "[$label] non-deterministic rc/reason: r1=$r1/$reason1 r2=$r2/$reason2" >&2
                mismatches=$((mismatches + 1))
                continue
            fi
            if ! diff -q "$out1" "$out2" >/dev/null 2>&1; then
                echo "[$label] non-deterministic output:" >&2
                diff -u "$out1" "$out2" >&2
                mismatches=$((mismatches + 1))
            fi
        done < <("$source")
    done

    if (( mismatches > 0 )); then
        echo "I6 violations: $mismatches inputs were non-deterministic" >&2
        return 1
    fi
}

@test "fuzz: I7 — LIT body content never re-expands even when it contains directive syntax" {
    # Belt-and-braces against the LIT scoping rule: an inner directive
    # token sitting inside a LIT body must come through verbatim.
    local cases=(
        "[[APR:LIT [[APR:FILE evil.md]]]]"
        "[[APR:LIT [[APR:SHA also.md]] more]]"
        "[[APR:LIT [[APR:LIT inception]]]]"
    )
    local input
    for input in "${cases[@]}"; do
        local actual="$ARTIFACT_DIR/lit_$(printf '%s' "$input" | md5sum | cut -c1-8).out"
        set +e
        apr_lib_template_expand "$input" "$PROJECT_ROOT" 0 0 0 > "$actual" 2>/dev/null
        local rc=$?
        set -e
        [[ "$rc" -eq 0 ]] || {
            echo "LIT failed unexpectedly for '$input' (rc=$rc, reason=$APR_TEMPLATE_ERROR_REASON)" >&2
            return 1
        }
        # The "inner" directive must remain as literal text. We can
        # detect re-expansion by checking that `[[APR:` still appears
        # somewhere in the output for inputs that contained it.
        if [[ "$input" == *"[[APR:FILE"* || "$input" == *"[[APR:SHA"* || "$input" == *"[[APR:LIT inception"* ]]; then
            grep -Fq '[[APR:' "$actual" || {
                echo "[I7] LIT body was re-expanded for '$input':" >&2
                cat "$actual" >&2
                return 1
            }
        fi
    done
}

@test "fuzz: corpus coverage — every documented reason is exercised at least once" {
    # Without this safeguard the corpus could drift and silently stop
    # covering a reason after a refactor. Bind the corpus tightly to the
    # taxonomy.
    local seen
    declare -A seen=()
    local line reason
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        reason=$(printf '%s' "$line" | awk -F'::' '{print $3}')
        [[ -n "$reason" ]] && seen[$reason]=1
    done < <(emit_corpus)

    local missing=()
    local r
    for r in "${DOCUMENTED_REASONS[@]}"; do
        # Some reasons are not reachable through template syntax:
        #   - symlink_traversal_blocked / file_unreadable: need symlink
        #     or chmod 000 setup that's awkward across CI envs.
        #   - empty_path / close_marker_in_path: defensive internal-only
        #     branches; the parser pre-filters both shapes (whitespace
        #     collapses to bad_args; `]]` terminates the directive).
        case "$r" in
            symlink_traversal_blocked|file_unreadable|empty_path|close_marker_in_path) continue ;;
        esac
        [[ -n "${seen[$r]:-}" ]] || missing+=("$r")
    done

    if (( ${#missing[@]} > 0 )); then
        echo "corpus drift: these documented reasons have no exemplar:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}
