#!/bin/bash
# SCRIPT_VERSION_4
# Kombinert skript for ComfyUI Docker Oppsett og Modelldenedlasting

# --- Globale Innstillinger og Konstanter ---
# Farger for logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# For Docker-oppsett
BASE_DOCKER_SETUP_DIR="$HOME/comfyui_unified_setup"
SCRIPT_LOG_FILE="$BASE_DOCKER_SETUP_DIR/ultimate_comfy_debug.log"
DOCKERFILES_DIR_NAME="docker_config"
COMFYUI_DATA_DIR_NAME="comfyui_data"
SCRIPTS_DIR_NAME="scripts"
COMFYUI_IMAGE_NAME="comfyui-app"

# Definer DEVEL image tag-delen her for klarhet
DOCKER_CUDA_DEVEL_TAG="12.4.1-cudnn-devel-ubuntu22.04"
# RUNTIME image tag er nå HARDKODET i Dockerfile-genereringen som "12.4.1-cudnn-runtime-ubuntu22.04"

# For Model Downloader (MD)
MD_SERVER_BASE_URL="http://192.168.1.29:8081/models/"
MD_PACKAGES_JSON_URL="http://192.168.1.29:8081/packages.json"
MD_DEFAULT_COMFYUI_PATH_FALLBACK="$HOME/comfyui_docker_data"
MD_ADDITIONAL_COMFYUI_PATHS_FALLBACK=("/home/octa/AI/ComfyUI/")

# Dynamisk satte stier
DOCKER_CONFIG_ACTUAL_PATH=""
DOCKER_DATA_ACTUAL_PATH=""
DOCKER_SCRIPTS_ACTUAL_PATH=""

# Stier for modelldownloader
MD_COMFYUI_PATH=""
MD_COMFYUI_BASE_MODELS_PATH=""

# --- Logging Setup ---
# Ensure log directory exists (might run before initialize_docker_paths which also creates BASE_DOCKER_SETUP_DIR)
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
script_log "INFO: Script execution started. Logging to $SCRIPT_LOG_FILE"
script_log "INFO: BASE_DOCKER_SETUP_DIR set to $BASE_DOCKER_SETUP_DIR"
trap 'script_log "INFO: --- Script execution finished with exit status $? ---"' EXIT

# --- Felles Hjelpefunksjoner ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1" >&2; }

press_enter_to_continue() {
    read -r -p "Trykk Enter for å fortsette..." dummy_var_for_read </dev/tty
}

initialize_docker_paths() {
    script_log "DEBUG: ENTERING initialize_docker_paths"
    DOCKER_CONFIG_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$DOCKERFILES_DIR_NAME"
    DOCKER_DATA_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME"
    DOCKER_SCRIPTS_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$SCRIPTS_DIR_NAME"
    script_log "DEBUG: EXITING initialize_docker_paths"
}

ensure_dialog_installed() {
    script_log "DEBUG: ENTERING ensure_dialog_installed"
    if command -v dialog &>/dev/null; then
        script_log "DEBUG: 'dialog' is available."
        script_log "DEBUG: EXITING ensure_dialog_installed (status 0)"
        return 0
    fi

    script_log "WARN: 'dialog' utility not installed." # Changed from log_warn to script_log for consistency
    local install_dialog_choice
    read -r -p "Do you want to attempt to install 'dialog' using 'sudo apt-get install -y dialog'? (ja/nei): " install_dialog_choice </dev/tty
    script_log "INFO: User choice for dialog install: '$install_dialog_choice'"

    if [[ "$install_dialog_choice" =~ ^[Jj][Aa]$ ]]; then
        script_log "INFO: Attempting 'dialog' installation..."
        if sudo apt-get update && sudo apt-get install -y dialog; then
            script_log "SUCCESS: 'dialog' installed successfully." # Changed from log_success
            script_log "DEBUG: EXITING ensure_dialog_installed (status 0)"
            return 0
        else
            script_log "ERROR: Failed to install 'dialog'." # Changed from log_error
            script_log "WARN: Falling back to basic menu." # Changed from log_warn
            script_log "DEBUG: EXITING ensure_dialog_installed (status 1)"
            return 1
        fi
    else
        script_log "INFO: Skipping 'dialog' installation."
        script_log "WARN: Falling back to basic menu." # Changed from log_warn
        script_log "DEBUG: EXITING ensure_dialog_installed (status 1)"
        return 1
    fi
}

# --- Docker Oppsett Funksjoner ---
check_docker_status() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker ser ikke ut til å være installert. Vennligst installer Docker og prøv igjen."
        return 1
    fi
    if ! docker info > /dev/null 2>&1; then
        log_error "Kan ikke koble til Docker daemon. Er Docker startet og kjører?"
        return 1
    fi
    return 0
}

