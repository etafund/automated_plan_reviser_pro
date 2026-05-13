#!/usr/bin/env bash
# APR error taxonomy helpers.
#
# This file is intentionally dependency-free so it can be sourced by apr, tests,
# or future command modules. Keep code strings stable; add new codes only when
# callers need a distinct branch.

apr_emit_error_code_tag() {
    local code="${1:-internal_error}"
    printf 'APR_ERROR_CODE=%s\n' "$code" >&2
}

apr_error_human_message() {
    local level="$1"
    local message="$2"

    case "$level" in
        error)
            if declare -F apr_ui_error >/dev/null; then
                apr_ui_error "$message"
            elif declare -F print_error >/dev/null; then
                print_error "$message"
            else
                printf '[apr] error: %s\n' "$message" >&2
            fi
            ;;
        info)
            if declare -F apr_ui_info >/dev/null; then
                apr_ui_info "$message"
            elif declare -F print_info >/dev/null; then
                print_info "$message"
            else
                printf '[apr] info: %s\n' "$message" >&2
            fi
            ;;
        *)
            printf '[apr] %s\n' "$message" >&2
            ;;
    esac
}

apr_error_codes() {
    printf '%s\n' \
        ok \
        usage_error \
        not_configured \
        config_error \
        validation_failed \
        dependency_missing \
        busy \
        network_error \
        update_error \
        attachment_mismatch \
        not_implemented \
        internal_error
}

apr_is_error_code() {
    local code="$1"
    case "$code" in
        ok|usage_error|not_configured|config_error|validation_failed|dependency_missing|busy|network_error|update_error|attachment_mismatch|not_implemented|internal_error)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

apr_error_code_meaning() {
    local code="$1"
    case "$code" in
        ok) printf '%s\n' "Success" ;;
        usage_error) printf '%s\n' "Bad arguments or invalid option values" ;;
        not_configured) printf '%s\n' "APR project is not initialized" ;;
        config_error) printf '%s\n' "Workflow, config, or filesystem configuration problem" ;;
        validation_failed) printf '%s\n' "Precondition failed before running" ;;
        dependency_missing) printf '%s\n' "Required local dependency is unavailable" ;;
        busy) printf '%s\n' "Single-flight lock or busy state blocks this operation" ;;
        network_error) printf '%s\n' "Remote or network operation failed" ;;
        update_error) printf '%s\n' "Self-update failed" ;;
        attachment_mismatch) printf '%s\n' "Attachment or file manifest mismatch" ;;
        not_implemented) printf '%s\n' "Requested feature is not supported in this install" ;;
        internal_error) printf '%s\n' "Unexpected APR bug or unknown state" ;;
        *) printf '%s\n' "Unknown APR error code" ;;
    esac
}

apr_exit_code_for_code() {
    local code="$1"
    case "$code" in
        ok) echo "${EXIT_SUCCESS:-0}" ;;
        usage_error) echo "${EXIT_USAGE_ERROR:-2}" ;;
        dependency_missing) echo "${EXIT_DEPENDENCY_ERROR:-3}" ;;
        not_configured|config_error|validation_failed|attachment_mismatch) echo "${EXIT_CONFIG_ERROR:-4}" ;;
        network_error) echo "${EXIT_NETWORK_ERROR:-10}" ;;
        update_error) echo "${EXIT_UPDATE_ERROR:-11}" ;;
        busy) echo "${EXIT_BUSY_ERROR:-12}" ;;
        not_implemented|internal_error) echo "${EXIT_PARTIAL_FAILURE:-1}" ;;
        *) echo "${EXIT_PARTIAL_FAILURE:-1}" ;;
    esac
}

apr_error_code_table() {
    local code
    while IFS= read -r code; do
        printf '%s\t%s\t%s\n' \
            "$code" \
            "$(apr_exit_code_for_code "$code")" \
            "$(apr_error_code_meaning "$code")"
    done < <(apr_error_codes)
}

apr_fail() {
    local code="${1:-internal_error}"
    local message="${2:-Unexpected APR failure}"
    local hint="${3:-}"
    local exit_code

    if ! apr_is_error_code "$code"; then
        code="internal_error"
    fi

    apr_error_human_message error "$message"
    [[ -n "$hint" ]] && apr_error_human_message info "$hint"
    apr_emit_error_code_tag "$code"
    exit_code="$(apr_exit_code_for_code "$code")"

    local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    if [[ "$caller" != "$0" ]]; then
        return "$exit_code"
    fi
    exit "$exit_code"
}
