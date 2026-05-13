#!/usr/bin/env bats
# test_ack.bats - Tests for lib/ack.sh (bd-34z)
#
# Validates the ACK policy primitives:
#   - apr_lib_ack_render_instruction
#   - apr_lib_ack_parse
#   - apr_lib_ack_validate

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/ack.sh"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Canonical 64-hex shas for tests.
SHA_A="9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
SHA_B="2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
SHA_C="5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

# =============================================================================
# apr_lib_ack_render_instruction
# =============================================================================

@test "render_instruction: empty input -> no output" {
    run apr_lib_ack_render_instruction
    assert_success
    assert_output ""
}

@test "render_instruction: emits ACK + END_ACK block" {
    local out
    out=$(apr_lib_ack_render_instruction "README.md|$SHA_A|100")
    [[ "$out" == *"ACK"* ]]
    [[ "$out" == *"END_ACK"* ]]
    [[ "$out" == *"README.md sha256=$SHA_A bytes=100"* ]]
}

@test "render_instruction: entries sorted by basename (LC_ALL=C)" {
    local out
    out=$(apr_lib_ack_render_instruction \
        "SPEC.md|$SHA_B|200" \
        "README.md|$SHA_A|100" \
        "Zoo.md|$SHA_C|50")
    # In LC_ALL=C, uppercase comes in ASCII order R < S < Z.
    local idx_r idx_s idx_z
    idx_r=$(printf '%s' "$out" | grep -bo 'README.md' | head -1 | cut -d: -f1)
    idx_s=$(printf '%s' "$out" | grep -bo 'SPEC.md'   | head -1 | cut -d: -f1)
    idx_z=$(printf '%s' "$out" | grep -bo 'Zoo.md'    | head -1 | cut -d: -f1)
    [ "$idx_r" -lt "$idx_s" ]
    [ "$idx_s" -lt "$idx_z" ]
}

@test "render_instruction: deterministic" {
    local out1 out2
    out1=$(apr_lib_ack_render_instruction "A|$SHA_A|10" "B|$SHA_B|20")
    out2=$(apr_lib_ack_render_instruction "A|$SHA_A|10" "B|$SHA_B|20")
    [ "$out1" = "$out2" ]
}

# =============================================================================
# apr_lib_ack_parse
# =============================================================================

@test "parse: empty input returns rc=1, no output" {
    local out rc=0
    out=$(apr_lib_ack_parse "") || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$out" ]
}

@test "parse: no ACK marker returns rc=1" {
    local out rc=0
    out=$(apr_lib_ack_parse "just some model output, no ack here") || rc=$?
    [ "$rc" -eq 1 ]
}

@test "parse: happy path extracts entries" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input="ACK
- README.md sha256=$SHA_A bytes=100
- SPEC.md sha256=$SHA_B bytes=200
END_ACK
rest of model output"
    local out
    out=$(apr_lib_ack_parse "$input")
    # Each line is a JSON object; total 2 entries.
    local count
    count=$(printf '%s\n' "$out" | grep -c '"basename"')
    [ "$count" = "2" ]
    # First entry parses cleanly.
    local first
    first=$(printf '%s\n' "$out" | head -1)
    python3 -c "
import json
d = json.loads('''$first''')
assert d['basename'] == 'README.md'
assert d['sha256'] == '$SHA_A'
assert d['bytes'] == 100
"
}

@test "parse: case-insensitive ACK / END_ACK markers" {
    local input
    input="ack
- README.md sha256=$SHA_A bytes=100
end_ack"
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *"README.md"* ]]
}

@test "parse: tolerant of leading whitespace + bullet variations" {
    local input
    input="  ACK
    * README.md sha256=$SHA_A bytes=100
  END_ACK"
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *"README.md"* ]]
}

@test "parse: extra spaces around sha256=/bytes=" {
    local input
    input="ACK
- README.md sha256 = $SHA_A   bytes = 100
END_ACK"
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *"$SHA_A"* ]]
}

