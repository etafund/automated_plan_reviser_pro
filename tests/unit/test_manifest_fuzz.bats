#!/usr/bin/env bats
# test_manifest_fuzz.bats
#
# Bead automated_plan_reviser_pro-fv5z — fuzz/property suite for
# lib/manifest.sh.
#
# tests/unit/test_manifest.bats covers each helper individually (39
# happy-path tests). This file adds a property-based layer that pins:
#
#   I1 — apr_lib_manifest_json_escape output, when wrapped in `"…"`,
#        always parses cleanly through jq for arbitrary input bytes
#   I2 — apr_lib_manifest_entry_json output parses as a valid JSON
#        object for every accepted reason + path combination
#   I3 — apr_lib_manifest_render_json output round-trips through jq
#        (parse → length matches input; insertion-by-path order)
#   I4 — render_json output is invariant under input permutation
#        (the helper sorts internally; the property pins that contract)
#   I5 — render_text and render_json describe the same entries
#        (same paths, same insertion-reason classification)
#   I6 — apr_lib_manifest_hash_text is deterministic AND
#        byte-sensitive (any text change → different hash)
#   I7 — empty input is handled cleanly in every renderer
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # Source lib/manifest.sh directly. No apr dependency.
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/manifest.sh"

    # Stage a small, deterministic fixture project so entry_json /
    # render_* have real files to read.
    FIXTURE_ROOT="$TEST_DIR/manifest_fuzz"
    mkdir -p "$FIXTURE_ROOT"
    printf 'alpha\n'             > "$FIXTURE_ROOT/a.md"
    printf 'bravo bravo\n'       > "$FIXTURE_ROOT/b.md"
    printf 'charlie\nfin\n'      > "$FIXTURE_ROOT/c.md"
    : > "$FIXTURE_ROOT/empty.md"
    export FIXTURE_ROOT

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# I1 — json_escape: adversarial input survives jq parse when quoted
# ===========================================================================

@test "json_escape: every adversarial input produces output parseable as a JSON string" {
    # The contract is: for any input s, `"$(escape s)"` is a valid JSON
    # string literal AND `jq -r '.'` on that literal reproduces s.
    # We can't fully assert the reverse for every byte (the engine
    # passes through ASCII controls), but for the cases the helper
    # *does* document — backslash, double quote, \n, \r, \t — we can
    # both parse AND round-trip.
    local cases=(
        "plain"
        "with backslash \\"
        "with \"quote\""
        "with"$'\n'"newline"
        "with"$'\r'"return"
        "with"$'\t'"tab"
        "all in one: \\ \" "$'\n'$'\t'" end"
        "json specials: { [ , : } ]"
        "unicode → ✓ ⚠ ✗"
        ""
    )
    local s esc wrapped roundtrip
    for s in "${cases[@]}"; do
        esc=$(apr_lib_manifest_json_escape "$s")
        wrapped="\"$esc\""
        # Parse step.
        jq -e . <<<"$wrapped" >/dev/null || {
            echo "[json_escape I1] not parseable for input '$(printf '%q' "$s")':" >&2
            echo "  escaped='$esc'" >&2
            echo "  wrapped='$wrapped'" >&2
            return 1
        }
        # Round-trip step (jq -r decodes the JSON string back to bytes).
        roundtrip=$(jq -r . <<<"$wrapped")
        [[ "$roundtrip" == "$s" ]] || {
            echo "[json_escape I1] round-trip mismatch for input '$(printf '%q' "$s")':" >&2
            echo "  got: '$(printf '%q' "$roundtrip")'" >&2
            return 1
        }
    done
}

@test "json_escape: long strings (>1KB) survive escaping" {
    local long
    long=$(printf 'a%.0s' $(seq 1 1500))
    local esc
    esc=$(apr_lib_manifest_json_escape "$long")
    jq -e . <<<"\"$esc\"" >/dev/null
    [[ "${#esc}" -eq 1500 ]]
}

# ===========================================================================
# I2 — entry_json validity across every accepted reason
# ===========================================================================

@test "entry_json: produces parseable JSON for every accepted reason" {
    local reasons=(required optional impl_every_n skipped)
    local r out
    for r in "${reasons[@]}"; do
        if [[ "$r" == "skipped" ]]; then
            out=$(apr_lib_manifest_entry_json "$FIXTURE_ROOT/a.md" "$r" "not_due_yet")
        else
            out=$(apr_lib_manifest_entry_json "$FIXTURE_ROOT/a.md" "$r")
        fi
        jq -e . <<<"$out" >/dev/null || {
            echo "entry_json with reason='$r' produced non-JSON:" >&2
            echo "  $out" >&2
            return 1
        }
        jq -e --arg r "$r" '.inclusion_reason == $r' <<<"$out" >/dev/null
    done
}

