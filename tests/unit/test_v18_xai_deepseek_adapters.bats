#!/usr/bin/env bats
# test_v18_xai_deepseek_adapters.bats - Unit tests for xAI and DeepSeek API adapters

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/xai-deepseek-adapters.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

start_fake_chat_api() {
    local port_file="$TEST_DIR/provider_port"
    local request_log="$TEST_DIR/provider_request.json"
    python3 - "$port_file" "$request_log" <<'PY' &
import http.server
import json
import sys

port_file, request_log = sys.argv[1:3]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        with open(request_log, "w", encoding="utf-8") as handle:
            handle.write(body)
        payload = {
            "id": "fake-response-1",
            "choices": [{"message": {"content": "fake provider response"}}],
        }
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _fmt, *_args):
        return

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.handle_request()
PY
    FAKE_API_PID=$!
    local i
    for ((i = 0; i < 50; i++)); do
        [[ -s "$port_file" ]] && break
        sleep 0.1
    done
    FAKE_API_BASE_URL="http://127.0.0.1:$(cat "$port_file")"
    export FAKE_API_BASE_URL
    export FAKE_API_REQUEST_LOG="$request_log"
}

@test "xAI adapter: check fail (missing key)" {
    unset XAI_API_KEY
    run python3 "$SCRIPT_PATH" --provider xai --action check --json
    assert_success
    assert_output --partial '"available": false'
    assert_output --partial '"api_key_status": "missing"'
}

@test "xAI adapter: check success" {
    export XAI_API_KEY="sk-test"
    run python3 "$SCRIPT_PATH" --provider xai --action check --json
    assert_success
    assert_output --partial '"available": true'
}

@test "xAI adapter: invoke success" {
    export XAI_API_KEY="sk-test"
    echo "test prompt" > prompt.txt
    start_fake_chat_api
    local output_file="$TEST_DIR/xai-output.txt"
    XAI_API_BASE_URL="$FAKE_API_BASE_URL" \
        run python3 "$SCRIPT_PATH" --provider xai --action invoke --prompt prompt.txt --output "$output_file" --json
    wait "$FAKE_API_PID"
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"model": "grok-4.3"'
    [[ -f "$output_file" ]]
    grep -Fq 'fake provider response' "$output_file"
    jq -e '.messages[0].content == "test prompt\n" and .reasoning_effort == "high"' "$FAKE_API_REQUEST_LOG" >/dev/null
}

@test "DeepSeek adapter: check success" {
    export DEEPSEEK_API_KEY="sk-test"
    run python3 "$SCRIPT_PATH" --provider deepseek --action check --json
    assert_success
    assert_output --partial '"available": true'
}

@test "DeepSeek adapter: invoke success" {
    export DEEPSEEK_API_KEY="sk-test"
    echo "test prompt" > prompt.txt
    start_fake_chat_api
    local output_file="$TEST_DIR/deepseek-output.txt"
    DEEPSEEK_API_BASE_URL="$FAKE_API_BASE_URL" \
        run python3 "$SCRIPT_PATH" --provider deepseek --action invoke --prompt prompt.txt --output "$output_file" --json
    wait "$FAKE_API_PID"
    assert_success
    assert_output --partial '"status": "success"'
    assert_output --partial '"model": "deepseek-v4-pro"'
    assert_output --partial '"thinking_enabled": true'
    [[ -f "$output_file" ]]
    grep -Fq 'fake provider response' "$output_file"
    jq -e '.messages[0].content == "test prompt\n" and .reasoning_effort == "max" and .thinking.type == "enabled"' "$FAKE_API_REQUEST_LOG" >/dev/null
}
