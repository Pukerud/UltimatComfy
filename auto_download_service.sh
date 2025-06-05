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
AUTO_NODES_PATH="Auto/Nodes/"
AUTO_MODELS_PATH="Auto/Models/"

NEEDS_RESTART=false

# Functions
check_for_new_nodes() {
    log_info "Checking for new nodes on the server..."

    local server_nodes_raw
    server_nodes_raw=$(curl -sL "$SERVER_BASE_URL$AUTO_NODES_PATH" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep '/$' | sed 's|/||')
    if [ $? -ne 0 ] || [ -z "$server_nodes_raw" ]; then
        log_info "Failed to retrieve node list from server or no nodes found."
        return
    fi

    mapfile -t server_nodes < <(echo "$server_nodes_raw")

    local local_custom_nodes_path="$DOCKER_DATA_ACTUAL_PATH/custom_nodes/"
    if [ ! -d "$local_custom_nodes_path" ]; then
        log_info "Local custom_nodes directory does not exist. Creating: $local_custom_nodes_path"
        mkdir -p "$local_custom_nodes_path"
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to create local custom_nodes directory: $local_custom_nodes_path"
            return
        fi
    fi

    local local_nodes_raw
    local_nodes_raw=$(ls "$local_custom_nodes_path")
    mapfile -t local_nodes < <(echo "$local_nodes_raw")

    for node_name in "${server_nodes[@]}"; do
        if [[ ! " ${local_nodes[*]} " =~ " ${node_name} " ]]; then
            log_info "New node '$node_name' found on server."
            if download_node "$node_name"; then
                NEEDS_RESTART=true
            fi
        fi
    done
    log_info "Finished checking for new nodes."
}

_recursive_download_node_contents() {
    local node_name="$1"                         # e.g., "ComfyUI-Crystools"
    local current_server_relative_path="$2"      # e.g., "" or "js/" or "subfolder/js/" (must end with / if not empty for directories)
    local current_local_node_base_path="$3"      # e.g., ".../custom_nodes/ComfyUI-Crystools" or ".../custom_nodes/ComfyUI-Crystools/js"

    local full_server_url="$SERVER_BASE_URL$AUTO_NODES_PATH$node_name/$current_server_relative_path"
    # Ensure trailing slash for directory URLs if current_server_relative_path is not empty and doesn't have one
    if [ -n "$current_server_relative_path" ] && [[ "$full_server_url" != */ ]]; then
        full_server_url+="/"
    elif [ -z "$current_server_relative_path" ] && [[ "$full_server_url" != */ ]]; then # Top level node_name might not have slash
         full_server_url+="/"
    fi

    log_info "Recursively processing server path: $full_server_url into local path: $current_local_node_base_path"

    local server_items_raw
    server_items_raw=$(curl -sL "$full_server_url" | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '^\.\./$' | grep -v '^Parent directory$' | grep -E -v '^\?C=[A-Z];O=[A-Z]$')

    if [ $? -ne 0 ]; then
        script_log "ERROR: curl failed to list items from $full_server_url"
        return 1 # curl error
    fi

    if [ -z "$server_items_raw" ]; then
        log_info "No items (files or subdirectories) found in $full_server_url. Assuming empty directory or end of recursion branch."
        return 0 # Successfully processed an empty directory
    fi

    mapfile -t server_items < <(echo "$server_items_raw")

    for item_on_server in "${server_items[@]}"; do
        local decoded_item_name
        decoded_item_name=$(printf '%b' "${item_on_server//%/\\x}") # URL decode

        if [[ "$item_on_server" == */ ]]; then # It's a directory (original name from server ends with /)
            log_info "Found directory: $decoded_item_name within $node_name/$current_server_relative_path"
            local local_subdir_path="$current_local_node_base_path/$decoded_item_name"
            # Ensure local_subdir_path also has a trailing slash if decoded_item_name had one.
            # decoded_item_name should retain the trailing slash from item_on_server.

            mkdir -p "$local_subdir_path" # mkdir -p handles trailing slash correctly
            if [ $? -ne 0 ]; then
                script_log "ERROR: Failed to create local directory $local_subdir_path"
                return 1
            fi

            # Recursive call:
            # - current_server_relative_path appends the new directory (item_on_server, which includes its trailing /)
            # - current_local_node_base_path is the newly created local_subdir_path (which should also have trailing slash if it's a dir)
            if ! _recursive_download_node_contents "$node_name" "$current_server_relative_path$item_on_server" "$local_subdir_path"; then
                script_log "ERROR: Recursive download failed for subdirectory $decoded_item_name of node $node_name."
                return 1 # Propagate failure
            fi
        else # It's a file
            log_info "Found file: $decoded_item_name within $node_name/$current_server_relative_path"
            # Construct file source URL carefully: full_server_url already has node_name/current_server_relative_path/
            # item_on_server is the filename itself from this level.
            local file_source_url="$full_server_url$item_on_server"
            local file_local_target_path="$current_local_node_base_path/$decoded_item_name"

            # Ensure parent directory for the file exists
            local file_parent_dir
            file_parent_dir=$(dirname "$file_local_target_path")
            mkdir -p "$file_parent_dir" # Should be redundant if current_local_node_base_path is correct, but safe
            if [ $? -ne 0 ]; then
                 script_log "ERROR: Failed to create parent directory $file_parent_dir for file $decoded_item_name"
                 return 1
            fi

            log_info "Downloading: $file_source_url to $file_local_target_path"
            wget -nv -O "$file_local_target_path" "$file_source_url"
            if [ $? -ne 0 ]; then
                script_log "ERROR: Failed to download file $decoded_item_name from $file_source_url to $file_local_target_path"
                return 1
            fi
        fi
    done
    return 0 # All items in this directory processed successfully
}

