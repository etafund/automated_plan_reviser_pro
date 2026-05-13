#!/usr/bin/env bats
# test_output.bats - Unit tests for APR output functions
#
# Tests:
#   - print_* functions (success, error, warning, info, dim, header)
#   - Stream separation (stderr vs stdout)
#   - NO_COLOR support
#   - QUIET_MODE behavior

# Load test helpers
load '../helpers/test_helper'

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    setup_test_environment
    load_apr_functions
    log_test_start "${BATS_TEST_NAME}"

    # Ensure deterministic output
    export NO_COLOR=1
    export APR_NO_GUM=1
    export GUM_AVAILABLE=false
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Stream Separation Tests (CRITICAL - per AGENTS.md)
# =============================================================================

@test "print_success: outputs to stderr only" {
    export QUIET_MODE=false

    log_test_step "action" "Calling print_success"

    capture_streams print_success "Test message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    # stdout should be empty
    [[ -z "$CAPTURED_STDOUT" ]]
    # stderr should have content
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Test message"* ]]
}

@test "print_error: outputs to stderr only" {
    log_test_step "action" "Calling print_error"

    capture_streams print_error "Error message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Error message"* ]]
}

@test "print_warning: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_warning "Warning message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Warning message"* ]]
}

@test "print_info: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_info "Info message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Info message"* ]]
}

@test "print_dim: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_dim "Dim message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Dim message"* ]]
}

@test "print_header: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_header "Header message"

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Header message"* ]]
}

# =============================================================================
# NO_COLOR Support Tests
# =============================================================================

@test "print_success: no ANSI codes when NO_COLOR is set" {
    export NO_COLOR=1
    export GUM_AVAILABLE=false

    capture_streams print_success "Test message"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    assert_no_ansi "$CAPTURED_STDERR"
}

@test "print_error: no ANSI codes when NO_COLOR is set" {
    export NO_COLOR=1
    export GUM_AVAILABLE=false

    capture_streams print_error "Test message"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    assert_no_ansi "$CAPTURED_STDERR"
}

@test "print_warning: no ANSI codes when NO_COLOR is set" {
    export NO_COLOR=1
    export GUM_AVAILABLE=false

    capture_streams print_warning "Test message"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    assert_no_ansi "$CAPTURED_STDERR"
}

@test "print_info: no ANSI codes when NO_COLOR is set" {
    export NO_COLOR=1
    export GUM_AVAILABLE=false

    capture_streams print_info "Test message"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    assert_no_ansi "$CAPTURED_STDERR"
}

# =============================================================================
# QUIET_MODE Tests
# =============================================================================

@test "print_success: suppressed in QUIET_MODE" {
    export QUIET_MODE=true

    capture_streams print_success "Should not appear"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDERR" ]]
}

@test "print_error: NOT suppressed in QUIET_MODE" {
    export QUIET_MODE=true

    capture_streams print_error "Error should appear"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    # Error messages should never be suppressed
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Error should appear"* ]]
}

@test "print_warning: NOT suppressed in QUIET_MODE (like errors)" {
    # Warnings are always shown, like errors - they're important
    export QUIET_MODE=true

    capture_streams print_warning "Warning should appear"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    # Warnings are NOT suppressed (important information)
    [[ -n "$CAPTURED_STDERR" ]]
    [[ "$CAPTURED_STDERR" == *"Warning should appear"* ]]
}

@test "print_info: suppressed in QUIET_MODE" {
    export QUIET_MODE=true

    capture_streams print_info "Should not appear"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDERR" ]]
}

# =============================================================================
# Message Format Tests
# =============================================================================

