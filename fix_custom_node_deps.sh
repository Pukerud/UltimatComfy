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
    # Navigate to ComfyUI directory and run the manager script
    cd /app/ComfyUI
    python custom_nodes/ComfyUI-Manager/cm-cli.py restore-dependencies

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

    echo "--- Installerer spesifikke tilleggspakker ---"
    pip install --upgrade huggingface_hub diffusers
    pip install opencv-python-headless
    pip install deepdiff
    pip install piexif
    pip install py-cpuinfo
    pip install pynvml

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
