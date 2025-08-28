#!/bin/bash

# --- Globale Innstillinger og Konstanter ---
# OS Detection
OS_TYPE="unknown"
case "$(uname -s)" in
    Linux*)     OS_TYPE="linux";;
    Darwin*)    OS_TYPE="mac";;
    CYGWIN*|MINGW*|MSYS*) OS_TYPE="windows";;
    *)          OS_TYPE="unknown";;
esac

# Farger for logging
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[0;33m'
BLUE='[0;34m'
NC='[0m'

# For Docker-oppsett (og generelt brukt)
export BASE_DOCKER_SETUP_DIR="${BASE_DOCKER_SETUP_DIR:-$HOME/comfyui_unified_setup}" # Provide a default if not set
SCRIPT_LOG_FILE="${SCRIPT_LOG_FILE:-$BASE_DOCKER_SETUP_DIR/ultimate_comfy_debug.log}" # Provide a default

# --- Logging Setup ---
# Ensure log directory exists
# On Windows, mkdir -p is available in Git Bash.
mkdir -p "$(dirname "$SCRIPT_LOG_FILE")"

# Script-wide debug logging function
script_log() {
    # Check if SCRIPT_LOG_FILE is writable, basic check
    if [ -w "$(dirname "$SCRIPT_LOG_FILE")" ]; then # Check if directory is writable
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$SCRIPT_LOG_FILE"
    else
        # Fallback if log file is not writable, echo to stderr
        echo "$(date '+%Y-%m-%d %H:%M:%S') - LOG_WRITE_ERROR - $1" >&2
    fi
}

# Initial Log and Exit Trap
echo "--- Log Start $(date '+%Y-%m-%d %H:%M:%S') ---" > "$SCRIPT_LOG_FILE" # Overwrite for fresh log
script_log "INFO: common_utils.sh sourced. Logging to $SCRIPT_LOG_FILE"
script_log "INFO: Detected OS_TYPE: $OS_TYPE"
script_log "INFO: BASE_DOCKER_SETUP_DIR set to $BASE_DOCKER_SETUP_DIR"
# The trap will be set by the main script that sources this, to ensure $? reflects the main script's exit.
# trap 'script_log "INFO: --- Script execution finished with exit status $? ---"' EXIT

# --- Felles Hjelpefunksjoner ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; script_log "INFO: $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; script_log "SUCCESS: $1"; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $1"; script_log "WARN: $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1" >&2; script_log "ERROR: $1"; }

press_enter_to_continue() {
    read -r -p "Trykk Enter for å fortsette..." dummy_var_for_read </dev/tty
}

ensure_dialog_installed() {
    script_log "DEBUG: ENTERING ensure_dialog_installed (common_utils.sh)"
    if [[ "$OS_TYPE" == "windows" ]]; then
        script_log "INFO: OS is Windows, 'dialog' utility is not applicable. Falling back to basic menu."
        script_log "DEBUG: EXITING ensure_dialog_installed (status 1)"
        return 1
    fi
    if command -v dialog &>/dev/null; then
        script_log "DEBUG: 'dialog' is available."
        script_log "DEBUG: EXITING ensure_dialog_installed (status 0)"
        return 0
    fi

    script_log "WARN: 'dialog' utility not installed."
    local install_dialog_choice
    # Ensure user prompt is readable and not mixed with other stdout/stderr
    echo -n "Do you want to attempt to install 'dialog' using 'sudo apt-get install -y dialog'? (ja/nei): " >&2
    read -r install_dialog_choice </dev/tty
    script_log "INFO: User choice for dialog install: '$install_dialog_choice'"

    if [[ "$install_dialog_choice" =~ ^[Jj][Aa]$ ]]; then
        script_log "INFO: Attempting 'dialog' installation..."
        if sudo apt-get update && sudo apt-get install -y dialog; then
            script_log "SUCCESS: 'dialog' installed successfully."
            log_success "'dialog' installed successfully." # User feedback
            script_log "DEBUG: EXITING ensure_dialog_installed (status 0)"
            return 0
        else
            script_log "ERROR: Failed to install 'dialog'."
            log_error "Failed to install 'dialog'." # User feedback
            log_warn "Falling back to basic menu."    # User feedback
            script_log "DEBUG: EXITING ensure_dialog_installed (status 1)"
            return 1
        fi
    else
        script_log "INFO: Skipping 'dialog' installation."
        log_warn "Skipping 'dialog' installation. Falling back to basic menu." # User feedback
        script_log "DEBUG: EXITING ensure_dialog_installed (status 1)"
        return 1
    fi
}

ensure_docker_dns() {
    script_log "DEBUG: ENTERING ensure_docker_dns (common_utils.sh)"
    if [[ "$OS_TYPE" == "windows" ]]; then
        script_log "INFO: OS is Windows, Docker Desktop manages DNS settings. Skipping check."
        script_log "DEBUG: EXITING ensure_docker_dns (no action taken on Windows)"
        return 0
    fi

    local DAEMON_JSON_FILE="/etc/docker/daemon.json"

    # If DNS is already configured, we don't need to do anything.
    if [ -f "$DAEMON_JSON_FILE" ] && grep -q '"dns"' "$DAEMON_JSON_FILE"; then
        script_log "DEBUG: Docker daemon appears to have DNS configured already."
        script_log "DEBUG: EXITING ensure_docker_dns (no action taken)"
        return 0
    fi

    log_warn "Docker DNS configuration not found or incomplete. Attempting to configure it."

    # Ensure the directory exists
    if [ ! -d "$(dirname "$DAEMON_JSON_FILE")" ]; then
        log_info "Creating directory $(dirname "$DAEMON_JSON_FILE")"
        if ! sudo mkdir -p "$(dirname "$DAEMON_JSON_FILE")"; then
            log_error "Failed to create directory for daemon.json. Please check permissions."
            return 1
        fi
    fi

    # Backup the existing file if it exists
    local DAEOMN_JSON_BACKUP="/etc/docker/daemon.json.bak.$(date +%s)"
    if [ -f "$DAEMON_JSON_FILE" ]; then
        log_info "Backing up existing $DAEMON_JSON_FILE to $DAEOMN_JSON_BACKUP"
        if ! sudo cp "$DAEMON_JSON_FILE" "$DAEOMN_JSON_BACKUP"; then
            log_error "Failed to create backup. Aborting automatic configuration."
            return 1
        fi
    fi

    # Prepare the DNS string
    local DNS_STRING='"dns": ["8.8.8.8", "8.8.4.4"]'

    # Case 1: The file does not exist or is empty/whitespace.
    if [ ! -s "$DAEMON_JSON_FILE" ]; then
        log_info "$DAEMON_JSON_FILE is missing or empty. Creating a new one with DNS settings."
        printf '{\n  %s\n}\n' "$DNS_STRING" | sudo tee "$DAEMON_JSON_FILE" > /dev/null
    else
        # Case 2: The file exists and has content. We need to add the DNS key.
        log_info "Adding DNS configuration to existing $DAEMON_JSON_FILE."
        # This is a bit tricky with sed. We remove the last '}' brace, add our key, and add the brace back.
        # This assumes the last '}' is on its own line or at least the last character.
        # We first remove any trailing whitespace from the file, then remove the last line if it's '}'
        # then add a comma to the new last line, then add our dns and the final '}'.
        local temp_json
        temp_json=$(sudo sed -e 's/[[:space:]]*$//' "$DAEMON_JSON_FILE" | sed '/^}$/d')

        # Add a comma to the new last line if it doesn't have one
        if [[ "$(echo -n "$temp_json" | tail -c 1)" != "," ]]; then
            temp_json=$(echo "$temp_json" | sed '$s/$/,/')
        fi

        printf '%s\n  %s\n}\n' "$temp_json" "$DNS_STRING" | sudo tee "$DAEMON_JSON_FILE" > /dev/null
    fi

    log_info "Attempting to restart Docker to apply new settings..."
    if sudo systemctl restart docker; then
        log_success "Docker restarted successfully with new DNS settings."
        script_log "DEBUG: EXITING ensure_docker_dns (restart successful)"
        return 0
    else
        log_error "Failed to restart Docker after modifying $DAEMON_JSON_FILE."
        log_error "Your Docker configuration might be broken."
        if [ -f "$DAEOMN_JSON_BACKUP" ]; then
            log_info "Attempting to restore from backup: $DAEOMN_JSON_BACKUP"
            if sudo mv "$DAEOMN_JSON_BACKUP" "$DAEMON_JSON_FILE"; then
                log_success "Restored daemon.json from backup. Please try restarting Docker manually."
            else
                log_error "COULD NOT RESTORE FROM BACKUP. Please do so manually: sudo mv $DAEOMN_JSON_BACKUP $DAEMON_JSON_FILE"
            fi
        fi
        script_log "DEBUG: EXITING ensure_docker_dns (restart failed)"
        return 1
    fi
}

check_and_perform_nvcr_login() {
    script_log "DEBUG: ENTERING check_and_perform_nvcr_login (common_utils.sh)"

    # Check if docker config exists and contains nvcr.io login
    if [ -f "$HOME/.docker/config.json" ] && grep -q "nvcr.io" "$HOME/.docker/config.json"; then
        log_info "Docker login for nvcr.io already configured."
        script_log "DEBUG: nvcr.io login found in Docker config. Skipping interactive login."
        script_log "DEBUG: EXITING check_and_perform_nvcr_login (already logged in)"
        return 0
    fi

    log_warn "Docker login for nvcr.io not found."
    log_info "To build the Docker image, login to NVIDIA's Container Registry (nvcr.io) is required."
    log_info "This requires an NVIDIA NGC API Key."
    log_info "You can get a key from: https://ngc.nvidia.com/setup/api-key"

    local nv_api_key
    while true; do
        echo -n "Please enter your NVIDIA NGC API Key (will be hidden): " >&2
        read -s nv_api_key </dev/tty
        echo "" # Newline after reading the key
        if [ -n "$nv_api_key" ]; then
            break
        else
            log_warn "API Key cannot be empty. Please try again."
        fi
    done

    log_info "Attempting to log in to nvcr.io..."
    if echo "$nv_api_key" | docker login nvcr.io --username '$oauthtoken' --password-stdin; then
        log_success "Successfully logged in to nvcr.io."
        log_info "Your credentials are now stored locally for future Docker builds."
        script_log "DEBUG: EXITING check_and_perform_nvcr_login (login successful)"
        # Clear the variable just in case
        unset nv_api_key
        return 0
    else
        log_error "Failed to log in to nvcr.io. Please check your API Key and try again."
        script_log "ERROR: docker login to nvcr.io failed."
        # Clear the variable just in case
        unset nv_api_key
        script_log "DEBUG: EXITING check_and_perform_nvcr_login (login failed)"
        return 1
    fi
}

script_log "DEBUG: common_utils.sh execution finished its own content."
