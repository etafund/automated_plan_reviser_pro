#!/usr/bin/env bash
# lib/validate.sh - APR validation core (bd-30c)
#
# Provides the reusable primitives for APR's validation pipeline so that
# `apr lint`, `apr run`, `apr robot validate`, `apr robot run`, and queue
# gating all share the same finding model and the same per-misconfiguration
# `code`. The wiring beads (bd-35i, bd-9fl, bd-vlq, bd-1eq, bd-1aw) layer on
# top of this module and call the small composable validators here.
#
# Finding model
# -------------
# Findings are objects with the shape recorded in the run ledger
# (docs/schemas/run-ledger.schema.json, `warnings[]`):
#
#   { code, message, hint, source, details }
#
# `code` is a stable taxonomy string aligned with bd-3tj (e.g. `config_error`,
# `validation_failed`). `source` is best-effort location (`file:line` when
# known, just `file` otherwise). `details` is an optional JSON-string blob
# that callers may attach for machine consumers.
#
# Storage strategy
# ----------------
# Findings are kept in parallel global arrays (one slot per finding,
# indexed by position) rather than a single delimiter-joined string, so we
# never have to escape internal delimiters and emission is straightforward.
# Callers MUST call `apr_lib_validate_init` at the start of each validation
# pass to clear residue.
#
# Stream conventions
# ------------------
# This module is pure logic; it does not write to stdout/stderr on its own.
# Callers use the `emit_json` / `emit_human` helpers to render the
# accumulated findings.

# Guard against double-sourcing.
if [[ "${_APR_LIB_VALIDATE_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_VALIDATE_LOADED=1

_APR_LIB_VALIDATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_VALIDATE_DIR/manifest.sh"

# -----------------------------------------------------------------------------
# Finding storage (parallel arrays)
# -----------------------------------------------------------------------------

declare -a _APR_VALIDATE_ERR_CODE=()
declare -a _APR_VALIDATE_ERR_MSG=()
declare -a _APR_VALIDATE_ERR_HINT=()
declare -a _APR_VALIDATE_ERR_SOURCE=()
declare -a _APR_VALIDATE_ERR_DETAILS=()

declare -a _APR_VALIDATE_WARN_CODE=()
declare -a _APR_VALIDATE_WARN_MSG=()
declare -a _APR_VALIDATE_WARN_HINT=()
declare -a _APR_VALIDATE_WARN_SOURCE=()
declare -a _APR_VALIDATE_WARN_DETAILS=()

# -----------------------------------------------------------------------------
# apr_lib_validate_init
#
# Reset all finding buffers. Call this once per validation pass before
# any add_error/add_warning calls.
# -----------------------------------------------------------------------------
apr_lib_validate_init() {
    _APR_VALIDATE_ERR_CODE=()
    _APR_VALIDATE_ERR_MSG=()
    _APR_VALIDATE_ERR_HINT=()
    _APR_VALIDATE_ERR_SOURCE=()
    _APR_VALIDATE_ERR_DETAILS=()

    _APR_VALIDATE_WARN_CODE=()
    _APR_VALIDATE_WARN_MSG=()
    _APR_VALIDATE_WARN_HINT=()
    _APR_VALIDATE_WARN_SOURCE=()
    _APR_VALIDATE_WARN_DETAILS=()
}

# -----------------------------------------------------------------------------
# apr_lib_validate_add_error <code> <message> [<hint>] [<source>] [<details_json>]
# apr_lib_validate_add_warning <code> <message> [<hint>] [<source>] [<details_json>]
#
# Append a finding to the appropriate bucket. <details_json> should be a
# pre-serialized JSON value (object or string); pass `null` (or omit) when
# there are no details to record. No escaping is done on details — callers
# are responsible for emitting valid JSON.
# -----------------------------------------------------------------------------
apr_lib_validate_add_error() {
    _APR_VALIDATE_ERR_CODE+=("${1:?code required}")
    _APR_VALIDATE_ERR_MSG+=("${2:-}")
    _APR_VALIDATE_ERR_HINT+=("${3:-}")
    _APR_VALIDATE_ERR_SOURCE+=("${4:-}")
    _APR_VALIDATE_ERR_DETAILS+=("${5:-null}")
}

apr_lib_validate_add_warning() {
    _APR_VALIDATE_WARN_CODE+=("${1:?code required}")
    _APR_VALIDATE_WARN_MSG+=("${2:-}")
    _APR_VALIDATE_WARN_HINT+=("${3:-}")
    _APR_VALIDATE_WARN_SOURCE+=("${4:-}")
    _APR_VALIDATE_WARN_DETAILS+=("${5:-null}")
}

# -----------------------------------------------------------------------------
# apr_lib_validate_error_count
# apr_lib_validate_warning_count
#
# Echo the number of accumulated findings.
# -----------------------------------------------------------------------------
apr_lib_validate_error_count() {
    # Guarded expansion: `${arr[@]+x}` is the bash-portable way to ask
    # "is this array bound?" under `set -u`. An empty `_APR_VALIDATE_ERR_CODE`
    # may otherwise trigger "unbound variable" depending on bash version.
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]]; then
        printf '%s' "${#_APR_VALIDATE_ERR_CODE[@]}"
    else
        printf '0'
    fi
}
apr_lib_validate_warning_count() {
    if [[ -n "${_APR_VALIDATE_WARN_CODE[*]+set}" ]]; then
        printf '%s' "${#_APR_VALIDATE_WARN_CODE[@]}"
    else
        printf '0'
    fi
}

