#!/usr/bin/env bats
# test_v18_history_show_ux.bats - Unit tests for history and show UX refresh (0br)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    
    mkdir -p .apr/workflows
    echo "default_workflow: test" > .apr/config.yaml
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: gpt-4
output_dir: rounds
EOF
    
    mkdir -p .apr/rounds/test
    echo "Round 1 content" > .apr/rounds/test/round_1.md
    echo "Round 2 content" > .apr/rounds/test/round_2.md
    
    # Set fixed timestamps for determinism if possible, but du/stat might vary.
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr history desktop layout shows previews" {
    export APR_LAYOUT=desktop
    export NO_COLOR=1
    run "${PROJECT_ROOT}/apr" history -w test
    assert_success
    assert_output --partial "REVISION HISTORY: test"
    assert_output --partial "Round 1"
    assert_output --partial "Round 2"
    assert_output --partial "Round 2 content"
}

@test "apr history compact layout is high-density" {
    export APR_LAYOUT=compact
    export NO_COLOR=1
    run "${PROJECT_ROOT}/apr" history -w test
    assert_success
    assert_output --partial "HISTORY · test"
    assert_output --partial "R1"
    assert_output --partial "R2"
    # Compact should NOT have full content preview
    refute_output --partial "Round 2 content"
}

@test "apr show displays header and CTA" {
    export APR_LAYOUT=desktop
    export NO_COLOR=1
    # We mock pager to avoid hanging
    export PAGER=cat
    run "${PROJECT_ROOT}/apr" show 1 -w test
    assert_success
    assert_output --partial "ROUND 1: test"
    assert_output --partial "Round 1 content"
    assert_output --partial "-> Compare: apr diff 0 1"
}

@test "apr diff displays refreshed header and CTA" {
    export APR_LAYOUT=desktop
    export NO_COLOR=1
    # We use a mock diff to avoid dependency on 'diff' or 'delta' version
    # but the script already uses them. We'll just check the header.
    run "${PROJECT_ROOT}/apr" diff 1 2 -w test
    assert_success
    assert_output --partial "ROUND COMPARISON: 1 → 2"
    assert_output --partial "-> Integrate: apr integrate 2"
}

@test "apr integrate displays refreshed header and CTA" {
    export APR_LAYOUT=desktop
    export NO_COLOR=1
    run "${PROJECT_ROOT}/apr" integrate 1 -w test
    assert_success
    assert_output --partial "CLAUDE CODE INTEGRATION PROMPT"
    assert_output --partial "Copy the following prompt"
    assert_output --partial "-> Copy: apr integrate 1 --copy"
}
