#!/usr/bin/env bash
# lib/queue.sh - APR queue event-log helpers (bd-3fn)
#
# Implements the read-side and append-side primitives for the queue
# event log specified in docs/schemas/queue-events.md.
#
# This module is the data-model foundation. Runner behaviour (bd-12b)
# and CLI surface (bd-18g) build on top.
#
# Stream conventions:
#   - stdout: structured output (JSON state, paths, single-line events)
#   - stderr: diagnostics (lock failures, partial-line warnings)
#
# Public API
# ----------
#   apr_lib_queue_paths <workflow> [<project_root>]
#       Echo two lines on stdout:
#           <events_file>
#           <lock_file>
#       Lets callers grab both paths in one go without re-deriving.
#
#   apr_lib_queue_append <events_file> <event_json>
#       Append <event_json> to <events_file> as one line (with `\n`
#       terminator). Creates the file and its parent directories if
#       needed. Atomic via shell-builtin append (one `write(2)` for
#       small lines under the system PIPE_BUF limit). Callers SHOULD
#       wrap this in `apr_lib_queue_with_lock`.
#
#   apr_lib_queue_with_lock <lock_file> <command...>
#       Acquire an exclusive flock on <lock_file>, run <command...>, then
#       release. Uses a 30s acquire timeout. Falls back to mkdir-locking
#       on systems without `flock`. Returns the command's exit code (or
#       1 on lock-acquire timeout).
#
#   apr_lib_queue_derive <events_file> <entry_id>
#       Read <events_file>, fold events for <entry_id>, emit a compact
#       JSON state document on stdout:
#           {"status":"queued|running|done|failed|canceled|unknown",
#            "round":N, ...}
#       Tolerates a partial trailing line (logs a warning to stderr).
#       Returns 0 on success, 1 if <entry_id> has no events.
#
#   apr_lib_queue_status_summary <events_file>
#       Emit a compact JSON summary of all entries:
#           {"counts":{"queued":N,"running":N,"done":N,"failed":N,"canceled":N},
#            "active":[entry_id,...]}
#
#   apr_lib_queue_next_queued <events_file>
#       Emit the oldest currently queued entry as compact JSON, or return
#       1 when no entry is ready. This is the dequeue selector used by
#       the runner. It folds the full event log first, so entries that
#       were started, finished, failed, or canceled are skipped.
#
#   apr_lib_queue_run_once <events_file> <lock_file> <runner_id> <command...>
#       Acquire the workflow queue lock, pick the oldest queued entry,
#       append a `start` event, run <command...>, then append `finish`
#       or `fail`. The command receives APR_QUEUE_ENTRY_* environment
#       variables. Returns the command exit code; returns 2 when the
#       queue has no queued entries.
#
# Implementation notes
# --------------------
# - We do NOT depend on jq because not every install has it. State
#   derivation uses a single python3 fold (python is required for tests
#   already and is reasonable to assume for the queue runner).
# - When python3 is absent, derive() falls back to a pure-Bash parser
#   that handles the well-formed canonical line shapes — sufficient for
#   the runner's hot path.

