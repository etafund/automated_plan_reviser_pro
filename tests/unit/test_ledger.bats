#!/usr/bin/env bats
# test_ledger.bats - Unit tests for lib/ledger.sh (bd-1xv)
#
# Validates the ledger writer:
#   - canonical path construction
#   - token-pattern redaction (Bearer, sk-, gh*_, Authorization header,
#     --token / --api-key flags, password= / secret= form fields)
#   - atomic write (tmp + rename; survives partial-write failure mode)
#   - build_started / build_finished produce schema-conformant JSON
#     and pass python json.loads + the schema fixture validator
#   - finished states satisfy the state-dependent invariants from the
#     run-ledger spec (`ok` derived from state+code; duration_ms is
#     a non-negative integer; output_path required for finished/null
#     for failed)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/ledger.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# path construction
# =============================================================================

@test "path: default project root is current dir" {
    run apr_lib_ledger_path default 3
    assert_success
    assert_output "./.apr/rounds/default/round_3.meta.json"
}

@test "path: explicit project root is respected" {
    run apr_lib_ledger_path myflow 12 /tmp/proj
    assert_success
    assert_output "/tmp/proj/.apr/rounds/myflow/round_12.meta.json"
}

@test "path: missing workflow fails" {
    run apr_lib_ledger_path "" 1
    [ "$status" -ne 0 ]
}

# =============================================================================
# redaction
# =============================================================================

@test "redact: passes through plain text unchanged" {
    run apr_lib_ledger_redact "plain text with no secrets"
    assert_success
    assert_output "plain text with no secrets"
}

@test "redact: Bearer tokens" {
    run apr_lib_ledger_redact "Authorization: Bearer abc123_token-value rest"
    assert_success
    [[ "$output" == *"Bearer <REDACTED>"* ]]
    [[ "$output" != *"abc123_token-value"* ]]
}

@test "redact: Basic auth tokens" {
    run apr_lib_ledger_redact "Authorization: Basic dXNlcjpwYXNz=="
    assert_success
    [[ "$output" == *"Basic <REDACTED>"* ]]
    [[ "$output" != *"dXNlcjpwYXNz=="* ]]
}

@test "redact: sk- tokens" {
    run apr_lib_ledger_redact "key=sk-aabbccdd1234567890eeffgg rest"
    assert_success
    [[ "$output" == *"sk-<REDACTED>"* ]]
    [[ "$output" != *"aabbccdd1234567890eeffgg"* ]]
}

@test "redact: GitHub PAT prefixes" {
    run apr_lib_ledger_redact "token=ghp_aabbccdd1234567890eeffgghhiijj"
    assert_success
    [[ "$output" == *"gh_<REDACTED>"* ]]
}

@test "redact: Authorization header in JSON" {
    run apr_lib_ledger_redact '{"Authorization":"some-token-value"}'
    assert_success
    [[ "$output" == *'"Authorization":"<REDACTED>"'* ]]
}

@test "redact: --token <value> CLI shape" {
    run apr_lib_ledger_redact "oracle --token foo123abc456 --slug x"
    assert_success
    [[ "$output" == *"--token <REDACTED>"* ]]
    [[ "$output" != *"foo123abc456"* ]]
    # Surrounding args preserved.
    [[ "$output" == *"--slug x"* ]]
}

@test "redact: --token=<value> CLI shape" {
    run apr_lib_ledger_redact "oracle --token=foo123abc456 --slug x"
    assert_success
    [[ "$output" == *"--token=<REDACTED>"* ]]
    [[ "$output" != *"foo123abc456"* ]]
}

@test "redact: --api-key both spelling shapes" {
    run apr_lib_ledger_redact "cmd --api-key abcdef --api-key=ghijkl rest"
    assert_success
    [[ "$output" == *"--api-key <REDACTED>"* ]]
    [[ "$output" == *"--api-key=<REDACTED>"* ]]
    [[ "$output" != *"abcdef"* ]]
    [[ "$output" != *"ghijkl"* ]]
}

