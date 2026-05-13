#!/usr/bin/env bash
# lib/busy.sh - APR "oracle is busy" detection (bd-3pu)
#
# Detects whether an oracle run terminated because the upstream provider
# (ChatGPT browser session, etc.) was single-flighted by another caller.
# Used to decide between "fail this round" and "wait/backoff/retry"
# (bd-3du, bd-2kd).
#
# This module is detection-only. The wait/backoff loop is implemented
# elsewhere; this file's contract is:
#
#   apr_lib_busy_detect_text "<captured-stderr-and-stdout>"
#       -> exit 0 iff busy was matched, 1 otherwise.
#
#   apr_lib_busy_detect_file "<path-to-log>"
#       -> same contract but reads from a file.
#
#   apr_lib_busy_describe_text "<captured-stderr-and-stdout>"
#       -> always exit 0; emits one-line JSON describing the match
#          (signature name + the matched line, truncated to 200 chars)
#          or {"busy":false} if no match.
#
# Design priorities:
#   1. Never misclassify a non-busy error as busy (would cause infinite waits).
#   2. Catch the documented oracle busy signatures (see _APR_BUSY_PATTERNS).
#   3. Pure Bash regex; no external runtime beyond awk/grep already in apr.
#
# Guard against double-sourcing.
if [[ "${_APR_LIB_BUSY_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_BUSY_LOADED=1

# Canonical taxonomy code used downstream (matches `busy` in apr's robot
# `code` enum). Exposed as a constant so callers don't hard-code strings.
# shellcheck disable=SC2034
APR_LIB_BUSY_CODE="busy"
export APR_LIB_BUSY_CODE

# -----------------------------------------------------------------------------
# Busy signature catalog
# -----------------------------------------------------------------------------
# Each signature is:
#   <name>|<bash-ERE>
# Regexes are applied **line-by-line** (so `^` and `$` mean start/end of
# line). They use explicit boundary character classes — `[^[:alnum:]_]`
# and the line anchors — rather than `\b`, which is a GNU extension and
# not portable across POSIX ERE.
#
# Patterns are case-insensitive via explicit `[Bb][Uu][Ss][Yy]` runs so we
# don't have to toggle `shopt nocasematch` (which leaks into the calling
# script).
#
# Adding a new signature: add to this array, add a corresponding positive
# fixture under tests/fixtures/busy/, and (if the signature could plausibly
# false-match unrelated text) add a negative fixture too.
_APR_BUSY_SIGNATURES=(
    # `ERROR: busy` at the start of a line, with optional leading whitespace
    # and optional trailing context. Catches the common oracle short-circuit.
    'error_busy_prefix|^[[:space:]]*[Ee][Rr][Rr][Oo][Rr]:[[:space:]]*[Bb][Uu][Ss][Yy]([[:space:]]|[.,;:!]|$)'

    # `User error (browser-automation): busy` and similar
    # `User error (<anything>): busy` shapes oracle is known to emit.
    'user_error_parens_busy|[Uu]ser[[:space:]]+error[[:space:]]*\([^)]*\)[[:space:]]*:[[:space:]]*[Bb][Uu][Ss][Yy]([[:space:]]|[.,;:!]|$)'

    # Standalone phrase "oracle is busy" / "browser is busy" / "session is busy".
    # Boundary on the left: line start OR a non-identifier char. Boundary on
    # the right: line end OR a non-identifier char. This excludes "busylight",
    # "busy_loop", "busyness". Subject keywords are matched case-insensitively
    # via explicit char classes (avoids leaky shopt nocasematch).
    'subject_is_busy|(^|[^[:alnum:]_])([Oo][Rr][Aa][Cc][Ll][Ee]|[Bb][Rr][Oo][Ww][Ss][Ee][Rr]|[Ss][Ee][Ss][Ss][Ii][Oo][Nn]|[Pp][Rr][Oo][Vv][Ii][Dd][Ee][Rr]|[Cc][Hh][Aa][Tt][Gg][Pp][Tt])[[:space:]]+[Ii][Ss][[:space:]]+[Bb][Uu][Ss][Yy]($|[^[:alnum:]_])'

    # Explicit "retry: busy" or "status: busy" key-value shapes.
    'kv_busy|(^|[[:space:]])(retry|status|state|reason)[[:space:]]*[:=][[:space:]]*[Bb][Uu][Ss][Yy]([[:space:]]|[.,;:!]|$)'
)

# -----------------------------------------------------------------------------
# apr_lib_busy_detect_text <text>
#
# Return 0 iff <text> matches at least one busy signature, else 1.
# Reads <text> as a single argument; intended for the captured-output use
# case (the apr runner already collects stderr/stdout into a variable).
# -----------------------------------------------------------------------------
apr_lib_busy_detect_text() {
    local text="${1-}"
    if [[ -z "$text" ]]; then
        return 1
    fi
    local sig regex line
    for sig in "${_APR_BUSY_SIGNATURES[@]}"; do
        regex="${sig#*|}"
        while IFS= read -r line; do
            if [[ "$line" =~ $regex ]]; then
                return 0
            fi
        done <<< "$text"
    done
    return 1
}

# -----------------------------------------------------------------------------
# apr_lib_busy_detect_file <path>
#
# Same as apr_lib_busy_detect_text but reads from <path>. Returns 1 if the
# file is missing/unreadable (treat as "not busy" rather than error — the
# caller decides what missing-log means).
# -----------------------------------------------------------------------------
apr_lib_busy_detect_file() {
    local path="${1:-}"
    if [[ -z "$path" || ! -r "$path" ]]; then
        return 1
    fi
    local text
    text=$(cat -- "$path" 2>/dev/null) || return 1
    apr_lib_busy_detect_text "$text"
}

# -----------------------------------------------------------------------------
# apr_lib_busy_describe_text <text>
#
# Always returns 0. Emits one line of JSON on stdout:
#   {"busy":true,"signature":"<name>","line":"<first matching line>"}
# or:
#   {"busy":false}
#
# The matched line is truncated to 200 bytes for log hygiene. Quotes,
# backslashes, and control bytes are escaped for JSON safety.
# -----------------------------------------------------------------------------
apr_lib_busy_describe_text() {
    local text="${1-}"
    if [[ -z "$text" ]]; then
        printf '{"busy":false}\n'
        return 0
    fi

    # Try each signature in order; the first to match wins.
    local sig name regex matched_line=""
    for sig in "${_APR_BUSY_SIGNATURES[@]}"; do
        name="${sig%%|*}"
        regex="${sig#*|}"
        # Find the first line that matches this pattern, if any.
        local line
        while IFS= read -r line; do
            if [[ "$line" =~ $regex ]]; then
                matched_line="$line"
                break
            fi
        done <<< "$text"
        if [[ -n "$matched_line" ]]; then
            # Truncate to 200 bytes.
            if [[ ${#matched_line} -gt 200 ]]; then
                matched_line="${matched_line:0:200}"
            fi
            # JSON-escape.
            local esc="$matched_line"
            esc="${esc//\\/\\\\}"
            esc="${esc//\"/\\\"}"
            esc="${esc//$'\n'/\\n}"
            esc="${esc//$'\r'/\\r}"
            esc="${esc//$'\t'/\\t}"
            printf '{"busy":true,"signature":"%s","line":"%s"}\n' "$name" "$esc"
            return 0
        fi
    done

    printf '{"busy":false}\n'
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_busy_describe_file <path>
#
# File-input wrapper for apr_lib_busy_describe_text. Missing/unreadable
# file emits {"busy":false}.
# -----------------------------------------------------------------------------
apr_lib_busy_describe_file() {
    local path="${1:-}"
    if [[ -z "$path" || ! -r "$path" ]]; then
        printf '{"busy":false}\n'
        return 0
    fi
    local text
    text=$(cat -- "$path" 2>/dev/null) || { printf '{"busy":false}\n'; return 0; }
    apr_lib_busy_describe_text "$text"
}

# -----------------------------------------------------------------------------
# apr_lib_busy_robot_data <stderr_text> [<policy>] [<remote_host>]
#                         [<retry_after_ms>] [<queue_entry_id>] [<elapsed_ms>]
#
# Build the .data object for a robot-mode busy response per the
# bd-18u contract (docs/schemas/robot-busy.md). Returns:
#   - 0 with a compact-JSON .data on stdout when busy detected;
#   - 1 with NO output when not busy (caller falls through to its
#     normal error path).
#
# Fields:
#   busy             always true on the success path
#   signature        the bd-3pu signature name that matched
#   line             matched stderr line (200-byte truncated, JSON-escaped)
#   policy           "error" (default) | "wait" | "enqueue"
#   remote_host      string or null (passed in by caller; no introspection)
#   retry_after_ms   int or null
#   queue_entry_id   string or null
#   elapsed_ms       int or null
#
# All optional args default to null when empty.
# -----------------------------------------------------------------------------
apr_lib_busy_robot_data() {
    local text="${1-}"
    local policy="${2:-error}"
    local remote_host="${3-}"
    local retry_after_ms="${4-}"
    local queue_entry_id="${5-}"
    local elapsed_ms="${6-}"

    if [[ -z "$text" ]]; then
        return 1
    fi

    # Reuse the describe helper to find the first matching signature.
    local desc
    desc=$(apr_lib_busy_describe_text "$text")
    case "$desc" in
        *'"busy":true'*) : ;;  # detected
        *) return 1 ;;
    esac

    # Extract signature + line from the describe output. We hand-parse
    # because we control the format above.
    local signature line
    signature="${desc#*\"signature\":\"}"; signature="${signature%%\"*}"
    line="${desc#*\"line\":\"}"; line="${line%\"\}*}"
    # Validate policy.
    case "$policy" in
        error|wait|enqueue) : ;;
        *) policy="error" ;;
    esac

    # Encode optionals: empty -> null, present -> JSON value.
    local rh_json="null"
    [[ -n "$remote_host" ]] && rh_json="\"$(printf '%s' "$remote_host" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    local qe_json="null"
    [[ -n "$queue_entry_id" ]] && qe_json="\"$(printf '%s' "$queue_entry_id" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    local ra_json="null"
    [[ "$retry_after_ms" =~ ^[0-9]+$ ]] && ra_json="$retry_after_ms"
    local el_json="null"
    [[ "$elapsed_ms" =~ ^[0-9]+$ ]] && el_json="$elapsed_ms"

    printf '{"busy":true,"signature":"%s","line":"%s","policy":"%s","remote_host":%s,"retry_after_ms":%s,"queue_entry_id":%s,"elapsed_ms":%s}' \
        "$signature" "$line" "$policy" "$rh_json" "$ra_json" "$qe_json" "$el_json"
    return 0
}
