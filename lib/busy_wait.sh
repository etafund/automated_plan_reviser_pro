#!/usr/bin/env bash
# lib/busy_wait.sh - APR busy wait loop policy (bd-3du)
#
# Implements the wait/backoff loop that runs when oracle returns the
# `busy` signal detected by lib/busy.sh (bd-3pu). Used by `apr run`,
# `apr robot run`, and the queue runner (bd-2kd, bd-18u, bd-12b) so that
# single-flight busy state is smoothed rather than instantly failing.
#
# Design summary
# --------------
# Exponential backoff with optional jitter, configurable floor + ceiling,
# optional infinite total wait, and a pluggable "is-busy" probe so the
# caller controls how busy is detected (typically by capturing `oracle
# status` output and passing it through `apr_lib_busy_detect_text`).
#
# This module is pure logic. It NEVER calls oracle directly — the caller
# passes a probe command via `apr_lib_busy_wait_set_probe` (or
# `apr_lib_busy_wait` via the optional positional arg), and that command
# is invoked between sleeps. Time accounting is recorded in three
# globals so the caller can persist them in the run ledger
# (`execution.busy_wait_count`, `execution.busy_wait_total_ms` per
# docs/schemas/run-ledger.schema.json).
#
# Public API
# ----------
#   apr_lib_busy_wait_configure [<key=value>...]
#       Set policy knobs. Known keys (all optional):
#           min_sleep       seconds, floor for the first sleep (default: 5)
#           max_sleep       seconds, ceiling per-iteration sleep (default: 120)
#           multiplier      backoff growth factor (default: 2)
#           jitter          0..100, percent of randomness (default: 25)
#           max_total_wait  seconds, total budget (default: 1800; 0 = infinite)
#           message_every   seconds between operator-visible updates (default: 30)
#       Unknown keys are recorded as warnings on stderr but do not fail.
#
#   apr_lib_busy_wait_set_probe <command>
#       Register a single command string that, when executed, returns
#       exit 0 iff the resource is still busy (i.e. should keep waiting).
#       The command is run via `eval` so callers can compose pipes / args.
#       Example:
#           apr_lib_busy_wait_set_probe \
#               'oracle status --slug "$slug" 2>&1 | apr_lib_busy_detect_text "$(cat)"'
#
#   apr_lib_busy_wait_set_sleep_fn <fn-name>
#       Override the sleep implementation. Defaults to `sleep`. Tests use
#       a no-op stub so the suite finishes in milliseconds.
#
#   apr_lib_busy_wait_set_clock_fn <fn-name>
#       Override the wall-clock epoch source. Defaults to `date +%s`.
#       Tests use a counter to make the loop deterministic.
#
#   apr_lib_busy_wait_set_message_fn <fn-name>
#       Override the operator-message sink. Defaults to printing on
#       stderr with `[apr] ` prefix. Tests use an array accumulator.
#
#   apr_lib_busy_wait
#       Run the loop. Returns 0 when the probe reports "not busy"; returns
#       1 when max_total_wait was exhausted before the probe cleared.
#       Writes timing counters to:
#           APR_BUSY_WAIT_COUNT       (int)
#           APR_BUSY_WAIT_TOTAL_MS    (int)
#           APR_BUSY_WAIT_LAST_REASON ("cleared" or "timeout")
#
# Determinism note: when `jitter > 0` the sleep amount uses $RANDOM. Tests
# can pin the jitter to 0 for byte-deterministic behavior, or pass their
# own sleep stub that ignores the actual seconds.

