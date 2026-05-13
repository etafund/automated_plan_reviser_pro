#!/usr/bin/env bats
# test_manifest_metamorphic.bats
#
# Metamorphic/property layer for lib/manifest.sh (bd-phj manifest
# helpers — the central trust contract under ACK validation (bd-34z),
# files_report compare (bd-1oh), ledger writes (bd-1xv), and cache
# invalidation (bd-1aw)).
#
# Bead automated_plan_reviser_pro-b6d8.
#
# tests/unit/test_manifest.bats + test_manifest_fuzz.bats +
# test_manifest_preamble.bats cover happy paths and adversarial inputs.
# This file PINS the cross-helper consistency and order-stability
# properties that downstream provenance/trust signals implicitly depend
# on.
#
# Invariants pinned:
#   I1  sha256 is byte-deterministic for the same file across N calls.
#   I2  size is byte-deterministic for the same file across N calls.
#   I3  Different file contents → different sha256 (collision smoke).
#   I4  Content addressing: same bytes in two distinct files →
#       identical sha256.
#   I5  Missing/unreadable file failure contract:
#         sha256: empty-sha + rc=1
#         size:   "0" + rc=1
#   I6  json_escape output, surrounded by quotes, is JSON-parseable AND
#       round-trips back to the original string for the documented
#       escape set (\\, ", \n, \r, \t).
#   I7  render_json output is byte-deterministic across N calls.
#   I8  render_json input-order invariance: shuffling triples does not
#       change the rendered output (sort by path).
#   I9  render_text input-order invariance analog of I8.
#   I10 render_json output is well-formed JSON for every documented
#       reason in {required, optional, impl_every_n, skipped}.
#   I11 hash_text(content_of_file) == sha256(file_with_that_content)
#       — cross-helper consistency between the two sha256 entry points.
#   I12 is_valid_reason totality: accepts EXACTLY the documented set
#       {required, optional, impl_every_n, skipped}; rejects all other
#       strings (case-sensitive, no whitespace tolerance).
#   I13 basename helper is total over normal paths: strips trailing
#       slashes, matches POSIX basename for the simple cases, and
#       never emits an absolute path.
#   I14 entry_json byte-determinism: same (path, reason, skipped_reason)
#       inputs → byte-identical output across N calls.
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/manifest.sh"

    FIXTURE_ROOT="$TEST_DIR/manifest_meta"
    mkdir -p "$FIXTURE_ROOT"
    export FIXTURE_ROOT

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Documented inclusion reasons per lib/manifest.sh.
DOCUMENTED_REASONS="required optional impl_every_n skipped"

# Empty-bytes sha256 sentinel for missing/unreadable files.
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Helpers.
_write_fixture() {
    # _write_fixture <relpath> <content>
    local p="$FIXTURE_ROOT/$1" c="$2"
    mkdir -p "$(dirname -- "$p")"
    printf '%s' "$c" > "$p"
    printf '%s' "$p"
}

# ===========================================================================
# I1 — sha256 byte-determinism
# ===========================================================================

@test "I1: sha256 is byte-deterministic across 25 calls on the same file" {
    local f
    f=$(_write_fixture "a.md" "alpha beta gamma")
    local first
    first=$(apr_lib_manifest_sha256 "$f")
    [[ "$first" =~ ^[0-9a-f]{64}$ ]]
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_manifest_sha256 "$f")
        [[ "$first" == "$again" ]] || {
            echo "I1 violation at iter $i: $first != $again" >&2
            return 1
        }
    done
}

# ===========================================================================
# I2 — size byte-determinism
# ===========================================================================

@test "I2: size is byte-deterministic across 25 calls on the same file" {
    local f
    f=$(_write_fixture "b.md" "0123456789abcdef")
    local first
    first=$(apr_lib_manifest_size "$f")
    [[ "$first" == "16" ]] || {
        echo "I2 setup: expected 16 bytes, got '$first'" >&2
        return 1
    }
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_manifest_size "$f")
        [[ "$first" == "$again" ]] || {
            echo "I2 violation at iter $i: $first != $again" >&2
            return 1
        }
    done
}

# ===========================================================================
# I3 — Different content → different sha256
# ===========================================================================

@test "I3: distinct contents produce distinct sha256 (collision smoke)" {
    local a b
    a=$(_write_fixture "c.md" "content one")
    b=$(_write_fixture "d.md" "content two")
    local sa sb
    sa=$(apr_lib_manifest_sha256 "$a")
    sb=$(apr_lib_manifest_sha256 "$b")
    [[ "$sa" != "$sb" ]] || {
        echo "I3 violation: distinct contents collided on sha256 $sa" >&2
        return 1
    }
}

