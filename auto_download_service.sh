#!/bin/bash
set -o pipefail
chmod u+x "$0"

# Source utility scripts
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
UTILS_SCRIPT="$SCRIPT_DIR/common_utils.sh"
DOCKER_SETUP_SCRIPT="$SCRIPT_DIR/docker_setup.sh"

if [ -f "$UTILS_SCRIPT" ]; then
    # shellcheck source=common_utils.sh
    source "$UTILS_SCRIPT"
else
    echo "Error: common_utils.sh not found."
    exit 1
fi

if [ -f "$DOCKER_SETUP_SCRIPT" ]; then
    # shellcheck source=docker_setup.sh
    source "$DOCKER_SETUP_SCRIPT"
else
    # If common_utils.sh sourced, script_log might be available.
    # Otherwise, echo to stderr.
    if command -v script_log &> /dev/null; then
        script_log "Error: docker_setup.sh not found."
    else
        echo "Error: docker_setup.sh not found." >&2
    fi
    exit 1
fi

# Initialize Docker paths (needed for logging and other functions)
initialize_docker_paths

# --- Lock File Configuration ---
LOCK_FILE_PATH="/tmp/auto_download_service.sbas.lock"

# Clean up stale lock file if it exists.
# This is a simple approach. A more robust solution might involve checking the PID
# of the process that created the lock file. For this service, it's acceptable
# to assume that if the script is starting, any pre-existing lock is stale.
if [ -d "$LOCK_FILE_PATH" ]; then
    log_warn "Stale lock file found at $LOCK_FILE_PATH. Attempting to remove it."
    if ! rmdir "$LOCK_FILE_PATH"; then
        # If rmdir fails, it might be because the directory is not empty,
        # or due to permissions. This could indicate a real running instance.
        script_log "ERROR: Could not remove stale lock directory $LOCK_FILE_PATH. It might be in use by another process. Exiting."
        exit 1
    fi
    log_info "Stale lock file removed."
fi

# Attempt to acquire lock
if mkdir "$LOCK_FILE_PATH"; then
    # log_info should be available now since common_utils and docker_setup are sourced, and paths initialized.
    log_info "Lock acquired: $LOCK_FILE_PATH. Auto download service (PID: $$) starting."
    # Setup trap to remove lock on exit
    trap 'rmdir "$LOCK_FILE_PATH"; log_info "Lock file $LOCK_FILE_PATH removed. Auto download service instance ($(basename $0) PID: $$) stopped."; exit' INT TERM EXIT HUP
else
    # If mkdir fails now, it's likely a race condition or a persistent issue.
    if command -v script_log &> /dev/null; then
        script_log "ERROR: Could not acquire lock. Another instance of auto_download_service.sh might have just started. Exiting."
    else
        echo "ERROR: Could not acquire lock. Another instance of auto_download_service.sh might have just started. Exiting." >&2
    fi
    exit 1
fi

# Script Version
SCRIPT_VERSION="1.0"

# Server configuration
SERVER_BASE_URL="http://192.168.1.29:8081/"
SERVER_SCRIPTS_PATH="Auto/Scripts/"
AUTO_NODES_PATH="Auto/Nodes/" # Used for Custom.txt, actual nodes are cloned from git repos
AUTO_MODELS_PATH="Auto/Models/"

NEEDS_RESTART=false
PROCESSED_CUSTOM_TXT_PATH="" # Will be initialized in main or after DOCKER_DATA_ACTUAL_PATH is set