if [[ "${_APR_LIB_QUEUE_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_QUEUE_LOADED=1

# -----------------------------------------------------------------------------
# apr_lib_queue_paths
# -----------------------------------------------------------------------------
apr_lib_queue_paths() {
    local workflow="${1:?workflow required}"
    local project_root="${2:-.}"
    printf '%s/.apr/queue/%s.events.jsonl\n' "$project_root" "$workflow"
    printf '%s/.apr/.locks/queue.%s.lock\n'   "$project_root" "$workflow"
}

# -----------------------------------------------------------------------------
# apr_lib_queue_append <events_file> <event_json>
# -----------------------------------------------------------------------------
apr_lib_queue_append() {
    local events_file="${1:?events_file required}"
    local event_json="${2:?event_json required}"
    local dir
    dir=$(dirname -- "$events_file")
    mkdir -p -- "$dir" 2>/dev/null || return 1
    # Single `>>` append; the kernel guarantees atomicity for writes <= PIPE_BUF
    # bytes on regular files (Linux: 4096). Lines longer than that should be
    # serialized through the lock.
    printf '%s\n' "$event_json" >> "$events_file" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_queue_with_lock <lock_file> <command...>
# -----------------------------------------------------------------------------
apr_lib_queue_with_lock() {
    local lock_file="${1:?lock_file required}"
    shift
    local lock_dir
    lock_dir=$(dirname -- "$lock_file")
    mkdir -p -- "$lock_dir" 2>/dev/null || return 1

    if command -v flock >/dev/null 2>&1; then
        # Open fd 9 for the lock file, then block on flock with a 30s timeout.
        # Use a subshell so the fd lifetime is bounded to this critical section.
        (
            exec 9>"$lock_file" || exit 1
            if ! flock -w 30 9; then
                printf '[apr] queue: failed to acquire lock %s within 30s\n' "$lock_file" >&2
                exit 1
            fi
            "$@"
        )
        return $?
    fi

    # Fallback: directory-based mutex. Atomic on every POSIX system.
    local mkdir_lock="${lock_file}.dir"
    local waited=0
    while ! mkdir -- "$mkdir_lock" 2>/dev/null; do
        if (( waited >= 30 )); then
            printf '[apr] queue: failed to acquire mkdir-lock %s within 30s\n' "$mkdir_lock" >&2
            return 1
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    local rc=0
    "$@" || rc=$?
    rmdir -- "$mkdir_lock" 2>/dev/null || true
    return $rc
}

# -----------------------------------------------------------------------------
# apr_lib_queue_derive <events_file> <entry_id>
# -----------------------------------------------------------------------------
apr_lib_queue_derive() {
    local events_file="${1:?events_file required}"
    local entry_id="${2:?entry_id required}"

    if [[ ! -r "$events_file" ]]; then
        printf '{"status":"unknown","entry_id":"%s"}\n' "$entry_id"
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$events_file" "$entry_id" <<'PY'
import json, sys
events_file, entry_id = sys.argv[1], sys.argv[2]
state = {"status": "unknown", "entry_id": entry_id, "events": 0}
found = False
partial = 0
with open(events_file, encoding='utf-8') as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    # Detect partial trailing line: not newline-terminated AND last line.
    is_last = (i == len(lines) - 1)
    if is_last and not line.endswith('\n'):
        partial = 1
        sys.stderr.write(f'[apr] queue: ignoring partial trailing line {i+1} of {events_file}\n')
        continue
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        if is_last:
            partial = 1
            sys.stderr.write(f'[apr] queue: ignoring unparseable line {i+1} of {events_file}\n')
            continue
        # A mid-stream bad line is a hard error; let it raise.
        raise
    if e.get('entry_id') != entry_id:
        continue
    found = True
    state['events'] += 1
    ev = e.get('event')
    if ev == 'enqueue':
        state['status'] = 'queued'
        state['workflow'] = e.get('workflow')
        state['round'] = e.get('round')
        state['include_impl'] = e.get('include_impl', False)
        if 'requested_slug' in e:
            state['requested_slug'] = e['requested_slug']
    elif ev == 'start':
        # Post-terminal mutation rule: don't move BACK to running once
        # the entry has a terminal status.
        if state['status'] not in ('done', 'failed', 'canceled'):
            state['status'] = 'running'
        state['runner_id'] = e.get('runner_id')
        state['started_at'] = e.get('started_at')
    elif ev == 'finish':
        if state['status'] not in ('canceled',):
            state['status'] = 'done'
        state['finished_at'] = e.get('finished_at')
        state['ok'] = True
        state['code'] = e.get('code')
        state['exit_code'] = e.get('exit_code')
        state['output_path'] = e.get('output_path')
        state['slug'] = e.get('slug')
    elif ev == 'fail':
        if state['status'] not in ('canceled',):
            state['status'] = 'failed'
        state['finished_at'] = e.get('finished_at')
        state['ok'] = False
        state['code'] = e.get('code')
        state['exit_code'] = e.get('exit_code')
        state['reason'] = e.get('reason')
    elif ev == 'cancel':
        state['status'] = 'canceled'
        state['canceled_at'] = e.get('canceled_at')
        state['reason'] = e.get('reason')
state['partial_trailing'] = bool(partial)
if not found:
    state['status'] = 'unknown'
sys.stdout.write(json.dumps(state, sort_keys=True))
sys.exit(0 if found else 1)
PY
        return $?
    fi

    # Pure-bash fallback (no python3). Sufficient for canonical lines.
    local status="unknown"
    local last_line=""
    local found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        last_line="$line"
        [[ "$line" != *"\"entry_id\":\"$entry_id\""* ]] && continue
        found=1
        case "$line" in
            *'"event":"enqueue"'*) status="queued" ;;
            *'"event":"start"'*)   [[ "$status" != "done" && "$status" != "failed" && "$status" != "canceled" ]] && status="running" ;;
            *'"event":"finish"'*)  [[ "$status" != "canceled" ]] && status="done" ;;
            *'"event":"fail"'*)    [[ "$status" != "canceled" ]] && status="failed" ;;
            *'"event":"cancel"'*)  status="canceled" ;;
        esac
    done < "$events_file"
    : "$last_line"  # acknowledge unused-by-design
    if [[ $found -eq 0 ]]; then
        printf '{"status":"unknown","entry_id":"%s"}\n' "$entry_id"
        return 1
    fi
    printf '{"status":"%s","entry_id":"%s"}\n' "$status" "$entry_id"
    return 0
}