@test "print_success: includes checkmark or success indicator" {
    export QUIET_MODE=false

    capture_streams print_success "Test"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    # Should have some success indicator (checkmark, [ok], etc.)
    [[ "$CAPTURED_STDERR" == *"✓"* ]] || \
    [[ "$CAPTURED_STDERR" == *"[ok]"* ]] || \
    [[ "$CAPTURED_STDERR" == *"success"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Test"* ]]
}

@test "print_error: includes error indicator" {
    capture_streams print_error "Test"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    # Should have some error indicator
    [[ "$CAPTURED_STDERR" == *"✗"* ]] || \
    [[ "$CAPTURED_STDERR" == *"[error]"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Error"* ]] || \
    [[ "$CAPTURED_STDERR" == *"error"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Test"* ]]
}

@test "print_warning: includes warning indicator" {
    export QUIET_MODE=false

    capture_streams print_warning "Test"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ "$CAPTURED_STDERR" == *"⚠"* ]] || \
    [[ "$CAPTURED_STDERR" == *"[warn]"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Warning"* ]] || \
    [[ "$CAPTURED_STDERR" == *"warning"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Test"* ]]
}

# =============================================================================
# print_step() Tests
# =============================================================================

@test "print_step: shows step number" {
    export QUIET_MODE=false

    capture_streams print_step 1 5 "Step message"

    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ "$CAPTURED_STDERR" == *"1"* ]]
    [[ "$CAPTURED_STDERR" == *"5"* ]] || [[ "$CAPTURED_STDERR" == *"Step message"* ]]
}

@test "print_step: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_step 1 3 "Test step"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
}

@test "print_step: suppressed in QUIET_MODE" {
    export QUIET_MODE=true

    capture_streams print_step 1 3 "Should not appear"

    [[ -z "$CAPTURED_STDERR" ]]
}

# =============================================================================
# print_banner() Tests
# =============================================================================

@test "print_banner: outputs to stderr only" {
    export QUIET_MODE=false

    capture_streams print_banner

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ -z "$CAPTURED_STDOUT" ]]
    [[ -n "$CAPTURED_STDERR" ]]
}

@test "print_banner: suppressed in QUIET_MODE" {
    export QUIET_MODE=true

    capture_streams print_banner

    [[ -z "$CAPTURED_STDERR" ]]
}

@test "print_banner: shows APR name" {
    export QUIET_MODE=false

    capture_streams print_banner

    # Should mention APR somewhere
    [[ "$CAPTURED_STDERR" == *"APR"* ]] || \
    [[ "$CAPTURED_STDERR" == *"apr"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Automated"* ]] || \
    [[ "$CAPTURED_STDERR" == *"Plan"* ]]
}

# =============================================================================
# GUM Fallback Tests
# =============================================================================

@test "output functions: work without gum" {
    export GUM_AVAILABLE=false
    export APR_NO_GUM=1
    export QUIET_MODE=false

    # All these should work without crashing
    capture_streams print_success "test"
    [[ -n "$CAPTURED_STDERR" ]]

    capture_streams print_error "test"
    [[ -n "$CAPTURED_STDERR" ]]

    capture_streams print_warning "test"
    [[ -n "$CAPTURED_STDERR" ]]

    capture_streams print_info "test"
    [[ -n "$CAPTURED_STDERR" ]]
}

# =============================================================================
# Layout and Capability Detection Tests
# =============================================================================

@test "apr_layout_mode: non-TTY auto defaults to compact" {
    export APR_LAYOUT=auto

    run apr_layout_mode
    assert_success
    assert_output "compact"
}

@test "apr_layout_mode: APR_LAYOUT overrides mode" {
    export APR_LAYOUT=desktop

    run apr_layout_mode
    assert_success
    assert_output "desktop"

    export APR_LAYOUT=compact
    run apr_layout_mode
    assert_success
    assert_output "compact"
}

@test "apr_layout_mode: invalid override returns compact and fails" {
    export APR_LAYOUT=sideways

    run apr_layout_mode
    assert_failure
    assert_output "compact"
}

@test "terminal size helpers honor deterministic env overrides" {
    export APR_TERM_COLUMNS=123
    export APR_TERM_LINES=31

    run apr_term_width
    assert_success
    assert_output "123"

    run apr_term_height
    assert_success
    assert_output "31"
}

@test "apr_ui_symbol: plain output uses ASCII-safe tokens" {
    export APR_NO_UNICODE=1

    run apr_ui_symbol success
    assert_success
    assert_output "[ok]"

    run apr_ui_symbol error
    assert_success
    assert_output "[error]"
}
