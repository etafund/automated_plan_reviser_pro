#!/usr/bin/env bash
# lib/redact.sh - APR prompt redaction layer (bd-3ut)
#
# Opt-in, best-effort scrubber that replaces high-signal secret
# patterns with TYPED sentinels (e.g. <<REDACTED:OPENAI_KEY>>) before
# the prompt is rendered, copied, or sent to Oracle. Distinct from
# lib/ledger.sh's redactor which targets ledger PERSISTENCE — this
# module's output IS the prompt the model will see, so the substitution
# must be readable to the model and audit-grep-able.
#
# This is NOT a security guarantee. The pattern set is conservative
# (high-confidence prefixes / well-known shapes) so it doesn't shred
# technical docs that happen to mention tokens. Operators opt in via
# APR_REDACT=1 or an explicit caller flag.
#
# Public API
# ----------
#   apr_lib_redact_prompt <text>
#       Echo <text> with secrets replaced by typed sentinels. Always
#       emits on stdout (even when nothing matched, output equals
#       input). Sets APR_REDACT_COUNT (total redactions performed,
#       integer >= 0) on success. Returns 0 always.
#
#   apr_lib_redact_prompt_assign <variable-name> <text>
#       Assigns the redacted prompt to <variable-name> without a command
#       substitution subshell, preserving APR_REDACT_COUNT and summary
#       counters in the caller.
#
#   apr_lib_redact_summary
#       Echo a compact JSON object summarizing the last redact call:
#         {"total": N, "by_type": {"OPENAI_KEY": N, "PRIVATE_KEY_BLOCK": N, ...}}
#       Useful for the run ledger (bd-1xv) and metrics (bd-2ic).
#
# Sentinel format
# ---------------
# Every replacement uses the literal shape:
#     <<REDACTED:<TYPE>>>
# where <TYPE> is one of (alphabetical):
#   AKIA_KEY              AWS access key id (AKIA-prefix)
#   AUTH_BEARER_TOKEN     Authorization: Bearer ...
#   GITHUB_FINEGRAINED    github_pat_... fine-grained PATs
#   GITHUB_TOKEN          ghp_/gho_/ghu_/ghs_/ghr_ prefixes
#   OPENAI_KEY            sk-...
#   PRIVATE_KEY_BLOCK     -----BEGIN <type> PRIVATE KEY----- ... -----END ... PRIVATE KEY-----
#   SLACK_TOKEN           xox[bpars]-...
#
# Determinism: identical input -> identical output, byte-for-byte.

