#!/bin/bash

# Source common utilities
# Assuming common_utils.sh is in the same directory
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source."; exit 1; }

script_log "INFO: docker_setup.sh sourced."

# --- Docker Setup Specific Globals & Constants ---
DOCKERFILES_DIR_NAME="docker_config"
COMFYUI_DATA_DIR_NAME="comfyui_data"
SCRIPTS_DIR_NAME="scripts"
COMFYUI_IMAGE_NAME="comfyui-app" # Default, can be overridden by main script if needed

# Definer DEVEL image tag-delen her for klarhet
DOCKER_CUDA_DEVEL_TAG="12.8.1-cudnn-devel-ubuntu22.04"
# RUNTIME image tag er nå DYNAMISK satt fra DOCKER_CUDA_DEVEL_TAG i Dockerfile-genereringen.

# Dynamisk satte stier (will be set by initialize_docker_paths)
DOCKER_CONFIG_ACTUAL_PATH=""
DOCKER_DATA_ACTUAL_PATH=""
DOCKER_SCRIPTS_ACTUAL_PATH=""

# --- Docker Oppsett Funksjoner ---

initialize_docker_paths() {
    script_log "DEBUG: ENTERING initialize_docker_paths (docker_setup.sh)"
    # BASE_DOCKER_SETUP_DIR is from common_utils.sh
    DOCKER_CONFIG_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$DOCKERFILES_DIR_NAME"
    DOCKER_DATA_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME"
    DOCKER_SCRIPTS_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$SCRIPTS_DIR_NAME"
    script_log "DEBUG: DOCKER_CONFIG_ACTUAL_PATH set to $DOCKER_CONFIG_ACTUAL_PATH"
    script_log "DEBUG: DOCKER_DATA_ACTUAL_PATH set to $DOCKER_DATA_ACTUAL_PATH"
    script_log "DEBUG: DOCKER_SCRIPTS_ACTUAL_PATH set to $DOCKER_SCRIPTS_ACTUAL_PATH"
    script_log "DEBUG: EXITING initialize_docker_paths (docker_setup.sh)"
}

check_docker_status() {
    script_log "DEBUG: ENTERING check_docker_status (docker_setup.sh)"
    if ! command -v docker &> /dev/null; then
        log_error "Docker ser ikke ut til å være installert. Vennligst installer Docker og prøv igjen."
        script_log "DEBUG: EXITING check_docker_status (docker not installed)"
        return 1
    fi
    if ! docker info > /dev/null 2>&1; then
        log_error "Kan ikke koble til Docker daemon. Er Docker startet og kjører?"
        script_log "DEBUG: EXITING check_docker_status (docker daemon not reachable)"
        return 1
    fi
    script_log "DEBUG: EXITING check_docker_status (success)"
    return 0
}