@test "redact: password / secret form fields" {
    run apr_lib_ledger_redact "form=user&password=hunter2&secret=stuff"
    assert_success
    [[ "$output" == *"password=<REDACTED>"* ]]
    [[ "$output" == *"secret=<REDACTED>"* ]]
    [[ "$output" != *"hunter2"* ]]
    [[ "$output" != *"secret=stuff"* ]]
}

@test "redact: deterministic across runs" {
    local input="Bearer aaa111 sk-bbb22233334444556677 password=qqq"
    local out1 out2
    out1=$(apr_lib_ledger_redact "$input")
    out2=$(apr_lib_ledger_redact "$input")
    [ "$out1" = "$out2" ]
}

# =============================================================================
# atomic_write
# =============================================================================

@test "atomic_write: creates parent directories" {
    local path="$BATS_TEST_TMPDIR/.apr/rounds/wf/round_1.meta.json"
    apr_lib_ledger_atomic_write "$path" '{"x":1}'
    [ -f "$path" ]
    [ "$(cat "$path")" = '{"x":1}' ]
}

@test "atomic_write: overwrites existing file atomically" {
    local path="$BATS_TEST_TMPDIR/ledger.json"
    apr_lib_ledger_atomic_write "$path" '{"first":true}'
    apr_lib_ledger_atomic_write "$path" '{"second":true}'
    [ "$(cat "$path")" = '{"second":true}' ]
}

@test "atomic_write: applies redaction" {
    local path="$BATS_TEST_TMPDIR/ledger.json"
    apr_lib_ledger_atomic_write "$path" 'Bearer abc123secret'
    local content
    content=$(cat "$path")
    [[ "$content" == *"<REDACTED>"* ]]
    [[ "$content" != *"abc123secret"* ]]
}

@test "atomic_write: no .tmp file remains after success" {
    local path="$BATS_TEST_TMPDIR/ledger.json"
    apr_lib_ledger_atomic_write "$path" '{"ok":true}'
    # No siblings beginning with `ledger.json.tmp.`.
    local stragglers
    stragglers=$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'ledger.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    [ "$stragglers" = "0" ]
}

# =============================================================================
# build_started
# =============================================================================

@test "build_started: emits well-formed JSON matching schema" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_ledger_build_started \
        myflow 5 apr-myflow-round-5 01HABCDEF1234567890ABCDEFGH \
        2026-05-12T19:14:00Z \
        '[]' \
        aabbccddeeff0011223344556677889900aabbccddeeff0011223344556677 \
        browser '5.2 Thinking')

    local out_file="$BATS_TEST_TMPDIR/started.json"
    printf '%s' "$out" > "$out_file"

    python3 -c "
import json
d = json.load(open('$out_file'))
assert d['schema_version'] == 'apr_run_ledger.v1', d['schema_version']
assert d['workflow'] == 'myflow'
assert d['round'] == 5
assert d['state'] == 'started'
assert d['finished_at'] is None
assert d['duration_ms'] is None
assert d['outcome']['code'] == 'running'
assert d['outcome']['ok'] is False
assert d['execution']['retries_count'] == 0
assert d['oracle']['engine'] == 'browser'
"
}

@test "build_started: optional fields default to null/empty" {
    local out
    out=$(apr_lib_ledger_build_started \
        wf 1 slug rid 2026-05-12T19:14:00Z '[]' deadbeef browser model)
    [[ "$out" == *'"thinking_time":null'* ]]
    [[ "$out" == *'"remote_host":null'* ]]
    [[ "$out" == *'"manifest_hash":null'* ]]
    [[ "$out" == *'"oracle_flags_used":[]'* ]]
}

@test "build_started: env-var-supplied optional fields are emitted" {
    local out
    APR_LEDGER_THINKING_TIME=high \
    APR_LEDGER_REMOTE_HOST=dev-mbp \
    APR_LEDGER_ORACLE_FLAGS='["--slug","x"]' \
    APR_LEDGER_MANIFEST_HASH="cafebabe$(printf '0%.0s' {1..56})" \
        out=$(apr_lib_ledger_build_started \
            wf 1 slug rid 2026-05-12T19:14:00Z '[]' deadbeef browser model)
    [[ "$out" == *'"thinking_time":"high"'* ]]
    [[ "$out" == *'"remote_host":"dev-mbp"'* ]]
    [[ "$out" == *'"manifest_hash":"cafebabe'* ]]
    [[ "$out" == *'"oracle_flags_used":["--slug","x"]'* ]]
}

