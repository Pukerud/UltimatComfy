#!/bin/bash

# Source common utilities
# Assuming common_utils.sh is in the same directory
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source."; exit 1; }

script_log "INFO: model_downloader.sh sourced."

# --- Model Downloader (MD) Specific Globals & Constants ---
MD_SERVER_BASE_URL="http://192.168.1.29:8081/Auto/Models/" # Example, can be overridden by main script if needed
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
        # OS_TYPE is sourced from common_utils.sh in the main script
        if [[ "$OS_TYPE" == "linux" ]]; then
            log_error "Installer med: sudo apt update && sudo apt install jq"
        elif [[ "$OS_TYPE" == "windows" ]]; then
            log_error "Installer 'jq' for Windows. For eksempel med Chocolatey: choco install jq"
            log_error "Eller last ned fra: https://jqlang.github.io/jq/download/"
        else
            log_error "Vennligst installer 'jq' for ditt operativsystem."
        fi
        script_log "DEBUG: EXITING md_check_jq (jq not found)"
        return 1
    fi
    script_log "DEBUG: EXITING md_check_jq (success)"
    return 0
}

md_find_and_select_comfyui_path() {
    script_log "DEBUG: ENTERING md_find_and_select_comfyui_path (model_downloader.sh)"
    ensure_dialog_installed
    local find_path_dialog_available=$?
    script_log "DEBUG: md_find_and_select_comfyui_path - find_path_dialog_available: $find_path_dialog_available"

    local pre_selected_path_base="$1"
    local found_paths=()

    if [[ -n "$pre_selected_path_base" ]] && [[ -d "$pre_selected_path_base/models" ]]; then
        log_info "Bruker forhåndsvalgt sti: $pre_selected_path_base"
        MD_COMFYUI_PATH="${pre_selected_path_base%/}"
        MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
        local use_this_preselected_path=true
        if [ "$find_path_dialog_available" -eq 0 ]; then
            if ! dialog --title "Bekreft Sti" --yesno "En ComfyUI data-sti ble funnet/passert:\n$MD_COMFYUI_PATH\n\nVil du bruke denne stien for modeller, eller velge/angi en annen?" 10 70 2>/dev/tty; then
                use_this_preselected_path=false
            fi
        else
            local use_preselected_text
            echo -n "Vil du bruke denne stien ($MD_COMFYUI_PATH) for modeller, eller velge en annen? (Bruk denne/Velg annen) [B]: " >&2
            read -r use_preselected_text </dev/tty
            use_preselected_text=${use_preselected_text:-B}
            if [[ "$use_preselected_text" =~ ^[Vv]$ ]]; then
                use_this_preselected_path=false
            fi
        fi

        if $use_this_preselected_path; then
            log_success "Bruker $MD_COMFYUI_PATH for modelldenedlasting."
            script_log "DEBUG: EXITING md_find_and_select_comfyui_path (used pre_selected_path_base)"
            return 0
        else
            MD_COMFYUI_PATH=""
            MD_COMFYUI_BASE_MODELS_PATH=""
            log_info "Lar deg velge/angi sti manuelt nedenfor."
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
    if [[ "$OS_TYPE" == "windows" ]]; then
        # Add common drive letters for Windows environments (as seen by Git Bash)
        search_locations+=("/c/" "/d/")
    fi
    if [[ -n "${BASE_DOCKER_SETUP_DIR:-}" && -d "$BASE_DOCKER_SETUP_DIR" ]]; then
        search_locations+=("$BASE_DOCKER_SETUP_DIR")
    fi
    # COMFYUI_DATA_DIR_NAME is defined in docker_setup.sh, sourced by UltimateComfy.sh
    for loc in "${search_locations[@]}"; do
        mapfile -t -d $'\0' current_finds < <(find "$loc" -maxdepth 4 -type d \( -name "ComfyUI" -o -name "comfyui_data" -o -name "comfyui_unified_setup" -o -name "ComfyUI_Docker_Data" -o -name "$COMFYUI_DATA_DIR_NAME" \) -print0 2>/dev/null)
        for path_found in "${current_finds[@]}"; do
            local normalized_path="${path_found%/}"
            if [[ -d "$normalized_path/models" ]]; then
                if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$normalized_path"; then
                    found_paths+=("$normalized_path")
                fi
            elif [[ -n "${COMFYUI_DATA_DIR_NAME:-}" && "$normalized_path" == "$BASE_DOCKER_SETUP_DIR" && -d "$normalized_path/$COMFYUI_DATA_DIR_NAME/models" ]]; then
                 # Special case for BASE_DOCKER_SETUP_DIR containing COMFYUI_DATA_DIR_NAME
                 local potential_data_path="$normalized_path/$COMFYUI_DATA_DIR_NAME"
                 if ! printf '%s\0' "${found_paths[@]}" | grep -Fxqz -- "$potential_data_path"; then
                    found_paths+=("$potential_data_path")
                fi
            fi
        done
    done


    local manual_path_input_required=true
    if [ ${#found_paths[@]} -gt 0 ]; then
        manual_path_input_required=false
        if [ "$find_path_dialog_available" -eq 0 ]; then
            local dialog_path_items=()
            local path_idx=1
            for path_item in "${found_paths[@]}"; do
                dialog_path_items+=("$path_idx" "$path_item")
                path_idx=$((path_idx + 1))
            done
            dialog_path_items+=("MANUAL" "Angi sti manuelt")

            local path_choice_tag
            path_choice_tag=$(dialog --clear --stdout --title "Velg ComfyUI Data Sti" --menu "Følgende potensielle ComfyUI data-stier ble funnet (de må inneholde en 'models'-undermappe).\nVelg en sti eller angi manuelt:" 20 76 15 "${dialog_path_items[@]}" "CANCEL" "Avbryt valget" 2>/dev/tty)
            local path_dialog_exit_status=$?

            if [ $path_dialog_exit_status -ne 0 ] || [ "$path_choice_tag" == "CANCEL" ]; then
                log_warn "Valg av sti avbrutt."
                script_log "DEBUG: EXITING md_find_and_select_comfyui_path (path selection cancelled)"
                return 1
            fi

            if [ "$path_choice_tag" == "MANUAL" ]; then
                manual_path_input_required=true
            else
                MD_COMFYUI_PATH="${found_paths[$((path_choice_tag-1))]}"
            fi
        else
            log_info "Følgende potensielle ComfyUI data-stier ble funnet:"
            for i in "${!found_paths[@]}"; do echo "  $((i+1))) ${found_paths[$i]}"; done
            echo "  $((${#found_paths[@]}+1))) Angi sti manuelt"
            local choice_val_text
            while true; do
                local default_choice_prompt_val="1"
                echo -n "Velg en sti (1-$((${#found_paths[@]}+1))), Enter for $default_choice_prompt_val): " >&2
                read -r choice_val_text </dev/tty
                choice_val_text="${choice_val_text:-$default_choice_prompt_val}"
                if [[ "$choice_val_text" =~ ^[0-9]+$ ]] && [ "$choice_val_text" -ge 1 ] && [ "$choice_val_text" -le $((${#found_paths[@]}+1)) ]; then break
                else log_warn "Ugyldig valg."; fi
            done
            if [ "$choice_val_text" -le ${#found_paths[@]} ]; then
                MD_COMFYUI_PATH="${found_paths[$((choice_val_text-1))]}"
            else
                manual_path_input_required=true
            fi
        fi
    fi

    if $manual_path_input_required; then
        MD_COMFYUI_PATH=""
        while [[ -z "$MD_COMFYUI_PATH" ]]; do
            local manual_path_val=""
            if [ "$find_path_dialog_available" -eq 0 ]; then
                manual_path_val=$(dialog --clear --stdout --title "Manuell Sti" --inputbox "Oppgi full sti til din ComfyUI data mappe (mappen som inneholder en 'models' undermappe):" 10 70 "" 2>/dev/tty)
                local input_exit_status=$?
                if [ $input_exit_status -ne 0 ]; then
                    log_warn "Manuell inntasting av sti avbrutt."
                    script_log "DEBUG: EXITING md_find_and_select_comfyui_path (manual path input cancelled)"
                    return 1
                fi
            else
                echo -n "Oppgi full sti til din ComfyUI data mappe (den som inneholder 'models'): " >&2
                read -r -e manual_path_val </dev/tty
            fi

            manual_path_val="${manual_path_val%/}"
            if [[ -d "$manual_path_val" ]] && [[ -d "$manual_path_val/models" ]]; then
                MD_COMFYUI_PATH="$manual_path_val"
            else
                local error_msg="Stien '$manual_path_val' er ugyldig eller mangler 'models'-undermappe. Prøv igjen."
                if [ "$find_path_dialog_available" -eq 0 ]; then
                    dialog --title "Feil Sti" --msgbox "$error_msg" 8 70 2>/dev/tty
                else
                    log_error "$error_msg"
                fi
            fi
        done
    fi

    if [[ -z "$MD_COMFYUI_PATH" ]]; then
        log_error "Ingen ComfyUI-sti ble satt."
        script_log "DEBUG: EXITING md_find_and_select_comfyui_path (no path was ultimately set)"
        return 1
    fi

    MD_COMFYUI_BASE_MODELS_PATH="$MD_COMFYUI_PATH/models"
    if [ ! -d "$MD_COMFYUI_BASE_MODELS_PATH" ]; then
        log_error "FEIL: Mappen '$MD_COMFYUI_BASE_MODELS_PATH' ble ikke funnet etter stivalg!"
        script_log "DEBUG: EXITING md_find_and_select_comfyui_path (base models path not found after selection)"
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

md_download_folder_recursive() {
    local source_url_base="$1"
    local local_target_base="$2"

    script_log "DEBUG: ENTERING md_download_folder_recursive for $source_url_base -> $local_target_base"

    # Ensure target directory exists
    if [ ! -d "$local_target_base" ]; then
        if ! mkdir -p "$local_target_base"; then
             log_error "Kunne ikke opprette mappe: $local_target_base"
             return 1
        fi
    fi

    local links
    links=$(md_get_links_from_url "$source_url_base")

    if [ -z "$links" ]; then
        log_warn "Ingen innhold funnet i $source_url_base"
        return 0
    fi

    # Iterate over links
    while IFS= read -r link || [ -n "$link" ]; do
        if [ -z "$link" ]; then continue; fi

        # Check if it is a directory (ends with /)
        if [[ "$link" == */ ]]; then
             # Recurse
             local new_source="$source_url_base$link"
             local new_target="$local_target_base/$link"
             # Remove trailing slash from target for safety/cleanliness
             new_target="${new_target%/}"

             md_download_folder_recursive "$new_source" "$new_target"
        else
             # File
             local file_source="$source_url_base$link"
             local file_target="$local_target_base/$link"

             if [ -f "$file_target" ]; then
                 log_info "Skipper eksisterende fil: $link"
             else
                 md_download_file "$file_source" "$file_target"
             fi
        fi
    done <<< "$links"
}

md_handle_package_download() {
    script_log "DEBUG: ENTERING md_handle_package_download (model_downloader.sh)"
    ensure_dialog_installed # from common_utils.sh
    local pkg_dialog_available=$?
    script_log "DEBUG: md_handle_package_download - pkg_dialog_available: $pkg_dialog_available"

    if [ "$pkg_dialog_available" -ne 0 ]; then clear; fi # Clear only for text mode

    echo "--- Last ned Modellpakke ---"; log_info "Henter pakkedefinisjoner fra $MD_PACKAGES_JSON_URL...";
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
        if [ "$pkg_dialog_available" -eq 0 ]; then
            dialog --title "Modellpakker" --msgbox "Ingen modellpakker funnet i JSON-data." 6 50 2>/dev/tty
        else
            log_warn "Ingen modellpakker funnet i JSON-data.";
            press_enter_to_continue;
        fi
        script_log "DEBUG: EXITING md_handle_package_download (no packages found)"
        return 0;
    fi;

    local selected_package_index
    local package_choice_tag_or_idx

    if [ "$pkg_dialog_available" -eq 0 ]; then
        local dialog_pkg_items=()
        local pkg_idx=1
        for name in "${package_display_names[@]}"; do
            dialog_pkg_items+=("$pkg_idx" "$name")
            pkg_idx=$((pkg_idx + 1))
        done

        package_choice_tag_or_idx=$(dialog --clear --stdout --title "Velg Modellpakke" --menu "Tilgjengelige modellpakker:" 20 76 15 "${dialog_pkg_items[@]}" "BACK" "Tilbake til forrige meny" 2>/dev/tty)
        local pkg_dialog_exit_status=$?

        if [ $pkg_dialog_exit_status -ne 0 ] || [ "$package_choice_tag_or_idx" == "BACK" ]; then
            script_log "DEBUG: EXITING md_handle_package_download (user chose back or cancelled dialog)"
            return 0
        fi
        selected_package_index=$((package_choice_tag_or_idx - 1))
    else
        echo "Tilgjengelige modellpakker:";
        for i in "${!package_display_names[@]}"; do echo "  $((i+1))) ${package_display_names[$i]}"; done;
        echo "  $((${#package_display_names[@]}+1))) Tilbake";
        local package_choice_idx_text;
        while true; do
            echo -n "Velg en pakke (1-$((${#package_display_names[@]}+1))): " >&2
            read -r package_choice_idx_text </dev/tty;
            if [[ "$package_choice_idx_text" =~ ^[0-9]+$ && "$package_choice_idx_text" -ge 1 && "$package_choice_idx_text" -le $((${#package_display_names[@]}+1)) ]]; then break;
            else log_warn "Ugyldig valg."; fi;
        done;
        if [ "$package_choice_idx_text" -eq $((${#package_display_names[@]}+1)) ]; then
            script_log "DEBUG: EXITING md_handle_package_download (user chose back)"
            return 0;
        fi;
        selected_package_index=$((package_choice_idx_text - 1))
    fi

    local selected_package_display_name="${package_display_names[$selected_package_index]}";
    mapfile -t package_files_to_download < <(echo "$packages_json" | jq -r --argjson idx "$selected_package_index" '.packages[$idx].files[]');

    if [ ${#package_files_to_download[@]} -eq 0 ]; then
        if [ "$pkg_dialog_available" -eq 0 ]; then
            dialog --title "Pakkeinnhold" --msgbox "Ingen filer definert for pakken '$selected_package_display_name'." 6 70 2>/dev/tty
        else
            log_warn "Ingen filer definert for pakken '$selected_package_display_name'.";
            press_enter_to_continue;
        fi
        script_log "DEBUG: EXITING md_handle_package_download (no files for package)"
        return 0;
    fi;

    local file_list_str=""
    for file_rel_path in "${package_files_to_download[@]}"; do
        file_list_str+="  - $file_rel_path\n"
    done;

    local proceed_with_download=false
    if [ "$pkg_dialog_available" -eq 0 ]; then
        if dialog --title "Bekreft Nedlasting" --yesno "Laster ned pakke: $selected_package_display_name\n\nFiler:\n${file_list_str}\nFortsett?" 15 70 2>/dev/tty; then
            proceed_with_download=true
        fi
    else
        log_info "Laster ned pakke: $selected_package_display_name";
        echo -e "Filer:\n${file_list_str}"
        local confirm_download_text
        echo -n "Fortsett? (ja/nei): " >&2
        read -r confirm_download_text </dev/tty;
        if [[ "$confirm_download_text" =~ ^[Jj][Aa]$ ]]; then proceed_with_download=true; fi;
    fi

    if ! $proceed_with_download; then
        log_info "Avbrutt."; press_enter_to_continue;
        script_log "DEBUG: EXITING md_handle_package_download (user aborted download confirmation)"
        return 0;
    fi;

    local dl_c=0 skip_c=0 fail_c=0;
    for file_relative_path in "${package_files_to_download[@]}"; do
        local source_url="${MD_SERVER_BASE_URL}${file_relative_path}";
        local target_path_locally="${MD_COMFYUI_BASE_MODELS_PATH}/${file_relative_path}";
        local target_filename; target_filename=$(basename "$file_relative_path");
        local do_actual_download=true

        if [ -f "$target_path_locally" ]; then
            if [ "$pkg_dialog_available" -eq 0 ]; then
                if ! dialog --title "Bekreft Overskriving" --yesno "Filen '$target_filename' finnes allerede.\nSti: $target_path_locally\n\nOverskriv?" 10 70 2>/dev/tty; then
                    log_info "Skipper '$target_filename'."
                    skip_c=$((skip_c+1)); do_actual_download=false
                fi
            else
                log_warn "Filen '$target_filename' finnes.";
                local overwrite_choice_pkg_text;
                echo -n "Overskriv? (ja/Nei) [N]: " >&2
                read -r overwrite_choice_pkg_text </dev/tty;
                overwrite_choice_pkg_text=${overwrite_choice_pkg_text:-N};
                if [[ ! "$overwrite_choice_pkg_text" =~ ^[Jj][Aa]$ ]]; then
                    log_info "Skipper '$target_filename'."; skip_c=$((skip_c+1)); do_actual_download=false
                fi;
            fi
        fi

        if $do_actual_download; then
            if md_download_file "$source_url" "$target_path_locally"; then
                dl_c=$((dl_c+1));
            else
                fail_c=$((fail_c+1));
            fi;
        fi
    done;
    local summary_msg="Pakke '$selected_package_display_name' ferdigbehandlet.\n"
    if [ "$dl_c" -gt 0 ]; then summary_msg+="$dl_c fil(er) lastet ned.\n"; fi;
    if [ "$skip_c" -gt 0 ]; then summary_msg+="$skip_c fil(er) hoppet over.\n"; fi;
    if [ "$fail_c" -gt 0 ]; then summary_msg+="$fail_c fil(er) feilet.\n"; fi;

    if [ "$pkg_dialog_available" -eq 0 ]; then
        dialog --title "Nedlastingssammendrag" --msgbox "$summary_msg" 12 70 2>/dev/tty
    else
        echo ""; log_success "Pakke '$selected_package_display_name' ferdig."
        if [ "$dl_c" -gt 0 ]; then log_info "$dl_c fil(er) lastet ned."; fi;
        if [ "$skip_c" -gt 0 ]; then log_info "$skip_c fil(er) hoppet over."; fi;
        if [ "$fail_c" -gt 0 ]; then log_warn "$fail_c fil(er) feilet."; fi;
    fi
    if [ "$pkg_dialog_available" -ne 0 ]; then
        press_enter_to_continue
    fi
    script_log "DEBUG: EXITING md_handle_package_download (package download process finished)"
}

run_model_downloader() {
    script_log "DEBUG: ENTERING run_model_downloader (model_downloader.sh)"
    local preselected_path_for_data_dir="$1" # This is DOCKER_DATA_ACTUAL_PATH from main script

    ensure_dialog_installed # from common_utils.sh
    local md_dialog_available=$?
    script_log "DEBUG: run_model_downloader - md_dialog_available: $md_dialog_available"

    if ! md_check_jq; then press_enter_to_continue; script_log "DEBUG: EXITING run_model_downloader (jq check failed)"; return 1; fi
    if ! md_find_and_select_comfyui_path "$preselected_path_for_data_dir"; then
        log_error "Kan ikke sette ComfyUI models-sti.";
        press_enter_to_continue;
        script_log "DEBUG: EXITING run_model_downloader (find_and_select_path failed)";
        return 1;
    fi

    local md_choice_val;
    while true; do

        if [ "$md_dialog_available" -eq 0 ]; then
            local dialog_title="Modelldenedlastingsverktøy"
            local dialog_text="Bruker models-mappe: $MD_COMFYUI_BASE_MODELS_PATH\nModellserver: $MD_SERVER_BASE_URL\n----------------------------------"

            md_choice_val=$(dialog --clear --stdout \
                --title "$dialog_title" \
                --ok-label "Velg" \
                --cancel-label "Tilbake" \
                --menu "$dialog_text" \
                20 76 5 \
                "1" "Utforsk mapper og last ned enkeltfiler" \
                "2" "Last ned alle manglende modeller (basert på serverstruktur)" \
                "3" "Last ned forhåndsdefinert pakke (fra packages.json)" \
                "4" "Bytt ComfyUI models-mappe" \
                "5" "Tilbake til hovedmeny" \
                2>/dev/tty)

            local dialog_exit_status=$?
            script_log "DEBUG: run_model_downloader dialog menu choice: '$md_choice_val', Exit status: $dialog_exit_status"
            if [ $dialog_exit_status -ne 0 ]; then
                md_choice_val="5"
            fi
        else
            clear
            echo "--- Modelldenedlastingsverktøy ---"
            echo "Bruker models-mappe: $MD_COMFYUI_BASE_MODELS_PATH"
            echo "Modellserver: $MD_SERVER_BASE_URL"
            echo "----------------------------------"
            echo " (Dialog utility not available or declined, using text menu)"
            echo "1) Utforsk mapper og last ned enkeltfiler"
            echo "2) Last ned alle manglende modeller (basert på serverstruktur)"
            echo "3) Last ned forhåndsdefinert pakke (fra packages.json)"
            echo "4) Bytt ComfyUI models-mappe"
            echo "5) Tilbake til hovedmeny"
            echo -n "Velg (1-5): " >&2
            read -r md_choice_val </dev/tty
            script_log "DEBUG: run_model_downloader text menu choice: '$md_choice_val'"
        fi

        case "$md_choice_val" in
            "1") # Utforsk mapper og last ned enkeltfiler
                script_log "DEBUG: Option 1 selected - Utforsk mapper (Refactored)"
                local current_relative_path=""
                local explore_active=true

                while $explore_active; do
                    local current_url="${MD_SERVER_BASE_URL}${current_relative_path}"
                    script_log "DEBUG: Exploring URL: $current_url"

                    local links_output
                    links_output=$(md_get_links_from_url "$current_url")

                    local menu_items=()
                    local item_map=() # Maps index to actual name (with suffix / for dirs)
                    local item_idx=1

                    if [ -n "$current_relative_path" ]; then
                        menu_items+=("$item_idx" ".. (Gå opp)")
                        item_map+=("..")
                        item_idx=$((item_idx + 1))
                    fi

                    local dirs=()
                    local files=()

                    while IFS= read -r link || [ -n "$link" ]; do
                        if [ -z "$link" ]; then continue; fi
                        # Trim carriage return if present (just in case)
                        link="${link//$'\r'/}"
                        if [[ "$link" == */ ]]; then
                            dirs+=("$link")
                        else
                            files+=("$link")
                        fi
                    done <<< "$links_output"

                    for d in "${dirs[@]}"; do
                        menu_items+=("$item_idx" "$d")
                        item_map+=("$d")
                        item_idx=$((item_idx + 1))
                    done

                    for f in "${files[@]}"; do
                        menu_items+=("$item_idx" "$f")
                        item_map+=("$f")
                        item_idx=$((item_idx + 1))
                    done

                    if [ ${#item_map[@]} -eq 0 ]; then
                         log_warn "Mappen er tom."
                    fi

                    local selection_idx=""
                    local selection_name=""

                    if [ "$md_dialog_available" -eq 0 ]; then
                        selection_idx=$(dialog --clear --stdout \
                            --title "Utforsk: /${current_relative_path}" \
                            --menu "Velg en mappe for å gå inn, eller en fil for å laste ned:" \
                            20 76 15 \
                            "${menu_items[@]}" \
                            "EXIT" "Avslutt utforsking" \
                            2>/dev/tty)

                        local ret=$?
                        if [ $ret -ne 0 ] || [ "$selection_idx" == "EXIT" ]; then
                            explore_active=false
                            continue
                        fi
                    else
                         clear
                         echo "--- Utforsk: /${current_relative_path} ---"
                         local i=0
                         for name in "${item_map[@]}"; do
                             i=$((i+1))
                             local display_name="$name"
                             if [ "$name" == ".." ]; then display_name=".. (Gå opp)"; fi
                             echo "$i) $display_name"
                         done
                         echo "$((i+1))) Avslutt utforsking"

                         echo -n "Velg (1-$((i+1))): "
                         read -r selection_idx </dev/tty
                         if [ "$selection_idx" -eq $((i+1)) ]; then
                             explore_active=false
                             continue
                         fi
                    fi

                    if [[ "$selection_idx" =~ ^[0-9]+$ ]] && [ "$selection_idx" -ge 1 ] && [ "$selection_idx" -le ${#item_map[@]} ]; then
                        selection_name="${item_map[$((selection_idx-1))]}"
                    else
                        log_warn "Ugyldig valg."
                        press_enter_to_continue
                        continue
                    fi

                    if [ "$selection_name" == ".." ]; then
                        local tmp="${current_relative_path%/}"
                        local parent="$(dirname "$tmp")"
                        if [ "$parent" == "." ] || [ "$parent" == "/" ]; then
                            current_relative_path=""
                        else
                            current_relative_path="$parent/"
                        fi

                    elif [[ "$selection_name" == */ ]]; then
                         if [ "$md_dialog_available" -eq 0 ]; then
                             local dir_action
                             dir_action=$(dialog --clear --stdout --title "Mappe: $selection_name" \
                                --menu "Hva vil du gjøre med denne mappen?" 12 60 5 \
                                "1" "Gå inn i mappen (Browse)" \
                                "2" "Last ned hele mappen (Rekursivt)" \
                                2>/dev/tty)
                             if [ "$?" -ne 0 ]; then continue; fi

                             if [ "$dir_action" == "1" ]; then
                                 current_relative_path="${current_relative_path}${selection_name}"
                             elif [ "$dir_action" == "2" ]; then
                                 local dl_source="${current_url}${selection_name}"
                                 local dl_target="${MD_COMFYUI_BASE_MODELS_PATH}/${current_relative_path}${selection_name}"
                                 dl_target="${dl_target%/}"

                                 md_download_folder_recursive "$dl_source" "$dl_target"
                                 log_success "Mappe lastet ned."
                                 press_enter_to_continue
                             fi
                         else
                             echo "Mappe: $selection_name"
                             echo "1) Gå inn i mappen (Browse)"
                             echo "2) Last ned hele mappen (Rekursivt)"
                             echo "3) Avbryt"
                             echo -n "Velg: "
                             local dir_action
                             read -r dir_action </dev/tty
                             if [ "$dir_action" == "1" ]; then
                                 current_relative_path="${current_relative_path}${selection_name}"
                             elif [ "$dir_action" == "2" ]; then
                                 local dl_source="${current_url}${selection_name}"
                                 local dl_target="${MD_COMFYUI_BASE_MODELS_PATH}/${current_relative_path}${selection_name}"
                                 dl_target="${dl_target%/}"
                                 md_download_folder_recursive "$dl_source" "$dl_target"
                                 log_success "Mappe lastet ned."
                                 press_enter_to_continue
                             fi
                         fi
                    else
                        local f_source="${current_url}${selection_name}"
                        local f_target="${MD_COMFYUI_BASE_MODELS_PATH}/${current_relative_path}${selection_name}"

                        local do_dl=true
                        if [ -f "$f_target" ]; then
                             local overwrite=true
                             if [ "$md_dialog_available" -eq 0 ]; then
                                 if ! dialog --yesno "Filen finnes allerede:\n$f_target\n\nOverskriv?" 10 60 2>/dev/tty; then
                                     overwrite=false
                                 fi
                             else
                                 echo "Filen finnes: $f_target"
                                 echo -n "Overskriv? (j/n): "
                                 local ov
                                 read -r ov </dev/tty
                                 if [[ ! "$ov" =~ ^[Jj] ]]; then overwrite=false; fi
                             fi
                             if ! $overwrite; then do_dl=false; fi
                        fi

                        if $do_dl; then
                            md_download_file "$f_source" "$f_target"
                            press_enter_to_continue
                        fi
                    fi

                done
                ;;
            2) # Last ned alle manglende
                if [ "$md_dialog_available" -ne 0 ]; then clear; fi

                local confirm_all_val_missing_bool=false
                local warning_text="ADVARSEL: Dette vil forsøke å laste ned filer fra alle undermapper på serveren\ntil korresponderende undermapper i din lokale '$MD_COMFYUI_BASE_MODELS_PATH'.\nDen sjekker kun om filnavnet eksisterer; den sjekker IKKE filstørrelser eller innhold."

                if [ "$md_dialog_available" -eq 0 ]; then
                    if dialog --title "Bekreft Alle Manglende" --yesno "$warning_text\n\nEr du sikker på at du vil fortsette?" 15 70 2>/dev/tty; then
                        confirm_all_val_missing_bool=true
                    fi
                else
                    echo "--- Last ned alle manglende modeller (sammenligner med serverstruktur) ---";
                    echo -e "${YELLOW}${warning_text}${NC}"

                    local confirm_all_val_missing_text
                    echo -n "Er du sikker på at du vil fortsette? (ja/nei): " >&2
                    read -r confirm_all_val_missing_text </dev/tty;
                    if [[ "$confirm_all_val_missing_text" =~ ^[Jj]$ ]]; then
                        confirm_all_val_missing_bool=true
                    fi
                fi

                if ! $confirm_all_val_missing_bool; then
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
                break ;; # Exit while loop
            *)
                if [ "$md_dialog_available" -ne 0 ]; then
                    log_warn "Ugyldig valg. Skriv inn et tall fra 1-5."
                else
                    script_log "WARN: Invalid md_choice_val from dialog or unhandled case: '$md_choice_val'"
                    log_warn "Uventet menyvalg."
                fi
                press_enter_to_continue
                ;;
        esac
    done
    script_log "DEBUG: run_model_downloader loop finished."
}

script_log "DEBUG: model_downloader.sh execution finished its own content."
