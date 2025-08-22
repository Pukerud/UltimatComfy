#!/bin/bash

# Source common utilities
# shellcheck source=./common_utils.sh
source "$(dirname "$0")/common_utils.sh" || { echo "ERROR: common_utils.sh not found. Exiting."; exit 1; }

# --- NCDU Installer and Runner ---
run_ncdu() {
    log_info "Starter ncdu-installasjon og kjøring..."

    # Sjekk for sudo/root-tilgang
    if [[ $EUID -ne 0 ]]; then
        log_info "Dette skriptet krever sudo-rettigheter for å installere pakker og skanne disken."
        log_info "Du kan bli bedt om passordet ditt."
        # Kjører en tom sudo kommando for å trigge passord-prompt tidlig
        sudo -v
        if [ $? -ne 0 ]; then
            log_error "Klarte ikke å få sudo-rettigheter. Avbryter."
            return 1
        fi
    fi

    log_info "Oppdaterer pakkedatabasen (sudo apt update)..."
    if sudo apt-get update; then
        log_info "Pakkedatabasen ble oppdatert."
    else
        log_error "Klarte ikke å oppdatere pakkedatabasen. Sjekk internettforbindelsen din og prøv igjen."
        return 1
    fi

    log_info "Installerer ncdu (sudo apt install ncdu)..."
    if sudo apt-get install -y ncdu; then
        log_info "ncdu ble installert."
    else
        log_error "Klarte ikke å installere ncdu. Prøv å kjøre installasjonen manuelt."
        return 1
    fi

    log_info "Starter ncdu for å analysere diskbruk fra roten (/)..."
    log_info "Trykk 'q' for å avslutte ncdu når du er ferdig."
    echo "----------------------------------------------------"
    echo " Starter ncdu... (laster inn diskdata)"
    echo "----------------------------------------------------"

    # Kjør ncdu
    if sudo ncdu /; then
        log_info "ncdu-sesjonen ble avsluttet normalt."
    else
        log_error "ncdu-sesjonen ble avsluttet med en feil."
    fi

    echo "----------------------------------------------------"
    log_info "Tilbake til hovedmenyen."
}

# Kjør hovedfunksjonen hvis skriptet kjøres direkte
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_ncdu
    # Gi brukeren tid til å lese output før skjermen eventuelt tømmes av hovedskriptet
    press_enter_to_continue
fi
