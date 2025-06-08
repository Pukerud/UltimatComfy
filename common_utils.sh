#!/bin/bash

# --- Globale Innstillinger og Konstanter ---
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

script_log "DEBUG: common_utils.sh execution finished its own content."
