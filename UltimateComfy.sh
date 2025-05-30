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
# Dockerfile ARGs (kan justeres her)
CUDA_VERSION_ARG="12.4.1"
CUDNN_TAG_ARG="cudnn8"
UBUNTU_VERSION_ARG="22.04"

# For Model Downloader (MD)
MD_SERVER_BASE_URL="http://192.168.1.29:8081/models/"
MD_PACKAGES_JSON_URL="http://192.168.1.29:8081/packages.json"
MD_DEFAULT_COMFYUI_PATH_FALLBACK="$HOME/comfyui_docker_data" # Fra ditt opprinnelige skript
MD_ADDITIONAL_COMFYUI_PATHS_FALLBACK=("/home/octa/AI/ComfyUI/") # Fra ditt opprinnelige skript

# Dynamisk satte stier (vil bli satt av funksjoner)
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
log_error() { echo -e "${RED}ERROR:${NC} $1" >&2; } # Ikke exit her, la kallende funksjon håndtere

press_enter_to_continue() {
    read -r -p "Trykk Enter for å fortsette..."
}

# Funksjon for å sette globale Docker-stier
initialize_docker_paths() {
    DOCKER_CONFIG_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$DOCKERFILES_DIR_NAME"
    DOCKER_DATA_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME"
    DOCKER_SCRIPTS_ACTUAL_PATH="$BASE_DOCKER_SETUP_DIR/$SCRIPTS_DIR_NAME"
}

# --- Docker Oppsett Funksjoner ---

# Sjekk om Docker er installert og kjører
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

