#!/bin/bash
# Kombinert skript for ComfyUI Docker Oppsett og Modelldenedlasting

# --- Globale Innstillinger og Konstanter ---
# Avslutt ved feil i kritiske deler (kan overstyres lokalt i funksjoner)
# set -e

# Farger for logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# For Docker-oppsett
BASE_DOCKER_SETUP_DIR="$HOME/comfyui_unified_setup"
DOCKERFILES_DIR_NAME="docker_config"
COMFYUI_DATA_DIR_NAME="comfyui_data"
SCRIPTS_DIR_NAME="scripts"
COMFYUI_IMAGE_NAME="comfyui-app"

# Definer de komplette image tag-delene her for klarhet
# DU MÅ VERIFISERE DENNE RUNTIME-TAGGEN PÅ NVIDIA NGC!
DOCKER_CUDA_DEVEL_TAG="12.4.1-cudnn-devel-ubuntu22.04"
DOCKER_CUDA_RUNTIME_TAG="12.4.1-cudnn-runtime-ubuntu22.04" # <--- VERIFISER DENNE!

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

# --- Felles Hjelpefunksjoner ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_warn() { echo -e "${YELLOW}WARN:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1" >&2; }

press_enter_to_continue() {
    read -r -p "Trykk Enter for å fortsette..." dummy_var_for_read </dev/tty
}

initialize_docker_paths() {
    DOCKER_CONFIG_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$DOCKERFILES_DIR_NAME"
    DOCKER_DATA_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME"
    DOCKER_SCRIPTS_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$SCRIPTS_DIR_NAME"
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
    initialize_docker_paths
    if [[ ! -f "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile" ]]; then
        log_error "Dockerfile ikke funnet i $DOCKER_CONFIG_ACTUAL_PATH. Kjør installasjon (valg 1) først."
        return 1
    fi

    log_info "Starter bygging av Docker-image '$COMFYUI_IMAGE_NAME'..."
    log_info "Bruker devel tag: $DOCKER_CUDA_DEVEL_TAG"
    log_info "Bruker runtime tag: $DOCKER_CUDA_RUNTIME_TAG (VERIFISER AT DENNE ER GYLDIG PÅ NGC!)"
    log_info "Dette kan ta en stund."

    if docker build -t "$COMFYUI_IMAGE_NAME" \
        --build-arg PASSED_CUDA_DEVEL_TAG="$DOCKER_CUDA_DEVEL_TAG" \
        --build-arg PASSED_CUDA_RUNTIME_TAG="$DOCKER_CUDA_RUNTIME_TAG" \
        "$DOCKER_CONFIG_ACTUAL_PATH"; then
        log_success "Docker-image '$COMFYUI_IMAGE_NAME' bygget/oppdatert vellykket."
        return 0
    else
        log_error "Bygging av Docker-image mislyktes."
        return 1
    fi
}

