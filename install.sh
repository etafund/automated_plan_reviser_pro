#!/usr/bin/env bash
#
# APR (Automated Plan Reviser Pro) Installer
# Downloads and installs APR to your system with checksum verification
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/automated_plan_reviser_pro/main/install.sh | bash
#
# Options (via environment variables):
#   DEST=/path/to/dir      Install directory (default: ~/.local/bin)
#   APR_SYSTEM=1           Install to /usr/local/bin (requires sudo)
#   APR_NO_DEPS=1          Skip dependency installation
#   APR_VERSION=x.y.z      Install specific version (default: latest from main)
#   APR_SKIP_VERIFY=1      Skip checksum verification (not recommended)
#   NO_COLOR=1             Disable colored output
#
# Exit Codes:
#   0   Success
#   1   General error
#   2   Download failed
#   3   Checksum verification failed
#   4   Installation failed

set -euo pipefail

# Exit codes (documented for consistency with apr)
# shellcheck disable=SC2034  # Documented for reference
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_DOWNLOAD_ERROR=2
readonly EXIT_CHECKSUM_ERROR=3
readonly EXIT_INSTALL_ERROR=4

# Configuration
readonly REPO_OWNER="Dicklesworthstone"
readonly REPO_NAME="automated_plan_reviser_pro"
readonly REPO_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
readonly RELEASES_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
readonly SCRIPT_NAME="apr"
readonly INSTALLER_VERSION="1.1.0"
readonly APR_LIB_FILES=(
    errors.sh
    ui.sh
    manifest.sh
    cache.sh
    size.sh
    redact.sh
    busy.sh
    busy_wait.sh
    queue.sh
    template.sh
    validate.sh
    ack.sh
    files_report.sh
    ledger.sh
)

# Colors (conditional on TTY and NO_COLOR)
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

# Logging functions (all output to stderr)
log_info() { echo -e "${GREEN}[apr]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[apr]${NC} $1" >&2; }
log_error() { echo -e "${RED}[apr]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[apr]${NC} $1" >&2; }
log_dim() { echo -e "${DIM}$1${NC}" >&2; }

# Download a file with retry and progress
download_file() {
    local url="$1"
    local out="$2"
    local max_retries=3
    local retry_delay=2
    local attempt=1

    while (( attempt <= max_retries )); do
        if command -v curl &> /dev/null; then
            if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$out" 2>/dev/null; then
                return 0
            fi
        elif command -v wget &> /dev/null; then
            if wget -q --timeout=60 -O "$out" "$url" 2>/dev/null; then
                return 0
            fi
        else
            log_error "Neither curl nor wget found. Please install one of them."
            return 127
        fi

        if (( attempt < max_retries )); then
            log_warn "Download attempt $attempt failed, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
        ((attempt++))
    done

    return 1
}

# Fetch a URL and return content to stdout
fetch_url() {
    local url="$1"
    if command -v curl &> /dev/null; then
        curl -fsSL --connect-timeout 5 --max-time 30 "$url" 2>/dev/null
    elif command -v wget &> /dev/null; then
        wget -q --timeout=30 -O - "$url" 2>/dev/null
    else
        return 1
    fi
}

# Verify checksum of a file
verify_checksum() {
    local file="$1"
    local expected="$2"

    if [[ -z "$expected" ]]; then
        return 0  # No checksum to verify
    fi

    local actual=""
    if command -v sha256sum &> /dev/null; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command -v shasum &> /dev/null; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        log_warn "No sha256sum or shasum available, skipping verification"
        return 0
    fi

    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        log_error "Checksum mismatch!"
        log_error "  Expected: $expected"
        log_error "  Got:      $actual"
        return 1
    fi
}

# For pinned installs, release assets can drift if the binary is re-uploaded
# while apr.sha256 still points at the original tag content. In that case,
# fall back to downloading the immutable tag source and verify against the same
# expected checksum before continuing.
try_tag_source_fallback() {
    local version="$1"
    local expected_checksum="$2"
    local current_tmp="$3"
    local tag_url=""
    local tag_tmp=""

    if [[ -z "$version" || -z "$expected_checksum" || -z "$current_tmp" ]]; then
        return 1
    fi

    tag_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/v${version}/${SCRIPT_NAME}"
    tag_tmp=$(mktemp)

    log_warn "Release artifact checksum mismatch for v${version}; trying immutable tag source"
    log_dim "  fallback: ${tag_url}"

    if ! download_file "$tag_url" "$tag_tmp"; then
        rm -f "$tag_tmp"
        return 1
    fi

    if ! verify_script "$tag_tmp"; then
        rm -f "$tag_tmp"
        return 1
    fi

    if ! verify_checksum "$tag_tmp" "$expected_checksum"; then
        rm -f "$tag_tmp"
        return 1
    fi

    mv "$tag_tmp" "$current_tmp"
    log_info "Recovered via immutable tag source"
    return 0
}

