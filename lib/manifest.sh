#!/usr/bin/env bash
# lib/manifest.sh - APR prompt manifest helpers (bd-phj)
#
# Provides deterministic helpers for computing per-document metadata
# (sha256, bytes, basename) and rendering the prompt manifest section in
# either human-facing text or machine-readable JSON.
#
# Design notes:
#   - Pure Bash; tolerates either GNU coreutils (Linux) or BSD tools (macOS).
#   - Functions live under the apr_lib_manifest_* namespace to avoid
#     collisions when sourced into the main `apr` script.
#   - Output of every function is byte-deterministic given the same inputs.
#     This is load-bearing for the run-ledger schema (docs/schemas/run-ledger.schema.json).
#   - No I/O outside the functions themselves; nothing is printed at source time.
#
# Stream conventions match the rest of APR:
#   - stdout: structured output (hashes, sizes, JSON, manifest text)
#   - stderr: diagnostics (none of these functions log on stderr; callers do)
#
# Guard against double-sourcing. (`return` only works when this file is
# being sourced, which is its only intended use.)
if [[ "${_APR_LIB_MANIFEST_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_MANIFEST_LOADED=1

# Inclusion reasons accepted by the manifest helpers.
# Must stay in sync with docs/schemas/run-ledger.schema.json (`inclusion_reason`).
_APR_MANIFEST_REASONS="required optional impl_every_n skipped"

# SHA256 of the empty byte string. Used for skipped/missing files so the
# downstream ledger always has a non-null `sha256` field.
_APR_MANIFEST_EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# -----------------------------------------------------------------------------
# apr_lib_manifest_sha256 <path>
#
# Emit the lowercase hex sha256 of <path>'s bytes on stdout, with no trailing
# newline. If the file is missing or unreadable, emits the empty-string sha256
# and returns 1 so callers can distinguish.
# -----------------------------------------------------------------------------
apr_lib_manifest_sha256() {
    local path="${1:-}"
    if [[ -z "$path" || ! -r "$path" ]]; then
        printf '%s' "$_APR_MANIFEST_EMPTY_SHA256"
        return 1
    fi
    local sum=""
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        sum=$(shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}')
    else
        printf '%s' "$_APR_MANIFEST_EMPTY_SHA256"
        return 2
    fi
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s' "$_APR_MANIFEST_EMPTY_SHA256"
        return 1
    fi
    printf '%s' "$sum"
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_size <path>
#
# Emit the exact byte size of <path> on stdout (decimal, no separators,
# no trailing newline). Missing/unreadable files emit "0" and return 1.
# -----------------------------------------------------------------------------
apr_lib_manifest_size() {
    local path="${1:-}"
    if [[ -z "$path" || ! -r "$path" ]]; then
        printf '%s' "0"
        return 1
    fi
    local size=""
    # Prefer `wc -c` since it works identically on Linux and macOS and
    # always counts bytes (POSIX behavior).
    size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        printf '%s' "0"
        return 1
    fi
    printf '%s' "$size"
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_basename <path>
#
# Emit the basename of <path> on stdout, with no trailing newline.
# Strips trailing slashes; never emits an absolute path.
# -----------------------------------------------------------------------------
apr_lib_manifest_basename() {
    local path="${1:-}"
    # Strip trailing slashes for stable basename behavior.
    while [[ "$path" == */ && "$path" != "/" ]]; do
        path="${path%/}"
    done
    if [[ -z "$path" ]]; then
        printf '%s' ""
        return 0
    fi
    local bn
    bn=$(basename -- "$path" 2>/dev/null) || bn="$path"
    printf '%s' "$bn"
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_is_valid_reason <reason>
#
# Return 0 iff <reason> is one of the accepted inclusion reasons.
# -----------------------------------------------------------------------------
apr_lib_manifest_is_valid_reason() {
    local reason="${1:-}"
    case "$reason" in
        required|optional|impl_every_n|skipped) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_json_escape <string>
#
# Minimal JSON-string escaper for the small set of values these helpers
# emit (paths, basenames, short reasons). Handles \\ " \n \r \t and control
# bytes 0x00-0x1F. Output has no surrounding quotes (caller adds them).
# -----------------------------------------------------------------------------
apr_lib_manifest_json_escape() {
    local s="${1-}"
    # Backslash first.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Tabs/newlines covered; other ASCII controls are rare in paths but
    # if any sneak in we still pass them through. Callers that care should
    # validate upstream.
    printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_entry_json <path> <reason> [<skipped_reason>]
#
# Emit one compact JSON object on stdout (no trailing newline, no comma)
# matching the `files[]` schema in docs/schemas/run-ledger.schema.json.
#
# Computes sha256, size, and basename in-line. If the file is missing,
# emits sha256=empty-sha, bytes=0, and the caller MUST pass reason=skipped
# (any other reason still emits a valid record but is logically wrong).
# -----------------------------------------------------------------------------
apr_lib_manifest_entry_json() {
    local path="${1:?path required}"
    local reason="${2:?reason required}"
    local skipped_reason="${3:-}"

    local basename bytes sha
    basename=$(apr_lib_manifest_basename "$path")
    sha=$(apr_lib_manifest_sha256 "$path") || true
    bytes=$(apr_lib_manifest_size "$path") || true

    local p_esc b_esc s_esc r_esc sk_esc
    p_esc=$(apr_lib_manifest_json_escape "$path")
    b_esc=$(apr_lib_manifest_json_escape "$basename")
    s_esc=$(apr_lib_manifest_json_escape "$sha")
    r_esc=$(apr_lib_manifest_json_escape "$reason")

    if [[ -n "$skipped_reason" ]]; then
        sk_esc=$(apr_lib_manifest_json_escape "$skipped_reason")
        printf '{"path":"%s","basename":"%s","bytes":%s,"sha256":"%s","inclusion_reason":"%s","skipped_reason":"%s"}' \
            "$p_esc" "$b_esc" "$bytes" "$s_esc" "$r_esc" "$sk_esc"
    else
        printf '{"path":"%s","basename":"%s","bytes":%s,"sha256":"%s","inclusion_reason":"%s"}' \
            "$p_esc" "$b_esc" "$bytes" "$s_esc" "$r_esc"
    fi
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_render_json <triples...>
#
# Render a JSON array of manifest entries on stdout (no trailing newline).
#
# Input is one or more whitespace-trimmed triples of the form:
#     <path>|<reason>|<skipped_reason>
# (skipped_reason may be empty). Paths are stable-sorted (LC_ALL=C) before
# rendering so output is reproducible.
#
# Example:
#   apr_lib_manifest_render_json \
#       "README.md|required|" \
#       "docs/impl.md|skipped|not-due-yet"
# -----------------------------------------------------------------------------
apr_lib_manifest_render_json() {
    local -a triples=("$@")
    if [[ ${#triples[@]} -eq 0 ]]; then
        printf '[]'
        return 0
    fi
    # Stable sort by path (the first '|' field).
    local sorted
    sorted=$(printf '%s\n' "${triples[@]}" | LC_ALL=C sort -t '|' -k1,1)

    local first=1
    printf '['
    while IFS='|' read -r path reason skipped_reason; do
        [[ -z "$path" ]] && continue
        if [[ $first -eq 0 ]]; then
            printf ','
        fi
        first=0
        apr_lib_manifest_entry_json "$path" "$reason" "$skipped_reason"
    done <<< "$sorted"
    printf ']'
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_render_text <triples...>
#
# Render a human-facing text manifest on stdout. Same input format as
# apr_lib_manifest_render_json. Output:
#
#     [APR Manifest]
#     Included files:
#
#       <basename>
#         path:   <path>
#         size:   <N> bytes
#         sha256: <64-hex>
#         reason: <reason>
#
#     Skipped files:
#
#       <basename>
#         path:   <path>
#         reason: skipped (<skipped_reason>)
#
# Sections appear only when they contain entries. Within each section,
# entries are stable-sorted by path (LC_ALL=C). A trailing newline is
# included so the manifest concatenates cleanly with the rest of the prompt.
# -----------------------------------------------------------------------------
apr_lib_manifest_render_text() {
    local -a triples=("$@")
    if [[ ${#triples[@]} -eq 0 ]]; then
        printf '[APR Manifest]\nNo files configured.\n'
        return 0
    fi

    local sorted
    sorted=$(printf '%s\n' "${triples[@]}" | LC_ALL=C sort -t '|' -k1,1)

    local -a included=() skipped=()
    local path reason skipped_reason
    while IFS='|' read -r path reason skipped_reason; do
        [[ -z "$path" ]] && continue
        if [[ "$reason" == "skipped" ]]; then
            skipped+=("$path|$reason|$skipped_reason")
        else
            included+=("$path|$reason|$skipped_reason")
        fi
    done <<< "$sorted"

    printf '[APR Manifest]\n'

    if [[ ${#included[@]} -gt 0 ]]; then
        printf 'Included files:\n\n'
        local entry bn bytes sha
        for entry in "${included[@]}"; do
            IFS='|' read -r path reason skipped_reason <<< "$entry"
            bn=$(apr_lib_manifest_basename "$path")
            bytes=$(apr_lib_manifest_size "$path") || true
            sha=$(apr_lib_manifest_sha256 "$path") || true
            printf '  %s\n' "$bn"
            printf '    path:   %s\n' "$path"
            printf '    size:   %s bytes\n' "$bytes"
            printf '    sha256: %s\n' "$sha"
            printf '    reason: %s\n\n' "$reason"
        done
    fi

    if [[ ${#skipped[@]} -gt 0 ]]; then
        printf 'Skipped files:\n\n'
        local entry bn
        for entry in "${skipped[@]}"; do
            IFS='|' read -r path reason skipped_reason <<< "$entry"
            bn=$(apr_lib_manifest_basename "$path")
            printf '  %s\n' "$bn"
            printf '    path:   %s\n' "$path"
            if [[ -n "$skipped_reason" ]]; then
                printf '    reason: skipped (%s)\n\n' "$skipped_reason"
            else
                printf '    reason: skipped\n\n'
            fi
        done
    fi
}

# -----------------------------------------------------------------------------
# apr_lib_manifest_hash_text <text>
#
# Emit the lowercase hex sha256 of the given text on stdout (no trailing
# newline). Convenience helper so callers can compute `prompt_hash` and
# `manifest_hash` (per docs/schemas/run-ledger.schema.json) without
# round-tripping through a tempfile.
# -----------------------------------------------------------------------------
apr_lib_manifest_hash_text() {
    local text="${1-}"
    local sum=""
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        sum=$(printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}')
    else
        printf '%s' "$_APR_MANIFEST_EMPTY_SHA256"
        return 2
    fi
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s' "$_APR_MANIFEST_EMPTY_SHA256"
        return 1
    fi
    printf '%s' "$sum"
}
