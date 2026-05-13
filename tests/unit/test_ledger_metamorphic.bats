#!/usr/bin/env bats
# test_ledger_metamorphic.bats
#
# Bead automated_plan_reviser_pro-lk2t — metamorphic/property layer
# for lib/ledger.sh (bd-1xv per-round provenance writer).
#
# tests/unit/test_ledger.bats (26 tests) covers happy paths. This file
# adds INVARIANT pins on round-trips, the state machine, and redaction
# idempotence so future tweaks can't drift away from the documented
# contract.
#
# Invariants pinned:
#   I1  redact is idempotent: redact(redact(x)) == redact(x)
#   I2  redact is deterministic: same input → byte-identical across 50 calls
#   I3  atomic_write round-trip: write(path, X) then read(path) == redact(X)
#   I4  atomic_write leaves no .tmp file on the happy path
#   I5  build_started → re-parse: schema-required fields all present;
#       schema_version stays "apr_run_ledger.v1"
#   I6  build_finished outcome.ok agrees with (state, code) per the
#       documented matrix
#   I7  build_finished byte-deterministic for the same inputs (env-var
#       contributions frozen)
#   I8  adversarial inputs (control bytes, very long strings, JSON
#       specials in slug/run_id/prompt_hash) produce valid JSON output
#   I9  write_start + write_finish lifecycle: finished JSON contains
#       BOTH started fields (workflow/round/slug) AND outcome.code
#   I10 rapid sequential writes to the same path leave a final state
#       that equals ONE of the inputs (atomic-rename guarantee)
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
    source "$BATS_TEST_DIRNAME/../../lib/ledger.sh"

    FIXTURE_ROOT="$TEST_DIR/ledger_fuzz"
    mkdir -p "$FIXTURE_ROOT"
    export FIXTURE_ROOT

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# I1 — redact is idempotent
# ===========================================================================

@test "I1: redact is idempotent across a representative cross-section of secret shapes" {
    local cases=(
        "Authorization: Bearer abc.def.ghi"
        "key: sk-abcdefghijklmnopqrstuvwxyz12"
        "github: ghp_xxxxxxxxxxxxxxxxxxxxxxx"
        '--token deadbeef0123'
        '--token=deadbeef0123'
        '--api-key sk-abc'
        'password=hunter2'
        'secret=supersecret'
        '{"Authorization": "Bearer foo"}'
    )
    local c once twice
    for c in "${cases[@]}"; do
        once=$(apr_lib_ledger_redact "$c")
        twice=$(apr_lib_ledger_redact "$once")
        [[ "$once" == "$twice" ]] || {
            echo "idempotence violated for '$(printf '%q' "$c")':" >&2
            echo "  once : $once" >&2
            echo "  twice: $twice" >&2
            return 1
        }
    done
}

# ===========================================================================
# I2 — redact is deterministic
# ===========================================================================