# -----------------------------------------------------------------------------
# apr_lib_queue_status_summary <events_file>
# -----------------------------------------------------------------------------
apr_lib_queue_status_summary() {
    local events_file="${1:?events_file required}"
    if [[ ! -r "$events_file" ]]; then
        printf '{"counts":{"queued":0,"running":0,"done":0,"failed":0,"canceled":0},"active":[]}'
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        # Without python3 we can't fold cleanly; emit zeros.
        printf '{"counts":{"queued":0,"running":0,"done":0,"failed":0,"canceled":0},"active":[]}'
        return 0
    fi
    python3 - "$events_file" <<'PY'
import json, sys
events_file = sys.argv[1]
by_id = {}
partial = 0
with open(events_file, encoding='utf-8') as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    is_last = (i == len(lines) - 1)
    if is_last and not line.endswith('\n'):
        partial = 1
        sys.stderr.write(f'[apr] queue: ignoring partial trailing line {i+1} of {events_file}\n')
        continue
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        if is_last:
            partial = 1
            sys.stderr.write(f'[apr] queue: ignoring unparseable line {i+1} of {events_file}\n')
            continue
        raise
    eid = e.get('entry_id')
    if not eid:
        continue
    prev = by_id.get(eid, 'unknown')
    ev = e.get('event')
    if ev == 'enqueue':
        new = 'queued'
    elif ev == 'start':
        new = prev if prev in ('done','failed','canceled') else 'running'
    elif ev == 'finish':
        new = 'done' if prev != 'canceled' else 'canceled'
    elif ev == 'fail':
        new = 'failed' if prev != 'canceled' else 'canceled'
    elif ev == 'cancel':
        new = 'canceled'
    else:
        new = prev
    by_id[eid] = new
counts = {"queued":0,"running":0,"done":0,"failed":0,"canceled":0}
active = []
for eid, s in by_id.items():
    if s in counts:
        counts[s] += 1
    if s in ('queued','running'):
        active.append(eid)
sys.stdout.write(json.dumps({"counts": counts, "active": sorted(active), "partial_trailing": bool(partial)}, sort_keys=True))
PY
}

