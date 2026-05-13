#!/usr/bin/env bash
# lib/ack.sh - APR ACK policy primitives (bd-34z)
#
# ACK is a small "echo back what you read" block the model is asked to
# emit at the start of its response. When ACK is enabled, the prompt
# (built by bd-3i5's manifest preamble + bd-btu's expansion) is
# instructed to begin with lines like:
#
#   ACK
#   - README.md sha256=<hex> bytes=<n>
#   - SPEC.md   sha256=<hex> bytes=<n>
#   - IMPL.md   sha256=<hex> bytes=<n>      # only if included
#   END_ACK
#
# After the run, the model's output is parsed for the block. The
# parsed entries are compared to the manifest to produce three trust
# signals:
#
#   ack_present          (boolean)
#   ack_complete         (every required entry present)
#   ack_matches_manifest (sha256 + bytes match the recorded manifest)
#
# bd-34z's apr-side wiring (prompt injection at render time, metrics
# emission, --strict-ack flag) is a follow-on. This module is the
# primitives: render the instruction text, parse a block from arbitrary
# output, validate against a manifest, and emit a structured trust
# signal that downstream code (apr stats / dashboard / ledger) can
# consume directly.
#
# Public API
# ----------
#   apr_lib_ack_render_instruction <triples...>
#       Render the ACK block instruction (as it appears in the prompt)
#       for a workflow's documents. Triples are "<basename>|<sha256>|<bytes>".
#       Stable LC_ALL=C sort by basename so the output is byte-deterministic.
#
#   apr_lib_ack_parse <model_output>
#       Find the first `ACK ... END_ACK` block and emit one JSON line
#       per entry on stdout:
#           {"basename":"README.md","sha256":"<hex>","bytes":<n>}
#       Tolerates extra whitespace and case variations on ACK / END_ACK.
#       Returns 0 if a block was found (even if empty), 1 if not.
#
#   apr_lib_ack_validate <model_output> <expected_triples...>
#       Compose the three signals and emit a compact JSON object:
#           {"ack_present": true/false,
#            "ack_complete": true/false,
#            "ack_matches_manifest": true/false,
#            "missing": [basename, ...],
#            "mismatched": [{basename, expected_sha, actual_sha, ...}, ...]}
#       Returns 0 if all three signals are positive, 1 otherwise.