@test "I2: 50 repeated redact calls on the same input produce byte-identical output" {
    local input='Bearer abc.def with sk-abcdefghijklmnopqrstuvwxyz12 and ghp_aaaaaaaaaaaaaaaaaaaaa'
    local baseline current i
    baseline=$(apr_lib_ledger_redact "$input")
    for i in $(seq 1 50); do
        current=$(apr_lib_ledger_redact "$input")
        [[ "$current" == "$baseline" ]] || {
            echo "drift at iteration $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I3 — atomic_write round-trip equals redact(content)
# ===========================================================================

@test "I3: atomic_write(path, X) → read(path) equals redact(X) for plain and secret-bearing inputs" {
    local cases=(
        "plain content"
        "Bearer abc.def.ghi"
        '{"key":"sk-abcdefghijklmnopqrstuvwxyz12","value":42}'
        "multi"$'\n'"line"$'\n'"with --token secret"
    )
    local c i=0
    for c in "${cases[@]}"; do
        i=$((i + 1))
        local p="$FIXTURE_ROOT/rt_$i.json"
        apr_lib_ledger_atomic_write "$p" "$c"
        local read_back redacted
        read_back=$(cat "$p")
        redacted=$(apr_lib_ledger_redact "$c")
        [[ "$read_back" == "$redacted" ]] || {
            echo "round-trip drift for case $i:" >&2
            diff <(printf '%s' "$read_back") <(printf '%s' "$redacted") >&2
            return 1
        }
    done
}

# ===========================================================================
# I4 — atomic_write leaves no .tmp residue on success
# ===========================================================================

@test "I4: atomic_write leaves no .tmp.* file after a successful write" {
    local p="$FIXTURE_ROOT/clean.json"
    apr_lib_ledger_atomic_write "$p" '{"state":"started"}'
    [[ -f "$p" ]]
    # No siblings starting with the base name + ".tmp."
    local stragglers
    stragglers=$(find "$FIXTURE_ROOT" -maxdepth 1 -name 'clean.json.tmp.*' 2>/dev/null | wc -l)
    [[ "$stragglers" -eq 0 ]] || {
        echo "found tmp residue:" >&2
        find "$FIXTURE_ROOT" -maxdepth 1 -name 'clean.json.tmp.*' >&2
        return 1
    }
}

# ===========================================================================
# I5 — build_started → re-parse shape
# ===========================================================================

@test "I5: build_started emits a valid envelope with every documented top-level field" {
    local json
    json=$(apr_lib_ledger_build_started \
        "default" 3 "round_3-2026" "run-abc123" "2026-05-13T05:00:00Z" \
        '[]' "sha256-prompt-x" "browser" "5.2 Thinking")

    jq -e . <<<"$json" >/dev/null || { echo "not JSON: $json" >&2; return 1; }

    # Required top-level keys per the schema.
    local key
    for key in schema_version workflow round slug run_id started_at \
               finished_at duration_ms state files prompt_hash oracle \
               outcome execution; do
        jq -e --arg k "$key" 'has($k)' <<<"$json" >/dev/null || {
            echo "missing key '$key':" >&2
            jq . <<<"$json" >&2
            return 1
        }
    done

    jq -e '.schema_version == "apr_run_ledger.v1"' <<<"$json" >/dev/null
    jq -e '.state == "started"'                    <<<"$json" >/dev/null
    jq -e '.outcome.code == "running"'             <<<"$json" >/dev/null
    jq -e '.outcome.ok == false'                   <<<"$json" >/dev/null
}

# ===========================================================================
# I6 — build_finished outcome.ok agreement
# ===========================================================================

@test "I6: build_finished outcome.ok == true iff state==finished AND code==ok" {
    # Pin the (state, code) → outcome.ok matrix per the ledger spec.
    local cases=(
        "finished ok 0 true"
        "finished validation_failed 4 false"
        "failed network_error 10 false"
        "failed ok 0 false"
        "canceled ok 0 false"
    )
    local entry state code exit_code want
    for entry in "${cases[@]}"; do
        read -r state code exit_code want <<<"$entry"
        local json
        json=$(apr_lib_ledger_build_finished \
            "wf" 1 "slug" "run" \
            "2026-01-01T00:00:00Z" "2026-01-01T00:00:30Z" \
            "$state" '[]' "sha256-x" "browser" "5.2 Thinking" \
            "$code" "$exit_code" ".apr/out.md")
        local got_ok
        got_ok=$(jq -r '.outcome.ok' <<<"$json")
        [[ "$got_ok" == "$want" ]] || {
            echo "($state, $code) → outcome.ok want=$want got=$got_ok" >&2
            jq '.outcome' <<<"$json" >&2
            return 1
        }
    done
}

# ===========================================================================
# I7 — build_finished is byte-deterministic for the same inputs
# ===========================================================================

@test "I7: build_finished is byte-deterministic across repeated calls" {
    local first second i
    for i in 1 2 3; do
        local json
        json=$(apr_lib_ledger_build_finished \
            "wf" 1 "slug-x" "run-deterministic" \
            "2026-01-01T00:00:00Z" "2026-01-01T00:00:30Z" \
            "finished" \
            '[{"path":"README.md","bytes":42,"sha256":"abc","inclusion_reason":"required"}]' \
            "sha256-prompt-determinism" "browser" "5.2 Thinking" \
            "ok" 0 ".apr/rounds/wf/round_1.md")
        if [[ "$i" -eq 1 ]]; then
            first="$json"
        else
            [[ "$json" == "$first" ]] || {
                echo "non-determinism on run $i:" >&2
                diff <(printf '%s' "$first") <(printf '%s' "$json") >&2
                return 1
            }
        fi
    done
}

# ===========================================================================
# I8 — adversarial inputs produce valid JSON
# ===========================================================================

@test "I8: adversarial slug/run_id/prompt_hash (JSON specials, control bytes) still produce valid JSON" {
    local adversarial=(
        $'with "quote"'
        $'with \\ backslash'
        $'with\nnewline'
        $'with\ttab'
        "with \"both\" and \\backslash"
    )
    local s
    for s in "${adversarial[@]}"; do
        local json
        json=$(apr_lib_ledger_build_started \
            "wf" 1 "$s" "$s" "2026-01-01T00:00:00Z" \
            '[]' "$s" "browser" "5.2 Thinking")
        jq -e . <<<"$json" >/dev/null || {
            echo "non-JSON output for adversarial input '$(printf '%q' "$s")':" >&2
            echo "$json" >&2
            return 1
        }
    done
}

@test "I8: 4KB+ slug/run_id values still produce parseable JSON" {
    local big
    big=$(printf 'x%.0s' $(seq 1 4096))
    local json
    json=$(apr_lib_ledger_build_started \
        "wf" 1 "$big" "$big" "2026-01-01T00:00:00Z" \
        '[]' "sha256-x" "browser" "5.2 Thinking")
    jq -e . <<<"$json" >/dev/null
    # The big string round-trips through jq.
    local got_slug
    got_slug=$(jq -r '.slug' <<<"$json")
    [[ "$got_slug" == "$big" ]]
}

# ===========================================================================
# I9 — write_start + write_finish lifecycle composition
# ===========================================================================

@test "I9: write_start → write_finish lifecycle produces a finished JSON with all original + outcome fields" {
    local p="$FIXTURE_ROOT/lifecycle.json"
    local started
    started=$(apr_lib_ledger_build_started \
        "default" 1 "slug-life" "run-life" "2026-01-01T00:00:00Z" \
        '[]' "sha256-life" "browser" "5.2 Thinking")
    apr_lib_ledger_write_start "$p" "$started"

    # Sanity: started state on disk.
    jq -e '.state == "started"' "$p" >/dev/null

    local finished
    finished=$(apr_lib_ledger_build_finished \
        "default" 1 "slug-life" "run-life" \
        "2026-01-01T00:00:00Z" "2026-01-01T00:00:30Z" \
        "finished" '[]' "sha256-life" "browser" "5.2 Thinking" \
        "ok" 0 ".apr/out.md")
    apr_lib_ledger_write_finish "$p" "$finished"

    # Finished state must preserve the started fields AND have an
    # outcome.ok==true.
    jq -e '.state == "finished"'                  "$p" >/dev/null
    jq -e '.workflow == "default"'                "$p" >/dev/null
    jq -e '.round == 1'                           "$p" >/dev/null
    jq -e '.slug == "slug-life"'                  "$p" >/dev/null
    jq -e '.run_id == "run-life"'                 "$p" >/dev/null
    jq -e '.prompt_hash == "sha256-life"'         "$p" >/dev/null
    jq -e '.outcome.ok == true'                   "$p" >/dev/null
    jq -e '.outcome.code == "ok"'                 "$p" >/dev/null
    jq -e '.outcome.exit_code == 0'               "$p" >/dev/null
    jq -e '.outcome.output_path == ".apr/out.md"' "$p" >/dev/null
    jq -e '.duration_ms == 30000'                 "$p" >/dev/null
    jq -e '.finished_at == "2026-01-01T00:00:30Z"' "$p" >/dev/null
}

# ===========================================================================
# I10 — Rapid sequential writes leave a final state equal to one of them
# ===========================================================================

@test "I10: 5 rapid sequential atomic_writes to the same path leave a coherent final state" {
    local p="$FIXTURE_ROOT/concurrency_proxy.json"
    local i out final
    local -a contents=()

    for i in 1 2 3 4 5; do
        local payload
        payload="$(printf '{"state":"%s","run":%d}' "iter_$i" "$i")"
        contents+=("$payload")
        apr_lib_ledger_atomic_write "$p" "$payload"
    done

    final=$(cat "$p")
    # The final must equal exactly one of the writes (modulo redaction,
    # but these inputs have no secrets).
    local match=0
    local c
    for c in "${contents[@]}"; do
        if [[ "$final" == "$c" ]]; then
            match=1
            break
        fi
    done
    [[ "$match" -eq 1 ]] || {
        echo "final state did not equal any of the 5 writes:" >&2
        echo "  final:  $final" >&2
        printf '  wrote:  %s\n' "${contents[@]}" >&2
        return 1
    }

    # And there should be no stragglers.
    local stragglers
    stragglers=$(find "$FIXTURE_ROOT" -maxdepth 1 -name 'concurrency_proxy.json.tmp.*' 2>/dev/null | wc -l)
    [[ "$stragglers" -eq 0 ]]
}

# ===========================================================================
# Cross-property: redact + atomic_write composition
# ===========================================================================

@test "compose: atomic_write transparently applies redaction to all secret classes" {
    local p="$FIXTURE_ROOT/redacted_write.json"
    local content='{"Authorization":"Bearer abc.def.ghi","key":"sk-abcdefghijklmnopqrstuvwxyz12","pat":"ghp_aaaaaaaaaaaaaaaaaaaaa","args":"--token deadbeef --api-key=sk-abc password=hunter2"}'
    apr_lib_ledger_atomic_write "$p" "$content"

    # No raw secrets in the persisted file.
    [[ "$(cat "$p")" != *"Bearer abc.def.ghi"* ]]
    [[ "$(cat "$p")" != *"sk-abcdefghijklmnopqrstuvwxyz12"* ]]
    [[ "$(cat "$p")" != *"ghp_aaaaaaaaaaaaaaaaaaaaa"* ]]
    [[ "$(cat "$p")" != *"deadbeef"* ]]
    [[ "$(cat "$p")" != *"hunter2"* ]]

    # And the redaction sentinels are present.
    grep -Fq '<REDACTED>' "$p"
}
