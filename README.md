# UltimateComfy.sh Script

## Overview

`UltimateComfy.sh` is a comprehensive bash script designed to simplify the setup, management, and usage of ComfyUI through Docker. It provides a menu-driven interface for various operations, including:

-   **Initial Docker Setup:** Configures the necessary directory structure, generates a Dockerfile tailored for ComfyUI with NVIDIA GPU support, and builds the Docker image.
-   **Docker Image Management:** Allows users to rebuild or update the ComfyUI Docker image.
-   **Model Downloading:** Features a utility to download models from a specified server, either individually, by pre-defined packages, or all at once. It helps manage the ComfyUI models directory.
-   **Container Management:** Provides easy options to start and stop ComfyUI Docker containers. For multi-GPU setups, it manages separate containers per GPU.

The script aims to streamline the ComfyUI experience, especially for users who prefer Docker-based installations and need to manage multiple GPUs or model repositories.

## Key Features

-   **Automated Dockerfile Generation:** Creates a Dockerfile based on specified CUDA versions and sets up a Python virtual environment.
-   **Multi-GPU Support:** During the initial setup, users can specify the number of GPUs. The script then generates start/stop scripts that manage individual Docker containers per GPU, mapping them to different host ports.
-   **Flexible Model Management:** Connects to a model server (configurable) to browse and download models directly into the appropriate ComfyUI data directories.
-   **User-Friendly Menu:** Interactive menus guide the user through different operations.
-   **Path Auto-detection & Manual Override:** Attempts to find existing ComfyUI data paths but also allows manual path specification for model downloads.

## Auto-Download Service

The `UltimateComfy.sh` setup now includes an automated background service (`auto_download_service.sh`) designed to keep your ComfyUI assets up-to-date.

