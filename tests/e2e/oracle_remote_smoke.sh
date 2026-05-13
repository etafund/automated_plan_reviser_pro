#!/usr/bin/env bash
# Optional live smoke test for APR remote Oracle wiring.
#
# This script is intentionally opt-in. It creates a tiny fixture project,
# captures every command into a timestamped log bundle, verifies APR dry-run
# evidence includes remote delegation flags, then runs one foreground round.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
APR_BIN="${APR_REMOTE_SMOKE_APR:-$REPO_ROOT/apr}"
LOG_ROOT="${APR_REMOTE_SMOKE_LOG_ROOT:-$REPO_ROOT/tests/logs/oracle_remote_smoke}"
WORKFLOW="remote-smoke"
ROUND="1"
SKIP_RUN="false"

usage() {
    cat <<'USAGE'
Usage: tests/e2e/oracle_remote_smoke.sh [options]

Runs an opt-in live smoke test for APR remote Oracle mode.

Required environment:
  ORACLE_REMOTE_HOST + ORACLE_REMOTE_TOKEN
    or
  ORACLE_REMOTE_POOL + ORACLE_REMOTE_TOKEN
    or
  ORACLE_REMOTE_POOL + ORACLE_REMOTE_TOKENS

Options:
  --workflow NAME       Fixture workflow name (default: remote-smoke)
  --round N             Round number to execute (default: 1)
  --log-root DIR        Log bundle root (default: tests/logs/oracle_remote_smoke)
  --apr PATH            APR executable path (default: ./apr)
  --skip-run            Stop after doctor/lint/dry-run remote flag checks
  -h, --help            Show this help

Outputs:
  tests/logs/oracle_remote_smoke/<timestamp>/
USAGE
}