# --- Self-update Function ---
check_for_self_update() {
    log_info "Checking for script updates..."
    local server_script_url="$SERVER_BASE_URL$SERVER_SCRIPTS_PATH$(basename "$0")"
    local temp_script_path
    temp_script_path=$(mktemp)

    if ! download_file "$server_script_url" "$temp_script_path"; then
        script_log "ERROR: Could not download latest script version from $server_script_url for update check."
        rm -f "$temp_script_path"
        return
    fi

    local server_version
    server_version=$(grep '^SCRIPT_VERSION=' "$temp_script_path" | cut -d'=' -f2 | tr -d '"')

    if [ -z "$server_version" ]; then
        script_log "WARN: Could not determine SCRIPT_VERSION from downloaded script at $server_script_url."
        rm -f "$temp_script_path"
        return
    fi

    log_info "Current script version: $SCRIPT_VERSION. Server script version: $server_version."

    # Simple version comparison.
    if [ "$(printf '%s\n' "$server_version" "$SCRIPT_VERSION" | sort -V | head -n1)" = "$SCRIPT_VERSION" ] && [ "$server_version" != "$SCRIPT_VERSION" ]; then
        log_info "New version available ($server_version). Updating script."
        chmod +x "$temp_script_path"
        log_info "Executing new script version and restarting service..."
        rmdir "$LOCK_FILE_PATH"
        if mv "$temp_script_path" "$0"; then
            log_info "Script file updated. Restarting with exec..."
            exec "$0" "$@"
            script_log "CRITICAL: exec failed to restart the script after update. Exiting."
            exit 1
        else
            script_log "ERROR: Failed to move new script into place. Update aborted."
            exit 1
        fi
    else
        log_info "Script is up to date."
        rm -f "$temp_script_path"
    fi
}

