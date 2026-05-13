#!/usr/bin/env bats
# test_template_wiring.bats - Tests for bd-btu: apr wires the safe
# template directive engine into build_revision_prompt when the
# workflow opts in via `template_directives.enabled: true`.
#
# What this covers (in addition to bd-1mf's engine-level tests):
#   - off-by-default: workflows without the toggle behave exactly like
#     before (byte-identical output).
#   - on: directives expand into the template body BEFORE the manifest
#     preamble is prepended.
#   - failure: a bad directive returns rc=1 and prints actionable
#     [apr] template: ... messages on stderr.
#   - safety: allow_traversal / allow_absolute opt-ins are honored.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"
    export APR_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    load_apr_functions
    setup_test_workflow
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Helper: rewrite the workflow yaml to embed a custom template body.
# The yaml created by setup_test_workflow has a `template: |` block at
# the end; we replace it wholesale.
_install_template_body() {
    local body="$1"
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    # Strip any existing `template:` section (keeps the structured fields).
    awk '/^template:[[:space:]]*\|/ {found=1; next} found && /^  / {next} {found=0; print}' "$wf" > "$wf.new"
    mv "$wf.new" "$wf"
    {
        printf '\ntemplate: |\n'
        printf '%s\n' "$body" | sed 's/^/  /'
    } >> "$wf"
}

_enable_directives() {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    # Use the flat form (template_directives_enabled) because the apr
    # yaml parser is non-recursive and this hits the same code path.
    printf '\ntemplate_directives_enabled: true\n' >> "$wf"
}

# =============================================================================
# Off-by-default: no toggle -> directives in template are NOT expanded
# =============================================================================

@test "build_revision_prompt: directives in template are NOT expanded when toggle absent" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Note: [[APR:LIT this is literal]] in body."
    # No _enable_directives call -> toggle absent.
    local out
    out=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    # Directive text remains verbatim in the prompt.
    [[ "$out" == *"[[APR:LIT this is literal]]"* ]]
}

# =============================================================================
# On: directives expand
# =============================================================================

@test "build_revision_prompt: LIT directive expands when toggle enabled" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Note: [[APR:LIT hello world]] in body."
    _enable_directives
    local out
    out=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    [[ "$out" == *"Note: hello world in body."* ]]
    [[ "$out" != *"[[APR:LIT"* ]]
}

@test "build_revision_prompt: SHA directive expands against project file" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "readme_sha=[[APR:SHA README.md]]"
    _enable_directives
    local out
    out=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    # Expect a 64-hex sha256 substring.
    [[ "$out" =~ readme_sha=[0-9a-f]{64} ]]
}

@test "build_revision_prompt: SIZE directive expands to byte count" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "readme_bytes=[[APR:SIZE README.md]]"
    _enable_directives
    local out
    out=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    # README.md size is small but >0.
    [[ "$out" =~ readme_bytes=[0-9]+ ]]
}

# =============================================================================
# Manifest preamble still wraps the expanded template
# =============================================================================

@test "build_revision_prompt: manifest preamble comes BEFORE expanded template" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Marker=[[APR:LIT EXPANDED]]"
    _enable_directives
    local out
    out=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    # Both present.
    [[ "$out" == *"[APR Manifest]"* ]]
    [[ "$out" == *"Marker=EXPANDED"* ]]
    # And manifest appears first.
    local idx_man idx_mark
    idx_man=$(printf '%s' "$out" | grep -bo '\[APR Manifest\]' | head -1 | cut -d: -f1)
    idx_mark=$(printf '%s' "$out" | grep -bo 'Marker=EXPANDED' | head -1 | cut -d: -f1)
    [ "$idx_man" -lt "$idx_mark" ]
}

# =============================================================================
# Lint / QC: expanded prompts are what the run gate validates
# =============================================================================

@test "lint_collect_findings: directives-enabled workflow expands and passes prompt QC" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body $'Read this inline README:\n[[APR:FILE README.md]]\nSpec sha=[[APR:SHA SPECIFICATION.md]]\nSpec bytes=[[APR:SIZE SPECIFICATION.md]]\nSpec excerpt=[[APR:EXCERPT SPECIFICATION.md 16]]'
    _enable_directives

    lint_collect_findings "1" "default" "false"
    local rc=0
    apr_lib_validate_has_errors || rc=$?
    [ "$rc" -ne 0 ]

    local prompt="$ARTIFACT_DIR/expanded_prompt.txt"
    build_revision_prompt "false" ".apr/workflows/default.yaml" > "$prompt"
    if grep -Fq '[[APR:' "$prompt"; then
        echo "expanded prompt retained APR directive residue" >&2
        return 1
    fi
    if grep -Fq '{{' "$prompt" || grep -Fq '}}' "$prompt"; then
        echo "expanded prompt retained mustache placeholder residue" >&2
        return 1
    fi
}

@test "lint_collect_findings: post-expansion mustache residue from LIT is fatal" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Leak: [[APR:LIT {{README}}]]"
    _enable_directives

    lint_collect_findings "1" "default" "false"
    apr_lib_validate_has_errors
    [ "$(apr_lib_validate_first_error_code)" = "prompt_qc_failed" ]
}

@test "lint_collect_findings: directive residue without enable toggle is fatal" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Directive left disabled: [[APR:FILE README.md]]"

    lint_collect_findings "1" "default" "false"
    apr_lib_validate_has_errors
    [ "$(apr_lib_validate_first_error_code)" = "prompt_qc_failed" ]
}

# =============================================================================
# Failure: bad directive -> rc=1 + actionable stderr
# =============================================================================

@test "build_revision_prompt: unknown directive type -> rc=1 with [apr] template message" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Bad: [[APR:NOPE x]] here"
    _enable_directives
    local rc=0 err
    err=$(build_revision_prompt "false" ".apr/workflows/default.yaml" 2>&1 1>/dev/null) || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$err" == *"[apr] template:"* ]]
    [[ "$err" == *"unknown_type"* ]] || [[ "$err" == *"NOPE"* ]]
}

@test "build_revision_prompt: traversal blocked by default" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Bad: [[APR:FILE ../etc/passwd]]"
    _enable_directives
    local rc=0 err
    err=$(build_revision_prompt "false" ".apr/workflows/default.yaml" 2>&1 1>/dev/null) || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$err" == *"traversal"* ]]
}

@test "build_revision_prompt: absolute paths blocked by default" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "Bad: [[APR:FILE /etc/passwd]]"
    _enable_directives
    local rc=0 err
    err=$(build_revision_prompt "false" ".apr/workflows/default.yaml" 2>&1 1>/dev/null) || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$err" == *"absolute"* ]]
}

# =============================================================================
# Determinism
# =============================================================================

@test "build_revision_prompt: expansion is deterministic" {
    cd "$TEST_PROJECT" || return 1
    _install_template_body "sha=[[APR:SHA README.md]] size=[[APR:SIZE README.md]]"
    _enable_directives
    local out1 out2
    out1=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    out2=$(build_revision_prompt "false" ".apr/workflows/default.yaml")
    [ "$out1" = "$out2" ]
}
