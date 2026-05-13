#!/usr/bin/env bats
# test_dashboard.bats - Unit tests for dashboard helper functions

# Load test helpers
load '../helpers/test_helper.bash'

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    setup_test_environment
    load_apr_functions
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# dashboard_iso_to_epoch() Tests
# =============================================================================

@test "dashboard_iso_to_epoch: valid ISO returns numeric epoch" {
    local iso="2026-01-12T00:00:00Z"

    run dashboard_iso_to_epoch "$iso"

    log_test_actual "epoch" "$output"
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]]
    [[ "$output" -gt 0 ]]
}

@test "dashboard_iso_to_epoch: null returns 0" {
    run dashboard_iso_to_epoch "null"

    log_test_actual "epoch" "$output"
    assert_success
    [[ "$output" == "0" ]]
}

@test "dashboard_iso_to_epoch: empty returns 0" {
    run dashboard_iso_to_epoch ""

    log_test_actual "epoch" "$output"
    assert_success
    [[ "$output" == "0" ]]
}

@test "dashboard_iso_to_epoch: invalid string returns 0" {
    run dashboard_iso_to_epoch "not-a-date"

    log_test_actual "epoch" "$output"
    assert_success
    [[ "$output" == "0" ]]
}

# =============================================================================
# dashboard_format_duration() Tests
# =============================================================================

@test "dashboard_format_duration: minutes only" {
    run dashboard_format_duration 59

    log_test_actual "duration" "$output"
    assert_success
    [[ "$output" == "0m" ]]
}

@test "dashboard_format_duration: hours and minutes" {
    run dashboard_format_duration 3720

    log_test_actual "duration" "$output"
    assert_success
    [[ "$output" == "1h 2m" ]]
}

@test "dashboard_format_duration: days and hours" {
    run dashboard_format_duration 90000

    log_test_actual "duration" "$output"
    assert_success
    [[ "$output" == "1d 1h" ]]
}

@test "dashboard_format_duration: negative returns N/A" {
    run dashboard_format_duration -5

    log_test_actual "duration" "$output"
    assert_success
    [[ "$output" == "N/A" ]]
}

@test "dashboard_format_duration: null returns N/A" {
    run dashboard_format_duration "null"

    log_test_actual "duration" "$output"
    assert_success
    [[ "$output" == "N/A" ]]
}

# =============================================================================
# dashboard_format_nullable() Tests
# =============================================================================

@test "dashboard_format_nullable: null returns dash" {
    run dashboard_format_nullable "null"

    log_test_actual "value" "$output"
    assert_success
    [[ "$output" == "-" ]]
}

@test "dashboard_format_nullable: empty returns dash" {
    run dashboard_format_nullable ""

    log_test_actual "value" "$output"
    assert_success
    [[ "$output" == "-" ]]
}

@test "dashboard_format_nullable: preserves value" {
    run dashboard_format_nullable "12"

    log_test_actual "value" "$output"
    assert_success
    [[ "$output" == "12" ]]
}

# =============================================================================
# dashboard_term_size() Tests
# =============================================================================

@test "dashboard_term_size: returns two numeric values" {
    run dashboard_term_size

    log_test_actual "term size" "$output"
    assert_success

    local cols rows
    cols=$(echo "$output" | awk '{print $1}')
    rows=$(echo "$output" | awk '{print $2}')
    [[ "$cols" =~ ^[0-9]+$ ]]
    [[ "$rows" =~ ^[0-9]+$ ]]
}

# =============================================================================
# dashboard_build_rounds() Tests
# =============================================================================

@test "dashboard_build_rounds: populates round arrays" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [
    {
      "round": 1,
      "timestamp": "2026-01-01T00:00:00Z",
      "output": { "char_count": 100 }
    },
    {
      "round": 2,
      "timestamp": "2026-01-02T00:00:00Z",
      "output": { "char_count": 50 },
      "changes_from_previous": {
        "lines_added": 10,
        "lines_deleted": 5,
        "similarity_score": 0.7
      }
    }
  ]
}
EOF
)

    dashboard_build_rounds "$metrics"

    log_test_actual "round count" "$DASHBOARD_TOTAL_ROUNDS"
    [[ "$DASHBOARD_TOTAL_ROUNDS" -eq 2 ]]
    [[ "${DASHBOARD_ROUND_NUMS[0]}" -eq 1 ]]
    [[ "${DASHBOARD_ROUND_NUMS[1]}" -eq 2 ]]
    [[ "${DASHBOARD_ROUND_SIZES[0]}" -eq 100 ]]
    [[ "${DASHBOARD_ROUND_SIZES[1]}" -eq 50 ]]
    [[ "${DASHBOARD_ROUND_ADDED[1]}" -eq 10 ]]
    [[ "${DASHBOARD_ROUND_DELETED[1]}" -eq 5 ]]
}

