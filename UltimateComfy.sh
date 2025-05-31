#!/bin/bash
# Kombinert skript for ComfyUI Docker Oppsett og Modelldenedlasting

# --- Globale Innstillinger og Konstanter ---
# Farger for logging
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# For Docker-oppsett
BASE_DOCKER_SETUP_DIR="$HOME/comfyui_unified_setup"
DOCKERFILES_DIR_NAME="docker_config"
COMFYUI_DATA_DIR_NAME="comfyui_data"
SCRIPTS_DIR_NAME="scripts"
COMFYUI_IMAGE_NAME="comfyui-app"

# Definer de komplette image tag-delene her for klarhet
DOCKER_CUDA_DEVEL_TAG="nvcr.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04"
# !! VIKTIG: VERIFISER DENNE RUNTIME-TAGGEN PÅ NVIDIA NGC !!
# Det kan være f.eks. "12.4.1-base-ubuntu22.04" eller lignende hvis "-cudnn-runtime-" ikke finnes.
DOCKER_CUDA_RUNTIME_TAG="12.4.1-cudnn-runtime-ubuntu22.04"

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
    log_info "DEBUG FØR BUILD: DOCKER_CUDA_DEVEL_TAG er satt til: [$DOCKER_CUDA_DEVEL_TAG]"
    log_info "DEBUG FØR BUILD: DOCKER_CUDA_RUNTIME_TAG er satt til: [$DOCKER_CUDA_RUNTIME_TAG] (VERIFISER DENNE!)"
    log_info "Dette kan ta en stund."
    log_info "TRYKK ENTER FOR Å STARTE BYGGING ETTER Å HA SETT DEBUG-INFO OVENFOR..."
    press_enter_to_continue

    if docker build -t "$COMFYUI_IMAGE_NAME" \
        --build-arg PASSED_CUDA_DEVEL_TAG="$DOCKER_CUDA_DEVEL_TAG" \
        --build-arg PASSED_CUDA_RUNTIME_TAG="$DOCKER_CUDA_RUNTIME_TAG" \
        "$DOCKER_CONFIG_ACTUAL_PATH"; then
        log_success "Docker-image '$COMFYUI_IMAGE_NAME' bygget/oppdatert vellykket."
        return 0
    else
        log_error "Bygging av Docker-image mislyktes."
        log_error "FEIL UNDER DOCKER BUILD. TRYKK ENTER FOR Å GÅ TILBAKE TIL MENY."
        press_enter_to_continue
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

    log_info "Genererer Dockerfile med printf..."
    (
    printf '%s\n' '# Stage 1: Builder'
    printf 'ARG %s\n' "PASSED_CUDA_DEVEL_TAG"
    printf 'FROM nvcr.io/nvidia/cuda:%s AS builder\n' '${PASSED_CUDA_DEVEL_TAG}'
    printf '\n'
    printf 'ENV %s\n' 'DEBIAN_FRONTEND=noninteractive'
    # Endret til de.archive.ubuntu.com og de.security.ubuntu.com
    printf 'RUN %s\n' 'sed -i "s/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/de.archive.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && sed -i "s/http:\/\/security.ubuntu.com\/ubuntu\//http:\/\/de.security.ubuntu.com\/ubuntu\//g" /etc/apt/sources.list && apt-get update && apt-get install -y --no-install-recommends git python3-pip python3-venv ffmpeg curl && rm -rf /var/lib/apt/lists/*'
    printf 'RUN %s\n' 'python3 -m venv /opt/venv'
    printf 'ENV PATH="/opt/venv/bin:%s"\n' '$PATH'
    printf 'WORKDIR %s\n' '/app'
    printf 'RUN %s\n' 'git clone https://github.com/comfyanonymous/ComfyUI.git'
    printf 'WORKDIR %s\n' '/app/ComfyUI'
    printf 'RUN %s\n' 'pip install --no-cache-dir -r requirements.txt'
    printf 'RUN %s\n' 'git clone https://github.com/ltdrdata/ComfyUI-Manager.git ./custom_nodes/ComfyUI-Manager'
    printf 'RUN %s\n' 'pip install --no-cache-dir -r ./custom_nodes/ComfyUI-Manager/requirements.txt'
    printf '\n'
    printf '%s\n' '# Stage 2: Runtime'
    printf 'ARG %s\n' "PASSED_CUDA_RUNTIME_TAG"
    printf 'FROM nvcr.io/nvidia/cuda:%s AS runtime\n' '${PASSED_CUDA_RUNTIME_TAG}'
    printf '\n'
    printf 'ENV %s\n' 'DEBIAN_FRONTEND=noninteractive'
    # Endret til de.archive.ubuntu.com og de.security.ubuntu.com også her
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
    
    set +e 
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
        use_preselected=${use_preselected:-B} # Default til Bruk denne
        if [[ "$use_preselected" =~ ^[Vv]$ ]]; then # V for Velg annen
            MD_COMFYUI_PATH="" 
            MD_COMFYUI_BASE_MODELS_PATH=""
            log_info "Lar deg velge sti manuelt."
        else
            log_success "Bruker $MD_COMFYUI_PATH for modelldenedlasting."
            return 0 
        fi
    fi

    # Fallback til å søke hvis ingen forhåndsvalgt sti ble akseptert
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
            # Sjekk om stien direkte har en 'models' undermappe ELLER om det er Docker data mappen som har det
            if [[ -d "$normalized_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            # Håndter tilfellet der path_found er f.eks. comfyui_unified_setup, og vi må se inni comfyui_data
            elif [[ "$normalized_path" == "$BASE_DOCKER_SETUP_DIR" ]] && [[ -d "$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME/models" ]]; then
                local docker_data_models_path="$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME"
                 if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$docker_data_models_path"; then
                    found_paths+=("$docker_data_models_path") # Legg til .../comfyui_data stien
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

    while [[ -z "$MD_COMFYUI_PATH" ]]; do # Loop til vi får en gyldig sti
        read -r -e -p "Oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " manual_path </dev/tty
        manual_path="${manual_path%/}" 
        if [[ -d "$manual_path" ]] && [[ -d "$manual_path/models" ]]; then
            MD_COMFYUI_PATH="$manual_path"
        else
            log_error "Stien '$manual_path' er ugyldig eller mangler 'models'-undermappe. Prøv igjen."
        fi
    done

    MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models" # Sett denne uansett etter løkken
    if [ ! -d "$MD_COMFYUI_BASE_MODELS_PATH" ]; then 
        log_error "FEIL: Mappen '$MD_COMFYUI_BASE_MODELS_PATH' ble ikke funnet etter stivalg!"
        return 1
    fi
    log_success "Bruker '$MD_COMFYUI_BASE_MODELS_PATH' for modeller."; return 0
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
    local target_dir
    target_dir=$(dirname "$target_path")
    local target_filename
    target_filename=$(basename "$target_path")

    log_info "Forbereder nedlasting av '$target_filename'"
    echo "     Fra: $source_url"
    echo "     Til: $target_path"

    if [ ! -d "$target_dir" ]; then
      log_warn "Målmappen '$target_dir' eksisterer ikke. Oppretter den..."
      if ! mkdir -p "$target_dir"; then
        log_error "Kunne ikke opprette mappen '$target_dir'. Hopper over nedlasting."
        return 1
      fi
    fi

    log_info "Starter nedlasting med wget..."
    if wget -c -O "$target_path" "$source_url" -q --show-progress --progress=bar:force 2>&1; then
      log_success "Nedlasting av '$target_filename' fullført!"
      if [ -f "$target_path" ]; then
         local filesize
         filesize=$(stat -c%s "$target_path")
         if [ "$filesize" -lt 10000 ]; then
           log_warn "Nedlastet fil '$target_filename' er liten ($filesize bytes). Den kan være en feilrespons fra serveren."
         else
           echo "  Nedlastet filstørrelse: $filesize bytes."
         fi
      else
          log_warn "Nedlasting rapporterte suksess, men filen '$target_path' ble ikke funnet."
      fi
      return 0
    else
      log_error "Nedlasting av '$target_filename' mislyktes."
      log_error "Sjekk nettverkstilkobling og tilgangen til kilde-URL-en."
      rm -f "$target_path" 
      return 1
    fi
}

md_handle_package_download() {
    clear
    echo "--- Last ned Modellpakke ---"
    log_info "Henter pakkedefinisjoner fra $MD_PACKAGES_JSON_URL..."

    local packages_json
    packages_json=$(curl --connect-timeout 10 -s -L -f "$MD_PACKAGES_JSON_URL")
    local curl_exit_code=$?

    if [ $curl_exit_code -ne 0 ]; then
        log_error "Kunne ikke hente pakkedefinisjonsfilen fra $MD_PACKAGES_JSON_URL."
        log_error "Curl feilkode: $curl_exit_code. Sjekk URL og nettverkstilkobling."
        press_enter_to_continue
        return 1
    fi

    if ! echo "$packages_json" | jq -e . > /dev/null 2>&1; then
        log_error "Pakkedefinisjonsfilen fra $MD_PACKAGES_JSON_URL er ikke gyldig JSON."
        log_error "Innhold mottatt (første 200 tegn): $(echo "$packages_json" | head -c 200)"
        press_enter_to_continue
        return 1
    fi
    
    mapfile -t package_display_names < <(echo "$packages_json" | jq -r '.packages[].displayName')

    if [ ${#package_display_names[@]} -eq 0 ]; then
        log_warn "Ingen modellpakker funnet i $MD_PACKAGES_JSON_URL eller filen er tom/feilformatert."
        press_enter_to_continue
        return 0
    fi

    echo "Tilgjengelige modellpakker:"
    for i in "${!package_display_names[@]}"; do
        echo "  $((i+1))) ${package_display_names[$i]}"
    done
    echo "  $((${#package_display_names[@]}+1))) Tilbake til meny"

    local package_choice_idx
    while true; do
        read -r -p "Velg en pakke (1-$((${#package_display_names[@]}+1))): " package_choice_idx </dev/tty
        if [[ "$package_choice_idx" =~ ^[0-9]+$ ]] && [ "$package_choice_idx" -ge 1 ] && [ "$package_choice_idx" -le $((${#package_display_names[@]}+1)) ]; then
            break
        else
            log_warn "Ugyldig valg."
        fi
    done

    if [ "$package_choice_idx" -eq $((${#package_display_names[@]}+1)) ]; then
        return 0 
    fi

    local selected_package_index=$((package_choice_idx - 1)) 
    local selected_package_display_name="${package_display_names[$selected_package_index]}"

    mapfile -t package_files_to_download < <(echo "$packages_json" | jq -r --argjson idx "$selected_package_index" '.packages[$idx].files[]')

    if [ ${#package_files_to_download[@]} -eq 0 ]; then
        log_warn "Ingen filer er definert for pakken '$selected_package_display_name' i JSON-filen."
        press_enter_to_continue
        return 0
    fi

    log_info "Du har valgt å laste ned pakken: $selected_package_display_name"
    echo "Følgende filer vil bli lastet ned (hvis de ikke allerede finnes):"
    for file_rel_path in "${package_files_to_download[@]}"; do
        echo "  - $file_rel_path"
    done
    
    read -r -p "Vil du fortsette med nedlastingen? (ja/nei): " confirm_download </dev/tty
    if [[ ! "$confirm_download" =~ ^[Jj][Aa]$ ]]; then
        log_info "Nedlasting av pakke avbrutt."
        press_enter_to_continue
        return 0
    fi

    local files_downloaded_count=0
    local files_skipped_count=0
    local files_failed_count=0

    for file_relative_path in "${package_files_to_download[@]}"; do
        local source_url="${MD_SERVER_BASE_URL}${file_relative_path}"
        local target_path_locally="${MD_COMFYUI_BASE_MODELS_PATH}/${file_relative_path}"
        local target_filename
        target_filename=$(basename "$file_relative_path")
        local target_dir_locally
        target_dir_locally=$(dirname "$target_path_locally")

        echo "" 
        if [ -f "$target_path_locally" ]; then
            log_warn "Filen '$target_filename' finnes allerede i '$target_dir_locally'."
            local overwrite_choice_pkg
            read -r -p "Vil du laste ned på nytt og overskrive? (ja/Nei, Enter for Nei): " overwrite_choice_pkg </dev/tty
            overwrite_choice_pkg=${overwrite_choice_pkg:-N}
            if [[ ! "$overwrite_choice_pkg" =~ ^[Jj][Aa]$ ]]; then
                log_info "Skipper nedlasting av '$target_filename'."
                files_skipped_count=$((files_skipped_count + 1))
                continue
            fi
        fi
        
        if md_download_file "$source_url" "$target_path_locally"; then
            files_downloaded_count=$((files_downloaded_count + 1))
        else
            files_failed_count=$((files_failed_count + 1))
        fi
    done

    echo ""
    log_success "Pakkenedlasting for '$selected_package_display_name' er fullført."
    if [ "$files_downloaded_count" -gt 0 ]; then log_info "$files_downloaded_count fil(er) ble lastet ned."; fi
    if [ "$files_skipped_count" -gt 0 ]; then log_info "$files_skipped_count fil(er) ble hoppet over."; fi
    if [ "$files_failed_count" -gt 0 ]; then log_warn "$files_failed_count fil(er) kunne ikke lastes ned."; fi
    press_enter_to_continue
}


run_model_downloader() {
    local preselected_path_for_data_dir="$1" 

    if ! md_check_jq; then press_enter_to_continue; return 1; fi
    
    # Forsøk å sette sti, hvis det feiler, ikke gå inn i menyen
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then
        log_error "Kunne ikke bestemme ComfyUI models-sti for nedlasting. Går tilbake til hovedmeny."
        press_enter_to_continue
        return 1
    fi

    local md_choice_val
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
        
        read -r -p "Velg et alternativ (1-5): " md_choice_val </dev/tty
        case "$md_choice_val" in
            1) # Utforsk enkeltfiler
                local map_choice_val
                while true; do # Mappevalg-løkke
                    clear
                    echo "--- Utforsker Mapper på Server: $MD_SERVER_BASE_URL ---"
                    log_info "Henter liste over undermapper fra $MD_SERVER_BASE_URL..."
                    local map_links_output_val
                    map_links_output_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                    local map_links_val
                    map_links_val=$(echo "$map_links_output_val" | grep '/$' ) 

                    if [ -z "$map_links_val" ]; then
                        log_warn "Fant ingen undermapper på $MD_SERVER_BASE_URL."
                        log_warn "Sjekk URL og serverkonfigurasjon. Går tilbake..."
                        sleep 2; break 
                    fi

                    local map_array_val=()
                    while IFS= read -r line; do map_array_val+=("$line"); done <<< "$map_links_val"
                    local num_maps_val=${#map_array_val[@]}

                    echo "Tilgjengelige mapper på serveren:"
                    for i in "${!map_array_val[@]}"; do echo "  $((i+1))) ${map_array_val[$i]}"; done
                    echo "  $((num_maps_val+1))) Gå tilbake til modelldownloader-meny"

                    while true; do
                        read -r -p "Velg en mappe å utforske (1-$((num_maps_val+1))): " map_choice_val </dev/tty
                        if [[ "$map_choice_val" =~ ^[0-9]+$ ]] && [ "$map_choice_val" -ge 1 ] && [ "$map_choice_val" -le "$((num_maps_val+1))" ]; then break; else log_warn "Ugyldig valg."; fi
                    done

                    if [ "$map_choice_val" -eq "$((num_maps_val+1))" ]; then break; fi # Tilbake til modelldownloader-meny

                    local selected_server_subdir_val="${map_array_val[$((map_choice_val-1))]}"
                    
                    local file_choice_val
                    while true; do # Filvalg-løkke
                        clear
                        local current_server_dir_url_val="${MD_SERVER_BASE_URL}${selected_server_subdir_val}"
                        echo "--- Utforsker Filer i: $current_server_dir_url_val ---"
                        log_info "Henter liste over filer..."
                        
                        local file_links_output_val
                        file_links_output_val=$(md_get_links_from_url "$current_server_dir_url_val")
                        local file_links_f_val
                        file_links_f_val=$(echo "$file_links_output_val" | grep -v '/$') # Kun filer

                        local file_array_f_val=()
                        if [ -n "$file_links_f_val" ]; then
                             while IFS= read -r line; do file_array_f_val+=("$line"); done <<< "$file_links_f_val"
                        fi
                        local num_files_val=${#file_array_f_val[@]}

                        if [ $num_files_val -eq 0 ]; then
                            log_warn "Fant ingen filer i '$selected_server_subdir_val'."
                        else
                            echo "Tilgjengelige filer:"
                            for i in "${!file_array_f_val[@]}"; do echo "  $((i+1))) ${file_array_f_val[$i]}"; done
                        fi
                        echo "  $((num_files_val+1))) Gå tilbake til mappevalg"

                        while true; do
                             read -r -p "Velg en fil å laste ned (1-$((num_files_val+1))): " file_choice_val </dev/tty
                             if [[ "$file_choice_val" =~ ^[0-9]+$ ]] && [ "$file_choice_val" -ge 1 ] && [ "$file_choice_val" -le "$((num_files_val+1))" ]; then break; else log_warn "Ugyldig valg."; fi
                        done

                        if [ "$file_choice_val" -eq "$((num_files_val+1))" ]; then break; fi # Tilbake til mappevalg

                        local selected_filename_val="${file_array_f_val[$((file_choice_val-1))]}"
                        local source_url_f_val="$current_server_dir_url_val$selected_filename_val"
                        # Server subdir har / på slutten, filnavn ikke.
                        local target_path_f_val="$MD_COMFYUI_BASE_MODELS_PATH/$selected_server_subdir_val$selected_filename_val"


                        if [ -f "$target_path_f_val" ]; then
                            log_warn "Filen '$selected_filename_val' finnes allerede."
                            local overwrite_choice_f_val
                            read -r -p "Vil du laste ned på nytt og overskrive? (ja/nei): " overwrite_choice_f_val </dev/tty
                            if [[ ! "$overwrite_choice_f_val" =~ ^[Jj][Aa]$ ]]; then
                                log_info "Skipper nedlasting."
                                # Spør om å laste ned en annen fil fra samme mappe
                                local another_file_same_folder_val
                                read -r -p "Last ned en annen fil fra '$selected_server_subdir_val'? (ja/nei, Enter for ja): " another_file_same_folder_val </dev/tty
                                another_file_same_folder_val=${another_file_same_folder_val:-j}
                                if [[ "$another_file_same_folder_val" =~ ^[Nn][Ee][Ii]$ ]]; then break; fi # Tilbake til mappevalg
                                continue # Fortsett filvalg-løkken
                            fi
                        fi
                        
                        md_download_file "$source_url_f_val" "$target_path_f_val"
                        
                        echo ""
                        local another_file_choice_val
                        read -r -p "Last ned en annen fil fra '$selected_server_subdir_val'? (ja/nei, Enter for ja): " another_file_choice_val </dev/tty
                        another_file_choice_val=${another_file_choice_val:-j}
                        if [[ "$another_file_choice_val" =~ ^[Nn][Ee][Ii]$ ]]; then break; fi # Tilbake til mappevalg
                    done # Slutt på filvalg-løkke

                    echo ""
                    local another_folder_choice_val
                    read -r -p "Utforske en annen mappe på serveren? (ja/nei, Enter for ja): " another_folder_choice_val </dev/tty
                    another_folder_choice_val=${another_folder_choice_val:-j}
                    if [[ "$another_folder_choice_val" =~ ^[Nn][Ee][Ii]$ ]]; then break; fi # Tilbake til modelldownloader-meny 
                done # Slutt på mappevalg-løkke
                ;;

            2) # Last ned alle
                clear
                echo "--- Starter 'Last ned alle' prosess ---"
                log_info "Sjekker alle mapper på $MD_SERVER_BASE_URL og laster ned manglende filer til '$MD_COMFYUI_BASE_MODELS_PATH/'..."
                read -r -p "Dette kan ta lang tid. Er du sikker? (ja/nei): " confirm_all_val </dev/tty
                if [[ ! "$confirm_all_val" =~ ^[Jj][Aa]$ ]]; then
                    log_info "Avbrutt av bruker."
                    press_enter_to_continue
                    continue 
                fi

                local map_links_output_all_val
                map_links_output_all_val=$(md_get_links_from_url "$MD_SERVER_BASE_URL")
                local map_links_all_val
                map_links_all_val=$(echo "$map_links_output_all_val" | grep '/$' )

                if [ -z "$map_links_all_val" ]; then
                    log_warn "Fant ingen undermapper på $MD_SERVER_BASE_URL. Kan ikke laste ned alle."
                else
                    local map_array_all_val=()
                    while IFS= read -r line; do map_array_all_val+=("$line"); done <<< "$map_links_all_val"
                    log_info "Fant ${#map_array_all_val[@]} mapper å sjekke."

                    for current_server_subdir_all_val in "${map_array_all_val[@]}"; do
                        echo ""
                        log_info "Sjekker mappe: $MD_SERVER_BASE_URL$current_server_subdir_all_val"
                        local current_server_dir_url_all_val="${MD_SERVER_BASE_URL}${current_server_subdir_all_val}"
                        
                        local file_links_output_all_f_val
                        file_links_output_all_f_val=$(md_get_links_from_url "$current_server_dir_url_all_val")
                        local file_links_all_f_val
                        file_links_all_f_val=$(echo "$file_links_output_all_f_val" | grep -v '/$')

                        if [ -z "$file_links_all_f_val" ]; then
                            log_info "  Ingen filer funnet i denne mappen på serveren."
                            continue
                        fi

                        local file_array_dl_all_val=()
                        while IFS= read -r line; do file_array_dl_all_val+=("$line"); done <<< "$file_links_all_f_val"
                        log_info "  Fant ${#file_array_dl_all_val[@]} filer i '$current_server_subdir_all_val' på serveren."

                        for current_filename_all_val in "${file_array_dl_all_val[@]}"; do
                            local target_path_locally_all_val="$MD_COMFYUI_BASE_MODELS_PATH/$current_server_subdir_all_val$current_filename_all_val"
                            local source_url_all_val="$current_server_dir_url_all_val$current_filename_all_val"

                            if [ -f "$target_path_locally_all_val" ]; then
                                echo "  Skipper: '$current_filename_all_val' finnes allerede lokalt."
                            else
                                md_download_file "$source_url_all_val" "$target_path_locally_all_val"
                            fi
                        done
                    done
                    log_success "Automatisk nedlastingsprosess fullført."
                fi
                press_enter_to_continue
                ;;
            3) md_handle_package_download ;;
            4) # Bytt ComfyUI models-mappe
                MD_COMFYUI_PATH="" 
                MD_COMFYUI_BASE_MODELS_PATH=""
                if ! md_find_and_select_comfyui_path ""; then 
                    log_error "Kunne ikke sette ny ComfyUI models-sti."
                fi
                press_enter_to_continue ;;
            5) break ;; # Tilbake til hovedmeny (main_menu)
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
        set +e 
        case "$main_choice" in
            1) perform_docker_initial_setup ;;
            2) if ! check_docker_status; then press_enter_to_continue; continue; fi; build_comfyui_image; press_enter_to_continue ;;
            3) if [[ -d "$DOCKER_DATA_ACTUAL_PATH/models" ]]; then run_model_downloader "$DOCKER_DATA_ACTUAL_PATH"; else log_info "Docker data sti ikke funnet ($DOCKER_DATA_ACTUAL_PATH/models)."; log_info "Lar deg velge sti for modelldenedlasting manuelt."; run_model_downloader; fi ;;
            4) if ! check_docker_status; then press_enter_to_continue; continue; fi; if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"; else log_warn "Startskript ikke funnet. Kjør installasjon (valg 1) først."; fi; press_enter_to_continue ;;
            5) if ! check_docker_status; then press_enter_to_continue; continue; fi; if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh" ]]; then "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"; else log_warn "Stoppskript ikke funnet."; fi; press_enter_to_continue ;;
            6) log_info "Avslutter."; exit 0 ;;
            *) log_warn "Ugyldig valg."; press_enter_to_continue ;;
        esac
    done
}

# --- Skriptets startpunkt ---
clear
log_info "Starter ComfyUI Unified Tool..."
main_menu
