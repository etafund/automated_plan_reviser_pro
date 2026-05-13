#!/usr/bin/env bats
# test_v18_files_report.bats - Unit tests for Oracle files-report verification (bd-1tl)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    export SCRIPT_PATH="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/verify-files-report.py"
    chmod +x "$SCRIPT_PATH"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "Files-report verification: perfect match" {
    local expected='[{"path":"README.md","bytes":100,"inclusion_reason":"required"},{"path":"spec.md","bytes":200,"inclusion_reason":"required"}]'
    local output_log="$TEST_DIR/oracle.log"
    cat > "$output_log" <<EOF
[oracle] Files report:
[oracle]   - README.md: success (100 bytes)
[oracle]   - spec.md: success (200 bytes)
EOF

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --json
    assert_success
    assert_output --partial '"files_report_ok": true'
    assert_output --partial '"files_report_supported": true'
}

@test "Files-report verification: missing file" {
    local expected='[{"path":"README.md","bytes":100,"inclusion_reason":"required"},{"path":"spec.md","bytes":200,"inclusion_reason":"required"}]'
    local output_log="$TEST_DIR/oracle.log"
    cat > "$output_log" <<EOF
[oracle] Files report:
[oracle]   - README.md: success (100 bytes)
EOF

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --json
    assert_success
    assert_output --partial '"files_report_ok": false'
    assert_output --partial '"missing": ['
    assert_output --partial '"spec.md"'
}

@test "Files-report verification: extra file" {
    local expected='[{"path":"README.md","bytes":100,"inclusion_reason":"required"}]'
    local output_log="$TEST_DIR/oracle.log"
    cat > "$output_log" <<EOF
[oracle] Files report:
[oracle]   - README.md: success (100 bytes)
[oracle]   - unknown.txt: success (50 bytes)
EOF

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --json
    assert_success
    assert_output --partial '"files_report_ok": false'
    assert_output --partial '"extra": ['
    assert_output --partial '"unknown.txt"'
}

@test "Files-report verification: size mismatch" {
    local expected='[{"path":"README.md","bytes":100,"inclusion_reason":"required"}]'
    local output_log="$TEST_DIR/oracle.log"
    cat > "$output_log" <<EOF
[oracle] Files report:
[oracle]   - README.md: success (500 bytes)
EOF

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --json
    assert_success
    assert_output --partial '"files_report_ok": false'
    assert_output --partial '"size_mismatch": ['
    assert_output --partial '"README.md"'
}

@test "Files-report verification: not supported" {
    local expected='[]'
    local output_log="$TEST_DIR/oracle.log"
    echo "some other oracle output" > "$output_log"

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --json
    assert_success
    assert_output --partial '"files_report_supported": false'
}

@test "Files-report verification: strict mode failure" {
    local expected='[{"path":"README.md","bytes":100,"inclusion_reason":"required"}]'
    local output_log="$TEST_DIR/oracle.log"
    cat > "$output_log" <<EOF
[oracle] Files report:
[oracle]   - README.md: success (500 bytes)
EOF

    run python3 "$SCRIPT_PATH" --expected-files "$expected" --oracle-output "$output_log" --strict --json
    assert_success
    assert_output --partial '"ok": false'
    assert_output --partial 'mismatch'
}
