#!/usr/bin/env bash
# lib/ledger.sh - APR per-round ledger writer (bd-1xv)
#
# Implements crash-tolerant, atomic ledger writes for the per-round
# provenance record specified in docs/schemas/run-ledger.schema.json
# (bd-246). Writers go through this module so that:
#
#   1. ledger files are created with `state=started` BEFORE oracle is
#      invoked (so even an APR crash leaves a useful trace);
#   2. terminal updates (`finished` / `failed` / `canceled`) rewrite the
#      ledger atomically via tmp-file + rename so readers never observe
#      torn JSON;
#   3. token-like substrings are redacted before persistence so we never
#      leak credentials into commit history.
#
# Public API
# ----------
#   apr_lib_ledger_path <workflow> <round> [<project_root>]
#       Echo the canonical ledger path:
#       <project_root>/.apr/rounds/<workflow>/round_<N>.meta.json
#       Defaults: project_root=.
#
#   apr_lib_ledger_redact <text>
#       Echo <text> with known token patterns replaced by `<REDACTED>`.
#
#   apr_lib_ledger_atomic_write <path> <content>
#       Write <content> to <path> atomically (tmp + rename). Creates
#       parent directories if needed. Applies redaction before write.
#       Returns 0 on success, non-zero on failure.
#
#   apr_lib_ledger_build_started <workflow> <round> <slug> <run_id>
#                                <started_at> <files_json> <prompt_hash>
#                                <engine> <model>
#       Echo a JSON document representing the `state=started` ledger.
#       Optional fields are supplied via these environment variables
#       before the call (so the call site doesn't need to take 15
#       positional args):
#           APR_LEDGER_THINKING_TIME   (default: null)
#           APR_LEDGER_REMOTE_HOST     (default: null)
#           APR_LEDGER_ORACLE_FLAGS    (JSON array string, default: [])
#           APR_LEDGER_MANIFEST_HASH   (default: null)
#
#   apr_lib_ledger_build_finished <workflow> <round> <slug> <run_id>
#                                 <started_at> <finished_at> <state>
#                                 <files_json> <prompt_hash> <engine>
#                                 <model> <code> <exit_code>
#                                 <output_path> <retries_count>
#                                 <busy_wait_count> <busy_wait_total_ms>
#       Echo a JSON document for the terminal-state ledger. Same env-var
#       knobs apply, plus:
#           APR_LEDGER_WARNINGS_JSON   (JSON array string, default: [])
#           APR_LEDGER_OVERRIDES_JSON  (JSON array string, default: [])
#
#   apr_lib_ledger_write_start  <path> <json_document>
#   apr_lib_ledger_write_finish <path> <json_document>
#       Convenience wrappers around `_atomic_write` that simply route the
#       caller's JSON through redaction and persistence. Kept as two
#       distinct names so callers (and reviewers) read clearly.

