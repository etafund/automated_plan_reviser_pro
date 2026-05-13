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
    local first=1
    if [[ -n "${_APR_VALIDATE_ERR_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_ERR_CODE[@]}"; do
            [[ $first -eq 0 ]] && echo "" >&2
            if declare -F apr_ui_error >/dev/null; then
                apr_ui_error "ERROR [${_APR_VALIDATE_ERR_CODE[$i]}]: ${_APR_VALIDATE_ERR_MSG[$i]}" \
                    "code: ${_APR_VALIDATE_ERR_CODE[$i]}${_APR_VALIDATE_ERR_SOURCE[$i]:+; source: ${_APR_VALIDATE_ERR_SOURCE[$i]}}${_APR_VALIDATE_ERR_HINT[$i]:+; hint: ${_APR_VALIDATE_ERR_HINT[$i]}}"
            else
                printf 'ERROR [%s]: %s\n' "${_APR_VALIDATE_ERR_CODE[$i]}" "${_APR_VALIDATE_ERR_MSG[$i]}"
                [[ -n "${_APR_VALIDATE_ERR_SOURCE[$i]}" ]] && printf '  source: %s\n' "${_APR_VALIDATE_ERR_SOURCE[$i]}"
                [[ -n "${_APR_VALIDATE_ERR_HINT[$i]}" ]] && printf '  hint:   %s\n' "${_APR_VALIDATE_ERR_HINT[$i]}"
            fi
            first=0
        done
    fi
    if [[ -n "${_APR_VALIDATE_WARN_CODE[*]+set}" ]]; then
        for i in "${!_APR_VALIDATE_WARN_CODE[@]}"; do
            [[ $first -eq 0 ]] && echo "" >&2
            if declare -F apr_ui_warn >/dev/null; then
                apr_ui_warn "WARN [${_APR_VALIDATE_WARN_CODE[$i]}]: ${_APR_VALIDATE_WARN_MSG[$i]}" \
                    "code: ${_APR_VALIDATE_WARN_CODE[$i]}${_APR_VALIDATE_WARN_SOURCE[$i]:+; source: ${_APR_VALIDATE_WARN_SOURCE[$i]}}${_APR_VALIDATE_WARN_HINT[$i]:+; hint: ${_APR_VALIDATE_WARN_HINT[$i]}}"
            else
                printf 'WARN  [%s]: %s\n' "${_APR_VALIDATE_WARN_CODE[$i]}" "${_APR_VALIDATE_WARN_MSG[$i]}"
                [[ -n "${_APR_VALIDATE_WARN_SOURCE[$i]}" ]] && printf '  source: %s\n' "${_APR_VALIDATE_WARN_SOURCE[$i]}"
                [[ -n "${_APR_VALIDATE_WARN_HINT[$i]}" ]] && printf '  hint:   %s\n' "${_APR_VALIDATE_WARN_HINT[$i]}"
            fi
            first=0
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

    # Shell-style placeholders (bd-64dh): ${VAR} (braced) and $VAR
    # (unbraced). The braced form is unambiguous; the unbraced form
    # carries a small false-positive risk in genuine shell snippets, so
    # we exclude the well-known special parameters $1..$9, $@, $*, $#,
    # $?, $$, $0, $! (which are almost always shell positionals, not
    # template placeholders). All matches respect code fences when
    # APR_QC_RESPECT_CODE_FENCES=1 (default).
    #
    # Patterns:
    #   braced:   \$\{[A-Za-z_][A-Za-z0-9_]*\}        (e.g. ${README}, ${MY_VAR})
    #   unbraced: \$[A-Za-z_][A-Za-z0-9_]*            (e.g. $README, $MY_VAR)
    local shell_pattern='\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*'
    if printf '%s' "$prompt" | grep -Eq "$shell_pattern"; then
        local hits
        hits=$(_apr_validate_qc_hits "$prompt" "$label" "$shell_pattern" "$respect_fences")
        if [[ -n "$hits" ]]; then
            local hits_json
            hits_json=$(_apr_validate_lines_to_json "$hits")
            local details
            details=$(printf '{"label":"%s","class":"shell_var","hits":%s}' \
                "$(_apr_validate_json_escape "$label")" "$hits_json")
            apr_lib_validate_add_warning \
                "prompt_qc_placeholder_marker" \
                "Prompt contains shell-style placeholder ('\${VAR}' or '\$VAR') outside code fences." \
                "Either expand the placeholder, move the example inside a \`\`\` fence, or set APR_QC_RESPECT_CODE_FENCES=0 to also check fenced examples. Shell special params (\$1, \$@, \$#, \$?, \$\$, \$0, \$!) are intentionally not flagged." \
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
# apr_lib_validate_workflow_schema <workflow_file>
#
# Validate that the workflow YAML contains required keys and warn on unknown
# ones.
# -----------------------------------------------------------------------------
apr_lib_validate_workflow_schema() {
    local wf_file="${1:?workflow file required}"
    if [[ ! -f "$wf_file" ]]; then
        return 1
    fi

    local -a required=(readme spec model output_dir)
    local -a known=(
        "${required[@]}"
        implementation
        impl_every_n
        thinking_time
        description
        template_directives
        template
        template_with_impl
    )

    local key val line=0
    local has_thinking_time=0
    while IFS=: read -r key val || [[ -n "$key" ]]; do
        line=$((line + 1))
        # Strip whitespace and quotes
        key=$(printf '%s' "$key" | xargs)
        [[ -z "$key" || "$key" == "#"* ]] && continue

        # Check if key is known
        local is_known=0 k
        for k in "${known[@]}"; do
            if [[ "$key" == "$k" || "$key" == "$k."* ]]; then
                is_known=1
                break
            fi
        done

        if [[ $is_known -eq 0 ]]; then
            apr_lib_validate_add_warning "config_warning" \
                "Unknown key in workflow: $key" \
                "Check for typos or remove the unused key." \
                "$wf_file:$line" \
                "$(printf '{"key":"%s"}' "$(_apr_validate_json_escape "$key")")"
        fi

        # Model policy (bd-19x)
        if [[ "$key" == "model" ]]; then
            local m
            m=$(printf '%s' "$val" | xargs)
            if [[ "${APR_ALLOW_NONPRO_MODELS:-0}" != "1" ]]; then
                # Allow list: Thinking, Pro, o1, o3, opus, 4.7, 5.2
                if [[ ! "$m" =~ (Thinking|Pro|o1|o3|opus|4.7|5.2) ]]; then
                    apr_lib_validate_add_warning "config_warning" \
                        "Model '$m' may produce lower quality refinements." \
                        "Recommended: Use a thinking-enabled or Pro model (e.g. 'GPT Pro 5.2 Thinking'). Silence with APR_ALLOW_NONPRO_MODELS=1." \
                        "$wf_file:$line" \
                        "$(printf '{"model":"%s"}' "$(_apr_validate_json_escape "$m")")"
                fi
            fi
        fi

        # Thinking time policy (bd-19x)
        if [[ "$key" == "thinking_time" ]]; then
            has_thinking_time=1
            local tt
            tt=$(printf '%s' "$val" | xargs)
            if [[ "${APR_ALLOW_LIGHT_THINKING:-0}" != "1" ]]; then
                if [[ "$tt" =~ ^[0-9]+$ ]] && (( tt < 60 )); then
                     apr_lib_validate_add_warning "config_warning" \
                        "Low thinking time: ${tt}s" \
                        "Thinking time below 60s is not recommended for high-quality reasoning. Set to 60+ or set APR_ALLOW_LIGHT_THINKING=1." \
                        "$wf_file:$line" \
                        "$(printf '{"thinking_time":%d}' "$tt")"
                fi
            fi
        fi
    done < "$wf_file"

    # Thinking time missing policy (bd-19x)
    if [[ $has_thinking_time -eq 0 && "${APR_ALLOW_LIGHT_THINKING:-0}" != "1" ]]; then
        apr_lib_validate_add_warning "config_warning" \
            "Thinking time not specified." \
            "Explicit thinking_time (e.g. 60) is recommended for stable reasoning. Silence with APR_ALLOW_LIGHT_THINKING=1." \
            "$wf_file" \
            "null"
    fi

    # Check for missing required keys
    local req
    for req in "${required[@]}"; do
        if ! grep -qE "^[[:space:]]*${req}[[:space:]]*:" "$wf_file"; then
            apr_lib_validate_add_error "config_error" \
                "Missing required workflow key: $req" \
                "Add '$req' to your workflow YAML." \
                "$wf_file" \
                "$(printf '{"key":"%s"}' "$req")"
        fi
    done

    return 0
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

# =============================================================================
# bd-zd6: per-document size policy
# =============================================================================
#
# Default warning thresholds (bytes) for the canonical document roles.
# These are conservative — a real-world README under 256 bytes is almost
# certainly a stub; a spec under 1 KiB is unlikely to be substantive.
# Operators can override per-role via APR_DOC_*_WARN_BYTES env vars.
_APR_VALIDATE_DEFAULT_WARN_README=256
_APR_VALIDATE_DEFAULT_WARN_SPEC=1024
_APR_VALIDATE_DEFAULT_WARN_IMPL=512

# -----------------------------------------------------------------------------
# apr_lib_validate_doc_size <path> <role> [<warn_threshold>] [<fatal_threshold>]
#
# Apply a per-document size policy to <path>:
#   - bytes < fatal_threshold (>0)  ->  config_error
#   - bytes < warn_threshold (>0)   ->  config_warning (escalates to error
#                                       under APR_FAIL_ON_WARN via
#                                       apr_lib_validate_finalize_strict)
#   - otherwise: no finding.
#
# Missing/unreadable files are NOT this function's concern — they are
# already flagged by apr_lib_validate_documents_exist. doc_size only
# fires when the file exists and is readable.
#
# <role> is a short label like "readme", "spec", or "impl" — used in
# the finding's details JSON and as the env-var override key. If
# <warn_threshold> is omitted/empty, defaults are pulled from
# APR_DOC_<ROLE>_WARN_BYTES env var, falling back to the constants
# above. Pass "0" to disable the warning check.
#
# <fatal_threshold> defaults to 0 (disabled). Strict mode does NOT
# auto-pick a fatal threshold; the operator must set it explicitly via
# APR_DOC_<ROLE>_FATAL_BYTES or the third argument.
# -----------------------------------------------------------------------------
apr_lib_validate_doc_size() {
    local path="${1:?path required}"
    local role="${2:?role required}"
    local warn_threshold="${3-}"
    local fatal_threshold="${4-}"

    [[ -e "$path" && -r "$path" ]] || return 0

    # Resolve per-role thresholds: explicit arg > env override > default.
    local role_upper
    role_upper=$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')
    if [[ -z "$warn_threshold" ]]; then
        local env_var="APR_DOC_${role_upper}_WARN_BYTES"
        warn_threshold="${!env_var-}"
    fi
    if [[ -z "$warn_threshold" ]]; then
        case "$role" in
            readme)            warn_threshold="$_APR_VALIDATE_DEFAULT_WARN_README" ;;
            spec|specification) warn_threshold="$_APR_VALIDATE_DEFAULT_WARN_SPEC" ;;
            impl|implementation) warn_threshold="$_APR_VALIDATE_DEFAULT_WARN_IMPL" ;;
            *) warn_threshold=0 ;;
        esac
    fi
    if [[ -z "$fatal_threshold" ]]; then
        local fenv_var="APR_DOC_${role_upper}_FATAL_BYTES"
        fatal_threshold="${!fenv_var:-0}"
    fi

    # Coerce to int; non-numeric -> disabled.
    [[ "$warn_threshold"  =~ ^[0-9]+$ ]] || warn_threshold=0
    [[ "$fatal_threshold" =~ ^[0-9]+$ ]] || fatal_threshold=0

    local bytes
    bytes=$(apr_lib_manifest_size "$path" 2>/dev/null || echo "0")
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    local details
    details=$(printf '{"path":"%s","role":"%s","bytes":%s,"warn_threshold":%s,"fatal_threshold":%s}' \
        "$(_apr_validate_json_escape "$path")" \
        "$(_apr_validate_json_escape "$role")" \
        "$bytes" \
        "$warn_threshold" \
        "$fatal_threshold")

    # Fatal first — beats the warning if both would fire.
    if [[ "$fatal_threshold" -gt 0 ]] && [[ "$bytes" -lt "$fatal_threshold" ]]; then
        apr_lib_validate_add_error "config_error" \
            "Document $path (role: $role) is below the fatal size threshold (${bytes} < ${fatal_threshold} bytes)." \
            "Populate the document, lower APR_DOC_${role_upper}_FATAL_BYTES, or remove the role from the workflow." \
            "$path" \
            "$details"
        return 0
    fi
    if [[ "$warn_threshold" -gt 0 ]] && [[ "$bytes" -lt "$warn_threshold" ]]; then
        apr_lib_validate_add_warning "config_warning" \
            "Document $path (role: $role) is suspiciously small (${bytes} < ${warn_threshold} bytes)." \
            "If this is intentional, lower APR_DOC_${role_upper}_WARN_BYTES; if not, populate the file before running." \
            "$path" \
            "$details"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_validate_doc_sizes <triples...>