if [[ "${_APR_LIB_ACK_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_ACK_LOADED=1

_APR_LIB_ACK_DIR_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_ACK_DIR_SELF/manifest.sh"

# -----------------------------------------------------------------------------
# apr_lib_ack_render_instruction <triple...>
#
# Each triple: "basename|sha256|bytes". Empty triples skipped.
# -----------------------------------------------------------------------------
apr_lib_ack_render_instruction() {
    local -a triples=("$@")
    if [[ ${#triples[@]} -eq 0 ]]; then
        return 0
    fi
    local sorted
    sorted=$(printf '%s\n' "${triples[@]}" | LC_ALL=C sort -t '|' -k1,1)
    printf 'Begin your response with the following ACK block, copied verbatim except for filling in the hashes/bytes (which must match exactly):\n\n'
    printf 'ACK\n'
    local bn sha bytes
    while IFS='|' read -r bn sha bytes; do
        [[ -z "$bn" ]] && continue
        printf -- '- %s sha256=%s bytes=%s\n' "$bn" "$sha" "$bytes"
    done <<< "$sorted"
    printf 'END_ACK\n\n'
    printf 'Then continue with your normal review. Do not omit the ACK block.\n'
}

# -----------------------------------------------------------------------------
# apr_lib_ack_parse <model_output>
#
# Extract the first ACK block. Tolerant matching:
#   - case-insensitive ACK / END_ACK markers
#   - leading whitespace on markers
#   - leading `-` or `*` bullet (or no bullet)
#   - extra spaces in `sha256=...` / `bytes=...`
#
# Returns 0 if a block was found, 1 otherwise. On found, emits one JSON
# object per entry on stdout (newline-delimited; callers can join into
# an array).
# -----------------------------------------------------------------------------
apr_lib_ack_parse() {
    local text="${1-}"
    if [[ -z "$text" ]]; then
        return 1
    fi
    local in_block=0
    local found=0
    local line
    while IFS= read -r line; do
        # Strip CR if present (Windows-style line endings).
        line="${line%$'\r'}"
        if [[ $in_block -eq 0 ]]; then
            # Look for opening ACK marker (case-insensitive).
            if [[ "$line" =~ ^[[:space:]]*[Aa][Cc][Kk][[:space:]]*$ ]]; then
                in_block=1
                found=1
            fi
            continue
        fi
        # In block: look for END_ACK or a parsable entry.
        if [[ "$line" =~ ^[[:space:]]*[Ee][Nn][Dd][_-]?[Aa][Cc][Kk][[:space:]]*$ ]]; then
            in_block=0
            break
        fi
        # Try to parse an entry. Accept optional `-` or `*` bullet,
        # then a basename, then `sha256=<hex>` and `bytes=<n>` in any
        # order with arbitrary whitespace.
        local cleaned
        cleaned=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*]?[[:space:]]*//')
        # Basename is the first whitespace-delimited token.
        local basename rest
        basename="${cleaned%%[[:space:]]*}"
        rest="${cleaned#*[[:space:]]}"
        [[ "$basename" == "$rest" ]] && rest=""
        if [[ -z "$basename" ]] || [[ "$basename" == "$cleaned" && -z "$rest" ]]; then
            continue
        fi
        # Pull sha256= and bytes= from anywhere in `rest`.
        local sha=""
        if [[ "$rest" =~ sha256[[:space:]]*=[[:space:]]*([0-9a-fA-F]{64}) ]]; then
            sha="${BASH_REMATCH[1]}"
            sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
        fi
        local bytes=""
        if [[ "$rest" =~ bytes[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
            bytes="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$sha" && -z "$bytes" ]]; then
            continue
        fi
        local bn_esc
        bn_esc=$(apr_lib_manifest_json_escape "$basename")
        if [[ -n "$sha" && -n "$bytes" ]]; then
            printf '{"basename":"%s","sha256":"%s","bytes":%s}\n' "$bn_esc" "$sha" "$bytes"
        elif [[ -n "$sha" ]]; then
            printf '{"basename":"%s","sha256":"%s","bytes":null}\n' "$bn_esc" "$sha"
        else
            printf '{"basename":"%s","sha256":null,"bytes":%s}\n' "$bn_esc" "$bytes"
        fi
    done <<< "$text"
    [[ $found -eq 1 ]] && return 0
    return 1
}

# -----------------------------------------------------------------------------
# apr_lib_ack_validate <model_output> <expected_triples...>
#
# Compose the three trust signals + per-entry diff data.
# Triples: "<basename>|<sha256>|<bytes>". Empty triples skipped.
#
# Emits a single compact JSON object on stdout. Returns 0 iff all three
# signals are true, 1 otherwise.
# -----------------------------------------------------------------------------
apr_lib_ack_validate() {
    local text="${1-}"
    shift
    local -a triples=("$@")

    local ack_present="false"
    local ack_complete="false"
    local ack_matches="false"
    local -a missing=()
    local -a mismatched=()
    local -a unexpected=()

    # Parse the ACK block.
    local parsed
    if parsed=$(apr_lib_ack_parse "$text" 2>/dev/null); then
        ack_present="true"
    fi

    # Build associative arrays of expected vs actual.
    declare -A exp_sha=() exp_bytes=()
    declare -A act_sha=() act_bytes=()
    local t bn sha bytes
    for t in "${triples[@]}"; do
        [[ -z "$t" ]] && continue
        IFS='|' read -r bn sha bytes <<< "$t"
        [[ -z "$bn" ]] && continue
        exp_sha[$bn]="$sha"
        exp_bytes[$bn]="$bytes"
    done
    if [[ -n "$parsed" ]]; then
        local line a_bn a_sha a_bytes
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            a_bn=$(printf '%s' "$line" | sed -E 's/.*"basename":"([^"]*)".*/\1/')
            a_sha=$(printf '%s' "$line" | sed -E 's/.*"sha256":(null|"[0-9a-f]+").*/\1/' | tr -d '"')
            a_bytes=$(printf '%s' "$line" | sed -E 's/.*"bytes":(null|[0-9]+).*/\1/')
            [[ "$a_sha"   == "null" ]] && a_sha=""
            [[ "$a_bytes" == "null" ]] && a_bytes=""
            act_sha[$a_bn]="$a_sha"
            act_bytes[$a_bn]="$a_bytes"
        done <<< "$parsed"
    fi

    # Determine completeness + match.
    local all_present=1
    local all_match=1
    local ebn
    if [[ -n "${exp_sha[*]+set}" ]]; then
        for ebn in "${!exp_sha[@]}"; do
            if [[ -z "${act_sha[$ebn]+set}" ]]; then
                all_present=0
                all_match=0
                missing+=("$ebn")
                continue
            fi
            local e_sha="${exp_sha[$ebn]}"
            local a_sha="${act_sha[$ebn]}"
            local e_bytes="${exp_bytes[$ebn]}"
            local a_bytes="${act_bytes[$ebn]}"
            if [[ "$e_sha" != "$a_sha" ]] || [[ "$e_bytes" != "$a_bytes" ]]; then
                all_match=0
                local mm
                mm=$(printf '{"basename":"%s","expected_sha":"%s","actual_sha":"%s","expected_bytes":%s,"actual_bytes":%s}' \
                    "$(apr_lib_manifest_json_escape "$ebn")" \
                    "$(apr_lib_manifest_json_escape "$e_sha")" \
                    "$(apr_lib_manifest_json_escape "$a_sha")" \
                    "${e_bytes:-null}" \
                    "${a_bytes:-null}")
                mismatched+=("$mm")
            fi
        done
    fi
    # bd-kk7n MR4: detect "unexpected" entries — basenames in the ACK
    # block that aren't in the expected set. Over-supply doesn't break
    # completeness (the model echoing extra files is harmless), but it's
    # a useful signal for orchestrators.
    if [[ -n "${act_sha[*]+set}" ]]; then
        local abn
        for abn in "${!act_sha[@]}"; do
            if [[ -z "${exp_sha[$abn]+set}" ]]; then
                unexpected+=("$abn")
            fi
        done
    fi

    if [[ "$ack_present" == "true" ]] && [[ $all_present -eq 1 ]]; then
        ack_complete="true"
    fi
    if [[ "$ack_present" == "true" ]] && [[ $all_present -eq 1 ]] && [[ $all_match -eq 1 ]]; then
        ack_matches="true"
    fi

    # Serialize missing[] + mismatched[] + unexpected[].
    local missing_json="[]"
    if [[ ${#missing[@]} -gt 0 ]]; then
        local mb first=1
        missing_json="["
        for mb in "${missing[@]}"; do
            if [[ $first -eq 0 ]]; then missing_json+=","; fi
            first=0
            missing_json+="\"$(apr_lib_manifest_json_escape "$mb")\""
        done
        missing_json+="]"
    fi
    local mismatched_json="[]"
    if [[ ${#mismatched[@]} -gt 0 ]]; then
        local mm first=1
        mismatched_json="["
        for mm in "${mismatched[@]}"; do
            if [[ $first -eq 0 ]]; then mismatched_json+=","; fi
            first=0
            mismatched_json+="$mm"
        done
        mismatched_json+="]"
    fi
    local unexpected_json="[]"
    if [[ ${#unexpected[@]} -gt 0 ]]; then
        # Stable sort for byte-deterministic output.
        local sorted_unexpected
        sorted_unexpected=$(printf '%s\n' "${unexpected[@]}" | LC_ALL=C sort)
        local ub first=1
        unexpected_json="["
        while IFS= read -r ub; do
            [[ -z "$ub" ]] && continue
            if [[ $first -eq 0 ]]; then unexpected_json+=","; fi
            first=0
            unexpected_json+="\"$(apr_lib_manifest_json_escape "$ub")\""
        done <<< "$sorted_unexpected"
        unexpected_json+="]"
    fi

    printf '{"ack_present":%s,"ack_complete":%s,"ack_matches_manifest":%s,"missing":%s,"mismatched":%s,"unexpected":%s}' \
        "$ack_present" "$ack_complete" "$ack_matches" "$missing_json" "$mismatched_json" "$unexpected_json"

    if [[ "$ack_matches" == "true" ]]; then
        return 0
    fi
    return 1
}