# Verify downloaded file is a valid bash script
verify_script() {
    local file="$1"
    local first_line=""

    IFS= read -r first_line < "$file" 2>/dev/null || true

    # Accept any valid bash shebang: #!/bin/bash, #!/usr/bin/env bash, etc.
    if [[ ! "$first_line" =~ ^#!.*bash ]]; then
        log_error "Downloaded file is not a valid bash script"
        log_error "Expected bash shebang, got: $first_line"
        return 1
    fi

    # Basic syntax check
    if ! bash -n "$file" 2>/dev/null; then
        log_error "Downloaded script has syntax errors"
        return 1
    fi

    return 0
}

# Verify downloaded file is a valid bash library.
verify_lib_script() {
    local file="$1"

    # Library files are sourced by apr and intentionally do not carry shebangs.
    if ! bash -n "$file" 2>/dev/null; then
        log_error "Downloaded library has syntax errors"
        return 1
    fi

    return 0
}

get_install_dir() {
    if [[ -n "${DEST:-}" ]]; then
        echo "$DEST"
    elif [[ -n "${APR_SYSTEM:-}" ]]; then
        echo "/usr/local/bin"
    else
        echo "${HOME}/.local/bin"
    fi
}

get_shell_config() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")

    case "$shell_name" in
        zsh) echo "${HOME}/.zshrc" ;;
        bash)
            if [[ -f "${HOME}/.bashrc" ]]; then
                echo "${HOME}/.bashrc"
            elif [[ -f "${HOME}/.bash_profile" ]]; then
                echo "${HOME}/.bash_profile"
            else
                echo "${HOME}/.bashrc"
            fi
            ;;
        fish) echo "${HOME}/.config/fish/config.fish" ;;
        *) echo "${HOME}/.bashrc" ;;
    esac
}

add_to_path() {
    local install_dir="$1"
    local shell_config="$2"
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")

    [[ ":$PATH:" == *":${install_dir}:"* ]] && return 0

    if [[ -f "$shell_config" ]] && grep -qF "$install_dir" "$shell_config" 2>/dev/null; then
        log_info "PATH entry already in $shell_config"
        return 0
    fi

    local config_dir
    config_dir=$(dirname "$shell_config")
    [[ ! -d "$config_dir" ]] && mkdir -p "$config_dir"

    local path_line
    if [[ "$shell_name" == "fish" ]]; then
        path_line="fish_add_path ${install_dir}"
    else
        path_line="export PATH=\"${install_dir}:\$PATH\""
    fi

    {
        echo ""
        echo "# Added by APR installer"
        echo "$path_line"
    } >> "$shell_config"

    log_info "Added ${install_dir} to PATH in ${shell_config}"
}