# Guard against double-sourcing.
if [[ "${_APR_LIB_BUSY_WAIT_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_BUSY_WAIT_LOADED=1

# Policy knobs (defaults).
_APR_BUSY_WAIT_MIN_SLEEP=5
_APR_BUSY_WAIT_MAX_SLEEP=120
_APR_BUSY_WAIT_MULTIPLIER=2
_APR_BUSY_WAIT_JITTER=25
_APR_BUSY_WAIT_MAX_TOTAL=1800
_APR_BUSY_WAIT_MESSAGE_EVERY=30

# Pluggable hooks.
_APR_BUSY_WAIT_PROBE_CMD=""
_APR_BUSY_WAIT_SLEEP_FN="sleep"
_APR_BUSY_WAIT_CLOCK_FN="_apr_busy_wait_default_clock"
_APR_BUSY_WAIT_MESSAGE_FN="_apr_busy_wait_default_message"

# Result globals (re-set on each apr_lib_busy_wait call).
APR_BUSY_WAIT_COUNT=0
APR_BUSY_WAIT_TOTAL_MS=0
APR_BUSY_WAIT_LAST_REASON=""
export APR_BUSY_WAIT_COUNT APR_BUSY_WAIT_TOTAL_MS APR_BUSY_WAIT_LAST_REASON

# -----------------------------------------------------------------------------
# Defaults for pluggable hooks.
# -----------------------------------------------------------------------------
_apr_busy_wait_default_clock() {
    date +%s
}

_apr_busy_wait_default_message() {
    # All operator messages go to stderr with `[apr] ` prefix to match
    # the rest of APR's human output.
    printf '[apr] %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# apr_lib_busy_wait_configure key=value ...
# -----------------------------------------------------------------------------
apr_lib_busy_wait_configure() {
    local arg key val
    for arg in "$@"; do
        key="${arg%%=*}"
        val="${arg#*=}"
        case "$key" in
            min_sleep)      _APR_BUSY_WAIT_MIN_SLEEP="$val" ;;
            max_sleep)      _APR_BUSY_WAIT_MAX_SLEEP="$val" ;;
            multiplier)     _APR_BUSY_WAIT_MULTIPLIER="$val" ;;
            jitter)         _APR_BUSY_WAIT_JITTER="$val" ;;
            max_total_wait) _APR_BUSY_WAIT_MAX_TOTAL="$val" ;;
            message_every)  _APR_BUSY_WAIT_MESSAGE_EVERY="$val" ;;
            *)
                printf '[apr] busy_wait_configure: unknown key "%s"\n' "$key" >&2
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Hook setters.
# -----------------------------------------------------------------------------
apr_lib_busy_wait_set_probe()      { _APR_BUSY_WAIT_PROBE_CMD="${1-}"; }
apr_lib_busy_wait_set_sleep_fn()   { _APR_BUSY_WAIT_SLEEP_FN="${1-}"; }
apr_lib_busy_wait_set_clock_fn()   { _APR_BUSY_WAIT_CLOCK_FN="${1-}"; }
apr_lib_busy_wait_set_message_fn() { _APR_BUSY_WAIT_MESSAGE_FN="${1-}"; }

# -----------------------------------------------------------------------------
# Internal: compute the next sleep amount based on the iteration index.
# Iteration 0 returns min_sleep. Subsequent iterations multiply by
# multiplier^iter, capped at max_sleep, then perturbed by jitter%.
#
# Stdout: integer seconds to sleep.
# -----------------------------------------------------------------------------
_apr_busy_wait_compute_sleep() {
    local iter="$1"
    local base="$_APR_BUSY_WAIT_MIN_SLEEP"
    local cap="$_APR_BUSY_WAIT_MAX_SLEEP"
    local mult="$_APR_BUSY_WAIT_MULTIPLIER"
    local jitter_pct="$_APR_BUSY_WAIT_JITTER"

    # Compute base * multiplier^iter without overflow surprises by
    # iterating. Bash arithmetic is fine for the small ints we expect.
    local sleep_s="$base"
    local i=0
    while (( i < iter )); do
        sleep_s=$(( sleep_s * mult ))
        if (( sleep_s >= cap )); then
            sleep_s="$cap"
            break
        fi
        i=$(( i + 1 ))
    done
    if (( sleep_s > cap )); then
        sleep_s="$cap"
    fi

    # Apply jitter as +/- jitter_pct% of sleep_s.
    if (( jitter_pct > 0 )); then
        local jitter_max=$(( (sleep_s * jitter_pct) / 100 ))
        if (( jitter_max > 0 )); then
            # $RANDOM is 0..32767; map into +/- jitter_max.
            local r=$(( (RANDOM % (2 * jitter_max + 1)) - jitter_max ))
            sleep_s=$(( sleep_s + r ))
        fi
        if (( sleep_s < 1 )); then
            sleep_s=1
        fi
    fi

    printf '%s' "$sleep_s"
}

