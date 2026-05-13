#!/usr/bin/env bats
# test_size_metamorphic.bats
#
# Bead automated_plan_reviser_pro-7123 — metamorphic/property layer
# for lib/size.sh (per-file byte accounting + budget enforcement +
# policy resolution).
#
# tests/unit/test_size.bats has 25 happy-path tests. This file adds
# invariant pins on the math + decision boundaries so future budget /
# threshold tweaks can't silently drift away from the documented
# semantics.
#
# Metamorphic relations and properties pinned:
#   MR1 — adding a file to the input list grows files_total by exactly
#         that file's bytes
#   MR2 — removing a file shrinks files_total by exactly that file's bytes
#   MR3 — doubling a file's bytes increases files_total by that delta
#   MR4 — total_bytes == manifest_bytes + template_bytes (load-bearing
#         contract: total is the bytes oracle -p actually sends)
#   MR5 — breakdown is byte-deterministic for the same inputs
#         (sort-stable)
#   MR6 — check_budget threshold: bytes == budget is OK (≤), bytes ==
#         budget + 1 is over
#   MR7 — policy_resolve monotonicity: warn ≤ budget; bytes flips from
#         ok → warn → over_budget at the thresholds
#   MR8 — empty input → total=0, files=[]
#   MR9 — missing files contribute bytes=0 (NOT silently skipped)
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/size.sh"

    FIXTURE_ROOT="$TEST_DIR/size_fuzz"
    mkdir -p "$FIXTURE_ROOT"
    export FIXTURE_ROOT

    # Stage 3 deterministic files of distinct known sizes.
    printf 'aaaaa\n'                                > "$FIXTURE_ROOT/small.md"   # 6 bytes
    printf 'bbbbbbbbbb\n'                           > "$FIXTURE_ROOT/medium.md"  # 11 bytes
    printf 'cccccccccccccccccccccccccccccc\n'       > "$FIXTURE_ROOT/large.md"   # 31 bytes

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Helper: extract a numeric field from breakdown JSON.
breakdown_field() {
    local field="$1" json="$2"
    jq -r ".$field" <<<"$json"
}

# ===========================================================================
# MR1 — adding a file grows files_total by exactly that file's bytes
# ===========================================================================

@test "MR1: adding a file grows files_total by exactly that file's bytes" {
    local b1 b2 delta
    b1=$(apr_lib_size_breakdown "" "" "$FIXTURE_ROOT/small.md" | jq -r '.files_total_bytes')
    b2=$(apr_lib_size_breakdown "" "" "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" | jq -r '.files_total_bytes')
    delta=$(( b2 - b1 ))
    local medium_bytes
    medium_bytes=$(wc -c < "$FIXTURE_ROOT/medium.md" | tr -d '[:space:]')
    [[ "$delta" -eq "$medium_bytes" ]] || {
        echo "delta=$delta want $medium_bytes (b1=$b1 b2=$b2)" >&2
        return 1
    }
}

# ===========================================================================
# MR2 — removing a file shrinks files_total by exactly that file's bytes
# ===========================================================================

@test "MR2: removing a file shrinks files_total by exactly that file's bytes" {
    local b_with b_without
    b_with=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" "$FIXTURE_ROOT/large.md" \
        | jq -r '.files_total_bytes')
    b_without=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/large.md" \
        | jq -r '.files_total_bytes')

    local medium_bytes
    medium_bytes=$(wc -c < "$FIXTURE_ROOT/medium.md" | tr -d '[:space:]')
    [[ $(( b_with - b_without )) -eq "$medium_bytes" ]]
}

# ===========================================================================
# MR3 — doubling a file's bytes increases files_total by that delta
# ===========================================================================

@test "MR3: doubling a file's bytes increases files_total by exactly the original byte count" {
    local before before_bytes
    before=$(apr_lib_size_breakdown "" "" "$FIXTURE_ROOT/medium.md" | jq -r '.files_total_bytes')
    before_bytes=$(wc -c < "$FIXTURE_ROOT/medium.md" | tr -d '[:space:]')

    # Double the file at the byte level (preserves any trailing newline).
    cat "$FIXTURE_ROOT/medium.md" "$FIXTURE_ROOT/medium.md" > "$FIXTURE_ROOT/medium.md.doubled"
    mv "$FIXTURE_ROOT/medium.md.doubled" "$FIXTURE_ROOT/medium.md"

    local after after_bytes
    after=$(apr_lib_size_breakdown "" "" "$FIXTURE_ROOT/medium.md" | jq -r '.files_total_bytes')
    after_bytes=$(wc -c < "$FIXTURE_ROOT/medium.md" | tr -d '[:space:]')

    # The on-disk file grew by exactly `before_bytes`.
    [[ "$after_bytes" -eq $(( before_bytes * 2 )) ]] || {
        echo "file did not double cleanly: $before_bytes → $after_bytes" >&2
        return 1
    }
    # And the breakdown reflects that delta.
    [[ $(( after - before )) -eq "$before_bytes" ]] || {
        echo "files_total delta: before=$before after=$after want=$before_bytes" >&2
        return 1
    }
}