download_node() {
    local node_name="$1" # This is just the top-level node directory name, e.g. "ComfyUI-Manager"
    log_info "Attempting to download node: $node_name"
    local target_node_top_level_dir="$DOCKER_DATA_ACTUAL_PATH/custom_nodes/$node_name"

    # Create the top-level directory for the node
    mkdir -p "$target_node_top_level_dir"
    if [ $? -ne 0 ]; then
        script_log "ERROR: Failed to create top-level directory for node $node_name at $target_node_top_level_dir"
        return 1
    fi

    log_info "Starting recursive download for node $node_name into $target_node_top_level_dir"
    # Initial call: current_server_relative_path is empty, current_local_node_base_path is the top-level dir
    if ! _recursive_download_node_contents "$node_name" "" "$target_node_top_level_dir"; then
        script_log "ERROR: Recursive download failed for node $node_name. Check previous logs for details."
        # Consider cleaning up: rm -rf "$target_node_top_level_dir"
        return 1 # Download part failed
    fi

    log_info "Successfully downloaded all contents for node $node_name."

    # Proceed with dependency installation only if download was successful
    if install_node_dependencies "$target_node_top_level_dir"; then
        log_info "Dependencies installed (or not needed) for node $node_name."
        return 0 # Success for both download and dependencies
    else
        script_log "ERROR: Failed to install dependencies for node $node_name."
        # Consider cleaning up: rm -rf "$target_node_top_level_dir"
        return 1 # Dependencies part failed
    fi
}

install_node_dependencies() {
    local node_path="$1"
    log_info "Checking for dependencies in: $node_path"

    local requirements_file="$node_path/requirements.txt"

    if [ ! -f "$requirements_file" ]; then
        log_info "No requirements.txt found in $node_path. No dependencies to install for this node."
        return 0 # Success, as there's nothing to do
    fi

    log_info "requirements.txt found in $node_path. Attempting to install dependencies."

    local current_dir
    current_dir=$(pwd)

    if ! cd "$node_path"; then
        script_log "ERROR: Failed to change directory to $node_path."
        # Attempt to cd back to original directory, though $current_dir might not be set if pwd failed.
        # However, pwd failing is highly unlikely.
        cd "$current_dir"
        return 1 # Failure
    fi

    log_info "Installing dependencies from $requirements_file..."
    pip install -r requirements.txt
    local pip_exit_code=$?

    if [ $pip_exit_code -eq 0 ]; then
        log_info "Successfully installed dependencies from $requirements_file."
    else
        script_log "ERROR: pip install -r requirements.txt failed with exit code $pip_exit_code for $node_path."
    fi

    if ! cd "$current_dir"; then
        script_log "ERROR: Failed to change directory back to $current_dir from $node_path. This is unexpected."
        # This is a more serious issue, might indicate a problem with $current_dir or filesystem state
        # For now, still return based on pip_exit_code, but this warrants attention if it occurs.
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
                if [ $? -ne 0 ]; then
                    script_log "ERROR: Failed to download file $file_in_item_dir_decoded for model directory $decoded_item_name from $file_source_url"
                    return 1 # Fail the whole directory download if one file fails
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
        if [ $? -ne 0 ]; then
            script_log "ERROR: Failed to download model file $decoded_item_name from $source_item_url"
            return 1
        fi
        log_info "Successfully downloaded model file: $decoded_item_name"
        return 0
    fi
}

restart_comfyui_containers() {
    log_info "Beginning ComfyUI container restart process..."

    if [ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]; then
        script_log "ERROR: DOCKER_SCRIPTS_ACTUAL_PATH is not set. Cannot restart containers."
        return 1
    fi

    local stop_script_path="$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    local start_script_path="$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"

    if [ ! -x "$stop_script_path" ]; then
        script_log "ERROR: Stop script not found or not executable at $stop_script_path"
        return 1
    fi

    if [ ! -x "$start_script_path" ]; then
        script_log "ERROR: Start script not found or not executable at $start_script_path"
        return 1
    fi

    log_info "Stopping ComfyUI containers using $stop_script_path..."
    "$stop_script_path"
    local stop_exit_code=$?
    if [ $stop_exit_code -ne 0 ]; then
        script_log "ERROR: Failed to stop ComfyUI containers. Exit code: $stop_exit_code. Proceeding to attempt start..."
    else
        log_info "ComfyUI containers stopped successfully."
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
