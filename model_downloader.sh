#!/bin/bash

# Source common utilities
# Assuming common_utils.sh is in the same directory
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source."; exit 1; }

script_log "INFO: model_downloader.sh sourced."

# --- Model Downloader (MD) Specific Globals & Constants ---
MD_SERVER_BASE_URL="http://192.168.1.29:8081/models/" # Example, can be overridden by main script if needed
MD_PACKAGES_JSON_URL="http://192.168.1.29:8081/packages.json" # Example
MD_DEFAULT_COMFYUI_PATH_FALLBACK="$HOME/comfyui_docker_data" # Example
MD_ADDITIONAL_COMFYUI_PATHS_FALLBACK=("/home/octa/AI/ComfyUI/") # Example

# Stier for modelldownloader (will be set by md_find_and_select_comfyui_path)
MD_COMFYUI_PATH=""
MD_COMFYUI_BASE_MODELS_PATH=""

# --- Model Downloader Funksjoner ---

md_check_jq() {
    script_log "DEBUG: ENTERING md_check_jq (model_downloader.sh)"
    if ! command -v jq &> /dev/null; then
        log_error "'jq' er ikke funnet. Dette kreves for modelldenedlasting."
        log_error "Installer med: sudo apt update && sudo apt install jq"
        script_log "DEBUG: EXITING md_check_jq (jq not found)"
        return 1
    fi
    script_log "DEBUG: EXITING md_check_jq (success)"
    return 0
}