if [[ "${_APR_LIB_REDACT_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_REDACT_LOADED=1

# Per-type and total counters, reset on every apr_lib_redact_prompt call.
APR_REDACT_COUNT=0
declare -A _APR_REDACT_BY_TYPE=()
export APR_REDACT_COUNT

# -----------------------------------------------------------------------------
# Internal: reset counters at the start of each redaction call.
# -----------------------------------------------------------------------------
_apr_redact_reset() {
    APR_REDACT_COUNT=0
    unset _APR_REDACT_BY_TYPE
    declare -gA _APR_REDACT_BY_TYPE=()
}

# -----------------------------------------------------------------------------
# Internal: count how many of <pattern> appear in <text>. Uses grep -c
# with -E (extended regex). Returns 0 (count) on stdout.
# -----------------------------------------------------------------------------
_apr_redact_count() {
    local text="$1" pattern="$2"
    local n
    n=$(printf '%s' "$text" | grep -Ec "$pattern" 2>/dev/null || printf '0')
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    # grep -c counts matching LINES. For multi-line keys we sometimes
    # want the number of MATCHES; for our high-signal patterns the
    # difference is negligible (one match per line is the rule). For
    # the multi-line PRIVATE_KEY_BLOCK case we count BEGIN-headers as a
    # proxy.
    printf '%s' "$n"
}

# -----------------------------------------------------------------------------
# Internal: increment _APR_REDACT_BY_TYPE[$1] by $2.
# -----------------------------------------------------------------------------
_apr_redact_bump() {
    local type="$1" by="${2:-0}"
    [[ "$by" =~ ^[0-9]+$ ]] || by=0
    local cur="${_APR_REDACT_BY_TYPE[$type]:-0}"
    _APR_REDACT_BY_TYPE[$type]=$(( cur + by ))
    APR_REDACT_COUNT=$(( APR_REDACT_COUNT + by ))
}

# -----------------------------------------------------------------------------
# apr_lib_redact_prompt_assign <variable-name> <text>
# -----------------------------------------------------------------------------
apr_lib_redact_prompt_assign() {
    local target="${1-}"
    local text="${2-}"
    if [[ ! "$target" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        return 2
    fi

    _apr_redact_reset

    # Multi-line PRIVATE KEY blocks. Count BEGIN headers as the proxy
    # for "blocks redacted" before substitution.
    local pk_count
    pk_count=$(printf '%s' "$text" | grep -Ec '^-----BEGIN [A-Z][A-Z ]*PRIVATE KEY-----' 2>/dev/null || printf '0')
    [[ "$pk_count" =~ ^[0-9]+$ ]] || pk_count=0

    # Single-line pattern counts BEFORE we substitute.
    local openai_n github_n ghpat_n slack_n akia_n auth_n
    openai_n=$(_apr_redact_count "$text" 'sk-[A-Za-z0-9_-]{20,}')
    github_n=$(_apr_redact_count "$text" 'gh[posur]_[A-Za-z0-9_-]{20,}')
    ghpat_n=$(_apr_redact_count "$text" 'github_pat_[A-Za-z0-9_]{20,}')
    slack_n=$(_apr_redact_count "$text" 'xox[bpars]-[A-Za-z0-9-]{10,}')
    akia_n=$(_apr_redact_count "$text" '\bAKIA[0-9A-Z]{16}\b')
    auth_n=$(_apr_redact_count "$text" 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]+')

    # Apply substitutions. Order matters only when patterns could
    # overlap; for the prefix-anchored set above they don't.
    # Use awk for the multi-line PRIVATE KEY block — we walk lines and
    # replace everything between BEGIN/END markers with a single
    # sentinel line.
    local out
    out=$(printf '%s' "$text" | awk '
        BEGIN { in_block=0 }
        /^-----BEGIN [A-Z][A-Z ]*PRIVATE KEY-----/ {
            if (!in_block) { print "<<REDACTED:PRIVATE_KEY_BLOCK>>"; in_block=1 }
            next
        }
        /^-----END [A-Z][A-Z ]*PRIVATE KEY-----/ {
            in_block=0
            next
        }
        in_block { next }
        { print }
    ')

    # Single-line patterns via sed.
    out=$(printf '%s' "$out" | sed -E \
        -e 's/sk-[A-Za-z0-9_-]{20,}/<<REDACTED:OPENAI_KEY>>/g' \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/<<REDACTED:GITHUB_FINEGRAINED>>/g' \
        -e 's/gh[posur]_[A-Za-z0-9_-]{20,}/<<REDACTED:GITHUB_TOKEN>>/g' \
        -e 's/xox[bpars]-[A-Za-z0-9-]{10,}/<<REDACTED:SLACK_TOKEN>>/g' \
        -e 's/\bAKIA[0-9A-Z]{16}\b/<<REDACTED:AKIA_KEY>>/g' \
        -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1<<REDACTED:AUTH_BEARER_TOKEN>>/g')

    # Bump counters AFTER substitution counts are stable.
    _apr_redact_bump PRIVATE_KEY_BLOCK "$pk_count"
    _apr_redact_bump OPENAI_KEY        "$openai_n"
    _apr_redact_bump GITHUB_FINEGRAINED "$ghpat_n"
    # GitHub PAT prefixes were ALSO matched by the gh*_ pattern; the
    # finegrained matches are a subset of the broader gh*_ counts in
    # rare cases. We rely on grep -c (per-line) and treat the two as
    # independent for reporting purposes.
    _apr_redact_bump GITHUB_TOKEN      "$github_n"
    _apr_redact_bump SLACK_TOKEN       "$slack_n"
    _apr_redact_bump AKIA_KEY          "$akia_n"
    _apr_redact_bump AUTH_BEARER_TOKEN "$auth_n"

    printf -v "$target" '%s' "$out"
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_redact_prompt <text>
# -----------------------------------------------------------------------------
apr_lib_redact_prompt() {
    local out
    apr_lib_redact_prompt_assign out "${1-}" || return $?
    printf '%s' "$out"
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_redact_summary
# -----------------------------------------------------------------------------
apr_lib_redact_summary() {
    local types=(AKIA_KEY AUTH_BEARER_TOKEN GITHUB_FINEGRAINED GITHUB_TOKEN OPENAI_KEY PRIVATE_KEY_BLOCK SLACK_TOKEN)
    local first=1 t n
    printf '{"total":%s,"by_type":{' "${APR_REDACT_COUNT:-0}"
    for t in "${types[@]}"; do
        n="${_APR_REDACT_BY_TYPE[$t]:-0}"
        if [[ "$n" -gt 0 ]]; then
            if [[ $first -eq 0 ]]; then printf ','; fi
            first=0
            printf '"%s":%s' "$t" "$n"
        fi
    done
    printf '}}'
}
