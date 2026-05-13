#!/usr/bin/env bats
# test_stats_desktop_ux.bats - Desktop UX coverage for apr stats.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"

    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    cd "$TEST_PROJECT" || return
    setup_test_workflow "default"
    write_desktop_stats_metrics
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

write_desktop_stats_metrics() {
    local metrics_dir="$TEST_PROJECT/.apr/analytics/default"
    local ts="2026-01-13T04:00:00Z"
    mkdir -p "$metrics_dir"

    cat > "$metrics_dir/metrics.json" << EOF
{
  "schema_version": "1.0.0",
  "workflow": "default",
  "created_at": "$ts",
  "updated_at": "$ts",
  "rounds": [
    {
      "round": 1,
      "timestamp": "2026-01-13T04:00:00Z",
      "output": {"char_count": 12000},
      "changes_from_previous": null
    },
    {
      "round": 2,
      "timestamp": "2026-01-13T04:10:00Z",
      "output": {"char_count": 9800},
      "changes_from_previous": {
        "lines_added": 160,
        "lines_deleted": 45,
        "diff_ratio": 0.58,
        "similarity_score": 0.54
      }
    },
    {
      "round": 3,
      "timestamp": "2026-01-13T04:20:00Z",
      "output": {"char_count": 8600},
      "changes_from_previous": {
        "lines_added": 95,
        "lines_deleted": 50,
        "diff_ratio": 0.35,
        "similarity_score": 0.72
      }
    },
    {
      "round": 4,
      "timestamp": "2026-01-13T04:30:00Z",
      "output": {"char_count": 7600},
      "changes_from_previous": {
        "lines_added": 45,
        "lines_deleted": 25,
        "diff_ratio": 0.18,
        "similarity_score": 0.89
      }
    }
  ],
  "convergence": {
    "detected": true,
    "confidence": 0.84,
    "estimated_rounds_remaining": 2,
    "signals": {
      "output_size_trend": 0.82,
      "change_velocity": 0.78,
      "similarity_trend": 0.91
    }
  }
}
EOF
}

@test "apr stats --desktop: renders premium desktop hierarchy on stderr" {
    APR_TERM_COLUMNS=120 APR_TERM_LINES=32 capture_streams "$APR_SCRIPT" stats --desktop

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"REVISION STATISTICS: default"* ]]
    [[ "$CAPTURED_STDERR" == *"Rounds: 4"* ]]
    [[ "$CAPTURED_STDERR" == *"Convergence:"*"confidence"* ]]
    [[ "$CAPTURED_STDERR" == *"TREND SPARKLINES"* ]]
    [[ "$CAPTURED_STDERR" == *"ROUND DETAILS"* ]]
    [[ "$CAPTURED_STDERR" == *"CONVERGENCE SIGNALS"* ]]
    [[ "$CAPTURED_STDERR" == *"Nearly converged. Consider 1-2 more rounds."* || "$CAPTURED_STDERR" == *"Significant changes still occurring."* ]]
    [[ "$CAPTURED_STDERR" == *"│"* ]]
    [[ "$CAPTURED_STDERR" == *"Output"* ]]
    [[ "$CAPTURED_STDERR" != *"STATS: default"* ]]
    [[ "$CAPTURED_STDERR" != *$'\033['* ]]

    local line
    while IFS= read -r line; do
        [[ ${#line} -le 120 ]]
    done <<< "$CAPTURED_STDERR"
}
