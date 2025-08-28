#!/bin/bash
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

# Server configuration
SERVER_BASE_URL="http://192.168.1.29:8081/"
AUTO_NODES_PATH="Auto/Nodes/" # Used for Custom.txt, actual nodes are cloned from git repos
AUTO_MODELS_PATH="Auto/Models/"

NEEDS_RESTART=false
PROCESSED_CUSTOM_TXT_PATH="" # Will be initialized in main or after DOCKER_DATA_ACTUAL_PATH is set

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

check_for_new_models() {
    log_info "Checking for new models on the server..."
    local models_url="$SERVER_BASE_URL$AUTO_MODELS_PATH"

    local server_model_items_raw
    server_model_items_raw=$(curl -sL "$models_url" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '^\.\./$' | grep -v '^Parent directory')

    if [ $? -ne 0 ]; then # Check curl exit status
        script_log "ERROR: Failed to retrieve model list from server at $models_url."
        return
    fi

    if [ -z "$server_model_items_raw" ]; then
        log_info "No model items found on the server at $models_url."
        return
    fi

    mapfile -t server_model_items < <(echo "$server_model_items_raw")

    local local_models_base_path="$DOCKER_DATA_ACTUAL_PATH/models/"
    if [ ! -d "$local_models_base_path" ]; then
        log_info "Local models directory does not exist. Creating: $local_models_base_path"
        mkdir -p "$local_models_base_path"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create local models directory: $local_models_base_path"
            return
        fi
    fi

    for item_name in "${server_model_items[@]}"; do
        local decoded_item_name
        decoded_item_name=$(printf '%b' "${item_name//%/\x}")

        if [[ "$decoded_item_name" == */ ]]; then # It's a directory
            log_info "Processing model directory '$decoded_item_name' from server list."
            download_model "$item_name"
        else # It's a file
            log_info "Processing model file '$decoded_item_name' from server list."
            download_model "$item_name"
        fi
    done
    log_info "Finished checking for new models."
}
download_model() {
    local item_name="$1"

    local decoded_item_name
    decoded_item_name=$(printf '%b' "${item_name//%/\x}")

    local current_item_source_url="$SERVER_BASE_URL$AUTO_MODELS_PATH$item_name"
    local current_local_item_path="$DOCKER_DATA_ACTUAL_PATH/models/$decoded_item_name"

    if [[ "$decoded_item_name" == */ ]]; then
        log_info "Ensuring local directory exists for server item '$item_name': $current_local_item_path"
        mkdir -p "$current_local_item_path"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create directory $current_local_item_path for model item $decoded_item_name"
            return 1
        fi

        local files_in_dir_raw
        files_in_dir_raw=$(curl -sL "$current_item_source_url" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '/$' | grep -v '^\.\./$' | grep -v '^Parent directory')

        local curl_exit_code=$?
        if [ $curl_exit_code -ne 0 ]; then
             script_log "ERROR: Failed to retrieve file list for model directory $decoded_item_name from $current_item_source_url. Curl exit: $curl_exit_code"
             return 1
        fi

        if [ -n "$files_in_dir_raw" ]; then
            mapfile -t files_in_dir < <(echo "$files_in_dir_raw")
            log_info "Found ${#files_in_dir[@]} files in server directory $decoded_item_name. Checking each file..."
            for file_in_item_dir_encoded in "${files_in_dir[@]}"; do
                local file_to_download_source_url="$current_item_source_url$file_in_item_dir_encoded"

                local file_to_download_decoded_name
                file_to_download_decoded_name=$(printf '%b' "${file_in_item_dir_encoded//%/\x}")
                local file_to_download_local_path="$current_local_item_path$file_to_download_decoded_name"

                log_info "Checking file in dir: $file_to_download_decoded_name (Source: $file_to_download_source_url)"

                local server_file_size_str
                server_file_size_str=$(curl --max-time 10 -sI "$file_to_download_source_url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n')

                local server_file_size=-1
                if [[ "$server_file_size_str" =~ ^[0-9]+$ ]]; then
                    server_file_size=$server_file_size_str
                    log_info "Server file size for $file_to_download_decoded_name: $server_file_size bytes."
                else
                    log_warn "Could not determine Content-Length for $file_to_download_source_url. Received: '$server_file_size_str'. Will download if missing locally, or if local version exists (to be safe)."
                fi

                local should_download=false
                if [ ! -f "$file_to_download_local_path" ]; then
                    log_info "Local file $file_to_download_local_path does not exist. Scheduling for download."
                    should_download=true
                else
                    local local_file_size
                    local_file_size=$(stat -c%s "$file_to_download_local_path")
                    log_info "Local file $file_to_download_local_path exists. Size: $local_file_size bytes."
                    if [ "$server_file_size" -ne -1 ] && [ "$local_file_size" -ne "$server_file_size" ]; then
                        log_info "Local file size ($local_file_size) differs from server size ($server_file_size). Scheduling for download."
                        should_download=true
                    elif [ "$server_file_size" -eq -1 ]; then
                         log_warn "Local file $file_to_download_local_path exists, but server file size unknown. Re-downloading to be safe, as it might have been updated."
                         should_download=true
                    else
                        log_info "Local file size matches server size ($server_file_size bytes). Skipping download for $file_to_download_decoded_name."
                        should_download=false
                    fi
                fi

                if [ "$should_download" = true ]; then
                    log_info "Downloading: $file_to_download_source_url to $file_to_download_local_path"
                    if download_file "$file_to_download_source_url" "$file_to_download_local_path"; then
                        log_info "Successfully downloaded $file_to_download_decoded_name."
                        # NEEDS_RESTART=true # This line is intentionally REMOVED
                        if [ ! -f "$file_to_download_local_path" ] || [ ! -s "$file_to_download_local_path" ]; then
                            script_log "CRITICAL_ERROR: File $file_to_download_local_path missing or empty after download for $file_to_download_decoded_name."
                        else
                            local dl_size=$(stat -c%s "$file_to_download_local_path")
                            log_info "VERIFIED: File $file_to_download_local_path OK, size $dl_size for $file_to_download_decoded_name."
                        fi
                    else
                        script_log "ERROR: Download failed for $file_to_download_source_url."
                        # Optional: attempt to clean up partially downloaded file
                        rm -f "$file_to_download_local_path"
                    fi
                fi
            done
        else
            log_info "Model directory $decoded_item_name is empty on the server or no downloadable files found."
        fi
        return 0

    else # Item is an individual file
        log_info "Checking individual file: $decoded_item_name (Source: $current_item_source_url)"

        local server_file_size_str
        server_file_size_str=$(curl --max-time 10 -sI "$current_item_source_url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n')

        local server_file_size=-1
        if [[ "$server_file_size_str" =~ ^[0-9]+$ ]]; then
            server_file_size=$server_file_size_str
            log_info "Server file size for $decoded_item_name: $server_file_size bytes."
        else
            log_warn "Could not determine Content-Length for $current_item_source_url. Received: '$server_file_size_str'. Will download if missing locally or if local version exists (to be safe)."
        fi

        local should_download=false
        if [ ! -f "$current_local_item_path" ]; then
            log_info "Local file $current_local_item_path does not exist. Scheduling for download."
            should_download=true
        else
            local local_file_size
            local_file_size=$(stat -c%s "$current_local_item_path")
            log_info "Local file $current_local_item_path exists. Size: $local_file_size bytes."
            if [ "$server_file_size" -ne -1 ] && [ "$local_file_size" -ne "$server_file_size" ]; then
                log_info "Local file size ($local_file_size) differs from server size ($server_file_size). Scheduling for download."
                should_download=true
            elif [ "$server_file_size" -eq -1 ]; then
                 log_warn "Local file $current_local_item_path exists, but server file size unknown. Re-downloading to be safe, as it might have been updated."
                 should_download=true
            else
                log_info "Local file size matches server size ($server_file_size bytes). Skipping download for $decoded_item_name."
                should_download=false
            fi
        fi

        if [ "$should_download" = true ]; then
            log_info "Downloading: $current_item_source_url to $current_local_item_path"
            local parent_dir
            parent_dir=$(dirname "$current_local_item_path")
            mkdir -p "$parent_dir"
            if [ $? -ne 0 ]; then
                script_log "ERROR: Failed to create parent directory $parent_dir for model file $decoded_item_name"
                return 1
            fi

            if download_file "$current_item_source_url" "$current_local_item_path"; then
                log_info "Successfully downloaded $decoded_item_name."
                # NEEDS_RESTART=true # This line is intentionally REMOVED
                if [ ! -f "$current_local_item_path" ] || [ ! -s "$current_local_item_path" ]; then
                    script_log "CRITICAL_ERROR: File $current_local_item_path missing or empty after download for $decoded_item_name."
                    return 1
                else
                    local dl_size=$(stat -c%s "$current_local_item_path")
                    log_info "VERIFIED: File $current_local_item_path OK, size $dl_size for $decoded_item_name."
                fi
            else
                script_log "ERROR: Download failed for $current_item_source_url."
                # Optional: attempt to clean up partially downloaded file
                rm -f "$current_local_item_path"
                return 1
            fi
        fi
        return 0
    fi
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
    log_info "Auto download service started."

    while true; do
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
