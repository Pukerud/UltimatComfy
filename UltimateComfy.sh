#!/bin/bash
# SCRIPT_VERSION_4
# Kombinert skript for ComfyUI Docker Oppsett og Modelldenedlasting - Nå en koordinator.

# --- Argument Parsing and Mode Setup ---
# We parse arguments first to enable headless operation without prompts.
HEADLESS_UPDATE=false
# Preserve original args for potential exec on script restart after update.
ORIGINAL_ARGS=("$@")

# Cannot log here yet as utils are not sourced.
for arg in "${ORIGINAL_ARGS[@]}"; do
  case $arg in
    -update)
      HEADLESS_UPDATE=true
      ;;
    -linux)
      export USER_SELECTED_OS="linux"
      ;;
    -windows)
      export USER_SELECTED_OS="windows"
      ;;
  esac
done


# Global variables for folder sizes
INPUT_SIZE_DISPLAY="N/A"
OUTPUT_SIZE_DISPLAY="N/A"

# Source utility and module scripts
# Assuming they are in the same directory as this script
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source. Exiting."; exit 1; }

# --- OS Selection ---
# Since automatic detection can be unreliable, we ask the user directly.
if [ -z "$USER_SELECTED_OS" ]; then # Check if the variable is already set
    while true; do
        echo "Please select your operating system:"
        echo "1) Windows"
        echo "2) Linux / macOS"
        read -r -p "Enter choice [1-2]: " os_choice
        case $os_choice in
            1)
                export USER_SELECTED_OS="windows"
                break
                ;;
            2)
                export USER_SELECTED_OS="linux"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2."
                ;;
        esac
    done
fi
script_log "INFO: User selected OS: $USER_SELECTED_OS"

# shellcheck source=./docker_setup.sh
source "$(dirname "$0")/docker_setup.sh" || { echo "ERROR: docker_setup.sh not found or failed to source. Exiting."; exit 1; }
# shellcheck source=./model_downloader.sh
source "$(dirname "$0")/model_downloader.sh" || { echo "ERROR: model_downloader.sh not found or failed to source. Exiting."; exit 1; }

# Set the exit trap for the main script
# SCRIPT_LOG_FILE is defined in common_utils.sh
trap 'script_log "INFO: --- UltimateComfy.sh execution finished with exit status $? ---"' EXIT

