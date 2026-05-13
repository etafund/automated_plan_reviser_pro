#!/usr/bin/env bats
# test_validate.bats - Unit tests for lib/validate.sh (bd-30c)
#
# Validates the validation-pipeline core primitives:
#   - finding storage (add_error, add_warning, counts)
#   - JSON envelope shape ({errors, warnings})
#   - human rendering
#   - prompt_qc placeholder detection (mustache + APR directive residue)
#   - documents_exist (required vs optional, missing/unreadable/empty)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/validate.sh"
    apr_lib_validate_init
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# init / has_errors / counts
# =============================================================================

@test "init: clears all findings" {
    apr_lib_validate_add_error "x" "msg"
    apr_lib_validate_add_warning "y" "msg"
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    apr_lib_validate_init
    [ "$(apr_lib_validate_error_count)" = "0" ]
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "has_errors: false when no findings" {
    run apr_lib_validate_has_errors
    [ "$status" -ne 0 ]
}

@test "has_errors: true after add_error" {
    apr_lib_validate_add_error "config_error" "missing"
    run apr_lib_validate_has_errors
    [ "$status" -eq 0 ]
}

@test "has_errors: false when only warnings recorded" {
    apr_lib_validate_add_warning "config_warning" "optional doc missing"
    run apr_lib_validate_has_errors
    [ "$status" -ne 0 ]
}

@test "first_error_code: empty when no errors" {
    run apr_lib_validate_first_error_code
    [ "$status" -eq 0 ]
    assert_output ""
}

@test "first_error_code: returns insertion-order first code" {
    apr_lib_validate_add_error "config_error" "a"
    apr_lib_validate_add_error "validation_failed" "b"
    run apr_lib_validate_first_error_code
    assert_output "config_error"
}

# =============================================================================
# emit_json: shape, escaping, ordering
# =============================================================================

@test "emit_json: empty -> {errors:[],warnings:[]}" {
    run apr_lib_validate_emit_json
    assert_success
    assert_output '{"errors":[],"warnings":[]}'
}

@test "emit_json: well-formed JSON with one error and one warning" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_validate_add_error "config_error" "missing readme" "Create README.md" "README.md" '{"path":"README.md"}'
    apr_lib_validate_add_warning "config_warning" "impl skipped" "" "docs/impl.md" "null"
    local out
    out=$(apr_lib_validate_emit_json)
    python3 -c "
import json, sys
d = json.loads('''$out''')
assert len(d['errors']) == 1
assert len(d['warnings']) == 1
assert d['errors'][0]['code'] == 'config_error'
assert d['errors'][0]['hint'] == 'Create README.md'
assert d['errors'][0]['details'] == {'path': 'README.md'}
assert d['warnings'][0]['code'] == 'config_warning'
assert d['warnings'][0]['details'] is None
"
}

@test "emit_json: special chars in message are JSON-escaped" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    # Use a message with embedded double quotes; the JSON output must
    # decode back to the original string. We route through a tempfile so
    # python doesn't have to navigate shell + python escape rules for the
    # backslashed JSON output.
    local raw='value="quoted" line'
    apr_lib_validate_add_error "x" "$raw" "" "" "null"
    local out_file="$BATS_TEST_TMPDIR/out.json"
    apr_lib_validate_emit_json > "$out_file"
    python3 -c "
import json
d = json.load(open('$out_file'))
assert d['errors'][0]['message'] == '$raw', d['errors'][0]['message']
"
}

@test "emit_json: insertion order preserved" {
    apr_lib_validate_add_error "a" "first"
    apr_lib_validate_add_error "b" "second"
    apr_lib_validate_add_error "c" "third"
    local out
    out=$(apr_lib_validate_emit_json)
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    python3 -c "
import json
d = json.loads('''$out''')
codes = [e['code'] for e in d['errors']]
assert codes == ['a','b','c'], codes
"
}

# =============================================================================
# emit_human: rendering
# =============================================================================

@test "emit_human: empty -> empty output" {
    run apr_lib_validate_emit_human
    assert_success
    assert_output ""
}

@test "emit_human: error includes code, message, hint, source" {
    apr_lib_validate_add_error "config_error" "missing readme" "Create README.md" "README.md" "null"
    run apr_lib_validate_emit_human
    assert_success
    assert_output --partial "ERROR [config_error]: missing readme"
    assert_output --partial "source: README.md"
    assert_output --partial "hint:   Create README.md"
}