md_find_and_select_comfyui_path() {
    script_log "DEBUG: ENTERING md_find_and_select_comfyui_path (model_downloader.sh)"
    local pre_selected_path_base="$1"
    local found_paths=()
    log_info "Søker etter ComfyUI-installasjoner for modelldenedlasting..."

    # Check pre_selected_path_base (typically DOCKER_DATA_ACTUAL_PATH from docker_setup.sh)
    if [[ -n "$pre_selected_path_base" ]] && [[ -d "$pre_selected_path_base/models" ]]; then
        log_info "Bruker forhåndsvalgt sti: $pre_selected_path_base"
        MD_COMFYUI_PATH="${pre_selected_path_base%/}"
        MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
        local use_preselected # Renamed
        echo -n "Vil du bruke denne stien ($MD_COMFYUI_PATH) for modeller, eller velge en annen? (Bruk denne/Velg annen) [B]: " >&2
        read -r use_preselected </dev/tty
        use_preselected=${use_preselected:-B}
        if [[ "$use_preselected" =~ ^[Vv]$ ]]; then
            MD_COMFYUI_PATH=""
            MD_COMFYUI_BASE_MODELS_PATH=""
            log_info "Lar deg velge sti manuelt."
        else
            log_success "Bruker $MD_COMFYUI_PATH for modelldenedlasting."
            script_log "DEBUG: EXITING md_find_and_select_comfyui_path (used pre_selected_path_base)"
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

    local search_locations=("$HOME" "/mnt" "/opt" "/srv") # BASE_DOCKER_SETUP_DIR could also be added here if relevant
    # Add BASE_DOCKER_SETUP_DIR/COMFYUI_DATA_DIR_NAME if it's a likely candidate and variables are available
    # For now, keeping search locations as they were.

    for loc in "${search_locations[@]}"; do
        mapfile -t -d $'\0' current_finds < <(find "$loc" -maxdepth 4 -type d \( -name "ComfyUI" -o -name "comfyui_data" -o -name "comfyui_unified_setup" \) -print0 2>/dev/null)
        for path_found in "${current_finds[@]}"; do
            local normalized_path="${path_found%/}"
            # Check for 'models' subdirectory
            if [[ -d "$normalized_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            # Special check for a path like BASE_DOCKER_SETUP_DIR/COMFYUI_DATA_DIR_NAME which itself is the data dir
            elif [[ -n "${BASE_DOCKER_SETUP_DIR:-}" && -n "${COMFYUI_DATA_DIR_NAME:-}" && \
                    "$normalized_path" == "$BASE_DOCKER_SETUP_DIR/$COMFYUI_DATA_DIR_NAME" && \
                    -d "$normalized_path/models" ]]; then
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
        local choice_val # Renamed
        while true; do
            local default_choice_prompt_val="1"; if [ ${#found_paths[@]} -eq 0 ]; then default_choice_prompt_val="$((${#found_paths[@]}+1))"; fi
            echo -n "Velg en sti (1-$((${#found_paths[@]}+1))), Enter for $default_choice_prompt_val): " >&2
            read -r choice_val </dev/tty
            choice_val="${choice_val:-$default_choice_prompt_val}"
            if [[ "$choice_val" =~ ^[0-9]+$ ]] && [ "$choice_val" -ge 1 ] && [ "$choice_val" -le $((${#found_paths[@]}+1)) ]; then break; else log_warn "Ugyldig valg."; fi
        done
        if [ "$choice_val" -le ${#found_paths[@]} ]; then MD_COMFYUI_PATH="${found_paths[$((choice_val-1))]}"; fi
    fi

    while [[ -z "$MD_COMFYUI_PATH" ]]; do
        echo -n "Oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " >&2
        read -r -e manual_path </dev/tty # Added -e for readline editing
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
        script_log "DEBUG: EXITING md_find_and_select_comfyui_path (base models path not found)"
        return 1
    fi
    log_success "Bruker '$MD_COMFYUI_BASE_MODELS_PATH' for modeller."
    script_log "DEBUG: EXITING md_find_and_select_comfyui_path (success)"
    return 0
}

md_get_links_from_url() {
    script_log "DEBUG: ENTERING md_get_links_from_url (model_downloader.sh) for URL: $1"
    local url="$1"
    # Added timeout and error resilience for curl
    curl --connect-timeout 10 -s -L -f "$url" 2>/dev/null | \
    grep -o '<a href="[^"]*"' | sed 's/<a href="//;s/"//' | \
    grep -v '^$' | \
    grep -E -v '(\.\.\/|Parent Directory|^\?|^\.|apache\.org|速度|名称|修改日期|大小)' || echo ""
    # script_log "DEBUG: EXITING md_get_links_from_url" # Can be too verbose
}

md_download_file() {
    script_log "DEBUG: ENTERING md_download_file (model_downloader.sh)"
    local source_url="$1"; local target_path="$2"; local target_dir; target_dir=$(dirname "$target_path"); local target_filename; target_filename=$(basename "$target_path");
    log_info "Forbereder nedlasting av '$target_filename' fra $source_url til $target_path";
    if [ ! -d "$target_dir" ]; then
      log_warn "Målmappen '$target_dir' eksisterer ikke. Oppretter den...";
      if ! mkdir -p "$target_dir"; then
          log_error "Kunne ikke opprette mappen '$target_dir'. Hopper over.";
          script_log "DEBUG: EXITING md_download_file (failed to create target dir)"
          return 1;
      fi;
    fi;
    # Using wget with options for progress bar, continue, and output to specific file
    if wget -c -O "$target_path" "$source_url" -q --show-progress --progress=bar:force 2>&1; then # stderr is progress
      log_success "Nedlasting av '$target_filename' fullført!";
      if [ -f "$target_path" ]; then
          local filesize; filesize=$(stat -c%s "$target_path");
          if [ "$filesize" -lt 10000 ]; then
              log_warn "Filen '$target_filename' er liten ($filesize bytes). Sjekk om den er korrekt.";
          fi;
      fi;
      script_log "DEBUG: EXITING md_download_file (success)"
      return 0;
    else
      log_error "Nedlasting av '$target_filename' mislyktes.";
      rm -f "$target_path"; # Clean up partial download
      script_log "DEBUG: EXITING md_download_file (wget failed)"
      return 1;
    fi;
}

md_handle_package_download() {
    script_log "DEBUG: ENTERING md_handle_package_download (model_downloader.sh)"
    clear; echo "--- Last ned Modellpakke ---"; log_info "Henter pakkedefinisjoner fra $MD_PACKAGES_JSON_URL...";
    local packages_json; packages_json=$(curl --connect-timeout 10 -s -L -f "$MD_PACKAGES_JSON_URL"); local curl_exit_code=$?;
    if [ $curl_exit_code -ne 0 ]; then
        log_error "Kunne ikke hente pakkedefinisjoner (curl exit code: $curl_exit_code).";
        press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (curl failed)"
        return 1;
    fi;
    if ! echo "$packages_json" | jq -e . > /dev/null 2>&1; then
        log_error "Pakkedefinisjonsfil er ikke gyldig JSON.";
        press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (invalid JSON)"
        return 1;
    fi;

    mapfile -t package_display_names < <(echo "$packages_json" | jq -r '.packages[].displayName');
    if [ ${#package_display_names[@]} -eq 0 ]; then
        log_warn "Ingen modellpakker funnet i JSON-data.";
        press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (no packages found)"
        return 0;
    fi;

    echo "Tilgjengelige modellpakker:";
    for i in "${!package_display_names[@]}"; do echo "  $((i+1))) ${package_display_names[$i]}"; done;
    echo "  $((${#package_display_names[@]}+1))) Tilbake";

    local package_choice_idx;
    while true; do
        echo -n "Velg en pakke (1-$((${#package_display_names[@]}+1))): " >&2
        read -r package_choice_idx </dev/tty;
        if [[ "$package_choice_idx" =~ ^[0-9]+$ && "$package_choice_idx" -ge 1 && "$package_choice_idx" -le $((${#package_display_names[@]}+1)) ]]; then break;
        else log_warn "Ugyldig valg."; fi;
    done;

    if [ "$package_choice_idx" -eq $((${#package_display_names[@]}+1)) ]; then
        script_log "DEBUG: EXITING md_handle_package_download (user chose back)"
        return 0;
    fi;

    local selected_package_index=$((package_choice_idx - 1));
    local selected_package_display_name="${package_display_names[$selected_package_index]}";
    mapfile -t package_files_to_download < <(echo "$packages_json" | jq -r --argjson idx "$selected_package_index" '.packages[$idx].files[]');

    if [ ${#package_files_to_download[@]} -eq 0 ]; then
        log_warn "Ingen filer definert for pakken '$selected_package_display_name'.";
        press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (no files for package)"
        return 0;
    fi;

    log_info "Laster ned pakke: $selected_package_display_name";
    echo "Filer:";
    for file_rel_path in "${package_files_to_download[@]}"; do echo "  - $file_rel_path"; done;

    local confirm_download # Renamed
    echo -n "Fortsett? (ja/nei): " >&2
    read -r confirm_download </dev/tty;
    if [[ ! "$confirm_download" =~ ^[Jj][Aa]$ ]]; then
        log_info "Avbrutt."; press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (user aborted download)"
        return 0;
    fi;

    local dl_c=0 skip_c=0 fail_c=0;
    for file_relative_path in "${package_files_to_download[@]}"; do
        local source_url="${MD_SERVER_BASE_URL}${file_relative_path}";
        local target_path_locally="${MD_COMFYUI_BASE_MODELS_PATH}/${file_relative_path}";
        local target_filename; target_filename=$(basename "$file_relative_path");

        if [ -f "$target_path_locally" ]; then
            log_warn "Filen '$target_filename' finnes.";
            local overwrite_choice_pkg;
            echo -n "Overskriv? (ja/Nei): " >&2
            read -r overwrite_choice_pkg </dev/tty;
            overwrite_choice_pkg=${overwrite_choice_pkg:-N};
            if [[ ! "$overwrite_choice_pkg" =~ ^[Jj][Aa]$ ]]; then
                log_info "Skipper '$target_filename'."; skip_c=$((skip_c+1)); continue;
            fi;
        fi;
        if md_download_file "$source_url" "$target_path_locally"; then
            dl_c=$((dl_c+1));
        else
            fail_c=$((fail_c+1));
        fi;
    done;
    echo ""; log_success "Pakke '$selected_package_display_name' ferdig.";
    if [ "$dl_c" -gt 0 ]; then log_info "$dl_c fil(er) lastet ned."; fi;
    if [ "$skip_c" -gt 0 ]; then log_info "$skip_c fil(er) hoppet over."; fi;
    if [ "$fail_c" -gt 0 ]; then log_warn "$fail_c fil(er) feilet."; fi;
    press_enter_to_continue;
    script_log "DEBUG: EXITING md_handle_package_download (package download process finished)"
}

run_model_downloader() {
    script_log "DEBUG: ENTERING run_model_downloader (model_downloader.sh)"
    local preselected_path_for_data_dir="$1" # This is DOCKER_DATA_ACTUAL_PATH from main script

    if ! md_check_jq; then press_enter_to_continue; script_log "DEBUG: EXITING run_model_downloader (jq check failed)"; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then
        log_error "Kan ikke sette ComfyUI models-sti.";
        press_enter_to_continue;
        script_log "DEBUG: EXITING run_model_downloader (find_and_select_path failed)";
        return 1;
    fi

    local md_choice_val; # Renamed
    while true; do
        clear;
        echo "--- Modelldenedlastingsverktøy ---";
        echo "Bruker models-mappe: $MD_COMFYUI_BASE_MODELS_PATH";
        echo "Modellserver: $MD_SERVER_BASE_URL";
        echo "----------------------------------";
        echo "1) Utforsk mapper og last ned enkeltfiler";
        echo "2) Last ned alle manglende modeller (basert på serverstruktur)";
        echo "3) Last ned forhåndsdefinert pakke (fra packages.json)";
        echo "4) Bytt ComfyUI models-mappe";
        echo "5) Tilbake til hovedmeny";
        echo -n "Velg (1-5): " >&2
        read -r md_choice_val </dev/tty;

        case "$md_choice_val" in
            1) # Utforsk og last ned enkeltfiler
                local map_choice_val_explore; # Renamed
                while true; do
                    clear;
                    echo "--- Utforsker mapper på $MD_SERVER_BASE_URL ---";
                    local map_links_output_val_explore; map_links_output_val_explore=$(md_get_links_from_url "$MD_SERVER_BASE_URL");
                    local map_links_val_explore; map_links_val_explore=$(echo "$map_links_output_val_explore" | grep '/$');

                    if [ -z "$map_links_val_explore" ]; then log_warn "Fant ingen undermapper på serveren."; sleep 1; break; fi;

                    local map_array_val_explore=();
                    while IFS= read -r line; do map_array_val_explore+=("$line"); done <<< "$map_links_val_explore";
                    local num_maps_val_explore=${#map_array_val_explore[@]};

                    echo "Tilgjengelige mapper på server:";
                    for i in "${!map_array_val_explore[@]}"; do echo "  $((i+1))) ${map_array_val_explore[$i]}"; done;
                    echo "  $((num_maps_val_explore+1))) Tilbake";

                    while true; do
                        echo -n "Velg mappe (1-$((num_maps_val_explore+1))): " >&2
                        read -r map_choice_val_explore </dev/tty;
                        if [[ "$map_choice_val_explore" =~ ^[0-9]+$ && "$map_choice_val_explore" -ge 1 && "$map_choice_val_explore" -le "$((num_maps_val_explore+1))" ]]; then break;
                        else log_warn "Ugyldig valg."; fi;
                    done;

                    if [ "$map_choice_val_explore" -eq "$((num_maps_val_explore+1))" ]; then break; fi;

                    local selected_server_subdir_val_explore="${map_array_val_explore[$((map_choice_val_explore-1))]}";
                    local file_choice_val_explore; # Renamed

                    while true; do
                        clear;
                        local current_server_dir_url_val_explore="${MD_SERVER_BASE_URL}${selected_server_subdir_val_explore}";
                        echo "--- Filer i servermappe: $current_server_dir_url_val_explore ---";
                        local file_links_output_val_explore; file_links_output_val_explore=$(md_get_links_from_url "$current_server_dir_url_val_explore");
                        local file_links_f_val_explore; file_links_f_val_explore=$(echo "$file_links_output_val_explore" | grep -v '/$');

                        local file_array_f_val_explore=();
                        if [ -n "$file_links_f_val_explore" ]; then
                            while IFS= read -r line; do file_array_f_val_explore+=("$line"); done <<< "$file_links_f_val_explore";
                        fi;
                        local num_files_val_explore=${#file_array_f_val_explore[@]};

                        if [ $num_files_val_explore -eq 0 ]; then
                            log_warn "Ingen filer i servermappen '$selected_server_subdir_val_explore'.";
                        else
                            echo "Filer på server:";
                            for i in "${!file_array_f_val_explore[@]}"; do echo "  $((i+1))) ${file_array_f_val_explore[$i]}"; done;
                        fi;
                        echo "  $((num_files_val_explore+1))) Tilbake (til mappevalg)";

                        while true; do
                            echo -n "Velg fil for nedlasting (1-$((num_files_val_explore+1))): " >&2
                            read -r file_choice_val_explore </dev/tty;
                            if [[ "$file_choice_val_explore" =~ ^[0-9]+$ && "$file_choice_val_explore" -ge 1 && "$file_choice_val_explore" -le "$((num_files_val_explore+1))" ]]; then break;
                            else log_warn "Ugyldig valg."; fi;
                        done;

                        if [ "$file_choice_val_explore" -eq "$((num_files_val_explore+1))" ]; then break; fi;

                        local selected_filename_val_explore="${file_array_f_val_explore[$((file_choice_val_explore-1))]}";
                        local source_url_f_val_explore="$current_server_dir_url_val_explore$selected_filename_val_explore";
                        # Ensure target path is correctly formed, including the subdir from server
                        local target_path_f_val_explore="$MD_COMFYUI_BASE_MODELS_PATH/$selected_server_subdir_val_explore$selected_filename_val_explore";

                        if [ -f "$target_path_f_val_explore" ]; then
                            log_warn "Fil '$selected_filename_val_explore' finnes allerede lokalt.";
                            local ovw_f_explore; # Renamed
                            echo -n "Overskriv? (ja/nei): " >&2
                            read -r ovw_f_explore </dev/tty;
                            if [[ ! "$ovw_f_explore" =~ ^[Jj]$ ]]; then
                                log_info "Skipper nedlasting.";
                                local another_f_same_dir_explore; # Renamed
                                echo -n "Last ned en annen fil fra '$selected_server_subdir_val_explore'? (Ja/nei): " >&2
                                read -r another_f_same_dir_explore </dev/tty;
                                another_f_same_dir_explore=${another_f_same_dir_explore:-J};
                                if [[ "$another_f_same_dir_explore" =~ ^[Nn]$ ]]; then break; fi;
                                continue;
                            fi;
                        fi;
                        md_download_file "$source_url_f_val_explore" "$target_path_f_val_explore";

                        local another_f_val_explore; # Renamed
                        echo -n "Last ned en annen fil fra '$selected_server_subdir_val_explore'? (Ja/nei): " >&2
                        read -r another_f_val_explore </dev/tty;
                        another_f_val_explore=${another_f_val_explore:-J};
                        if [[ "$another_f_val_explore" =~ ^[Nn]$ ]]; then break; fi;
                    done; # End of file selection loop for a chosen subdir

                    local another_m_val_explore; # Renamed
                    echo -n "Velg en annen mappe for å utforske? (Ja/nei): " >&2
                    read -r another_m_val_explore </dev/tty;
                    another_m_val_explore=${another_m_val_explore:-J};
                    if [[ "$another_m_val_explore" =~ ^[Nn]$ ]]; then break; fi;
                done ;; # End of main explore loop (map_choice_val_explore)
            2) # Last ned alle manglende
                clear; echo "--- Last ned alle manglende modeller (sammenligner med serverstruktur) ---";
                echo -e "${YELLOW}ADVARSEL:${NC} Dette vil forsøke å laste ned filer fra alle undermapper på serveren"
                echo "til korresponderende undermapper i din lokale '$MD_COMFYUI_BASE_MODELS_PATH'."
                echo "Den sjekker kun om filnavnet eksisterer; den sjekker IKKE filstørrelser eller innhold."
                local confirm_all_val_missing; # Renamed
                echo -n "Er du sikker på at du vil fortsette? (ja/nei): " >&2
                read -r confirm_all_val_missing </dev/tty;
                if [[ ! "$confirm_all_val_missing" =~ ^[Jj]$ ]]; then
                    log_info "Avbrutt."; press_enter_to_continue; continue;
                fi;

                local map_links_all_o_val_missing; map_links_all_o_val_missing=$(md_get_links_from_url "$MD_SERVER_BASE_URL");
                local map_links_all_val_missing; map_links_all_val_missing=$(echo "$map_links_all_o_val_missing" | grep '/$');

                if [ -z "$map_links_all_val_missing" ]; then
                    log_warn "Fant ingen undermapper på serveren å sjekke.";
                else
                    local map_array_all_val_missing=();
                    while IFS= read -r line; do map_array_all_val_missing+=("$line"); done <<< "$map_links_all_val_missing";

                    for cur_subdir_all_val_missing in "${map_array_all_val_missing[@]}"; do
                        echo ""; log_info "Sjekker servermappe: $cur_subdir_all_val_missing";
                        local cur_srv_dir_all_val_missing="${MD_SERVER_BASE_URL}${cur_subdir_all_val_missing}";

                        local file_links_o_all_f_missing; file_links_o_all_f_missing=$(md_get_links_from_url "$cur_srv_dir_all_val_missing");
                        local file_links_all_f_missing; file_links_all_f_missing=$(echo "$file_links_o_all_f_missing" | grep -v '/$');

                        if [ -z "$file_links_all_f_missing" ]; then
                            log_info "  Ingen filer funnet i denne servermappen."; continue;
                        fi;

                        # Ensure local subdirectory exists before trying to download into it
                        local local_target_subdir="$MD_COMFYUI_BASE_MODELS_PATH/$cur_subdir_all_val_missing"
                        if [ ! -d "$local_target_subdir" ]; then
                            log_info "  Lokal mappe '$local_target_subdir' ikke funnet, oppretter den..."
                            mkdir -p "$local_target_subdir" || {
                                log_error "  Kunne ikke opprette '$local_target_subdir', hopper over denne mappen."
                                continue
                            }
                        fi

                        local file_arr_dl_all_missing=();
                        while IFS= read -r line; do file_arr_dl_all_missing+=("$line"); done <<< "$file_links_all_f_missing";

                        for cur_fname_all_val_missing in "${file_arr_dl_all_missing[@]}"; do
                            local target_path_all_val_missing="$MD_COMFYUI_BASE_MODELS_PATH/$cur_subdir_all_val_missing$cur_fname_all_val_missing";
                            local source_url_all_val_missing="$cur_srv_dir_all_val_missing$cur_fname_all_val_missing";
                            if [ -f "$target_path_all_val_missing" ]; then
                                echo "  Skipper: '$cur_fname_all_val_missing' finnes allerede lokalt.";
                            else
                                md_download_file "$source_url_all_val_missing" "$target_path_all_val_missing";
                            fi;
                        done;
                    done;
                    log_success "Automatisk nedlasting av manglende filer (basert på serverstruktur) er fullført.";
                fi;
                press_enter_to_continue ;;
            3) md_handle_package_download ;; # This function is already part of this script
            4)
                MD_COMFYUI_PATH=""; MD_COMFYUI_BASE_MODELS_PATH=""; # Clear current paths
                if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then # Pass original preselected_path again
                    log_error "Kunne ikke sette ny ComfyUI models-sti.";
                fi;
                press_enter_to_continue ;;
            5)
                script_log "DEBUG: EXITING run_model_downloader (user chose back to main menu)"
                break ;; # Exit while loop, returning to main menu
            *) log_warn "Ugyldig valg. Skriv inn et tall fra 1-5." ;;
        esac
    done
    script_log "DEBUG: run_model_downloader loop finished."
}

script_log "DEBUG: model_downloader.sh execution finished its own content."