# -----------------------------------------------------------------------------
# apr_lib_queue_next_queued <events_file>
# -----------------------------------------------------------------------------
apr_lib_queue_next_queued() {
    local events_file="${1:?events_file required}"
    if [[ ! -r "$events_file" ]]; then
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf '[apr] queue: python3 is required to select queued entries\n' >&2
        return 1
    fi
    python3 - "$events_file" <<'PY'
import json, sys
events_file = sys.argv[1]
by_id = {}
order = []
with open(events_file, encoding='utf-8') as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    is_last = (i == len(lines) - 1)
    if is_last and not line.endswith('\n'):
        sys.stderr.write(f'[apr] queue: ignoring partial trailing line {i+1} of {events_file}\n')
        continue
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        if is_last:
            sys.stderr.write(f'[apr] queue: ignoring unparseable line {i+1} of {events_file}\n')
            continue
        raise
    eid = e.get('entry_id')
    if not eid:
        continue
    if eid not in by_id:
        by_id[eid] = {'entry_id': eid, 'status': 'unknown'}
        order.append(eid)
    state = by_id[eid]
    ev = e.get('event')
    if ev == 'enqueue':
        state.update({
            'status': 'queued',
            'workflow': e.get('workflow'),
            'round': e.get('round'),
            'include_impl': e.get('include_impl', False),
        })
        if 'requested_slug' in e:
            state['requested_slug'] = e['requested_slug']
    elif ev == 'start':
        if state.get('status') not in ('done', 'failed', 'canceled'):
            state['status'] = 'running'
    elif ev == 'finish':
        if state.get('status') != 'canceled':
            state['status'] = 'done'
    elif ev == 'fail':
        if state.get('status') != 'canceled':
            state['status'] = 'failed'
    elif ev == 'cancel':
        state['status'] = 'canceled'
for eid in order:
    state = by_id[eid]
    if state.get('status') == 'queued':
        sys.stdout.write(json.dumps(state, sort_keys=True))
        sys.exit(0)
sys.exit(1)
PY
}

_apr_lib_queue_now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_apr_lib_queue_entry_fields() {
    local entry_json="${1:?entry_json required}"
    python3 - "$entry_json" <<'PY'
import json, sys
entry = json.loads(sys.argv[1])
fields = [
    entry.get('entry_id') or '',
    entry.get('workflow') or '',
    str(entry.get('round') if entry.get('round') is not None else ''),
    'true' if entry.get('include_impl') is True else 'false',
    entry.get('requested_slug') or '',
]
for field in fields:
    print(field)
PY
}

_apr_lib_queue_event_json() {
    local event="${1:?event required}"
    local entry_id="${2:?entry_id required}"
    local workflow="${3:?workflow required}"
    local round="${4:-}"
    local include_impl="${5:-false}"
    local runner_id="${6:-}"
    local code="${7:-}"
    local exit_code="${8:-}"
    local output_path="${9:-}"
    local slug="${10:-}"
    local reason="${11:-}"
    local ts
    ts="$(_apr_lib_queue_now_utc)"

    python3 - "$event" "$entry_id" "$workflow" "$round" "$include_impl" "$runner_id" "$code" "$exit_code" "$output_path" "$slug" "$reason" "$ts" <<'PY'
import json, sys
event, entry_id, workflow, round_value, include_impl, runner_id, code, exit_code, output_path, slug, reason, ts = sys.argv[1:]
payload = {
    'schema_version': 'apr_queue_event.v1',
    'ts': ts,
    'event': event,
    'entry_id': entry_id,
    'workflow': workflow,
}
if event == 'enqueue':
    payload['round'] = int(round_value)
    payload['include_impl'] = include_impl == 'true'
elif event == 'start':
    payload['runner_id'] = runner_id
    payload['started_at'] = ts
elif event == 'finish':
    payload.update({
        'ok': True,
        'code': code or 'ok',
        'exit_code': int(exit_code or '0'),
        'output_path': output_path,
        'slug': slug,
        'finished_at': ts,
    })
elif event == 'fail':
    payload.update({
        'ok': False,
        'code': code or 'queue_run_failed',
        'exit_code': int(exit_code or '1'),
        'finished_at': ts,
        'reason': reason or f'runner command exited {exit_code or "1"}',
    })
print(json.dumps(payload, sort_keys=True, separators=(',', ':')))
PY
}