# =============================================================================
# build_finished
# =============================================================================

@test "build_finished: ok state derives outcome.ok=true" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_ledger_build_finished \
        wf 1 slug rid \
        2026-05-12T19:14:00Z 2026-05-12T19:39:17Z \
        finished '[]' deadbeef browser model ok 0 .apr/rounds/wf/round_1.md 0 0 0)
    local out_file="$BATS_TEST_TMPDIR/fin.json"
    printf '%s' "$out" > "$out_file"
    python3 -c "
import json
d = json.load(open('$out_file'))
assert d['state'] == 'finished'
assert d['outcome']['ok'] is True
assert d['outcome']['code'] == 'ok'
assert d['outcome']['exit_code'] == 0
assert d['outcome']['output_path'] == '.apr/rounds/wf/round_1.md'
assert d['duration_ms'] == 1517000, d['duration_ms']
"
}

@test "build_finished: failed state has outcome.ok=false" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_ledger_build_finished \
        wf 1 slug rid \
        2026-05-12T19:14:00Z 2026-05-12T19:39:17Z \
        failed '[]' deadbeef browser model oracle_error 2 "" 1 2 95000)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['state'] == 'failed'
assert d['outcome']['ok'] is False
assert d['outcome']['code'] == 'oracle_error'
assert d['outcome']['exit_code'] == 2
assert d['outcome']['output_path'] is None
assert d['execution']['retries_count'] == 1
assert d['execution']['busy_wait_count'] == 2
assert d['execution']['busy_wait_total_ms'] == 95000
"
}

@test "build_finished: ok=false when state=finished but code != ok" {
    local out
    out=$(apr_lib_ledger_build_finished \
        wf 1 slug rid \
        2026-05-12T19:14:00Z 2026-05-12T19:39:17Z \
        finished '[]' deadbeef browser model degraded 0 some/path 0 0 0)
    [[ "$out" == *'"ok":false'* ]]
    [[ "$out" == *'"code":"degraded"'* ]]
}

@test "build_finished: env-var warnings + overrides are pass-through" {
    local out
    APR_LEDGER_WARNINGS_JSON='[{"code":"w1","message":"warn"}]' \
    APR_LEDGER_OVERRIDES_JSON='[{"name":"allow_x","value":true}]' \
        out=$(apr_lib_ledger_build_finished \
            wf 1 slug rid \
            2026-05-12T19:14:00Z 2026-05-12T19:39:17Z \
            finished '[]' deadbeef browser model ok 0 some/path 0 0 0)
    [[ "$out" == *'"warnings":[{"code":"w1","message":"warn"}]'* ]]
    [[ "$out" == *'"overrides":[{"name":"allow_x","value":true}]'* ]]
}

# =============================================================================
# End-to-end: start then finish via convenience wrappers
# =============================================================================

@test "write_start + write_finish: full lifecycle leaves valid finished JSON" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local path="$BATS_TEST_TMPDIR/.apr/rounds/wf/round_1.meta.json"
    local started finished
    started=$(apr_lib_ledger_build_started \
        wf 1 slug rid 2026-05-12T19:14:00Z '[]' deadbeef browser model)
    apr_lib_ledger_write_start "$path" "$started"
    [ -f "$path" ]
    python3 -c "import json; d=json.load(open('$path')); assert d['state']=='started'"

    finished=$(apr_lib_ledger_build_finished \
        wf 1 slug rid \
        2026-05-12T19:14:00Z 2026-05-12T19:39:17Z \
        finished '[]' deadbeef browser model ok 0 .apr/rounds/wf/round_1.md 0 0 0)
    apr_lib_ledger_write_finish "$path" "$finished"
    python3 -c "import json; d=json.load(open('$path')); assert d['state']=='finished'; assert d['outcome']['ok'] is True"
}
