#!/usr/bin/env bats
# test_status_ux.bats - UX coverage for apr status.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

setup_status_oracle() {
    local mode="${1:-active}"
    local mock_oracle="$TEST_DIR/bin/oracle"
    mkdir -p "$(dirname "$mock_oracle")"

    cat >"$mock_oracle" <<'EOF'
#!/usr/bin/env bash
echo "Mock Oracle called with: $*" >&2

case "$1" in
    --version)
        echo "oracle 0.8.4 (mock)"
        exit 0
        ;;
    status)
        case "${APR_STATUS_MODE:-active}" in
            idle)
                echo "No active sessions" >&2
                ;;
            fail)
                echo "Oracle profile unavailable" >&2
                exit 47
                ;;
            *)
                echo "apr-alpha  running    12m  apr attach apr-alpha" >&2
                echo "apr-beta   completed  2h   apr show 4" >&2
                ;;
        esac
        ;;
    *)
        echo "Unexpected oracle call: $*" >&2
        exit 64
        ;;
esac
EOF
    chmod +x "$mock_oracle"
    export PATH="$TEST_DIR/bin:$PATH"
    export APR_STATUS_MODE="$mode"
}

assert_lines_at_most() {
    local output="$1"
    local max_width="$2"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if ((${#line} > max_width)); then
            printf 'line exceeds %s columns: %s\n' "$max_width" "$line" >&2
            return 1
        fi
    done <<<"$output"
}

@test "apr status desktop frames Oracle sessions with actions" {
    setup_status_oracle active

    capture_streams env APR_LAYOUT=desktop APR_TERM_COLUMNS=120 APR_TERM_LINES=32 APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" status --hours 12

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"ORACLE SESSION STATUS"* ]]
    [[ "$CAPTURED_STDERR" == *"Window:    last 12h"* ]]
    [[ "$CAPTURED_STDERR" == *"State:     sessions available"* ]]
    [[ "$CAPTURED_STDERR" == *"SESSIONS"* ]]
    [[ "$CAPTURED_STDERR" == *"Mock Oracle called with: status --hours 12"* ]]
    [[ "$CAPTURED_STDERR" == *"apr-alpha  running"* ]]
    [[ "$CAPTURED_STDERR" == *"ACTIONS"* ]]
    [[ "$CAPTURED_STDERR" == *"Attach: apr attach <session>"* ]]
    [[ "$CAPTURED_STDERR" == *"Dashboard: apr dashboard"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
    assert_lines_at_most "$CAPTURED_STDERR" 120
}

@test "apr status compact stays narrow and shows filter hint" {
    setup_status_oracle idle

    capture_streams env APR_LAYOUT=compact APR_TERM_COLUMNS=64 APR_TERM_LINES=18 APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" status --hours 6

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"STATUS"* ]]
    [[ "$CAPTURED_STDERR" == *"window: 6h"* ]]
    [[ "$CAPTURED_STDERR" == *"state:  idle"* ]]
    [[ "$CAPTURED_STDERR" == *"No active sessions"* ]]
    [[ "$CAPTURED_STDERR" == *"Filter: apr status --hours 24"* ]]
    [[ "$CAPTURED_STDERR" == *"Attach: apr attach <session>"* ]]
    [[ "$CAPTURED_STDERR" != *"ORACLE SESSION STATUS"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
    assert_lines_at_most "$CAPTURED_STDERR" 80
}

@test "apr status failure returns Oracle code with recovery hint" {
    setup_status_oracle fail

    capture_streams env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" status --hours 3

    [[ "$CAPTURED_STATUS" -eq 47 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"state:  error"* ]]
    [[ "$CAPTURED_STDERR" == *"Oracle profile unavailable"* ]]
    [[ "$CAPTURED_STDERR" == *"Oracle status failed"* ]]
    [[ "$CAPTURED_STDERR" == *"apr doctor"* ]]
    [[ "$CAPTURED_STDERR" == *"apr status --hours 3"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
}