_apr_lib_queue_default_slug() {
    local workflow="${1:?workflow required}"
    local round="${2:?round required}"
    local include_impl="${3:-false}"
    local slug="apr-${workflow}-round-${round}"
    if [[ "$include_impl" == "true" ]]; then
        slug="${slug}-with-impl"
    fi
    printf '%s\n' "$slug"
}

_apr_lib_queue_default_output_path() {
    local workflow="${1:?workflow required}"
    local round="${2:?round required}"
    printf '.apr/rounds/%s/round_%s.md\n' "$workflow" "$round"
}

_apr_lib_queue_run_once_locked() {
    local events_file="${1:?events_file required}"
    local runner_id="${2:?runner_id required}"
    shift 2
    if (($# == 0)); then
        printf '[apr] queue: runner command required\n' >&2
        return 64
    fi

    local entry_json
    if ! entry_json="$(apr_lib_queue_next_queued "$events_file")"; then
        printf '{"ran":false,"status":"empty"}\n'
        return 2
    fi

    local fields=()
    mapfile -t fields < <(_apr_lib_queue_entry_fields "$entry_json")
    local entry_id="${fields[0]}"
    local workflow="${fields[1]}"
    local round="${fields[2]}"
    local include_impl="${fields[3]}"
    local requested_slug="${fields[4]}"
    local slug output_path start_event finish_event fail_event
    slug="${requested_slug:-$(_apr_lib_queue_default_slug "$workflow" "$round" "$include_impl")}"
    output_path="$(_apr_lib_queue_default_output_path "$workflow" "$round")"

    start_event="$(_apr_lib_queue_event_json start "$entry_id" "$workflow" "$round" "$include_impl" "$runner_id")"
    apr_lib_queue_append "$events_file" "$start_event" || return 1

    local rc=0
    APR_QUEUE_ENTRY_JSON="$entry_json" \
        APR_QUEUE_ENTRY_ID="$entry_id" \
        APR_QUEUE_WORKFLOW="$workflow" \
        APR_QUEUE_ROUND="$round" \
        APR_QUEUE_INCLUDE_IMPL="$include_impl" \
        APR_QUEUE_RUNNER_ID="$runner_id" \
        "$@" || rc=$?

    if (( rc == 0 )); then
        finish_event="$(_apr_lib_queue_event_json finish "$entry_id" "$workflow" "$round" "$include_impl" "$runner_id" ok 0 "$output_path" "$slug")"
        apr_lib_queue_append "$events_file" "$finish_event" || return 1
        printf '{"ran":true,"entry_id":"%s","status":"done","exit_code":0,"slug":"%s","output_path":"%s"}\n' "$entry_id" "$slug" "$output_path"
    else
        fail_event="$(_apr_lib_queue_event_json fail "$entry_id" "$workflow" "$round" "$include_impl" "$runner_id" queue_run_failed "$rc" "" "" "runner command exited $rc")"
        apr_lib_queue_append "$events_file" "$fail_event" || return 1
        printf '{"ran":true,"entry_id":"%s","status":"failed","exit_code":%s,"code":"queue_run_failed"}\n' "$entry_id" "$rc"
    fi

    return "$rc"
}

# -----------------------------------------------------------------------------
# apr_lib_queue_run_once <events_file> <lock_file> <runner_id> <command...>
# -----------------------------------------------------------------------------
apr_lib_queue_run_once() {
    local events_file="${1:?events_file required}"
    local lock_file="${2:?lock_file required}"
    local runner_id="${3:?runner_id required}"
    shift 3
    apr_lib_queue_with_lock "$lock_file" _apr_lib_queue_run_once_locked "$events_file" "$runner_id" "$@"
}