install_gum() {
    if command -v gum &> /dev/null; then
        log_info "gum already installed"
        return 0
    fi

    log_step "Installing gum (beautiful CLI output)..."

    local os="unknown"
    case "$(uname -s)" in
        Darwin*) os="macos" ;;
        Linux*)  os="linux" ;;
    esac

    case "$os" in
        macos)
            if command -v brew &> /dev/null; then
                brew install gum &>/dev/null && return 0
            fi
            ;;
        linux)
            if command -v apt-get &> /dev/null; then
                (
                    sudo mkdir -p /etc/apt/keyrings 2>/dev/null
                    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
                    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
                    sudo apt-get update -qq && sudo apt-get install -y -qq gum
                ) &>/dev/null && return 0
            elif command -v dnf &> /dev/null; then
                (
                    echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo >/dev/null
                    sudo dnf install -y gum
                ) &>/dev/null && return 0
            elif command -v pacman &> /dev/null; then
                sudo pacman -S --noconfirm gum &>/dev/null && return 0
            fi

            # Fallback: GitHub releases
            local arch
            arch=$(uname -m)
            case "$arch" in
                x86_64) arch="amd64" ;;
                aarch64|arm64) arch="arm64" ;;
                *) log_warn "Unsupported architecture for gum: $arch"; return 1 ;;
            esac

            # Try to get latest version from GitHub API, fall back to known good version
            local gum_version="0.14.5"  # Fallback version
            local latest_version=""
            latest_version=$(fetch_url "https://api.github.com/repos/charmbracelet/gum/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d 'v') || true
            if [[ -n "$latest_version" && "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                gum_version="$latest_version"
            fi

            local tmp_dir
            tmp_dir=$(mktemp -d)
            local gum_url="https://github.com/charmbracelet/gum/releases/download/v${gum_version}/gum_${gum_version}_Linux_${arch}.tar.gz"

            (
                cd "$tmp_dir"
                curl -fsSL "$gum_url" -o gum.tar.gz
                tar -xzf gum.tar.gz
                sudo mv gum /usr/local/bin/gum 2>/dev/null || {
                    mkdir -p ~/.local/bin
                    mv gum ~/.local/bin/gum
                }
            ) &>/dev/null && rm -rf "$tmp_dir" && return 0

            rm -rf "$tmp_dir"
            ;;
    esac

    log_warn "Could not install gum automatically (APR will fall back to ANSI colors)"
    return 1
}

install_node() {
    if command -v node &> /dev/null && command -v npm &> /dev/null; then
        log_info "Node.js already installed: $(node --version 2>/dev/null | head -1)"
        return 0
    fi

    log_step "Installing Node.js (required for Oracle)..."

    local os="unknown"
    case "$(uname -s)" in
        Darwin*) os="macos" ;;
        Linux*)  os="linux" ;;
    esac

    case "$os" in
        macos)
            if command -v brew &> /dev/null; then
                brew install node &>/dev/null && return 0
            fi
            ;;
        linux)
            if ! command -v sudo &> /dev/null; then
                log_warn "sudo not available; cannot install Node.js automatically"
                return 1
            fi
            if command -v apt-get &> /dev/null; then
                if command -v curl &> /dev/null; then
                    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - &>/dev/null
                    sudo apt-get install -y -qq nodejs &>/dev/null && return 0
                elif command -v wget &> /dev/null; then
                    wget -qO- https://deb.nodesource.com/setup_18.x | sudo -E bash - &>/dev/null
                    sudo apt-get install -y -qq nodejs &>/dev/null && return 0
                else
                    log_warn "curl/wget not available; cannot install Node.js via NodeSource"
                    return 1
                fi
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y nodejs &>/dev/null && return 0
            elif command -v pacman &> /dev/null; then
                sudo pacman -S --noconfirm nodejs npm &>/dev/null && return 0
            fi
            ;;
    esac

    log_warn "Could not install Node.js automatically"
    return 1
}

install_oracle() {
    if command -v oracle &> /dev/null; then
        log_info "Oracle already installed: $(oracle --version 2>/dev/null | head -1)"
        return 0
    fi

    log_step "Ensuring Oracle is installed..."

    if ! command -v npm &> /dev/null; then
        install_node || {
            log_warn "Node.js not installed; cannot install Oracle automatically"
            return 1
        }
    fi

    if command -v npm &> /dev/null; then
        log_step "Installing Oracle globally..."
        if npm install -g @steipete/oracle &>/dev/null; then
            return 0
        fi
        log_warn "Oracle global install failed; trying npx fallback"
    fi

    if command -v npx &> /dev/null; then
        log_info "Oracle available via npx"
        return 0
    fi

    log_warn "Oracle not installed. APR requires Oracle for GPT Pro reviews."
    log_warn "Install Node.js and run: npm install -g @steipete/oracle"
    return 1
}

# Self-refresh: re-download installer if stale (cache-busting)
check_installer_update() {
    # Only check if we have network and this is a fresh install
    if [[ -n "${APR_SKIP_INSTALLER_CHECK:-}" ]]; then
        return 0
    fi

    local remote_version=""
    remote_version=$(fetch_url "${REPO_URL}/install.sh" 2>/dev/null | grep -m1 '^readonly INSTALLER_VERSION=' | cut -d'"' -f2) || true

    if [[ -n "$remote_version" && "$remote_version" != "$INSTALLER_VERSION" ]]; then
        log_warn "Newer installer available ($INSTALLER_VERSION -> $remote_version)"
        log_dim "  Re-run: curl -fsSL ${REPO_URL}/install.sh | bash"
    fi
}

