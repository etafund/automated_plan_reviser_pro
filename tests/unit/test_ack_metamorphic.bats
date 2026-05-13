#!/usr/bin/env bats
# test_ack_metamorphic.bats - Metamorphic / property tests for lib/ack.sh (kk7n)
#
# Complements tests/unit/test_ack.bats (21 happy-path tests) with seven
# metamorphic relations that pin invariants the implementation must
# preserve across refactors.
#
# MR1 — parse(render(entries)) preserves the entry set (round-trip)
# MR2 — render(parse(text_with_ack)) reproduces the block from its
#       parsed contents (modulo entry order, since render sorts)
# MR3 — validate(perfect_ack, expected) is permutation-invariant on
#       `expected`
# MR4 — adding an unexpected entry to the ACK marks validate's
#       `unexpected` signal AND ack_complete remains true
# MR5 — render output is sort-stable (input order doesn't affect output)
# MR6 — parse on the same input is byte-deterministic across N calls
# MR7 — validate's JSON output is well-formed AND has the documented
#       {ack_present, ack_complete, ack_matches_manifest, missing,
#        mismatched, unexpected} shape

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

# Canonical 64-hex shas. Distinct so order matters.
SHA_A="9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
SHA_B="2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
SHA_C="5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
SHA_D="ef2d127de37b942baad06145e54b0c619a1f22327b2ebbcfbec78f5564afe39d"

# =============================================================================
# MR1 — parse(render(entries)) preserves the entry set
# =============================================================================

@test "MR1: parse(render(triples)) preserves entry set" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local triples=(
        "README.md|$SHA_A|100"
        "SPEC.md|$SHA_B|200"
        "IMPL.md|$SHA_C|300"
    )
    local rendered parsed
    rendered=$(apr_lib_ack_render_instruction "${triples[@]}")
    parsed=$(apr_lib_ack_parse "$rendered")
    # Convert parsed JSON-lines back into a comparable set.
    local parsed_set
    parsed_set=$(printf '%s\n' "$parsed" | python3 -c "
import json, sys
entries = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    entries.append((d['basename'], d['sha256'], d['bytes']))
print(sorted(entries))
")
    # Build the expected set from triples.
    local expected_set
    expected_set=$(python3 -c "
triples = ['README.md|$SHA_A|100', 'SPEC.md|$SHA_B|200', 'IMPL.md|$SHA_C|300']
es = []
for t in triples:
    bn, sha, bts = t.split('|')
    es.append((bn, sha, int(bts)))
print(sorted(es))
")
    [ "$parsed_set" = "$expected_set" ]
}

# =============================================================================
# MR2 — render(parse(text)) reproduces the block (modulo order)
# =============================================================================

@test "MR2: render(parse(text_with_ack)) reproduces block modulo entry order" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    # Note input is in non-sorted order; render() will sort.
    local input="ACK
- SPEC.md sha256=$SHA_B bytes=200
- README.md sha256=$SHA_A bytes=100
END_ACK"
    # Parse to triples.
    local parsed triples_arg=()
    parsed=$(apr_lib_ack_parse "$input")
    while IFS= read -r jline; do
        [[ -z "$jline" ]] && continue
        local triple
        triple=$(printf '%s' "$jline" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(f\"{d['basename']}|{d['sha256']}|{d['bytes']}\")
")
        triples_arg+=("$triple")
    done <<< "$parsed"
    # Re-render.
    local re_rendered
    re_rendered=$(apr_lib_ack_render_instruction "${triples_arg[@]}")
    # Re-parse the re-rendered text -> compare entry SETS (the bead
    # explicitly says "modulo entry order, since render sorts").
    local re_parsed
    re_parsed=$(apr_lib_ack_parse "$re_rendered")
    # Set equality: sort both parsings line-by-line.
    local p_sorted r_sorted
    p_sorted=$(printf '%s\n' "$parsed" | LC_ALL=C sort)
    r_sorted=$(printf '%s\n' "$re_parsed" | LC_ALL=C sort)
    [ "$p_sorted" = "$r_sorted" ]
}

# =============================================================================
# MR3 — validate is permutation-invariant on `expected`
# =============================================================================

@test "MR3: validate(perfect_ack, expected) permutation-invariant" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input="ACK
- README.md sha256=$SHA_A bytes=100
- SPEC.md sha256=$SHA_B bytes=200
- IMPL.md sha256=$SHA_C bytes=300
END_ACK"
    local out_order1 out_order2 out_order3
    out_order1=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200" "IMPL.md|$SHA_C|300" || true)
    out_order2=$(apr_lib_ack_validate "$input" "IMPL.md|$SHA_C|300" "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200" || true)
    out_order3=$(apr_lib_ack_validate "$input" "SPEC.md|$SHA_B|200" "IMPL.md|$SHA_C|300" "README.md|$SHA_A|100" || true)
    # All three permutations of `expected` should produce identical JSON.
    [ "$out_order1" = "$out_order2" ]
    [ "$out_order2" = "$out_order3" ]
}

# =============================================================================
# MR4 — over-supply doesn't break ack_complete; unexpected populated
# =============================================================================

@test "MR4: extra entry in ACK marks unexpected; ack_complete still true" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input="ACK
- README.md sha256=$SHA_A bytes=100
- SPEC.md sha256=$SHA_B bytes=200
- BONUS.md sha256=$SHA_D bytes=42
END_ACK"
    # Expected list is only README + SPEC; BONUS is over-supply.
    local out
    out=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200" || true)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['ack_present'] is True
assert d['ack_complete'] is True   # over-supply does NOT break completeness
assert d['unexpected'] == ['BONUS.md'], d
assert d['missing'] == []
"
}

