#!/bin/bash

# --- Konfigurasjon ---
# Disse vil bli satt av brukeren under kjøring.
SPECIFIC_TARGET_VERSION=""
TARGET_DRIVER_MAJOR_VERSION=""

# --- Funksjoner ---
log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_success() { echo "[SUCCESS] $1"; }

discover_driver_series() {
    # Søker etter driver-metapakker, trekker ut serienummeret, sorterer numerisk og fjerner duplikater.
    apt-cache search --names-only '^nvidia-driver-[0-9]+$' | cut -d- -f3 | sort -un
}

discover_specific_versions() {
    local series="$1"
    log_info "Søker etter spesifikke versjoner i $series-serien..."
    # Bruker apt-cache madison for å finne versjoner for metapakken
    apt-cache madison "nvidia-driver-$series" | awk '{print $3}'
}

check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        log_warn "Dette scriptet må kjøres med sudo for å kunne installere/reinstallere pakker."
        log_info "Prøver å kjøre på nytt med sudo..."
        sudo bash "$0" "$@"
        exit $?
    fi
}

ensure_graphics_drivers_ppa() {
    log_info "Sjekker om PPA for grafikkdrivere (ppa:graphics-drivers/ppa) er lagt til..."
    # Sjekk om PPA er aktivt
    if ! grep -q "^deb .*ppa.launchpad.net/graphics-drivers/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        log_warn "PPA ikke funnet. Legger til ppa:graphics-drivers/ppa for å få tilgang til nyere drivere."
        if ! command -v add-apt-repository &> /dev/null; then
            log_info "Installerer software-properties-common..."
            apt-get install -y software-properties-common
        fi
        add-apt-repository -y ppa:graphics-drivers/ppa
        log_success "PPA lagt til. Oppdaterer pakkelister..."
        apt-get update
    else
        log_info "PPA for grafikkdrivere er allerede konfigurert."
    fi
}

get_kernel_driver_version() {
    if [ -f /proc/driver/nvidia/version ]; then
        grep -oP 'Kernel Module\s+\K[0-9]+\.[0-9]+(\.[0-9]+)?' /proc/driver/nvidia/version | head -n 1
    else
        echo ""
    fi
}

get_nvml_library_version_from_smi_error() {
    local smi_output
    smi_output=$(nvidia-smi 2>&1)
    if echo "$smi_output" | grep -q "NVML library version:"; then
        echo "$smi_output" | grep "NVML library version:" | grep -oP '([0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?)' | head -n 1
    else
        echo ""
    fi
}

get_package_version() {
    local pkg_name="$1"
    dpkg-query -W -f='${Version}\n' "$pkg_name" 2>/dev/null | head -n 1 || echo ""
}

extract_core_version() {
    local full_version="$1"
    echo "$full_version" | sed -e 's/^.*://' -e 's/-.*$//' | grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+(\.[0-9]+)?)?'
}

# --- Hovedlogikk ---
check_sudo
ensure_graphics_drivers_ppa

# --- Serie- og versjonsvalg ---
log_info "Starter interaktivt valg av NVIDIA driver..."