# ===========================================================================
# MR4 — total_bytes == manifest_bytes + template_bytes
# ===========================================================================

@test "MR4: total_bytes equals manifest_bytes + template_bytes exactly" {
    local cases=(
        " | "                                                  # both empty
        "manifest only| "                                      # manifest only
        " |template only"                                      # template only
        "Manifest with newlines here|And template body too"    # both
    )
    local case manifest template json total mb tb
    for case in "${cases[@]}"; do
        manifest="${case%%|*}"
        template="${case##*|}"
        json=$(apr_lib_size_breakdown "$manifest" "$template" \
            "$FIXTURE_ROOT/small.md")
        total=$(jq -r '.total_bytes' <<<"$json")
        mb=$(jq -r '.manifest_bytes' <<<"$json")
        tb=$(jq -r '.template_bytes' <<<"$json")
        [[ "$total" -eq $(( mb + tb )) ]] || {
            echo "MR4 violation for '$case': total=$total mb=$mb tb=$tb" >&2
            return 1
        }
    done
}

# ===========================================================================
# MR5 — breakdown is byte-deterministic across repeated calls
# ===========================================================================

@test "MR5: 30 repeated breakdown calls produce byte-identical JSON" {
    local baseline current i
    baseline=$(apr_lib_size_breakdown "manifest" "template" \
        "$FIXTURE_ROOT/large.md" "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md")
    for i in $(seq 1 30); do
        current=$(apr_lib_size_breakdown "manifest" "template" \
            "$FIXTURE_ROOT/large.md" "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md")
        [[ "$current" == "$baseline" ]] || {
            echo "non-determinism at iter $i" >&2
            return 1
        }
    done
}

@test "MR5 sort-stability: same file set in any input order produces identical files[] array" {
    local out1 out2
    out1=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" "$FIXTURE_ROOT/large.md" \
        | jq '.files')
    out2=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/large.md" "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" \
        | jq '.files')
    [[ "$out1" == "$out2" ]]
}

# ===========================================================================
# MR6 — check_budget boundary semantics
# ===========================================================================

@test "MR6: check_budget with bytes == budget returns 0 (inclusive ≤)" {
    apr_lib_size_check_budget 100 100 || {
        echo "100 <= 100 should be OK" >&2
        return 1
    }
}

@test "MR6: check_budget with bytes == budget + 1 returns 1 (over)" {
    if apr_lib_size_check_budget 101 100; then
        echo "101 > 100 should NOT be OK" >&2
        return 1
    fi
}

@test "MR6: check_budget with budget=0 disables the check (always returns 0)" {
    apr_lib_size_check_budget 1000000000 0
}

# ===========================================================================
# MR7 — policy_resolve monotonicity
# ===========================================================================

@test "MR7: policy_resolve ok / warn / over_budget transitions at the configured thresholds" {
    # warn=50, budget=100. Pin every state.
    local v
    v=$(apr_lib_size_policy_resolve 10 100 50);  [[ "$v" == "ok"          ]] || { echo "10 want=ok got=$v"; return 1; }
    v=$(apr_lib_size_policy_resolve 50 100 50);  [[ "$v" == "ok"          ]] || { echo "50 want=ok got=$v"; return 1; }
    v=$(apr_lib_size_policy_resolve 51 100 50);  [[ "$v" == "warn"        ]] || { echo "51 want=warn got=$v"; return 1; }
    v=$(apr_lib_size_policy_resolve 100 100 50); [[ "$v" == "warn"        ]] || { echo "100 want=warn got=$v"; return 1; }
    v=$(apr_lib_size_policy_resolve 101 100 50); [[ "$v" == "over_budget" ]] || { echo "101 want=over_budget got=$v"; return 1; }
}

@test "MR7: policy_resolve respects warn=0 (disabled) → never returns 'warn'" {
    local v
    v=$(apr_lib_size_policy_resolve 50 100 0);  [[ "$v" == "ok"          ]]
    v=$(apr_lib_size_policy_resolve 200 100 0); [[ "$v" == "over_budget" ]]
}