build_comfyui_image() {
    script_log "DEBUG: ENTERING build_comfyui_image"
    initialize_docker_paths
    if [[ ! -f "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile" ]]; then
        log_error "Dockerfile ikke funnet i $DOCKER_CONFIG_ACTUAL_PATH. Kjør installasjon (valg 1) først."
        return 1
    fi

    log_info "Starter bygging av Docker-image '$COMFYUI_IMAGE_NAME'..."

    local clean_devel_tag
    clean_devel_tag=$(echo -n "$DOCKER_CUDA_DEVEL_TAG" | tr -d '\r\t' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    log_info "DEBUG FØR BUILD (Original DEVEL): DOCKER_CUDA_DEVEL_TAG er satt til: [$DOCKER_CUDA_DEVEL_TAG]"
    log_info "DEBUG FØR BUILD (Renset DEVEL): clean_devel_tag er satt til: [$clean_devel_tag]"
    log_info "Bruker devel tag (via build-arg): $clean_devel_tag"
    log_info "Runtime tag er hardkodet i Dockerfile som: 12.4.1-cudnn-runtime-ubuntu22.04"
    log_info "Dette kan ta en stund."

    local build_arg_devel_str
    build_arg_devel_str=$(printf '%s=%s' "PASSED_CUDA_DEVEL_TAG" "$clean_devel_tag")

    local DOCKER_BUILD_LOG_FILE
    DOCKER_BUILD_LOG_FILE="${DOCKER_CONFIG_ACTUAL_PATH}/docker_build_$(date +%Y%m%d_%H%M%S).log"
    log_info "Docker build output will be logged to: ${DOCKER_BUILD_LOG_FILE}"

    # Execute docker build and tee output to log file and screen
    docker build -t "$COMFYUI_IMAGE_NAME" \
        --build-arg "$build_arg_devel_str" \
        "$DOCKER_CONFIG_ACTUAL_PATH" 2>&1 | tee "${DOCKER_BUILD_LOG_FILE}"

    # Check the exit status of 'docker build' (the first command in the pipe)
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_success "Docker-image '$COMFYUI_IMAGE_NAME' bygget/oppdatert vellykket. Full log: ${DOCKER_BUILD_LOG_FILE}"
        return 0
    else
        log_error "Bygging av Docker-image mislyktes. Sjekk loggfilen for detaljer: ${DOCKER_BUILD_LOG_FILE}"
        log_error "FEIL UNDER DOCKER BUILD. TRYKK ENTER FOR Å GÅ TILBAKE TIL MENY."
        press_enter_to_continue
        script_log "DEBUG: EXITING build_comfyui_image (Dockerfile not found or build failed)"
        return 1
    fi
    script_log "DEBUG: EXITING build_comfyui_image"
}

perform_docker_initial_setup() {
    script_log "DEBUG: ENTERING perform_docker_initial_setup"
    set -e 
    if ! check_docker_status; then
        script_log "DEBUG: EXITING perform_docker_initial_setup (Docker status check failed)"
        return 1;
    fi
    initialize_docker_paths

    log_info "Starter førstegangs oppsett for ComfyUI i Docker..."

    if [ -d "$BASE_DOCKER_SETUP_DIR" ]; then
        log_warn "Mappen '$BASE_DOCKER_SETUP_DIR' eksisterer allerede."
        read -r -p "Vil du fortsette og potensielt overskrive konfigurasjonsfiler? (ja/nei): " overwrite_choice </dev/tty
        if [[ ! "$overwrite_choice" =~ ^[Jj][Aa]$ ]]; then
            log_info "Oppsett avbrutt av bruker."
            set +e
            return 1
        fi
    fi

    num_gpus=0
    while true; do
        read -r -p "Hvor mange GPUer vil du sette opp ComfyUI for? (f.eks. 1 eller 2): " num_gpus_input </dev/tty
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
    printf 'RUN %s\n' 'sed -i "s/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/de.archive.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && sed -i "s/http:\/\/security.ubuntu.com\/ubuntu\//http:\/\/de.security.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && apt-get update && apt-get install -y --no-install-recommends git python3-pip python3-venv ffmpeg curl && rm -rf /var/lib/apt/lists/*'
    printf 'RUN %s\n' 'python3 -m venv /opt/venv'
    printf 'ENV PATH="/opt/venv/bin:%s"\n' '$PATH' 
    printf 'WORKDIR %s\n' '/app'
    printf 'RUN %s\n' 'git clone https://github.com/comfyanonymous/ComfyUI.git'
    printf 'WORKDIR %s\n' '/app/ComfyUI'
    printf 'RUN %s\n' 'pip install --no-cache-dir -r requirements.txt'
    printf '\n'
    printf '%s\n' '# Stage 2: Runtime'
    # ARG for PASSED_CUDA_RUNTIME_TAG er fjernet. Taggen hardkodes i neste linje.
    printf 'FROM nvcr.io/nvidia/cuda:%s AS runtime\n' "12.4.1-cudnn-runtime-ubuntu22.04" # HARDKODET RUNTIME TAG
    printf '\n'
    printf 'ENV %s\n' 'DEBIAN_FRONTEND=noninteractive'
    printf 'RUN %s\n' 'sed -i "s/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/de.archive.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && sed -i "s/http:\/\/security.ubuntu.com\/ubuntu\//http:\/\/de.security.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && apt-get update && apt-get install -y --no-install-recommends python3-pip ffmpeg curl libgl1 && rm -rf /var/lib/apt/lists/*'
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
        set +e
        return 1
    fi

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    # ... (resten av start_comfyui.sh genereringen er uendret) ...
    echo "set -e" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    for i in $(seq 0 $((num_gpus - 1))); do
        container_name="comfyui-gpu${i}"
        host_port=$((8188 + i))
        echo "echo \"Starter ComfyUI for GPU $i (Container: $container_name) på port $host_port...\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "docker run -d --name \"$container_name\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  --gpus '\"device=$i\"' \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -p \"${host_port}:8188\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/models:/app/ComfyUI/models\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/custom_nodes:/app/ComfyUI/custom_nodes\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/input:/app/ComfyUI/input\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/output:/app/ComfyUI/output\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/gpu${i}/temp:/app/ComfyUI/temp\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/huggingface:/cache/huggingface\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/torch:/cache/torch\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  -v \"$DOCKER_DATA_ACTUAL_PATH/cache/gpu${i}/whisperx:/cache/whisperx\" \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  --network host \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  --restart unless-stopped \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  \"$COMFYUI_IMAGE_NAME\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "echo \"ComfyUI for GPU $i (Container: $container_name) er tilgjengelig på http://localhost:${host_port}\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    done
    chmod +x "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    log_success "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh generert."

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    # ... (resten av stop_comfyui.sh genereringen er uendret) ...
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
    # ... (resten av oppsummeringen er uendret) ...
    log_info "ComfyUI Docker-oppsett er konfigurert i: $BASE_DOCKER_SETUP_DIR"
    log_info "Viktige stier:"
    echo "  - Docker konfig: $DOCKER_CONFIG_ACTUAL_PATH"
    echo "  - Data (modeller, custom_nodes etc.): $DOCKER_DATA_ACTUAL_PATH"
    echo "  - Start/stopp skript: $DOCKER_SCRIPTS_ACTUAL_PATH"
    log_warn "HUSK: Legg modeller i '$DOCKER_DATA_ACTUAL_PATH/models' og custom nodes i '$DOCKER_DATA_ACTUAL_PATH/custom_nodes'."
    
    # Ensure error checking is not causing premature exit for the prompts below
    set +e 

    # Call to install ComfyUI-Manager on host
    install_comfyui_manager_on_host

    read -r -p "Vil du starte ComfyUI container(e) nå? (ja/nei): " start_now_choice </dev/tty
    if [[ "$start_now_choice" =~ ^[Jj][Aa]$ ]]; then
        if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
            "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        else
            log_error "Startskript ikke funnet."
        fi
    fi
    read -r -p "Vil du gå til modelldenedlastingsverktøyet nå? (ja/nei): " model_download_choice </dev/tty
    if [[ "$model_download_choice" =~ ^[Jj][Aa]$ ]]; then
        run_model_downloader "$DOCKER_DATA_ACTUAL_PATH" 
    fi
    script_log "DEBUG: EXITING perform_docker_initial_setup"
}

install_comfyui_manager_on_host() {
    script_log "DEBUG: ENTERING install_comfyui_manager_on_host"
    if [ -z "$DOCKER_DATA_ACTUAL_PATH" ]; then
        initialize_docker_paths
    fi

    local target_custom_nodes_dir="${DOCKER_DATA_ACTUAL_PATH}/custom_nodes"
    local manager_dir="${target_custom_nodes_dir}/ComfyUI-Manager"

    log_info "Checking ComfyUI-Manager installation in host directory: $manager_dir"

    if [ -d "$manager_dir" ]; then
        read -r -p "ComfyUI-Manager already exists at $manager_dir. Reinstall? (ja/nei): " reinstall_choice </dev/tty
        if [[ "$reinstall_choice" =~ ^[Jj][Aa]$ ]]; then
            log_info "Removing existing ComfyUI-Manager for reinstall..."
            if ! rm -rf "$manager_dir"; then
                log_error "Failed to remove existing ComfyUI-Manager directory. Please check permissions."
                return 1
            fi
            log_success "Existing ComfyUI-Manager removed."
        else
            log_info "Skipping ComfyUI-Manager installation."
            # Display warning messages even if skipping re-installation but it exists
            log_warn "IMPORTANT: ComfyUI-Manager is present at $manager_dir."
            log_warn "Its Python dependencies may need to be installed *inside the running Docker container's environment*."
            log_warn "After starting ComfyUI, you might need to run a command like:"
            log_warn "  docker exec -it <your_container_name> pip install -r /app/ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt"
            log_warn "Replace <your_container_name> with the actual name of your running ComfyUI container (e.g., comfyui-gpu0)."
            return 0
        fi
    fi

    # Proceed to clone if it doesn't exist or was just removed
    if ! mkdir -p "$target_custom_nodes_dir"; then
        log_error "Failed to create target directory $target_custom_nodes_dir. Please check permissions."
        return 1
    fi

    # Check for git installation
    if ! command -v git &> /dev/null; then
        log_warn "git not found. Attempting to install..."
        if sudo apt update && sudo apt install -y git; then
            log_success "git installed successfully."
            if ! command -v git &> /dev/null; then
                log_error "git installation was reported as successful, but 'git' command is still not found. Please install git manually and try again."
                return 1
            fi
        else
            log_error "Failed to install git. Please install git manually and try again."
            return 1
        fi
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
        return 1
    fi
    script_log "DEBUG: EXITING install_comfyui_manager_on_host"
    return 0
}

# --- Model Downloader Funksjoner ---
# (Denne delen er den utpakkede, mer lesbare versjonen fra forrige korreksjon)
md_check_jq() {
    if ! command -v jq &> /dev/null; then
        log_error "'jq' er ikke funnet. Dette kreves for modelldenedlasting."
        log_error "Installer med: sudo apt update && sudo apt install jq"
        return 1
    fi
    return 0
}

md_find_and_select_comfyui_path() {
    local pre_selected_path_base="$1" 
    local found_paths=()
    log_info "Søker etter ComfyUI-installasjoner for modelldenedlasting..."

    if [[ -n "$pre_selected_path_base" ]] && [[ -d "$pre_selected_path_base/models" ]]; then
        log_info "Bruker forhåndsvalgt sti fra Docker-oppsett: $pre_selected_path_base"
        MD_COMFYUI_PATH="${pre_selected_path_base%/}"
        MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
        read -r -p "Vil du bruke denne stien ($MD_COMFYUI_PATH) for modeller, eller velge en annen? (Bruk denne/Velg annen) [B]: " use_preselected </dev/tty
        use_preselected=${use_preselected:-B} 
        if [[ "$use_preselected" =~ ^[Vv]$ ]]; then 
            MD_COMFYUI_PATH="" 
            MD_COMFYUI_BASE_MODELS_PATH=""
            log_info "Lar deg velge sti manuelt."
        else
            log_success "Bruker $MD_COMFYUI_PATH for modelldenedlasting."
            return 0 
        fi
    fi

    if [[ -n "$MD_DEFAULT_COMFYUI_PATH_FALLBACK" ]]; then
        local normalized_default_path="${MD_DEFAULT_COMFYUI_PATH_FALLBACK%/}"
        if [[ -d "$normalized_default_path" ]] && [[ -d "$normalized_default_path/models" ]]; then
            if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_default_path"; then
                found_paths+=("$normalized_default_path")
            fi
        fi
    fi

    for additional_path_candidate in "${MD_ADDITIONAL_COMFYUI_PATHS_FALLBACK[@]}"; do
        if [[ -n "$additional_path_candidate" ]]; then
            local normalized_additional_path="${additional_path_candidate%/}"
            if [[ -d "$normalized_additional_path" ]] && [[ -d "$normalized_additional_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_additional_path"; then
                     found_paths+=("$normalized_additional_path")
                fi
            fi
        fi
    done

    local search_locations=("$HOME" "/mnt" "/opt" "/srv")
    for loc in "${search_locations[@]}"; do
        mapfile -t -d $'\0' current_finds < <(find "$loc" -maxdepth 4 -type d \( -name "ComfyUI" -o -name "comfyui_data" -o -name "comfyui_unified_setup" \) -print0 2>/dev/null)
        for path_found in "${current_finds[@]}"; do
            local normalized_path="${path_found%/}"
            if [[ -d "$normalized_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            elif [[ "$normalized_path" == "$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME" ]] && [[ -d "$normalized_path/models" ]]; then
                 if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path") 
                fi
            fi
        done
    done

    if [ ${#found_paths[@]} -eq 0 ]; then
        log_warn "Ingen ComfyUI-stier funnet automatisk."
    else
        log_info "Følgende potensielle ComfyUI data-stier ble funnet (de må inneholde en 'models'-undermappe):"
        for i in "${!found_paths[@]}"; do echo "  $((i+1))) ${found_paths[$i]}"; done
        echo "  $((${#found_paths[@]}+1))) Angi sti manuelt"
        local choice_val
        while true; do
            local default_choice_prompt_val="1"; if [ ${#found_paths[@]} -eq 0 ]; then default_choice_prompt_val="$((${#found_paths[@]}+1))"; fi
            read -r -p "Velg en sti (1-$((${#found_paths[@]}+1))), Enter for $default_choice_prompt_val): " choice_val </dev/tty
            choice_val="${choice_val:-$default_choice_prompt_val}"
            if [[ "$choice_val" =~ ^[0-9]+$ ]] && [ "$choice_val" -ge 1 ] && [ "$choice_val" -le $((${#found_paths[@]}+1)) ]; then break; else log_warn "Ugyldig valg."; fi
        done
        if [ "$choice_val" -le ${#found_paths[@]} ]; then MD_COMFYUI_PATH="${found_paths[$((choice_val-1))]}"; fi
    fi

    while [[ -z "$MD_COMFYUI_PATH" ]]; do 
        read -r -e -p "Oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " manual_path </dev/tty
        manual_path="${manual_path%/}" 
        if [[ -d "$manual_path" ]] && [[ -d "$manual_path/models" ]]; then
            MD_COMFYUI_PATH="$manual_path"
        else
            log_error "Stien '$manual_path' er ugyldig eller mangler 'models'-undermappe. Prøv igjen."
        fi
    done

    MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models" 
    if [ ! -d "$MD_COMFYUI_BASE_MODELS_PATH" ]; then 
        log_error "FEIL: Mappen '$MD_COMFYUI_BASE_MODELS_PATH' ble ikke funnet etter stivalg!"
        return 1
    fi
    log_success "Bruker '$MD_COMFYUI_BASE_MODELS_PATH' for modeller."; return 0
}

md_get_links_from_url() {
    local url="$1"; curl --connect-timeout 5 -s -L -f "$url" 2>/dev/null | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '^$' | grep -E -v '(\.\.\/|Parent Directory|^\?|^\.|apache\.org|速度|名称|修改日期|大小)' || echo "";
}

md_download_file() {
    local source_url="$1"; local target_path="$2"; local target_dir; target_dir=$(dirname "$target_path"); local target_filename; target_filename=$(basename "$target_path");
    log_info "Forbereder nedlasting av '$target_filename' fra $source_url til $target_path";
    if [ ! -d "$target_dir" ]; then
      log_warn "Målmappen '$target_dir' eksisterer ikke. Oppretter den...";
      if ! mkdir -p "$target_dir"; then log_error "Kunne ikke opprette mappen '$target_dir'. Hopper over."; return 1; fi;
    fi;
    if wget -c -O "$target_path" "$source_url" -q --show-progress --progress=bar:force 2>&1; then
      log_success "Nedlasting av '$target_filename' fullført!";
      if [ -f "$target_path" ]; then local filesize; filesize=$(stat -c%s "$target_path"); if [ "$filesize" -lt 10000 ]; then log_warn "Filen '$target_filename' er liten ($filesize bytes)."; fi; fi;
      return 0;
    else log_error "Nedlasting av '$target_filename' mislyktes."; rm -f "$target_path"; return 1; fi;
}

md_handle_package_download() {
    clear; echo "--- Last ned Modellpakke ---"; log_info "Henter pakkedefinisjoner fra $MD_PACKAGES_JSON_URL...";
    local packages_json; packages_json=$(curl --connect-timeout 10 -s -L -f "$MD_PACKAGES_JSON_URL"); local curl_exit_code=$?;
    if [ $curl_exit_code -ne 0 ]; then log_error "Kunne ikke hente pakkedefinisjoner."; press_enter_to_continue; return 1; fi;
    if ! echo "$packages_json" | jq -e . > /dev/null 2>&1; then log_error "Pakkedefinisjonsfil er ikke gyldig JSON."; press_enter_to_continue; return 1; fi;
    mapfile -t package_display_names < <(echo "$packages_json" | jq -r '.packages[].displayName');
    if [ ${#package_display_names[@]} -eq 0 ]; then log_warn "Ingen modellpakker funnet."; press_enter_to_continue; return 0; fi;
    echo "Tilgjengelige modellpakker:"; for i in "${!package_display_names[@]}"; do echo "  $((i+1))) ${package_display_names[$i]}"; done; echo "  $((${#package_display_names[@]}+1))) Tilbake";
    local package_choice_idx;
    while true; do read -r -p "Velg en pakke (1-$((${#package_display_names[@]}+1))): " package_choice_idx </dev/tty; if [[ "$package_choice_idx" =~ ^[0-9]+$ && "$package_choice_idx" -ge 1 && "$package_choice_idx" -le $((${#package_display_names[@]}+1)) ]]; then break; else log_warn "Ugyldig valg."; fi; done;
    if [ "$package_choice_idx" -eq $((${#package_display_names[@]}+1)) ]; then return 0; fi;
    local selected_package_index=$((package_choice_idx - 1)); local selected_package_display_name="${package_display_names[$selected_package_index]}";
    mapfile -t package_files_to_download < <(echo "$packages_json" | jq -r --argjson idx "$selected_package_index" '.packages[$idx].files[]');
    if [ ${#package_files_to_download[@]} -eq 0 ]; then log_warn "Ingen filer definert for pakken '$selected_package_display_name'."; press_enter_to_continue; return 0; fi;
    log_info "Laster ned pakke: $selected_package_display_name"; echo "Filer:"; for file_rel_path in "${package_files_to_download[@]}"; do echo "  - $file_rel_path"; done;
    read -r -p "Fortsett? (ja/nei): " confirm_download </dev/tty; if [[ ! "$confirm_download" =~ ^[Jj][Aa]$ ]]; then log_info "Avbrutt."; press_enter_to_continue; return 0; fi;
    local dl_c=0 skip_c=0 fail_c=0;
    for file_relative_path in "${package_files_to_download[@]}"; do
        local source_url="${MD_SERVER_BASE_URL}${file_relative_path}"; local target_path_locally="${MD_COMFYUI_BASE_MODELS_PATH}/${file_relative_path}";
        local target_filename; target_filename=$(basename "$file_relative_path");
        if [ -f "$target_path_locally" ]; then
            log_warn "Filen '$target_filename' finnes."; local overwrite_choice_pkg; read -r -p "Overskriv? (ja/Nei): " overwrite_choice_pkg </dev/tty; overwrite_choice_pkg=${overwrite_choice_pkg:-N};
            if [[ ! "$overwrite_choice_pkg" =~ ^[Jj][Aa]$ ]]; then log_info "Skipper '$target_filename'."; skip_c=$((skip_c+1)); continue; fi;
        fi;
        if md_download_file "$source_url" "$target_path_locally"; then dl_c=$((dl_c+1)); else fail_c=$((fail_c+1)); fi;
    done;
    echo ""; log_success "Pakke '$selected_package_display_name' ferdig.";
    if [ "$dl_c" -gt 0 ]; then log_info "$dl_c fil(er) lastet ned."; fi; if [ "$skip_c" -gt 0 ]; then log_info "$skip_c fil(er) hoppet over."; fi; if [ "$fail_c" -gt 0 ]; then log_warn "$fail_c fil(er) feilet."; fi;
    press_enter_to_continue;
}

run_model_downloader() {
    local preselected_path_for_data_dir="$1" 
    if ! md_check_jq; then press_enter_to_continue; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then log_error "Kan ikke sette ComfyUI models-sti."; press_enter_to_continue; return 1; fi
    local md_choice_val;
    while true; do
        clear; echo "--- Modelldenedlastingsverktøy ---"; echo "Bruker models-mappe: $MD_COMFYUI_BASE_MODELS_PATH"; echo "Modellserver: $MD_SERVER_BASE_URL"; echo "----------------------------------";
        echo "1) Utforsk mapper og last ned enkeltfiler"; echo "2) Last ned alle manglende modeller"; echo "3) Last ned forhåndsdefinert pakke"; echo "4) Bytt ComfyUI models-mappe"; echo "5) Tilbake til hovedmeny";
        read -r -p "Velg (1-5): " md_choice_val </dev/tty;
        case "$md_choice_val" in
            1) local map_choice_val; while true; do clear; echo "--- Utforsker mapper på $MD_SERVER_BASE_URL ---"; local map_links_output_val; map_links_output_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL"); local map_links_val; map_links_val=$(echo "$map_links_output_val" | grep '/$');
                if [ -z "$map_links_val" ]; then log_warn "Fant ingen undermapper."; sleep 1; break; fi;
                local map_array_val=(); while IFS= read -r line; do map_array_val+=("$line"); done <<< "$map_links_val"; local num_maps_val=${#map_array_val[@]};
                echo "Tilgjengelige mapper:"; for i in "${!map_array_val[@]}"; do echo "  $((i+1))) ${map_array_val[$i]}"; done; echo "  $((num_maps_val+1))) Tilbake";
                while true; do read -r -p "Velg mappe (1-$((num_maps_val+1))): " map_choice_val </dev/tty; if [[ "$map_choice_val" =~ ^[0-9]+$ && "$map_choice_val" -ge 1 && "$map_choice_val" -le "$((num_maps_val+1))" ]]; then break; else log_warn "Ugyldig."; fi; done;
                if [ "$map_choice_val" -eq "$((num_maps_val+1))" ]; then break; fi;
                local selected_server_subdir_val="${map_array_val[$((map_choice_val-1))]}"; local file_choice_val;
                while true; do clear; local current_server_dir_url_val="${MD_SERVER_BASE_URL}${selected_server_subdir_val}"; echo "--- Filer i: $current_server_dir_url_val ---"; local file_links_output_val; file_links_output_val=$(md_get_links_from_url "$current_server_dir_url_val"); local file_links_f_val; file_links_f_val=$(echo "$file_links_output_val" | grep -v '/$');
                    local file_array_f_val=(); if [ -n "$file_links_f_val" ]; then while IFS= read -r line; do file_array_f_val+=("$line"); done <<< "$file_links_f_val"; fi; local num_files_val=${#file_array_f_val[@]};
                    if [ $num_files_val -eq 0 ]; then log_warn "Ingen filer i '$selected_server_subdir_val'."; else echo "Filer:"; for i in "${!file_array_f_val[@]}"; do echo "  $((i+1))) ${file_array_f_val[$i]}"; done; fi; echo "  $((num_files_val+1))) Tilbake";
                    while true; do read -r -p "Velg fil (1-$((num_files_val+1))): " file_choice_val </dev/tty; if [[ "$file_choice_val" =~ ^[0-9]+$ && "$file_choice_val" -ge 1 && "$file_choice_val" -le "$((num_files_val+1))" ]]; then break; else log_warn "Ugyldig."; fi; done;
                    if [ "$file_choice_val" -eq "$((num_files_val+1))" ]; then break; fi;
                    local selected_filename_val="${file_array_f_val[$((file_choice_val-1))]}"; local source_url_f_val="$current_server_dir_url_val$selected_filename_val"; local target_path_f_val="$MD_COMFYUI_BASE_MODELS_PATH/$selected_server_subdir_val$selected_filename_val";
                    if [ -f "$target_path_f_val" ]; then
                        log_warn "Fil '$selected_filename_val' finnes."; local ovw_f; read -r -p "Overskriv? (j/n): " ovw_f </dev/tty;
                        if [[ ! "$ovw_f" =~ ^[Jj]$ ]]; then log_info "Skipper."; local another_f_same_dir; read -r -p "Annen fil fra '$selected_server_subdir_val'? (J/n): " another_f_same_dir </dev/tty; another_f_same_dir=${another_f_same_dir:-j}; if [[ "$another_f_same_dir" =~ ^[Nn]$ ]]; then break; fi; continue; fi;
                    fi;
                    md_download_file "$source_url_f_val" "$target_path_f_val";
                    local another_f_val; read -r -p "Annen fil fra '$selected_server_subdir_val'? (J/n): " another_f_val </dev/tty; another_f_val=${another_f_val:-j}; if [[ "$another_f_val" =~ ^[Nn]$ ]]; then break; fi;
                done;
                local another_m_val; read -r -p "Annen mappe? (J/n): " another_m_val </dev/tty; another_m_val=${another_m_val:-j}; if [[ "$another_m_val" =~ ^[Nn]$ ]]; then break; fi;
            done ;;
            2) clear; echo "--- Last ned alle manglende ---"; read -r -p "Sikker på at du vil laste ned alle? (j/n): " confirm_all_val </dev/tty;
                if [[ ! "$confirm_all_val" =~ ^[Jj]$ ]]; then log_info "Avbrutt."; press_enter_to_continue; continue; fi;
                local map_links_all_o_val; map_links_all_o_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL"); local map_links_all_val; map_links_all_val=$(echo "$map_links_all_o_val" | grep '/$');
                if [ -z "$map_links_all_val" ]; then log_warn "Fant ingen undermapper."; else
                    local map_array_all_val=(); while IFS= read -r line; do map_array_all_val+=("$line"); done <<< "$map_links_all_val";
                    for cur_subdir_all_val in "${map_array_all_val[@]}"; do
                        echo ""; log_info "Sjekker mappe: $cur_subdir_all_val"; local cur_srv_dir_all_val="${MD_SERVER_BASE_URL}${cur_subdir_all_val}";
                        local file_links_o_all_f; file_links_o_all_f=$(md_get_links_from_url "$cur_srv_dir_all_val"); local file_links_all_f; file_links_all_f=$(echo "$file_links_o_all_f" | grep -v '/$');
                        if [ -z "$file_links_all_f" ]; then log_info "  Ingen filer i denne mappen."; continue; fi;
                        local file_arr_dl_all=(); while IFS= read -r line; do file_arr_dl_all+=("$line"); done <<< "$file_links_all_f";
                        for cur_fname_all_val in "${file_arr_dl_all[@]}"; do
                            local target_path_all_val="$MD_COMFYUI_BASE_MODELS_PATH/$cur_subdir_all_val$cur_fname_all_val"; local source_url_all_val="$cur_srv_dir_all_val$cur_fname_all_val";
                            if [ -f "$target_path_all_val" ]; then echo "  Skipper: '$cur_fname_all_val' finnes."; else md_download_file "$source_url_all_val" "$target_path_all_val"; fi;
                        done;
                    done; log_success "Automatisk nedlasting fullført.";
                fi; press_enter_to_continue ;;
            3) md_handle_package_download ;;
            4) MD_COMFYUI_PATH=""; MD_COMFYUI_BASE_MODELS_PATH=""; if ! md_find_and_select_comfyui_path ""; then log_error "Kunne ikke sette ny sti."; fi; press_enter_to_continue ;;
            5) break ;;
            *) log_warn "Ugyldig valg." ;;
        esac
    done
}

# --- Hovedmeny Funksjon ---
main_menu() {
    initialize_docker_paths 

    ensure_dialog_installed # Call the function to check/install dialog
    local dialog_available=$? # Store its return status
    script_log "DEBUG: ensure_dialog_installed returned: $dialog_available"

    local main_choice

    while true; do
        script_log "DEBUG: main_menu loop iteration started. dialog_available=$dialog_available"
        if [ "$dialog_available" -eq 0 ]; then
            script_log "DEBUG: Calling dialog command..."
            # Use dialog for menu
            # Redirect stderr to a temporary file to check dialog's exit status properly
            # as dialog itself writes selection to stderr if --stdout is not used.
            # With --stdout, selection goes to stdout. Exit status $? indicates cancel.
            main_choice=$(dialog --clear --stdout \
                --title "ComfyUI Unified Tool (v4)" \
                --ok-label "Select" \
                --cancel-label "Exit" \
                --menu "Base Dir: $BASE_DOCKER_SETUP_DIR
Image: $COMFYUI_IMAGE_NAME

Choose an option:" \
                20 76 6 \
                "1" "Førstegangs oppsett/Installer ComfyUI i Docker" \
                "2" "Bygg/Oppdater ComfyUI Docker Image" \
                "3" "Last ned/Administrer Modeller" \
                "4" "Start ComfyUI Docker Container(e)" \
                "5" "Stopp ComfyUI Docker Container(e)" \
                "6" "Avslutt" \
                2>/dev/tty) # Added redirection here

            local dialog_exit_status=$?
            script_log "DEBUG: dialog command finished. main_choice='$main_choice', dialog_exit_status='$dialog_exit_status'"
            if [ $dialog_exit_status -ne 0 ]; then # User pressed Esc or "Exit"
                main_choice="6"
                script_log "DEBUG: Dialog cancelled or Exit selected, main_choice set to 6."
            fi
        else
            script_log "DEBUG: Using basic menu fallback."
            # Fallback to basic menu
            clear # Clear screen for the basic menu
            echo "--- ComfyUI Unified Tool (v4) ---"
            echo "Primær oppsettsmappe: $BASE_DOCKER_SETUP_DIR"
            echo "Docker image navn: $COMFYUI_IMAGE_NAME"
            echo "--------------------------------"
            echo " (Dialog utility not found or install declined, using basic menu)"
            echo "1) Førstegangs oppsett/Installer ComfyUI i Docker"
            echo "2) Bygg/Oppdater ComfyUI Docker Image"
            echo "3) Last ned/Administrer Modeller"
            echo "4) Start ComfyUI Docker Container(e)"
            echo "5) Stopp ComfyUI Docker Container(e)"
            echo "6) Avslutt"
            echo "--------------------------------"
            read -r -p "Velg et alternativ (1-6): " main_choice </dev/tty
            script_log "DEBUG: Basic menu read finished. main_choice='$main_choice'"
        fi

        script_log "DEBUG: main_menu case: main_choice='$main_choice'"
        set +e 
        case "$main_choice" in
            "1")
                perform_docker_initial_setup
                press_enter_to_continue
                ;;
            "2")
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                build_comfyui_image
                press_enter_to_continue
                ;;
            "3")
                # Ensure DOCKER_DATA_ACTUAL_PATH is set if this menu is somehow reached before Option 1
                if [ -z "$DOCKER_DATA_ACTUAL_PATH" ]; then initialize_docker_paths; fi
                if [[ -d "$DOCKER_DATA_ACTUAL_PATH/models" ]]; then
                    run_model_downloader "$DOCKER_DATA_ACTUAL_PATH"
                else
                    log_info "Docker data sti ikke funnet ($DOCKER_DATA_ACTUAL_PATH/models)."
                    log_info "Lar deg velge sti for modelldenedlasting manuelt."
                    run_model_downloader ""
                fi
                press_enter_to_continue
                ;;
            "4")
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                # Ensure DOCKER_SCRIPTS_ACTUAL_PATH is set
                if [ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]; then initialize_docker_paths; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
                else
                    log_warn "Startskript ikke funnet. Kjør installasjon (valg 1) først."
                fi
                press_enter_to_continue
                ;;
            "5")
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                # Ensure DOCKER_SCRIPTS_ACTUAL_PATH is set
                if [ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]; then initialize_docker_paths; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh" ]]; then
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
                else
                    log_warn "Stoppskript ikke funnet."
                fi
                press_enter_to_continue
                ;;
            "6")
                script_log "DEBUG: main_menu attempting to exit (Option 6)."
                log_info "Avslutter."
                clear # Clear screen on exit
                exit 0
                ;;
            *) # Invalid choice
                if [ "$dialog_available" -eq 0 ]; then
                    dialog --title "Ugyldig valg" --msgbox "Vennligst velg et gyldig alternativ fra menyen." 6 50
                else
                    log_warn "Ugyldig valg. Skriv inn et tall fra 1-6."
                fi
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Skriptets startpunkt ---
# clear # Comment out clear for now to see any echos before this.
script_log "DEBUG: --- Skriptets startpunkt (before initial clear and log_info) ---"
log_info "Starter ComfyUI Unified Tool (v4)..." # Lagt til v4 her

script_log "DEBUG: About to call main_menu."
main_menu
script_log "DEBUG: main_menu call finished (script should have exited from within main_menu)."