# -----------------------------------------------------------------------------
# Internal: call the probe and return its exit code (0 = still busy,
# non-zero = clear). Probe absence is treated as "not busy" (no-op).
# -----------------------------------------------------------------------------
_apr_busy_wait_probe() {
    if [[ -z "$_APR_BUSY_WAIT_PROBE_CMD" ]]; then
        return 1
    fi
    # `eval` lets callers pass pipes and command substitutions.
    eval "$_APR_BUSY_WAIT_PROBE_CMD"
}

# -----------------------------------------------------------------------------
# apr_lib_busy_wait
#
# Run the loop. See top-of-file docstring for contract.
# -----------------------------------------------------------------------------
apr_lib_busy_wait() {
    APR_BUSY_WAIT_COUNT=0
    APR_BUSY_WAIT_TOTAL_MS=0
    APR_BUSY_WAIT_LAST_REASON=""

    local start_epoch
    start_epoch=$("$_APR_BUSY_WAIT_CLOCK_FN")

    # Operator-visible "we're waiting" banner up front so they don't think
    # APR is hung. Skip if not busy at all.
    if ! _apr_busy_wait_probe; then
        APR_BUSY_WAIT_LAST_REASON="cleared"
        return 0
    fi

    "$_APR_BUSY_WAIT_MESSAGE_FN" "oracle busy; waiting (min ${_APR_BUSY_WAIT_MIN_SLEEP}s, cap ${_APR_BUSY_WAIT_MAX_SLEEP}s, budget ${_APR_BUSY_WAIT_MAX_TOTAL}s)"

    local iter=0
    local last_message_epoch="$start_epoch"

    while :; do
        local sleep_s
        sleep_s=$(_apr_busy_wait_compute_sleep "$iter")

        # Check budget. max_total_wait==0 means unbounded.
        local now elapsed
        now=$("$_APR_BUSY_WAIT_CLOCK_FN")
        elapsed=$(( now - start_epoch ))
        if (( _APR_BUSY_WAIT_MAX_TOTAL > 0 )); then
            if (( elapsed + sleep_s > _APR_BUSY_WAIT_MAX_TOTAL )); then
                # Shrink final sleep to fit, or break if we're already over.
                local remaining=$(( _APR_BUSY_WAIT_MAX_TOTAL - elapsed ))
                if (( remaining <= 0 )); then
                    APR_BUSY_WAIT_LAST_REASON="timeout"
                    "$_APR_BUSY_WAIT_MESSAGE_FN" "oracle busy; timeout after ${elapsed}s (budget ${_APR_BUSY_WAIT_MAX_TOTAL}s)"
                    return 1
                fi
                sleep_s="$remaining"
            fi
        fi

        # Throttled operator update.
        local since_last=$(( now - last_message_epoch ))
        if (( since_last >= _APR_BUSY_WAIT_MESSAGE_EVERY )); then
            "$_APR_BUSY_WAIT_MESSAGE_FN" "still busy; elapsed=${elapsed}s next=${sleep_s}s (oracle serve is single-flight)"
            last_message_epoch="$now"
        fi

        # Sleep.
        "$_APR_BUSY_WAIT_SLEEP_FN" "$sleep_s"

        APR_BUSY_WAIT_COUNT=$(( APR_BUSY_WAIT_COUNT + 1 ))
        APR_BUSY_WAIT_TOTAL_MS=$(( APR_BUSY_WAIT_TOTAL_MS + sleep_s * 1000 ))

        # Re-probe.
        if ! _apr_busy_wait_probe; then
            APR_BUSY_WAIT_LAST_REASON="cleared"
            "$_APR_BUSY_WAIT_MESSAGE_FN" "oracle cleared after ${APR_BUSY_WAIT_COUNT} wait(s), total $(( APR_BUSY_WAIT_TOTAL_MS / 1000 ))s"
            return 0
        fi

        iter=$(( iter + 1 ))
    done
}
