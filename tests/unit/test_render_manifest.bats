#!/usr/bin/env bats
# test_render_manifest.bats - Tests for bd-2nx
#
# Validates the --show-manifest / --manifest-only preview flags + the
# new `apr robot render` command. Operators can verify file selection,
# hashes, and the exact prompt without invoking Oracle.

load '../helpers/test_helper'

setup() {
    setup_test_environment
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
# robot_render: returns the manifest + prompt + sha256
# =============================================================================

@test "robot_render: requires a round argument" {
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    local out rc=0
    out=$(robot_render "" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *'"ok":false'* ]]
    [[ "$out" == *'"code":"usage_error"'* ]]
}

@test "robot_render: non-numeric round -> usage_error" {
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    local out rc=0
    out=$(robot_render "abc" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *'"code":"usage_error"'* ]]
}

@test "robot_render: missing workflow -> usage_error" {
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    WORKFLOW="no-such-flow"
    local out rc=0
    out=$(robot_render "1" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *'"code":"usage_error"'* ]]
}

@test "robot_render: happy path returns ok with manifest + prompt + hash" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    robot_render "1" 2>/dev/null > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['ok'] is True
assert d['code'] == 'ok'
data = d['data']
assert data['workflow'] == 'default'
assert data['round'] == 1
assert data['include_impl'] is False
assert data['manifest_only'] is False
assert '[APR Manifest]' in data['manifest_text']
assert data['prompt_text'] != ''
# prompt_hash is 64 hex chars
import re
assert re.match(r'^[0-9a-f]{64}\$', data['prompt_hash']), data['prompt_hash']
"
}

@test "robot_render: --manifest-only mode hashes only the manifest" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    MANIFEST_ONLY=true
    robot_render "1" 2>/dev/null > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
data = d['data']
assert data['manifest_only'] is True
assert '[APR Manifest]' in data['manifest_text']
assert data['prompt_text'] == ''
# Still has a hash (of the manifest_text)
import re
assert re.match(r'^[0-9a-f]{64}\$', data['prompt_hash'])
"
}

@test "robot_render: include_impl=true flips IMPLEMENTATION.md to impl_every_n" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    INCLUDE_IMPL=true
    robot_render "1" 2>/dev/null > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
data = d['data']
assert data['include_impl'] is True
assert 'impl_every_n' in data['manifest_text']
"
}

@test "robot_render: deterministic across calls" {
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    local out1 out2
    out1=$(robot_render "1" 2>/dev/null)
    out2=$(robot_render "1" 2>/dev/null)
    # Strip the meta.ts timestamp before comparing (it changes per call).
    local norm1 norm2
    norm1=$(printf '%s' "$out1" | sed 's/"ts":"[^"]*"/"ts":"X"/')
    norm2=$(printf '%s' "$out2" | sed 's/"ts":"[^"]*"/"ts":"X"/')
    [ "$norm1" = "$norm2" ]
}

@test "robot_render: include_impl auto-triggers via impl_every_n on matching round" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    cd "$TEST_PROJECT" || return 1
    # Update workflow to use impl_every_n=2.
    sed -i 's|^rounds:|rounds:\n  impl_every_n: 2|' ".apr/workflows/default.yaml"
    ROBOT_COMPACT=true
    INCLUDE_IMPL=false
    robot_render "2" 2>/dev/null > "$BATS_TEST_TMPDIR/out_impl.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out_impl.json'))
data = d['data']
# Round 2 with impl_every_n=2 -> auto-include flips on.
assert data['include_impl'] is True
"
}

# =============================================================================
# Manifest text content properties
# =============================================================================

@test "robot_render: manifest_text contains README + SPEC entries with sha256" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    cd "$TEST_PROJECT" || return 1
    ROBOT_COMPACT=true
    robot_render "1" 2>/dev/null > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
m = d['data']['manifest_text']
assert 'README.md' in m
assert 'SPECIFICATION.md' in m
# Three or more sha256 lines (README + SPEC at minimum; impl skipped row counts via skipped section).
import re
shas = re.findall(r'sha256: [0-9a-f]{64}', m)
assert len(shas) >= 2
"
}

# =============================================================================
# Help text exposes the new flags
# =============================================================================

@test "show_help: mentions --show-manifest and --manifest-only" {
    local out
    out=$(show_help 2>&1)
    [[ "$out" == *"--show-manifest"* ]]
    [[ "$out" == *"--manifest-only"* ]]
}

@test "robot_help: lists 'render' command" {
    local out
    out=$(robot_help 2>&1)
    [[ "$out" == *"render"* ]]
}