# =============================================================================
# MR5 — render is sort-stable
# =============================================================================

@test "MR5: render output is sort-stable across input permutations" {
    local in_order1 in_order2 in_order3
    in_order1=$(apr_lib_ack_render_instruction "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200" "IMPL.md|$SHA_C|300")
    in_order2=$(apr_lib_ack_render_instruction "IMPL.md|$SHA_C|300" "README.md|$SHA_A|100" "SPEC.md|$SHA_B|200")
    in_order3=$(apr_lib_ack_render_instruction "SPEC.md|$SHA_B|200" "IMPL.md|$SHA_C|300" "README.md|$SHA_A|100")
    [ "$in_order1" = "$in_order2" ]
    [ "$in_order2" = "$in_order3" ]
}

# =============================================================================
# MR6 — parse is byte-deterministic
# =============================================================================

@test "MR6: parse byte-deterministic across N invocations" {
    local input="ACK
- README.md sha256=$SHA_A bytes=100
- SPEC.md sha256=$SHA_B bytes=200
END_ACK"
    local p1 p2 p3 p4
    p1=$(apr_lib_ack_parse "$input")
    p2=$(apr_lib_ack_parse "$input")
    p3=$(apr_lib_ack_parse "$input")
    p4=$(apr_lib_ack_parse "$input")
    [ "$p1" = "$p2" ]
    [ "$p2" = "$p3" ]
    [ "$p3" = "$p4" ]
}

# =============================================================================
# MR7 — validate output shape matches documented contract
# =============================================================================

@test "MR7: validate output is well-formed JSON with documented field set" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local input="ACK
- README.md sha256=$SHA_A bytes=100
END_ACK"
    local out
    out=$(apr_lib_ack_validate "$input" "README.md|$SHA_A|100" || true)
    python3 -c "
import json
d = json.loads('''$out''')
expected_keys = {
    'ack_present', 'ack_complete', 'ack_matches_manifest',
    'missing', 'mismatched', 'unexpected'
}
actual_keys = set(d.keys())
assert actual_keys == expected_keys, f'shape mismatch: got {actual_keys}, expected {expected_keys}'
# Type assertions.
assert isinstance(d['ack_present'], bool)
assert isinstance(d['ack_complete'], bool)
assert isinstance(d['ack_matches_manifest'], bool)
assert isinstance(d['missing'], list)
assert isinstance(d['mismatched'], list)
assert isinstance(d['unexpected'], list)
"
}

# =============================================================================
# Bonus: round-trip with permutation invariance
# =============================================================================

@test "MR-bonus: render is the inverse of parse on canonical input (set-equality)" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local triples=(
        "README.md|$SHA_A|100"
        "SPEC.md|$SHA_B|200"
    )
    # forward: triples -> render -> parse
    local rendered parsed
    rendered=$(apr_lib_ack_render_instruction "${triples[@]}")
    parsed=$(apr_lib_ack_parse "$rendered")
    # Recover triples from parsed
    local recovered=()
    while IFS= read -r jline; do
        [[ -z "$jline" ]] && continue
        local triple
        triple=$(printf '%s' "$jline" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(f\"{d['basename']}|{d['sha256']}|{d['bytes']}\")
")
        recovered+=("$triple")
    done <<< "$parsed"
    # Render again from recovered triples
    local rendered_again
    rendered_again=$(apr_lib_ack_render_instruction "${recovered[@]}")
    # Should be byte-identical because render sorts.
    [ "$rendered" = "$rendered_again" ]
}