@test "MR7: policy_resolve respects budget=0 (disabled) → never returns 'over_budget'" {
    local v
    v=$(apr_lib_size_policy_resolve 50 0 0); [[ "$v" == "ok" ]]
    v=$(apr_lib_size_policy_resolve 999999999 0 100); [[ "$v" == "warn" ]]
}

# ===========================================================================
# MR8 — empty input → zeros + empty files[]
# ===========================================================================

@test "MR8: empty manifest + empty template + no files → all-zero envelope with []" {
    local json
    json=$(apr_lib_size_breakdown "" "")
    jq -e '
        .total_bytes == 0
        and .manifest_bytes == 0
        and .template_bytes == 0
        and .files_total_bytes == 0
        and (.files | length == 0)
    ' <<<"$json" >/dev/null
}

@test "MR8: apr_lib_size_total on empty input returns 0" {
    local v
    v=$(apr_lib_size_total "")
    [[ "$v" == "0" ]]
}

# ===========================================================================
# MR9 — missing files contribute bytes=0 (NOT silently skipped)
# ===========================================================================

@test "MR9: missing file paths contribute bytes=0 and still appear in files[]" {
    local json
    json=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/does-not-exist.md")

    # Both files appear in files[].
    [[ "$(jq '.files | length' <<<"$json")" -eq 2 ]]

    # The missing one has bytes=0.
    jq -e '.files[] | select(.path | endswith("does-not-exist.md")) | .bytes == 0' \
        <<<"$json" >/dev/null

    # files_total_bytes equals just small.md's bytes.
    local small_bytes
    small_bytes=$(wc -c < "$FIXTURE_ROOT/small.md" | tr -d '[:space:]')
    [[ "$(jq -r '.files_total_bytes' <<<"$json")" -eq "$small_bytes" ]]
}

# ===========================================================================
# Cross-property: breakdown.files[i].bytes sum equals files_total_bytes
# ===========================================================================

@test "compose: sum of breakdown.files[].bytes equals files_total_bytes" {
    local json sum total
    json=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" "$FIXTURE_ROOT/large.md")
    sum=$(jq -r '[.files[].bytes] | add' <<<"$json")
    total=$(jq -r '.files_total_bytes' <<<"$json")
    [[ "$sum" -eq "$total" ]] || {
        echo "sum-of-files ($sum) != files_total ($total)" >&2
        return 1
    }
}

@test "compose: every breakdown.files[] entry has {path, basename, bytes}" {
    local json
    json=$(apr_lib_size_breakdown "" "" \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md")
    jq -e '[.files[]
            | (has("path") and has("basename") and has("bytes"))]
            | all' <<<"$json" >/dev/null
}

# ===========================================================================
# Edge: very large file (1MB) sums correctly
# ===========================================================================

@test "edge: 1MB file contributes exactly 1048576 bytes" {
    local big="$FIXTURE_ROOT/big.bin"
    dd if=/dev/zero of="$big" bs=1024 count=1024 2>/dev/null
    local json bytes
    json=$(apr_lib_size_breakdown "" "" "$big")
    bytes=$(jq -r '.files[0].bytes' <<<"$json")
    [[ "$bytes" -eq 1048576 ]]
}

# ===========================================================================
# JSON validity over a corpus of inputs
# ===========================================================================

@test "conformance: breakdown emits valid JSON across diverse inputs" {
    local inputs=(
        "''"
        "'manifest only' ''"
        "'' 'template only'"
        "'manifest' 'template' '$FIXTURE_ROOT/small.md'"
        "'$(printf 'multi\nline')' '$(printf 'with\ttabs')' '$FIXTURE_ROOT/small.md' '$FIXTURE_ROOT/medium.md'"
    )
    local m t f1 f2 json
    # m, t = manifest/template texts; f1, f2 = optional files.
    json=$(apr_lib_size_breakdown "" "")
    jq -e . <<<"$json" >/dev/null

    json=$(apr_lib_size_breakdown "m" "" "$FIXTURE_ROOT/small.md")
    jq -e . <<<"$json" >/dev/null

    json=$(apr_lib_size_breakdown $'man\nifest' $'tem\tplate' \
        "$FIXTURE_ROOT/small.md" "$FIXTURE_ROOT/medium.md" "$FIXTURE_ROOT/large.md")
    jq -e . <<<"$json" >/dev/null
}