@test "dashboard_build_rounds: sorts rounds ascending" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [
    {"round": 3, "timestamp": "2026-01-03T00:00:00Z", "output": {"char_count": 300}},
    {"round": 1, "timestamp": "2026-01-01T00:00:00Z", "output": {"char_count": 100}},
    {"round": 2, "timestamp": "2026-01-02T00:00:00Z", "output": {"char_count": 200}}
  ]
}
EOF
)

    dashboard_build_rounds "$metrics"

    [[ "${DASHBOARD_ROUND_NUMS[0]}" -eq 1 ]]
    [[ "${DASHBOARD_ROUND_NUMS[1]}" -eq 2 ]]
    [[ "${DASHBOARD_ROUND_NUMS[2]}" -eq 3 ]]
}

# =============================================================================
# dashboard_render_*() Tests
# =============================================================================

@test "dashboard_render_convergence: prints status" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [{"round": 1, "output": {"char_count": 10}}],
  "convergence": {
    "confidence": 0.8,
    "estimated_rounds_remaining": 2
  }
}
EOF
)

    capture_streams dashboard_render_convergence "$metrics"

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"CONVERGENCE STATUS"* ]]
    [[ "$CAPTURED_STDERR" == *"80%"* ]]
}

@test "dashboard_render_quick_stats: prints key fields" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [
    {"round": 1, "timestamp": "2026-01-01T00:00:00Z", "output": {"char_count": 100}},
    {"round": 2, "timestamp": "2026-01-02T00:00:00Z", "output": {"char_count": 200}}
  ]
}
EOF
)

    capture_streams dashboard_render_quick_stats "$metrics"

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"QUICK STATS"* ]]
    [[ "$CAPTURED_STDERR" == *"Rounds:"* ]]
    [[ "$CAPTURED_STDERR" == *"Last Run:"* ]]
}

@test "dashboard_render_bar_chart: renders labels" {
    capture_streams dashboard_render_bar_chart 10 20 5

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"OUTPUT SIZE TREND"* ]]
    [[ "$CAPTURED_STDERR" == *"R1"* ]]
    [[ "$CAPTURED_STDERR" == *"R2"* ]]
    [[ "$CAPTURED_STDERR" == *"R3"* ]]
}

@test "dashboard_render_bar_chart: no data prints placeholder" {
    capture_streams dashboard_render_bar_chart

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"(no data)"* ]]
}

@test "dashboard_render_header: includes workflow name" {
    capture_streams dashboard_render_header "demo"

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"APR Analytics Dashboard"* ]]
    [[ "$CAPTURED_STDERR" == *"demo"* ]]
}

@test "dashboard_render_round_table: shows selected marker and keys" {
    DASHBOARD_ROUND_NUMS=(1 2 3)
    DASHBOARD_ROUND_SIZES=(1000 2000 3000)
    DASHBOARD_ROUND_ADDED=(10 null 30)
    DASHBOARD_ROUND_DELETED=(1 null 3)
    DASHBOARD_ROUND_SIMILARITY=(0.5 0.7 0.9)
    DASHBOARD_ROUND_TS=("2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z" "2026-01-03T00:00:00Z")

    capture_streams dashboard_render_round_table 1 3

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ "$CAPTURED_STDERR" == *"ROUND DETAILS"* ]]
    [[ "$CAPTURED_STDERR" == *">"* ]]
    [[ "$CAPTURED_STDERR" == *"Keys:"* ]]
    [[ "$CAPTURED_STDERR" == *"-"* ]]
}

