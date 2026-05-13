#!/usr/bin/env bats
# test_files_report_metamorphic.bats
#
# Metamorphic/property layer for lib/files_report.sh (bd-1oh parser
# + compare helper).
#
# tests/unit/test_files_report.bats covers happy-path behavior across
# the three documented shapes. This file PINS THE CROSS-SHAPE AND
# ROUND-TRIP PROPERTIES that make the parser useful as the authoritative
# attachment-provenance signal:
#
#   I1  Shape-A (JSON-lines) round-trip preserves the file set.
#   I2  Shape-B (plain columns) round-trip preserves the file set.
#   I3  Shape-C (JSON envelope) round-trip preserves the file set.
#   I4  Cross-shape equivalence: the same logical file list rendered
#       in shapes A, B, and C yields BYTE-IDENTICAL canonical envelopes.
#   I5  Permutation invariance on input order: shuffling input lines
#       does not change the canonical envelope (parser sorts by path).
#   I6  Byte-deterministic across N calls on the same input.
#   I7  compare round-trip identity: comparing an expected set against
#       the parsed envelope of that same set produces empty diffs + rc=0.
#   I8  Permutation invariance on `expected_csv` argument order.
#   I9  Single-axis defect injection:
#         - drop a file -> ONLY `missing` is populated
#         - add a file  -> ONLY `extra` is populated
#         - drift bytes -> ONLY `size_mismatch` is populated
#         - flip status -> `status_failed` is populated; the other
#           buckets remain empty when paths/bytes match.
#   I10 compare with empty expected and empty canonical -> all-empty
#       diff + rc=0 (trivial identity case).
#   I11 compare output has stable key shape: missing/extra/size_mismatch
#       always present; status_failed only when failures exist.
#   I12 Multiple defects compose: missing + extra + size_mismatch can
#       coexist in a single compare output without leaking across
#       buckets.
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — lib/files_report.sh requires it"
    fi

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/files_report.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Test fixture: canonical 3-file set used as the basis for round-trip /
# cross-shape comparisons. Path strings deliberately span the LC_ALL=C
# range R < S < Z so sort-stability is observable.
# ---------------------------------------------------------------------------

_canonical_3file_records() {
    # path|bytes|sha256|status, one per line.
    cat <<'EOF'
README.md|5420|aaa111|ok
SPEC.md|14820|bbb222|ok
Zoo.md|50|ccc333|ok
EOF
}

_render_shape_a() {
    # JSON-lines (one object per line, in input order).
    local p b s st
    while IFS='|' read -r p b s st; do
        [[ -z "$p" ]] && continue
        printf '{"path":"%s","bytes":%s,"sha256":"%s","status":"%s"}\n' "$p" "$b" "$s" "$st"
    done
}

_render_shape_b() {
    # Plain columns separated by spaces, in input order.
    local p b s st
    while IFS='|' read -r p b s st; do
        [[ -z "$p" ]] && continue
        printf '%s %s %s %s\n' "$p" "$b" "$s" "$st"
    done
}

_render_shape_c() {
    # Single JSON envelope. stdin = "path|bytes|sha|status" lines.
    # NOTE: `python3 - <<'PY'` consumes stdin for source code; we pass
    # the records via argv to avoid that conflict.
    local records
    records=$(cat)
    python3 - "$records" <<'PY'
import json, sys
files = []
for line in sys.argv[1].splitlines():
    if not line:
        continue
    p, b, s, st = line.split('|', 3)
    files.append({"path": p, "bytes": int(b), "sha256": s, "status": st})
sys.stdout.write(json.dumps({"files": files}))
PY
}

# Pull the canonical-envelope file list as a sorted, normalized string.
_envelope_files_sorted() {
    # arg1: canonical envelope JSON string.
    # stdout: a stable "path|bytes|sha256|status" line per file, sorted.
    python3 - "$1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for f in sorted(d.get("files", []), key=lambda x: x.get("path", "")):
    sys.stdout.write("{}|{}|{}|{}\n".format(
        f.get("path", ""), f.get("bytes"), f.get("sha256"), f.get("status")
    ))
PY
}

