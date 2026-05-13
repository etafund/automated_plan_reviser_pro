#!/usr/bin/env bats
# test_template_golden.bats
#
# Bead automated_plan_reviser_pro-3g7e — golden-artifact regression
# baselines for lib/template.sh expansion.
#
# tests/unit/test_template.bats already covers each directive in
# isolation. This suite frozen byte-exact expansions of realistic
# multi-directive templates so any subtle interaction change (whitespace,
# newline policy, directive ordering) lights up as a golden diff. Reviewers
# can also inspect the .golden files directly to see exactly what an
# expansion produces today.
#
# Update workflow:
#   UPDATE_GOLDEN=1 tests/lib/bats-core/bin/bats \
#       tests/integration/test_template_golden.bats
# regenerates every .golden file. Diff and commit.
#
# Fixture layout under tests/fixtures/templates/:
#   docs/{readme,spec,impl,notes}.md       — fixture source documents
#   <NN>_<case>.tpl                        — input template
#   .golden/<NN>_<case>.expected           — frozen expansion
#
# Per-test artifacts (input, actual, expected, diff) land under
# tests/logs/integration/<ts>__<test>/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Fixture paths
# ---------------------------------------------------------------------------

_templates_root() {
    printf '%s\n' "$BATS_TEST_DIRNAME/../fixtures/templates"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    # Stage the fixture documents (and *only* those) inside an isolated
    # PROJECT_ROOT so the template engine's path-safety guards have a
    # well-known tree to walk. We deliberately re-create instead of
    # symlinking so SHA/SIZE results match the committed bytes verbatim
    # on every platform.
    PROJECT_ROOT="$TEST_DIR/template_project"
    mkdir -p "$PROJECT_ROOT/docs"
    cp -- "$(_templates_root)/docs/"*.md "$PROJECT_ROOT/docs/"
    export PROJECT_ROOT

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/template.sh"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Golden-case driver
# ---------------------------------------------------------------------------
#
# golden_compare <case-basename>
#
# - reads tests/fixtures/templates/<case>.tpl
# - expands it under $PROJECT_ROOT
# - compares stdout against tests/fixtures/templates/.golden/<case>.expected
#
# Env: UPDATE_GOLDEN=1 rewrites the golden in-place instead of comparing.

golden_compare() {
    local case_name="$1"
    local tpl_path="$(_templates_root)/${case_name}.tpl"
    local golden_path="$(_templates_root)/.golden/${case_name}.expected"

    [[ -f "$tpl_path" ]] || {
        echo "template fixture missing: $tpl_path" >&2
        return 1
    }

    local tpl_body
    tpl_body="$(cat "$tpl_path")"

    local actual="$ARTIFACT_DIR/actual.out"
    local error_log="$ARTIFACT_DIR/expand_err.log"

    # Run the engine. Capture stderr so a failure surfaces with full
    # context in the artifact directory.
    set +e
    apr_lib_template_expand "$tpl_body" "$PROJECT_ROOT" 0 0 0 \
        > "$actual" 2> "$error_log"
    local rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo "apr_lib_template_expand failed (rc=$rc) for $case_name" >&2
        echo "--- stderr ---" >&2; cat "$error_log" >&2
        echo "--- template ---" >&2; cat "$tpl_path" >&2
        return 1
    fi

    # Update-mode: rewrite the golden and stop. The test still passes.
    if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
        mkdir -p "$(dirname "$golden_path")"
        cp -- "$actual" "$golden_path"
        echo "[update-golden] wrote $golden_path" >&2
        return 0
    fi

    [[ -f "$golden_path" ]] || {
        echo "golden file missing: $golden_path" >&2
        echo "run: UPDATE_GOLDEN=1 bats tests/integration/test_template_golden.bats" >&2
        return 1
    }

    if ! diff -u "$golden_path" "$actual" > "$ARTIFACT_DIR/golden.diff" 2>&1; then
        echo "golden diff for $case_name:" >&2
        cat "$ARTIFACT_DIR/golden.diff" >&2
        echo "to refresh: UPDATE_GOLDEN=1 bats tests/integration/test_template_golden.bats" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Golden cases
# ---------------------------------------------------------------------------

@test "golden: 01 no directives — input is returned byte-for-byte" {
    golden_compare "01_no_directives"
}

@test "golden: 02 single FILE directive — inline expansion preserves surrounding text" {
    golden_compare "02_single_file_inline"
}

@test "golden: 03 all directives mixed — SIZE + SHA + FILE + LIT in a realistic layout" {
    golden_compare "03_all_directives_mixed"
}

@test "golden: 04 EXCERPT boundary — small N and huge N both produce stable output" {
    golden_compare "04_excerpt_boundary"
}

@test "golden: 05 LIT protects directive-shaped strings from re-expansion" {
    golden_compare "05_lit_protects_syntax"
}

# ---------------------------------------------------------------------------
# Conformance invariants on the goldens themselves
# ---------------------------------------------------------------------------

@test "golden: every .tpl fixture has a matching .golden/.expected file" {
    local root
    root="$(_templates_root)"

    local missing=()
    local tpl
    while IFS= read -r -d '' tpl; do
        local base="${tpl##*/}"
        base="${base%.tpl}"
        if [[ ! -f "$root/.golden/${base}.expected" ]]; then
            missing+=("$base")
        fi
    done < <(find "$root" -maxdepth 1 -type f -name '*.tpl' -print0)

    if (( ${#missing[@]} > 0 )); then
        echo "templates missing .golden/.expected:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "golden: every .golden/.expected file has a matching .tpl input" {
    local root
    root="$(_templates_root)"

    local orphans=()
    local g
    while IFS= read -r -d '' g; do
        local base="${g##*/}"
        base="${base%.expected}"
        if [[ ! -f "$root/${base}.tpl" ]]; then
            orphans+=("$base")
        fi
    done < <(find "$root/.golden" -maxdepth 1 -type f -name '*.expected' -print0)

    if (( ${#orphans[@]} > 0 )); then
        echo "orphan goldens with no .tpl input:" >&2
        printf '  %s\n' "${orphans[@]}" >&2
        return 1
    fi
}

@test "golden: no expanded output retains '{{...}}' mustache placeholders" {
    # If any expanded golden carries `{{` or `}}`, then either the fixture
    # leaked a placeholder OR the engine left one un-expanded. Both are
    # contract violations per bd-1s9 (placeholder-leak class).
    local root
    root="$(_templates_root)"
    local offenders=()
    local g
    while IFS= read -r -d '' g; do
        if grep -Fq -e '{{' -e '}}' "$g"; then
            offenders+=("$g")
        fi
    done < <(find "$root/.golden" -maxdepth 1 -type f -name '*.expected' -print0)

    if (( ${#offenders[@]} > 0 )); then
        echo "expanded goldens contain mustache placeholders:" >&2
        printf '  %s\n' "${offenders[@]}" >&2
        return 1
    fi
}

@test "golden: expansion is byte-identical on a second run (determinism)" {
    # Re-run case 03 (the most directive-heavy fixture) a second time and
    # diff against the first run. This pins the determinism guarantee at
    # the integration layer (the unit suite has a similar in-memory check).
    local tpl_body
    tpl_body="$(cat "$(_templates_root)/03_all_directives_mixed.tpl")"

    local first="$ARTIFACT_DIR/run1.out"
    local second="$ARTIFACT_DIR/run2.out"

    apr_lib_template_expand "$tpl_body" "$PROJECT_ROOT" 0 0 0 > "$first"
    apr_lib_template_expand "$tpl_body" "$PROJECT_ROOT" 0 0 0 > "$second"

    diff -u "$first" "$second" > "$ARTIFACT_DIR/determinism.diff" 2>&1 || {
        echo "non-deterministic expansion:" >&2
        cat "$ARTIFACT_DIR/determinism.diff" >&2
        return 1
    }
}
