#!/usr/bin/env bats
# test_v18_workflow_explain.bats - Unit tests for apr workflow explain

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    
    mkdir -p .apr/workflows
    echo "default_workflow: test" > .apr/config.yaml
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
implementation: apr
model: gpt-4
output_dir: rounds
impl_every_n: 2
EOF
    echo "test" > README.md
    echo "test" > SPEC.md
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr workflow explain returns correct resolved paths" {
    run "${PROJECT_ROOT}/apr" workflow explain -w test 1 --json
    assert_success
    assert_output --partial '"readme": "README.md"'
    assert_output --partial '"spec": "SPEC.md"'
}

@test "apr workflow explain computes include_impl correctly" {
    # Round 1: include_impl should be false (impl_every_n: 2)
    run "${PROJECT_ROOT}/apr" workflow explain -w test 1 --json
    assert_success
    assert_output --partial '"include_impl": false'
    
    # Round 2: include_impl should be true
    run "${PROJECT_ROOT}/apr" workflow explain -w test 2 --json
    assert_success
    assert_output --partial '"include_impl": true'
}

@test "apr lint warns on unknown workflow keys" {
    echo "unknown_key: value" >> .apr/workflows/test.yaml
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    assert_output --partial "Unknown key in workflow: unknown_key"
}
