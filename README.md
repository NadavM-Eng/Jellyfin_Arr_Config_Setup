# Jellyfin Arr Config Setup

A modular Docker-based installer for deploying and configuring a Jellyfin media server stack.

The project provides a Linux Quick Setup that creates the required storage structure, starts the Docker Compose stack, verifies the installation, and automatically configures the main applications so they can communicate with one another.

The configuration is designed to be readable, repeatable, and safe to run more than once.

## Project Status

### Linux

Linux is the currently supported platform.

The Linux installer provides the complete Quick Setup workflow, including Docker infrastructure and application-level configuration.

### Windows

Windows support is planned.

`windows-setup.ps1` currently exists as an early infrastructure prototype, but it does **not** yet provide feature parity with the Linux installer and should not be considered a complete Windows installation method.

Windows support will be completed after the Linux implementation is finalized.

## Included Services

| Service | Purpose | Container |
|---|---|---|
| Jellyfin | Media server | LinuxServer.io Jellyfin |
| Sonarr | TV and anime library management | LinuxServer.io Sonarr |
| Radarr | Movie library management | LinuxServer.io Radarr |
| Bazarr | Subtitle management | LinuxServer.io Bazarr |
| Prowlarr | Indexer management and Arr integration | LinuxServer.io Prowlarr |
| qBittorrent | Download client | LinuxServer.io qBittorrent |
| Seerr | Media request interface | Seerr Team |
| Nginx Proxy Manager | Reverse proxy management | Nginx Proxy Manager |
| DuckDNS | Dynamic DNS | LinuxServer.io DuckDNS |
| TRAWL | FlareSolverr-compatible proxy service | TRAWL |
| Redis | TRAWL data/cache service | Redis |

All applications remain independent third-party projects. This repository only provides deployment and configuration automation.

## What Quick Setup Configures

The Linux Quick Setup currently performs the following application configuration automatically:

- creates the Jellyfin administrator account;
- creates Jellyfin Movies, TV Shows, and Anime libraries;
- enables media deletion for the Jellyfin administrator;
- creates qBittorrent download categories and paths;
- configures Sonarr root folders, naming, Custom Formats, Quality Profiles, and qBittorrent;
- configures Radarr root folders, naming, Custom Formats, Quality Profiles, and qBittorrent;
- connects Prowlarr to Sonarr and Radarr;
- configures the TRAWL proxy in Prowlarr;
- configures selected Prowlarr indexers;
- configures Bazarr languages, subtitle behavior, and Sonarr/Radarr connections;
- connects Seerr to Jellyfin, Sonarr, and Radarr;
- enables the Jellyfin libraries in Seerr;
- verifies the persistent Docker configuration mounts before modifying application state.

Most configuration operations are designed to be idempotent. Running Quick Setup again should update or verify managed configuration rather than creating duplicate entries.

## Linux Quick Start

Clone the repository:

```bash
git clone https://github.com/NadavM-Eng/Jellyfin_Arr_Config_Setup.git
cd Jellyfin_Arr_Config_Setup
```

Make the installer executable:

```bash
chmod +x linux-setup.sh
```

Start Quick Setup:

```bash
./linux-setup.sh quick
```

The installer will ask where configuration and media data should be stored.

Press Enter to accept the default locations:

```text
runtime/config
runtime/data
```

The installer then:

1. checks or installs the required Linux dependencies;
2. creates `.env`;
3. creates the persistent directory structure;
4. validates the Compose configuration;
5. pulls the container images;
6. starts the stack;
7. verifies container and bind-mount integrity;
8. runs the application Quick Configuration scripts;
9. prints the local service addresses.

After installation, verify the infrastructure at any time with:

```bash
./linux-setup.sh verify
```

## Generated Credentials

On a new Linux installation, the installer generates credentials for services that require an initial administrator password.

The generated values are stored in:

```text
.env
```

Do not commit `.env`.

To inspect the generated credentials:

```bash
cat .env
```

## Optional Credentials

Some integrations require credentials that cannot be generated automatically.

Edit `.env` after the initial installation if you want to configure them.

### Bazarr / OpenSubtitles.com

```env
BAZARR_OPENSUBTITLES_USERNAME=
BAZARR_OPENSUBTITLES_PASSWORD=
```

### Prowlarr private indexers

```env
ANIMETOSHO_API_KEY=
FUZER_COOKIE=
HEBITS_COOKIE=
```

### DuckDNS

```env
DUCKDNS_SUBDOMAINS=
DUCKDNS_TOKEN=
```

After changing supported application settings, Quick Setup can be run again:

