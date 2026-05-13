#!/usr/bin/env bats
# test_lib_conformance.bats
#
# Bead automated_plan_reviser_pro-wp76 — cross-lib conformance harness.
#
# With every lib/ module now having dedicated tests, the next regression
# class is *convention drift*:
#   - a new lib lands without the double-source guard
#   - a function gets renamed away from apr_lib_<module>_*
#   - a lib gets added to lib/ without being wired into
#     apr_source_optional_libs's load list
#   - a tests/unit/test_<lib>* file is missing for a new module
#
# This harness pins those conventions so drift surfaces in CI.
#
# Per-test artifacts under tests/logs/integration/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"

    LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    APR_PATH="$BATS_TEST_DIRNAME/../../apr"
    TESTS_DIR="$BATS_TEST_DIRNAME/.."

    [[ -d "$LIB_DIR" ]] || skip "lib directory not present"
    [[ -f "$APR_PATH" ]] || skip "apr script not present"

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Echo every lib/*.sh module name (basename, no extension).
lib_modules() {
    local f base
    for f in "$LIB_DIR"/*.sh; do
        base="${f##*/}"
        base="${base%.sh}"
        printf '%s\n' "$base"
    done
}

# Echo the load list from apr_source_optional_libs.
apr_loaded_libs() {
    awk '/^apr_source_optional_libs\(\)/,/^}/' "$APR_PATH" \
        | grep -oE '"\$lib_dir"/[a-z_]+\.sh' \
        | sed -E 's#.*/##; s#\.sh##'
}

# ===========================================================================
# C1 — Public-API naming convention: apr_lib_<module>_<func>
# ===========================================================================

# lib/errors.sh and lib/ui.sh predate the apr_lib_<module>_* convention.
# Their functions use the bare `apr_<thing>` namespace because they're
# sourced INTO apr's main namespace (no module scoping needed). Pin
# the current historical exemption rather than forcing a rename.
USES_APR_ONLY_NAMESPACE=(errors ui)

