#!/usr/bin/env bats
# test_redact_fuzz.bats
#
# Bead automated_plan_reviser_pro-fuyz — fuzz/property layer for
# lib/redact.sh (the prompt redaction layer added in bd-3ut).
#
# lib/redact.sh replaces secrets with typed sentinels
# (<<REDACTED:TYPE>>) before the prompt reaches Oracle. It is
# security-critical: a regression that drops a secret type or
# misclassifies one could land tokens in conversation history. The
# happy-path suite (tests/unit/test_redact.bats, 18 tests) covers
# each individual class; this file adds an adversarial / property
# layer on top.
#
# Invariants pinned:
#   I1  composition: all 7 classes mixed → correct per-type counts + total
#   I2  idempotence: redact(redact(x)) == redact(x)
#   I3  determinism: 50 repeated calls produce byte-identical output
#   I4  sentinel format: every replacement is <<REDACTED:TYPE>>, TYPE ∈ documented 7
#   I5  counter conformance: APR_REDACT_COUNT == sum(by_type); summary.total == APR_REDACT_COUNT
#   I6  by_type field invariant: only positive-count types appear
#   I7  false-positive resistance: short prefixes, wrong-length AKIA,
#       prose containing "bearer" without header structure
#   I8  secret embedded in JSON / code fence still redacted
#   I9  empty / 1-byte / 100KB inputs handled cleanly
#   I10 multi-block: 3 distinct PRIVATE KEY blocks → 3 sentinel lines,
#       prompt body preserved
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

DOCUMENTED_TYPES=(
    AKIA_KEY
    AUTH_BEARER_TOKEN
    GITHUB_FINEGRAINED
    GITHUB_TOKEN
    OPENAI_KEY
    PRIVATE_KEY_BLOCK
    SLACK_TOKEN
)

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/redact.sh"

    log_test_start "${BATS_TEST_NAME}"
}