```bash
./linux-setup.sh quick
```

## Storage Layout

The default installation uses:

```text
runtime/
├── config/
│   ├── npm/
│   │   ├── data/
│   │   └── letsencrypt/
│   ├── jellyfin/
│   ├── sonarr/
│   ├── radarr/
│   ├── bazarr/
│   ├── prowlarr/
│   ├── trawl/
│   │   └── proxy-ca/
│   ├── qbittorrent/
│   └── seerr/
│
└── data/
    ├── torrents/
    │   ├── movies/
    │   ├── tv/
    │   └── anime/
    │
    ├── usenet/
    │   ├── incomplete/
    │   └── complete/
    │       ├── movies/
    │       └── tv/
    │
    └── media/
        ├── movies/
        ├── tv/
        └── anime/
```

A different config or data root can be selected during installation.

## Docker Compose Structure

The project uses multiple Compose files instead of one large Compose document.

```text
compose/
├── base.yml
├── reverse-proxy/
├── media-management/
├── bypass/
├── downloads/
└── request-system/
```

`quick-stack.txt` defines which Compose modules are included in Quick Setup.

This keeps individual services easy to inspect, replace, or remove.

## Application Bootstrap Structure

Application configuration is stored separately from Docker Compose:

```text
bootstrap/
├── jellyfin/
├── sonarr/
├── radarr/
├── bazarr/
├── prowlarr/
├── qbittorrent/
└── seerr/
```

The Compose files are responsible for running containers.

The bootstrap scripts are responsible for configuring applications through their APIs or generated configuration.

## Customizing Sonarr

Sonarr Custom Formats and Quality Profiles are data-driven.

See:

```text
bootstrap/sonarr/README.md
```

New JSON definitions placed in the appropriate directories are discovered automatically by the Sonarr bootstrap.

## Customizing Radarr

Radarr Custom Formats and Quality Profiles are also data-driven.

See:

```text
bootstrap/radarr/README.md
```

The loader resolves Radarr IDs and API schemas dynamically instead of storing installation-specific IDs in the repository.

## Reverse Proxy and Remote Access

Nginx Proxy Manager and DuckDNS are included in the Quick Setup stack, but public-domain configuration and certificates are not automatically created by the application bootstrap.

Review your network, firewall, DNS, and reverse-proxy configuration before exposing any service to the public internet.

The applications are published on host ports by Docker and are intended to be reachable on the local network unless you restrict them separately.

## Updating

Pull the newest repository changes:

```bash
git pull
```

Then run:

```bash
./linux-setup.sh quick
```

The installer will reuse the existing `.env`, storage directories, and application configuration where possible.

## Development

Before committing changes to a shell script, at minimum run:

```bash
bash -n linux-setup.sh
```

For bootstrap changes:

```bash
find bootstrap -type f -name '*.sh' -print0 |
    xargs -0 -n1 bash -n
```

Using ShellCheck during development is also recommended.

## Security Notes

Docker normally requires elevated access to its daemon. Users added to the `docker` group effectively receive root-level control over the host through Docker.

Keep `.env` private because it contains service credentials.

Do not expose administration interfaces directly to the public internet without understanding the security implications.

Review third-party application security documentation before enabling remote access.

## Third-Party Projects and Credits

This project builds on the work of the following open-source projects and services:

- [Docker](https://www.docker.com/)
- [Jellyfin](https://jellyfin.org/)
- [Sonarr](https://sonarr.tv/)
- [Radarr](https://radarr.video/)
- [Bazarr](https://www.bazarr.media/)
- [Prowlarr](https://prowlarr.com/)
- [qBittorrent](https://www.qbittorrent.org/)
- [Seerr](https://github.com/seerr-team/seerr)
- [Nginx Proxy Manager](https://nginxproxymanager.com/)
- [DuckDNS](https://www.duckdns.org/)
- [TRAWL](https://github.com/germondai/trawl)
- [Redis](https://redis.io/)
- [LinuxServer.io](https://www.linuxserver.io/)

LinuxServer.io provides the container images used by this project for Jellyfin, Sonarr, Radarr, Bazarr, Prowlarr, qBittorrent, and DuckDNS.

All trademarks, project names, container images, licenses, and copyrights belong to their respective owners.

This project is not affiliated with or endorsed by those projects.

## Responsible Use

This repository provides infrastructure and application-configuration automation.

Users are responsible for complying with the terms of service, licenses, copyright rules, and laws applicable to the services and content they use.

## License

Add a project license before distributing or accepting external contributions if one has not already been selected.
