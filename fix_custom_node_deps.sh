#!/bin/bash

# --- KJØR SCRIPTET ---

TARGET_CONTAINERS=$(docker ps -a --filter "name=^comfyui-gpu" --format "{{.Names}}")

if [ -z "$TARGET_CONTAINERS" ]; then
    echo "Ingen ComfyUI GPU containere (comfyui-gpuX) funnet."
    exit 1
fi
echo "--- Målcontainere som vil bli prosessert: ---"
echo "$TARGET_CONTAINERS"
echo "---------------------------------------------"

for CONTAINER_NAME in $TARGET_CONTAINERS; do
    echo ""
    echo "--- Starter prosessering for container: $CONTAINER_NAME ---"

    echo "--- Steg 1: Installerer manglende Python-pakker inne i containeren $CONTAINER_NAME... ---"
    echo "Dette er en utvidet prosess og kan ta flere minutter. Vær tålmodig."

    # Kjører et robust installasjonsscript non-interaktivt inne i containeren.
    docker exec "$CONTAINER_NAME" /bin/bash -c '
        echo "--- Kjører ComfyUI-Manager sin restore-funksjon (første pass)..."
        cd /app/ComfyUI
        python custom_nodes/ComfyUI-Manager/cm-cli.py restore-dependencies

        echo "---"
        echo "--- Kjører en manuell, garantert sjekk av ALLE noder (andre pass)..."
        for d in /app/ComfyUI/custom_nodes/*/; do
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
    ' # End of docker exec block

    echo ""
    echo "--- Steg 2: Prosessen er ferdig for $CONTAINER_NAME. Restarter containeren for å aktivere endringene... ---"
    docker restart "$CONTAINER_NAME"
    echo "Container $CONTAINER_NAME restartet."

done # End of for loop

echo ""
echo "--- Alle spesifiserte ComfyUI GPU containere er prosessert. ---"
echo "Du kan sjekke logger for individuelle containere manuelt ved behov, for eksempel med 'docker logs <container_name>'."
