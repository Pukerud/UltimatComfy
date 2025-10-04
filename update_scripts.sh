#!/bin/bash
chmod u+x "$0"

# This script is designed to be run non-interactively to update all scripts.

# Source utility scripts to get logging functions
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
UTILS_SCRIPT="$SCRIPT_DIR/common_utils.sh"

if [ -f "$UTILS_SCRIPT" ]; then
    # shellcheck source=common_utils.sh
    source "$UTILS_SCRIPT"
else
    # Can't use logging functions if not found, so echo to stderr
    echo "Error: common_utils.sh not found. Cannot proceed with updates." >&2
    exit 1
fi

# --- Server Configuration ---
SERVER_BASE_URL="http://192.168.1.29:8081/"
SERVER_SCRIPTS_PATH="Auto/Scripts/"

# --- List of scripts to update ---
# This list should be maintained to include all scripts that are part of the project.
SCRIPTS_TO_UPDATE=(
    "UltimateComfy.sh"
    "auto_download_service.sh"
    "common_utils.sh"
    "docker_setup.sh"
    "fix_custom_node_deps.sh"
    "model_downloader.sh"
    "run_ncdu.sh"
    "update_frontend.sh"
    "upgrade_nvidia_driver.sh"
    "update_scripts.sh" # This script for self-updating
)

# --- Downloader Function for this script ---
# A self-contained download function to avoid issues if common_utils is being updated.
# It only logs to the script log file, not to console, to keep the output clean.
headless_download_file() {
    local url="$1"
    local output_path="$2"

    script_log "Attempting to download $url to $output_path"
    if command -v curl &>/dev/null; then
        curl -sL --fail -o "$output_path" "$url"
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            script_log "ERROR: curl failed to download $url. Exit code: $exit_code"
            return 1
        fi
        return 0
    elif command -v wget &>/dev/null; then
        wget -q -O "$output_path" "$url" # -q for quiet
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            script_log "ERROR: wget failed to download $url. Exit code: $exit_code"
            return 1
        fi
        return 0
    else
        script_log "CRITICAL: Neither curl nor wget is available. Cannot download files."
        return 1
    fi
}

# --- Main Update Logic ---
main() {
    log_info "Starting headless script update..."

    local update_failed_count=0
    local script_name

    for script_name in "${SCRIPTS_TO_UPDATE[@]}"; do
        echo "Checking for updates for: $script_name" # Direct echo for visibility
        script_log "--- Checking for updates for: $script_name ---"

        local server_script_url="$SERVER_BASE_URL$SERVER_SCRIPTS_PATH$script_name"
        local target_script_path="$SCRIPT_DIR/$script_name"
        local temp_script_path
        temp_script_path=$(mktemp)

        if ! headless_download_file "$server_script_url" "$temp_script_path"; then
            echo "ERROR: Failed to download '$script_name' from server. Skipping." >&2
            script_log "ERROR: Failed to download '$script_name' from server. Skipping update for this script."
            ((update_failed_count++))
            rm -f "$temp_script_path"
            continue
        fi

        # If target file doesn't exist, we must update.
        if [ ! -f "$target_script_path" ] || ! cmp -s "$temp_script_path" "$target_script_path"; then
            echo "New version of '$script_name' found. Applying update."
            script_log "New version of '$script_name' found. Applying update."

            # Make the new script executable
            chmod +x "$temp_script_path"

            # Replace the old script with the new one
            if mv "$temp_script_path" "$target_script_path"; then
                echo "Successfully updated '$script_name'."
                script_log "Successfully updated '$script_name'."
            else
                echo "ERROR: Failed to move new script into place for '$script_name'. Update failed." >&2
                script_log "ERROR: Failed to move new script into place for '$script_name'. Update failed."
                ((update_failed_count++))
                rm -f "$temp_script_path"
            fi
        else
            echo "'$script_name' is already up to date."
            script_log "'$script_name' is already up to date."
            rm -f "$temp_script_path"
        fi
    done

    echo "----------------------------------------"
    if [ "$update_failed_count" -eq 0 ]; then
        log_success "Headless update complete. All scripts are up to date."
        exit 0
    else
        log_error "Headless update finished with $update_failed_count error(s). Please check the log file: $SCRIPT_LOG_FILE"
        exit 1
    fi
}

# Run the main function
main