#
# Convenience wrapper: apply apr_lib_validate_doc_size to several
# documents in one call. Triples are pipe-separated strings of:
#   "<path>|<role>|<warn>|<fatal>"
# Warn/fatal are optional (empty = use env/default).
#
# Skips empty paths so callers can drop unset workflow fields in
# without conditionals.
# -----------------------------------------------------------------------------
apr_lib_validate_doc_sizes() {
    local triple path role warn fatal
    for triple in "$@"; do
        IFS='|' read -r path role warn fatal <<< "$triple"
        [[ -z "$path" ]] && continue
        apr_lib_validate_doc_size "$path" "$role" "$warn" "$fatal"
    done
}

# =============================================================================
# bd-1eq: secret scanning (warn-only; strict mode escalates via finalize_strict)
# =============================================================================
#
# Complements bd-3ut (lib/redact.sh):
#   - bd-3ut silently substitutes secrets with typed sentinels in the
#     prompt before it leaves APR.
#   - bd-1eq DETECTS likely secrets so the operator sees a clear warning
#     (or a strict-mode error) before the run; the actual prompt is
#     untouched.
#
# Pattern set matches bd-3ut for consistency. Each finding records:
#   - source: <label>:<line_no>
#   - hint:   "Remove the secret, move it to an env var, or enable
#              redaction mode (APR_REDACT=1)."
#   - details: {"label", "class": "OPENAI_KEY|...", "line": N,
#               "redacted_snippet": "<context with secret replaced>"}
#
# Code-fence-aware (APR_QC_RESPECT_CODE_FENCES=1, default on). Strict
# mode (APR_FAIL_ON_WARN=1) escalates to error via the existing
# apr_lib_validate_finalize_strict promotion path.
# -----------------------------------------------------------------------------