perform_self_update() {
    local mode="$1" # "headless" or ""
    shift || true   # Consume mode argument, ignore error if no args
    local original_args=("$@") # Store the rest of the original arguments

    _maybe_pause() {
        if [ "$mode" != "headless" ]; then
            press_enter_to_continue
        fi
    }

    script_log "INFO: Attempting self-update (mode: ${mode:-interactive})..."
    local script_path_abs
    script_path_abs=$(readlink -f "$0") # Absolute path to the currently running script
    local script_dir
    script_dir=$(dirname "$script_path_abs")

    if [ ! -d "$script_dir/.git" ]; then
        log_error "FEIL: Dette skriptet ser ikke ut til å være i en Git repository-mappe."
        log_error "Kan ikke oppdatere. Gå til $script_dir og initialiser git eller klon på nytt."
        _maybe_pause
        return
    fi

    # Change to the script's directory to ensure git commands run in the correct context
    cd "$script_dir" || { log_error "FEIL: Kunne ikke bytte til mappen $script_dir"; _maybe_pause; return; }

    log_info "Sjekker for oppdateringer (git fetch)..."
    git fetch || {
        log_error "FEIL: 'git fetch' mislyktes. Sjekk internettforbindelsen og Git-oppsettet."
        _maybe_pause
        cd - > /dev/null # Return to previous directory
        return
    }

    local local_commit
    local remote_commit
    local_commit=$(git rev-parse HEAD)
    remote_commit=$(git rev-parse '@{u}') # Equivalent to origin/main or whatever the upstream is

    if [ "$local_commit" = "$remote_commit" ]; then
        log_info "Du har allerede den nyeste versjonen."
        _maybe_pause
        cd - > /dev/null
        return
    fi

    log_info "Ny versjon tilgjengelig. Prøver å oppdatere (git pull)..."
    # Stash any local changes to avoid conflicts, apply them after pull
    local stash_needed=false
    if ! git diff --quiet HEAD; then
        log_info "Lokale endringer funnet. Prøver å midlertidig lagre dem (git stash)..."
        git stash push -u -m "Autostash before update" && stash_needed=true || {
            log_error "FEIL: 'git stash' mislyktes. Løs konflikter manuelt og prøv igjen."
            _maybe_pause
            cd - > /dev/null
            return
        }
    fi

    # Store the modification timestamp or checksum of the script itself before pull
    local pre_update_checksum=""
    if [[ -f "$script_path_abs" ]]; then # Ensure script_path_abs is valid file
        pre_update_checksum=$(md5sum "$script_path_abs" | awk '{print $1}')
    fi

    if git pull --ff-only; then # Using --ff-only to avoid merge commits, prefer rebase if needed
        log_success "Oppdatering vellykket."
        if [ "$stash_needed" = true ]; then
            log_info "Prøver å gjenopprette midlertidig lagrede endringer (git stash pop)..."
            if ! git stash pop; then
                log_warn "Kunne ikke automatisk gjenopprette midlertidig lagrede endringer."
                log_warn "Du må kanskje kjøre 'git stash apply' manuelt for å løse konflikter."
            fi
        fi

        local post_update_checksum=""
        if [[ -f "$script_path_abs" ]]; then # Ensure script_path_abs is valid file after potential changes
             post_update_checksum=$(md5sum "$script_path_abs" | awk '{print $1}')
        fi

        # Check if the script itself was updated or if any update happened
        local new_local_commit
        new_local_commit=$(git rev-parse HEAD)

        if [ "$new_local_commit" != "$local_commit" ] && [ "$pre_update_checksum" != "$post_update_checksum" ]; then
            log_info "UltimateComfy.sh ble oppdatert. Starter på nytt..."
            _maybe_pause
            cd - > /dev/null # Return to original directory before exec
            exec "$script_path_abs" "${original_args[@]}" # Use original args for exec
        elif [ "$new_local_commit" != "$local_commit" ]; then
            log_info "Oppdateringer ble lastet ned, men UltimateComfy.sh ble ikke endret. Går tilbake til menyen."
            _maybe_pause
        else
            # This case should ideally not be hit if local_commit != remote_commit
            log_info "Ingen endringer i UltimateComfy.sh etter pull, selv om HEAD endret seg. Merkelig."
            _maybe_pause
        fi
    else
        log_error "FEIL: 'git pull' mislyktes. Løs eventuelle konflikter manuelt i mappen $script_dir og prøv igjen."
        if [ "$stash_needed" = true ]; then
            log_warn "Dine lokale endringer er fortsatt i 'stash'. Du kan gjenopprette dem med 'git stash pop' etter å ha løst pull-konflikter."
        fi
        _maybe_pause
    fi

    cd - > /dev/null # Return to original directory if not restarting
}

check_and_update_startup_scripts() {
    # This function will be called at the start of UltimateComfy.sh
    script_log "INFO: Checking if startup scripts need regeneration..."

    # Ensure paths are initialized so we know where to look
    if [[ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]]; then
        initialize_docker_paths
    fi

    local start_script_path="$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"

    # If the script doesn't exist, there's nothing to update. The user needs to run the initial setup.
    if [ ! -f "$start_script_path" ]; then
        script_log "INFO: start_comfyui.sh not found. Skipping update check. User should run initial setup."
        return
    fi

    # Extract version from existing script. The version is in a comment like: # Generated by UltimateComfy - Version 1.1
    local existing_version
    existing_version=$(grep '# Generated by UltimateComfy - Version' "$start_script_path" | head -n 1 | awk '{print $NF}')

    # The latest version is from the docker_setup.sh script's variable
    local latest_version="$STARTUP_SCRIPT_VERSION"

    if [ -z "$existing_version" ]; then
        log_warn "Could not determine version of existing startup script at $start_script_path."
        log_warn "Regenerating scripts to be safe."
        existing_version="0" # Force update
    fi

    log_info "Found existing startup script version: $existing_version. Latest version is: $latest_version."

    # Compare versions. If they are different, regenerate.
    if [ "$existing_version" != "$latest_version" ]; then
        log_warn "Startup script version mismatch. Found: $existing_version, Expected: $latest_version."
        log_info "Automatically regenerating startup scripts..."

        # We need the project root dir to pass to the regeneration function
        local project_root_dir
        project_root_dir=$(dirname "$0")

        # The regenerate function can auto-detect the GPU count, so we don't need to pass it.
        regenerate_startup_scripts "$project_root_dir" "" # Pass empty string for num_gpus to trigger auto-detection

        if [ $? -eq 0 ]; then
            log_success "Startup scripts have been successfully updated to version $latest_version."
            echo "Startup scripts were outdated and have been automatically updated. Please review any new options and continue."
            press_enter_to_continue
        else
            log_error "Failed to automatically regenerate startup scripts. Please try running the initial setup again."
            press_enter_to_continue
        fi
    else
        log_info "Startup scripts are up to date."
    fi
}

