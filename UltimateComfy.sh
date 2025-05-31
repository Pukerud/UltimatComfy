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
DOCKER_CUDA_DEVEL_TAG="12.4.1-cudnn-devel-ubuntu22.04"
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
        use_preselected=${use_preselected:-B}
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
        mapfile -t -d $'\0' current_finds < <(find "$loc" -maxdepth 4 -type d \( -name "ComfyUI" -o -name "comfyui_data" -o -name "comfyui_unified_setup" \) -print0 2>/dev/null)
        for path_found in "${current_finds[@]}"; do
            local normalized_path="${path_found%/}"
            if [[ -d "$normalized_path/models" ]]; then # Ser spesifikt etter en 'models' undermappe
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            elif [[ "$normalized_path" == "$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME" ]] && [[ -d "$normalized_path/models" ]]; then # Spesialtilfelle for Docker-data
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
        if [[ -d "$manual_path" ]] && [[ -d "$manual_path/models" ]]; then MD_COMFYUI_PATH="$manual_path";
        else log_error "Stien '$manual_path' er ugyldig eller mangler 'models'-mappe."; fi
    done
    MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
    if [ ! -d "$MD_COMFYUI_BASE_MODELS_PATH" ]; then log_error "FEIL: Mappen '$MD_COMFYUI_BASE_MODELS_PATH' ble ikke funnet!"; return 1; fi
    log_success "Bruker '$MD_COMFYUI_BASE_MODELS_PATH' for modeller."; return 0
}