# -----------------------------------------------------------------------------
# apr_lib_validate_has_errors
#
# Return 0 iff at least one error has been recorded since the last init.
# -----------------------------------------------------------------------------
apr_lib_validate_has_errors() {
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]]; then
        [[ ${#_APR_VALIDATE_ERR_CODE[@]} -gt 0 ]]
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------
# apr_lib_validate_first_error_code
#
# Echo the `code` of the first recorded error, or empty if no errors. This
# is what the robot envelope's top-level `.code` should be when the
# validation pass fails (callers pick `validation_failed` for compound
# failures, but for a single-error pass the first code is the most useful).
# -----------------------------------------------------------------------------
apr_lib_validate_first_error_code() {
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]] && [[ ${#_APR_VALIDATE_ERR_CODE[@]} -gt 0 ]]; then
        printf '%s' "${_APR_VALIDATE_ERR_CODE[0]}"
    fi
}

# -----------------------------------------------------------------------------
# Internal: JSON-string-escape a single value.
# -----------------------------------------------------------------------------
_apr_validate_json_escape() {
    # Reuse the helper from manifest.sh (same rules: \\ \" \n \r \t).
    apr_lib_manifest_json_escape "${1-}"
}

# -----------------------------------------------------------------------------
# Internal: emit one finding as JSON object (no trailing newline/comma).
# -----------------------------------------------------------------------------
_apr_validate_finding_json() {
    local code="$1" msg="$2" hint="$3" source="$4" details="$5"
    local code_e msg_e hint_e source_e
    code_e=$(_apr_validate_json_escape "$code")
    msg_e=$(_apr_validate_json_escape "$msg")
    hint_e=$(_apr_validate_json_escape "$hint")
    source_e=$(_apr_validate_json_escape "$source")
    # Details is passed through as raw JSON; default to null.
    [[ -z "$details" ]] && details="null"
    printf '{"code":"%s","message":"%s","hint":"%s","source":"%s","details":%s}' \
        "$code_e" "$msg_e" "$hint_e" "$source_e" "$details"
}

# -----------------------------------------------------------------------------
# apr_lib_validate_emit_json
#
# Emit the accumulated findings as a compact JSON envelope:
#   {"errors":[{...},...], "warnings":[{...},...]}
# Stable key order; no trailing newline. The order of findings within each
# array is the insertion order.
# -----------------------------------------------------------------------------
apr_lib_validate_emit_json() {
    local i first
    printf '{"errors":['
    first=1
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_ERR_CODE[@]}"; do
            if [[ $first -eq 0 ]]; then printf ','; fi
            first=0
            _apr_validate_finding_json \
                "${_APR_VALIDATE_ERR_CODE[$i]}" \
                "${_APR_VALIDATE_ERR_MSG[$i]}" \
                "${_APR_VALIDATE_ERR_HINT[$i]}" \
                "${_APR_VALIDATE_ERR_SOURCE[$i]}" \
                "${_APR_VALIDATE_ERR_DETAILS[$i]}"
        done
    fi
    printf '],"warnings":['
    first=1
    if [[ -n "${_APR_VALIDATE_WARN_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_WARN_CODE[@]}"; do
            if [[ $first -eq 0 ]]; then printf ','; fi
            first=0
            _apr_validate_finding_json \
                "${_APR_VALIDATE_WARN_CODE[$i]}" \
                "${_APR_VALIDATE_WARN_MSG[$i]}" \
                "${_APR_VALIDATE_WARN_HINT[$i]}" \
                "${_APR_VALIDATE_WARN_SOURCE[$i]}" \
                "${_APR_VALIDATE_WARN_DETAILS[$i]}"
        done
    fi
    printf ']}'
}

# -----------------------------------------------------------------------------
# apr_lib_validate_emit_human
#
# Render accumulated findings as human-readable text on stdout. Each
# finding is laid out as:
#
#   ERROR [code]: message
#     source: path:line          (omitted if no source)
#     hint:   <hint>             (omitted if no hint)
#
# Errors come first, then warnings, matching the typical scan order. Output
# is byte-deterministic for byte-identical inputs (stable insertion order).
# -----------------------------------------------------------------------------
apr_lib_validate_emit_human() {
    local i
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_ERR_CODE[@]}"; do
            printf 'ERROR [%s]: %s\n' \
                "${_APR_VALIDATE_ERR_CODE[$i]}" \
                "${_APR_VALIDATE_ERR_MSG[$i]}"
            if [[ -n "${_APR_VALIDATE_ERR_SOURCE[$i]}" ]]; then
                printf '  source: %s\n' "${_APR_VALIDATE_ERR_SOURCE[$i]}"
            fi
            if [[ -n "${_APR_VALIDATE_ERR_HINT[$i]}" ]]; then
                printf '  hint:   %s\n' "${_APR_VALIDATE_ERR_HINT[$i]}"
            fi
        done
    fi
    if [[ -n "${_APR_VALIDATE_WARN_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_WARN_CODE[@]}"; do
            printf 'WARN  [%s]: %s\n' \
                "${_APR_VALIDATE_WARN_CODE[$i]}" \
                "${_APR_VALIDATE_WARN_MSG[$i]}"
            if [[ -n "${_APR_VALIDATE_WARN_SOURCE[$i]}" ]]; then
                printf '  source: %s\n' "${_APR_VALIDATE_WARN_SOURCE[$i]}"
            fi
            if [[ -n "${_APR_VALIDATE_WARN_HINT[$i]}" ]]; then
                printf '  hint:   %s\n' "${_APR_VALIDATE_WARN_HINT[$i]}"
            fi
        done
    fi
}

# =============================================================================
# Composable validators
# =============================================================================

# -----------------------------------------------------------------------------
# apr_lib_validate_prompt_qc <prompt_text> [<label>] [<source>]
#
# Detect placeholder leaks in a prompt. Records ONE error per detected
# residue class (currently: mustache `{{...}}` and APR directive residue
# `[[APR:`). Does not return non-zero on its own; callers should check
# `apr_lib_validate_has_errors` after running all validators.
#
# This subsumes the placeholder-detection logic previously inlined in
# apr's `prompt_quality_check`. Operators may still opt out of mustache
# detection via APR_ALLOW_CURLY_PLACEHOLDERS=1; that's recorded as an
# override.
#
# Code-fence awareness (bd-2lc): when APR_QC_RESPECT_CODE_FENCES=1
# (default), matches inside triple-backtick fenced regions are ignored.
# Strict mode (APR_FAIL_ON_WARN=1) disables this leniency.
#
# Lines triggering the match are recorded in details as a JSON array (max
# 8 entries per residue class) so robot consumers get actionable detail.
# -----------------------------------------------------------------------------
apr_lib_validate_prompt_qc() {
    local prompt="${1-}"
    local label="${2:-prompt}"
    local source="${3:-}"

    local respect_fences="${APR_QC_RESPECT_CODE_FENCES:-1}"
    # Strict mode overrides leniency: in strict, fenced text is checked too.
    if apr_lib_validate_strict_mode; then
        respect_fences=0
    fi

    # Mustache check (skippable via APR_ALLOW_CURLY_PLACEHOLDERS=1).
    if [[ "${APR_ALLOW_CURLY_PLACEHOLDERS:-}" != "1" ]]; then
        if [[ "$prompt" == *"{{"* || "$prompt" == *"}}"* ]]; then
            local hits
            hits=$(_apr_validate_qc_hits "$prompt" "$label" '{{|}}' "$respect_fences")
            if [[ -n "$hits" ]]; then
                local hits_json
                hits_json=$(_apr_validate_lines_to_json "$hits")
                local details
                details=$(printf '{"label":"%s","hits":%s}' \
                    "$(_apr_validate_json_escape "$label")" \
                    "$hits_json")
                apr_lib_validate_add_error \
                    "prompt_qc_failed" \
                    "Prompt contains unexpanded placeholders ('{{' / '}}'). APR does not substitute these." \
                    "Remove {{...}} from the workflow template, or set APR_ALLOW_CURLY_PLACEHOLDERS=1 to bypass." \
                    "$source" \
                    "$details"
            fi
        fi
    fi

    # Template directive residue check (always on; the template engine
    # already errors before this point in the happy path, so any residue
    # here means a bug in expansion or a workflow that printed `[[APR:`
    # without enabling directives).
    if [[ "$prompt" == *"[[APR:"* ]]; then
        local hits
        hits=$(_apr_validate_qc_hits "$prompt" "$label" '\[\[APR:' "$respect_fences")
        if [[ -n "$hits" ]]; then
            local hits_json
            hits_json=$(_apr_validate_lines_to_json "$hits")
            local details
            details=$(printf '{"label":"%s","hits":%s}' \
                "$(_apr_validate_json_escape "$label")" \
                "$hits_json")
            apr_lib_validate_add_error \
                "prompt_qc_failed" \
                "Prompt contains unexpanded APR directive residue ('[[APR:')." \
                "Enable template_directives in the workflow or remove the directive text." \
                "$source" \
                "$details"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Internal: emit `label:N` lines for every NR where <pattern> matches.
# When <respect_fences>=1, lines inside triple-backtick fenced regions
# are skipped. Pattern is an awk ERE.
# -----------------------------------------------------------------------------
_apr_validate_qc_hits() {
    local prompt="$1" label="$2" pattern="$3" respect_fences="$4"
    printf '%s\n' "$prompt" | awk \
        -v lbl="$label" \
        -v pat="$pattern" \
        -v respect_fences="$respect_fences" '
        BEGIN { in_fence = 0; count = 0 }
        # Fence toggle (triple backtick optionally with language tag).
        /^[[:space:]]*```/ {
            if (respect_fences == "1") {
                in_fence = !in_fence
                next
            }
        }
        respect_fences == "1" && in_fence { next }
        $0 ~ pat {
            printf "%s:%d\n", lbl, NR
            count++
            if (count >= 8) exit
        }
    '
}

# -----------------------------------------------------------------------------
# apr_lib_validate_additional_placeholders <prompt_text> [<label>] [<source>]
#
# Detect common "template not filled" markers that aren't mustache or
# APR directive residue (bd-2lc). These are recorded as WARNINGS by
# default (heuristic; false positives are possible), promoted to ERRORS
# in strict mode (`apr_lib_validate_finalize_strict`).
#
# Detected classes:
#   - <REPLACE_ME>, <INSERT>, <FIXME>, <TBD>           (angle-bracket markers)
#   - TODO: / TBD: / FIXME: / XXX:                     (colon-suffixed markers)
#
# Skipped inside triple-backtick fences when APR_QC_RESPECT_CODE_FENCES=1
# (default).
# -----------------------------------------------------------------------------
apr_lib_validate_additional_placeholders() {
    local prompt="${1-}"
    local label="${2:-prompt}"
    local source="${3:-}"

    local respect_fences="${APR_QC_RESPECT_CODE_FENCES:-1}"
    if apr_lib_validate_strict_mode; then
        respect_fences=0
    fi

    # Angle-bracket markers — distinct error code class so consumers can
    # filter independently.
    local angle_pattern='<(REPLACE_ME|INSERT|FIXME|TBD)>'
    if printf '%s' "$prompt" | grep -Eq "$angle_pattern"; then
        local hits
        hits=$(_apr_validate_qc_hits "$prompt" "$label" "$angle_pattern" "$respect_fences")
        if [[ -n "$hits" ]]; then
            local hits_json
            hits_json=$(_apr_validate_lines_to_json "$hits")
            local details
            details=$(printf '{"label":"%s","class":"angle_marker","hits":%s}' \
                "$(_apr_validate_json_escape "$label")" "$hits_json")
            apr_lib_validate_add_warning \
                "prompt_qc_placeholder_marker" \
                "Prompt contains template marker (<REPLACE_ME>, <INSERT>, <FIXME>, <TBD>)." \
                "Fill in the marker or remove it. Set APR_QC_RESPECT_CODE_FENCES=0 to also check fenced examples." \
                "$source" \
                "$details"
        fi
    fi

    # Colon-suffixed markers. Require word boundary on the left so we don't
    # match "GOTO:CASE" etc.; standard awk ERE here.
    local colon_pattern='(^|[^[:alnum:]_])(TODO|TBD|FIXME|XXX):'
    if printf '%s' "$prompt" | grep -Eq "$colon_pattern"; then
        local hits
        hits=$(_apr_validate_qc_hits "$prompt" "$label" "$colon_pattern" "$respect_fences")
        if [[ -n "$hits" ]]; then
            local hits_json
            hits_json=$(_apr_validate_lines_to_json "$hits")
            local details
            details=$(printf '{"label":"%s","class":"colon_marker","hits":%s}' \
                "$(_apr_validate_json_escape "$label")" "$hits_json")
            apr_lib_validate_add_warning \
                "prompt_qc_placeholder_marker" \
                "Prompt contains 'TODO:'/'TBD:'/'FIXME:'/'XXX:' marker outside code fences." \
                "Resolve the marker, move it inside a code fence, or set APR_FAIL_ON_WARN=0 to keep this as a warning." \
                "$source" \
                "$details"
        fi
    fi
}

# -----------------------------------------------------------------------------
# apr_lib_validate_strict_mode
#
# Return 0 iff strict mode is active (APR_FAIL_ON_WARN=1).
# -----------------------------------------------------------------------------
apr_lib_validate_strict_mode() {
    [[ "${APR_FAIL_ON_WARN:-}" == "1" ]]
}

# -----------------------------------------------------------------------------
# apr_lib_validate_finalize_strict
#
# In strict mode, promote ALL recorded warnings to errors so any
# warning blocks the run. Idempotent: warnings stay in the warnings
# bucket too (audit trail), but their codes/messages/hints are
# additionally appended to the errors bucket.
#
# Returns 0 always.
# -----------------------------------------------------------------------------
apr_lib_validate_finalize_strict() {
    if ! apr_lib_validate_strict_mode; then
        return 0
    fi
    if [[ -z "${_APR_VALIDATE_WARN_CODE[*]+set}" ]]; then
        return 0
    fi
    local i
    for i in "${!_APR_VALIDATE_WARN_CODE[@]}"; do
        apr_lib_validate_add_error \
            "${_APR_VALIDATE_WARN_CODE[$i]}" \
            "[strict] ${_APR_VALIDATE_WARN_MSG[$i]}" \
            "${_APR_VALIDATE_WARN_HINT[$i]}" \
            "${_APR_VALIDATE_WARN_SOURCE[$i]}" \
            "${_APR_VALIDATE_WARN_DETAILS[$i]}"
    done
    return 0
}

# -----------------------------------------------------------------------------
# Internal: convert one-per-line text to a JSON array of strings.
# -----------------------------------------------------------------------------
_apr_validate_lines_to_json() {
    local lines="${1-}"
    if [[ -z "$lines" ]]; then
        printf '[]'
        return 0
    fi
    local first=1 line esc
    printf '['
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ $first -eq 0 ]]; then printf ','; fi
        first=0
        esc=$(_apr_validate_json_escape "$line")
        printf '"%s"' "$esc"
    done <<< "$lines"
    printf ']'
}

# -----------------------------------------------------------------------------
# apr_lib_validate_documents_exist <required_paths_csv> [<optional_paths_csv>]
#
# Validate that every path in <required_paths_csv> exists and is readable.
# Optional paths add a warning if missing but do not fail. Empty paths are
# skipped.
#
# CSV is "|" separated to avoid collision with paths containing commas.
# -----------------------------------------------------------------------------
apr_lib_validate_documents_exist() {
    local required_csv="${1-}"
    local optional_csv="${2-}"

    local IFS='|'
    # shellcheck disable=SC2206
    local -a required=($required_csv)
    # shellcheck disable=SC2206
    local -a optional=($optional_csv)
    IFS=$' \t\n'

    local p details
    for p in "${required[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ ! -e "$p" ]]; then
            details=$(printf '{"path":"%s","required":true}' "$(_apr_validate_json_escape "$p")")
            apr_lib_validate_add_error "config_error" \
                "Required document not found: $p" \
                "Check the workflow yaml; paths are resolved relative to the project root." \
                "$p" \
                "$details"
            continue
        fi
        if [[ ! -r "$p" ]]; then
            details=$(printf '{"path":"%s","required":true}' "$(_apr_validate_json_escape "$p")")
            apr_lib_validate_add_error "config_error" \
                "Required document not readable: $p" \
                "Check file permissions." \
                "$p" \
                "$details"
            continue
        fi
        # Empty / suspiciously-small content policy (bd-zd6 will refine).
        local bytes
        bytes=$(apr_lib_manifest_size "$p" 2>/dev/null || echo "0")
        if [[ "$bytes" == "0" ]]; then
            details=$(printf '{"path":"%s","bytes":0}' "$(_apr_validate_json_escape "$p")")
            apr_lib_validate_add_error "config_error" \
                "Required document is empty: $p" \
                "Populate the file or remove it from the workflow." \
                "$p" \
                "$details"
        fi
    done

    for p in "${optional[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ ! -e "$p" ]]; then
            details=$(printf '{"path":"%s","required":false}' "$(_apr_validate_json_escape "$p")")
            apr_lib_validate_add_warning "config_warning" \
                "Optional document not found: $p (will be skipped)" \
                "Either create the file or drop the optional reference from the workflow." \
                "$p" \
                "$details"
        elif [[ ! -r "$p" ]]; then
            details=$(printf '{"path":"%s","required":false}' "$(_apr_validate_json_escape "$p")")
            apr_lib_validate_add_warning "config_warning" \
                "Optional document not readable: $p" \
                "Check file permissions." \
                "$p" \
                "$details"
        fi
    done
}