@test "parse: tolerates Windows-style CRLF line endings" {
    local input
    input=$'ACK\r\n- README.md sha256='"$SHA_A"$' bytes=100\r\nEND_ACK\r\n'
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *"README.md"* ]]
}

@test "parse: stops at END_ACK, ignores later ACK-like content" {
    local input
    input="ACK
- README.md sha256=$SHA_A bytes=100
END_ACK
then later: ACK
- FAKE.md sha256=ffffff bytes=999
END_ACK"
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *"README.md"* ]]
    [[ "$out" != *"FAKE.md"* ]]
}

@test "parse: missing bytes -> bytes:null" {
    local input
    input="ACK
- README.md sha256=$SHA_A
END_ACK"
    local out
    out=$(apr_lib_ack_parse "$input")
    [[ "$out" == *'"bytes":null'* ]]
}

@test "parse: empty ACK block returns rc=0 with no entries" {
    local input
    input="ACK
END_ACK
rest"
    local rc=0 out
    out=$(apr_lib_ack_parse "$input") || rc=$?
    [ "$rc" -eq 0 ]
    [ -z "$out" ]
}

# =============================================================================
# apr_lib_ack_validate
# =============================================================================

@test "validate: perfect ACK -> all signals true, rc=0" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input="ACK
- README.md sha256=$SHA_A bytes=100
- SPEC.md sha256=$SHA_B bytes=200
END_ACK"
    local out rc=0
    out=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200") || rc=$?
    [ "$rc" -eq 0 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_present'] is True
assert d['ack_complete'] is True
assert d['ack_matches_manifest'] is True
assert d['missing'] == []
assert d['mismatched'] == []
"
}

@test "validate: no ACK block -> all signals false, rc=1" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out rc=0
    out=$(apr_lib_ack_validate "model output without ack" \
        "README.md|$SHA_A|100") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_present'] is False
assert d['ack_complete'] is False
assert d['ack_matches_manifest'] is False
assert d['missing'] == ['README.md']
"
}

@test "validate: missing required entry -> ack_complete=false" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input="ACK
- README.md sha256=$SHA_A bytes=100
END_ACK"
    local out rc=0
    out=$(apr_lib_ack_validate "$input" \
        "README.md|$SHA_A|100" \
        "SPEC.md|$SHA_B|200") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_present'] is True
assert d['ack_complete'] is False
assert d['ack_matches_manifest'] is False
assert 'SPEC.md' in d['missing']
"
}

@test "validate: sha mismatch -> ack_matches=false, mismatched populated" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local wrong_sha="0000000000000000000000000000000000000000000000000000000000000000"
    local input
    input="ACK
- README.md sha256=$wrong_sha bytes=100
END_ACK"
    local out rc=0
    out=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_present'] is True
assert d['ack_complete'] is True
assert d['ack_matches_manifest'] is False
assert len(d['mismatched']) == 1
mm = d['mismatched'][0]
assert mm['basename'] == 'README.md'
assert mm['expected_sha'] == '$SHA_A'
assert mm['actual_sha'] == '$wrong_sha'
"
}

@test "validate: bytes mismatch -> ack_matches=false" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input
    input="ACK
- README.md sha256=$SHA_A bytes=999
END_ACK"
    local out rc=0
    out=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100") || rc=$?
    [ "$rc" -eq 1 ]
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_matches_manifest'] is False
assert len(d['mismatched']) == 1
"
}

@test "validate: empty expected list + ACK present -> all signals true" {
    # If the workflow has no required docs (edge), an ACK is trivially
    # complete and matching.
    local input
    input="ACK
END_ACK"
    local out rc=0
    out=$(apr_lib_ack_validate "$input") || rc=$?
    [ "$rc" -eq 0 ]
    [[ "$out" == *'"ack_present":true'* ]]
    [[ "$out" == *'"ack_matches_manifest":true'* ]]
}

@test "validate: well-formed JSON output" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_ack_validate "no ack" "X|abc|1" || true)
    python3 -c "import json; json.loads('''$out''')"
}