md_get_links_from_url() { local url="$1"; curl --connect-timeout 5 -s -L -f "$url" 2>/dev/null | grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | grep -v '^$' | grep -E -v '(\.\.\/|Parent Directory|^\?|^\.|apache\.org|速度|名称|修改日期|大小)' || echo ""; }
md_download_file() { local S="$1" T="$2" D=$(dirname "$T") F=$(basename "$T"); log_info "Laster ned '$F' fra $S til $T"; if [ ! -d "$D" ]; then log_warn "Mappe '$D' finnes ikke. Oppretter..."; if ! mkdir -p "$D"; then log_error "Kunne ikke opprette '$D'."; return 1; fi; fi; if wget -c -O "$T" "$S" -q --show-progress --progress=bar:force 2>&1; then log_success "Nedlasting '$F' OK!"; if [ -f "$T" ]; then local FS=$(stat -c%s "$T"); if [ "$FS" -lt 10000 ]; then log_warn "Fil '$F' er liten ($FS bytes)."; fi; fi; return 0; else log_error "Nedlasting '$F' FEIL."; rm -f "$T"; return 1; fi; }
md_handle_package_download() { clear; echo "--- Last ned Modellpakke ---"; log_info "Henter fra $MD_PACKAGES_JSON_URL..."; local J=$(curl -sL --connect-timeout 10 -f "$MD_PACKAGES_JSON_URL"); if [ $? -ne 0 ]; then log_error "Kunne ikke hente pakker."; press_enter_to_continue; return 1; fi; if ! echo "$J" | jq -e . >/dev/null 2>&1; then log_error "Pakke-JSON ugyldig."; press_enter_to_continue; return 1; fi; mapfile -t Pdns < <(echo "$J" | jq -r '.packages[].displayName'); if [ ${#Pdns[@]} -eq 0 ]; then log_warn "Ingen pakker."; press_enter_to_continue; return 0; fi; echo "Pakker:"; for i in "${!Pdns[@]}"; do echo " $((i+1))) ${Pdns[$i]}"; done; echo " $((${#Pdns[@]}+1))) Tilbake"; local Pci; while true; do read -r -p "Velg (1-$((${#Pdns[@]}+1))): " Pci </dev/tty; if [[ "$Pci" =~ ^[0-9]+$ && "$Pci" -ge 1 && "$Pci" -le $((${#Pdns[@]}+1)) ]]; then break; else log_warn "Ugyldig."; fi; done; if [ "$Pci" -eq $((${#Pdns[@]}+1)) ]; then return 0; fi; local Spi=$((Pci-1)); mapfile -t Ftd < <(echo "$J" | jq -r --argjson idx "$Spi" '.packages[$idx].files[]'); if [ ${#Ftd[@]} -eq 0 ]; then log_warn "Ingen filer i pakken."; press_enter_to_continue; return 0; fi; log_info "Pakke: ${Pdns[$Spi]}"; echo "Filer:"; for Frp in "${Ftd[@]}"; do echo "  - $Frp"; done; read -r -p "Fortsett? (j/n): " Cdl </dev/tty; if [[ ! "$Cdl" =~ ^[Jj]$ ]]; then return 0; fi; local Dc=0 Sc=0 Fc=0; for Frp in "${Ftd[@]}"; do local Su="${MD_SERVER_BASE_URL}${Frp}"; local Tp="${MD_COMFYUI_BASE_MODELS_PATH}/${Frp}"; if [ -f "$Tp" ]; then read -r -p "Fil '$(basename "$Frp")' finnes. Overskriv? (j/N): " Orp </dev/tty; if [[ ! "$Orp" =~ ^[Jj]$ ]]; then log_info "Hopper over."; Sc=$((Sc+1)); continue; fi; fi; if md_download_file "$Su" "$Tp"; then Dc=$((Dc+1)); else Fc=$((Fc+1)); fi; done; log_info "Ferdig. DL:$Dc, Skip:$Sc, Feil:$Fc."; press_enter_to_continue; }

run_model_downloader() {
    local preselected_path_for_data_dir="$1" 
    if ! md_check_jq; then press_enter_to_continue; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then log_error "Kan ikke sette ComfyUI models-sti."; press_enter_to_continue; return 1; fi
    while true; do clear; echo "--- Modelldenedlastingsverktøy ---"; echo "Bruker: $MD_COMFYUI_BASE_MODELS_PATH"; echo "Server: $MD_SERVER_BASE_URL"; echo "----------------------------------"; echo "1) Utforsk enkeltfiler"; echo "2) Last ned alle manglende"; echo "3) Last ned pakke"; echo "4) Bytt ComfyUI models-mappe"; echo "5) Tilbake til hovedmeny"; local Mdc; read -r -p "Velg (1-5): " Mdc </dev/tty;
        case "$Mdc" in
            1) while true; do clear; echo "--Mapper på $MD_SERVER_BASE_URL--"; local Mlo; Mlo=$(md_get_links_from_url "$MD_SERVER_BASE_URL"); local Ml; Ml=$(echo "$Mlo" | grep '/$'); if [ -z "$Ml" ]; then log_warn "Ingen mapper."; sleep 1; break; fi; local Ma=(); while IFS= read -r l; do Ma+=("$l"); done <<< "$Ml"; echo "Mapper:"; for i in "${!Ma[@]}"; do echo "$((i+1))) ${Ma[$i]}"; done; echo "$((${#Ma[@]}+1))) Tilbake"; local Mc; while true; do read -r -p "Velg (1-$((${#Ma[@]}+1))): " Mc </dev/tty; if [[ "$Mc" =~ ^[0-9]+$ && "$Mc" -ge 1 && "$Mc" -le $((${#Ma[@]}+1)) ]]; then break; fi; done; if [ "$Mc" -eq $((${#Ma[@]}+1)) ]; then break; fi; local Sd="${Ma[$((Mc-1))]}";
                while true; do clear; local Csdu="${MD_SERVER_BASE_URL}${Sd}"; echo "--Filer i $Csdu--"; local Flo; Flo=$(md_get_links_from_url "$Csdu"); local Flf; Flf=$(echo "$Flo" | grep -v '/$'); local Faf=(); if [ -n "$Flf" ]; then while IFS= read -r l; do Faf+=("$l"); done <<< "$Flf"; fi; if [ ${#Faf[@]} -eq 0 ]; then log_warn "Ingen filer."; else echo "Filer:"; for i in "${!Faf[@]}"; do echo "$((i+1))) ${Faf[$i]}"; done; fi; echo "$((${#Faf[@]}+1))) Tilbake"; local Fc_val; while true; do read -r -p "Velg (1-$((${#Faf[@]}+1))): " Fc_val </dev/tty; if [[ "$Fc_val" =~ ^[0-9]+$ && "$Fc_val" -ge 1 && "$Fc_val" -le $((${#Faf[@]}+1)) ]; then break; fi; done; if [ "$Fc_val" -eq $((${#Faf[@]}+1)) ]; then break; fi; local Sfn="${Faf[$((Fc_val-1))]}"; local Suf="$Csdu$Sfn"; local Tpf="$MD_COMFYUI_BASE_MODELS_PATH/$Sd$Sfn"; if [ -f "$Tpf" ]; then read -r -p "Finnes. Overskriv? (j/n):" Of </dev/tty; if [[ ! "$Of" =~ ^[Jj]$ ]]; then log_info "Hopper over."; continue; fi; fi; md_download_file "$Suf" "$Tpf"; read -r -p "Annen fil fra '$Sd'? (J/n): " Anf </dev/tty; Anf=${Anf:-j}; if [[ "$Anf" =~ ^[Nn]$ ]]; then break; fi; done;
                read -r -p "Annen mappe? (J/n): " Anm </dev/tty; Anm=${Anm:-j}; if [[ "$Anm" =~ ^[Nn]$ ]]; then break; fi; done ;;
            2) clear; echo "--Last ned alle manglende--"; read -r -p "Sikker? (j/n): " Ca </dev/tty; if [[ ! "$Ca" =~ ^[Jj]$ ]]; then log_info "Avbrutt."; continue; fi; local Mall_o; Mall_o=$(md_get_links_from_url "$MD_SERVER_BASE_URL"); local Mall; Mall=$(echo "$Mall_o" | grep '/$'); if [ -z "$Mall" ]; then log_warn "Ingen mapper."; else local Maa=(); while IFS= read -r l; do Maa+=("$l"); done <<< "$Mall"; for Csa in "${Maa[@]}"; do log_info "Sjekker: $Csa"; local Foa; Foa=$(md_get_links_from_url "$MD_SERVER_BASE_URL$Csa"); local Ffa; Ffa=$(echo "$Foa" | grep -v '/$'); if [ -z "$Ffa" ]; then log_info " Ingen filer."; continue; fi; local Fada=(); while IFS= read -r l; do Fada+=("$l"); done <<< "$Ffa"; for Cfna in "${Fada[@]}"; do local Tpa="$MD_COMFYUI_BASE_MODELS_PATH/$Csa$Cfna"; if [ -f "$Tpa" ]; then echo "  Skipper: '$(basename "$Tpa")'"; else md_download_file "$MD_SERVER_BASE_URL$Csa$Cfna" "$Tpa"; fi; done; done; fi; log_success "Alle ferdig."; press_enter_to_continue ;;
            3) md_handle_package_download ;;
            4) MD_COMFYUI_PATH=""; MD_COMFYUI_BASE_MODELS_PATH=""; if ! md_find_and_select_comfyui_path ""; then log_error "Kunne ikke sette ny sti."; fi; press_enter_to_continue ;;
            5) break ;;
            *) log_warn "Ugyldig." ;;
        esac; done; }

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