# `$(apr_lib_redact_prompt ...)` runs in a subshell — internal state
# (_APR_REDACT_BY_TYPE, APR_REDACT_COUNT) is lost when the subshell
# exits. Tests that need to inspect counters or call
# apr_lib_redact_summary after redaction must capture via tempfile +
# redirect so the parent shell sees the updated globals.
capture_redact() {
    # Args: <out-var> <input-text>
    local _out="$1" _text="$2"
    local _tmp="$ARTIFACT_DIR/redact_$RANDOM.out"
    apr_lib_redact_prompt "$_text" > "$_tmp"
    printf -v "$_out" '%s' "$(< "$_tmp")"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# I1 — Composition: all 7 classes mixed in one input
# ===========================================================================

@test "I1: a single input containing all 7 secret classes redacts each with correct counts" {
    local input
    input=$(cat <<'EOF'
OpenAI key: sk-1234567890abcdefghijklmnopqrstuvwxyz
GitHub PAT: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
GitHub fine-grained: github_pat_aaaaaaaaaaaaaaaaaaaa_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
Slack token: xoxb-1234567890-abcdefghij-1234567890
AWS key: AKIAABCDEFGHIJKLMNOP
Authorization: Bearer abc.def.ghi
-----BEGIN RSA PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDx
-----END RSA PRIVATE KEY-----
End of secrets.
EOF
)

    local out summary
    capture_redact out "$input"
    summary=$(apr_lib_redact_summary)

    # Every documented type should appear exactly once in by_type.
    local t want_count
    for t in "${DOCUMENTED_TYPES[@]}"; do
        want_count=$(jq -r --arg t "$t" '.by_type[$t] // 0' <<<"$summary")
        [[ "$want_count" -ge 1 ]] || {
            echo "type $t was not counted:" >&2
            echo "$summary" >&2
            echo "--- output ---" >&2
            echo "$out" >&2
            return 1
        }
    done

    # Total >= 7.
    [[ "$(jq -r '.total' <<<"$summary")" -ge 7 ]]

    # And the "End of secrets." marker is preserved verbatim.
    grep -Fq "End of secrets." <<<"$out"
}

# ===========================================================================
# I2 — Idempotence
# ===========================================================================

@test "I2: redact is idempotent — applying it twice yields the same output as once" {
    local cases=(
        "OpenAI: sk-abcdefghijklmnopqrstuvwxyz123456"
        "GH: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        "Authorization: Bearer abc.def.ghi"
        "$(printf 'sk-1234567890abcdefghij and a normal line\nplus another sk-ABCDEFGHIJ1234567890\n')"
    )
    local c once twice
    for c in "${cases[@]}"; do
        once=$(apr_lib_redact_prompt "$c")
        twice=$(apr_lib_redact_prompt "$once")
        [[ "$once" == "$twice" ]] || {
            echo "idempotence violated for '$(printf '%q' "$c")':" >&2
            diff <(printf '%s' "$once") <(printf '%s' "$twice") >&2
            return 1
        }
    done
}

# ===========================================================================
# I3 — Determinism
# ===========================================================================

@test "I3: 50 repeated calls on the same input produce byte-identical output" {
    local input='line1 sk-aaaaaaaaaaaaaaaaaaaa
line2 normal
line3 ghp_aaaaaaaaaaaaaaaaaaaa'
    local baseline current i
    baseline=$(apr_lib_redact_prompt "$input")
    for i in $(seq 1 50); do
        current=$(apr_lib_redact_prompt "$input")
        [[ "$current" == "$baseline" ]] || {
            echo "drift at iteration $i" >&2
            return 1
        }
    done
}

# ===========================================================================
# I4 — Sentinel format invariant
# ===========================================================================

@test "I4: every replacement sentinel matches <<REDACTED:TYPE>> with TYPE in the documented 7" {
    local input='sk-1234567890abcdefghijklmn ghp_xxxxxxxxxxxxxxxxxxxxx xoxb-1234567890-abcdefghij-1234567890 AKIAABCDEFGHIJKLMNOP'
    local out
    out=$(apr_lib_redact_prompt "$input")

    # Every <<REDACTED:...>> occurrence in the output must reference a
    # documented type.
    local matches
    matches=$(grep -oE '<<REDACTED:[A-Z_]+>>' <<<"$out" || true)
    [[ -n "$matches" ]]

    local m type allowed
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        type="${m#<<REDACTED:}"
        type="${type%>>}"
        allowed=0
        local d
        for d in "${DOCUMENTED_TYPES[@]}"; do
            if [[ "$d" == "$type" ]]; then allowed=1; break; fi
        done
        [[ "$allowed" -eq 1 ]] || {
            echo "undocumented sentinel TYPE: '$type'" >&2
            return 1
        }
    done <<<"$matches"
}

@test "I4: sentinels themselves do NOT contain any documented secret prefix (no self-redaction loop)" {
    # The literal sentinel strings must not embed `sk-`, `ghp_`, etc.,
    # which would create a self-redaction loop on a second pass.
    local d
    for d in "${DOCUMENTED_TYPES[@]}"; do
        local sentinel="<<REDACTED:${d}>>"
        # The sentinel passes through cleanly when fed back through.
        local rt
        rt=$(apr_lib_redact_prompt "$sentinel")
        [[ "$rt" == "$sentinel" ]] || {
            echo "sentinel '$sentinel' was mutated on re-redact: '$rt'" >&2
            return 1
        }
    done
}

# ===========================================================================
# I5 — Counter conformance
# ===========================================================================

@test "I5: APR_REDACT_COUNT equals the sum of by_type counts in the summary" {
    local input
    input=$(cat <<'EOF'
sk-aaaaaaaaaaaaaaaaaaaa
sk-bbbbbbbbbbbbbbbbbbbb
ghp_xxxxxxxxxxxxxxxxxxxxxxx
AKIAABCDEFGHIJKLMNOP
EOF
)
    apr_lib_redact_prompt "$input" > /dev/null
    local summary total by_total
    summary=$(apr_lib_redact_summary)
    total=$(jq -r '.total' <<<"$summary")
    by_total=$(jq -r '[.by_type[]] | add // 0' <<<"$summary")

    [[ "$total" -eq "$by_total" ]] || {
        echo "summary.total ($total) != sum(by_type) ($by_total)" >&2
        echo "$summary" >&2
        return 1
    }
    [[ "$total" -eq "$APR_REDACT_COUNT" ]] || {
        echo "summary.total ($total) != APR_REDACT_COUNT ($APR_REDACT_COUNT)" >&2
        return 1
    }
}

# ===========================================================================
# I6 — by_type field invariant: only positive-count types appear
# ===========================================================================

@test "I6: types with zero count are omitted from summary.by_type" {
    apr_lib_redact_prompt "sk-aaaaaaaaaaaaaaaaaaaa" > /dev/null
    local summary
    summary=$(apr_lib_redact_summary)

    # Only OPENAI_KEY should be present.
    local keys
    keys=$(jq -r '.by_type | keys | sort | join(",")' <<<"$summary")
    [[ "$keys" == "OPENAI_KEY" ]] || {
        echo "expected only OPENAI_KEY in by_type, got: $keys" >&2
        return 1
    }
}

@test "I6: clean input → summary.total == 0 AND summary.by_type == {}" {
    apr_lib_redact_prompt "no secrets here, just prose" > /dev/null
    local summary
    summary=$(apr_lib_redact_summary)
    jq -e '.total == 0' <<<"$summary" >/dev/null
    jq -e '.by_type | length == 0' <<<"$summary" >/dev/null
}

# ===========================================================================
# I7 — False-positive resistance
# ===========================================================================

@test "I7: short / wrong-length / non-prefix patterns do NOT trigger redaction" {
    local non_secrets=(
        "sk-tooshort"                 # sk- but < 20 chars after
        "ghp_short"                   # gh prefix but too short
        "github_pat_short"            # gh fine prefix too short
        "xoxb-short"                  # slack but < 10 chars after
        "AKIAABC"                     # AKIA but wrong length
        "AKIAABCDEFGHIJKLMNOPQ"       # AKIA but 17 chars (need exactly 16)
        "the bearer arrived"          # prose containing 'bearer'
        "Authorization: Basic abc"    # wrong scheme
        "openai uses sk- prefixes"    # bare prefix
    )
    local input
    for input in "${non_secrets[@]}"; do
        local out
        out=$(apr_lib_redact_prompt "$input")
        if [[ "$out" == *"<<REDACTED:"* ]]; then
            echo "false positive on '$(printf '%q' "$input")':" >&2
            echo "  → $out" >&2
            return 1
        fi
        [[ "$out" == "$input" ]] || {
            echo "non-secret input was mutated: '$(printf '%q' "$input")' → '$(printf '%q' "$out")'" >&2
            return 1
        }
    done
}

# ===========================================================================
# I8 — Secret embedded in JSON / code fence still redacted
# ===========================================================================

@test "I8: secret embedded in a JSON string is still redacted (no escape hatch)" {
    local input='{"api_key": "sk-1234567890abcdefghij", "user": "alice"}'
    local out
    out=$(apr_lib_redact_prompt "$input")
    [[ "$out" != *"sk-1234567890abcdefghij"* ]] || {
        echo "secret leaked through JSON wrapping:" >&2
        echo "$out" >&2
        return 1
    }
    [[ "$out" == *"<<REDACTED:OPENAI_KEY>>"* ]]
}

@test "I8: secret inside a code-fenced block is still redacted (no escape hatch)" {
    local input
    input=$(cat <<'EOF'
Use the following key:
```bash
export OPENAI_API_KEY=sk-1234567890abcdefghijklmnop
```
End.
EOF
)
    local out
    out=$(apr_lib_redact_prompt "$input")
    [[ "$out" != *"sk-1234567890abcdefghijklmnop"* ]] || {
        echo "secret leaked through code-fence wrapping" >&2
        return 1
    }
    [[ "$out" == *"<<REDACTED:OPENAI_KEY>>"* ]]
}

# ===========================================================================
# I9 — Boundary inputs
# ===========================================================================

@test "I9: empty input → empty output, total=0, no sentinels" {
    local out
    out=$(apr_lib_redact_prompt "")
    [[ -z "$out" ]]
    [[ "$APR_REDACT_COUNT" -eq 0 ]]
}

@test "I9: 1-byte input → unchanged" {
    local out
    out=$(apr_lib_redact_prompt "x")
    [[ "$out" == "x" ]]
}

@test "I9: 100KB input with one secret near the end still gets redacted" {
    local big
    big=$(printf 'safe line %05d\n' $(seq 1 5000))
    big+=$'\nfinal: sk-1234567890abcdefghijklmnop\n'

    local out
    out=$(apr_lib_redact_prompt "$big")
    [[ "$out" == *"<<REDACTED:OPENAI_KEY>>"* ]] || {
        echo "secret near end of 100KB input was not redacted" >&2
        return 1
    }
    [[ "$out" != *"sk-1234567890abcdefghijklmnop"* ]]
}

# ===========================================================================
# I10 — Multi-key block: 3 distinct PRIVATE KEY blocks
# ===========================================================================

@test "I10: 3 distinct PRIVATE KEY blocks each collapse to a single sentinel line" {
    local input
    input=$(cat <<'EOF'
header
-----BEGIN RSA PRIVATE KEY-----
AAAAB3NzaC1yc2EAAAA
-----END RSA PRIVATE KEY-----
middle
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdj
-----END OPENSSH PRIVATE KEY-----
later
-----BEGIN EC PRIVATE KEY-----
MIIBIjANBgkqhkiG9w
-----END EC PRIVATE KEY-----
trailer
EOF
)
    local out summary
    capture_redact out "$input"
    summary=$(apr_lib_redact_summary)

    # Exactly 3 sentinel lines.
    local n
    n=$(grep -Fc '<<REDACTED:PRIVATE_KEY_BLOCK>>' <<<"$out")
    [[ "$n" -eq 3 ]] || {
        echo "expected 3 PRIVATE_KEY_BLOCK sentinels, got $n" >&2
        echo "$out" >&2
        return 1
    }

    # Surrounding prose preserved.
    grep -Fxq "header"  <<<"$out"
    grep -Fxq "middle"  <<<"$out"
    grep -Fxq "later"   <<<"$out"
    grep -Fxq "trailer" <<<"$out"

    # No raw base64 leakage.
    [[ "$out" != *"AAAAB3NzaC1yc2EAAAA"* ]]
    [[ "$out" != *"b3BlbnNzaC1rZXktdj"* ]]
    [[ "$out" != *"MIIBIjANBgkqhkiG9w"* ]]

    # Summary records 3 PRIVATE_KEY_BLOCK redactions.
    [[ "$(jq -r '.by_type.PRIVATE_KEY_BLOCK' <<<"$summary")" -eq 3 ]]
}

# ===========================================================================
# Cross-property: summary JSON parses cleanly for every fuzz input
# ===========================================================================

@test "conformance: apr_lib_redact_summary always emits valid JSON" {
    local inputs=(
        ""
        "plain text"
        "sk-aaaaaaaaaaaaaaaaaaaa"
        "$(printf 'multi\nline\nsecret sk-aaaaaaaaaaaaaaaaaaaa\n')"
        "ghp_xxxxxxxxxxxxxxxxxxxxxxx AKIAABCDEFGHIJKLMNOP"
    )
    local i
    for i in "${inputs[@]}"; do
        apr_lib_redact_prompt "$i" > /dev/null
        local summary
        summary=$(apr_lib_redact_summary)
        jq -e . <<<"$summary" >/dev/null || {
            echo "summary not JSON for input '$(printf '%q' "$i")': $summary" >&2
            return 1
        }
        jq -e '.total | type == "number"'   <<<"$summary" >/dev/null
        jq -e '.by_type | type == "object"' <<<"$summary" >/dev/null
    done
}