install_apr_libraries() {
    local install_dir="$1"
    local use_sudo="$2"
    local version_info="$3"
    local lib_install_dir="${install_dir}/lib"
    local lib_base_url="${REPO_URL}/lib"

    if [[ -n "${APR_VERSION:-}" ]]; then
        lib_base_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/v${APR_VERSION}/lib"
    fi

    log_step "Installing APR libraries (${version_info})..."
    $use_sudo mkdir -p "$lib_install_dir"

    local lib_file lib_url lib_tmp
    for lib_file in "${APR_LIB_FILES[@]}"; do
        lib_url="${lib_base_url}/${lib_file}"

        lib_tmp=$(mktemp)
        if ! download_file "$lib_url" "$lib_tmp"; then
            log_error "Failed to download APR library: lib/${lib_file}"
            log_error "Source URL: ${lib_url}"
            exit $EXIT_DOWNLOAD_ERROR
        fi
        if ! verify_lib_script "$lib_tmp"; then
            log_error "Invalid APR library: lib/${lib_file}"
            exit $EXIT_CHECKSUM_ERROR
        fi

        $use_sudo mv "$lib_tmp" "${lib_install_dir}/${lib_file}"
        $use_sudo chmod 0644 "${lib_install_dir}/${lib_file}"
    done
}