**Host Prerequisites:**
-   For the service to automatically install Python dependencies for custom nodes (from `requirements.txt` files), `python3` and `python3-pip` must be installed and available in the PATH on the host system where `auto_download_service.sh` runs. If these are not present, `git clone` operations will still complete, but dependency installation will fail (and be retried on subsequent checks if the node isn't marked as 'processed').

**Functionality:**
-   **Automatic Updates:** The service runs in the background when you start ComfyUI using the generated `start_comfyui.sh` script. It polls a pre-configured server every 10 seconds.
-   **Custom Nodes:**
    -   Checks for new custom nodes on the server (expected under an `Auto/Nodes/` directory on the server).
    -   Downloads new nodes to your local `$BASE_DOCKER_SETUP_DIR/comfyui_data/custom_nodes/` directory, preserving any subdirectory structure from the server.
    -   Installs Python dependencies by running `pip install -r requirements.txt` if a `requirements.txt` file is found within the downloaded node's directory.
    -   Automatically triggers a restart of the ComfyUI Docker containers if a new node and its dependencies (if any) are successfully downloaded and installed.
-   **Models:**
    -   Checks for new models on the server (expected under an `Auto/Models/` directory on the server).
    -   Downloads new models (individual files or files within one level of subdirectories) to your local `$BASE_DOCKER_SETUP_DIR/comfyui_data/models/` directory, preserving structure.
    -   Downloading new models does **not** trigger a restart of ComfyUI.

**Monitoring the Service:**
-   **Log File:** The service logs its activities to `$BASE_DOCKER_SETUP_DIR/auto_download_service.log`. If the `BASE_DOCKER_SETUP_DIR` variable is not set when the service starts (which is unlikely when launched via `start_comfyui.sh`), logs will fallback to `/tmp/auto_download_service.log`.
-   **Process ID (PID):** When active, the service's PID is stored in `$BASE_DOCKER_SETUP_DIR/scripts/auto_download_service.pid`.
-   **Checking Status:** You can check if the service is running using commands like:
    ```bash
    ps aux | grep auto_download_service.sh
    ```
    Or by checking the contents of the PID file:
    ```bash
    cat $HOME/comfyui_unified_setup/scripts/auto_download_service.pid
    ```
    (Adjust `$HOME/comfyui_unified_setup` if your `BASE_DOCKER_SETUP_DIR` is different).

**Lifecycle:**
-   The auto-download service is automatically started when you run `start_comfyui.sh`.
-   It is automatically stopped when you run `stop_comfyui.sh`.

**Server Configuration:**
-   The service expects new nodes and models to be available on the server configured within the scripts (default: `http://192.168.1.29:8081/`) under the paths `Auto/Nodes/` and `Auto/Models/` respectively.

## Networking Configuration (Previously `--network host`)

Previous versions of this script used the `--network host` setting for Docker. This has been **removed** to ensure cross-platform compatibility, as it is not supported on Windows or macOS.

The script now uses standard Docker port mapping (`-p <host_port>:<container_port>`). For example, `-p 8188:8188`.

**Implications of this change:**
-   **Cross-Platform Support:** The script now works correctly on Linux, Windows (with Docker Desktop), and macOS.
-   **Improved Security:** Containers have their own isolated network stack, which is more secure than sharing the host's network.
-   **No Port Conflicts:** The application inside the container always listens on its default port (8188). The script manages mapping this to unique ports on the host machine for multi-GPU setups (e.g., 8188, 8189, etc.), avoiding conflicts.

## Windows Usage

This script is now compatible with Windows. Here are the prerequisites and instructions:

**1. Prerequisites:**
   - **Git for Windows:** You must install Git for Windows, which includes **Git Bash**. Git Bash is required to run the `.sh` scripts. You can download it from [git-scm.com](https://git-scm.com/).
   - **Docker Desktop:** You must install Docker Desktop for Windows. It should be configured to use the **WSL 2 backend** (this is the default for most modern installations). You can download it from the [Docker website](https://www.docker.com/products/docker-desktop/).
   - **(Optional) NVIDIA GPU Support:**
     - Install the latest **NVIDIA drivers** for your GPU.
     - In Docker Desktop settings, under **Resources > WSL Integration**, ensure your WSL 2 distribution is enabled. GPU support is typically enabled by default if you have a compatible GPU and drivers.
   - **(Optional) `jq` for Model Downloader:** To use the model package downloader, you need the `jq` command-line tool. You can install it using a package manager like Chocolatey (`choco install jq`) or by downloading the executable from the [official jq website](https://jqlang.github.io/jq/download/) and adding it to your system's PATH.

**2. Running the Script:**
   - Instead of running `UltimateComfy.sh` directly, Windows users should use the provided batch file:
     ```
     UltimateComfy.bat
     ```
   - You can simply double-click this file from the Windows File Explorer. It will automatically launch the script in a Git Bash environment.

## Getting Started & Usage

**1. Download the Scripts:**

*   **Recommended Method: `git clone`** (for easy updates)
    ```bash
    git clone https://github.com/Pukerud/UltimatComfy.git
    cd UltimatComfy
    ```

**2. Run the Script:**
*   **On Linux:**
    ```bash
    chmod +x UltimateComfy.sh
    ./UltimateComfy.sh
    ```
*   **On Windows:**
    Double-click `UltimateComfy.bat` in File Explorer, or run it from a command prompt:
    ```cmd
    UltimateComfy.bat
    ```

**3. Follow the on-screen menu options:**
    Once the script is running:
    *   **Option 1 (Førstegangs oppsett/Installer ComfyUI i Docker):** This should be your first step if you haven't set up ComfyUI with this script before. It will:
        *   Ask for the number of GPUs.
        *   Create necessary directories (default: under `$HOME/comfyui_unified_setup`).
        *   Generate a `Dockerfile`.
        *   Build the Docker image.
        *   Generate `start_comfyui.sh` and `stop_comfyui.sh` scripts.
    *   **Option 2 (Bygg/Oppdater ComfyUI Docker Image):** Use this to rebuild the Docker image.
    *   **Option 3 (Last ned/Administrer Modeller):** Access the model downloader utility.
    *   **Option 4 (Start ComfyUI Docker Container(e)):** Runs the generated `start_comfyui.sh`.
    *   **Option 5 (Stopp ComfyUI Docker Container(e)):** Runs the generated `stop_comfyui.sh`.
    *   **Option 12 (Avslutt):** Exits the script.

## Script Variables and Configuration

The script suite uses several global variables for paths and settings. Core constants are defined in `common_utils.sh`, Docker-specific variables in `docker_setup.sh`, and model downloader variables in `model_downloader.sh`. Some default paths are also set in `common_utils.sh` or the respective scripts.

## Important Considerations

-   **Docker and NVIDIA Docker:** Ensure Docker is installed and configured correctly to work with NVIDIA GPUs (e.g., `nvidia-container-toolkit` is installed).
-   **Rootless Docker:** The script uses `docker` commands directly. If you are running Docker in rootless mode, ensure your user has the necessary permissions.
-   **Model Storage:** Models are stored in the `comfyui_data/models` subdirectory within your `BASE_DOCKER_SETUP_DIR`. Ensure you have sufficient disk space.
-   **Multi-GPU Setups:** The script correctly handles multi-GPU setups by launching a separate container for each GPU and mapping them to different host ports (e.g., `localhost:8188` for GPU 0, `localhost:8189` for GPU 1, and so on).

This script provides a powerful way to manage ComfyUI, but always review scripts from the internet before running them, especially those that perform system operations like Docker image building and container management.
