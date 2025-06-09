#!/bin/bash

# --- INNSTILLINGER ---
# 1. Sett navnet på containeren din her (den er allerede riktig for deg)
CONTAINER_NAME="comfyui-gpu0"


# --- KJØR SCRIPTET ---
echo "--- Steg 1: Installerer manglende Python-pakker inne i containeren... ---"
echo "Dette er en utvidet prosess og kan ta flere minutter. Vær tålmodig."

# Kjører et robust installasjonsscript non-interaktivt inne i containeren.
# Dette scriptet kjører FØRST Managerens verktøy, og DERETTER en manuell sjekk for å fange alt det overser.
docker exec "$CONTAINER_NAME" /bin/bash -c '
    set -e # Avslutt hvis en kommando feiler

    echo "--- Kjører ComfyUI-Manager sin restore-funksjon (første pass)..."
    # Ensure we are in the correct directory for cm-cli.py if it's sensitive to CWD
    if [ -d "/app/ComfyUI/custom_nodes/ComfyUI-Manager" ]; then
        cd /app/ComfyUI/custom_nodes/ComfyUI-Manager # Changed to manager dir
        python cm-cli.py restore-dependencies
    elif [ -f "/app/ComfyUI/manager/main.py" ]; then # Older manager?
        echo "WARN: ComfyUI-Manager seems to be an older version or in a different location. Trying to run restore from /app/ComfyUI/manager."
        cd /app/ComfyUI # Fallback to main ComfyUI dir
        python manager/main.py --restore-dependencies # Hypothetical, check actual command for older manager
    elif [ -f "/app/ComfyUI/main.py" ] && [ -d "/app/ComfyUI/custom_nodes/ComfyUI-Manager" ]; then # Standard location check
        echo "Standard ComfyUI-Manager location found."
        cd /app/ComfyUI # Ensure we are in /app/ComfyUI for the script path
        python custom_nodes/ComfyUI-Manager/cm-cli.py restore-dependencies
    else
        echo "ERROR: ComfyUI-Manager cm-cli.py not found in expected locations (/app/ComfyUI/custom_nodes/ComfyUI-Manager/cm-cli.py or /app/ComfyUI/manager/main.py with restore flag). Skipping manager restore."
    fi

    echo "---"
    echo "--- Kjører en manuell, garantert sjekk av ALLE noder (andre pass)..."
    # Gå gjennom hver undermappe i custom_nodes
    for d in /app/ComfyUI/custom_nodes/*/; do
        # Sjekk om requirements.txt finnes
        if [ -f "${d}requirements.txt" ]; then
            echo "--> Fant requirements for $(basename "$d"). Installerer..."
            pip install -r "${d}requirements.txt"
        fi
    done

    echo "Alle avhengigheter er nå sjekket og installert."
'

echo ""
echo "--- Steg 2: Prosessen er ferdig. Restarter containeren for å aktivere endringene... ---"
docker restart "$CONTAINER_NAME"

echo ""
echo "--- Steg 3: Venter noen sekunder, og viser live-loggen. Se etter feilmeldinger. ---"
echo "Trykk Ctrl+C for å stoppe loggvisningen."

sleep 5 # Gir containeren litt tid til å starte opp

docker logs -f "$CONTAINER_NAME"