perform_docker_initial_setup() {
    set -e # Avslutt denne funksjonen ved feil
    if ! check_docker_status; then return 1; fi
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

    log_info "Genererer Dockerfile..."
    cat <<EOF > "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile"
# Stage 1: Builder
ARG PASSED_CUDA_DEVEL_TAG 
# FROM nvcr.io/nvidia/cuda:\${PASSED_CUDA_DEVEL_TAG} AS builder # Gammel linje for referanse
FROM nvcr.io/nvidia/cuda:\${PASSED_CUDA_DEVEL_TAG} AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends git python3-pip python3-venv ffmpeg curl && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:\$PATH"
WORKDIR /app
RUN git clone https://github.com/comfyanonymous/ComfyUI.git
WORKDIR /app/ComfyUI
RUN pip install --no-cache-dir -r requirements.txt
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git ./custom_nodes/ComfyUI-Manager
RUN pip install --no-cache-dir -r ./custom_nodes/ComfyUI-Manager/requirements.txt

# Stage 2: Runtime
ARG PASSED_CUDA_RUNTIME_TAG
# FROM nvcr.io/nvidia/cuda:\${PASSED_CUDA_RUNTIME_TAG} AS runtime # Gammel linje for referanse
FROM nvcr.io/nvidia/cuda:\${PASSED_CUDA_RUNTIME_TAG} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip ffmpeg curl libgl1 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app/ComfyUI /app/ComfyUI
WORKDIR /app/ComfyUI
RUN mkdir -p ./models ./input ./output ./temp /cache/huggingface /cache/torch /cache/whisperx
ENV HF_HOME="/cache/huggingface"
ENV TORCH_HOME="/cache/torch"
ENV WHISPERX_CACHE_DIR="/cache/whisperx" # Bekreft denne variabelen for WhisperX
ENV PATH="/opt/venv/bin:\$PATH"
EXPOSE 8188
CMD ["python3", "main.py", "--max-upload-size", "1000", "--listen", "0.0.0.0", "--port", "8188", "--preview-method", "auto"]
EOF
    log_success "Dockerfile generert."

    if ! build_comfyui_image; then
        log_error "Kunne ikke bygge Docker image. Oppsett ufullstendig."
        set +e
        return 1
    fi

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
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
        echo "  --restart unless-stopped \\" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "  \"$COMFYUI_IMAGE_NAME\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        echo "echo \"ComfyUI for GPU $i (Container: $container_name) er tilgjengelig på http://localhost:${host_port}\"" >> "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    done
    chmod +x "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    log_success "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh generert."

    log_info "Genererer $DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh..."
    echo "#!/bin/bash" > "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
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
    
    set +e # Gjenopprett normal feilhåndtering

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
}

