#!/usr/bin/env bats
# test_attach_ux.bats - UX coverage for apr attach.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

make_failing_oracle() {
    local mock_oracle="$TEST_DIR/bin/oracle"
    mkdir -p "$(dirname "$mock_oracle")"

    cat > "$mock_oracle" <<'EOF'
#!/usr/bin/env bash
echo "Mock Oracle called with: $*" >&2
case "$1" in
    session)
        echo "Session not found: $2" >&2
        exit 42
        ;;
    --version)
        echo "oracle 0.8.4 (mock)"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$mock_oracle"
    export PATH="$TEST_DIR/bin:$PATH"
}

@test "apr attach compact output identifies session and status action" {
    setup_mock_oracle

    capture_streams env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" attach apr-test-session

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ "$CAPTURED_STDERR" == *"ATTACH"* ]]
    [[ "$CAPTURED_STDERR" == *"Session: apr-test-session"* ]]
    [[ "$CAPTURED_STDERR" == *"Find sessions: apr status --hours 72"* ]]
    [[ "$CAPTURED_STDERR" == *"Mock Oracle called with: session apr-test-session --render"* ]]
    [[ "$CAPTURED_STDERR" == *"Session render complete"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
}

@test "apr attach desktop output shows slug and query state" {
    setup_mock_oracle

    capture_streams env APR_LAYOUT=desktop APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" attach apr-test-session

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ "$CAPTURED_STDERR" == *"ATTACH SESSION"* ]]
    [[ "$CAPTURED_STDERR" == *"Session slug: apr-test-session"* ]]
    [[ "$CAPTURED_STDERR" == *"State: querying Oracle"* ]]
    [[ "$CAPTURED_STDERR" == *"Session render complete"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
}

@test "apr attach failure gives one-step recovery hint" {
    make_failing_oracle

    capture_streams env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "$APR_SCRIPT" attach missing-session

    [[ "$CAPTURED_STATUS" -eq 42 ]]
    [[ "$CAPTURED_STDERR" == *"Session not found: missing-session"* ]]
    [[ "$CAPTURED_STDERR" == *"Oracle could not render session: missing-session"* ]]
    [[ "$CAPTURED_STDERR" == *"apr status --hours 72"* ]]
    [[ "$CAPTURED_STDERR" == *"retry 'apr attach <session>'"* ]]
    assert_no_ansi "$CAPTURED_STDERR"
}