build_comfyui_image() {
    script_log "DEBUG: ENTERING build_comfyui_image (docker_setup.sh)"

    if ! check_and_perform_nvcr_login; then
        log_error "NVIDIA Container Registry login failed or was skipped. Aborting build."
        script_log "DEBUG: EXITING build_comfyui_image (nvcr login failed)"
        return 1
    fi

    # initialize_docker_paths # This should be called before this function if paths are needed immediately.
                            # Or ensure it's called if DOCKER_CONFIG_ACTUAL_PATH is empty.
    if [[ -z "$DOCKER_CONFIG_ACTUAL_PATH" ]]; then
        log_warn "DOCKER_CONFIG_ACTUAL_PATH is not set. Calling initialize_docker_paths."
        initialize_docker_paths
    fi

    if [[ ! -f "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile" ]]; then
        log_error "Dockerfile ikke funnet i $DOCKER_CONFIG_ACTUAL_PATH. Kjør installasjon (valg 1) først."
        script_log "DEBUG: EXITING build_comfyui_image (Dockerfile not found)"
        return 1
    fi

    log_info "Starter bygging av Docker-image '$COMFYUI_IMAGE_NAME'..."

    local clean_devel_tag
    clean_devel_tag=$(echo -n "$DOCKER_CUDA_DEVEL_TAG" | tr -d '	' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    script_log "DEBUG FØR BUILD (Original DEVEL): DOCKER_CUDA_DEVEL_TAG er satt til: [$DOCKER_CUDA_DEVEL_TAG]"
    script_log "DEBUG FØR BUILD (Renset DEVEL): clean_devel_tag er satt til: [$clean_devel_tag]"
    log_info "Bruker devel tag (via build-arg): $clean_devel_tag"
    log_info "Runtime tag er dynamisk satt til samme som devel tag i Dockerfile: $DOCKER_CUDA_DEVEL_TAG"
    log_info "Dette kan ta en stund."

    local build_arg_devel_str
    build_arg_devel_str=$(printf '%s=%s' "PASSED_CUDA_DEVEL_TAG" "$clean_devel_tag")

    local DOCKER_BUILD_LOG_FILE
    DOCKER_BUILD_LOG_FILE="${DOCKER_CONFIG_ACTUAL_PATH}/docker_build_$(date +%Y%m%d_%H%M%S).log"
    log_info "Docker build output will be logged to: ${DOCKER_BUILD_LOG_FILE}"

    # Execute docker build and tee output to log file and screen
    docker build -t "$COMFYUI_IMAGE_NAME" \
        --build-arg "$build_arg_devel_str" \
        --build-arg "CACHE_BUSTER_RUNTIME_PACKAGES=$(date +%s)" \
        "$DOCKER_CONFIG_ACTUAL_PATH" 2>&1 | tee "${DOCKER_BUILD_LOG_FILE}"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Docker-image '$COMFYUI_IMAGE_NAME' bygget/oppdatert vellykket. Full log: ${DOCKER_BUILD_LOG_FILE}"
        script_log "DEBUG: EXITING build_comfyui_image (success)"
        return 0
    else
        log_error "Bygging av Docker-image mislyktes. Sjekk loggfilen for detaljer: ${DOCKER_BUILD_LOG_FILE}"
        log_error "FEIL UNDER DOCKER BUILD. TRYKK ENTER FOR Å GÅ TILBAKE TIL MENY."
        press_enter_to_continue # from common_utils.sh
        script_log "DEBUG: EXITING build_comfyui_image (build failed)"
        return 1
    fi
}

perform_docker_initial_setup() {
    local project_root_dir="$1"
    if [ -z "$project_root_dir" ]; then
        log_error "Project root directory not provided to perform_docker_initial_setup. Cannot locate auto_download_service.sh."
        return 1
    fi
    script_log "DEBUG: project_root_dir in perform_docker_initial_setup is: $project_root_dir"
    script_log "DEBUG: ENTERING perform_docker_initial_setup (docker_setup.sh)"
    set -e
    if ! check_docker_status; then
        script_log "DEBUG: EXITING perform_docker_initial_setup (Docker status check failed)"
        set +e
        return 1;
    fi

    # Ensure paths are initialized
    if [[ -z "$DOCKER_CONFIG_ACTUAL_PATH" ]]; then
        log_warn "Docker paths not set, calling initialize_docker_paths."
        initialize_docker_paths
    fi

    log_info "Starter førstegangs oppsett for ComfyUI i Docker..."

    if [ -d "$BASE_DOCKER_SETUP_DIR" ]; then # BASE_DOCKER_SETUP_DIR from common_utils.sh
        log_warn "Mappen '$BASE_DOCKER_SETUP_DIR' eksisterer allerede."
        local overwrite_choice # Renamed to avoid conflict if main script has same var
        echo -n "Vil du fortsette og potensielt overskrive konfigurasjonsfiler? (ja/nei): " >&2
        read -r overwrite_choice
        if [[ ! "$overwrite_choice" =~ ^[Jj][Aa]$ ]]; then
            log_info "Oppsett avbrutt av bruker."
            script_log "DEBUG: EXITING perform_docker_initial_setup (user aborted overwrite)"
            set +e
            return 1
        fi
    fi

    local num_gpus=0
    while true; do
        echo -n "Hvor mange GPUer vil du sette opp ComfyUI for? (f.eks. 1 eller 2): " >&2
        read -r num_gpus_input
        if [[ "$num_gpus_input" =~ ^[1-9][0-9]*$ ]]; then
            num_gpus=$num_gpus_input
            break
        else
            log_warn "Ugyldig input. Vennligst skriv inn et positivt tall."
        fi
    done

    log_info "Oppretter katalogstruktur i $BASE_DOCKER_SETUP_DIR..."
    mkdir -p "$DOCKER_CONFIG_ACTUAL_PATH"
    mkdir -p "$DOCKER_SCRIPTS_ACTUAL_PATH"
    mkdir -p "$DOCKER_DATA_ACTUAL_PATH/models"
    mkdir -p "$DOCKER_DATA_ACTUAL_PATH/custom_nodes"

    for i in $(seq 0 $((num_gpus - 1))); do
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/gpu${i}/input"
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/gpu${i}/output"
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/gpu${i}/temp"
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/huggingface"
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/torch"
        mkdir -p "$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/whisperx"
    done
    log_success "Katalogstruktur opprettet."

    log_info "Genererer Dockerfile med printf..."
    (
    printf '%s\n' '# Stage 1: Builder'
    printf 'ARG %s\n' "PASSED_CUDA_DEVEL_TAG"
    printf 'FROM nvcr.io/nvidia/cuda:%s AS builder\n' '${PASSED_CUDA_DEVEL_TAG}'
    printf '\n'
    printf 'ENV %s\n' 'DEBIAN_FRONTEND=noninteractive'
    # git was already here in builder stage
    printf 'RUN %s\n' 'apt-get update && apt-get install -y --no-install-recommends git python3-pip python3-venv ffmpeg curl && rm -rf /var/lib/apt/lists/*'
    printf 'RUN %s\n' 'python3 -m venv /opt/venv'
    printf 'ENV PATH="/opt/venv/bin:%s"\n' '$PATH'
    printf 'WORKDIR %s\n' '/app'
    printf 'RUN %s\n' 'git clone https://github.com/comfyanonymous/ComfyUI.git'
    printf 'WORKDIR %s\n' '/app/ComfyUI'
    printf 'RUN %s\n' 'pip install --no-cache-dir -r requirements.txt'
    printf 'RUN %s\n' 'pip install --no-cache-dir sageattention==1.0.6'
    printf '\n'
    printf '%s\n' '# Stage 2: Runtime'
    # Bruker samme tag som devel for runtime for å sikre kompatibilitet og tilgang til dev-verktøy hvis nødvendig
    printf 'FROM nvcr.io/nvidia/cuda:%s AS runtime\n' "$DOCKER_CUDA_DEVEL_TAG"
    printf '\n' # Ensure a blank line for readability if one isn't already there
    printf '# Set environment variables to make CUDA discoverable\n'
    printf 'ENV CUDA_HOME=/usr/local/cuda\n'
    printf 'ENV PATH=/usr/local/cuda/bin:${PATH}\n'
    printf 'ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}\n'
    printf '\n' # Add a blank line after for readability
    printf 'ENV %s\n' 'DEBIAN_FRONTEND=noninteractive'
    # git added here in runtime stage in previous commit
    printf 'ARG CACHE_BUSTER_RUNTIME_PACKAGES\n'
    printf 'RUN %s\n' 'apt-get update && apt-get install -y --no-install-recommends git python3-pip ffmpeg curl libgl1 build-essential gcc python3-dev && rm -rf /var/lib/apt/lists/*'
    printf 'RUN ldconfig\n'
    printf 'COPY %s\n' '--from=builder /opt/venv /opt/venv'
    printf 'COPY %s\n' '--from=builder /app/ComfyUI /app/ComfyUI'
    printf 'WORKDIR %s\n' '/app/ComfyUI'
    printf 'RUN %s\n' 'mkdir -p ./models ./input ./output ./temp /cache/huggingface /cache/torch /cache/whisperx'
    printf 'ENV HF_HOME="%s"\n' '/cache/huggingface'
    printf 'ENV TORCH_HOME="%s"\n' '/cache/torch'
    printf 'ENV WHISPERX_CACHE_DIR="%s"\n' '/cache/whisperx'
    printf 'ENV PATH="/opt/venv/bin:%s"\n' '$PATH'
    printf 'EXPOSE %s\n' '8188'
    printf 'CMD %s\n' '["python3", "main.py", "--max-upload-size", "1000", "--listen", "0.0.0.0", "--port", "8188", "--preview-method", "auto"]'
    ) > "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile"
    log_success "Dockerfile generert med printf."

    if ! build_comfyui_image; then
        log_error "Kunne ikke bygge Docker image. Oppsett ufullstendig."
        script_log "DEBUG: EXITING perform_docker_initial_setup (build_comfyui_image failed)"
        set +e
        return 1
    fi

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "set -e" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "# Auto-downloader service management" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "auto_downloader_script_path=\"$project_root_dir/auto_download_service.sh\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "pid_file_path=\"\$(dirname \"\$0\")/auto_download_service.pid\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    # Get BASE_DOCKER_SETUP_DIR from environment, should be exported by common_utils.sh from the parent execution
    echo "base_docker_setup_dir_for_log=\"\$BASE_DOCKER_SETUP_DIR\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "if [ -f \"\$auto_downloader_script_path\" ]; then" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    echo \"Starting auto-download service...\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    if [ -z \"\$base_docker_setup_dir_for_log\" ]; then" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "        echo 'WARN: BASE_DOCKER_SETUP_DIR not found in environment. Logging auto-downloader to /tmp/auto_download_service.log'" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "        log_file=\"/tmp/auto_download_service.log\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    else" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "        log_file=\"\${base_docker_setup_dir_for_log}/auto_download_service.log\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    fi" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    mkdir -p \"\$(dirname \"\$log_file\")\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    nohup \"\$auto_downloader_script_path\" >> \"\$log_file\" 2>&1 & echo \$! > \"\$pid_file_path\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    echo \"Auto-download service started with PID \$(cat \$pid_file_path). Log: \$log_file\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "else" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "    echo \"WARN: Auto-download service script not found at \$auto_downloader_script_path\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "fi" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    echo "" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"

    for i in $(seq 0 $((num_gpus - 1))); do
        container_name="comfyui-gpu${i}"
        host_port=$((8188 + i))
        echo "echo \"Starter ComfyUI for GPU $i (Container: $container_name) på port $host_port...\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "docker run -d --name \"$container_name\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  --gpus device=$i \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -p \"${host_port}:8188\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/models:/app/ComfyUI/models\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/custom_nodes:/app/ComfyUI/custom_nodes\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v comfyui_pip_packages:/opt/venv/lib/python3.10/site-packages/ \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/input:/app/ComfyUI/input\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/output:/app/ComfyUI/output\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/temp:/app/ComfyUI/temp\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/huggingface:/cache/huggingface\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/torch:/cache/torch\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/whisperx:/cache/whisperx\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  --network host \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" # Keep or remove based on user needs
        echo "  --restart unless-stopped \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  \"$COMFYUI_IMAGE_NAME\" python3 main.py --max-upload-size 1000 --listen 0.0.0.0 --port \"${host_port}\" --preview-method auto --cuda-device $i" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "echo \"ComfyUI for GPU $i (Container: $container_name) er tilgjengelig på http://localhost:${host_port}\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    done
    chmod +x "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    log_success "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh generert."

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "# Auto-downloader service management" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "pid_file_path=\"\$(dirname \"\$0\")/auto_download_service.pid\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "if [ -f \"\$pid_file_path\" ]; then" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    echo \"Stopping auto-download service...\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    service_pid=\$(cat \"\$pid_file_path\")" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    if [ -n \"\$service_pid\" ]; then" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        if kill \"\$service_pid\" > /dev/null 2>&1; then" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "            echo \"Auto-download service (PID: \$service_pid) stopped.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        else" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "            echo \"WARN: Failed to stop auto-download service (PID: \$service_pid), or it was not running.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        fi" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        rm \"\$pid_file_path\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    else" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        echo \"WARN: PID file was empty at \$pid_file_path, removing it.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "        rm \"\$pid_file_path\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    fi" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "else" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "    echo \"INFO: Auto-download service PID file not found at \$pid_file_path, service likely not started or already stopped.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "fi" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    echo "" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"

    for i in $(seq 0 $((num_gpus - 1))); do
        container_name="comfyui-gpu${i}"
        echo "echo \"Stopper og fjerner container $container_name...\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
        echo "docker stop \"$container_name\" >/dev/null 2>&1 || echo \"Container $container_name var ikke startet.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
        echo "docker rm \"$container_name\" >/dev/null 2>&1 || echo \"Container $container_name fantes ikke.\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    done
    chmod +x "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    log_success "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh generert."

    echo ""
    log_success "--- Docker Oppsett Fullført! ---"
    log_info "ComfyUI Docker-oppsett er konfigurert i: $BASE_DOCKER_SETUP_DIR"
    log_info "Viktige stier:"
    echo "  - Docker konfig: $DOCKER_CONFIG_ACTUAL_PATH"
    echo "  - Data (modeller, custom_nodes etc.): $DOCKER_DATA_ACTUAL_PATH"
    echo "  - Start/stopp skript: $DOCKER_SCRIPTS_ACTUAL_PATH"
    log_warn "HUSK: Legg modeller i '$DOCKER_DATA_ACTUAL_PATH/models' og custom nodes i '$DOCKER_DATA_ACTUAL_PATH/custom_nodes'."

    set +e

    install_comfyui_manager_on_host # This function is also part of docker_setup.sh

    local start_now_choice # Renamed
    echo -n "Vil du starte ComfyUI container(e) nå? (ja/nei): " >&2
    read -r start_now_choice
    if [[ "$start_now_choice" =~ ^[Jj][Aa]$ ]]; then
        if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
            "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        else
            log_error "Startskript ikke funnet."
        fi
    fi

    # Prompt for model downloader will be handled by the main script menu logic
    # We don't call run_model_downloader from here anymore.
    script_log "DEBUG: EXITING perform_docker_initial_setup (docker_setup.sh)"
}

install_comfyui_manager_on_host() {
    script_log "DEBUG: ENTERING install_comfyui_manager_on_host (docker_setup.sh)"
    # Ensure DOCKER_DATA_ACTUAL_PATH is set
    if [ -z "$DOCKER_DATA_ACTUAL_PATH" ]; then
        log_warn "DOCKER_DATA_ACTUAL_PATH is not set. Calling initialize_docker_paths."
        initialize_docker_paths
    fi

    local target_custom_nodes_dir="${DOCKER_DATA_ACTUAL_PATH}/custom_nodes"
    local manager_dir="${target_custom_nodes_dir}/ComfyUI-Manager"

    log_info "Checking ComfyUI-Manager installation in host directory: $manager_dir"

    if [ -d "$manager_dir" ]; then
        local reinstall_choice # Renamed
        echo -n "ComfyUI-Manager already exists at $manager_dir. Reinstall? (ja/nei): " >&2
        read -r reinstall_choice
        if [[ "$reinstall_choice" =~ ^[Jj][Aa]$ ]]; then
            log_info "Removing existing ComfyUI-Manager for reinstall..."
            log_info "Attempting to remove with sudo due to potential permission issues..."
            if ! sudo rm -rf "$manager_dir"; then
                log_error "Failed to remove existing ComfyUI-Manager directory. Please check permissions and sudo access."
                script_log "DEBUG: EXITING install_comfyui_manager_on_host (failed to remove old manager dir)"
                return 1
            fi
            log_success "Existing ComfyUI-Manager removed."
        else
            log_info "Skipping ComfyUI-Manager installation."
            log_warn "IMPORTANT: ComfyUI-Manager is present at $manager_dir."
            log_warn "Its Python dependencies may need to be installed *inside the running Docker container's environment*."
            # ... (other warnings remain the same)
            script_log "DEBUG: EXITING install_comfyui_manager_on_host (skipped reinstall)"
            return 0
        fi
    fi

    if ! command -v git &> /dev/null; then
        log_warn "git command not found. Attempting to install..."
        if sudo apt update && sudo apt install -y git; then
            log_success "git installed successfully."
        else
            log_error "Failed to install git. ComfyUI-Manager cloning will likely fail."
            log_error "Please install git manually and try again."
            script_log "DEBUG: EXITING install_comfyui_manager_on_host (git install failed)"
            return 1
        fi
    fi

    if ! mkdir -p "$target_custom_nodes_dir"; then
        log_error "Failed to create target directory $target_custom_nodes_dir. Please check permissions."
        script_log "DEBUG: EXITING install_comfyui_manager_on_host (failed to create target_custom_nodes_dir)"
        return 1
    fi

    log_info "Cloning ComfyUI-Manager to $manager_dir..."
    if git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$manager_dir"; then
        log_success "ComfyUI-Manager cloned successfully to $manager_dir."
        log_warn "IMPORTANT: ComfyUI-Manager has been cloned to $manager_dir."
        log_warn "Its Python dependencies may need to be installed *inside the running Docker container's environment*."
        log_warn "After starting ComfyUI, you might need to run a command like:"
        log_warn "  docker exec -it <your_container_name> pip install -r /app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt"
        log_warn "Replace <your_container_name> with the actual name of your running ComfyUI container (e.g., comfyui-gpu0)."
    else
        log_error "Failed to clone ComfyUI-Manager."
        script_log "DEBUG: EXITING install_comfyui_manager_on_host (git clone failed)"
        return 1
    fi
    script_log "DEBUG: EXITING install_comfyui_manager_on_host (success)"
    return 0
}

script_log "DEBUG: docker_setup.sh execution finished its own content."
