#!/usr/bin/env bats
# test_prompt_placeholder_guard.bats
#
# Bead bd-1s9 (Testing Infrastructure / ufc epic):
#   - prove the canonical attached-file template fixture passes APR's
#     prompt quality check (no `{{...}}` leakage),
#   - prove the guard fixture is rejected by default with an instructive
#     error and a stable exit code,
#   - prove the documented escape hatch (APR_ALLOW_CURLY_PLACEHOLDERS=1)
#     actually bypasses the guard.
#
# Every test drops a timestamped artifact directory under
#   tests/logs/e2e/<ts>__<test>/{stdout.log,stderr.log,env.txt,cmdline.txt}
# matching the ufc epic "Logging & Artifacts" contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# install_fixture_workflow <fixture_basename> <workflow_name>
#
# Drop the fixture YAML in under .apr/workflows/<workflow_name>.yaml and
# stand up the required source documents the workflow expects to attach.
install_fixture_workflow() {
    local fixture="$1"          # e.g. with_template.yaml
    local workflow="$2"         # e.g. template

    cd "$TEST_PROJECT" || return 1

    mkdir -p .apr/workflows ".apr/rounds/$workflow"

    cat > .apr/config.yaml <<EOF
default_workflow: $workflow
EOF

    cp "$FIXTURES_DIR/configs/$fixture" ".apr/workflows/$workflow.yaml"

    # Override output_dir so each fixture lands in its own rounds dir.
    if command -v sed &>/dev/null; then
        sed -i.bak "s#^\(\s*output_dir:\).*#\1 .apr/rounds/$workflow#" \
            ".apr/workflows/$workflow.yaml" 2>/dev/null || true
        rm -f ".apr/workflows/$workflow.yaml.bak"
    fi

    # Documents the fixture expects to attach.
    cat > README.md <<'EOF'
# Sample README

Hello world.
EOF
    cat > SPECIFICATION.md <<'EOF'
# Sample Specification

A short spec for placeholder-guard testing.
EOF
    cat > IMPLEMENTATION.md <<'EOF'
# Sample Implementation

A placeholder implementation note.
EOF
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    setup_mock_oracle
    start_test_artifacts "e2e" "${BATS_TEST_NAME}"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    # Preserve any generated .apr/ content for post-mortem.
    if [[ -d "$TEST_PROJECT/.apr" ]]; then
        save_artifact "$TEST_PROJECT/.apr" "apr_dir"
    fi
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Canonical (default-safe) template
# ---------------------------------------------------------------------------

@test "guard: canonical attached-file template renders without placeholders" {
    install_fixture_workflow "with_template.yaml" "template"

    # --render asks Oracle (the mock) to print the rendered bundle. Critically
    # it routes through prompt_quality_check first, so this also asserts the
    # fixture clears the guard.
    run_with_artifacts "$APR_SCRIPT" run 1 --render

    log_test_output "$output"

    [[ "$status" -eq 0 ]] || {
        echo "render exited $status with output:" >&2
        echo "$output" >&2
        return 1
    }

    # The rendered bundle must not leak any mustache tokens.
    if grep -Fq '{{' "$ARTIFACT_DIR/stdout.log" || \
       grep -Fq '}}' "$ARTIFACT_DIR/stdout.log"; then
        echo "stdout still contains '{{' or '}}':" >&2
        cat "$ARTIFACT_DIR/stdout.log" >&2
        return 1
    fi

    # And the fixture itself must not be reintroducing placeholders.
    run grep -F '{{' "$TEST_PROJECT/.apr/workflows/template.yaml"
    [[ "$status" -ne 0 ]]
}

@test "guard: canonical fixture passes dry-run (no template QC failure)" {
    install_fixture_workflow "with_template.yaml" "template"

    run_with_artifacts "$APR_SCRIPT" run 1 --dry-run

    [[ "$status" -eq 0 ]]
    # No QC failure surface (the failure message uses a recognizable prefix).
    if grep -Fq 'Prompt quality check failed' "$ARTIFACT_DIR/stderr.log"; then
        return 1
    fi
    if grep -Fq 'unexpanded placeholders' "$ARTIFACT_DIR/stderr.log"; then
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Guard fixture (kept intentionally with {{...}})
# ---------------------------------------------------------------------------

@test "guard: placeholders fixture is rejected by default with instructive error" {
    install_fixture_workflow "with_placeholders_guard.yaml" "guard"

    # No bypass set: APR must refuse.
    unset APR_ALLOW_CURLY_PLACEHOLDERS

    run_with_artifacts "$APR_SCRIPT" run 1 --render

    # Should fail.
    [[ "$status" -ne 0 ]]

    # Should explain *why* and *how to fix it* (this is the value of the
    # guard: cheap-and-loud failures instead of a wasted Oracle round).
    grep -Fq 'unexpanded placeholders' "$ARTIFACT_DIR/stderr.log"
    grep -Fq 'APR does not substitute' "$ARTIFACT_DIR/stderr.log"
    grep -Fq 'APR_ALLOW_CURLY_PLACEHOLDERS=1' "$ARTIFACT_DIR/stderr.log"

    # And the guard fixture itself must still contain placeholders so this
    # test does not silently rot.
    grep -Fq '{{README}}' "$FIXTURES_DIR/configs/with_placeholders_guard.yaml"
}

@test "guard: APR_ALLOW_CURLY_PLACEHOLDERS=1 bypass lets render proceed" {
    install_fixture_workflow "with_placeholders_guard.yaml" "guard"

    APR_ALLOW_CURLY_PLACEHOLDERS=1 \
        run_with_artifacts "$APR_SCRIPT" run 1 --render

    [[ "$status" -eq 0 ]] || {
        echo "bypass run failed (status=$status):" >&2
        echo "--- stdout ---" >&2; cat "$ARTIFACT_DIR/stdout.log" >&2
        echo "--- stderr ---" >&2; cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }

    # No QC failure message in stderr.
    if grep -Fq 'Prompt quality check failed' "$ARTIFACT_DIR/stderr.log"; then
        return 1
    fi
}

@test "redact: APR_REDACT=1 redacts resolved prompt before render" {
    install_fixture_workflow "with_template.yaml" "redact"

    cat > "$TEST_PROJECT/.apr/workflows/redact.yaml" <<'EOF'
name: redact-workflow
documents:
  readme: README.md
  spec: SPECIFICATION.md
oracle:
  model: "5.2 Thinking"
rounds:
  output_dir: .apr/rounds/redact
template: |
  Please review this plan.
  Diagnostic token: sk-aabbccddeeff112233445566778899XYZABC
EOF

    cat > "$TEST_DIR/bin/oracle" <<'EOF'
#!/usr/bin/env bash
prompt=""
while (($#)); do
    case "$1" in
        --version)
            echo "oracle 0.8.4 (mock)"
            exit 0
            ;;
        --help)
            echo "Usage: oracle [options]"
            exit 0
            ;;
        -p)
            shift
            prompt="${1-}"
            ;;
    esac
    shift || true
done
printf '%s\n' "$prompt"
EOF
    chmod +x "$TEST_DIR/bin/oracle"

    APR_REDACT=1 run_with_artifacts "$APR_SCRIPT" run 1 --render --no-lint

    [[ "$status" -eq 0 ]] || {
        echo "render exited $status with output:" >&2
        echo "$output" >&2
        return 1
    }

    grep -Fq '<<REDACTED:OPENAI_KEY>>' "$ARTIFACT_DIR/stdout.log"
    if grep -Fq 'sk-aabbccddeeff112233445566778899XYZABC' "$ARTIFACT_DIR/stdout.log"; then
        return 1
    fi
    grep -Fq 'Prompt redaction applied: 1 replacement(s)' "$ARTIFACT_DIR/stderr.log"
}

# ---------------------------------------------------------------------------
# Regression: no other fixture leaks {{...}}
# ---------------------------------------------------------------------------

@test "guard: no fixture except the explicit guard contains '{{' or '}}'" {
    # Walk every fixture under tests/fixtures/ and look for unexpanded
    # mustache tokens. Only the named guard fixture is allowed to carry them.
    local fixtures_root="$FIXTURES_DIR"
    local offenders=()

    while IFS= read -r -d '' f; do
        case "$f" in
            "$fixtures_root/configs/with_placeholders_guard.yaml")
                continue
                ;;
        esac
        if grep -F -q -e '{{' -e '}}' "$f"; then
            offenders+=("$f")
        fi
    done < <(find "$fixtures_root" -type f -print0)

    if (( ${#offenders[@]} > 0 )); then
        {
            echo "Fixtures with mustache placeholders other than the explicit guard fixture:"
            printf '  %s\n' "${offenders[@]}"
        } > "$ARTIFACT_DIR/offenders.txt"
        cat "$ARTIFACT_DIR/offenders.txt" >&2
        return 1
    fi
}
