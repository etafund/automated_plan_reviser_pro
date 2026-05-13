#!/usr/bin/env bash
# APR CLI design tokens, terminal capabilities, and responsive layout helpers.

if [[ -z "${APR_DEFAULT_DESKTOP_MIN_COLS:-}" ]]; then
    APR_DEFAULT_DESKTOP_MIN_COLS=100
fi
if [[ -z "${APR_DEFAULT_DESKTOP_MIN_ROWS:-}" ]]; then
    APR_DEFAULT_DESKTOP_MIN_ROWS=24
fi
readonly APR_DEFAULT_DESKTOP_MIN_COLS APR_DEFAULT_DESKTOP_MIN_ROWS

apr_term_width() {
    local width="${APR_TERM_COLUMNS:-${COLUMNS:-}}"

    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
        printf '%s\n' "$width"
        return 0
    fi

    if [[ -t 2 ]] && command -v tput &>/dev/null; then
        width=$(tput cols 2>/dev/null || true)
        if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
            printf '%s\n' "$width"
            return 0
        fi
    fi

    printf '80\n'
}

apr_term_height() {
    local height="${APR_TERM_LINES:-${LINES:-}}"

    if [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]]; then
        printf '%s\n' "$height"
        return 0
    fi

    if [[ -t 2 ]] && command -v tput &>/dev/null; then
        height=$(tput lines 2>/dev/null || true)
        if [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]]; then
            printf '%s\n' "$height"
            return 0
        fi
    fi

    printf '24\n'
}

apr_color_enabled() {
    [[ -t 2 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    return 0
}

apr_unicode_enabled() {
    [[ -t 2 ]] || return 1
    [[ -z "${APR_NO_UNICODE:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    return 0
}

apr_bool_word() {
    [[ $# -gt 0 ]] || {
        printf 'false\n'
        return 0
    }
    if "$@"; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

apr_stderr_is_tty() {
    [[ -t 2 ]]
}

apr_layout_mode() {
    local override="${APR_LAYOUT:-auto}"
    local min_cols="${APR_DESKTOP_MIN_COLS:-$APR_DEFAULT_DESKTOP_MIN_COLS}"
    local min_rows="${APR_DESKTOP_MIN_ROWS:-$APR_DEFAULT_DESKTOP_MIN_ROWS}"
    local width height

    override="${override,,}"
    case "$override" in
        desktop|wide)
            printf 'desktop\n'
            return 0
            ;;
        compact|mobile)
            printf 'compact\n'
            return 0
            ;;
        auto|"")
            ;;
        *)
            printf 'compact\n'
            return 2
            ;;
    esac

    if [[ ! -t 2 ]]; then
        printf 'compact\n'
        return 0
    fi

    width=$(apr_term_width)
    height=$(apr_term_height)
    if (( width >= min_cols && height >= min_rows )); then
        printf 'desktop\n'
    else
        printf 'compact\n'
    fi
}

apr_gum_allowed() {
    [[ -z "${APR_NO_GUM:-}" ]] || return 1
    [[ -z "${CI:-}" ]] || return 1
    apr_color_enabled || return 1
    command -v gum &>/dev/null || return 1
    return 0
}

apr_terminal_capabilities() {
    local layout layout_status
    local width height
    local color unicode stderr_tty gum

    layout_status=0
    layout=$(apr_layout_mode) || layout_status=$?
    width=$(apr_term_width)
    height=$(apr_term_height)
    stderr_tty=$(apr_bool_word apr_stderr_is_tty)
    color=$(apr_bool_word apr_color_enabled)
    unicode=$(apr_bool_word apr_unicode_enabled)
    gum=$(apr_bool_word apr_gum_allowed)

    printf 'layout=%s\n' "$layout"
    printf 'layout_status=%s\n' "$layout_status"
    printf 'width=%s\n' "$width"
    printf 'height=%s\n' "$height"
    printf 'stderr_tty=%s\n' "$stderr_tty"
    printf 'color=%s\n' "$color"
    printf 'unicode=%s\n' "$unicode"
    printf 'gum=%s\n' "$gum"
}

apr_ui_symbol() {
    local token="$1"
    local unicode=false
    if apr_unicode_enabled; then
        unicode=true
    fi

    case "$token:$unicode" in
        success:true) printf '%s' '✓' ;;
        success:false) printf '%s' '[ok]' ;;
        error:true) printf '%s' '✗' ;;
        error:false) printf '%s' '[error]' ;;
        warning:true) printf '%s' '⚠' ;;
        warning:false) printf '%s' '[warn]' ;;
        info:true) printf '%s' 'ℹ' ;;
        info:false) printf '%s' '[info]' ;;
        arrow:true) printf '%s' '→' ;;
        arrow:false) printf '%s' '->' ;;
        rule:true) printf '%s' '━' ;;
        rule:false) printf '%s' '=' ;;
        light_rule:true) printf '%s' '─' ;;
        light_rule:false) printf '%s' '-' ;;
        *) printf '%s' "$token" ;;
    esac
}