while (($# > 0)); do
    case "$1" in
        --workflow)
            [[ $# -ge 2 ]] || { echo "missing value for --workflow" >&2; exit 2; }
            WORKFLOW="$2"
            shift 2
            ;;
        --round)
            [[ $# -ge 2 ]] || { echo "missing value for --round" >&2; exit 2; }
            ROUND="$2"
            shift 2
            ;;
        --log-root)
            [[ $# -ge 2 ]] || { echo "missing value for --log-root" >&2; exit 2; }
            LOG_ROOT="$2"
            shift 2
            ;;
        --apr)
            [[ $# -ge 2 ]] || { echo "missing value for --apr" >&2; exit 2; }
            APR_BIN="$2"
            shift 2
            ;;
        --skip-run)
            SKIP_RUN="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$ROUND" =~ ^[0-9]+$ || "$ROUND" -lt 1 ]]; then
    echo "--round must be a positive integer" >&2
    exit 2
fi

timestamp_utc() {
    date -u '+%Y%m%dT%H%M%SZ'
}

LOG_DIR="$LOG_ROOT/$(timestamp_utc)"
PROJECT_DIR="$LOG_DIR/project"
mkdir -p "$LOG_DIR" "$PROJECT_DIR/.apr/workflows" "$PROJECT_DIR/.apr/rounds/$WORKFLOW"

die() {
    local message="$1"
    printf '%s\n' "$message" | tee -a "$LOG_DIR/summary.txt" >&2
    printf 'log_bundle=%s\n' "$LOG_DIR" >&2
    exit 1
}

write_redacted_env() {
    {
        printf 'APR_REMOTE_SMOKE_APR=%s\n' "$APR_BIN"
        printf 'APR_REMOTE_SMOKE_LOG_ROOT=%s\n' "$LOG_ROOT"
        printf 'ORACLE_REMOTE_HOST=%s\n' "${ORACLE_REMOTE_HOST:-}"
        printf 'ORACLE_REMOTE_POOL=%s\n' "${ORACLE_REMOTE_POOL:-}"
        if [[ -n "${ORACLE_REMOTE_TOKEN:-}" ]]; then
            printf 'ORACLE_REMOTE_TOKEN=<set>\n'
        else
            printf 'ORACLE_REMOTE_TOKEN=<unset>\n'
        fi
        if [[ -n "${ORACLE_REMOTE_TOKENS:-}" ]]; then
            printf 'ORACLE_REMOTE_TOKENS=<set>\n'
        else
            printf 'ORACLE_REMOTE_TOKENS=<unset>\n'
        fi
        printf 'PATH=%s\n' "$PATH"
    } > "$LOG_DIR/env.redacted"
}

validate_remote_env() {
    local single_host_ok="false"
    local pool_ok="false"

    if [[ -n "${ORACLE_REMOTE_HOST:-}" && -n "${ORACLE_REMOTE_TOKEN:-}" ]]; then
        single_host_ok="true"
    fi
    if [[ -n "${ORACLE_REMOTE_POOL:-}" ]] && { [[ -n "${ORACLE_REMOTE_TOKEN:-}" ]] || [[ -n "${ORACLE_REMOTE_TOKENS:-}" ]]; }; then
        pool_ok="true"
    fi

    if [[ "$single_host_ok" != "true" && "$pool_ok" != "true" ]]; then
        die "remote configuration missing: set ORACLE_REMOTE_HOST+ORACLE_REMOTE_TOKEN or ORACLE_REMOTE_POOL with token env"
    fi
}

write_fixture_project() {
    cat > "$PROJECT_DIR/README.md" <<'EOF'
# APR Remote Smoke Fixture

This tiny fixture exists only to verify APR can send a minimal remote Oracle
round and collect enough logs to debug failures.
EOF

    cat > "$PROJECT_DIR/SPECIFICATION.md" <<'EOF'
# Specification

Return a concise review with one strength, one risk, and one next action.
EOF

    cat > "$PROJECT_DIR/.apr/config.yaml" <<EOF
default_workflow: $WORKFLOW
EOF

    cat > "$PROJECT_DIR/.apr/workflows/$WORKFLOW.yaml" <<EOF
name: $WORKFLOW
description: Live remote Oracle smoke fixture

documents:
  readme: README.md
  spec: SPECIFICATION.md

oracle:
  model: "5.2 Thinking"
  thinking_time: heavy

rounds:
  output_dir: .apr/rounds/$WORKFLOW

template: |
  Read the fixture README and specification.

  Verify that the context is sufficient, then produce:
  - one strength
  - one risk
  - one concrete next action
EOF
}

quote_cmd() {
    local first="true"
    local arg
    for arg in "$@"; do
        if [[ "$first" == "true" ]]; then
            first="false"
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    printf '\n'
}

run_capture_in() {
    local cwd="$1"
    local name="$2"
    shift 2

    quote_cmd "$@" > "$LOG_DIR/$name.cmdline"
    set +e
    (
        cd "$cwd"
        "$@"
    ) > "$LOG_DIR/$name.stdout.log" 2> "$LOG_DIR/$name.stderr.log"
    local rc=$?
    set -e
    printf '%s\n' "$rc" > "$LOG_DIR/$name.exit"
    return "$rc"
}

oracle_status_snapshot() {
    local name="$1"
    if command -v oracle >/dev/null 2>&1; then
        run_capture_in "$PROJECT_DIR" "$name" oracle status || true
    elif command -v npx >/dev/null 2>&1; then
        run_capture_in "$PROJECT_DIR" "$name" npx oracle status || true
    else
        printf 'oracle and npx unavailable; status snapshot skipped\n' > "$LOG_DIR/$name.stderr.log"
        printf '127\n' > "$LOG_DIR/$name.exit"
    fi
}

hostport_from_remote_value() {
    local raw="$1"
    raw="${raw#http://}"
    raw="${raw#https://}"
    raw="${raw%%/*}"
    if [[ "$raw" == *:* ]]; then
        printf '%s\n' "$raw"
    else
        printf '%s:80\n' "$raw"
    fi
}

network_probe_one() {
    local hostport="$1"
    local host="${hostport%:*}"
    local port="${hostport##*:}"

    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$host" "$port" >> "$LOG_DIR/network.log" 2>&1; then
            printf 'reachable %s\n' "$hostport" >> "$LOG_DIR/network.log"
            return 0
        fi
        printf 'unreachable %s\n' "$hostport" >> "$LOG_DIR/network.log"
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl --silent --show-error --max-time 3 "http://$hostport/" >> "$LOG_DIR/network.log" 2>&1; then
            printf 'reachable %s\n' "$hostport" >> "$LOG_DIR/network.log"
            return 0
        fi
        printf 'unreachable %s\n' "$hostport" >> "$LOG_DIR/network.log"
        return 1
    fi

    printf 'network probe skipped for %s; install nc or curl\n' "$hostport" >> "$LOG_DIR/network.log"
    return 0
}

network_probes() {
    local reachable=0
    local checked=0

    : > "$LOG_DIR/network.log"
    if [[ -n "${ORACLE_REMOTE_HOST:-}" ]]; then
        checked=$((checked + 1))
        if network_probe_one "$(hostport_from_remote_value "$ORACLE_REMOTE_HOST")"; then
            reachable=$((reachable + 1))
        fi
    fi

    if [[ -n "${ORACLE_REMOTE_POOL:-}" ]]; then
        local pool="$ORACLE_REMOTE_POOL"
        local item
        while [[ -n "$pool" ]]; do
            item="${pool%%,*}"
            if [[ "$pool" == *,* ]]; then
                pool="${pool#*,}"
            else
                pool=""
            fi
            [[ -n "$item" ]] || continue
            checked=$((checked + 1))
            if network_probe_one "$(hostport_from_remote_value "$item")"; then
                reachable=$((reachable + 1))
            fi
        done
    fi

    if ((checked > 0 && reachable == 0)); then
        die "no configured remote host was reachable; see $LOG_DIR/network.log"
    fi
}

assert_remote_flags_in_dry_run() {
    local combined="$LOG_DIR/apr-dry-run.combined.log"
    {
        cat "$LOG_DIR/apr-dry-run.stdout.log"
        cat "$LOG_DIR/apr-dry-run.stderr.log"
    } > "$combined"

    if ! grep -Eq -- '(^|[[:space:]])--remote-host([[:space:]]|$)' "$combined"; then
        die "APR dry-run did not include --remote-host; refusing live run to avoid local browser fallback"
    fi
    if ! grep -Eq -- '(^|[[:space:]])--remote-token([[:space:]]|$)' "$combined"; then
        die "APR dry-run did not include --remote-token; refusing live run to avoid unauthenticated remote smoke"
    fi
}

write_redacted_env
validate_remote_env
write_fixture_project
network_probes

printf 'log_bundle=%s\n' "$LOG_DIR" > "$LOG_DIR/summary.txt"
printf 'project_dir=%s\n' "$PROJECT_DIR" >> "$LOG_DIR/summary.txt"

oracle_status_snapshot "oracle-status-before"

if ! run_capture_in "$PROJECT_DIR" "apr-doctor" "$APR_BIN" doctor --json; then
    die "apr doctor failed; see $LOG_DIR/apr-doctor.stderr.log and stdout JSON"
fi

if ! run_capture_in "$PROJECT_DIR" "apr-lint" "$APR_BIN" lint "$ROUND"; then
    die "apr lint failed; see $LOG_DIR/apr-lint.stderr.log"
fi

if ! run_capture_in "$PROJECT_DIR" "apr-dry-run" "$APR_BIN" run "$ROUND" --dry-run; then
    die "apr run --dry-run failed; see $LOG_DIR/apr-dry-run.stderr.log"
fi

assert_remote_flags_in_dry_run

if [[ "$SKIP_RUN" == "true" ]]; then
    printf 'result=skipped-live-run\n' >> "$LOG_DIR/summary.txt"
    printf 'Remote smoke preflight complete. Log bundle: %s\n' "$LOG_DIR"
    exit 0
fi

if ! run_capture_in "$PROJECT_DIR" "apr-run" "$APR_BIN" run "$ROUND" --wait; then
    oracle_status_snapshot "oracle-status-after"
    die "apr live remote run failed; see $LOG_DIR/apr-run.stderr.log"
fi

oracle_status_snapshot "oracle-status-after"

printf 'result=passed\n' >> "$LOG_DIR/summary.txt"
printf 'output_file=%s\n' "$PROJECT_DIR/.apr/rounds/$WORKFLOW/round_$ROUND.md" >> "$LOG_DIR/summary.txt"
printf 'Remote smoke passed. Log bundle: %s\n' "$LOG_DIR"