# Guard against double-sourcing.
if [[ "${_APR_LIB_LEDGER_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_LEDGER_LOADED=1

_APR_LIB_LEDGER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_LEDGER_DIR/manifest.sh"

# -----------------------------------------------------------------------------
# apr_lib_ledger_path
# -----------------------------------------------------------------------------
apr_lib_ledger_path() {
    local workflow="${1:?workflow required}"
    local round="${2:?round required}"
    local project_root="${3:-.}"
    printf '%s/.apr/rounds/%s/round_%s.meta.json' \
        "$project_root" "$workflow" "$round"
}

# -----------------------------------------------------------------------------
# apr_lib_ledger_redact <text>
#
# Strip well-known credential patterns. Conservative on purpose — we only
# replace patterns that are unambiguously secrets:
#
#   - Bearer / Basic Authorization tokens
#   - OpenAI-style sk-... tokens
#   - GitHub PAT prefixes (ghp_, gho_, ghu_, ghs_, ghr_)
#   - "Authorization: <something>" header values
#   - `--token <something>` / `--api-key <something>` CLI arg shapes
#   - `password=<something>` / `secret=<something>` form fields
#
# Replacement is always the literal `<REDACTED>` so consumers can grep for
# it. Replacement is byte-deterministic — same input always yields the
# same output.
# -----------------------------------------------------------------------------
apr_lib_ledger_redact() {
    local text="${1-}"
    # sed -E patterns. Sed is part of the existing dependency set used by
    # apr; available on every POSIX system we target.
    #
    # NOTE: order matters. More specific patterns must come before
    # broader ones.
    printf '%s' "$text" | sed -E \
        -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._\-]+/\1<REDACTED>/g' \
        -e 's/(Basic[[:space:]]+)[A-Za-z0-9+/=._\-]+/\1<REDACTED>/g' \
        -e 's/sk-[A-Za-z0-9_-]{20,}/sk-<REDACTED>/g' \
        -e 's/gh[posur]_[A-Za-z0-9_-]{20,}/gh_<REDACTED>/g' \
        -e 's/("Authorization"[[:space:]]*:[[:space:]]*")[^"]+(")/\1<REDACTED>\2/g' \
        -e 's/(--token[[:space:]]+)[^[:space:]]+/\1<REDACTED>/g' \
        -e 's/(--token=)[^[:space:]&]+/\1<REDACTED>/g' \
        -e 's/(--api-key[[:space:]]+)[^[:space:]]+/\1<REDACTED>/g' \
        -e 's/(--api-key=)[^[:space:]&]+/\1<REDACTED>/g' \
        -e 's/(password=)[^[:space:]&]+/\1<REDACTED>/g' \
        -e 's/(secret=)[^[:space:]&]+/\1<REDACTED>/g'
}

# -----------------------------------------------------------------------------
# apr_lib_ledger_atomic_write <path> <content>
#
# Write <content> to <path> using a tmp-file + rename pattern so readers
# never see a partial file. Parent directories are created as needed.
# Redaction is applied to <content> before writing.
# -----------------------------------------------------------------------------
apr_lib_ledger_atomic_write() {
    local path="${1:?path required}"
    local content="${2-}"

    local dir
    dir=$(dirname -- "$path")
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        return 1
    fi

    # Tmp must live in the SAME directory so the rename is guaranteed
    # atomic on POSIX (cross-filesystem renames are not atomic).
    local tmp="${path}.tmp.$$"
    local redacted
    redacted=$(apr_lib_ledger_redact "$content")
    # Use printf rather than echo to avoid byte-level surprises.
    if ! printf '%s' "$redacted" > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -f -- "$tmp" "$path" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Internal: emit a JSON property line with proper escaping.
# Usage: _apr_ledger_str_prop <key> <value> [<trailing-comma>=1]
# Emits:  "<key>":"<escaped-value>"[,]
# -----------------------------------------------------------------------------
_apr_ledger_str_prop() {
    local key="$1" value="$2" trailing="${3:-1}"
    local k_esc v_esc
    k_esc=$(apr_lib_manifest_json_escape "$key")
    v_esc=$(apr_lib_manifest_json_escape "$value")
    if [[ "$trailing" == "1" ]]; then
        printf '"%s":"%s",' "$k_esc" "$v_esc"
    else
        printf '"%s":"%s"' "$k_esc" "$v_esc"
    fi
}

# Emit a raw (non-string-escaped) property — caller must ensure the value
# is valid JSON (number, bool, null, object, or array).
# Usage: _apr_ledger_raw_prop <key> <raw_json_value> [<trailing-comma>=1]
_apr_ledger_raw_prop() {
    local key="$1" raw="$2" trailing="${3:-1}"
    local k_esc
    k_esc=$(apr_lib_manifest_json_escape "$key")
    if [[ "$trailing" == "1" ]]; then
        printf '"%s":%s,' "$k_esc" "$raw"
    else
        printf '"%s":%s' "$k_esc" "$raw"
    fi
}

# -----------------------------------------------------------------------------
# Internal: emit the shared `oracle` object.
# -----------------------------------------------------------------------------
_apr_ledger_oracle_object() {
    local engine="$1" model="$2"
    local thinking_time="${APR_LEDGER_THINKING_TIME:-null}"
    local remote_host="${APR_LEDGER_REMOTE_HOST:-null}"
    local flags="${APR_LEDGER_ORACLE_FLAGS:-[]}"
    printf '{'
    _apr_ledger_str_prop "engine" "$engine" 1
    _apr_ledger_str_prop "model" "$model" 1
    # thinking_time may be a quoted string OR null. Treat the literal
    # word "null" as raw JSON, otherwise quote it.
    if [[ "$thinking_time" == "null" ]]; then
        _apr_ledger_raw_prop "thinking_time" "null" 1
    else
        _apr_ledger_str_prop "thinking_time" "$thinking_time" 1
    fi
    if [[ "$remote_host" == "null" ]]; then
        _apr_ledger_raw_prop "remote_host" "null" 1
    else
        _apr_ledger_str_prop "remote_host" "$remote_host" 1
    fi
    _apr_ledger_raw_prop "oracle_flags_used" "$flags" 0
    printf '}'
}

# -----------------------------------------------------------------------------
# apr_lib_ledger_build_started
# -----------------------------------------------------------------------------
apr_lib_ledger_build_started() {
    local workflow="${1:?workflow required}"
    local round="${2:?round required}"
    local slug="${3:?slug required}"
    local run_id="${4:?run_id required}"
    local started_at="${5:?started_at required}"
    local files_json="${6:-[]}"
    local prompt_hash="${7:?prompt_hash required}"
    local engine="${8:?engine required}"
    local model="${9:?model required}"

    local manifest_hash="${APR_LEDGER_MANIFEST_HASH:-null}"
    local oracle_obj
    oracle_obj=$(_apr_ledger_oracle_object "$engine" "$model")

    printf '{'
    _apr_ledger_str_prop "schema_version" "apr_run_ledger.v1" 1
    _apr_ledger_str_prop "workflow" "$workflow" 1
    _apr_ledger_raw_prop "round" "$round" 1
    _apr_ledger_str_prop "slug" "$slug" 1
    _apr_ledger_str_prop "run_id" "$run_id" 1
    _apr_ledger_str_prop "started_at" "$started_at" 1
    _apr_ledger_raw_prop "finished_at" "null" 1
    _apr_ledger_raw_prop "duration_ms" "null" 1
    _apr_ledger_str_prop "state" "started" 1
    _apr_ledger_raw_prop "files" "$files_json" 1
    _apr_ledger_str_prop "prompt_hash" "$prompt_hash" 1
    if [[ "$manifest_hash" == "null" ]]; then
        _apr_ledger_raw_prop "manifest_hash" "null" 1
    else
        _apr_ledger_str_prop "manifest_hash" "$manifest_hash" 1
    fi
    _apr_ledger_raw_prop "oracle" "$oracle_obj" 1
    # In-flight outcome.
    printf '"outcome":{'
    _apr_ledger_raw_prop "ok" "false" 1
    _apr_ledger_str_prop "code" "running" 1
    _apr_ledger_raw_prop "exit_code" "null" 1
    _apr_ledger_raw_prop "output_path" "null" 0
    printf '},'
    # Execution counters all start at zero.
    printf '"execution":{"retries_count":0,"busy_wait_count":0,"busy_wait_total_ms":0}'
    printf '}'
}

# -----------------------------------------------------------------------------
# apr_lib_ledger_build_finished
# -----------------------------------------------------------------------------
apr_lib_ledger_build_finished() {
    local workflow="${1:?workflow required}"
    local round="${2:?round required}"
    local slug="${3:?slug required}"
    local run_id="${4:?run_id required}"
    local started_at="${5:?started_at required}"
    local finished_at="${6:?finished_at required}"
    local state="${7:?state required}"
    local files_json="${8:-[]}"
    local prompt_hash="${9:?prompt_hash required}"
    local engine="${10:?engine required}"
    local model="${11:?model required}"
    local code="${12:?code required}"
    local exit_code="${13:-0}"
    local output_path="${14:-}"
    local retries_count="${15:-0}"
    local busy_wait_count="${16:-0}"
    local busy_wait_total_ms="${17:-0}"

    local manifest_hash="${APR_LEDGER_MANIFEST_HASH:-null}"
    local warnings="${APR_LEDGER_WARNINGS_JSON:-[]}"
    local overrides="${APR_LEDGER_OVERRIDES_JSON:-[]}"
    local oracle_obj
    oracle_obj=$(_apr_ledger_oracle_object "$engine" "$model")

    # Compute duration_ms via date arithmetic (epoch seconds * 1000 + ms
    # placeholder). The caller already has both timestamps; we keep it
    # simple by parsing them as epoch seconds when possible. If date
    # parsing fails (e.g. on macOS without GNU date), duration is 0.
    local dur=0
    local s_epoch f_epoch
    if s_epoch=$(date -u -d "$started_at" +%s 2>/dev/null) && \
       f_epoch=$(date -u -d "$finished_at" +%s 2>/dev/null); then
        dur=$(( (f_epoch - s_epoch) * 1000 ))
    fi

    # `ok` is true iff state is finished AND code is ok.
    local ok="false"
    if [[ "$state" == "finished" && "$code" == "ok" ]]; then
        ok="true"
    fi

    printf '{'
    _apr_ledger_str_prop "schema_version" "apr_run_ledger.v1" 1
    _apr_ledger_str_prop "workflow" "$workflow" 1
    _apr_ledger_raw_prop "round" "$round" 1
    _apr_ledger_str_prop "slug" "$slug" 1
    _apr_ledger_str_prop "run_id" "$run_id" 1
    _apr_ledger_str_prop "started_at" "$started_at" 1
    _apr_ledger_str_prop "finished_at" "$finished_at" 1
    _apr_ledger_raw_prop "duration_ms" "$dur" 1
    _apr_ledger_str_prop "state" "$state" 1
    _apr_ledger_raw_prop "files" "$files_json" 1
    _apr_ledger_str_prop "prompt_hash" "$prompt_hash" 1
    if [[ "$manifest_hash" == "null" ]]; then
        _apr_ledger_raw_prop "manifest_hash" "null" 1
    else
        _apr_ledger_str_prop "manifest_hash" "$manifest_hash" 1
    fi
    _apr_ledger_raw_prop "oracle" "$oracle_obj" 1
    # Outcome.
    printf '"outcome":{'
    _apr_ledger_raw_prop "ok" "$ok" 1
    _apr_ledger_str_prop "code" "$code" 1
    _apr_ledger_raw_prop "exit_code" "$exit_code" 1
    if [[ -z "$output_path" ]]; then
        _apr_ledger_raw_prop "output_path" "null" 0
    else
        _apr_ledger_str_prop "output_path" "$output_path" 0
    fi
    printf '},'
    # Execution.
    printf '"execution":{"retries_count":%s,"busy_wait_count":%s,"busy_wait_total_ms":%s},' \
        "$retries_count" "$busy_wait_count" "$busy_wait_total_ms"
    # Warnings + overrides arrays (raw JSON pass-through).
    _apr_ledger_raw_prop "warnings" "$warnings" 1
    _apr_ledger_raw_prop "overrides" "$overrides" 0
    printf '}'
}

# -----------------------------------------------------------------------------
# Convenience wrappers (build + write).
# -----------------------------------------------------------------------------
apr_lib_ledger_write_start() {
    local path="${1:?path required}"
    local content="${2:?content required}"
    apr_lib_ledger_atomic_write "$path" "$content"
}

apr_lib_ledger_write_finish() {
    local path="${1:?path required}"
    local content="${2:?content required}"
    apr_lib_ledger_atomic_write "$path" "$content"
}