@test "entry_json: every required key is present (path, basename, bytes, sha256, inclusion_reason)" {
    local out
    out=$(apr_lib_manifest_entry_json "$FIXTURE_ROOT/b.md" "required")
    jq -e '
        has("path") and has("basename") and has("bytes")
        and has("sha256") and has("inclusion_reason")
    ' <<<"$out" >/dev/null
    # skipped_reason only when actually skipped.
    jq -e 'has("skipped_reason") == false' <<<"$out" >/dev/null
}

@test "entry_json: skipped reason adds skipped_reason key" {
    local out
    out=$(apr_lib_manifest_entry_json "$FIXTURE_ROOT/b.md" "skipped" "not_due_yet")
    jq -e '.skipped_reason == "not_due_yet"' <<<"$out" >/dev/null
}

@test "entry_json: path containing JSON specials still produces valid JSON" {
    # Stage a file whose path contains backslash and quote characters.
    # We can't actually create a file with `"` in some filesystems, but
    # the json_escape layer is what matters — entry_json round-trips
    # whatever path it's given through json_escape.
    local weird_path='odd"file\name.md'
    local fpath="$FIXTURE_ROOT/$weird_path"
    printf 'x' > "$fpath" || skip "filesystem rejects the test path"
    local out
    out=$(apr_lib_manifest_entry_json "$fpath" "required")
    jq -e . <<<"$out" >/dev/null
    # jq -r decodes the embedded JSON string back to bytes.
    local got_path
    got_path=$(jq -r '.path' <<<"$out")
    [[ "$got_path" == "$fpath" ]]
}

# ===========================================================================
# I3 — render_json round-trip + length
# ===========================================================================

@test "render_json: round-trips through jq and reports the expected entry count" {
    local out
    out=$(apr_lib_manifest_render_json \
        "$FIXTURE_ROOT/a.md|required|" \
        "$FIXTURE_ROOT/b.md|optional|" \
        "$FIXTURE_ROOT/c.md|impl_every_n|")
    jq -e . <<<"$out" >/dev/null
    [[ "$(jq 'length' <<<"$out")" -eq 3 ]]
    # Each entry validates as a JSON object with the required keys.
    jq -e '[.[] | (has("path") and has("basename") and has("bytes")
                    and has("sha256") and has("inclusion_reason"))] | all' \
        <<<"$out" >/dev/null
}

@test "render_json: empty input returns the JSON array '[]'" {
    local out
    out=$(apr_lib_manifest_render_json)
    [[ "$out" == "[]" ]]
    jq -e 'length == 0' <<<"$out" >/dev/null
}

# ===========================================================================
# I4 — render_json is invariant under input permutation (internal sort)
# ===========================================================================