main() {
    echo "" >&2
    echo -e "${BOLD}${MAGENTA}+================================================================+${NC}" >&2
    echo -e "${BOLD}${MAGENTA}|${NC}  ${BOLD}  Automated Plan Reviser Pro${NC}                                ${BOLD}${MAGENTA}|${NC}" >&2
    echo -e "${BOLD}${MAGENTA}|${NC}  ${DIM}Iterative AI-Powered Spec Refinement${NC}                         ${BOLD}${MAGENTA}|${NC}" >&2
    echo -e "${BOLD}${MAGENTA}+================================================================+${NC}" >&2
    echo "" >&2
    log_dim "Installer version: $INSTALLER_VERSION"
    echo "" >&2

    # Check for installer updates (non-blocking)
    check_installer_update

    local install_dir shell_config
    install_dir=$(get_install_dir)
    shell_config=$(get_shell_config)
    local script_path="${install_dir}/${SCRIPT_NAME}"

    log_step "Install directory: ${install_dir}"
    log_step "Shell config: ${shell_config}"

    # Create install directory
    if [[ ! -d "$install_dir" ]]; then
        log_info "Creating directory: ${install_dir}"
        mkdir -p "$install_dir"
    fi

    # Check if we need sudo
    local use_sudo=""
    if [[ ! -w "$install_dir" ]]; then
        if command -v sudo &> /dev/null; then
            use_sudo="sudo"
            log_warn "Using sudo for installation to ${install_dir}"
        else
            log_error "Cannot write to ${install_dir} and sudo not available"
            exit $EXIT_ERROR
        fi
    fi

    # Determine download URL
    local download_url checksum_url version_info=""
    if [[ -n "${APR_VERSION:-}" ]]; then
        # Specific version from releases
        download_url="${RELEASES_URL}/download/v${APR_VERSION}/apr"
        checksum_url="${RELEASES_URL}/download/v${APR_VERSION}/apr.sha256"
        version_info="v${APR_VERSION}"
    else
        # Latest from main branch
        download_url="${REPO_URL}/${SCRIPT_NAME}"
        checksum_url="${REPO_URL}/apr.sha256"
        version_info="latest"
    fi

    # Download APR
    log_step "Downloading APR (${version_info})..."
    local tmp_file
    tmp_file=$(mktemp)
    if ! download_file "$download_url" "$tmp_file"; then
        log_error "Failed to download APR from: $download_url"
        rm -f "$tmp_file"
        exit $EXIT_DOWNLOAD_ERROR
    fi

    # Verify it's a valid script
    log_step "Verifying script..."
    if ! verify_script "$tmp_file"; then
        rm -f "$tmp_file"
        exit $EXIT_CHECKSUM_ERROR
    fi

    # Checksum verification (if available and not skipped)
    if [[ -z "${APR_SKIP_VERIFY:-}" ]]; then
        local expected_checksum=""
        expected_checksum=$(fetch_url "$checksum_url" 2>/dev/null | awk '{print $1}' | tr -d '[:space:]') || true

        if [[ -n "$expected_checksum" ]]; then
            log_step "Verifying checksum..."
            if ! verify_checksum "$tmp_file" "$expected_checksum"; then
                if [[ -n "${APR_VERSION:-}" ]] && try_tag_source_fallback "$APR_VERSION" "$expected_checksum" "$tmp_file"; then
                    :
                else
                    rm -f "$tmp_file"
                    exit $EXIT_CHECKSUM_ERROR
                fi
            fi
            log_info "Checksum verified"
        else
            log_dim "  (checksum not available for verification)"
        fi
    else
        log_warn "Skipping checksum verification (APR_SKIP_VERIFY=1)"
    fi

    # Install APR
    log_step "Installing to ${script_path}..."
    $use_sudo mv "$tmp_file" "$script_path"
    $use_sudo chmod +x "$script_path"

    # Install sourced APR libraries next to the apr executable. The runtime
    # loader defaults to "${script_dir}/lib", so curl|bash installs must carry
    # these files or lib-backed commands fail with "command not found".
    install_apr_libraries "$install_dir" "$use_sudo" "$version_info"

    # Add to PATH
    add_to_path "$install_dir" "$shell_config"

    # Install dependencies (unless disabled)
    local gum_ok=false oracle_ok=false
    if [[ -z "${APR_NO_DEPS:-}" ]]; then
        echo "" >&2
        log_step "Installing dependencies..."
        install_gum && gum_ok=true
        install_oracle && oracle_ok=true
    else
        # Check if already available
        command -v gum &>/dev/null && gum_ok=true
        { command -v oracle &>/dev/null || command -v npx &>/dev/null; } && oracle_ok=true
    fi

    # Verify installation
    if [[ -x "$script_path" ]]; then
        # Get installed version
        local installed_version=""
        installed_version=$("$script_path" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true

        echo "" >&2
        log_info "Installation complete! ${installed_version:+(v$installed_version)}"
        echo "" >&2
        echo -e "${BOLD}What APR Does:${NC}" >&2
        echo -e "  ${GREEN}1.${NC} Bundle your docs (README, spec, implementation)" >&2
        echo -e "  ${GREEN}2.${NC} Send to GPT Pro 5.2 with Extended Reasoning" >&2
        echo -e "  ${GREEN}3.${NC} Capture detailed revision suggestions" >&2
        echo -e "  ${GREEN}4.${NC} Track multiple rounds of refinement" >&2
        echo "" >&2

        # Show dependency status
        echo -e "${BOLD}Dependencies:${NC}" >&2
        if [[ "$gum_ok" == "true" ]]; then
            echo -e "  ${GREEN}✓${NC} gum (beautiful TUI)" >&2
        else
            echo -e "  ${YELLOW}○${NC} gum (optional - will fall back to basic output)" >&2
        fi
        if [[ "$oracle_ok" == "true" ]]; then
            echo -e "  ${GREEN}✓${NC} oracle (ChatGPT automation)" >&2
        else
            echo -e "  ${RED}✗${NC} oracle ${RED}(required)${NC} - install with: npm install -g @steipete/oracle" >&2
        fi
        echo "" >&2

        echo -e "${BOLD}Quick Start:${NC}" >&2
        echo "" >&2

        if [[ ":$PATH:" != *":${install_dir}:"* ]]; then
            echo -e "  ${BOLD}1. Reload your shell:${NC}" >&2
            echo -e "     source ${shell_config}" >&2
            echo "" >&2
            echo -e "  ${BOLD}2. Run the setup wizard:${NC}" >&2
        else
            echo -e "  ${BOLD}Run the setup wizard:${NC}" >&2
        fi

        echo -e "     ${CYAN}apr setup${NC}" >&2
        echo "" >&2
        echo -e "  ${BOLD}Then start your first revision:${NC}" >&2
        echo -e "     ${CYAN}apr run 1${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}First run will require ChatGPT login via browser${NC}" >&2
        echo "" >&2
    else
        log_error "Installation failed - script not executable"
        exit $EXIT_INSTALL_ERROR
    fi
}

main "$@"