@test "emit_human: warning rendered with WARN prefix" {
    apr_lib_validate_add_warning "config_warning" "optional file missing" "" "" "null"
    run apr_lib_validate_emit_human
    assert_output --partial "WARN  [config_warning]: optional file missing"
}

@test "emit_human: errors come before warnings" {
    apr_lib_validate_add_warning "w" "warn-msg"
    apr_lib_validate_add_error "e" "err-msg"
    local out
    out=$(apr_lib_validate_emit_human)
    local idx_err idx_warn
    idx_err=$(printf '%s' "$out" | grep -bo 'ERROR \[e\]' | head -1 | cut -d: -f1)
    idx_warn=$(printf '%s' "$out" | grep -bo 'WARN  \[w\]' | head -1 | cut -d: -f1)
    [ "$idx_err" -lt "$idx_warn" ]
}

# =============================================================================
# prompt_qc
# =============================================================================

@test "prompt_qc: no placeholders -> no findings" {
    apr_lib_validate_prompt_qc "Read the attached README and refine the spec."
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "prompt_qc: mustache placeholders -> prompt_qc_failed error" {
    apr_lib_validate_prompt_qc "Spec: {{README}}" "template" "workflow.yaml:42"
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [ "${_APR_VALIDATE_ERR_CODE[0]}" = "prompt_qc_failed" ]
    [[ "${_APR_VALIDATE_ERR_MSG[0]}" == *"{{"* ]]
    [ "${_APR_VALIDATE_ERR_SOURCE[0]}" = "workflow.yaml:42" ]
}

@test "prompt_qc: APR_ALLOW_CURLY_PLACEHOLDERS=1 disables mustache check" {
    APR_ALLOW_CURLY_PLACEHOLDERS=1 apr_lib_validate_prompt_qc "Spec: {{README}}" "template"
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "prompt_qc: APR directive residue -> prompt_qc_failed error" {
    apr_lib_validate_prompt_qc "Hash: [[APR:SHA r.md]]" "template"
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [[ "${_APR_VALIDATE_ERR_MSG[0]}" == *"directive residue"* ]]
}

@test "prompt_qc: both residues -> two errors" {
    apr_lib_validate_prompt_qc "{{README}} and [[APR:FILE x]]" "template"
    [ "$(apr_lib_validate_error_count)" = "2" ]
}

@test "prompt_qc: details contains line hits as JSON array" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input=$'line1\n{{README}}\nline3\n{{SPEC}}'
    apr_lib_validate_prompt_qc "$input" "tpl"
    local details="${_APR_VALIDATE_ERR_DETAILS[0]}"
    python3 -c "
import json
d = json.loads('''$details''')
assert d['label'] == 'tpl'
assert isinstance(d['hits'], list)
assert len(d['hits']) >= 1
"
}

# =============================================================================
# documents_exist
# =============================================================================

@test "documents_exist: all required present -> no findings" {
    printf 'content' > "$BATS_TEST_TMPDIR/a.md"
    printf 'more'    > "$BATS_TEST_TMPDIR/b.md"
    apr_lib_validate_documents_exist "$BATS_TEST_TMPDIR/a.md|$BATS_TEST_TMPDIR/b.md"
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "documents_exist: missing required -> config_error" {
    apr_lib_validate_documents_exist "$BATS_TEST_TMPDIR/missing.md"
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [ "${_APR_VALIDATE_ERR_CODE[0]}" = "config_error" ]
    [[ "${_APR_VALIDATE_ERR_MSG[0]}" == *"not found"* ]]
}

@test "documents_exist: empty required file -> config_error" {
    : > "$BATS_TEST_TMPDIR/empty.md"
    apr_lib_validate_documents_exist "$BATS_TEST_TMPDIR/empty.md"
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [[ "${_APR_VALIDATE_ERR_MSG[0]}" == *"empty"* ]]
}

@test "documents_exist: missing optional -> config_warning, no error" {
    apr_lib_validate_documents_exist "" "$BATS_TEST_TMPDIR/optional-missing.md"
    [ "$(apr_lib_validate_error_count)" = "0" ]
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [ "${_APR_VALIDATE_WARN_CODE[0]}" = "config_warning" ]
}

@test "documents_exist: mixed required + missing optional reports both correctly" {
    printf 'ok' > "$BATS_TEST_TMPDIR/r.md"
    apr_lib_validate_documents_exist "$BATS_TEST_TMPDIR/r.md" "$BATS_TEST_TMPDIR/maybe.md"
    [ "$(apr_lib_validate_error_count)" = "0" ]
    [ "$(apr_lib_validate_warning_count)" = "1" ]
}

@test "documents_exist: empty paths are skipped" {
    apr_lib_validate_documents_exist "" ""
    [ "$(apr_lib_validate_error_count)" = "0" ]
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

# =============================================================================
# bd-2lc: code-fence-aware prompt_qc
# =============================================================================

@test "prompt_qc bd-2lc: mustache inside code fence is IGNORED by default" {
    local input
    input=$'Real text.\n```\nEcho {{README}} here\n```\nMore real text.'
    apr_lib_validate_prompt_qc "$input" "template"
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "prompt_qc bd-2lc: mustache OUTSIDE fence is still flagged" {
    local input
    input=$'Real text.\n{{README}}\n```\nIgnored: {{X}}\n```\nMore.'
    apr_lib_validate_prompt_qc "$input" "template"
    [ "$(apr_lib_validate_error_count)" = "1" ]
}

@test "prompt_qc bd-2lc: APR_QC_RESPECT_CODE_FENCES=0 checks fenced text too" {
    local input
    input=$'```\nFenced {{X}}\n```'
    APR_QC_RESPECT_CODE_FENCES=0 apr_lib_validate_prompt_qc "$input" "template"
    [ "$(apr_lib_validate_error_count)" = "1" ]
}

@test "prompt_qc bd-2lc: strict mode forces fence check even with default flag" {
    local input
    input=$'```\nFenced {{X}}\n```'
    APR_FAIL_ON_WARN=1 apr_lib_validate_prompt_qc "$input" "template"
    [ "$(apr_lib_validate_error_count)" = "1" ]
}

@test "prompt_qc bd-2lc: directive residue inside fence is ignored by default" {
    local input
    input=$'doc text\n```\nexample: [[APR:FILE x]]\n```\nmore'
    apr_lib_validate_prompt_qc "$input" "template"
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

# =============================================================================
# bd-2lc: additional placeholder markers
# =============================================================================

@test "additional_placeholders: <REPLACE_ME> -> warning (default)" {
    apr_lib_validate_additional_placeholders "Insert <REPLACE_ME> here" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "additional_placeholders: <INSERT> + <FIXME> + <TBD> all trigger the angle-marker warning" {
    apr_lib_validate_additional_placeholders "Look at <INSERT>" "tpl"
    apr_lib_validate_additional_placeholders "And <FIXME>" "tpl"
    apr_lib_validate_additional_placeholders "And <TBD>" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "3" ]
}

@test "additional_placeholders: TODO:/TBD:/FIXME:/XXX: colon markers trigger warning" {
    apr_lib_validate_additional_placeholders "TODO: fix this later" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [ "${_APR_VALIDATE_WARN_CODE[0]}" = "prompt_qc_placeholder_marker" ]
}

@test "additional_placeholders: 'TODO' without colon is NOT flagged" {
    apr_lib_validate_additional_placeholders "TODO is a verb here, no colon" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders: 'GOTO:CASE' (no word boundary) is NOT flagged" {
    apr_lib_validate_additional_placeholders "switch GOTO:CASE_A" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders: angle marker inside code fence is ignored by default" {
    local input
    input=$'real text\n```\nexample <REPLACE_ME> here\n```\nmore real'
    apr_lib_validate_additional_placeholders "$input" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders: TODO: in code fence is ignored by default" {
    local input
    input=$'doc text\n```\nTODO: ignored in fence\n```\nmore'
    apr_lib_validate_additional_placeholders "$input" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders: strict mode escalates after finalize" {
    APR_FAIL_ON_WARN=1 apr_lib_validate_additional_placeholders "TODO: outside fence" "tpl"
    # Recorded as warning first.
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict
    # Now also surfaced as error so the run blocks.
    [ "$(apr_lib_validate_error_count)" = "1" ]
    [[ "${_APR_VALIDATE_ERR_MSG[0]}" == *"[strict]"* ]]
}

# =============================================================================
# strict_mode + finalize_strict
# =============================================================================

@test "strict_mode: false by default" {
    run apr_lib_validate_strict_mode
    [ "$status" -ne 0 ]
}

@test "strict_mode: true when APR_FAIL_ON_WARN=1" {
    APR_FAIL_ON_WARN=1 apr_lib_validate_strict_mode && status=0 || status=$?
    [ "$status" -eq 0 ]
}

@test "finalize_strict: no-op when not strict" {
    apr_lib_validate_add_warning "x" "msg"
    apr_lib_validate_finalize_strict
    [ "$(apr_lib_validate_error_count)" = "0" ]
}

@test "finalize_strict: promotes ALL warnings to errors when strict" {
    apr_lib_validate_add_warning "a" "warn-a"
    apr_lib_validate_add_warning "b" "warn-b"
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict
    [ "$(apr_lib_validate_error_count)" = "2" ]
    [ "$(apr_lib_validate_warning_count)" = "2" ]
    # Promoted errors keep the original code so consumers can join.
    [ "${_APR_VALIDATE_ERR_CODE[0]}" = "a" ]
    [ "${_APR_VALIDATE_ERR_CODE[1]}" = "b" ]
}

@test "finalize_strict: idempotent on already-error findings" {
    apr_lib_validate_add_error "e1" "real-error"
    apr_lib_validate_add_warning "w1" "warning"
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict
    # Errors: original + 1 promoted warning = 2.
    [ "$(apr_lib_validate_error_count)" = "2" ]
}

# =============================================================================
# bd-64dh: shell-style placeholder detection
# =============================================================================

@test "additional_placeholders bd-64dh: \${VAR} braced form -> warning" {
    apr_lib_validate_additional_placeholders "Inline \${README} here" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [ "${_APR_VALIDATE_WARN_CODE[0]}" = "prompt_qc_placeholder_marker" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *"shell_var"* ]]
}

@test "additional_placeholders bd-64dh: \$VAR unbraced form -> warning" {
    apr_lib_validate_additional_placeholders "Inline \$MYVAR here" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    [[ "${_APR_VALIDATE_WARN_DETAILS[0]}" == *"shell_var"* ]]
}

@test "additional_placeholders bd-64dh: shell special params NOT flagged" {
    apr_lib_validate_additional_placeholders \
        "use \$1 args \$@ count \$# pid \$\$ rc \$? name \$0 status \$!" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders bd-64dh: \$VAR inside code fence ignored by default" {
    local input
    input=$'doc text\n```\necho ${X} and $Y\n```\nmore text'
    apr_lib_validate_additional_placeholders "$input" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}

@test "additional_placeholders bd-64dh: APR_QC_RESPECT_CODE_FENCES=0 flags fenced \$VAR" {
    local input
    input=$'```\necho ${X}\n```'
    APR_QC_RESPECT_CODE_FENCES=0 apr_lib_validate_additional_placeholders "$input" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
}

@test "additional_placeholders bd-64dh: strict mode promotes shell-var warning to error" {
    APR_FAIL_ON_WARN=1 apr_lib_validate_additional_placeholders "Inline \${README} here" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "1" ]
    APR_FAIL_ON_WARN=1 apr_lib_validate_finalize_strict
    [ "$(apr_lib_validate_error_count)" = "1" ]
}

@test "additional_placeholders bd-64dh: details JSON has hits + class=shell_var" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_validate_additional_placeholders "Use \${X} here" "tpl"
    local details="${_APR_VALIDATE_WARN_DETAILS[0]}"
    python3 -c "
import json
d = json.loads('''$details''')
assert d['class'] == 'shell_var'
assert isinstance(d['hits'], list)
assert len(d['hits']) >= 1
"
}

@test "additional_placeholders bd-64dh: digit-only \$1..\$9 not flagged even at line start" {
    local input
    input=$'echo $1 here\nand $9 there'
    apr_lib_validate_additional_placeholders "$input" "tpl"
    [ "$(apr_lib_validate_warning_count)" = "0" ]
}