apr_ui_quiet_enabled() {
    [[ "${QUIET_MODE:-false}" == "true" ]]
}

apr_ui_feedback_symbol() {
    local kind="$1"

    case "$kind" in
        success) apr_ui_symbol success ;;
        error) apr_ui_symbol error ;;
        warning|warn) apr_ui_symbol warning ;;
        info) apr_ui_symbol info ;;
        progress|cta) apr_ui_symbol arrow ;;
        *) apr_ui_symbol info ;;
    esac
}

apr_ui_feedback_color() {
    local kind="$1"

    case "$kind" in
        success) printf '%s\n' "82" ;;
        error) printf '%s\n' "196" ;;
        warning|warn) printf '%s\n' "214" ;;
        progress|info|cta) printf '%s\n' "39" ;;
        *) printf '%s\n' "39" ;;
    esac
}

apr_ui_feedback_line() {
    local kind="${1:-info}"
    local message="${2:-}"
    local hint="${3:-}"
    local symbol color

    case "$kind" in
        error|warning|warn) ;;
        *)
            apr_ui_quiet_enabled && return 0
            ;;
    esac

    symbol=$(apr_ui_feedback_symbol "$kind")
    if apr_gum_allowed; then
        color=$(apr_ui_feedback_color "$kind")
        gum style --foreground "$color" "$symbol $message" >&2
    else
        printf '%s %s\n' "$symbol" "$message" >&2
    fi

    if [[ -n "$hint" ]]; then
        if apr_gum_allowed; then
            gum style --faint "  $hint" >&2
        else
            printf '  %s\n' "$hint" >&2
        fi
    fi
}

apr_ui_error() {
    apr_ui_feedback_line error "$@"
}

apr_ui_warn() {
    apr_ui_feedback_line warning "$@"
}

apr_ui_info() {
    apr_ui_feedback_line info "$@"
}

apr_ui_success() {
    apr_ui_feedback_line success "$@"
}

apr_ui_progress() {
    apr_ui_feedback_line progress "$1" "${2:-}"
}

apr_ui_cta() {
    local label="${1:-Next}"
    local command_text="${2:-}"
    local hint="${3:-}"

    [[ -n "$command_text" ]] || return 2
    apr_ui_quiet_enabled && return 0

    apr_ui_feedback_line cta "$label: $command_text" "$hint"
}

apr_ui_banner() {
    local version="${1:-1.0.0}"
    local layout
    layout=$(apr_layout_mode)

    if [[ "$layout" == "desktop" ]]; then
        if apr_gum_allowed; then
            gum style \
                --foreground 212 --border double --border-foreground 212 \
                --padding "1 2" --margin "1 2" --align center --width 60 \
                "APR v${version}" "Iterative AI-Powered Spec Refinement" >&2
        else
            printf '\n  APR v%s\n  Iterative AI-Powered Spec Refinement\n\n' "$version" >&2
        fi
    else
        # Compact/Mobile banner
        if apr_gum_allowed; then
            gum style --foreground 212 --bold "APR v${version}" >&2
        else
            printf 'APR v%s\n' "$version" >&2
        fi
    fi
}

apr_ui_run_step() {
    local message="${1:-Working}"
    shift || true

    if [[ $# -eq 0 ]]; then
        apr_ui_progress "$message"
        return 0
    fi

    if apr_gum_allowed && ! apr_ui_quiet_enabled; then
        gum spin --spinner dot --title "$message" -- "$@"
    else
        apr_ui_progress "$message"
        "$@"
    fi
}

apr_set_layout_override() {
    local value="${1:-auto}"
    value="${value,,}"
    case "$value" in
        auto|desktop|wide|compact|mobile)
            APR_LAYOUT="$value"
            if [[ "$value" == "compact" || "$value" == "mobile" ]]; then
                # shellcheck disable=SC2034  # Consumed by apr after sourcing this helper.
                GUM_AVAILABLE=false
            fi
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
