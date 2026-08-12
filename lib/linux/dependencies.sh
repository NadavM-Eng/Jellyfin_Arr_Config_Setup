#!/usr/bin/env bash

# ==============================================================================
# MasterBuilder - Linux Dependency Management
# ==============================================================================
#
# Installs and prepares:
#   - curl
#   - ca-certificates
#   - jq
#   - Docker Engine
#   - Docker Compose v2
#
# Docker installation strategy:
#   Ubuntu / Debian       -> official Docker repositories
#   Fedora / RHEL/CentOS -> official Docker repositories
#   Arch                  -> distribution packages
#   Alpine                -> distribution packages
#   openSUSE              -> distribution packages
#
# Unknown distributions are never guessed.
# ==============================================================================


# ------------------------------------------------------------------------------
# Privilege handling
# ------------------------------------------------------------------------------

ROOT_CMD=()

initialize_root_command() {
    if (( EUID == 0 )); then
        ROOT_CMD=()
        return
    fi

    command -v sudo >/dev/null 2>&1 ||
        fatal "Administrative privileges are required, but sudo is not installed."

    ROOT_CMD=(sudo)
}


run_root() {
    "${ROOT_CMD[@]}" "$@"
}


# ------------------------------------------------------------------------------
# Operating system detection
# ------------------------------------------------------------------------------

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_UBUNTU_CODENAME=""
PACKAGE_MANAGER=""


load_os_information() {
    [[ -r /etc/os-release ]] ||
        fatal "Cannot detect this Linux distribution: /etc/os-release is missing."

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"

    [[ -n "$OS_ID" ]] ||
        fatal "Linux distribution ID could not be determined."
}


detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER="apk"
    else
        fatal "No supported Linux package manager was found."
    fi

    info "Detected Linux distribution: $OS_ID"
    info "Detected package manager: $PACKAGE_MANAGER"
}


# ------------------------------------------------------------------------------
# Base utilities
# ------------------------------------------------------------------------------

ensure_base_dependencies() {
    local missing=false

    command -v curl >/dev/null 2>&1 || missing=true
    command -v jq   >/dev/null 2>&1 || missing=true

    if [[ "$missing" == false ]]; then
        info "curl and jq are available."
        return
    fi

    heading "INSTALLING LINUX DEPENDENCIES"

    case "$PACKAGE_MANAGER" in

        apt)
            run_root apt-get update

            run_root apt-get install -y \
                ca-certificates \
                curl \
                jq
            ;;

        dnf)
            run_root dnf install -y \
                ca-certificates \
                curl \
                jq
            ;;

        pacman)
            run_root pacman -S \
                --needed \
                --noconfirm \
                ca-certificates \
                curl \
                jq
            ;;

        zypper)
            run_root zypper \
                --non-interactive \
                install \
                ca-certificates \
                curl \
                jq
            ;;

        apk)
            run_root apk add \
                --no-cache \
                ca-certificates \
                curl \
                jq
            ;;

        *)
            fatal "Automatic dependency installation is unsupported on this distribution."
            ;;
    esac

    command -v curl >/dev/null 2>&1 ||
        fatal "curl installation completed, but curl cannot be found."

    command -v jq >/dev/null 2>&1 ||
        fatal "jq installation completed, but jq cannot be found."

    info "Base Linux dependencies are available."
}


# ------------------------------------------------------------------------------
# Docker - APT family
# ------------------------------------------------------------------------------

install_docker_apt() {
    local docker_family
    local docker_codename
    local docker_repo
    local docker_gpg
    local architecture

    if [[ "$OS_ID" == "ubuntu" ||
          -n "$OS_UBUNTU_CODENAME" ||
          " $OS_ID_LIKE " == *" ubuntu "* ]]
    then
        docker_family="ubuntu"

        docker_codename="${DOCKER_BASE_CODENAME:-${OS_UBUNTU_CODENAME:-$OS_VERSION_CODENAME}}"

    elif [[ "$OS_ID" == "debian" ]]; then
        docker_family="debian"

        docker_codename="${DOCKER_BASE_CODENAME:-$OS_VERSION_CODENAME}"

    else
        fatal "This Debian-family derivative cannot be mapped safely to a Docker repository.

Set DOCKER_BASE_CODENAME to the codename of its Debian base and run the installer again."
    fi

    [[ -n "$docker_codename" ]] ||
        fatal "Could not determine the base distribution codename for Docker."

    docker_repo="https://download.docker.com/linux/$docker_family"
    docker_gpg="$docker_repo/gpg"

    architecture="$(dpkg --print-architecture)"

    info "Docker repository family: $docker_family"
    info "Docker repository codename: $docker_codename"

    run_root apt-get update

    run_root apt-get install -y \
        ca-certificates \
        curl

    run_root install \
        -m 0755 \
        -d \
        /etc/apt/keyrings

    curl -fsSL "$docker_gpg" |
        run_root tee /etc/apt/keyrings/docker.asc \
        >/dev/null

    run_root chmod \
        a+r \
        /etc/apt/keyrings/docker.asc

    printf '%s\n' \
        "Types: deb" \
        "URIs: $docker_repo" \
        "Suites: $docker_codename" \
        "Components: stable" \
        "Architectures: $architecture" \
        "Signed-By: /etc/apt/keyrings/docker.asc" |
        run_root tee \
            /etc/apt/sources.list.d/masterbuilder-docker.sources \
            >/dev/null

    run_root apt-get update

    if ! run_root apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    then
        fatal "Docker installation failed.

An existing distribution-provided Docker/containerd package may conflict with
Docker CE. MasterBuilder will not automatically remove existing packages."
    fi
}