view_autodownload_log() {
    log_info "Viser Auto-Download Service logg..."
    # BASE_DOCKER_SETUP_DIR is from common_utils.sh, should be available
    if [[ -z "$BASE_DOCKER_SETUP_DIR" ]]; then
        log_error "BASE_DOCKER_SETUP_DIR er ikke satt. Kan ikke bestemme loggfilsti."
        press_enter_to_continue
        return
    fi

    local primary_log_path="$BASE_DOCKER_SETUP_DIR/auto_download_service.log"
    local fallback_log_path="/tmp/auto_download_service.log"
    local log_file_to_tail=""

    if [ -f "$primary_log_path" ]; then
        log_file_to_tail="$primary_log_path"
    elif [ -f "$fallback_log_path" ]; then
        log_warn "Primær loggfil ikke funnet på $primary_log_path."
        log_info "Bruker fallback loggfil: $fallback_log_path"
        log_file_to_tail="$fallback_log_path"
    else
        log_error "Loggfil for auto-download service ikke funnet."
        log_error "Sjekket: $primary_log_path"
        log_error "Og:      $fallback_log_path"
        log_warn "Sørg for at Docker containerne er startet og at tjenesten kjører."
        press_enter_to_continue
        return
    fi

    log_info "Bruker loggfil: $log_file_to_tail"
    log_info "Trykk Ctrl+C for å avslutte loggvisningen og returnere til menyen."
    echo "--- Viser logg (Ctrl+C for å avslutte) ---"
    # Ensure terminal is available for tail -f
    if [ -t 1 ] ; then
        (tail -f "$log_file_to_tail")
    else
        log_error "Kan ikke kjøre 'tail -f': Ingen terminal tilgjengelig."
        log_error "Dette valget fungerer best når skriptet kjøres i et interaktivt terminalvindu."
    fi
    # After tail -f is exited (Ctrl+C), the script continues here.
    # A press_enter_to_continue will be handled by the main loop after the case statement.
    # No explicit press_enter_to_continue needed here unless we want to pause before the menu redraws.
    # For now, let it fall through, and the main loop's press_enter will catch it if no dialog.
    echo "--- Loggvisning avsluttet ---"
}