# --- Model Downloader Funksjoner ---

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
        if [[ "$use_preselected" =~ ^[Vv]$ ]]; then
            MD_COMFYUI_PATH="" 
            MD_COMFYUI_BASE_MODELS_PATH=""
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
        mapfile -t -d $'\0' current_finds < <(find "$loc" -maxdepth 4 -type d \( -name "ComfyUI" -o -name "comfyui_data" \) -print0 2>/dev/null)
        for path_found in "${current_finds[@]}"; do
            local normalized_path="${path_found%/}"
            if [[ -d "$normalized_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            fi
        done
    done

    if [ ${#found_paths[@]} -eq 0 ]; then
        log_warn "Ingen ComfyUI-stier funnet automatisk."
    else
        log_info "Følgende potensielle ComfyUI-stier ble funnet:"
        for i in "${!found_paths[@]}"; do
            local display_path="${found_paths[$i]}"
            echo "  $((i+1))) ${display_path}"
        done
        echo "  $((${#found_paths[@]}+1))) Angi sti manuelt"

        local choice_val
        while true; do
            local default_choice_prompt_val="1"
             if [ ${#found_paths[@]} -eq 0 ]; then default_choice_prompt_val="$((${#found_paths[@]}+1))"; fi
            read -r -p "Velg en sti for ComfyUI-data (1-$((${#found_paths[@]}+1))), Enter for $default_choice_prompt_val): " choice_val </dev/tty
            choice_val="${choice_val:-$default_choice_prompt_val}"
            if [[ "$choice_val" =~ ^[0-9]+$ ]] && [ "$choice_val" -ge 1 ] && [ "$choice_val" -le $((${#found_paths[@]}+1)) ]; then
                break
            else log_warn "Ugyldig valg."; fi
        done

        if [ "$choice_val" -le ${#found_paths[@]} ]; then
            MD_COMFYUI_PATH="${found_paths[$((choice_val-1))]}"
        fi
    fi

    while [[ -z "$MD_COMFYUI_PATH" ]]; do
        read -r -e -p "Vennligst oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " manual_path </dev/tty
        manual_path="${manual_path%/}" 
        if [[ -d "$manual_path" ]] && [[ -d "$manual_path/models" ]]; then
            MD_COMFYUI_PATH="$manual_path"
        else
            log_error "Stien '$manual_path' er ugyldig eller mangler 'models'-mappe. Prøv igjen."
        fi
    done

    MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
    if [ ! -d "$MD_COMFYUI_BASE_MODELS_PATH" ]; then
        log_error "FEIL: Mappen '$MD_COMFYUI_BASE_MODELS_PATH' ble ikke funnet!"
        return 1
    fi
    log_success "Bruker '$MD_COMFYUI_BASE_MODELS_PATH' for modeller."
    return 0
}

md_get_links_from_url() {
    local url="$1"
    curl --connect-timeout 5 -s -L -f "$url" 2>/dev/null | \
    grep -o '<a href="[^"]*"' | \
    sed 's/<a href="//;s/"//' | \
    grep -v '^$' | \
    grep -E -v '(\.\.\/|Parent Directory|^\?|^\.|apache\.org|速度|名称|修改日期|大小)' || echo "" 
}

md_download_file() {
    local source_url="$1"
    local target_path="$2"
    local target_dir; target_dir=$(dirname "$target_path")
    local target_filename; target_filename=$(basename "$target_path")

    log_info "Forbereder nedlasting av '$target_filename' fra $source_url til $target_path"

    if [ ! -d "$target_dir" ]; then
      log_warn "Målmappen '$target_dir' eksisterer ikke. Oppretter den..."
      if ! mkdir -p "$target_dir"; then
        log_error "Kunne ikke opprette '$target_dir'. Hopper over."
        return 1
      fi
    fi

    if wget -c -O "$target_path" "$source_url" -q --show-progress --progress=bar:force 2>&1; then
      log_success "Nedlasting av '$target_filename' fullført!"
      if [ -f "$target_path" ]; then
         local filesize; filesize=$(stat -c%s "$target_path")
         if [ "$filesize" -lt 10000 ]; then
           log_warn "Filen '$target_filename' er liten ($filesize bytes)."
         fi
      fi
      return 0
    else
      log_error "Nedlasting av '$target_filename' mislyktes."
      rm -f "$target_path" 
      return 1
    fi
}

md_handle_package_download() {
    clear; echo "--- Last ned Modellpakke ---"
    log_info "Henter pakkedefinisjoner fra $MD_PACKAGES_JSON_URL..."
    local packages_json; packages_json=$(curl --connect-timeout 10 -s -L -f "$MD_PACKAGES_JSON_URL")
    if [ $? -ne 0 ]; then
        log_error "Kunne ikke hente pakkedefinisjoner. Sjekk URL og nettverk."; press_enter_to_continue; return 1;
    fi
    if ! echo "$packages_json" | jq -e . > /dev/null 2>&1; then
        log_error "Pakkedefinisjonsfil er ikke gyldig JSON."; press_enter_to_continue; return 1;
    fi
    mapfile -t package_display_names < <(echo "$packages_json" | jq -r '.packages[].displayName')
    if [ ${#package_display_names[@]} -eq 0 ]; then
        log_warn "Ingen pakker funnet."; press_enter_to_continue; return 0;
    fi

    echo "Tilgjengelige modellpakker:"; for i in "${!package_display_names[@]}"; do echo " $((i+1))) ${package_display_names[$i]}"; done
    echo " $((${#package_display_names[@]}+1))) Tilbake"; local choice_idx_pkg
    while true; do
        read -r -p "Velg pakke (1-$((${#package_display_names[@]}+1))): " choice_idx_pkg </dev/tty
        if [[ "$choice_idx_pkg" =~ ^[0-9]+$ ]] && [ "$choice_idx_pkg" -ge 1 ] && [ "$choice_idx_pkg" -le $((${#package_display_names[@]}+1)) ]; then break; else log_warn "Ugyldig."; fi
    done
    if [ "$choice_idx_pkg" -eq $((${#package_display_names[@]}+1)) ]; then return 0; fi
    local selected_pkg_idx_val=$((choice_idx_pkg - 1))
    mapfile -t files_to_dl_pkg < <(echo "$packages_json" | jq -r --argjson idx "$selected_pkg_idx_val" '.packages[$idx].files[]')
    if [ ${#files_to_dl_pkg[@]} -eq 0 ]; then log_warn "Ingen filer for denne pakken."; press_enter_to_continue; return 0; fi

    log_info "Pakke: ${package_display_names[$selected_pkg_idx_val]}"; echo "Filer som lastes ned (hvis de ikke finnes):"
    for file_rel_path_pkg in "${files_to_dl_pkg[@]}"; do echo "  - $file_rel_path_pkg"; done
    read -r -p "Fortsett? (ja/nei): " confirm_dl_pkg </dev/tty; if [[ ! "$confirm_dl_pkg" =~ ^[Jj][Aa]$ ]]; then return 0; fi

    local dl_c_pkg=0 skip_c_pkg=0 fail_c_pkg=0
    for file_rel_path_pkg in "${files_to_dl_pkg[@]}"; do
        local src_url_pkg="${MD_SERVER_BASE_URL}${file_rel_path_pkg}"
        local target_path_pkg="${MD_COMFYUI_BASE_MODELS_PATH}/${file_rel_path_pkg}"
        if [ -f "$target_path_pkg" ]; then
            read -r -p "Filen '$(basename "$file_rel_path_pkg")' finnes. Overskriv? (ja/Nei): " ovrw_pkg_file </dev/tty
            if [[ ! "$ovrw_pkg_file" =~ ^[Jj][Aa]$ ]]; then log_info "Hopper over."; skip_c_pkg=$((skip_c_pkg+1)); continue; fi
        fi
        if md_download_file "$src_url_pkg" "$target_path_pkg"; then dl_c_pkg=$((dl_c_pkg+1)); else fail_c_pkg=$((fail_c_pkg+1)); fi
    done
    log_info "Pakkenedlasting ferdig. Nedlastet: $dl_c_pkg, Hoppet over: $skip_c_pkg, Mislyktes: $fail_c_pkg."
    press_enter_to_continue
}

run_model_downloader() {
    local preselected_path_for_data_dir="$1" 

    if ! md_check_jq; then press_enter_to_continue; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then
        log_error "Kunne ikke bestemme ComfyUI models-sti for nedlasting."
        press_enter_to_continue
        return 1
    fi

    while true; do
        clear
        echo "--- Modelldenedlastingsverktøy ---"
        echo "Bruker ComfyUI models-mappe: $MD_COMFYUI_BASE_MODELS_PATH"
        echo "Modellserver: $MD_SERVER_BASE_URL"
        echo "----------------------------------"
        echo "1) Utforsk mapper og last ned enkeltfiler"
        echo "2) Last ned alle modeller som ikke finnes lokalt"
        echo "3) Last ned forhåndsdefinert modellpakke"
        echo "4) Bytt ComfyUI models-mappe"
        echo "5) Tilbake til hovedmeny"
        local md_choice_val
        read -r -p "Velg et alternativ (1-5): " md_choice_val </dev/tty
        case "$md_choice_val" in
            1) 
                while true; do 
                    clear; echo "--- Utforsker mapper på $MD_SERVER_BASE_URL ---"
                    local map_links_output_val; map_links_output_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                    local map_links_val; map_links_val=$(echo "$map_links_output_val" | grep '/$' )
                    if [ -z "$map_links_val" ]; then log_warn "Fant ingen undermapper."; sleep 2; break; fi
                    local map_array_val=(); while IFS= read -r line; do map_array_val+=("$line"); done <<< "$map_links_val"
                    echo "Tilgjengelige mapper:"; for i in "${!map_array_val[@]}"; do echo "$((i+1))) ${map_array_val[$i]}"; done
                    echo "$((${#map_array_val[@]}+1))) Tilbake"; local map_c_val
                    while true; do read -r -p "Velg mappe (1-$((${#map_array_val[@]}+1))): " map_c_val </dev/tty; if [[ "$map_c_val" =~ ^[0-9]+$ ]] && [ "$map_c_val" -ge 1 ] && [ "$map_c_val" -le $((${#map_array_val[@]}+1)) ]; then break; fi; done
                    if [ "$map_c_val" -eq $((${#map_array_val[@]}+1)) ]; then break; fi
                    local sel_subdir_val="${map_array_val[$((map_c_val-1))]}"

                    while true; do 
                        clear; local current_srv_dir_url_val="${MD_SERVER_BASE_URL}${sel_subdir_val}"
                        echo "--- Filer i $current_srv_dir_url_val ---"
                        local file_links_o_val; file_links_o_val=$(md_get_links_from_url "$current_srv_dir_url_val")
                        local file_links_f_val; file_links_f_val=$(echo "$file_links_o_val" | grep -v '/$' )
                        local file_array_f_val=(); if [ -n "$file_links_f_val" ]; then while IFS= read -r line; do file_array_f_val+=("$line"); done <<< "$file_links_f_val"; fi
                        if [ ${#file_array_f_val[@]} -eq 0 ]; then log_warn "Ingen filer funnet."; else echo "Filer:"; for i in "${!file_array_f_val[@]}"; do echo "$((i+1))) ${file_array_f_val[$i]}"; done; fi
                        echo "$((${#file_array_f_val[@]}+1))) Tilbake"; local file_c_val
                        while true; do read -r -p "Velg fil (1-$((${#file_array_f_val[@]}+1))): " file_c_val </dev/tty; if [[ "$file_c_val" =~ ^[0-9]+$ ]] && [ "$file_c_val" -ge 1 ] && [ "$file_c_val" -le $((${#file_array_f_val[@]}+1)) ]; then break; fi; done
                        if [ "$file_c_val" -eq $((${#file_array_f_val[@]}+1)) ]; then break; fi
                        local sel_fname_val="${file_array_f_val[$((file_c_val-1))]}"
                        local src_url_f_val="$current_srv_dir_url_val$sel_fname_val"
                        local target_path_f_val="$MD_COMFYUI_BASE_MODELS_PATH/$sel_subdir_val$sel_fname_val"
                        if [ -f "$target_path_f_val" ]; then
                           read -r -p "Filen finnes. Overskriv? (ja/nei):" ovrw_f_val </dev/tty; if [[ ! "$ovrw_f_val" =~ ^[Jj][Aa]$ ]]; then log_info "Hopper over."; continue; fi
                        fi
                        md_download_file "$src_url_f_val" "$target_path_f_val"
                        read -r -p "Last ned en annen fil fra '$sel_subdir_val'? (ja/nei) [j]: " another_f_val </dev/tty; another_f_val=${another_f_val:-j}; if [[ "$another_f_val" =~ ^[Nn]$ ]]; then break; fi
                    done
                    read -r -p "Utforske en annen mappe? (ja/nei) [j]: " another_m_val </dev/tty; another_m_val=${another_m_val:-j}; if [[ "$another_m_val" =~ ^[Nn]$ ]]; then break; fi
                done ;;
            2) 
                clear; echo "--- Last ned alle manglende modeller ---"
                read -r -p "Dette kan ta lang tid. Er du sikker? (ja/nei): " confirm_all_val </dev/tty
                if [[ ! "$confirm_all_val" =~ ^[Jj][Aa]$ ]]; then log_info "Avbrutt."; continue; fi
                local map_links_all_o_val; map_links_all_o_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                local map_links_all_val; map_links_all_val=$(echo "$map_links_all_o_val" | grep '/$' )
                if [ -z "$map_links_all_val" ]; then log_warn "Fant ingen undermapper på server."; else
                    local map_arr_all_val=(); while IFS= read -r line; do map_arr_all_val+=("$line"); done <<< "$map_links_all_val"
                    for cur_subdir_all_val in "${map_arr_all_val[@]}"; do
                        log_info "Sjekker mappe: $cur_subdir_all_val"
                        local files_o_all_val; files_o_all_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL$cur_subdir_all_val")
                        local files_f_all_val; files_f_all_val=$(echo "$files_o_all_val" | grep -v '/$' )
                        if [ -z "$files_f_all_val" ]; then log_info " Ingen filer i denne mappen."; continue; fi
                        local files_arr_dl_all_val=(); while IFS= read -r line; do files_arr_dl_all_val+=("$line"); done <<< "$files_f_all_val"
                        for cur_fname_all_val in "${files_arr_dl_all_val[@]}"; do
                            local target_p_all_val="$MD_COMFYUI_BASE_MODELS_PATH/$cur_subdir_all_val$cur_fname_all_val"
                            if [ -f "$target_p_all_val" ]; then echo "  Skipper: '$(basename "$target_p_all_val")' finnes."; else
                                md_download_file "$MD_SERVER_BASE_URL$cur_subdir_all_val$cur_fname_all_val" "$target_p_all_val"
                            fi
                        done
                    done
                fi
                log_success "Nedlasting av alle fullført."; press_enter_to_continue ;;
            3) md_handle_package_download ;;
            4) 
                MD_COMFYUI_PATH="" 
                MD_COMFYUI_BASE_MODELS_PATH=""
                if ! md_find_and_select_comfyui_path ""; then 
                    log_error "Kunne ikke sette ny ComfyUI models-sti."
                fi
                press_enter_to_continue ;;
            5) break ;; 
            *) log_warn "Ugyldig valg." ;;
        esac
    done
}

# --- Hovedmeny Funksjon ---
main_menu() {
    initialize_docker_paths 
    while true; do
        clear
        echo "--- ComfyUI Unified Tool ---"
        echo "Primær oppsettsmappe: $BASE_DOCKER_SETUP_DIR"
        echo "Docker image navn: $COMFYUI_IMAGE_NAME"
        echo "--------------------------------"
        echo "1) Førstegangs oppsett/Installer ComfyUI i Docker"
        echo "2) Bygg/Oppdater ComfyUI Docker Image"
        echo "3) Last ned/Administrer Modeller"
        echo "4) Start ComfyUI Docker Container(e)"
        echo "5) Stopp ComfyUI Docker Container(e)"
        echo "6) Avslutt"
        echo "--------------------------------"
        local main_choice
        read -r -p "Velg et alternativ: " main_choice </dev/tty

        set +e # Tillat feil uten å avslutte hele skriptet i case-blokken

        case "$main_choice" in
            1) perform_docker_initial_setup ;;
            2)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                build_comfyui_image
                press_enter_to_continue
                ;;
            3)
                if [[ -d "$DOCKER_DATA_ACTUAL_PATH/models" ]]; then
                    run_model_downloader "$DOCKER_DATA_ACTUAL_PATH"
                else
                    log_info "Docker data sti ikke funnet ($DOCKER_DATA_ACTUAL_PATH/models)."
                    log_info "Lar deg velge sti for modelldenedlasting manuelt."
                    run_model_downloader 
                fi
                ;;
            4)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
                else
                    log_warn "Startskript '$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh' ikke funnet. Kjør installasjon (valg 1) først."
                fi
                press_enter_to_continue
                ;;
            5)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh" ]]; then
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
                else
                    log_warn "Stoppskript '$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh' ikke funnet."
                fi
                press_enter_to_continue
                ;;
            6) log_info "Avslutter."; exit 0 ;;
            *) log_warn "Ugyldig valg."; press_enter_to_continue ;;
        esac
    done
}

# --- Skriptets startpunkt ---
clear
log_info "Starter ComfyUI Unified Tool..."
main_menu