@test "dashboard_render: desktop view preserves hierarchy, chart, table, and action footer" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [
    {"round": 1, "timestamp": "2026-01-01T00:00:00Z", "output": {"char_count": 1200}},
    {"round": 2, "timestamp": "2026-01-02T00:00:00Z", "output": {"char_count": 1900}},
    {"round": 3, "timestamp": "2026-01-03T00:00:00Z", "output": {"char_count": 2100}}
  ],
  "convergence": {
    "confidence": 0.82,
    "estimated_rounds_remaining": 2
  }
}
EOF
)
    DASHBOARD_ROUND_NUMS=(1 2 3)
    DASHBOARD_ROUND_SIZES=(1200 1900 2100)
    DASHBOARD_ROUND_ADDED=(null 20 12)
    DASHBOARD_ROUND_DELETED=(null 5 3)
    DASHBOARD_ROUND_SIMILARITY=(null 0.64 0.82)
    DASHBOARD_ROUND_TS=("2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z" "2026-01-03T00:00:00Z")
    DASHBOARD_TOTAL_ROUNDS=3

    NO_COLOR=1 capture_streams dashboard_render "default" "$metrics" 1

    log_test_actual "stderr" "$CAPTURED_STDERR"
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"APR Analytics Dashboard"* ]]
    [[ "$CAPTURED_STDERR" == *"Press 'q' to quit"* ]]
    [[ "$CAPTURED_STDERR" == *"CONVERGENCE STATUS"* ]]
    [[ "$CAPTURED_STDERR" == *"QUICK STATS"* ]]
    [[ "$CAPTURED_STDERR" == *"OUTPUT SIZE TREND"* ]]
    [[ "$CAPTURED_STDERR" == *"ROUND DETAILS (use"* ]]
    [[ "$CAPTURED_STDERR" == *"Keys: Enter=details  d=diff  r=refresh  ?=help  q=quit"* ]]
    [[ "$CAPTURED_STDERR" == *" >   2"* ]]
    [[ "$CAPTURED_STDERR" != *$'\033'* ]]
}

@test "dashboard_render: desktop sections appear in scan order and stay within 100 columns" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    local metrics
    metrics=$(cat << 'EOF'
{
  "rounds": [
    {"round": 1, "timestamp": "2026-01-01T00:00:00Z", "output": {"char_count": 1000}},
    {"round": 2, "timestamp": "2026-01-02T00:00:00Z", "output": {"char_count": 2000}}
  ],
  "convergence": {
    "confidence": 0.75,
    "estimated_rounds_remaining": 3
  }
}
EOF
)
    DASHBOARD_ROUND_NUMS=(1 2)
    DASHBOARD_ROUND_SIZES=(1000 2000)
    DASHBOARD_ROUND_ADDED=(null 18)
    DASHBOARD_ROUND_DELETED=(null 6)
    # shellcheck disable=SC2034  # Read indirectly by dashboard_render_round_table.
    DASHBOARD_ROUND_SIMILARITY=(null 0.75)
    # shellcheck disable=SC2034  # Read indirectly by dashboard_render_round_table.
    DASHBOARD_ROUND_TS=("2026-01-01T00:00:00Z" "2026-01-02T00:00:00Z")
    DASHBOARD_TOTAL_ROUNDS=2

    capture_streams dashboard_render "default" "$metrics" 0

    local header_line convergence_line stats_line chart_line table_line keys_line
    header_line=$(awk '/APR Analytics Dashboard/ {print NR; exit}' <<<"$CAPTURED_STDERR")
    convergence_line=$(awk '/CONVERGENCE STATUS/ {print NR; exit}' <<<"$CAPTURED_STDERR")
    stats_line=$(awk '/QUICK STATS/ {print NR; exit}' <<<"$CAPTURED_STDERR")
    chart_line=$(awk '/OUTPUT SIZE TREND/ {print NR; exit}' <<<"$CAPTURED_STDERR")
    table_line=$(awk '/ROUND DETAILS/ {print NR; exit}' <<<"$CAPTURED_STDERR")
    keys_line=$(awk '/Keys: Enter=details/ {print NR; exit}' <<<"$CAPTURED_STDERR")

    [[ "$header_line" =~ ^[0-9]+$ ]]
    [[ "$convergence_line" =~ ^[0-9]+$ ]]
    [[ "$stats_line" =~ ^[0-9]+$ ]]
    [[ "$chart_line" =~ ^[0-9]+$ ]]
    [[ "$table_line" =~ ^[0-9]+$ ]]
    [[ "$keys_line" =~ ^[0-9]+$ ]]
    (( header_line < convergence_line ))
    (( convergence_line < stats_line ))
    (( stats_line < chart_line ))
    (( chart_line < table_line ))
    (( table_line < keys_line ))

    local max_width
    max_width=$(printf '%s\n' "$CAPTURED_STDERR" | wc -L | awk '{print $1}')
    [[ "$max_width" =~ ^[0-9]+$ ]]
    (( max_width <= 100 ))
}