# ===========================================================================
# I1 — Shape A round-trip
# ===========================================================================

@test "I1: Shape A (JSON-lines) round-trip preserves the file set" {
    local input expected_lines actual_lines
    input=$(_canonical_3file_records | _render_shape_a)
    local canonical
    canonical=$(apr_lib_files_report_parse "$input")
    expected_lines=$(_canonical_3file_records | LC_ALL=C sort)
    actual_lines=$(_envelope_files_sorted "$canonical" | LC_ALL=C sort)
    [[ "$expected_lines" == "$actual_lines" ]] || {
        echo "I1 violation: round-trip drift" >&2
        diff <(printf '%s' "$expected_lines") <(printf '%s' "$actual_lines") >&2 || true
        return 1
    }
}

# ===========================================================================
# I2 — Shape B round-trip
# ===========================================================================

@test "I2: Shape B (plain columns) round-trip preserves the file set" {
    local input
    input=$(_canonical_3file_records | _render_shape_b)
    local canonical
    canonical=$(apr_lib_files_report_parse "$input")
    local expected_lines actual_lines
    expected_lines=$(_canonical_3file_records | LC_ALL=C sort)
    actual_lines=$(_envelope_files_sorted "$canonical" | LC_ALL=C sort)
    [[ "$expected_lines" == "$actual_lines" ]] || {
        echo "I2 violation: round-trip drift" >&2
        diff <(printf '%s' "$expected_lines") <(printf '%s' "$actual_lines") >&2 || true
        return 1
    }
}

# ===========================================================================
# I3 — Shape C round-trip
# ===========================================================================

@test "I3: Shape C (JSON envelope) round-trip preserves the file set" {
    local input
    input=$(_canonical_3file_records | _render_shape_c)
    local canonical
    canonical=$(apr_lib_files_report_parse "$input")
    local expected_lines actual_lines
    expected_lines=$(_canonical_3file_records | LC_ALL=C sort)
    actual_lines=$(_envelope_files_sorted "$canonical" | LC_ALL=C sort)
    [[ "$expected_lines" == "$actual_lines" ]] || {
        echo "I3 violation: round-trip drift" >&2
        diff <(printf '%s' "$expected_lines") <(printf '%s' "$actual_lines") >&2 || true
        return 1
    }
}

# ===========================================================================
# I4 — Cross-shape equivalence: A/B/C of the same logical files produce
#      byte-identical canonical envelopes.
# ===========================================================================

@test "I4: cross-shape equivalence (A/B/C produce byte-identical canonical envelope)" {
    local input_a input_b input_c canonical_a canonical_b canonical_c
    input_a=$(_canonical_3file_records | _render_shape_a)
    input_b=$(_canonical_3file_records | _render_shape_b)
    input_c=$(_canonical_3file_records | _render_shape_c)
    canonical_a=$(apr_lib_files_report_parse "$input_a")
    canonical_b=$(apr_lib_files_report_parse "$input_b")
    canonical_c=$(apr_lib_files_report_parse "$input_c")
    [[ "$canonical_a" == "$canonical_b" ]] || {
        echo "I4 violation: Shape A vs Shape B differ" >&2
        diff <(printf '%s' "$canonical_a") <(printf '%s' "$canonical_b") >&2 || true
        return 1
    }
    [[ "$canonical_b" == "$canonical_c" ]] || {
        echo "I4 violation: Shape B vs Shape C differ" >&2
        diff <(printf '%s' "$canonical_b") <(printf '%s' "$canonical_c") >&2 || true
        return 1
    }
}

# ===========================================================================
# I5 — Permutation invariance on input order (output is sorted by path).
# ===========================================================================

