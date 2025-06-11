#!/bin/bash

# --- CONFIGURATION ---
TARGET_DRIVER_MAJOR_VERSION="550" # Target NVIDIA driver major version

# --- Logging Function ---
# Simple logger, prepends date and time.
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: $1"
}

log_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARN: $1" >&2
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $1" >&2
}

# --- Helper Functions ---
check_sudo() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script requires superuser (sudo) privileges to run."
        log_error "Please run with sudo: sudo $0"
        exit 1
    fi
    log_info "Sudo privileges confirmed."
}

ensure_graphics_drivers_ppa() {
    log_info "Ensuring the graphics-drivers PPA is added..."
    if ! grep -q "^deb .*ppa:graphics-drivers/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        log_info "Adding graphics-drivers PPA."
        add-apt-repository ppa:graphics-drivers/ppa -y || {
            log_error "Failed to add graphics-drivers PPA. Please check for errors."
            exit 1
        }
        log_info "PPA added. Running apt update..."
        apt-get update || {
            log_error "apt-get update after adding PPA failed."
            exit 1
        }
        log_success "Graphics-drivers PPA added and apt updated successfully."
    else
        log_info "Graphics-drivers PPA already exists."
    fi
}

get_current_driver_version() {
    log_info "Checking current NVIDIA driver version..."
    local current_version
    current_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
    if [[ -z "$current_version" ]]; then
        log_warn "NVIDIA driver not found or nvidia-smi is not working."
        echo "" # Return empty if not found
    else
        log_info "Current NVIDIA driver version: $current_version"
        echo "$current_version"
    fi
}

get_available_target_driver() {
    log_info "Searching for available driver version: nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}..."
    # Ensure apt cache is updated before searching
    apt-cache search "nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}" | grep "^nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}\s" | awk '{print $1}' | sort -V | tail -n 1 || {
        log_warn "No exact match found for nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION} via apt-cache search."
        # Fallback: try to find any driver of that major version if exact name fails
        apt-cache search "nvidia-driver-" | grep "nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}" | awk '{print $1}' | sort -V | tail -n 1
    }
}


# --- Main Script Logic ---
main() {
    log_info "--- NVIDIA Driver Upgrade Script Started ---"
    check_sudo

    ensure_graphics_drivers_ppa

    CURRENT_DRIVER_VERSION=$(get_current_driver_version)
    CURRENT_DRIVER_MAJOR_VERSION=$(echo "$CURRENT_DRIVER_VERSION" | cut -d. -f1)

    if [[ "$CURRENT_DRIVER_VERSION" == "" ]]; then
        log_warn "No NVIDIA driver currently installed or detected."
    elif [[ "$CURRENT_DRIVER_MAJOR_VERSION" -ge "$TARGET_DRIVER_MAJOR_VERSION" ]]; then
        log_info "Current driver version ($CURRENT_DRIVER_VERSION) is already >= target version ($TARGET_DRIVER_MAJOR_VERSION)."
        log_info "No upgrade needed based on major version. If you need a specific minor version, please install manually."
        log_info "--- NVIDIA Driver Upgrade Script Finished ---"
        exit 0
    else
        log_info "Current driver version ($CURRENT_DRIVER_VERSION) is less than target major version ($TARGET_DRIVER_MAJOR_VERSION)."
    fi

    log_info "Searching for the best available nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION} package..."

    # Updated search logic to handle cases where the exact package name isn't found initially
    # and to ensure we get the full package name for installation.
    local full_package_name
    full_package_name=$(apt-cache search "nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}" | grep "^nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}" | awk '{print $1}' | sort -V | tail -n 1)

    if [[ -z "$full_package_name" ]]; then
        log_warn "No package matching 'nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}' found directly."
        log_warn "Attempting a broader search for drivers of major version ${TARGET_DRIVER_MAJOR_VERSION}..."
        # This attempts to find related packages if the direct name isn't available, e.g. nvidia-driver-550-server
        full_package_name=$(apt-cache search "nvidia-driver-" | grep -- "-${TARGET_DRIVER_MAJOR_VERSION}" | awk '{print $1}' | grep "^nvidia-driver-${TARGET_DRIVER_MAJOR_VERSION}" | sort -V | tail -n 1)
    fi

    if [[ -z "$full_package_name" ]]; then
        log_error "Could not find any suitable NVIDIA driver package for major version ${TARGET_DRIVER_MAJOR_VERSION} after extensive search."
        log_error "Please check available drivers with 'apt search nvidia-driver-*' or from the PPA page."
        log_info "--- NVIDIA Driver Upgrade Script Finished (with errors) ---"
        exit 1
    fi

    log_info "Found best available package: $full_package_name"

    echo ""
    log_warn "The script will attempt to install/upgrade to: $full_package_name"
    log_warn "This will involve uninstalling any existing NVIDIA drivers."
    echo -n "Do you want to proceed with the NVIDIA driver upgrade? (yes/no): "
    local confirm
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "User aborted the upgrade."
        log_info "--- NVIDIA Driver Upgrade Script Finished ---"
        exit 0
    fi

    log_info "Proceeding with NVIDIA driver upgrade to $full_package_name..."

    log_info "Purging any existing NVIDIA drivers..."
    apt-get purge -y 'nvidia.*' || {
        log_warn "apt-get purge 'nvidia.*' had some issues. This might be okay if no drivers were installed."
    }
    apt-get autoremove -y || {
        log_warn "apt-get autoremove had some issues."
    }

    log_info "Installing $full_package_name..."
    apt-get install -y "$full_package_name" || {
        log_error "Failed to install $full_package_name."
        log_error "Please check the output for errors. You might need to resolve dependencies or conflicts manually."
        log_info "--- NVIDIA Driver Upgrade Script Finished (with errors) ---"
        exit 1
    }

    log_success "Successfully installed $full_package_name."
    log_warn "A REBOOT IS REQUIRED to load the new NVIDIA driver."
    echo -n "Do you want to reboot now? (yes/no): "
    local reboot_confirm
    read -r reboot_confirm
    if [[ "$reboot_confirm" == "yes" ]]; then
        log_info "Rebooting now..."
        reboot
    else
        log_info "Please reboot your system manually to apply the new driver."
    fi

    log_info "--- NVIDIA Driver Upgrade Script Finished ---"
}

# --- Utility for log_success (if not in common_utils or similar) ---
log_success() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS: $1"
}


# Run main
main "$@"
