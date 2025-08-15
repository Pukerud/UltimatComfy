#!/bin/bash

# Source common utilities
# Assuming common_utils.sh is in the same directory
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source."; exit 1; }
# shellcheck source=./docker_setup.sh
source "$(dirname "$0")/docker_setup.sh" || { echo "ERROR: docker_setup.sh not found or failed to source. Exiting."; exit 1; }

script_log "INFO: update_frontend.sh started."

if ! check_docker_status; then
    log_error "Docker is not running. Please start Docker and try again."
    script_log "INFO: update_frontend.sh finished (Docker not running)."
    exit 1
fi

log_info "Searching for running ComfyUI containers (comfyui-gpu*)..."
mapfile -t running_containers < <(docker ps --filter "name=comfyui-gpu" --format "{{.Names}}")

if [ ${#running_containers[@]} -eq 0 ]; then
    log_warn "No running ComfyUI containers found."
    script_log "INFO: update_frontend.sh finished (no containers found)."
    exit 0
fi

log_info "Found running containers:"
for container in "${running_containers[@]}"; do
    echo " - $container"
done

for container in "${running_containers[@]}"; do
    log_info "--- Updating frontend for $container ---"

    # The command to run inside the container
    update_command="/opt/venv/bin/python3 -m pip install -r /app/ComfyUI/requirements.txt"

    log_info "Executing command in $container: $update_command"

    # Execute the command
    docker exec "$container" sh -c "$update_command"

    if [ $? -eq 0 ]; then
        log_success "--- Successfully updated frontend for $container ---"
    else
        log_error "--- Failed to update frontend for $container ---"
    fi
done

log_success "Frontend update process finished for all found containers."
script_log "INFO: update_frontend.sh finished."
exit 0