# Funksjon for å bygge Docker-imaget
build_comfyui_image() {
    initialize_docker_paths
    if [[ ! -f "$DOCKER_CONFIG_ACTUAL_PATH/Dockerfile" ]]; then
        log_error "Dockerfile ikke funnet i $DOCKER_CONFIG_ACTUAL_PATH. Kjør installasjon (valg 1) først."
        return 1
    fi

    log_info "Starter bygging av Docker-image '$COMFYUI_IMAGE_NAME'..."
    log_info "Dette kan ta en stund."
    if docker build -t "$COMFYUI_IMAGE_NAME" \
        --build-arg CUDA_VERSION="$CUDA_VERSION_ARG" \
        --build-arg CUDNN_TAG="$CUDNN_TAG_ARG" \
        --build-arg UBUNTU_VERSION="$UBUNTU_VERSION_ARG" \
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
        read -r -p "Vil du fortsette og potensielt overskrive konfigurasjonsfiler? (ja/nei): " overwrite_choice
        if [[ ! "$overwrite_choice" =~ ^[Jj][Aa]$ ]]; then
            log_info "Oppsett avbrutt av bruker."
            set +e
            return 1
        fi
    fi

    num_gpus=0
    while true; do
        read -r -p "Hvor mange GPUer vil du sette opp ComfyUI for? (f.eks. 1 eller 2): " num_gpus_input
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
ARG CUDA_VERSION=${CUDA_VERSION_ARG}
ARG CUDNN_TAG=${CUDNN_TAG_ARG}
ARG UBUNTU_VERSION=${UBUNTU_VERSION_ARG}
FROM nvidia/cuda:\${CUDA_VERSION}-\${CUDNN_TAG}-devel-ubuntu\${UBUNTU_VERSION} AS builder
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
FROM nvidia/cuda:\${CUDA_VERSION}-\${CUDNN_TAG}-runtime-ubuntu\${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends python3-pip ffmpeg curl libgl1 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app/ComfyUI /app/ComfyUI
WORKDIR /app/ComfyUI
RUN mkdir -p ./models ./input ./output ./temp /cache/huggingface /cache/torch /cache/whisperx
ENV HF_HOME="/cache/huggingface"
ENV TORCH_HOME="/cache/torch"
ENV WHISPERX_CACHE_DIR="/cache/whisperx"
ENV PATH="/opt/venv/bin:\$PATH"
EXPOSE 8188
CMD ["python3", "main.py", "--max-upload-size", "1000", "--listen", "0.0.0.0", "--port", "8188", "--preview-method", "auto"]
EOF
    log_success "Dockerfile generert."

    log_info "Genererer .dockerignore..."
    cat <<EOF > "$DOCKER_CONFIG_ACTUAL_PATH/.dockerignore"
.git
.vscode
__pycache__
*.pyc *.pyo *.pyd
venv/
ComfyUI/
models/
input/
output/
custom_nodes/
temp/
*.DS_Store
EOF
    log_success ".dockerignore generert."

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

    read -r -p "Vil du starte ComfyUI container(e) nå? (ja/nei): " start_now_choice
    if [[ "$start_now_choice" =~ ^[Jj][Aa]$ ]]; then
        if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
            "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
        else
            log_error "Startskript ikke funnet."
        fi
    fi

    read -r -p "Vil du gå til modelldenedlastingsverktøyet nå? (ja/nei): " model_download_choice
    if [[ "$model_download_choice" =~ ^[Jj][Aa]$ ]]; then
        run_model_downloader "$DOCKER_DATA_ACTUAL_PATH" # Send med stien til data-mappen
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
    local pre_selected_path_base="$1" # Dette er stien til /comfyui_data, ikke /comfyui_data/models
    local found_paths=()
    log_info "Søker etter ComfyUI-installasjoner for modelldenedlasting..."

    # 0. Hvis en sti er forhåndsvalgt (fra Docker-oppsettet)
    if [[ -n "$pre_selected_path_base" ]] && [[ -d "$pre_selected_path_base/models" ]]; then
        log_info "Bruker forhåndsvalgt sti fra Docker-oppsett: $pre_selected_path_base"
        MD_COMFYUI_PATH="${pre_selected_path_base%/}"
        MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
        # Tilby brukeren å endre hvis de ønsker
        read -r -p "Vil du bruke denne stien ($MD_COMFYUI_PATH) for modeller, eller velge en annen? (Bruk denne/Velg annen) [B]: " use_preselected
        if [[ "$use_preselected" =~ ^[Vv]$ ]]; then
            MD_COMFYUI_PATH="" # Nullstill så vi går inn i manuell valg nedenfor
            MD_COMFYUI_BASE_MODELS_PATH=""
        else
            log_success "Bruker $MD_COMFYUI_PATH for modelldenedlasting."
            return 0 # Ferdig hvis brukeren aksepterer forhåndsvalgt sti
        fi
    fi

    # 1. Sjekk den definerte standardstien først (fallback)
    if [[ -n "$MD_DEFAULT_COMFYUI_PATH_FALLBACK" ]]; then
        local normalized_default_path="${MD_DEFAULT_COMFYUI_PATH_FALLBACK%/}"
        if [[ -d "$normalized_default_path" ]] && [[ -d "$normalized_default_path/models" ]]; then
            if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_default_path"; then
                found_paths+=("$normalized_default_path")
            fi
        fi
    fi

    # 1b. Sjekk ytterligere forhåndsdefinerte stier (fallback)
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

    # 2. Søk i vanlige steder (kan utelates hvis vi stoler på forhåndsdefinerte)
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

        local choice
        while true; do
            local default_choice_prompt="1"
             if [ ${#found_paths[@]} -eq 0 ]; then default_choice_prompt="$((${#found_paths[@]}+1))"; fi
            read -r -p "Velg en sti for ComfyUI-data (1-$((${#found_paths[@]}+1))), Enter for $default_choice_prompt): " choice
            choice="${choice:-$default_choice_prompt}"
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#found_paths[@]}+1)) ]; then
                break
            else log_warn "Ugyldig valg."; fi
        done

        if [ "$choice" -le ${#found_paths[@]} ]; then
            MD_COMFYUI_PATH="${found_paths[$((choice-1))]}"
        fi
    fi

    while [[ -z "$MD_COMFYUI_PATH" ]]; do
        read -r -e -p "Vennligst oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " manual_path
        manual_path="${manual_path%/}" # Fjern trailing slash
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
    grep -E -v '(\.\.\/|Parent Directory|^\?|^\.|apache\.org|速度|名称|修改日期|大小)' || echo "" # Returner tom streng ved feil
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
      # Liten filstørrelsesjekk
      if [ -f "$target_path" ]; then
         local filesize; filesize=$(stat -c%s "$target_path")
         if [ "$filesize" -lt 10000 ]; then
           log_warn "Filen '$target_filename' er liten ($filesize bytes)."
         fi
      fi
      return 0
    else
      log_error "Nedlasting av '$target_filename' mislyktes."
      rm -f "$target_path" # Fjern ufullstendig fil
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
    echo " $((${#package_display_names[@]}+1))) Tilbake"; local choice_idx
    while true; do
        read -r -p "Velg pakke (1-$((${#package_display_names[@]}+1))): " choice_idx
        if [[ "$choice_idx" =~ ^[0-9]+$ ]] && [ "$choice_idx" -ge 1 ] && [ "$choice_idx" -le $((${#package_display_names[@]}+1)) ]; then break; else log_warn "Ugyldig."; fi
    done
    if [ "$choice_idx" -eq $((${#package_display_names[@]}+1)) ]; then return 0; fi
    local selected_pkg_idx=$((choice_idx - 1))
    mapfile -t files_to_dl < <(echo "$packages_json" | jq -r --argjson idx "$selected_pkg_idx" '.packages[$idx].files[]')
    if [ ${#files_to_dl[@]} -eq 0 ]; then log_warn "Ingen filer for denne pakken."; press_enter_to_continue; return 0; fi

    log_info "Pakke: ${package_display_names[$selected_pkg_idx]}"; echo "Filer som lastes ned (hvis de ikke finnes):"
    for file_rel_path in "${files_to_dl[@]}"; do echo "  - $file_rel_path"; done
    read -r -p "Fortsett? (ja/nei): " confirm_dl; if [[ ! "$confirm_dl" =~ ^[Jj][Aa]$ ]]; then return 0; fi

    local dl_c=0 skip_c=0 fail_c=0
    for file_rel_path in "${files_to_dl[@]}"; do
        local src_url="${MD_SERVER_BASE_URL}${file_rel_path}"
        local target_path="${MD_COMFYUI_BASE_MODELS_PATH}/${file_rel_path}"
        if [ -f "$target_path" ]; then
            log_warn "Filen '$(basename "$file_rel_path")' finnes. Overskriv? (ja/Nei): "
            read -r ovrw_pkg; if [[ ! "$ovrw_pkg" =~ ^[Jj][Aa]$ ]]; then log_info "Hopper over."; skip_c=$((skip_c+1)); continue; fi
        fi
        if md_download_file "$src_url" "$target_path"; then dl_c=$((dl_c+1)); else fail_c=$((fail_c+1)); fi
    done
    log_info "Pakkenedlasting ferdig. Nedlastet: $dl_c, Hoppet over: $skip_c, Mislyktes: $fail_c."
    press_enter_to_continue
}


run_model_downloader() {
    local preselected_path_for_data_dir="$1" # Dette er f.eks. ~/comfyui_unified_setup/comfyui_data

    if ! md_check_jq; then press_enter_to_continue; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then
        log_error "Kunne ikke bestemme ComfyUI models-sti for nedlasting."
        press_enter_to_continue
        return 1
    fi

    # Hovedløkke for modelldownloader
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
        local md_choice
        read -r -p "Velg et alternativ (1-5): " md_choice
        case "$md_choice" in
            1) # Utforsk enkeltfiler
                while true; do # Mappevalg
                    clear; echo "--- Utforsker mapper på $MD_SERVER_BASE_URL ---"
                    local map_links_output; map_links_output=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                    local map_links; map_links=$(echo "$map_links_output" | grep '/$' )
                    if [ -z "$map_links" ]; then log_warn "Fant ingen undermapper."; sleep 2; break; fi
                    local map_array=(); while IFS= read -r line; do map_array+=("$line"); done <<< "$map_links"
                    echo "Tilgjengelige mapper:"; for i in "${!map_array[@]}"; do echo "$((i+1))) ${map_array[$i]}"; done
                    echo "$((${#map_array[@]}+1))) Tilbake"; local map_c
                    while true; do read -r -p "Velg mappe (1-$((${#map_array[@]}+1))): " map_c; if [[ "$map_c" =~ ^[0-9]+$ ]] && [ "$map_c" -ge 1 ] && [ "$map_c" -le $((${#map_array[@]}+1)) ]; then break; fi; done
                    if [ "$map_c" -eq $((${#map_array[@]}+1)) ]; then break; fi
                    local sel_subdir="${map_array[$((map_c-1))]}"

                    while true; do # Filvalg
                        clear; local current_srv_dir_url="${MD_SERVER_BASE_URL}${sel_subdir}"
                        echo "--- Filer i $current_srv_dir_url ---"
                        local file_links_o; file_links_o=$(md_get_links_from_url "$current_srv_dir_url")
                        local file_links_f; file_links_f=$(echo "$file_links_o" | grep -v '/$' )
                        local file_array_f=(); if [ -n "$file_links_f" ]; then while IFS= read -r line; do file_array_f+=("$line"); done <<< "$file_links_f"; fi
                        if [ ${#file_array_f[@]} -eq 0 ]; then log_warn "Ingen filer funnet."; else echo "Filer:"; for i in "${!file_array_f[@]}"; do echo "$((i+1))) ${file_array_f[$i]}"; done; fi
                        echo "$((${#file_array_f[@]}+1))) Tilbake"; local file_c
                        while true; do read -r -p "Velg fil (1-$((${#file_array_f[@]}+1))): " file_c; if [[ "$file_c" =~ ^[0-9]+$ ]] && [ "$file_c" -ge 1 ] && [ "$file_c" -le $((${#file_array_f[@]}+1)) ]; then break; fi; done
                        if [ "$file_c" -eq $((${#file_array_f[@]}+1)) ]; then break; fi
                        local sel_fname="${file_array_f[$((file_c-1))]}"
                        local src_url_f="$current_srv_dir_url$sel_fname"
                        local target_path_f="$MD_COMFYUI_BASE_MODELS_PATH/$sel_subdir$sel_fname"
                        if [ -f "$target_path_f" ]; then
                           log_warn "Filen finnes. Overskriv? (ja/nei):"; read -r ovrw_f; if [[ ! "$ovrw_f" =~ ^[Jj][Aa]$ ]]; then log_info "Hopper over."; continue; fi
                        fi
                        md_download_file "$src_url_f" "$target_path_f"
                        read -r -p "Last ned en annen fil fra '$sel_subdir'? (ja/nei) [j]: " another_f; if [[ "$another_f" =~ ^[Nn]$ ]]; then break; fi
                    done
                    read -r -p "Utforske en annen mappe? (ja/nei) [j]: " another_m; if [[ "$another_m" =~ ^[Nn]$ ]]; then break; fi
                done ;;
            2) # Last ned alle
                clear; echo "--- Last ned alle manglende modeller ---"
                read -r -p "Dette kan ta lang tid. Er du sikker? (ja/nei): " confirm_all
                if [[ ! "$confirm_all" =~ ^[Jj][Aa]$ ]]; then log_info "Avbrutt."; continue; fi
                local map_links_all_o; map_links_all_o=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                local map_links_all; map_links_all=$(echo "$map_links_all_o" | grep '/$' )
                if [ -z "$map_links_all" ]; then log_warn "Fant ingen undermapper på server."; else
                    local map_arr_all=(); while IFS= read -r line; do map_arr_all+=("$line"); done <<< "$map_links_all"
                    for cur_subdir_all in "${map_arr_all[@]}"; do
                        log_info "Sjekker mappe: $cur_subdir_all"
                        local files_o_all; files_o_all=$(md_get_links_from_url "$MD_SERVER_BASE_URL$cur_subdir_all")
                        local files_f_all; files_f_all=$(echo "$files_o_all" | grep -v '/$' )
                        if [ -z "$files_f_all" ]; then log_info " Ingen filer i denne mappen."; continue; fi
                        local files_arr_dl_all=(); while IFS= read -r line; do files_arr_dl_all+=("$line"); done <<< "$files_f_all"
                        for cur_fname_all in "${files_arr_dl_all[@]}"; do
                            local target_p_all="$MD_COMFYUI_BASE_MODELS_PATH/$cur_subdir_all$cur_fname_all"
                            if [ -f "$target_p_all" ]; then echo "  Skipper: '$(basename "$target_p_all")' finnes."; else
                                md_download_file "$MD_SERVER_BASE_URL$cur_subdir_all$cur_fname_all" "$target_p_all"
                            fi
                        done
                    done
                fi
                log_success "Nedlasting av alle fullført."; press_enter_to_continue ;;
            3) md_handle_package_download ;;
            4) # Bytt ComfyUI models-mappe
                MD_COMFYUI_PATH="" # Nullstill for å tvinge nytt valg
                MD_COMFYUI_BASE_MODELS_PATH=""
                if ! md_find_and_select_comfyui_path ""; then # "" betyr ingen forhåndsvalgt sti
                    log_error "Kunne ikke sette ny ComfyUI models-sti."
                fi
                press_enter_to_continue ;;
            5) break ;; # Tilbake til hovedmeny
            *) log_warn "Ugyldig valg." ;;
        esac
    done
}
# --- Hovedmeny Funksjon ---
main_menu() {
    initialize_docker_paths # Sørg for at disse er satt ved start
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
        read -r -p "Velg et alternativ: " choice

        # Nullstill feilflagg for set -e
        set +e

        case "$choice" in
            1) perform_docker_initial_setup ;;
            2)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                build_comfyui_image
                press_enter_to_continue
                ;;
            3)
                # Hvis Docker-oppsettet er gjort, bruk den stien, ellers la brukeren velge
                if [[ -d "$DOCKER_DATA_ACTUAL_PATH/models" ]]; then
                    run_model_downloader "$DOCKER_DATA_ACTUAL_PATH"
                else
                    run_model_downloader # Uten argument, bruker vil bli spurt
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
