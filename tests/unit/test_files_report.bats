#!/usr/bin/env bats
# test_files_report.bats - Tests for lib/files_report.sh (bd-1oh)
#
# Verifies oracle --files-report parsing across the three documented
# shapes (Shape A: JSON-lines, Shape B: plain columns, Shape C: JSON
# envelope) plus the compare helper that produces the metrics
# files_report_mismatch object.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/files_report.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# parse: empty / malformed input
# =============================================================================

@test "parse: empty input -> {\"files\":[]} + rc=1" {
    local out rc=0
    out=$(apr_lib_files_report_parse "") || rc=$?
    [ "$rc" -eq 1 ]
    [ "$out" = '{"files":[]}' ]
}

@test "parse: nothing recognizable -> {\"files\":[]} + rc=1" {
    local out rc=0
    out=$(apr_lib_files_report_parse "just random text") || rc=$?
    [ "$rc" -eq 1 ]
    [ "$out" = '{"files":[]}' ]
}

# =============================================================================
# Shape A: JSON-lines
# =============================================================================

@test "parse: Shape A JSON-lines -> canonical envelope" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input='{"path":"README.md","bytes":5420,"sha256":"abc","status":"ok"}
{"path":"SPEC.md","bytes":14820,"sha256":"def","status":"ok"}'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert len(d['files']) == 2
paths = [f['path'] for f in d['files']]
assert paths == ['README.md', 'SPEC.md']
assert d['files'][0]['bytes'] == 5420
assert d['files'][0]['sha256'] == 'abc'
assert d['files'][1]['status'] == 'ok'
"
}

# =============================================================================
# Shape B: plain columns
# =============================================================================

@test "parse: Shape B plain columns -> canonical envelope" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input='README.md 5420 abc ok
SPEC.md 14820 def ok'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert len(d['files']) == 2
assert d['files'][0]['path'] == 'README.md'
assert d['files'][0]['bytes'] == 5420
"
}

@test "parse: Shape B tolerates tabs as separator" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input=$'README.md\t5420\tabc\tok'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['files'][0]['bytes'] == 5420
"
}

@test "parse: Shape B status defaults to 'ok' when omitted" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input='README.md 5420 abc'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['files'][0]['status'] == 'ok'
"
}

@test "parse: Shape B '#' comment lines are skipped" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input='# header comment
README.md 5420 abc ok'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert len(d['files']) == 1
"
}

# =============================================================================
# Shape C: JSON envelope
# =============================================================================

@test "parse: Shape C JSON envelope -> canonical envelope" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input='{"files":[{"path":"README.md","bytes":100,"sha256":"aaa","status":"ok"},{"path":"SPEC.md","bytes":200,"sha256":"bbb","status":"failed"}]}'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
assert len(d['files']) == 2
# Files are sorted by path -> README first.
assert d['files'][0]['path'] == 'README.md'
assert d['files'][1]['status'] == 'failed'
"
}

# =============================================================================
# Canonical envelope: stable sort by path
# =============================================================================

@test "parse: output stably sorted by path (LC_ALL=C-ish)" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input='Zoo.md 50 zzz ok
README.md 100 aaa ok
Middle.md 75 mmm ok'
    local out
    out=$(apr_lib_files_report_parse "$input")
    python3 -c "
import json
d = json.loads('''$out''')
paths = [f['path'] for f in d['files']]
assert paths == ['Middle.md', 'README.md', 'Zoo.md'], paths
"
}

# =============================================================================
# compare: clean match
# =============================================================================

@test "compare: every expected file present, sizes match -> all-empty mismatch + rc=0" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input='{"files":[{"path":"R.md","bytes":100,"sha256":"a","status":"ok"},{"path":"S.md","bytes":200,"sha256":"b","status":"ok"}]}'
    local canonical
    canonical=$(apr_lib_files_report_parse "$input")
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md:100|S.md:200" "$canonical") || rc=$?
    [ "$rc" -eq 0 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['missing'] == []
assert d['extra'] == []
assert d['size_mismatch'] == []
"
}

# =============================================================================
# compare: missing
# =============================================================================

@test "compare: expected file not in report -> missing[] populated, rc=1" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local canonical='{"files":[{"path":"R.md","bytes":100,"sha256":"a","status":"ok"}]}'
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md:100|S.md:200|IMPL.md:300" "$canonical") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert sorted(d['missing']) == ['IMPL.md', 'S.md']
assert d['extra'] == []
"
}

# =============================================================================
# compare: extra
# =============================================================================

@test "compare: report has extra file not expected -> extra[] populated" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local canonical='{"files":[{"path":"R.md","bytes":100},{"path":"BONUS.md","bytes":50}]}'
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md:100" "$canonical") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['extra'] == ['BONUS.md']
"
}

# =============================================================================
# compare: size mismatch
# =============================================================================

@test "compare: bytes differ -> size_mismatch[] populated" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local canonical='{"files":[{"path":"R.md","bytes":100},{"path":"S.md","bytes":999}]}'
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md:100|S.md:200" "$canonical") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['size_mismatch'] == ['S.md']
"
}

# =============================================================================
# compare: non-ok status surfaces status_failed
# =============================================================================

@test "compare: file with status=failed -> status_failed[] populated" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local canonical='{"files":[{"path":"R.md","bytes":100,"status":"ok"},{"path":"S.md","bytes":200,"status":"failed"}]}'
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md:100|S.md:200" "$canonical") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d.get('status_failed') == ['S.md']
"
}

# =============================================================================
# compare: bytes omitted in expected -> size check skipped
# =============================================================================

@test "compare: expected paths without bytes -> size check skipped" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local canonical='{"files":[{"path":"R.md","bytes":100},{"path":"S.md","bytes":200}]}'
    local out rc=0
    out=$(apr_lib_files_report_compare "R.md|S.md" "$canonical") || rc=$?
    [ "$rc" -eq 0 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['size_mismatch'] == []
"
}

# =============================================================================
# Determinism
# =============================================================================

@test "parse: deterministic across calls" {
    local input='S.md 200 b ok
R.md 100 a ok'
    local out1 out2
    out1=$(apr_lib_files_report_parse "$input")
    out2=$(apr_lib_files_report_parse "$input")
    [ "$out1" = "$out2" ]
}