# ===========================================================================
# I4 — Content addressing: same bytes, two files → same sha256
# ===========================================================================

@test "I4: content addressing — same bytes in two files → identical sha256" {
    local payload="the same exact bytes"
    local a b
    a=$(_write_fixture "twin1.md" "$payload")
    b=$(_write_fixture "subdir/twin2.md" "$payload")
    local sa sb
    sa=$(apr_lib_manifest_sha256 "$a")
    sb=$(apr_lib_manifest_sha256 "$b")
    [[ "$sa" == "$sb" ]] || {
        echo "I4 violation: identical contents diverged: $sa != $sb" >&2
        return 1
    }
}

# ===========================================================================
# I5 — Missing/unreadable file failure contract
# ===========================================================================

@test "I5: missing file -> sha256=empty-sha + rc=1, size='0' + rc=1" {
    local missing="$FIXTURE_ROOT/does_not_exist.md"
    local out rc=0
    out=$(apr_lib_manifest_sha256 "$missing") || rc=$?
    [[ "$rc" -eq 1 ]] || { echo "I5: sha256 rc=$rc (want 1)" >&2; return 1; }
    [[ "$out" == "$EMPTY_SHA" ]] || { echo "I5: sha256 out='$out' (want empty-sha)" >&2; return 1; }

    rc=0
    out=$(apr_lib_manifest_size "$missing") || rc=$?
    [[ "$rc" -eq 1 ]] || { echo "I5: size rc=$rc (want 1)" >&2; return 1; }
    [[ "$out" == "0" ]] || { echo "I5: size out='$out' (want '0')" >&2; return 1; }
}

# ===========================================================================
# I6 — json_escape round-trip via JSON parser
# ===========================================================================

@test "I6: json_escape output (wrapped in quotes) is JSON-parseable and round-trips" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — json_escape round-trip uses it"
    fi
    local cases=(
        "plain text"
        ""
        "with \"double quotes\" inside"
        "with backslash \\ inside"
        $'newline\nin middle'
        $'tab\tin middle'
        $'carriage\rreturn'
        "all combos: \"quote\" \\backslash"$'\nnewline\ttab'
    )
    local raw escaped
    for raw in "${cases[@]}"; do
        escaped=$(apr_lib_manifest_json_escape "$raw")
        # Wrap in quotes and parse with Python; recovered must equal raw.
        python3 - "$raw" "$escaped" <<'PY'
import json, sys
raw, escaped = sys.argv[1], sys.argv[2]
quoted = '"' + escaped + '"'
recovered = json.loads(quoted)
assert recovered == raw, (raw, escaped, recovered)
PY
    done
}

# ===========================================================================
# I7 — render_json determinism
# ===========================================================================

@test "I7: render_json is byte-deterministic across 25 calls" {
    local a b
    a=$(_write_fixture "r1.md" "alpha")
    b=$(_write_fixture "r2.md" "beta")
    local first
    first=$(apr_lib_manifest_render_json "$a|required|" "$b|optional|")
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_manifest_render_json "$a|required|" "$b|optional|")
        [[ "$first" == "$again" ]] || {
            echo "I7 violation at iter $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I8 — render_json input order invariance
# ===========================================================================

@test "I8: render_json output is invariant under input-triple permutation" {
    local a b c
    a=$(_write_fixture "p1_a.md" "AAA")
    b=$(_write_fixture "p1_b.md" "BBB")
    c=$(_write_fixture "p1_c.md" "CCC")
    local out_abc out_cba
    out_abc=$(apr_lib_manifest_render_json "$a|required|" "$b|optional|" "$c|impl_every_n|")
    out_cba=$(apr_lib_manifest_render_json "$c|impl_every_n|" "$b|optional|" "$a|required|")
    [[ "$out_abc" == "$out_cba" ]] || {
        echo "I8 violation: order-dependent render_json:" >&2
        diff <(printf '%s' "$out_abc") <(printf '%s' "$out_cba") >&2 || true
        return 1
    }
}

# ===========================================================================
# I9 — render_text input order invariance
# ===========================================================================

@test "I9: render_text output is invariant under input-triple permutation" {
    local a b c
    a=$(_write_fixture "p2_a.md" "AAA")
    b=$(_write_fixture "p2_b.md" "BBB")
    c=$(_write_fixture "p2_c.md" "CCC")
    local out_abc out_cba
    out_abc=$(apr_lib_manifest_render_text "$a|required|" "$b|optional|" "$c|skipped|not-due-yet")
    out_cba=$(apr_lib_manifest_render_text "$c|skipped|not-due-yet" "$b|optional|" "$a|required|")
    [[ "$out_abc" == "$out_cba" ]] || {
        echo "I9 violation: order-dependent render_text" >&2
        diff <(printf '%s' "$out_abc") <(printf '%s' "$out_cba") >&2 || true
        return 1
    }
}

# ===========================================================================
# I10 — render_json produces well-formed JSON for every documented reason
# ===========================================================================

@test "I10: render_json output is valid JSON across every documented reason" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available — JSON validity check uses it"
    fi
    local f reason out
    f=$(_write_fixture "j.md" "json fixture")
    for reason in $DOCUMENTED_REASONS; do
        if [[ "$reason" == "skipped" ]]; then
            out=$(apr_lib_manifest_render_json "$f|$reason|illustrative-reason")
        else
            out=$(apr_lib_manifest_render_json "$f|$reason|")
        fi
        python3 - "$out" "$reason" <<'PY'
import json, sys
out, reason = sys.argv[1], sys.argv[2]
arr = json.loads(out)
assert isinstance(arr, list) and len(arr) == 1, arr
entry = arr[0]
assert entry["inclusion_reason"] == reason, (entry, reason)
assert isinstance(entry["bytes"], int), entry
assert isinstance(entry["sha256"], str) and len(entry["sha256"]) == 64, entry
PY
    done
}