@test "I5: shuffling input order does not change the canonical envelope" {
    local in_ordered in_reversed canonical_ordered canonical_reversed
    in_ordered=$(_canonical_3file_records | _render_shape_a)
    # Reverse the JSON-lines input order.
    in_reversed=$(_canonical_3file_records | _render_shape_a | tac)
    canonical_ordered=$(apr_lib_files_report_parse "$in_ordered")
    canonical_reversed=$(apr_lib_files_report_parse "$in_reversed")
    [[ "$canonical_ordered" == "$canonical_reversed" ]] || {
        echo "I5 violation: order-dependent canonical output" >&2
        diff <(printf '%s' "$canonical_ordered") <(printf '%s' "$canonical_reversed") >&2 || true
        return 1
    }
}

# ===========================================================================
# I6 — parse is byte-deterministic across N calls
# ===========================================================================

@test "I6: parse is byte-deterministic across 25 calls" {
    local input
    input=$(_canonical_3file_records | _render_shape_a)
    local first
    first=$(apr_lib_files_report_parse "$input")
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_files_report_parse "$input")
        [[ "$first" == "$again" ]] || {
            echo "I6 violation at iter $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I7 — compare round-trip identity (expected vs parse(emit(expected)))
# ===========================================================================

@test "I7: compare(expected, parse(emit(expected))) is the empty diff (rc=0)" {
    local input canonical out rc=0
    input=$(_canonical_3file_records | _render_shape_a)
    canonical=$(apr_lib_files_report_parse "$input")
    out=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820|Zoo.md:50" "$canonical") || rc=$?
    [[ "$rc" -eq 0 ]] || {
        echo "I7 violation: rc=$rc (want 0). diff: $out" >&2
        return 1
    }
    python3 - <<PY
import json, sys
d = json.loads('''$out''')
assert d == {"missing": [], "extra": [], "size_mismatch": []}, d
PY
}

# ===========================================================================
# I8 — compare is permutation-invariant on the expected_csv argument
# ===========================================================================

@test "I8: compare output is invariant under expected_csv permutation" {
    local input canonical out_a out_b
    input=$(_canonical_3file_records | _render_shape_a)
    canonical=$(apr_lib_files_report_parse "$input")
    out_a=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820|Zoo.md:50" "$canonical")
    out_b=$(apr_lib_files_report_compare "Zoo.md:50|README.md:5420|SPEC.md:14820" "$canonical")
    [[ "$out_a" == "$out_b" ]] || {
        echo "I8 violation: expected_csv permutation changed compare output" >&2
        echo "  out_a=$out_a" >&2
        echo "  out_b=$out_b" >&2
        return 1
    }
}

# ===========================================================================
# I9 — Single-axis defect injection: each defect populates only its bucket.
# ===========================================================================

@test "I9a: dropping a file from the report -> ONLY missing[] populated" {
    local canonical out rc=0
    # Emit only 2 of the 3 expected files.
    canonical=$(printf 'README.md|5420|aaa111|ok\nSPEC.md|14820|bbb222|ok\n' \
        | _render_shape_a \
        | { read -r -d '' input || true; apr_lib_files_report_parse "$input"; })
    # Re-parse cleanly:
    canonical=$(apr_lib_files_report_parse "$(printf '{"path":"README.md","bytes":5420,"sha256":"aaa111","status":"ok"}\n{"path":"SPEC.md","bytes":14820,"sha256":"bbb222","status":"ok"}\n')")
    out=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820|Zoo.md:50" "$canonical") || rc=$?
    [[ "$rc" -eq 1 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d['missing'] == ['Zoo.md'], d
assert d['extra'] == [], d
assert d['size_mismatch'] == [], d
PY
}

@test "I9b: report has an extra file not in expected -> ONLY extra[] populated" {
    local canonical out rc=0
    canonical=$(apr_lib_files_report_parse "$(printf '{"path":"README.md","bytes":5420,"sha256":"aaa111","status":"ok"}\n{"path":"SPEC.md","bytes":14820,"sha256":"bbb222","status":"ok"}\n{"path":"BONUS.md","bytes":99,"sha256":"zzz","status":"ok"}\n')")
    out=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820" "$canonical") || rc=$?
    [[ "$rc" -eq 1 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d['missing'] == [], d
assert d['extra'] == ['BONUS.md'], d
assert d['size_mismatch'] == [], d
PY
}

@test "I9c: bytes drift -> ONLY size_mismatch[] populated" {
    local canonical out rc=0
    canonical=$(apr_lib_files_report_parse "$(printf '{"path":"README.md","bytes":5420,"sha256":"aaa111","status":"ok"}\n{"path":"SPEC.md","bytes":99999,"sha256":"bbb222","status":"ok"}\n')")
    out=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820" "$canonical") || rc=$?
    [[ "$rc" -eq 1 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d['missing'] == [], d
assert d['extra'] == [], d
assert d['size_mismatch'] == ['SPEC.md'], d
PY
}

@test "I9d: non-ok status flips status_failed; other buckets stay empty" {
    local canonical out rc=0
    canonical=$(apr_lib_files_report_parse "$(printf '{"path":"README.md","bytes":5420,"sha256":"aaa111","status":"ok"}\n{"path":"SPEC.md","bytes":14820,"sha256":"bbb222","status":"failed"}\n')")
    out=$(apr_lib_files_report_compare "README.md:5420|SPEC.md:14820" "$canonical") || rc=$?
    [[ "$rc" -eq 1 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d['missing'] == [], d
assert d['extra'] == [], d
assert d['size_mismatch'] == [], d
assert d.get('status_failed') == ['SPEC.md'], d
PY
}

# ===========================================================================
# I10 — empty expected + empty canonical -> empty diff + rc=0
# ===========================================================================

@test "I10: empty expected and empty canonical -> all-empty diff + rc=0" {
    local out rc=0
    out=$(apr_lib_files_report_compare "" '{"files":[]}') || rc=$?
    [[ "$rc" -eq 0 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d == {"missing": [], "extra": [], "size_mismatch": []}, d
PY
}

# ===========================================================================
# I11 — compare output key shape is stable: missing/extra/size_mismatch
#       always present; status_failed only when failures exist.
# ===========================================================================

@test "I11: compare output always has missing/extra/size_mismatch; status_failed only when failures" {
    local canonical_ok out_ok canonical_bad out_bad
    # Clean canonical (no failures).
    canonical_ok=$(apr_lib_files_report_parse "$(printf '{"path":"R.md","bytes":1,"sha256":"a","status":"ok"}\n')")
    out_ok=$(apr_lib_files_report_compare "R.md:1" "$canonical_ok")
    python3 - <<PY
import json
d = json.loads('''$out_ok''')
assert set(d.keys()) == {"missing", "extra", "size_mismatch"}, d
PY

    # Failure canonical (status flipped).
    canonical_bad=$(apr_lib_files_report_parse "$(printf '{"path":"R.md","bytes":1,"sha256":"a","status":"failed"}\n')")
    out_bad=$(apr_lib_files_report_compare "R.md:1" "$canonical_bad") || true
    python3 - <<PY
import json
d = json.loads('''$out_bad''')
assert set(d.keys()) == {"missing", "extra", "size_mismatch", "status_failed"}, d
assert d['status_failed'] == ['R.md'], d
PY
}

# ===========================================================================
# I12 — Compound defects compose without bucket leakage.
# ===========================================================================

@test "I12: compound defects populate independent buckets without leakage" {
    local canonical out rc=0
    # missing: Z.md ; extra: BONUS.md ; size_mismatch: S.md
    canonical=$(apr_lib_files_report_parse "$(printf '{"path":"R.md","bytes":100,"sha256":"a","status":"ok"}\n{"path":"S.md","bytes":999,"sha256":"b","status":"ok"}\n{"path":"BONUS.md","bytes":50,"sha256":"x","status":"ok"}\n')")
    out=$(apr_lib_files_report_compare "R.md:100|S.md:200|Z.md:300" "$canonical") || rc=$?
    [[ "$rc" -eq 1 ]]
    python3 - <<PY
import json
d = json.loads('''$out''')
assert d['missing'] == ['Z.md'], d
assert d['extra'] == ['BONUS.md'], d
assert d['size_mismatch'] == ['S.md'], d
assert 'status_failed' not in d, d
PY
}