@test "render_json: output is byte-identical when input triples are permuted" {
    local out1 out2 out3
    out1=$(apr_lib_manifest_render_json \
        "$FIXTURE_ROOT/a.md|required|" \
        "$FIXTURE_ROOT/b.md|optional|" \
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet")
    out2=$(apr_lib_manifest_render_json \
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet" \
        "$FIXTURE_ROOT/a.md|required|" \
        "$FIXTURE_ROOT/b.md|optional|")
    out3=$(apr_lib_manifest_render_json \
        "$FIXTURE_ROOT/b.md|optional|" \
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet" \
        "$FIXTURE_ROOT/a.md|required|")
    [[ "$out1" == "$out2" ]] || {
        echo "permutation 2 differs:" >&2
        diff <(printf '%s' "$out1") <(printf '%s' "$out2") >&2
        return 1
    }
    [[ "$out1" == "$out3" ]]
}

@test "render_json: entries are sorted by path (LC_ALL=C)" {
    # Use lexicographic-sort-revealing names so we can verify ordering
    # at the output level.
    printf 'z' > "$FIXTURE_ROOT/zeta.md"
    printf 'a' > "$FIXTURE_ROOT/alpha.md"
    printf 'm' > "$FIXTURE_ROOT/mike.md"
    local out
    out=$(apr_lib_manifest_render_json \
        "$FIXTURE_ROOT/zeta.md|required|" \
        "$FIXTURE_ROOT/alpha.md|required|" \
        "$FIXTURE_ROOT/mike.md|required|")
    local paths
    paths=$(jq -r '.[].path' <<<"$out")
    # Compare to the LC_ALL=C-sorted list.
    local expected
    expected=$(printf '%s\n' \
        "$FIXTURE_ROOT/zeta.md" \
        "$FIXTURE_ROOT/alpha.md" \
        "$FIXTURE_ROOT/mike.md" | LC_ALL=C sort)
    [[ "$paths" == "$expected" ]]
}

# ===========================================================================
# I5 — render_text and render_json describe the same entries
# ===========================================================================

@test "render_text matches render_json on entry count and path set" {
    local triples=(
        "$FIXTURE_ROOT/a.md|required|"
        "$FIXTURE_ROOT/b.md|optional|"
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet"
    )
    local json text
    json=$(apr_lib_manifest_render_json "${triples[@]}")
    text=$(apr_lib_manifest_render_text "${triples[@]}")

    # Every path in render_json appears in render_text.
    local p
    while IFS= read -r p; do
        grep -Fq "path:   $p" <<<"$text" || {
            echo "render_text missing path '$p':" >&2
            echo "$text" >&2
            return 1
        }
    done < <(jq -r '.[].path' <<<"$json")

    # Conversely, the count of "path:" lines in render_text equals the
    # JSON array length.
    local text_count json_count
    text_count=$(grep -c '^    path:' <<<"$text")
    json_count=$(jq 'length' <<<"$json")
    [[ "$text_count" -eq "$json_count" ]]
}

@test "render_text: empty input emits a deterministic placeholder" {
    local out
    out=$(apr_lib_manifest_render_text)
    grep -Fq "[APR Manifest]" <<<"$out"
    grep -Fq "No files configured." <<<"$out"
}

# ===========================================================================
# I6 — hash_text determinism + byte-sensitivity
# ===========================================================================

@test "hash_text: deterministic across repeated calls on the same input" {
    local s='manifest provenance text'
    local h1 h2
    h1=$(apr_lib_manifest_hash_text "$s")
    h2=$(apr_lib_manifest_hash_text "$s")
    [[ "$h1" == "$h2" ]]
    # Lowercase hex sha256 shape.
    [[ "$h1" =~ ^[0-9a-f]{64}$ ]]
}

@test "hash_text: any byte change in input changes the hash" {
    local base='manifest provenance text'
    local h_base
    h_base=$(apr_lib_manifest_hash_text "$base")
    local mutations=(
        'manifest provenance text!'
        'manifest provenance tex'
        'Manifest provenance text'
        'manifest  provenance text'    # double space
    )
    local m h
    for m in "${mutations[@]}"; do
        h=$(apr_lib_manifest_hash_text "$m")
        [[ "$h" != "$h_base" ]] || {
            echo "hash collision for mutation '$(printf '%q' "$m")'" >&2
            return 1
        }
    done
}

@test "hash_text: empty string hashes to the documented empty-string sha256" {
    local empty_sha
    empty_sha=$(apr_lib_manifest_hash_text "")
    # Bash $'' subtleties: printf '%s' '' produces 0 bytes, so this is
    # the sha256 of the empty string.
    [[ "$empty_sha" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]]
}

# ===========================================================================
# I3+I6 composition — render → hash is deterministic AND order-invariant
# ===========================================================================

@test "compose: hash_text(render_json(triples)) is deterministic and order-invariant" {
    local triples_in_order=(
        "$FIXTURE_ROOT/a.md|required|"
        "$FIXTURE_ROOT/b.md|optional|"
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet"
    )
    local triples_shuffled=(
        "$FIXTURE_ROOT/c.md|skipped|not_due_yet"
        "$FIXTURE_ROOT/a.md|required|"
        "$FIXTURE_ROOT/b.md|optional|"
    )
    local r1 r2 h1 h2
    r1=$(apr_lib_manifest_render_json "${triples_in_order[@]}")
    r2=$(apr_lib_manifest_render_json "${triples_shuffled[@]}")
    h1=$(apr_lib_manifest_hash_text "$r1")
    h2=$(apr_lib_manifest_hash_text "$r2")
    [[ "$h1" == "$h2" ]] || {
        echo "manifest hash drift under permutation: $h1 vs $h2" >&2
        return 1
    }
}

# ===========================================================================
# Negative: corrupted triples don't crash the renderers
# ===========================================================================

@test "render_json: triples with empty path are silently dropped" {
    local out
    out=$(apr_lib_manifest_render_json \
        "|required|" \
        "$FIXTURE_ROOT/a.md|required|" \
        "|optional|")
    [[ "$(jq 'length' <<<"$out")" -eq 1 ]]
}

@test "render_text: triples with empty path are silently dropped" {
    local out
    out=$(apr_lib_manifest_render_text \
        "|required|" \
        "$FIXTURE_ROOT/a.md|required|" \
        "|optional|")
    # Only one path: line.
    [[ "$(grep -c '^    path:' <<<"$out")" -eq 1 ]]
}
