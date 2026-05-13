#!/usr/bin/env bats
# test_manifest_preamble.bats - Tests for bd-3i5: manifest preamble
# is prepended to the prompt by build_revision_prompt.
#
# Validates:
#   - build_prompt_manifest emits a deterministic [APR Manifest] block
#     when given a workflow yaml with readme/spec/impl paths
#   - build_revision_prompt prepends the manifest before the template
#   - include_impl flag changes the inclusion_reason for the impl file
#   - APR_NO_MANIFEST=1 fully disables the preamble (opt-out)
#   - missing config_file -> no preamble (fallback prompt path)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # apr_source_optional_libs uses BASH_SOURCE[0] which points at the
    # test-time sed-stripped copy, not the real script. Set the lib dir
    # explicitly so manifest.sh loads.
    export APR_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    load_apr_functions
    setup_test_workflow
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# build_prompt_manifest
# =============================================================================

@test "build_prompt_manifest: emits [APR Manifest] header when workflow has files" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_prompt_manifest "false" "$wf")
    [[ "$out" == *"[APR Manifest]"* ]]
    [[ "$out" == *"Included files:"* ]]
}

@test "build_prompt_manifest: lists README + spec as required" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_prompt_manifest "false" "$wf")
    [[ "$out" == *"README.md"* ]]
    [[ "$out" == *"SPECIFICATION.md"* ]]
    [[ "$out" == *"reason: required"* ]]
}

@test "build_prompt_manifest: impl is in Skipped section when include_impl=false" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_prompt_manifest "false" "$wf")
    [[ "$out" == *"Skipped files:"* ]]
    [[ "$out" == *"IMPLEMENTATION.md"* ]]
    [[ "$out" == *"not-included-this-round"* ]]
}

@test "build_prompt_manifest: impl is in Included section when include_impl=true" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_prompt_manifest "true" "$wf")
    [[ "$out" == *"IMPLEMENTATION.md"* ]]
    [[ "$out" == *"reason: impl_every_n"* ]]
    # And no Skipped section in this case.
    [[ "$out" != *"Skipped files:"* ]]
}

@test "build_prompt_manifest: every entry has a sha256 line" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_prompt_manifest "true" "$wf")
    # Three entries (README, SPEC, IMPL); three sha256 lines.
    local sha_count
    sha_count=$(printf '%s\n' "$out" | grep -c 'sha256: [0-9a-f]\{64\}')
    [ "$sha_count" -eq 3 ]
}

@test "build_prompt_manifest: deterministic across calls" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out1 out2
    out1=$(build_prompt_manifest "false" "$wf")
    out2=$(build_prompt_manifest "false" "$wf")
    [ "$out1" = "$out2" ]
}

@test "build_prompt_manifest: APR_NO_MANIFEST=1 produces no output" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(APR_NO_MANIFEST=1 build_prompt_manifest "false" "$wf")
    [ -z "$out" ]
}

@test "build_prompt_manifest: missing config_file produces no output" {
    local out
    out=$(build_prompt_manifest "false" "")
    [ -z "$out" ]
    out=$(build_prompt_manifest "false" "$TEST_PROJECT/.apr/workflows/no-such.yaml")
    [ -z "$out" ]
}

# =============================================================================
# build_revision_prompt: integration
# =============================================================================

@test "build_revision_prompt: prepends manifest before template" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_revision_prompt "false" "$wf")
    # Manifest comes first.
    local manifest_idx template_idx
    manifest_idx=$(printf '%s' "$out" | grep -bo '\[APR Manifest\]' | head -1 | cut -d: -f1)
    # template body should contain something distinctive — workflow yaml's
    # template field starts with "First, read this" by default in setup_test_workflow.
    # Use a less-specific anchor: the `---` divider after manifest.
    [ -n "$manifest_idx" ]
    [ "$manifest_idx" -lt 50 ]   # near the start
}

@test "build_revision_prompt: APR_NO_MANIFEST=1 skips manifest, template still emitted" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(APR_NO_MANIFEST=1 build_revision_prompt "false" "$wf")
    [[ "$out" != *"[APR Manifest]"* ]]
    # Template content (or fallback prompt) is still present.
    [ -n "$out" ]
}

@test "build_revision_prompt: include_impl=true manifest references IMPLEMENTATION.md as impl_every_n" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local out
    out=$(build_revision_prompt "true" "$wf")
    [[ "$out" == *"[APR Manifest]"* ]]
    [[ "$out" == *"IMPLEMENTATION.md"* ]]
    [[ "$out" == *"impl_every_n"* ]]
}

@test "build_revision_prompt: prompt_hash is deterministic across runs" {
    local wf="$TEST_PROJECT/.apr/workflows/default.yaml"
    local h1 h2
    h1=$(build_revision_prompt "false" "$wf" | apr_lib_manifest_hash_text "$(cat)")
    # Recompute via a fresh build to confirm byte-identity.
    h2=$(build_revision_prompt "false" "$wf" | apr_lib_manifest_hash_text "$(cat)")
    # NOTE: the pipe-to-apr_lib_manifest_hash_text-using-$(cat) idiom is
    # quirky because apr_lib_manifest_hash_text takes its arg, not stdin.
    # Just compute via a tempfile instead.
    build_revision_prompt "false" "$wf" > "$BATS_TEST_TMPDIR/p1"
    build_revision_prompt "false" "$wf" > "$BATS_TEST_TMPDIR/p2"
    local sha1 sha2
    sha1=$(sha256sum < "$BATS_TEST_TMPDIR/p1" | awk '{print $1}')
    sha2=$(sha256sum < "$BATS_TEST_TMPDIR/p2" | awk '{print $1}')
    [ "$sha1" = "$sha2" ]
    [ "${#sha1}" -eq 64 ]
}
