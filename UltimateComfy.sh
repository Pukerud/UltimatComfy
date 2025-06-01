#!/bin/bash
# SCRIPT_VERSION_4
# Kombinert skript for ComfyUI Docker Oppsett og Modelldenedlasting - Nå en koordinator.

# Source utility and module scripts
# Assuming they are in the same directory as this script
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found or failed to source. Exiting."; exit 1; }
# shellcheck source=./docker_setup.sh
source "$(dirname "$0")/docker_setup.sh" || { echo "ERROR: docker_setup.sh not found or failed to source. Exiting."; exit 1; }
# shellcheck source=./model_downloader.sh
source "$(dirname "$0")/model_downloader.sh" || { echo "ERROR: model_downloader.sh not found or failed to source. Exiting."; exit 1; }

# Set the exit trap for the main script
# SCRIPT_LOG_FILE is defined in common_utils.sh
trap 'script_log "INFO: --- UltimateComfy.sh execution finished with exit status $? ---"' EXIT

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

Choose an option:" \
                20 76 6 \
                "1" "Førstegangs oppsett/Installer ComfyUI i Docker" \
                "2" "Bygg/Oppdater ComfyUI Docker Image" \
                "3" "Last ned/Administrer Modeller" \
                "4" "Start ComfyUI Docker Container(e)" \
                "5" "Stopp ComfyUI Docker Container(e)" \
                "6" "Avslutt" \
                2>/dev/tty)

            local dialog_exit_status=$?
            script_log "DEBUG: dialog command finished. main_choice='$main_choice', dialog_exit_status='$dialog_exit_status'"
            if [ $dialog_exit_status -ne 0 ]; then
                main_choice="6"
                script_log "DEBUG: Dialog cancelled or Exit selected, main_choice set to 6."
            fi
        else
            script_log "DEBUG: Using basic menu fallback."
            clear
            echo "--- ComfyUI Unified Tool (v4 Refactored) ---"
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
            echo -n "Velg et alternativ (1-6): " >&2
            read -r main_choice </dev/tty
            script_log "DEBUG: Basic menu read finished. main_choice='$main_choice'"
        fi

        script_log "DEBUG: main_menu case: main_choice='$main_choice'"
        set +e 
        case "$main_choice" in
            "1")
                # perform_docker_initial_setup is from docker_setup.sh
                perform_docker_initial_setup
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
                    "$DOCKER_SCRIPTS_ACTUAL_PATH/start_comfyui.sh"
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
                script_log "DEBUG: main_menu attempting to exit (Option 6)."
                log_info "Avslutter." # from common_utils.sh
                clear
                exit 0
                ;;
            *)
                if [ "$dialog_available" -eq 0 ]; then
                    # dialog is from common_utils.sh (via ensure_dialog_installed)
                    dialog --title "Ugyldig valg" --msgbox "Vennligst velg et gyldig alternativ fra menyen." 6 50 2>/dev/tty
                else
                    log_warn "Ugyldig valg. Skriv inn et tall fra 1-6." # from common_utils.sh
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
# log_info "Starter ComfyUI Unified Tool (v4 Refactored)..." # This kind of message is now in common_utils.sh or can be added if a distinct one is needed

main_menu
script_log "DEBUG: main_menu call finished (UltimateComfy.sh should have exited from within main_menu)."