toggle_autodownloader() {
    local script_path="auto_download_service.sh"
    log_info "Checking status of auto-downloader..."

    local is_enabled
    if [ -x "$script_path" ]; then
        is_enabled=true
        log_info "Auto-downloader is currently ENABLED (executable)."
    else
        is_enabled=false
        log_info "Auto-downloader is currently DISABLED (not executable)."
    fi

    local action
    if [ "$is_enabled" = true ]; then
        action="disable"
    else
        action="enable"
    fi

    local confirm_choice
    echo -n "Do you want to ${action^^} the auto-downloader? (yes/no): " >&2
    read -r confirm_choice
    if [[ ! "$confirm_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_info "Operation cancelled."
        press_enter_to_continue
        return
    fi

    log_info "Stopping ComfyUI containers to apply changes..."
    if [[ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]]; then initialize_docker_paths; fi
    local stop_script="$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
    if [ -f "$stop_script" ]; then "$stop_script"; else log_warn "Stop script not found."; fi

    log_info "Applying changes..."
    if [ "$action" = "disable" ]; then
        chmod -x "$script_path"
    else
        chmod +x "$script_path"
    fi

    if [ $? -eq 0 ]; then
        log_success "Auto-downloader successfully ${action}d."
    else
        log_error "Failed to change permissions on $script_path."
        press_enter_to_continue
        return
    fi

    log_info "Restarting ComfyUI containers..."
    local start_script="$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
    if [ -f "$start_script" ]; then bash "$start_script"; else log_warn "Start script not found."; fi

    log_success "ComfyUI restarted."
    press_enter_to_continue
}

update_folder_sizes() {
    script_log "INFO: Updating folder sizes..."
    local total_input_kb=0
    local total_output_kb=0

    local data_dir="$BASE_DOCKER_SETUP_DIR/comfyui_data"

    if [ ! -d "$data_dir" ]; then
        INPUT_SIZE_DISPLAY="0B"
        OUTPUT_SIZE_DISPLAY="0B"
        script_log "WARN: Data directory not found at $data_dir. Sizes set to 0."
        return
    fi

    # Find all gpu* directories
    local gpu_dirs
    gpu_dirs=$(find "$data_dir" -mindepth 1 -maxdepth 1 -type d -name "gpu*")

    if [ -z "$gpu_dirs" ]; then
        INPUT_SIZE_DISPLAY="0B"
        OUTPUT_SIZE_DISPLAY="0B"
        script_log "INFO: No gpu* directories found. Sizes set to 0."
        return
    fi

    for dir in $gpu_dirs; do
        local input_path="$dir/input"
        local output_path="$dir/output"

        if [ -d "$input_path" ]; then
            # Use du -sk to get size reliably in kilobytes.
            local current_input_kb
            current_input_kb=$(du -sk "$input_path" | awk '{print $1}')
            total_input_kb=$((total_input_kb + current_input_kb))
        fi

        if [ -d "$output_path" ]; then
            local current_output_kb
            current_output_kb=$(du -sk "$output_path" | awk '{print $1}')
            total_output_kb=$((total_output_kb + current_output_kb))
        fi
    done

    # Check if numfmt is available for human-readable formatting
    if command -v numfmt &>/dev/null; then
        # Convert total KB to bytes for numfmt for accurate conversion
        local total_input_bytes=$((total_input_kb * 1024))
        local total_output_bytes=$((total_output_kb * 1024))

        # Convert Bytes to human-readable format (e.g., 1.0M, 512K, 1.2G)
        INPUT_SIZE_DISPLAY=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$total_input_bytes" | sed 's/\.0\([A-Z]\)/\1/')
        OUTPUT_SIZE_DISPLAY=$(numfmt --to=iec-i --suffix=B --format="%.1f" "$total_output_bytes" | sed 's/\.0\([A-Z]\)/\1/')
    else
        # Fallback if numfmt is not available
        INPUT_SIZE_DISPLAY="${total_input_kb}K"
        OUTPUT_SIZE_DISPLAY="${total_output_kb}K"
        script_log "WARN: numfmt not found. Displaying size in kilobytes."
    fi

    script_log "INFO: Calculated sizes -> Input: $INPUT_SIZE_DISPLAY, Output: $OUTPUT_SIZE_DISPLAY"
}

clean_comfyui_folders() {
    log_info "Starting cleanup of ComfyUI input and output folders..."

    if [[ -z "$BASE_DOCKER_SETUP_DIR" ]]; then
        log_error "BASE_DOCKER_SETUP_DIR is not set. Cannot determine folder paths."
        return
    fi

    local data_dir="$BASE_DOCKER_SETUP_DIR/comfyui_data"
    if [ ! -d "$data_dir" ]; then
        log_warn "Data directory not found at $data_dir. Nothing to clean."
        return
    fi

    # Set permissions to avoid issues before cleaning
    log_info "Attempting to set write permissions for all users on $data_dir..."
    if sudo chmod -R a+w "$data_dir"; then
        log_success "Permissions updated successfully."
    else
        log_error "Failed to update permissions. The cleanup might fail."
        # Ask user if they want to continue despite the failure
        local continue_choice
        read -r -p "Do you want to attempt to continue the cleanup anyway? (yes/no): " continue_choice </dev/tty
        if [[ ! "$continue_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
            log_info "Cleanup operation cancelled by user."
            return
        fi
    fi

    # Find all gpu* directories and build a list of paths to clean
    local paths_to_clean=()
    local gpu_dirs
    gpu_dirs=$(find "$data_dir" -mindepth 1 -maxdepth 1 -type d -name "gpu*")

    if [ -z "$gpu_dirs" ]; then
        log_info "No gpu* directories found. Nothing to clean."
        return
    fi

    log_info "The following directories will be cleaned:"
    for dir in $gpu_dirs; do
        if [ -d "$dir/input" ]; then
            log_info " - $dir/input"
            paths_to_clean+=("$dir/input")
        fi
        if [ -d "$dir/output" ]; then
            log_info " - $dir/output"
            paths_to_clean+=("$dir/output")
        fi
    done

    if [ ${#paths_to_clean[@]} -eq 0 ]; then
        log_info "No input or output subdirectories found to clean."
        return
    fi
    echo

    local confirm_choice
    read -r -p "Are you sure you want to delete all files and subfolders in the locations listed above? (yes/no): " confirm_choice </dev/tty

    if [[ ! "$confirm_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        log_info "Cleanup operation cancelled by user."
        return
    fi

    for path in "${paths_to_clean[@]}"; do
        log_info "Cleaning $path..."
        if find "$path" -mindepth 1 -delete; then
            log_success "Successfully cleaned $path."
        else
            log_error "An error occurred while cleaning $path."
        fi
    done

    log_info "Cleanup operation finished."
}

# --- Hovedmeny Funksjon ---
main_menu() {
    # Ensure paths are initialized once for the menu context if needed for display or passing.
    # DOCKER_CONFIG_ACTUAL_PATH, DOCKER_DATA_ACTUAL_PATH, DOCKER_SCRIPTS_ACTUAL_PATH
    # are set by initialize_docker_paths (from docker_setup.sh)
    if [[ -z "$DOCKER_CONFIG_ACTUAL_PATH" ]]; then
        initialize_docker_paths
    fi

    # ensure_dialog_installed is from common_utils.sh
    ensure_dialog_installed
    local dialog_available=$?
    script_log "DEBUG: main_menu (UltimateComfy.sh) - ensure_dialog_installed returned: $dialog_available"

    local main_choice

    while true; do
        # Update folder sizes each time the menu is displayed
        update_folder_sizes

        script_log "DEBUG: main_menu loop iteration started. dialog_available=$dialog_available"
        if [ "$dialog_available" -eq 0 ]; then
            script_log "DEBUG: Calling dialog command..."
            # BASE_DOCKER_SETUP_DIR from common_utils.sh
            # COMFYUI_IMAGE_NAME from docker_setup.sh
            main_choice=$(dialog --clear --stdout \
                --title "ComfyUI Unified Tool (v4 Refactored)" \
                --ok-label "Select" \
                --cancel-label "Exit" \
                --menu "Base Dir: $BASE_DOCKER_SETUP_DIR
Image: $COMFYUI_IMAGE_NAME
Input: $INPUT_SIZE_DISPLAY | Output: $OUTPUT_SIZE_DISPLAY

Choose an option:" \
                25 76 13 \
                "1" "Førstegangs oppsett/Installer ComfyUI i Docker" \
                "2" "Bygg/Oppdater ComfyUI Docker Image" \
                "3" "Last ned/Administrer Modeller" \
                "4" "Start ComfyUI Docker Container(e)" \
                "5" "Stopp ComfyUI Docker Container(e)" \
                "6" "Fix Custom Node Python Dependencies" \
                "7" "Update UltimateComfy" \
                "8" "Oppgrader NVIDIA Driver (Host)" \
                "9" "Se Auto-Download Service Logg" \
                "10" "Update Frontend" \
                "11" "Installer og kjør ncdu" \
                "12" "Toggle Auto-Downloader" \
                "13" "Clean ComfyUI Folders" \
                "14" "Avslutt" \
                2>/dev/tty)

            local dialog_exit_status=$?
            script_log "DEBUG: dialog command finished. main_choice='$main_choice', dialog_exit_status='$dialog_exit_status'"
            if [ $dialog_exit_status -ne 0 ]; then
                main_choice="14" # Updated for new Avslutt number
                script_log "DEBUG: Dialog cancelled or Exit selected, main_choice set to 14."
            fi
        else
            script_log "DEBUG: Using basic menu fallback."
            clear
            echo "--- ComfyUI Unified Tool (v4 Refactored) ---"
            echo "Primær oppsettsmappe: $BASE_DOCKER_SETUP_DIR"
            echo "Docker image navn: $COMFYUI_IMAGE_NAME"
            echo "Input: $INPUT_SIZE_DISPLAY | Output: $OUTPUT_SIZE_DISPLAY"
            echo "--------------------------------"
            echo " (Dialog utility not found or install declined, using basic menu)"
            echo "1) Førstegangs oppsett/Installer ComfyUI i Docker"
            echo "2) Bygg/Oppdater ComfyUI Docker Image"
            echo "3) Last ned/Administrer Modeller"
            echo "4) Start ComfyUI Docker Container(e)"
            echo "5) Stopp ComfyUI Docker Container(e)"
            echo "6) Fix Custom Node Python Dependencies"
            echo "7) Update UltimateComfy"
            echo "8) Oppgrader NVIDIA Driver (Host)"
            echo "9) Se Auto-Download Service Logg"
            echo "10) Update Frontend"
            echo "11) Installer og kjør ncdu"
            echo "12) Toggle Auto-Downloader"
            echo "13) Clean ComfyUI Folders"
            echo "14) Avslutt"
            echo "--------------------------------"
            echo -n "Velg et alternativ (1-14): " >&2
            read -r main_choice </dev/tty
            script_log "DEBUG: Basic menu read finished. main_choice='$main_choice'"
        fi

        script_log "DEBUG: main_menu case: main_choice='$main_choice'"
        set +e 
        case "$main_choice" in
            "1")
                # perform_docker_initial_setup is from docker_setup.sh
                perform_docker_initial_setup "$(dirname "$0")"
                press_enter_to_continue # from common_utils.sh
                ;;
            "2")
                # check_docker_status and build_comfyui_image are from docker_setup.sh
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                build_comfyui_image
                press_enter_to_continue
                ;;
            "3")
                # run_model_downloader is from model_downloader.sh
                # Ensure DOCKER_DATA_ACTUAL_PATH is set. It should be by the call at the start of main_menu.
                if [[ -z "$DOCKER_DATA_ACTUAL_PATH" ]]; then
                    log_info "Docker data stien er ikke satt. Kjører initialize_docker_paths..."
                    initialize_docker_paths # from docker_setup.sh
                fi

                if [[ -d "$DOCKER_DATA_ACTUAL_PATH/models" ]]; then
                    run_model_downloader "$DOCKER_DATA_ACTUAL_PATH"
                else
                    log_info "Docker data sti ikke funnet ($DOCKER_DATA_ACTUAL_PATH/models) eller ikke initialisert."
                    log_info "Lar deg velge sti for modelldenedlasting manuelt."
                    run_model_downloader ""
                fi
                press_enter_to_continue
                ;;
            "4")
                # check_docker_status from docker_setup.sh
                # DOCKER_SCRIPTS_ACTUAL_PATH from docker_setup.sh (set by initialize_docker_paths)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                if [[ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]]; then initialize_docker_paths; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh" ]]; then
                    bash "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
                else
                    log_warn "Startskript ikke funnet. Kjør installasjon (valg 1) først."
                fi
                press_enter_to_continue
                ;;
            "5")
                # check_docker_status from docker_setup.sh
                # DOCKER_SCRIPTS_ACTUAL_PATH from docker_setup.sh (set by initialize_docker_paths)
                if ! check_docker_status; then press_enter_to_continue; continue; fi
                if [[ -z "$DOCKER_SCRIPTS_ACTUAL_PATH" ]]; then initialize_docker_paths; fi
                if [[ -f "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh" ]]; then
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/stop_comfyui.sh"
                else
                    log_warn "Stoppskript ikke funnet."
                fi
                press_enter_to_continue
                ;;
            "6")
                script_log "INFO: User selected 'Fix Custom Node Python Dependencies'."
                local fix_deps_script_path
                fix_deps_script_path="$(dirname "$0")/fix_custom_node_deps.sh"
                if [ -x "$fix_deps_script_path" ]; then
                    if ! check_docker_status; then press_enter_to_continue; continue; fi # from docker_setup.sh
                    "$fix_deps_script_path"
                else
                    log_error "Fix dependencies script not found or not executable at $fix_deps_script_path."
                fi
                press_enter_to_continue # from common_utils.sh
                ;;
            "7")
                script_log "INFO: User selected 'Update UltimateComfy'."
                perform_self_update
                # main_menu will loop again, or script will have restarted if update occurred
                ;;
            "8")
                script_log "INFO: User selected 'Oppgrader NVIDIA Driver (Host)'."
                local nvidia_upgrade_script_path
                nvidia_upgrade_script_path="$(dirname "$0")/upgrade_nvidia_driver.sh"
                if [ -f "$nvidia_upgrade_script_path" ]; then
                    if [ -x "$nvidia_upgrade_script_path" ]; then
                        "$nvidia_upgrade_script_path"
                    else
                        log_error "FEIL: $nvidia_upgrade_script_path er ikke kjørbar (executable)."
                        log_error "Kjør 'chmod +x $nvidia_upgrade_script_path' for å fikse."
                    fi
                else
                    log_error "FEIL: $nvidia_upgrade_script_path ble ikke funnet."
                fi
                press_enter_to_continue
                ;;
            "9")
                script_log "INFO: User selected 'Se Auto-Download Service Logg'."
                view_autodownload_log
                press_enter_to_continue
                ;;
            "10")
                script_log "INFO: User selected 'Update Frontend'."
                local update_frontend_script_path
                update_frontend_script_path="$(dirname "$0")/update_frontend.sh"
                if [ -x "$update_frontend_script_path" ]; then
                    "$update_frontend_script_path"
                else
                    log_error "Update frontend script not found or not executable at $update_frontend_script_path."
                fi
                press_enter_to_continue
                ;;
            "11")
                script_log "INFO: User selected 'Installer og kjør ncdu'."
                local ncdu_script_path
                ncdu_script_path="$(dirname "$0")/run_ncdu.sh"
                if [ -f "$ncdu_script_path" ]; then
                    if [ -x "$ncdu_script_path" ]; then
                        "$ncdu_script_path"
                    else
                        log_error "FEIL: $ncdu_script_path er ikke kjørbar (executable)."
                        log_error "Kjør 'chmod +x $ncdu_script_path' for å fikse."
                    fi
                else
                    log_error "FEIL: $ncdu_script_path ble ikke funnet."
                fi
                press_enter_to_continue
                ;;
            "12")
                script_log "INFO: User selected 'Toggle Auto-Downloader'."
                toggle_autodownloader
                ;;
            "13")
                script_log "INFO: User selected 'Clean ComfyUI Folders'."
                clean_comfyui_folders
                press_enter_to_continue
                ;;
            "14")
                script_log "DEBUG: main_menu attempting to exit (Option 14)."
                log_info "Avslutter." # from common_utils.sh
                clear
                exit 0
                ;;
            *)
                if [ "$dialog_available" -eq 0 ]; then
                    # dialog is from common_utils.sh (via ensure_dialog_installed)
                    dialog --title "Ugyldig valg" --msgbox "Vennligst velg et gyldig alternativ fra menyen." 6 50 2>/dev/tty
                else
                    log_warn "Ugyldig valg. Skriv inn et tall fra 1-14." # from common_utils.sh
                fi
                press_enter_to_continue # from common_utils.sh
                ;;
        esac
    done
}

# --- Skriptets startpunkt ---
# Initial script_log calls are now in common_utils.sh when it's sourced.
# The first log specific to this main script.
script_log "INFO: --- UltimateComfy.sh (Refactored) startpunkt ---"

# --- Headless vs Interactive Execution ---
if [ "$HEADLESS_UPDATE" = true ]; then
    # This is a headless update run.
    script_log "INFO: Headless update mode activated. Running self-update..."
    # Call the update function in headless mode, passing original args
    perform_self_update "headless" "${ORIGINAL_ARGS[@]}"
    update_exit_code=$?
    script_log "INFO: Headless update finished with exit code $update_exit_code. Exiting."
    exit $update_exit_code
else
    # This is a normal interactive run.
    # Check if startup scripts need to be updated before showing the menu
    check_and_update_startup_scripts

    main_menu
    script_log "DEBUG: main_menu call finished (UltimateComfy.sh should have exited from within main_menu)."
fi