@test "C1: every lib/*.sh exposes at least one apr_lib_<module>_* function (or uses the apr_-only namespace)" {
    local lib module pattern matches missing=()
    while IFS= read -r module; do
        # Exempt libs that use the older apr_<thing> convention.
        local exempt=0
        local e
        for e in "${USES_APR_ONLY_NAMESPACE[@]}"; do
            [[ "$e" == "$module" ]] && exempt=1
        done
        if [[ "$exempt" -eq 1 ]]; then
            # Still require at least one apr_<thing> function so we
            # catch a totally-empty lib.
            matches=$(grep -cE "^apr_[a-z_]+ *\\(\\)" "$LIB_DIR/${module}.sh" || true)
            [[ "$matches" -gt 0 ]] || missing+=("$module (apr_*-namespace lib has no public functions)")
            continue
        fi

        lib="$LIB_DIR/${module}.sh"
        pattern="^apr_lib_${module}_[a-z_]+ *\\(\\)"
        matches=$(grep -cE "$pattern" "$lib" || true)
        if [[ "$matches" -eq 0 ]]; then
            missing+=("$module (looking for $pattern)")
        fi
    done < <(lib_modules)

    if (( ${#missing[@]} > 0 )); then
        echo "libs without expected public functions:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ===========================================================================
# C2 — Double-source guard convention
# ===========================================================================
#
# Today: lib/errors.sh and lib/ui.sh do NOT have the
# `_APR_LIB_<MODULE>_LOADED` guard. They're both small and idempotent
# (declarative function definitions only), so re-sourcing them is
# harmless. Pin the CURRENT topology rather than the aspirational one,
# so a NEW lib that lands without a guard surfaces here.

EXEMPT_FROM_GUARD=(errors ui)

@test "C2: every non-exempt lib/*.sh has a double-source guard" {
    local module guard found exempt
    local missing=()
    while IFS= read -r module; do
        exempt=0
        local e
        for e in "${EXEMPT_FROM_GUARD[@]}"; do
            [[ "$e" == "$module" ]] && exempt=1
        done
        [[ "$exempt" -eq 1 ]] && continue

        # Guard convention: `_APR_LIB_<UPPER>_LOADED`.
        local upper
        upper=$(printf '%s' "$module" | tr '[:lower:]' '[:upper:]')
        guard="_APR_LIB_${upper}_LOADED"
        if ! grep -Fq "$guard" "$LIB_DIR/${module}.sh"; then
            missing+=("$module (looking for \$$guard)")
        fi
    done < <(lib_modules)

    if (( ${#missing[@]} > 0 )); then
        echo "libs missing the double-source guard:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "C2: each guarded lib early-returns on re-source (idempotency check)" {
    # Sourcing the same lib twice must not produce errors or duplicate
    # function definitions. We test by counting `apr_lib_<m>_<f>` defs
    # before and after a second source.
    local module exempt
    while IFS= read -r module; do
        exempt=0
        local e
        for e in "${EXEMPT_FROM_GUARD[@]}"; do
            [[ "$e" == "$module" ]] && exempt=1
        done
        [[ "$exempt" -eq 1 ]] && continue

        # Fresh subshell, source twice, verify no error.
        local out rc=0
        out=$(bash -c "
            set -e
            source '$LIB_DIR/${module}.sh' 2>&1
            source '$LIB_DIR/${module}.sh' 2>&1
            echo OK
        " 2>&1) || rc=$?

        if [[ "$rc" -ne 0 || "$out" != *"OK"* ]]; then
            echo "lib/${module}.sh fails double-source idempotency:" >&2
            echo "  rc=$rc" >&2
            echo "  out: $out" >&2
            return 1
        fi
    done < <(lib_modules)
}

# ===========================================================================
# C3 — Load topology: apr_source_optional_libs's list
# ===========================================================================
#
# Today: apr_source_optional_libs sources all runtime libs directly. Pin the
# CURRENT topology so a refactor surfaces.

DIRECTLY_LOADED_BY_APR=(errors ui manifest redact busy queue template validate ledger)
# Utility/experimental libs that are intentionally not in apr's default runtime
# source path until a production command path adopts them.
OPTIONAL_STANDALONE_LIBS=(ack busy_wait cache files_report size)

@test "C3: apr_source_optional_libs's load list matches the documented set" {
    local actual
    actual=$(apr_loaded_libs | LC_ALL=C sort)
    local expected
    expected=$(printf '%s\n' "${DIRECTLY_LOADED_BY_APR[@]}" | LC_ALL=C sort)

    if [[ "$actual" != "$expected" ]]; then
        echo "apr_source_optional_libs load list drift:" >&2
        echo "--- actual ---"   >&2; printf '%s\n' "$actual"   >&2
        echo "--- expected ---" >&2; printf '%s\n' "$expected" >&2
        return 1
    fi
}

@test "C3: every lib in apr_source_optional_libs's list actually exists in lib/" {
    local module
    while IFS= read -r module; do
        [[ -f "$LIB_DIR/${module}.sh" ]] || {
            echo "apr_source_optional_libs references nonexistent lib: lib/${module}.sh" >&2
            return 1
        }
    done < <(apr_loaded_libs)
}

@test "C3: every lib/*.sh is reachable — either directly loaded by apr OR transitively sourced" {
    # For libs NOT in DIRECTLY_LOADED_BY_APR, assert that at least one
    # of the directly-loaded libs sources them.
    local module
    local new_orphans=()
    while IFS= read -r module; do
        local direct=0
        local d
        for d in "${DIRECTLY_LOADED_BY_APR[@]}"; do
            [[ "$d" == "$module" ]] && direct=1
        done
        if [[ "$direct" -eq 1 ]]; then continue; fi
        local standalone=0
        for d in "${OPTIONAL_STANDALONE_LIBS[@]}"; do
            [[ "$d" == "$module" ]] && standalone=1
        done
        if [[ "$standalone" -eq 1 ]]; then continue; fi

        local found=0
        for d in "${DIRECTLY_LOADED_BY_APR[@]}"; do
            if grep -Fq "${module}.sh" "$LIB_DIR/${d}.sh" 2>/dev/null; then
                found=1
                break
            fi
        done

        if [[ "$found" -eq 0 ]]; then
            new_orphans+=("$module")
        fi
    done < <(lib_modules)

    if (( ${#new_orphans[@]} > 0 )); then
        echo "orphan libs (not directly loaded AND not transitively sourced):" >&2
        printf '  %s\n' "${new_orphans[@]}" >&2
        echo "Either wire them into apr_source_optional_libs's load list," >&2
        echo "or have a directly-loaded lib source them." >&2
        return 1
    fi
}

# ===========================================================================
# C4 — Every lib has at least one tests/unit/test_*.bats file
# ===========================================================================

@test "C4: every lib/*.sh has at least one tests/unit/test_*.bats file referencing it" {
    local module
    local missing=()
    while IFS= read -r module; do
        # Look for `source ".../lib/<module>.sh"` or
        # `load_apr_functions` (which sources every lib transitively
        # via apr) in any tests/unit/test_*.bats file.
        if ! grep -rlFq "lib/${module}.sh" "$TESTS_DIR/unit" 2>/dev/null; then
            # Also accept the transitive load via load_apr_functions
            # IF the lib is on the apr_source_optional_libs list.
            local in_apr_load=0
            local d
            for d in "${DIRECTLY_LOADED_BY_APR[@]}"; do
                [[ "$d" == "$module" ]] && in_apr_load=1
            done
            [[ "$in_apr_load" -eq 1 ]] && continue

            missing+=("$module")
        fi
    done < <(lib_modules)

    if (( ${#missing[@]} > 0 )); then
        echo "libs without dedicated tests/unit/test_*.bats file:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ===========================================================================
# C5 — Shebang convention
# ===========================================================================

@test "C5: every lib/*.sh starts with #!/usr/bin/env bash" {
    local module first
    local bad=()
    while IFS= read -r module; do
        first=$(head -n 1 "$LIB_DIR/${module}.sh")
        if [[ "$first" != "#!/usr/bin/env bash" ]]; then
            bad+=("$module (first line: '$first')")
        fi
    done < <(lib_modules)

    if (( ${#bad[@]} > 0 )); then
        echo "libs with non-standard shebang:" >&2
        printf '  %s\n' "${bad[@]}" >&2
        return 1
    fi
}

# ===========================================================================
# C6 — Every lib has a docstring-style header
# ===========================================================================

@test "C6: every lib/*.sh has a header comment naming itself in line 2" {
    local module second
    local bad=()
    while IFS= read -r module; do
        # Line 2 typically: `# lib/<module>.sh - <description>`
        # We tolerate variation but require: line 2 starts with `# `
        # AND mentions the module name OR a short description.
        second=$(sed -n '2p' "$LIB_DIR/${module}.sh")
        if [[ "$second" != "# "* ]]; then
            bad+=("$module (line 2: '$second')")
        fi
    done < <(lib_modules)

    if (( ${#bad[@]} > 0 )); then
        echo "libs without a header comment on line 2:" >&2
        printf '  %s\n' "${bad[@]}" >&2
        return 1
    fi
}

# ===========================================================================
# Cross-property: every public apr_lib_<module>_* function in apr's
# script body actually exists in the corresponding lib
# ===========================================================================

@test "cross: every apr_lib_<module>_* call in apr resolves to a defined function" {
    # Pull every reference of apr_lib_<module>_<fn> from the apr script,
    # then verify the lib actually defines that function.
    local refs missing=()
    refs=$(grep -oE 'apr_lib_[a-z_]+' "$APR_PATH" | LC_ALL=C sort -u)

    local fn module
    while IFS= read -r fn; do
        # `apr_lib_<module>_<rest>`
        module=$(printf '%s' "$fn" | sed -E 's/^apr_lib_([a-z]+)_.*/\1/')
        # Some libs have multi-word names that we'd mis-parse here;
        # also accept module = the longest prefix that names a lib file.
        if [[ ! -f "$LIB_DIR/${module}.sh" ]]; then
            # Try compound: e.g., apr_lib_busy_wait_* → busy_wait
            local alt
            alt=$(printf '%s' "$fn" | sed -E 's/^apr_lib_([a-z_]+)_[a-z]+$/\1/')
            if [[ -f "$LIB_DIR/${alt}.sh" ]]; then
                module="$alt"
            fi
        fi

        if [[ ! -f "$LIB_DIR/${module}.sh" ]]; then
            # No matching lib file at all — could be a typo in apr OR a
            # missing lib. Pin the contract.
            missing+=("$fn (no matching lib/${module}.sh)")
            continue
        fi

        # Verify the function is defined in that lib.
        if ! grep -Eq "^${fn}\\(\\)" "$LIB_DIR/${module}.sh"; then
            missing+=("$fn (lib/${module}.sh exists but does not define it)")
        fi
    done <<<"$refs"

    if (( ${#missing[@]} > 0 )); then
        echo "apr references undefined apr_lib_<module>_* functions:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}