# Pattern catalog: "class|extended-regex". Aligned with bd-3ut.
_APR_VALIDATE_SECRET_PATTERNS=(
    'PRIVATE_KEY_BLOCK|^-----BEGIN [A-Z][A-Z ]*PRIVATE KEY-----'
    'OPENAI_KEY|sk-[A-Za-z0-9_-]{20,}'
    'GITHUB_FINEGRAINED|github_pat_[A-Za-z0-9_]{20,}'
    'GITHUB_TOKEN|gh[posur]_[A-Za-z0-9_-]{20,}'
    'SLACK_TOKEN|xox[bpars]-[A-Za-z0-9-]{10,}'
    'AKIA_KEY|(^|[^A-Z0-9])AKIA[0-9A-Z]{16}([^A-Z0-9]|$)'
    'AUTH_BEARER_TOKEN|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]+'
)

# -----------------------------------------------------------------------------
# Internal: emit a redacted snippet of <line> with the matched secret
# replaced by <<class>>. Truncates to 200 bytes for log hygiene.
# -----------------------------------------------------------------------------
_apr_validate_secret_redact_line() {
    local line="$1" class="$2" regex="$3"
    local redacted
    redacted=$(printf '%s' "$line" | sed -E "s/$regex/<<$class>>/g" 2>/dev/null) || redacted="<<$class>>"
    if [[ ${#redacted} -gt 200 ]]; then
        redacted="${redacted:0:200}"
    fi
    printf '%s' "$redacted"
}

# -----------------------------------------------------------------------------
# apr_lib_validate_secret_scan <text> [<label>] [<source_prefix>]
#
# Scan <text> for high-confidence secret patterns. Records one warning
# per match (class + line number + redacted snippet). Honors
# APR_QC_RESPECT_CODE_FENCES (default 1; strict mode forces 0).
#
# <source_prefix> is used for the finding's `source` field (typically
# "<file-path>"); the line number is appended as ":<n>" so robot
# consumers get exact locations.
# -----------------------------------------------------------------------------
apr_lib_validate_secret_scan() {
    local text="${1-}"
    local label="${2:-prompt}"
    local source_prefix="${3-}"

    [[ -z "$text" ]] && return 0

    local respect_fences="${APR_QC_RESPECT_CODE_FENCES:-1}"
    if apr_lib_validate_strict_mode; then
        respect_fences=0
    fi

    local sig class regex
    for sig in "${_APR_VALIDATE_SECRET_PATTERNS[@]}"; do
        class="${sig%%|*}"
        regex="${sig#*|}"
        if ! printf '%s' "$text" | grep -Eq "$regex"; then
            continue
        fi
        local hits
        hits=$(_apr_validate_qc_hits "$text" "$label" "$regex" "$respect_fences")
        [[ -z "$hits" ]] && continue
        local hit line_no hit_label
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            hit_label="${hit%:*}"
            line_no="${hit##*:}"
            [[ "$line_no" =~ ^[0-9]+$ ]] || continue
            local line
            line=$(printf '%s\n' "$text" | sed -n "${line_no}p")
            local snippet
            snippet=$(_apr_validate_secret_redact_line "$line" "$class" "$regex")
            local details
            details=$(printf '{"label":"%s","class":"%s","line":%s,"redacted_snippet":"%s"}' \
                "$(_apr_validate_json_escape "$hit_label")" \
                "$class" \
                "$line_no" \
                "$(_apr_validate_json_escape "$snippet")")
            local src=""
            if [[ -n "$source_prefix" ]]; then
                src="${source_prefix}:${line_no}"
            else
                src="${hit_label}:${line_no}"
            fi
            apr_lib_validate_add_warning "secret_detected" \
                "Likely $class secret at ${hit_label}:${line_no} (redacted snippet: $snippet)" \
                "Remove the secret from the doc, move it to an env var, or enable redaction mode (APR_REDACT=1). Use APR_FAIL_ON_WARN=1 to block runs on detection." \
                "$src" \
                "$details"
        done <<< "$hits"
    done
    return 0
}