# --- Downloader Function ---
# Tries to use curl, falls back to wget. Logs errors if neither is found.
# Usage: download_file "URL" "OUTPUT_PATH"
download_file() {
    local url="$1"
    local output_path="$2"

    if command -v curl &>/dev/null; then
        # Use curl
        log_info "Using curl to download $url to $output_path"
        curl -L --fail -o "$output_path" "$url"
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            script_log "ERROR: curl failed to download $url. Exit code: $exit_code"
            return 1
        fi
        return 0
    elif command -v wget &>/dev/null; then
        # Use wget
        log_info "Using wget to download $url to $output_path"
        wget -nv -O "$output_path" "$url"
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

# --- Permissions Function ---
set_model_permissions() {
    local model_path="$DOCKER_DATA_ACTUAL_PATH/models/"
    log_info "Attempting to set permissions for models directory: $model_path"
    if [ -d "$model_path" ]; then
        # The script is likely run as root from systemd, but sudo is safer if run manually
        if command -v sudo &>/dev/null; then
            if sudo chmod -R a+w "$model_path"; then
                log_info "Permissions (a+w) set successfully for $model_path"
            else
                script_log "ERROR: Failed to set permissions for $model_path using sudo."
            fi
        else
            if chmod -R a+w "$model_path"; then
                 log_info "Permissions (a+w) set successfully for $model_path (without sudo)."
            else
                script_log "ERROR: Failed to set permissions for $model_path. Sudo not found."
            fi
        fi
    else
        script_log "WARN: Models directory $model_path does not exist. Skipping permission setting."
    fi
}


# Functions

process_git_clone_command() {
    local clone_command_line="$1"
    log_info "Processing git clone command: $clone_command_line"

    if ! echo "$clone_command_line" | grep -qE '^git clone'; then
        script_log "ERROR: Invalid command. Not a 'git clone' command: $clone_command_line"
        return 1
    fi

    # Extract URL - This handles `git clone <URL>` or `git clone --depth 1 <URL>` etc.
    # It takes the last argument as URL, or second to last if last is a target dir.
    # This is a simplified parser. A more robust solution might require more complex parsing if various git clone formats are used.
    local words=($clone_command_line)
    local git_url=""
    local target_dir_specified=false

    # Check if the second to last argument is a URL (common for `git clone <url> <dir>`)
    # or if the last argument is a URL (common for `git clone <url>`)
    # A simple heuristic: if the last word doesn't look like an option (doesn't start with -)
    # and the second to last word looks like a URL, it might be `clone url dir`.
    # Otherwise, assume last word is URL if it doesn't start with -.

    # For now, let's assume the URL is the second argument if only two args, or third if more (e.g. git clone --depth 1 <URL>)
    # A very basic approach: find the first argument that looks like a URL.
    for word in "${words[@]}"; do
        if [[ "$word" == http* ]] || [[ "$word" == git@* ]]; then
            git_url="$word"
            break
        fi
    done

    if [ -z "$git_url" ]; then
        script_log "ERROR: Could not reliably extract Git URL from command: $clone_command_line"
        return 1
    fi
    log_info "Extracted Git URL: $git_url"

    local git_url_basename
    git_url_basename=$(basename "$git_url")

    local derived_repo_name="${git_url_basename%.git}" # Removes .git suffix ONLY if present at the end

    # Now, sanitize this derived_repo_name to remove CR.
    repo_name=$(echo "$derived_repo_name" | tr -d '\r')

    if [ -z "$repo_name" ] || [ "$repo_name" == "." ]; then
        script_log "ERROR: Could not determine repository name from URL: $git_url (derived: $derived_repo_name, basename: $git_url_basename)"
        return 1
    fi
    log_info "Extracted Git URL: $git_url, Determined and sanitized repository name: $repo_name"

    local target_custom_nodes_base_dir="$DOCKER_DATA_ACTUAL_PATH/custom_nodes"
    # Ensure base custom_nodes dir exists
    mkdir -p "$target_custom_nodes_base_dir"
    if [ $? -ne 0 ]; then
        script_log "ERROR: Failed to create base custom_nodes directory: $target_custom_nodes_base_dir"
        return 1
    fi

    local cloned_repo_path="$target_custom_nodes_base_dir/$repo_name"
    cloned_repo_path=$(echo "$cloned_repo_path" | tr -s '/') # Normalize path

    if [ -d "$cloned_repo_path" ]; then
        log_info "Repository $repo_name already exists at $cloned_repo_path. Skipping clone."
        return 2 # Skipped, already exists
    fi

    log_info "Cloning $git_url into $cloned_repo_path"
    # We clone into a temporary path first, then move on success. This avoids partial clones in the final location.
    local temp_clone_path
    temp_clone_path=$(mktemp -d -p "$target_custom_nodes_base_dir" "${repo_name}.tmp.XXXXXX")

    # Construct the specific git clone command. For now, just basic clone.
    # If clone_command_line contains options, they are not used here yet.
    # This part needs to be more robust if complex git clone commands are in Custom.txt
    git clone "$git_url" "$temp_clone_path"
    local clone_exit_code=$?

    if [ $clone_exit_code -ne 0 ]; then
        script_log "ERROR: 'git clone $git_url' failed with exit code $clone_exit_code."
        rm -rf "$temp_clone_path" # Clean up temp clone
        return 1 # Error
    fi

    # Move temp clone to final destination
    mv "$temp_clone_path" "$cloned_repo_path"
    if [ $? -ne 0 ]; then
        script_log "ERROR: Failed to move temporary clone from $temp_clone_path to $cloned_repo_path."
        rm -rf "$temp_clone_path" # Clean up temp clone just in case
        # cloned_repo_path might be partially there if mv failed midway, consider cleaning it too
        rm -rf "$cloned_repo_path"
        return 1 # Error
    fi

    log_info "Successfully cloned $repo_name to $cloned_repo_path."
    return 0 # Cloned successfully
}


check_for_new_nodes() {
    log_info "Checking for new custom nodes via Custom.txt..."
    if [ -z "$PROCESSED_CUSTOM_TXT_PATH" ]; then # Ensure PROCESSED_CUSTOM_TXT_PATH is initialized
        if [ -n "$DOCKER_DATA_ACTUAL_PATH" ]; then
            PROCESSED_CUSTOM_TXT_PATH="$DOCKER_DATA_ACTUAL_PATH/Custom.txt.processed"
        else
            # Fallback if DOCKER_DATA_ACTUAL_PATH is somehow not set yet. This should not happen.
            local fallback_path="$SCRIPT_DIR/Custom.txt.processed" # SCRIPT_DIR is dir of auto_download_service.sh
            log_warn "DOCKER_DATA_ACTUAL_PATH not set! Using fallback for PROCESSED_CUSTOM_TXT_PATH: $fallback_path"
            PROCESSED_CUSTOM_TXT_PATH="$fallback_path"
        fi
    fi

    local server_custom_txt_url="$SERVER_BASE_URL$AUTO_NODES_PATH/Custom.txt"
    local downloaded_custom_txt
    downloaded_custom_txt=$(mktemp)

    log_info "Downloading Custom.txt from $server_custom_txt_url"
    if ! download_file "$server_custom_txt_url" "$downloaded_custom_txt"; then
        script_log "ERROR: Failed to download Custom.txt from $server_custom_txt_url."
        rm -f "$downloaded_custom_txt"
        return
    fi
    log_info "Custom.txt downloaded successfully to $downloaded_custom_txt."

    if [ ! -f "$PROCESSED_CUSTOM_TXT_PATH" ]; then
        log_info "Processed Custom.txt file not found at $PROCESSED_CUSTOM_TXT_PATH. Creating it."
        touch "$PROCESSED_CUSTOM_TXT_PATH"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create $PROCESSED_CUSTOM_TXT_PATH. Cannot proceed with node checks."
            rm -f "$downloaded_custom_txt"
            return
        fi
    fi

    mapfile -t current_lines < "$downloaded_custom_txt"

    for line in "${current_lines[@]}"; do
        local trimmed_line
        trimmed_line=$(echo "$line" | tr -d '\r' | awk '{$1=$1};1') # Trim CRLF and leading/trailing whitespace

        if [ -z "$trimmed_line" ] || [[ "$trimmed_line" == \#* ]]; then # Skip empty lines or comments
            continue
        fi

        # Check if command already processed
        # Using grep -Fxq for exact, fixed string, quiet match.
        if ! grep -Fxq "$trimmed_line" "$PROCESSED_CUSTOM_TXT_PATH"; then
            log_info "New command found in Custom.txt: '$trimmed_line'"
            if [[ "$trimmed_line" == git\ clone* ]]; then
                process_git_clone_command "$trimmed_line"
                local result_code=$?
                if [ $result_code -eq 0 ]; then # Cloned successfully
                    log_info "Successfully cloned: '$trimmed_line'. Appending to processed list. Restart needed."
                    echo "$trimmed_line" >> "$PROCESSED_CUSTOM_TXT_PATH"
                    NEEDS_RESTART=true
                elif [ $result_code -eq 2 ]; then # Skipped, already exists
                    log_info "Skipped (already exists): '$trimmed_line'. Appending to processed list. No restart needed for this item."
                    echo "$trimmed_line" >> "$PROCESSED_CUSTOM_TXT_PATH"
                    # NEEDS_RESTART is not changed; it might be true from a previous command
                else # Error (result_code == 1)
                    script_log "ERROR: Failed to process command: '$trimmed_line'. It will be retried next cycle."
                    # Do not append to processed list, do not set NEEDS_RESTART
                fi
            else
                script_log "WARN: Non 'git clone' command found in Custom.txt: '$trimmed_line'. Skipping."
                # Optionally, add non-clone lines to processed list if they should not be re-evaluated
                # For now, non-git-clone commands are not added to processed list and will be re-evaluated.
                # To mark them as processed (and avoid re-evaluation), uncomment the next line:
                # echo "$trimmed_line" >> "$PROCESSED_CUSTOM_TXT_PATH"
            fi
        else
            log_info "Command already processed: '$trimmed_line'"
        fi
    done

    rm -f "$downloaded_custom_txt"
    log_info "Finished checking for new nodes from Custom.txt."
}

# --- Model Sync Functions ---

# Global array to hold the list of files found on the server
SERVER_FILES_LIST=()

# Recursively process a directory on the model server
# Returns 0 on success, 1 on failure to connect/list items.
process_model_directory_recursively() {
    local relative_dir_path="$1" # e.g., "checkpoints/" or "" for root
    local full_server_url="$SERVER_BASE_URL$AUTO_MODELS_PATH$relative_dir_path"
    local local_dir_path="$DOCKER_DATA_ACTUAL_PATH/models/$relative_dir_path"

    log_info "Processing server directory: $full_server_url"
    mkdir -p "$local_dir_path"

    # Get directory listing from server
    local server_items_raw
    # Use --fail to make curl exit with an error if the server returns 4xx or 5xx
    server_items_raw=$(curl -sL --fail "$full_server_url" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '^\.\./$' | grep -v '^Parent directory')
    if [ $? -ne 0 ]; then
        script_log "ERROR: Failed to retrieve item list from server directory: $full_server_url. Aborting model sync for this cycle."
        return 1 # Indicate failure
    fi

    mapfile -t server_items < <(echo "$server_items_raw")

    for item_encoded in "${server_items[@]}"; do
        local item_decoded
        item_decoded=$(printf '%b' "${item_encoded//%/\x}")
        local server_item_relative_path="$relative_dir_path$item_decoded"

        # Determine if the item is a directory or a file.
        # Method 1: Item has a trailing slash. It's a directory.
        if [[ "$item_decoded" == */ ]]; then
            SERVER_FILES_LIST+=("$server_item_relative_path")
            log_info "Found directory on server (by slash): $server_item_relative_path. Descending..."
            if ! process_model_directory_recursively "$server_item_relative_path"; then
                return 1 # Propagate failure
            fi
            continue # Continue to next item in the loop
        fi

        # Method 2: Item does not have a trailing slash. It could be a file or a directory.
        # We perform a HEAD request to check its Content-Type. 'text/html' implies a directory.
        local item_url="$SERVER_BASE_URL$AUTO_MODELS_PATH$server_item_relative_path"
        local content_type
        content_type=$(curl -sI --max-time 10 --fail "$item_url" 2>/dev/null | grep -i '^Content-Type:' | awk '{print $2}' | tr -d '\r\n')
        local curl_exit_code=$?

        if [ $curl_exit_code -ne 0 ]; then
            script_log "ERROR: HEAD request failed for '$item_url'. Cannot determine item type. Aborting sync cycle."
            return 1 # Propagate failure
        fi

        if [[ "$content_type" == text/html* ]]; then
            # It's a directory. Add trailing slash for consistency and descend.
            local dir_path_with_slash="${server_item_relative_path}/"
            SERVER_FILES_LIST+=("$dir_path_with_slash")
            log_info "Found directory on server (by content-type): $dir_path_with_slash. Descending..."
            if ! process_model_directory_recursively "$dir_path_with_slash"; then
                return 1 # Propagate failure
            fi
        else
            # It's a file. Add to list and process for download.
            SERVER_FILES_LIST+=("$server_item_relative_path")
            log_info "Found file on server: $server_item_relative_path"

            local local_item_path="$DOCKER_DATA_ACTUAL_PATH/models/$server_item_relative_path"
            local server_file_url="$item_url" # URL is already defined above

            # --- File download/update logic ---
            local server_file_size_str
            # We can reuse the HEAD request info, but it's cleaner to just get it again.
            server_file_size_str=$(curl --max-time 10 -sI "$server_file_url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n')

            local server_file_size=-1
            if [[ "$server_file_size_str" =~ ^[0-9]+$ ]]; then
                server_file_size=$server_file_size_str
            else
                log_warn "Could not determine Content-Length for $server_file_url. Received: '$server_file_size_str'."
            fi

            local should_download=false
            if [ ! -f "$local_item_path" ]; then
                log_info "Local file does not exist. Downloading."
                should_download=true
            else
                local local_file_size
                local_file_size=$(stat -c%s "$local_item_path")
                if [ "$server_file_size" -ne -1 ] && [ "$local_file_size" -ne "$server_file_size" ]; then
                    log_info "Local file size ($local_file_size) differs from server ($server_file_size). Re-downloading."
                    should_download=true
                else
                    log_info "Local file exists and size matches. Skipping."
                fi
            fi

            if [ "$should_download" = true ]; then
                log_info "Downloading: $server_file_url to $local_item_path"
                if ! download_file "$server_file_url" "$local_item_path"; then
                    script_log "ERROR: Download failed for $server_file_url. Aborting sync cycle."
                    rm -f "$local_item_path" # Clean up partial download
                    return 1 # Propagate failure
                else
                    log_info "Successfully downloaded $item_decoded."
                fi
            fi
        fi
    done

    return 0 # Success
}

# Main function to check for new models and sync (mirror)
check_for_new_models() {
    log_info "Starting model sync process..."

    # Reset the server file list for this run
    SERVER_FILES_LIST=()

    # 1. Recursively scan server and download/update files
    # The function now returns a status code. 0 for success, 1 for failure.
    if ! process_model_directory_recursively ""; then
        script_log "ERROR: Server scan failed. Skipping cleanup of local models to prevent data loss."
        return # Exit without cleaning up
    fi
    log_info "Finished server scan and download phase successfully."


    # 2. Get a list of all local files and directories
    local local_models_base_path="$DOCKER_DATA_ACTUAL_PATH/models/"
    if [ ! -d "$local_models_base_path" ]; then
        log_info "Local models directory does not exist. Nothing to clean up."
        return
    fi

    mapfile -t local_files < <(find "$local_models_base_path" -path "$local_models_base_path" -o -print | sed "s|^$local_models_base_path||")

    # 3. Compare and delete local files not on the server
    log_info "Comparing local files to server file list for cleanup..."
    local found
    for local_item in "${local_files[@]}"; do
        if [ -z "$local_item" ]; then continue; fi
        found=0
        for server_item in "${SERVER_FILES_LIST[@]}"; do
            if [ "$local_item" = "$server_item" ]; then
                found=1
                break
            fi
        done

        if [ $found -eq 0 ]; then
            local full_local_path="$local_models_base_path$local_item"
            if [ -f "$full_local_path" ]; then
                log_info "DELETING file not on server: $full_local_path"
                rm -f "$full_local_path"
            elif [ -d "$full_local_path" ]; then
                # This directory might be deleted later if it's empty
                log_info "Directory not on server list: $full_local_path. Will be cleaned up if empty."
            fi
        fi
    done

    # 4. Clean up empty directories
    log_info "Cleaning up empty directories..."
    find "$local_models_base_path" -depth -type d -empty -exec rmdir {} \;

    log_info "Finished model sync process."
}
restart_comfyui_containers() {
    log_info "Beginning ComfyUI container restart process..."

    if [ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]; then
        script_log "ERROR: DOCKER_SCRIPTS_ACTUAL_PATH is not set. Cannot locate start_comfyui.sh."
        return 1
    fi

    local start_script_path="$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"

    if [ ! -x "$start_script_path" ]; then
        script_log "ERROR: Start script not found or not executable at $start_script_path"
        return 1
    fi

    log_info "Stopping and removing ComfyUI containers (comfyui-gpu*)..."
    local comfyui_containers
    comfyui_containers=$(docker ps -a --filter "name=comfyui-gpu" --format "{{.Names}}")

    local overall_stop_success=true
    if [ -z "$comfyui_containers" ]; then
        log_info "No running or stopped ComfyUI containers (comfyui-gpu*) found to stop/remove."
    else
        for container_name in $comfyui_containers; do
            log_info "Stopping container: $container_name"
            docker stop "$container_name"
            local stop_code=$?
            if [ $stop_code -ne 0 ]; then
                script_log "WARN: Failed to stop container $container_name. Exit code: $stop_code. Attempting removal anyway."
                overall_stop_success=false
            else
                log_info "Container $container_name stopped successfully."
            fi

            log_info "Removing container: $container_name"
            docker rm "$container_name"
            local rm_code=$?
            if [ $rm_code -ne 0 ]; then
                script_log "ERROR: Failed to remove container $container_name. Exit code: $rm_code."
                overall_stop_success=false # Mark as failure if rm fails
            else
                log_info "Container $container_name removed successfully."
            fi
        done
    fi

    if ! $overall_stop_success; then
        script_log "ERROR: One or more ComfyUI containers could not be properly stopped/removed. Proceeding to attempt start..."
        # Depending on desired behavior, one might choose to return 1 here.
        # However, if start_comfyui.sh can handle existing (though possibly problematic) states,
        # proceeding might be acceptable. For now, we log error and continue.
    else
        log_info "All identified ComfyUI containers stopped and removed successfully."
    fi

    log_info "Starting ComfyUI containers using $start_script_path..."
    if "$start_script_path"; then
        log_info "ComfyUI containers started successfully by $start_script_path."

    else
        local start_exit_code=$? # Capture exit code immediately
        script_log "ERROR: Failed to start ComfyUI containers using $start_script_path. Exit code: $start_exit_code."
        return 1 # Start script failed, so the overall restart failed.
    fi

    # If stop failed but start succeeded (and subsequent dependency install logged its own errors),
    # we consider it a success overall for the restart operation's attempt to get containers running.
    return 0
}

# Main loop
main() {
    log_info "Auto download service started (Version: $SCRIPT_VERSION)."

    # Set model directory permissions on startup
    set_model_permissions

    while true; do
        # Check for self-update at the beginning of each cycle
        check_for_self_update

        NEEDS_RESTART=false
        log_info "-------------------- New Check Cycle --------------------"
        log_info "Checking for updates..."
        check_for_new_nodes
        check_for_new_models

        if [ "$NEEDS_RESTART" = true ]; then
            log_info "Changes detected, initiating ComfyUI container restart."
            if restart_comfyui_containers; then
                log_info "ComfyUI container restart successful."
            else
                script_log "ERROR: ComfyUI container restart failed."
            fi
        else
            log_info "No new items requiring restart."
        fi

        log_info "Cycle finished. Waiting for 10 seconds..."
        sleep 10
    done
}

# Run the main function - This will only be reached if the lock was acquired.
main
