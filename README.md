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

## `--network host` Modification

The `docker run` command used to start the ComfyUI containers has been modified to include the `--network host` option.

**What it does:**
When `--network host` is used, the Docker container shares the network stack of the host machine. This means the container does not get its own IP address but uses the host's IP address directly. Any ports opened by applications inside the container will be directly accessible on the host machine's IP, without needing explicit port mapping (`-p host_port:container_port`).

**Implications:**
-   **Simplified Port Access:** The ComfyUI instance running inside the Docker container will be accessible at `http://localhost:8188` (or `http://<host_ip>:8188`), assuming 8188 is the default ComfyUI port. If multiple instances are run, they will need to listen on different ports within the container to avoid conflicts, as they all share the host's network. The script already handles assigning different host ports for multi-GPU setups by incrementing from 8188 (e.g., 8188, 8189, etc.). With `--network host`, the application inside the container *must* listen on these specific ports (e.g., main.py --port 8189). The current script's `CMD` in the Dockerfile is hardcoded to `python3 main.py --listen 0.0.0.0 --port 8188`. This means for multi-GPU setups with `--network host`, only the first instance (on 8188) will be directly accessible unless the `CMD` is made dynamic or the `docker run` command overrides the `CMD` to pass a different `--port` for each instance. *This is a potential issue to be aware of with the current script structure when using `--network host` for multiple containers.*
-   **Potential Port Conflicts:** Since the container uses the host's network directly, if any service on the host machine (or another container using `--network host`) is already using a port that ComfyUI tries to use, there will be a conflict.
-   **Performance:** May offer slight network performance improvements in some cases by reducing network address translation (NAT) overhead.
-   **Security:** Reduces network isolation between the container and the host. Use with caution, especially in multi-tenant environments or when running untrusted images.

**Note on Port Mapping (`-p`):**
The script currently retains the `-p ${host_port}:8188` option in the `docker run` command. When `--network host` is used, explicit port mappings with `-p` are generally ignored or unnecessary. However, their presence shouldn't typically cause issues.

## Getting Started & Usage

This project now consists of multiple script files due to refactoring for better organization. To use `UltimateComfy.sh`, you first need to obtain all the necessary script files.

**1. Download the Scripts:**

*   **Recommended Method: `git clone`** (for easy updates)
    ```bash
    git clone https://github.com/Pukerud/UltimatComfy.git
    cd UltimatComfy
    chmod +x UltimateComfy.sh
    ./UltimateComfy.sh
    ```
    *(The main `UltimateComfy.sh` script needs to be executable. The other `.sh` files (`common_utils.sh`, `docker_setup.sh`, `model_downloader.sh`) are sourced and do not strictly require execute permissions, but it's harmless to set them.)*

    **For Existing Users (Updating an Existing Clone):**
    If you have already cloned the repository, you can update to the latest version by navigating into the `UltimatComfy` directory and running `git pull`:
    ```bash
    cd UltimatComfy  # Ensure you are in the cloned directory
    git pull
    # Then run the script as usual
    ./UltimateComfy.sh
    ```

*   **Alternative Method: Download Archive (Tar.gz)**
    ```bash
    curl -sSL -o UltimatComfy.tar.gz https://github.com/Pukerud/UltimatComfy/archive/refs/heads/main.tar.gz
    tar -xzf UltimatComfy.tar.gz
    # The extracted directory might be named UltimatComfy-main or similar
    cd UltimatComfy-main
    chmod +x UltimateComfy.sh
    ./UltimateComfy.sh
    ```

**2. Follow the on-screen menu options:**
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
    *   **Option 6 (Avslutt):** Exits the script.

## Script Variables and Configuration

The script suite uses several global variables for paths and settings. Core constants are defined in `common_utils.sh`, Docker-specific variables in `docker_setup.sh`, and model downloader variables in `model_downloader.sh`. Some default paths are also set in `common_utils.sh` or the respective scripts.

## Important Considerations

-   **Docker and NVIDIA Docker:** Ensure Docker is installed and configured correctly to work with NVIDIA GPUs (e.g., `nvidia-container-toolkit` is installed).
-   **Rootless Docker:** The script uses `docker` commands directly. If you are running Docker in rootless mode, ensure your user has the necessary permissions.
-   **Model Storage:** Models are stored in the `comfyui_data/models` subdirectory within your `BASE_DOCKER_SETUP_DIR`. Ensure you have sufficient disk space.
-   **Multi-GPU with `--network host`:** As noted in the "Implications" section for `--network host`, the current Dockerfile `CMD` hardcodes the ComfyUI listening port to 8188. For multiple GPU instances to be accessible when using `--network host`, each container would need to be started with a different `--port` argument to `main.py`. The `start_comfyui.sh` script generated by `UltimateComfy.sh` *does* map different host ports (`-p 8188:8188`, `-p 8189:8188`, etc.), but with `--network host`, the internal application port must also change. This means the `-p` option becomes less relevant, and the focus shifts to ensuring the `main.py` command inside each container uses a unique port corresponding to what you expect on the host. The current script does not dynamically adjust the `CMD` for `main.py` for different GPU instances.

This script provides a powerful way to manage ComfyUI, but always review scripts from the internet before running them, especially those that perform system operations like Docker image building and container management.