# ------------------------------------------------------------------------------
# Docker - DNF family
# ------------------------------------------------------------------------------

install_docker_dnf() {
    local repo_url

    run_root dnf install -y \
        dnf-plugins-core \
        ca-certificates \
        curl \
        jq

    case "$OS_ID" in

        fedora)
            repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"

            run_root dnf config-manager \
                addrepo \
                --from-repofile \
                "$repo_url"
            ;;

        rhel)
            repo_url="https://download.docker.com/linux/rhel/docker-ce.repo"

            run_root dnf config-manager \
                --add-repo \
                "$repo_url"
            ;;

        centos)
            repo_url="https://download.docker.com/linux/centos/docker-ce.repo"

            run_root dnf config-manager \
                --add-repo \
                "$repo_url"
            ;;

        *)
            fatal "Automatic Docker CE repository configuration is not supported for '$OS_ID'.

Install Docker Engine manually or use a directly supported Fedora/RHEL/CentOS distribution."
            ;;
    esac

    if ! run_root dnf install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    then
        fatal "Docker installation failed.

MasterBuilder will not automatically remove potentially conflicting packages."
    fi
}


# ------------------------------------------------------------------------------
# Docker - native distribution packages
# ------------------------------------------------------------------------------

install_docker_arch() {
    run_root pacman -S \
        --needed \
        --noconfirm \
        docker \
        docker-compose
}


install_docker_alpine() {
    run_root apk add \
        --no-cache \
        docker \
        docker-cli-compose
}


install_docker_opensuse() {
    run_root zypper \
        --non-interactive \
        install \
        docker \
        docker-compose
}


# ------------------------------------------------------------------------------
# Docker installation dispatcher
# ------------------------------------------------------------------------------

install_docker() {
    heading "INSTALLING DOCKER"

    case "$PACKAGE_MANAGER" in

        apt)
            install_docker_apt
            ;;

        dnf)
            install_docker_dnf
            ;;

        pacman)
            install_docker_arch
            ;;

        apk)
            install_docker_alpine
            ;;

        zypper)
            install_docker_opensuse
            ;;

        *)
            fatal "Automatic Docker installation is unsupported on this distribution."
            ;;
    esac

    command -v docker >/dev/null 2>&1 ||
        fatal "Docker installation completed, but the docker command cannot be found."

    info "Docker packages installed."
}


# ------------------------------------------------------------------------------
# Docker service
# ------------------------------------------------------------------------------

start_docker_service() {
    if docker info >/dev/null 2>&1; then
        info "Docker daemon is already available."
        return
    fi

    heading "STARTING DOCKER"

    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl enable --now docker

    elif command -v rc-service >/dev/null 2>&1; then
        run_root rc-update add docker default || true
        run_root rc-service docker start

    elif command -v service >/dev/null 2>&1; then
        run_root service docker start

    else
        fatal "Docker was installed, but no supported service manager was found."
    fi

    if run_root docker info >/dev/null 2>&1; then
        info "Docker daemon is running."
        return
    fi

    fatal "Docker was installed, but the Docker daemon is not responding."
}


# ------------------------------------------------------------------------------
# Docker permissions
# ------------------------------------------------------------------------------

configure_docker_permissions() {
    local installer="$1"
    shift

    if docker info >/dev/null 2>&1; then
        info "Current user can access Docker."
        return
    fi

    if (( EUID == 0 )); then
        fatal "Docker is running but cannot be accessed by root."
    fi

    if ! run_root docker info >/dev/null 2>&1; then
        fatal "Docker daemon is not available."
    fi

    info "Adding '$USER' to the docker group..."

    if ! getent group docker >/dev/null 2>&1; then
        run_root groupadd docker
    fi

    run_root usermod \
        -aG docker \
        "$USER"

    warn "Membership in the docker group grants root-level privileges."

    # The current shell does not automatically receive new supplementary groups.
    # sg lets this installation continue immediately in the updated docker group.
    if command -v sg >/dev/null 2>&1; then
        local command_line=""

        printf -v command_line '%q ' \
            "$installer" \
            "$@"

        info "Refreshing Docker group membership..."

        exec sg docker -c "$command_line"
    fi

    fatal "Docker permissions were configured, but the current session must be refreshed.

Log out and back in, then run the installer again."
}


# ------------------------------------------------------------------------------
# Complete dependency bootstrap
# ------------------------------------------------------------------------------

ensure_linux_dependencies() {
    local installer="$1"
    shift

    initialize_root_command
    load_os_information
    detect_package_manager

    ensure_base_dependencies

    if command -v docker >/dev/null 2>&1; then

        if ! docker compose version >/dev/null 2>&1; then
            fatal "Docker is already installed, but Docker Compose v2 is missing.

MasterBuilder will not replace an existing Docker installation automatically."
        fi

        info "Docker and Docker Compose are installed."

    else

        install_docker

    fi

    start_docker_service

    docker compose version >/dev/null 2>&1 ||
        fatal "Docker Compose v2 is not available after installation."

    configure_docker_permissions \
        "$installer" \
        "$@"
}
