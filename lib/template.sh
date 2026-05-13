#!/usr/bin/env bash
# lib/template.sh - APR safe template directive engine (bd-1mf)
#
# Implements the directive parser and handlers specified in
# docs/schemas/template-directives.md (bd-2nq):
#
#   [[APR:FILE <path>]]
#   [[APR:SHA <path>]]
#   [[APR:SIZE <path>]]
#   [[APR:EXCERPT <path> <n>]]
#   [[APR:LIT <text...>]]
#
# Public API:
#   apr_lib_template_expand <text> [<project_root>] [<allow_traversal>] [<allow_absolute>] [<verbose>]
#       Emit expanded text on stdout. Return 0 on success, non-zero on
#       directive failure. On failure, the following globals carry the
#       structured error context:
#
#           APR_TEMPLATE_ERROR_CODE      - always "template_engine_error"
#           APR_TEMPLATE_ERROR_REASON    - one of the documented reasons
#                                          (e.g. unknown_type, bad_args,
#                                          unterminated_directive, ...)
#           APR_TEMPLATE_ERROR_LINE      - 1-based template line number
#           APR_TEMPLATE_ERROR_DIRECTIVE - the offending directive text
#           APR_TEMPLATE_ERROR_TYPE      - the parsed TYPE (or "")
#           APR_TEMPLATE_ERROR_ARG       - the offending argument (or "")
#           APR_TEMPLATE_ERROR_MESSAGE   - human-readable message
#           APR_TEMPLATE_ERROR_HINT      - one-line remediation hint
#
# Design priorities:
#   1. Safe by construction (allowlist + strict parsing).
#   2. Deterministic (byte-identical output for byte-identical inputs).
#   3. Pure Bash; depends on the helpers in lib/manifest.sh for sha256/size.
#   4. Error messages cite the template line number.
#
# Guard against double-sourcing.
if [[ "${_APR_LIB_TEMPLATE_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_TEMPLATE_LOADED=1

# Resolve the directory containing this file so we can source siblings
# regardless of CWD.
_APR_LIB_TEMPLATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Depend on manifest helpers (sha256, size).
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_TEMPLATE_DIR/manifest.sh"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Allowlisted directive types (must stay in sync with template-directives.md).
_APR_TEMPLATE_TYPES=("FILE" "SHA" "SIZE" "EXCERPT" "LIT")

# Public canonical taxonomy code for template engine errors.
# shellcheck disable=SC2034
APR_TEMPLATE_ERROR_CODE_CONST="template_engine_error"
export APR_TEMPLATE_ERROR_CODE_CONST

# Error context globals (re-set on each call). Exported so callers in robot
# mode can pull structured detail without re-parsing stderr.
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_CODE=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_REASON=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_LINE=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_DIRECTIVE=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_TYPE=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_ARG=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_MESSAGE=""
# shellcheck disable=SC2034
export APR_TEMPLATE_ERROR_HINT=""

# -----------------------------------------------------------------------------
# Internal: _apr_template_set_error <reason> <line> <directive> <type> <arg> <message> <hint>
# -----------------------------------------------------------------------------
_apr_template_set_error() {
    APR_TEMPLATE_ERROR_CODE="template_engine_error"
    APR_TEMPLATE_ERROR_REASON="${1:-}"
    APR_TEMPLATE_ERROR_LINE="${2:-}"
    APR_TEMPLATE_ERROR_DIRECTIVE="${3:-}"
    APR_TEMPLATE_ERROR_TYPE="${4:-}"
    APR_TEMPLATE_ERROR_ARG="${5:-}"
    APR_TEMPLATE_ERROR_MESSAGE="${6:-}"
    APR_TEMPLATE_ERROR_HINT="${7:-}"
}

# -----------------------------------------------------------------------------
# _apr_template_is_known_type <type>
#
# Return 0 iff <type> is one of the allowlisted directive TYPEs.
# -----------------------------------------------------------------------------
_apr_template_is_known_type() {
    local t="${1:-}"
    local known
    for known in "${_APR_TEMPLATE_TYPES[@]}"; do
        [[ "$t" == "$known" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# _apr_template_known_types_csv
#
# Emit the comma-separated list of allowlisted TYPEs (for error messages).
# -----------------------------------------------------------------------------
_apr_template_known_types_csv() {
    local IFS=,
    printf '%s' "${_APR_TEMPLATE_TYPES[*]}"
}

# -----------------------------------------------------------------------------
# _apr_template_validate_path <path> <project_root> <allow_traversal> <allow_absolute>
#
# Validate <path> against the safety rules in the directive spec.
# Returns 0 on success, sets _apr_template_path_reason and returns 1 on failure.
# -----------------------------------------------------------------------------
_apr_template_path_reason=""
_apr_template_validate_path() {
    local path="$1"
    local project_root="${2:-.}"
    local allow_traversal="${3:-0}"
    local allow_absolute="${4:-0}"

    _apr_template_path_reason=""

    if [[ -z "$path" ]]; then
        _apr_template_path_reason="empty_path"
        return 1
    fi
    # NUL bytes cannot survive in Bash string variables (the string is
    # truncated at the first NUL), so no defensive check is needed here —
    # the directive parser would never see a NUL through normal input.
    # `]]` substring cannot occur (parser splits on it) but check anyway.
    if [[ "$path" == *"]]"* ]]; then
        _apr_template_path_reason="close_marker_in_path"
        return 1
    fi
    # Absolute path policy.
    if [[ "$path" == /* ]]; then
        if [[ "$allow_absolute" != "1" ]]; then
            _apr_template_path_reason="absolute_path_blocked"
            return 1
        fi
    fi
    # Traversal: any segment equal to `..`.
    if [[ "$allow_traversal" != "1" ]]; then
        local segment
        local IFS=/
        # shellcheck disable=SC2206
        local parts=($path)
        IFS=$' \t\n'
        for segment in "${parts[@]}"; do
            if [[ "$segment" == ".." ]]; then
                _apr_template_path_reason="traversal_blocked"
                return 1
            fi
        done
        # Symlink-resolution check: if realpath is available and the path
        # exists, ensure its resolved form is under project_root.
        if command -v realpath >/dev/null 2>&1; then
            local abs_root abs_resolved
            abs_root=$(realpath -m -- "$project_root" 2>/dev/null) || abs_root=""
            local target="$path"
            if [[ "$path" != /* ]]; then
                target="$project_root/$path"
            fi
            abs_resolved=$(realpath -m -- "$target" 2>/dev/null) || abs_resolved=""
            if [[ -n "$abs_root" && -n "$abs_resolved" ]]; then
                if [[ "$abs_resolved" != "$abs_root" && "$abs_resolved" != "$abs_root/"* ]]; then
                    _apr_template_path_reason="symlink_traversal_blocked"
                    return 1
                fi
            fi
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# _apr_template_handle <out_var> <type> <project_root> <line_no> <directive_text>
#                      <allow_traversal> <allow_absolute> <verbose> <args...>
#
# Run the handler for <type>. The expansion text is written into the
# variable named by <out_var> via `printf -v` (no command substitution, so
# globals set inside the handler — including error context and validate-
# path reason — survive into the caller).
#
# Returns 0 on success, non-zero on error (with the error globals set).
# -----------------------------------------------------------------------------
_apr_template_handle() {
    local _out_var="$1"; shift
    local type="$1"; shift
    local project_root="$1"; shift
    local line_no="$1"; shift
    local directive_text="$1"; shift
    local allow_traversal="$1"; shift
    local allow_absolute="$1"; shift
    local verbose="$1"; shift
    local -a args=("$@")

    # Always clear the out var up front so partial writes don't leak.
    printf -v "$_out_var" '%s' ""

    case "$type" in
        FILE|SHA|SIZE)
            if [[ ${#args[@]} -ne 1 ]]; then
                _apr_template_set_error "bad_args" "$line_no" "$directive_text" "$type" "" \
                    "$type directive requires exactly 1 argument (path)" \
                    "Write [[APR:$type <path>]]"
                return 1
            fi
            local path="${args[0]}"
            if ! _apr_template_validate_path "$path" "$project_root" "$allow_traversal" "$allow_absolute"; then
                local reason="$_apr_template_path_reason"
                _apr_template_set_error "$reason" "$line_no" "$directive_text" "$type" "$path" \
                    "Path '$path' rejected: $reason" \
                    "$(_apr_template_path_hint "$reason")"
                return 1
            fi
            local resolved="$path"
            if [[ "$path" != /* ]]; then
                resolved="$project_root/$path"
            fi
            if [[ ! -e "$resolved" ]]; then
                _apr_template_set_error "file_not_found" "$line_no" "$directive_text" "$type" "$path" \
                    "File not found: $path" \
                    "Check the path; it is resolved relative to the project root ($project_root)"
                return 1
            fi
            if [[ ! -r "$resolved" ]]; then
                _apr_template_set_error "file_unreadable" "$line_no" "$directive_text" "$type" "$path" \
                    "File not readable: $path" \
                    "Check file permissions"
                return 1
            fi
            case "$type" in
                FILE)
                    # Preserve trailing newlines (command substitution would
                    # strip them). Append a sentinel `X` and remove it.
                    local _file_content
                    _file_content=$(cat -- "$resolved"; printf 'X')
                    _file_content="${_file_content%X}"
                    printf -v "$_out_var" '%s' "$_file_content"
                    if [[ "$verbose" == "1" ]]; then
                        local sz
                        sz=$(apr_lib_manifest_size "$resolved" 2>/dev/null || echo "?")
                        printf '[apr] template: expanded [[APR:FILE %s]] -> %s bytes\n' "$path" "$sz" >&2
                    fi
                    ;;
                SHA)
                    local sha
                    sha=$(apr_lib_manifest_sha256 "$resolved")
                    printf -v "$_out_var" '%s' "$sha"
                    if [[ "$verbose" == "1" ]]; then
                        printf '[apr] template: expanded [[APR:SHA %s]] -> %s... (64-byte sha256)\n' "$path" "${sha:0:8}" >&2
                    fi
                    ;;
                SIZE)
                    local sz
                    sz=$(apr_lib_manifest_size "$resolved")
                    printf -v "$_out_var" '%s' "$sz"
                    if [[ "$verbose" == "1" ]]; then
                        printf '[apr] template: expanded [[APR:SIZE %s]] -> %s\n' "$path" "$sz" >&2
                    fi
                    ;;
            esac
            return 0
            ;;
        EXCERPT)
            if [[ ${#args[@]} -ne 2 ]]; then
                _apr_template_set_error "bad_args" "$line_no" "$directive_text" "$type" "" \
                    "EXCERPT directive requires exactly 2 arguments (path, n)" \
                    "Write [[APR:EXCERPT <path> <n>]]"
                return 1
            fi
            local path="${args[0]}"
            local n="${args[1]}"
            if [[ ! "$n" =~ ^[0-9]+$ ]] || [[ "$n" == "0" ]]; then
                _apr_template_set_error "bad_arg_excerpt_n" "$line_no" "$directive_text" "$type" "$n" \
                    "EXCERPT requires a positive integer for n; got '$n'" \
                    "Write [[APR:EXCERPT <path> <positive-integer>]]"
                return 1
            fi
            if ! _apr_template_validate_path "$path" "$project_root" "$allow_traversal" "$allow_absolute"; then
                local reason="$_apr_template_path_reason"
                _apr_template_set_error "$reason" "$line_no" "$directive_text" "$type" "$path" \
                    "Path '$path' rejected: $reason" \
                    "$(_apr_template_path_hint "$reason")"
                return 1
            fi
            local resolved="$path"
            if [[ "$path" != /* ]]; then
                resolved="$project_root/$path"
            fi
            if [[ ! -e "$resolved" ]]; then
                _apr_template_set_error "file_not_found" "$line_no" "$directive_text" "$type" "$path" \
                    "File not found: $path" \
                    "Check the path; it is resolved relative to the project root ($project_root)"
                return 1
            fi
            if [[ ! -r "$resolved" ]]; then
                _apr_template_set_error "file_unreadable" "$line_no" "$directive_text" "$type" "$path" \
                    "File not readable: $path" \
                    "Check file permissions"
                return 1
            fi
            # Capture excerpt bytes via the same sentinel trick used by FILE
            # so trailing newlines (if any) are preserved.
            local _excerpt_content
            _excerpt_content=$(head -c "$n" -- "$resolved" 2>/dev/null; printf 'X')
            _excerpt_content="${_excerpt_content%X}"
            printf -v "$_out_var" '%s' "$_excerpt_content"
            if [[ "$verbose" == "1" ]]; then
                local actual_size
                actual_size=$(apr_lib_manifest_size "$resolved" 2>/dev/null || echo "?")
                local emitted="$n"
                if [[ "$actual_size" =~ ^[0-9]+$ ]] && [[ "$actual_size" -lt "$n" ]]; then
                    emitted="$actual_size"
                    printf '[apr] template: expanded [[APR:EXCERPT %s %s]] -> %s bytes (short file)\n' "$path" "$n" "$emitted" >&2
                else
                    printf '[apr] template: expanded [[APR:EXCERPT %s %s]] -> %s bytes (truncated)\n' "$path" "$n" "$emitted" >&2
                fi
            fi
            return 0
            ;;
        LIT)
            # LIT returns its raw argument text. Re-join args with single
            # spaces (matches the natural reading; we lose original spacing,
            # but that's documented).
            local lit="${args[*]}"
            printf -v "$_out_var" '%s' "$lit"
            if [[ "$verbose" == "1" ]]; then
                printf '[apr] template: expanded [[APR:LIT ...]] -> %s bytes\n' "${#lit}" >&2
            fi
            return 0
            ;;
        *)
            _apr_template_set_error "unknown_type" "$line_no" "$directive_text" "$type" "" \
                "Unknown directive type '$type'. Allowed: $(_apr_template_known_types_csv)" \
                "Use one of: $(_apr_template_known_types_csv)"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# _apr_template_path_hint <reason>
#
# Map a path-rejection reason to a one-line remediation hint.
# -----------------------------------------------------------------------------
_apr_template_path_hint() {
    case "${1:-}" in
        empty_path) printf '%s' "Provide a non-empty path argument" ;;
        absolute_path_blocked) printf '%s' "Use a project-relative path, or set template_directives.allow_absolute=true" ;;
        traversal_blocked) printf '%s' "Remove '..' segments, or set template_directives.allow_traversal=true" ;;
        symlink_traversal_blocked) printf '%s' "The symlink resolves outside the project root; replace with a real file or set allow_traversal=true" ;;
        nul_in_path) printf '%s' "Paths may not contain NUL bytes" ;;
        close_marker_in_path) printf '%s' "Paths may not contain ']]'" ;;
        *) printf '%s' "Inspect the path and retry" ;;
    esac
}

# -----------------------------------------------------------------------------
# apr_lib_template_expand <text> [<project_root>] [<allow_traversal>] [<allow_absolute>] [<verbose>]
#
# See top-of-file docstring.
# -----------------------------------------------------------------------------
apr_lib_template_expand() {
    local text="${1-}"
    local project_root="${2:-.}"
    local allow_traversal="${3:-0}"
    local allow_absolute="${4:-0}"
    local verbose="${5:-0}"

    # Reset error globals.
    _apr_template_set_error "" "" "" "" "" "" ""

    if [[ -z "$text" ]]; then
        return 0
    fi

    local -a output_lines=()
    local line_no=0
    local line
    # Preserve trailing newline behavior by detecting absence/presence.
    local has_trailing_newline=0
    if [[ "$text" == *$'\n' ]]; then
        has_trailing_newline=1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        local out=""
        while [[ "$line" == *"[[APR:"* ]]; do
            local pre rest body post
            pre="${line%%\[\[APR:*}"
            rest="${line#*\[\[APR:}"
            # If rest has no `]]`, it's unterminated on this line.
            if [[ "$rest" != *"]]"* ]]; then
                _apr_template_set_error "unterminated_directive" "$line_no" "[[APR:$rest" "" "" \
                    "Directive on line $line_no has no closing ']]'" \
                    "Add ']]' to terminate the directive on the same line"
                return 1
            fi
            body="${rest%%\]\]*}"
            post="${rest#*\]\]}"
            out+="$pre"

            # Parse body: split on whitespace into TYPE + args.
            # Trim leading/trailing whitespace from body.
            local body_trimmed
            body_trimmed="$(_apr_template_trim "$body")"
            local directive_text="[[APR:${body}]]"
            # Disable pathname expansion before splitting on whitespace.
            # Without this, an unquoted expansion of `$body_trimmed`
            # below would glob-expand `*`, `?`, `[...]` against the CWD
            # — leaking filenames into directive args (bd-r3lo).
            # We restore the prior glob state immediately after.
            local _apr_t_old_glob_off=0
            case $- in *f*) _apr_t_old_glob_off=1 ;; esac
            set -f
            # shellcheck disable=SC2206
            local -a tokens=($body_trimmed)
            if [[ "$_apr_t_old_glob_off" -eq 0 ]]; then
                set +f
            fi
            if [[ ${#tokens[@]} -eq 0 ]]; then
                _apr_template_set_error "bad_args" "$line_no" "$directive_text" "" "" \
                    "Empty directive body" \
                    "Use one of: $(_apr_template_known_types_csv)"
                return 1
            fi
            local type="${tokens[0]}"
            local -a args=("${tokens[@]:1}")

            if ! _apr_template_is_known_type "$type"; then
                _apr_template_set_error "unknown_type" "$line_no" "$directive_text" "$type" "" \
                    "Unknown directive type '$type'. Allowed: $(_apr_template_known_types_csv)" \
                    "Use one of: $(_apr_template_known_types_csv)"
                return 1
            fi

            local _expansion=""
            # Run the handler WITHOUT a subshell so error globals + the
            # validate-path reason survive into this caller.
            if ! _apr_template_handle _expansion "$type" "$project_root" "$line_no" "$directive_text" \
                                       "$allow_traversal" "$allow_absolute" "$verbose" \
                                       "${args[@]}"; then
                return 1
            fi
            out+="$_expansion"
            line="$post"
        done
        out+="$line"
        output_lines+=("$out")
    done <<< "$text"

    # Reassemble: newlines between elements, plus optional trailing.
    local i first=1
    for i in "${!output_lines[@]}"; do
        if [[ $first -eq 1 ]]; then
            printf '%s' "${output_lines[$i]}"
            first=0
        else
            printf '\n%s' "${output_lines[$i]}"
        fi
    done
    if [[ $has_trailing_newline -eq 1 ]]; then
        printf '\n'
    fi
    return 0
}

# -----------------------------------------------------------------------------
# _apr_template_trim <s>
#
# Trim leading/trailing whitespace (space, tab) from <s>.
# -----------------------------------------------------------------------------
_apr_template_trim() {
    local s="${1-}"
    # Leading.
    while [[ "$s" == [[:space:]]* ]]; do
        s="${s#?}"
    done
    # Trailing.
    while [[ "$s" == *[[:space:]] ]]; do
        s="${s%?}"
    done
    printf '%s' "$s"
}
