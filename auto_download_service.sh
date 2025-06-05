#!/bin/bash

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
    script_log "Error: docker_setup.sh not found."
    exit 1
fi

# Initialize Docker paths
initialize_docker_paths

# Server configuration
SERVER_BASE_URL="http://192.168.1.29:8081/"
AUTO_NODES_PATH="Auto/Nodes/" # Used for Custom.txt, actual nodes are cloned from git repos
AUTO_MODELS_PATH="Auto/Models/"

NEEDS_RESTART=false
PROCESSED_CUSTOM_TXT_PATH="" # Will be initialized in main or after DOCKER_DATA_ACTUAL_PATH is set

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

    local repo_name
    repo_name=$(basename "$git_url" .git)
    repo_name=$(basename "$repo_name") # Handles if .git was not present, or to get final component

    if [ -z "$repo_name" ] || [ "$repo_name" == "." ]; then
        script_log "ERROR: Could not determine repository name from URL: $git_url"
        return 1
    fi
    log_info "Determined repository name: $repo_name"

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
        # We still run install_node_dependencies in case requirements changed or failed previously
        if install_node_dependencies "$cloned_repo_path"; then
            return 0 # Success, as it's "processed"
        else
            script_log "ERROR: Dependency installation failed for existing repo $repo_name. It will be retried."
            return 1 # Failed, so it's not marked as "processed" in Custom.txt.processed
        fi
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
        return 1
    fi

    # Move temp clone to final destination
    mv "$temp_clone_path" "$cloned_repo_path"
    if [ $? -ne 0 ]; then
        script_log "ERROR: Failed to move temporary clone from $temp_clone_path to $cloned_repo_path."
        rm -rf "$temp_clone_path" # Clean up temp clone just in case
        # cloned_repo_path might be partially there if mv failed midway, consider cleaning it too
        rm -rf "$cloned_repo_path"
        return 1
    fi

    log_info "Successfully cloned $repo_name to $cloned_repo_path."

    if install_node_dependencies "$cloned_repo_path"; then
        log_info "Dependencies installed successfully for $repo_name."
        return 0 # Full success
    else
        script_log "ERROR: Dependency installation failed for $repo_name."
        # Keep the cloned repo, but return failure so it's retried (deps might be fixed later)
        return 1
    fi
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
    wget -nv -O "$downloaded_custom_txt" "$server_custom_txt_url"
    local wget_exit_code=$?

    if [ $wget_exit_code -ne 0 ]; then
        script_log "ERROR: Failed to download Custom.txt from $server_custom_txt_url. Exit code: $wget_exit_code"
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

    local new_commands_processed_this_cycle=false
    mapfile -t current_lines < "$downloaded_custom_txt"

    for line in "${current_lines[@]}"; do
        local trimmed_line
        trimmed_line=$(echo "$line" | awk '{$1=$1};1') # Trim leading/trailing whitespace, handles multiple spaces

        if [ -z "$trimmed_line" ] || [[ "$trimmed_line" == \#* ]]; then # Skip empty lines or comments
            continue
        fi

        # Check if command already processed
        # Using grep -Fxq for exact, fixed string, quiet match.
        if ! grep -Fxq "$trimmed_line" "$PROCESSED_CUSTOM_TXT_PATH"; then
            log_info "New command found in Custom.txt: '$trimmed_line'"
            if [[ "$trimmed_line" == git\ clone* ]]; then
                if process_git_clone_command "$trimmed_line"; then
                    log_info "Successfully processed command: '$trimmed_line'. Appending to processed list."
                    echo "$trimmed_line" >> "$PROCESSED_CUSTOM_TXT_PATH"
                    NEEDS_RESTART=true
                    new_commands_processed_this_cycle=true
                else
                    script_log "ERROR: Failed to process command: '$trimmed_line'. It will be retried next cycle."
                fi
            else
                script_log "WARN: Non 'git clone' command found in Custom.txt: '$trimmed_line'. Skipping."
                # Optionally, add non-clone lines to processed list if they should not be re-evaluated
                # echo "$trimmed_line" >> "$PROCESSED_CUSTOM_TXT_PATH"
            fi
        else
            log_info "Command already processed: '$trimmed_line'"
        fi
    done

    rm -f "$downloaded_custom_txt"
    log_info "Finished checking for new nodes from Custom.txt."
    # If new_commands_processed_this_cycle is true, NEEDS_RESTART would have been set.
}

install_node_dependencies() {
    local node_path="$1" # This is the host path, e.g., /data/ComfyUI/custom_nodes/MyNode
    log_info "Checking for dependencies in: $node_path"

    local host_requirements_file="$node_path/requirements.txt"

    if [ ! -f "$host_requirements_file" ]; then
        log_info "No requirements.txt found in $node_path. No dependencies to install for this node."
        return 0 # Success, as there's nothing to do
    fi

    log_info "requirements.txt found at $host_requirements_file. Attempting to install dependencies in ComfyUI container."

    local container_name
    container_name=$(docker ps --filter "name=comfyui-gpu" --format "{{.Names}}" | head -n 1)

    if [ -z "$container_name" ]; then
        script_log "ERROR: No running ComfyUI container (comfyui-gpu*) found. Cannot install dependencies for $node_path."
        return 1
    fi
    log_info "Found ComfyUI container: $container_name"

    local repo_name
    repo_name=$(basename "$node_path")
    if [ -z "$repo_name" ] || [ "$repo_name" == "." ]; then
        script_log "ERROR: Could not determine repository name from node path: $node_path"
        return 1
    fi

    # DOCKER_DATA_ACTUAL_PATH/custom_nodes/MyNode/requirements.txt -> /app/ComfyUI/custom_nodes/MyNode/requirements.txt
    local container_req_path="/app/ComfyUI/custom_nodes/$repo_name/requirements.txt"
    log_info "Host requirements file: $host_requirements_file"
    log_info "Target container requirements file path: $container_req_path for repo $repo_name in container $container_name"

    log_info "Executing pip install in container $container_name for $container_req_path..."
    docker exec "$container_name" python3 -m pip install -r "$container_req_path"
    local pip_exit_code=$?

    if [ $pip_exit_code -eq 0 ]; then
        log_info "Successfully installed dependencies from $container_req_path in container $container_name."
    else
        script_log "ERROR: 'docker exec $container_name python3 -m pip install -r $container_req_path' failed with exit code $pip_exit_code."
    fi

    return $pip_exit_code
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
        # Decode URL-encoded characters like %20 for space
        decoded_item_name=$(printf '%b' "${item_name//%/\\x}")

        local local_item_path="$local_models_base_path$decoded_item_name"

        if [[ "$decoded_item_name" == */ ]]; then # It's a directory
            if [ ! -d "$local_item_path" ]; then
                log_info "New model directory '$decoded_item_name' found on server."
                download_model "$decoded_item_name" # Pass with trailing slash
            fi
        else # It's a file
            if [ ! -f "$local_item_path" ]; then
                log_info "New model file '$decoded_item_name' found on server."
                download_model "$decoded_item_name" # Pass as is
            fi
        fi
    done
    log_info "Finished checking for new models."
}

download_model() {
    local item_name="$1" # Can be "file.safetensors" or "subdir/"
    log_info "Attempting to download model item: $item_name"

    # Decode URL-encoded characters from item_name, as it comes from HTML listing
    local decoded_item_name
    decoded_item_name=$(printf '%b' "${item_name//%/\\x}")

    local source_item_url="$SERVER_BASE_URL$AUTO_MODELS_PATH$item_name" # Use original item_name for URL
    local local_item_path="$DOCKER_DATA_ACTUAL_PATH/models/$decoded_item_name" # Use decoded_item_name for local path

    if [[ "$decoded_item_name" == */ ]]; then # Directory
        log_info "Creating directory and downloading contents for: $local_item_path"
        mkdir -p "$local_item_path"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create directory $local_item_path for model item $decoded_item_name"
            return 1
        fi

        local files_in_dir_raw
        files_in_dir_raw=$(curl -sL "$source_item_url" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '/$' | grep -v '^\.\./$' | grep -v '^Parent directory')

        if [ $? -ne 0 ]; then # Check curl exit status for listing files in dir
             script_log "ERROR: Failed to retrieve file list for model directory $decoded_item_name from $source_item_url"
             return 1
        fi

        # It's okay if a directory is empty, so no error if files_in_dir_raw is empty.
        if [ -n "$files_in_dir_raw" ]; then
            mapfile -t files_in_dir < <(echo "$files_in_dir_raw")
            log_info "Found ${#files_in_dir[@]} files in directory $decoded_item_name. Starting download..."
            for file_in_item_dir_encoded in "${files_in_dir[@]}"; do
                local file_in_item_dir_decoded
                file_in_item_dir_decoded=$(printf '%b' "${file_in_item_dir_encoded//%/\\x}")

                local file_source_url="$source_item_url$file_in_item_dir_encoded" # Use encoded for URL
                local file_local_path="$local_item_path$file_in_item_dir_decoded" # Use decoded for local path

                log_info "Downloading: $file_source_url to $file_local_path"
                wget -nv -O "$file_local_path" "$file_source_url"
                local wget_exit_code=$?
                log_info "wget raw exit code for model file $file_in_item_dir_decoded ($file_source_url): $wget_exit_code"
                if [ $wget_exit_code -ne 0 ]; then
                    script_log "ERROR: wget download failed for model file $file_in_item_dir_decoded from $file_source_url with exit code $wget_exit_code."
                    script_log "DEBUG: Listing contents of target directory $(dirname "$file_local_path"):"
                    ls -lA "$(dirname "$file_local_path")"
                    return 1
                fi
                # Stricter verification for model files in a directory
                if [ ! -f "$file_local_path" ]; then
                    script_log "CRITICAL_ERROR: Model file $file_local_path NOT FOUND immediately after wget reported success (exit code 0) for $file_in_item_dir_decoded."
                    script_log "DEBUG: Listing contents of target directory $(dirname "$file_local_path"):"
                    ls -lA "$(dirname "$file_local_path")"
                    return 1
                elif [ ! -s "$file_local_path" ]; then
                    script_log "CRITICAL_ERROR: Model file $file_local_path IS EMPTY immediately after wget reported success (exit code 0) for $file_in_item_dir_decoded."
                    script_log "DEBUG: Listing contents of target directory $(dirname "$file_local_path"):"
                    ls -lA "$(dirname "$file_local_path")"
                    return 1
                else
                    local file_size
                    file_size=$(stat -c%s "$file_local_path")
                    log_info "VERIFIED: Model file $file_local_path exists, is not empty, and has size $file_size bytes after download for $file_in_item_dir_decoded."
                fi
            done
        else
            log_info "Model directory $decoded_item_name is empty on the server."
        fi
        log_info "Successfully processed model directory: $decoded_item_name"
        return 0
    else # File
        log_info "Downloading file: $source_item_url to $local_item_path"
        local parent_dir
        parent_dir=$(dirname "$local_item_path")
        mkdir -p "$parent_dir"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create parent directory $parent_dir for model file $decoded_item_name"
            return 1
        fi

        wget -nv -O "$local_item_path" "$source_item_url"
        local wget_exit_code=$?
        log_info "wget raw exit code for single model $decoded_item_name ($source_item_url): $wget_exit_code"
        if [ $wget_exit_code -ne 0 ]; then
            script_log "ERROR: wget download failed for single model $decoded_item_name from $source_item_url with exit code $wget_exit_code."
            script_log "DEBUG: Listing contents of target directory $(dirname "$local_item_path"):"
            ls -lA "$(dirname "$local_item_path")"
            return 1
        fi
        # Stricter verification for single model file
        if [ ! -f "$local_item_path" ]; then
            script_log "CRITICAL_ERROR: Single model file $local_item_path NOT FOUND immediately after wget reported success (exit code 0) for $decoded_item_name."
            script_log "DEBUG: Listing contents of target directory $(dirname "$local_item_path"):"
            ls -lA "$(dirname "$local_item_path")"
            return 1
        elif [ ! -s "$local_item_path" ]; then
            script_log "CRITICAL_ERROR: Single model file $local_item_path IS EMPTY immediately after wget reported success (exit code 0) for $decoded_item_name."
            script_log "DEBUG: Listing contents of target directory $(dirname "$local_item_path"):"
            ls -lA "$(dirname "$local_item_path")"
            return 1
        else
            local file_size
            file_size=$(stat -c%s "$local_item_path")
            log_info "VERIFIED: Single model file $local_item_path exists, is not empty, and has size $file_size bytes after download for $decoded_item_name."
        fi
        log_info "Successfully downloaded model file: $decoded_item_name"
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
    "$start_script_path"
    local start_exit_code=$?
    if [ $start_exit_code -ne 0 ]; then
        script_log "ERROR: Failed to start ComfyUI containers. Exit code: $start_exit_code."
        return 1
    else
        log_info "ComfyUI containers started successfully."
    fi

    # If stop failed but start succeeded, we consider it a success overall for the restart operation's attempt.
    # The primary goal is to get the containers running with the new changes.
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

# Run the main function
main
