#!/usr/bin/env bats
# test_queue_cli.bats - Integration tests for apr queue CLI (bd-18g)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"

    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi

    export NO_COLOR=1 APR_NO_GUM=1 CI=true
    cd "$TEST_PROJECT" || return 1
    setup_test_workflow "default"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

setup_queue_mock_oracle_writer() {
    local mock_oracle="$TEST_DIR/bin/oracle"
    mkdir -p "$(dirname "$mock_oracle")"

    cat > "$mock_oracle" <<'EOF'
#!/usr/bin/env bash
output_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            printf '%s\n' "Usage: oracle [options]"
            printf '%s\n' "  --notify"
            exit 0
            ;;
        --version)
            printf '%s\n' "oracle 0.8.4 (queue mock)"
            exit 0
            ;;
        status)
            printf '%s\n' "No active sessions" >&2
            exit 0
            ;;
        session)
            printf 'Session: %s\n' "${2:-}" >&2
            exit 0
            ;;
        --write-output)
            output_file="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "$output_file" ]]; then
    mkdir -p "$(dirname "$output_file")"
    python3 - "$output_file" <<'PY'
import sys
path = sys.argv[1]
body = "# Queue Mock Review\n\n" + ("This is deterministic queue output. " * 90) + "Done."
with open(path, "w", encoding="utf-8") as f:
    f.write(body)
PY
fi
exit 0
EOF
    chmod +x "$mock_oracle"
    export PATH="$TEST_DIR/bin:$PATH"
}

@test "queue: add status and cancel preserve JSONL audit state" {
    capture_streams "$APR_SCRIPT" queue add 2 --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_valid_json "$CAPTURED_STDOUT"
    assert_json_value "$CAPTURED_STDOUT" ".workflow" "default"
    assert_json_value "$CAPTURED_STDOUT" ".round" "2"

    local entry_id
    entry_id="$(printf '%s' "$CAPTURED_STDOUT" | jq -r '.entry_id')"

    capture_streams "$APR_SCRIPT" queue status --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_valid_json "$CAPTURED_STDOUT"
    assert_json_value "$CAPTURED_STDOUT" ".counts.queued" "1"
    assert_json_value "$CAPTURED_STDOUT" ".queued[0].entry_id" "$entry_id"

    capture_streams "$APR_SCRIPT" queue cancel "$entry_id" --reason "operator changed plan" --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_valid_json "$CAPTURED_STDOUT"
    assert_json_value "$CAPTURED_STDOUT" ".entry.status" "canceled"

    capture_streams "$APR_SCRIPT" queue status --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_json_value "$CAPTURED_STDOUT" ".counts.queued" "0"
    assert_json_value "$CAPTURED_STDOUT" ".counts.canceled" "1"
}

@test "robot queue: add emits stable robot envelope" {
    capture_streams "$APR_SCRIPT" robot --compact queue add 4 -w default --include-impl --slug custom-round-4
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_valid_json "$CAPTURED_STDOUT"
    assert_json_value "$CAPTURED_STDOUT" ".ok" "true"
    assert_json_value "$CAPTURED_STDOUT" ".code" "ok"
    assert_json_value "$CAPTURED_STDOUT" ".data.workflow" "default"
    assert_json_value "$CAPTURED_STDOUT" ".data.round" "4"
    assert_json_value "$CAPTURED_STDOUT" ".data.include_impl" "true"
    assert_json_value "$CAPTURED_STDOUT" ".data.requested_slug" "custom-round-4"
}

@test "queue run: once processes the next queued entry through apr run" {
    setup_queue_mock_oracle_writer

    capture_streams "$APR_SCRIPT" queue add 1 --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]

    export run_log="$TEST_DIR/queue-oracle.log"
    : > "$run_log"
    capture_streams "$APR_SCRIPT" queue run --once --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_valid_json "$CAPTURED_STDOUT"
    assert_json_value "$CAPTURED_STDOUT" ".processed" "1"
    assert_json_value "$CAPTURED_STDOUT" ".failures" "0"
    assert_json_value "$CAPTURED_STDOUT" ".last_result.status" "done"

    assert_file_exists "$TEST_PROJECT/.apr/rounds/default/round_1.md"

    capture_streams "$APR_SCRIPT" queue status --json
    [[ "$CAPTURED_STATUS" -eq 0 ]]
    assert_json_value "$CAPTURED_STDOUT" ".counts.done" "1"
    assert_json_value "$CAPTURED_STDOUT" ".counts.queued" "0"
}