# ===========================================================================
# I11 — hash_text cross-consistency with sha256
# ===========================================================================

@test "I11: hash_text(content) == sha256(file_with_that_content)" {
    local payload="cross-consistency payload — alpha beta gamma 123"
    local f
    f=$(_write_fixture "cc.md" "$payload")
    local from_file from_text
    from_file=$(apr_lib_manifest_sha256 "$f")
    from_text=$(apr_lib_manifest_hash_text "$payload")
    [[ "$from_file" == "$from_text" ]] || {
        echo "I11 violation: file=$from_file text=$from_text" >&2
        return 1
    }
}

# ===========================================================================
# I12 — is_valid_reason totality
# ===========================================================================

@test "I12: is_valid_reason accepts exactly the documented set; rejects everything else" {
    local r rc
    for r in $DOCUMENTED_REASONS; do
        rc=0
        apr_lib_manifest_is_valid_reason "$r" || rc=$?
        [[ "$rc" -eq 0 ]] || {
            echo "I12 violation: documented reason '$r' rejected (rc=$rc)" >&2
            return 1
        }
    done
    local bogus
    local -a rejects=(
        ""
        "REQUIRED"
        "Required"
        "required "
        " required"
        "optional;"
        "unknown"
        "impl_every"
        "impl_every_n_2"
        "skip"
        "skipped\n"
    )
    for bogus in "${rejects[@]}"; do
        rc=0
        apr_lib_manifest_is_valid_reason "$bogus" || rc=$?
        [[ "$rc" -ne 0 ]] || {
            echo "I12 violation: bogus reason '$bogus' accepted" >&2
            return 1
        }
    done
}

# ===========================================================================
# I13 — basename totality + trailing-slash + no absolute paths
# ===========================================================================

@test "I13: basename is total over normal paths and strips trailing slashes" {
    local cases=(
        "README.md|README.md"
        "docs/spec.md|spec.md"
        "/abs/path/to/file.txt|file.txt"
        "trailing/|trailing"
        "trailing///|trailing"
        "deep/nested/path/x.y|x.y"
        "./relative.md|relative.md"
    )
    local entry input expected actual
    for entry in "${cases[@]}"; do
        input="${entry%|*}"
        expected="${entry#*|}"
        actual=$(apr_lib_manifest_basename "$input")
        [[ "$actual" == "$expected" ]] || {
            echo "I13 violation: basename('$input') = '$actual' (want '$expected')" >&2
            return 1
        }
        # Negative pin: basename never emits an absolute path.
        [[ "$actual" != /* ]] || {
            echo "I13 violation: basename returned absolute path '$actual'" >&2
            return 1
        }
    done
    # Empty input returns empty (documented behavior).
    actual=$(apr_lib_manifest_basename "")
    [[ -z "$actual" ]] || {
        echo "I13 violation: basename('') = '$actual'" >&2
        return 1
    }
}

# ===========================================================================
# I14 — entry_json byte-determinism
# ===========================================================================

@test "I14: entry_json is byte-deterministic across N calls for the same inputs" {
    local f
    f=$(_write_fixture "e.md" "entry json determinism payload")
    local first
    first=$(apr_lib_manifest_entry_json "$f" "required" "")
    local i again
    for ((i=0; i<25; i++)); do
        again=$(apr_lib_manifest_entry_json "$f" "required" "")
        [[ "$first" == "$again" ]] || {
            echo "I14 violation at iter $i" >&2
            return 1
        }
    done
}