# Oppdag og velg driver-serie
SERIES_LIST=($(discover_driver_series))
if [ ${#SERIES_LIST[@]} -eq 0 ]; then
    log_error "Klarte ikke å finne noen tilgjengelige NVIDIA driver-serier."
    log_error "Sjekk at PPA (ppa:graphics-drivers/ppa) er riktig konfigurert og at 'apt-cache search' fungerer."
    exit 1
fi

log_info "Følgende driver-serier ble funnet:"
for i in "${!SERIES_LIST[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${SERIES_LIST[$i]}"
done

SERIES_CHOICE=""
while true; do
    read -r -p "Vennligst velg en serie å installere fra (1-${#SERIES_LIST[@]}): " SERIES_CHOICE
    if [[ "$SERIES_CHOICE" =~ ^[0-9]+$ ]] && [ "$SERIES_CHOICE" -ge 1 ] && [ "$SERIES_CHOICE" -le ${#SERIES_LIST[@]} ]; then
        TARGET_DRIVER_MAJOR_VERSION="${SERIES_LIST[$((SERIES_CHOICE-1))]}"
        log_info "Du har valgt $TARGET_DRIVER_MAJOR_VERSION serien."
        break
    else
        log_warn "Ugyldig valg. Vennligst skriv inn et tall mellom 1 og ${#SERIES_LIST[@]}."
    fi
done

# Oppdag og velg spesifikk versjon
VERSION_LIST=($(discover_specific_versions "$TARGET_DRIVER_MAJOR_VERSION"))
if [ ${#VERSION_LIST[@]} -eq 0 ]; then
    log_error "Klarte ikke å finne noen spesifikke versjoner for $TARGET_DRIVER_MAJOR_VERSION-serien."
    exit 1
fi

log_info "Følgende spesifikke versjoner ble funnet for $TARGET_DRIVER_MAJOR_VERSION serien:"
for i in "${!VERSION_LIST[@]}"; do
    version_str="${VERSION_LIST[$i]}"
    core_version=$(extract_core_version "$version_str")
    # Beste forsøk på å finne CUDA-versjon fra pakkebeskrivelsen
    cuda_info=$(apt-cache show "nvidia-driver-$TARGET_DRIVER_MAJOR_VERSION=$version_str" 2>/dev/null | grep -i 'cuda' | head -n 1)
    if [ -n "$cuda_info" ]; then
        cuda_info="($(echo "$cuda_info" | sed -e 's/^\s*[*]//' -e 's/Description-en: //' -e 's/\s\s*/ /g'))"
    fi
    printf "  %d) %s %s\n" "$((i+1))" "$core_version" "$cuda_info"
done

VERSION_CHOICE=""
while true; do
    read -r -p "Vennligst velg en versjon å installere (1-${#VERSION_LIST[@]}): " VERSION_CHOICE
    if [[ "$VERSION_CHOICE" =~ ^[0-9]+$ ]] && [ "$VERSION_CHOICE" -ge 1 ] && [ "$VERSION_CHOICE" -le ${#VERSION_LIST[@]} ]; then
        SPECIFIC_TARGET_VERSION="${VERSION_LIST[$((VERSION_CHOICE-1))]}"
        FINAL_TARGET_VERSION_CORE=$(extract_core_version "$SPECIFIC_TARGET_VERSION")
        log_info "Du har valgt versjon $FINAL_TARGET_VERSION_CORE for installasjon."
        break
    else
        log_warn "Ugyldig valg. Vennligst skriv inn et tall mellom 1 og ${#VERSION_LIST[@]}."
    fi
done

# Nå som en spesifikk versjon er valgt, fortsetter vi med synkroniseringssjekken.
log_info "Starter NVIDIA driver og bibliotekssynkroniseringssjekk for valgt versjon $FINAL_TARGET_VERSION_CORE."

# ... (Resten av den robuste logikken din) ...

KERNEL_DRIVER_VERSION_RAW=$(get_kernel_driver_version)
KERNEL_DRIVER_VERSION_CORE=$(extract_core_version "$KERNEL_DRIVER_VERSION_RAW")
NVML_LIB_VERSION_FROM_SMI_ERROR_RAW=$(get_nvml_library_version_from_smi_error)
NVML_LIB_VERSION_FROM_SMI_ERROR_CORE=$(extract_core_version "$NVML_LIB_VERSION_FROM_SMI_ERROR_RAW")
SMI_WORKS=true
NVIDIA_SMI_DRIVER_VERSION_RAW=""
NVIDIA_SMI_DRIVER_VERSION_CORE=""

if ! nvidia-smi --query-gpu=driver_version --format=csv,noheader > /dev/null 2>&1; then
    SMI_WORKS=false
    log_warn "nvidia-smi feiler. Dette indikerer et eksisterende driver/bibliotek-mismatch."
    if [ -n "$NVML_LIB_VERSION_FROM_SMI_ERROR_CORE" ]; then
        log_info "nvidia-smi feilmelding indikerer NVML bibliotek kjerneversjon: $NVML_LIB_VERSION_FROM_SMI_ERROR_CORE"
    fi
else
    NVIDIA_SMI_DRIVER_VERSION_RAW=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
    NVIDIA_SMI_DRIVER_VERSION_CORE=$(extract_core_version "$NVIDIA_SMI_DRIVER_VERSION_RAW")
    log_info "nvidia-smi fungerer. Rapportert driver kjerneversjon: $NVIDIA_SMI_DRIVER_VERSION_CORE"
fi

if [ -n "$KERNEL_DRIVER_VERSION_CORE" ]; then
    log_info "Lastet kernel drivermodul kjerneversjon: $KERNEL_DRIVER_VERSION_CORE"
else
    log_warn "Klarte ikke å finne versjon av lastet kernel drivermodul."
fi

CURRENT_DRIVER_VERSION_CORE=""
if $SMI_WORKS && [ -n "$NVIDIA_SMI_DRIVER_VERSION_CORE" ]; then
    CURRENT_DRIVER_VERSION_CORE="$NVIDIA_SMI_DRIVER_VERSION_CORE"
elif [ -n "$KERNEL_DRIVER_VERSION_CORE" ]; then
    CURRENT_DRIVER_VERSION_CORE="$KERNEL_DRIVER_VERSION_CORE"
    log_info "Bruker kernel driver kjerneversjon $CURRENT_DRIVER_VERSION_CORE som referanse."
fi

LIBNVIDIA_GL_PKG_BASE="libnvidia-gl-$TARGET_DRIVER_MAJOR_VERSION"
LIBNVIDIA_GL_PKG_SERVER="$LIBNVIDIA_GL_PKG_BASE-server"
LIB_GL_VERSION_RAW=$(get_package_version "$LIBNVIDIA_GL_PKG_BASE")
LIB_GL_SERVER_VERSION_RAW=$(get_package_version "$LIBNVIDIA_GL_PKG_SERVER")
INSTALLED_LIB_PKG_NAME=""
INSTALLED_LIB_PKG_VERSION_RAW=""
INSTALLED_LIB_PKG_VERSION_CORE=""

if [ -n "$LIB_GL_VERSION_RAW" ]; then
    INSTALLED_LIB_PKG_NAME="$LIBNVIDIA_GL_PKG_BASE"
    INSTALLED_LIB_PKG_VERSION_RAW="$LIB_GL_VERSION_RAW"
elif [ -n "$LIB_GL_SERVER_VERSION_RAW" ]; then
    INSTALLED_LIB_PKG_NAME="$LIBNVIDIA_GL_PKG_SERVER"
    INSTALLED_LIB_PKG_VERSION_RAW="$LIB_GL_SERVER_VERSION_RAW"
fi

if [ -n "$INSTALLED_LIB_PKG_NAME" ]; then
    INSTALLED_LIB_PKG_VERSION_CORE=$(extract_core_version "$INSTALLED_LIB_PKG_VERSION_RAW")
    log_info "Installert bibliotekspakke: $INSTALLED_LIB_PKG_NAME. Kjerneversjon: $INSTALLED_LIB_PKG_VERSION_CORE"
else
    log_warn "Ingen $LIBNVIDIA_GL_PKG_BASE eller $LIBNVIDIA_GL_PKG_SERVER pakke funnet."
    if [ -n "$NVML_LIB_VERSION_FROM_SMI_ERROR_CORE" ]; then
        INSTALLED_LIB_PKG_VERSION_CORE="$NVML_LIB_VERSION_FROM_SMI_ERROR_CORE"
        log_info "Bruker NVML bibliotek kjerneversjon $INSTALLED_LIB_PKG_VERSION_CORE fra nvidia-smi feil som referanse."
    fi
fi

# FINAL_TARGET_VERSION_CORE og SPECIFIC_TARGET_VERSION er nå satt av den interaktive velgeren ovenfor.
# Den gamle logikken for å bestemme versjonen er ikke lenger nødvendig.

if $SMI_WORKS && [ -n "$CURRENT_DRIVER_VERSION_CORE" ] && [ -n "$INSTALLED_LIB_PKG_VERSION_CORE" ] && \
   [ "$CURRENT_DRIVER_VERSION_CORE" == "$INSTALLED_LIB_PKG_VERSION_CORE" ] && \
   [[ "$CURRENT_DRIVER_VERSION_CORE" == $TARGET_DRIVER_MAJOR_VERSION* ]]; then
    log_success "Systemet ser ut til å være OK og allerede på $TARGET_DRIVER_MAJOR_VERSION serien. Driver: $CURRENT_DRIVER_VERSION_CORE."
	read -r -p "Vil du tvinge en reinstallasjon uansett? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log_info "Avbryter."
        exit 0
    fi
    log_info "Fortsetter med reinstallasjon på brukerens forespørsel."
fi

log_warn "Driver/Bibliotek er enten i mismatch, feil versjon, eller nvidia-smi feiler."
read -r -p "Du har valgt å installere versjon $FINAL_TARGET_VERSION_CORE. Vil du fortsette? (y/N): " choice
if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log_info "Fiks avbrutt av bruker."
    exit 1
fi

read -r -p "For å unngå konflikter, anbefales det å fjerne alle eksisterende NVIDIA-driverpakker først. Dette kan løse 'unmet dependencies'-feil. Vil du gjøre dette? (Y/n): " purge_choice
if [[ ! "$purge_choice" =~ ^[Nn]$ ]]; then
    log_info "Fjerner eksisterende NVIDIA-pakker for å unngå konflikter..."
    if ! apt-get purge -y --allow-change-held-packages 'nvidia-*' 'libnvidia-*'; then
        log_error "Klarte ikke å fjerne eksisterende NVIDIA-pakker. Dette kan føre til problemer."
        log_warn "Prøver å fortsette uansett, men installasjonen kan mislykkes."
    else
        log_info "Kjører 'apt-get autoremove' for å rydde opp..."
        apt-get autoremove -y -qq
        log_success "Eksisterende NVIDIA-pakker ble fjernet."
    fi
else
    log_warn "Hopper over fjerning av eksisterende NVIDIA-pakker. Dette kan føre til installasjonsfeil."
fi

log_info "Oppdaterer pakkelister (kan allerede være gjort hvis PPA ble lagt til)..."
apt-get update -qq

DRIVER_META_PKG="nvidia-driver-$TARGET_DRIVER_MAJOR_VERSION"
LIB_PKG_TO_FIX_BASE_NAME="libnvidia-gl-$TARGET_DRIVER_MAJOR_VERSION"
UTILS_PKG="nvidia-utils-$TARGET_DRIVER_MAJOR_VERSION"
KERNEL_COMMON_PKG="nvidia-kernel-common-$TARGET_DRIVER_MAJOR_VERSION"
KERNEL_SOURCE_PKG="nvidia-kernel-source-$TARGET_DRIVER_MAJOR_VERSION"
ACTUAL_LIB_PKG_TO_FIX="$LIB_PKG_TO_FIX_BASE_NAME"

if apt-cache policy "$LIBNVIDIA_GL_PKG_SERVER" &> /dev/null && ! apt-cache policy "$LIBNVIDIA_GL_PKG_SERVER" | grep -q "Installed: (none)"; then
    ACTUAL_LIB_PKG_TO_FIX="$LIBNVIDIA_GL_PKG_SERVER"
fi

PACKAGES_TO_PROCESS=("$DRIVER_META_PKG" "$ACTUAL_LIB_PKG_TO_FIX" "$UTILS_PKG" "$KERNEL_COMMON_PKG" "$KERNEL_SOURCE_PKG")
APT_COMMAND_ARGS=""
for pkg_base_name in "${PACKAGES_TO_PROCESS[@]}"; do
    if apt-cache show "$pkg_base_name" > /dev/null 2>&1; then
        pkg_spec="$pkg_base_name"
        if [ -n "$FINAL_TARGET_VERSION_CORE" ]; then
             VERSION_TO_INSTALL_STR=$(apt-cache madison "$pkg_base_name" 2>/dev/null | grep -F "$FINAL_TARGET_VERSION_CORE" | head -1 | awk '{print $3}')
             if [ -n "$VERSION_TO_INSTALL_STR" ]; then
                pkg_spec="$pkg_base_name=$VERSION_TO_INSTALL_STR"
                log_info "  - Funnet spesifikk versjon for $pkg_base_name: $VERSION_TO_INSTALL_STR"
             else
                 log_warn "  - Fant ikke spesifikk pakkeversjon for $pkg_base_name som matcher $FINAL_TARGET_VERSION_CORE. Bruker $pkg_base_name."
             fi
        else
            log_info "  - Legger til $pkg_base_name (nyeste $TARGET_DRIVER_MAJOR_VERSION)"
        fi
        APT_COMMAND_ARGS+="$pkg_spec "
    else
        log_warn "Pakken $pkg_base_name ser ikke ut til å eksistere i repoene, hopper over den."
    fi
done

if [ -z "$(echo "$APT_COMMAND_ARGS" | xargs)" ]; then
    log_error "Ingen gyldige pakker å installere. Avbryter."
    exit 1
fi

log_info "Følgende pakkespesifikasjoner vil bli brukt med apt-get:"
log_info "  $APT_COMMAND_ARGS"

log_info "Kjører: apt-get install -y --reinstall --allow-downgrades --fix-broken $APT_COMMAND_ARGS"
if apt-get install -y --reinstall --allow-downgrades --fix-broken $APT_COMMAND_ARGS; then
    log_success "Pakkeinstallasjon/-reinstallasjon ser ut til å ha lyktes."
    log_warn "En OMSTART (sudo reboot) er nesten helt sikkert nødvendig nå for at endringene skal tre i kraft!"
    log_info "Kjører nvidia-smi for å sjekke status etter fiks..."
    if nvidia-smi; then
        log_success "nvidia-smi kjører nå uten feil! Omstart anbefales fortsatt på det sterkeste."
    else
        log_error "nvidia-smi feiler fortsatt. En omstart (sudo reboot) er definitivt nødvendig."
    fi
else
    log_error "Feil under apt-get install. En omstart (sudo reboot) kan løse problemer med kernel moduler."
fi

exit 0
