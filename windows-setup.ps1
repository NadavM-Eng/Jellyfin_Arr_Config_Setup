#Requires -Version 5.1
<###############################################################################
MasterBuilder - Windows Installer

Requirements:
- Windows PowerShell / PowerShell
- Docker Desktop / Docker Engine
- Docker Compose v2

QUICK SETUP:
Reads quick-stack.txt, validates every registered Compose file, prints the exact
services/images Docker will use, pulls them, and starts the complete stack.

ADDING A CONTAINER LATER:
1. Add its YAML file under compose/<module>/
2. Add that YAML path to quick-stack.txt
3. If it needs a new persistent directory or variable, add it below.

FUTURE:
Invoke-QuickConfiguration is reserved for automatic application configuration.
###############################################################################>

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ==============================================================================
# Project paths
# ==============================================================================
$ProjectRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile       = Join-Path $ProjectRoot ".env"
$QuickManifest = Join-Path $ProjectRoot "quick-stack.txt"

# ==============================================================================
# Persistent directory structure
# ==============================================================================
$ConfigDirectories = @(
    "npm/data",
    "npm/letsencrypt",
    "jellyfin",
    "sonarr",
    "radarr",
    "bazarr",
    "prowlarr",
    "trawl/proxy-ca",
    "qbittorrent",
    "seerr"
)

$DataDirectories = @(
    "torrents/movies",
    "torrents/tv",
    "usenet/incomplete",
    "usenet/complete/movies",
    "usenet/complete/tv",
    "media/movies",
    "media/tv",
    "media/anime"
)

# ==============================================================================
# Output helpers
# ==============================================================================
function Write-Heading([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 72)
    Write-Host $Text
    Write-Host ("=" * 72)
}

function Write-Info([string]$Text)    { Write-Host "[+] $Text" }
function Write-Warning2([string]$Text) { Write-Host "[!] $Text" -ForegroundColor Yellow }
function Stop-WithError([string]$Text) { throw "[X] $Text" }

function Convert-ToComposePath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
}

# ==============================================================================
# Docker checks
# ==============================================================================
function Test-Docker {
    Write-Heading "CHECKING DOCKER"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-WithError "Docker was not found in PATH."
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Docker is installed, but the Docker daemon is not available."
    }

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Docker Compose v2 ('docker compose') is not available."
    }

    Write-Info "Docker is available."
    Write-Info "Docker Compose is available."
}

# ==============================================================================
# .env handling
# ==============================================================================
function Get-EnvValue([string]$Key) {
    if (-not (Test-Path $EnvFile)) { return $null }

    $line = Get-Content $EnvFile |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Key))=" } |
        Select-Object -Last 1

    if (-not $line) { return $null }

    $value = ($line -split '=', 2)[1].Trim()

    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    return $value
}

function Initialize-Environment {
    Write-Heading "INITIALIZING VARIABLES"

    if (Test-Path $EnvFile) {
        Write-Info "Existing .env found. Reusing it."
        return
    }

    $defaultConfig = Join-Path $ProjectRoot "runtime/config"
    $defaultData   = Join-Path $ProjectRoot "runtime/data"

    $configInput = Read-Host "Config root [$defaultConfig]"
    $dataInput   = Read-Host "Data root   [$defaultData]"

    if ([string]::IsNullOrWhiteSpace($configInput)) { $configInput = $defaultConfig }
    if ([string]::IsNullOrWhiteSpace($dataInput))   { $dataInput = $defaultData }

    $configRoot = Convert-ToComposePath $configInput
    $dataRoot   = Convert-ToComposePath $dataInput

    # LinuxServer containers use Linux UID/GID internally. Under Docker Desktop
    # on Windows, 1000:1000 is our portable Quick Setup default and can later be
    # overridden directly in .env.
    $content = @"
# MasterBuilder environment

PUID=1000
PGID=1000
TZ=Asia/Jerusalem

CONFIG_ROOT="$configRoot"
DATA_ROOT="$dataRoot"

# Reverse Proxy / DuckDNS
DUCKDNS_SUBDOMAINS=
DUCKDNS_TOKEN=

# qBittorrent
QBITTORRENT_WEBUI_PORT=8080
QBITTORRENT_TORRENTING_PORT=6881

# TRAWL
TRAWL_BROWSER_POOL_SIZE=1
TRAWL_PROXY_URL=
TRAWL_RESIDENTIAL_PROXY_URL=
TRAWL_MITM_ENABLED=false
TRAWL_MITM_MAX_TIER=3
TRAWL_MITM_DEBUG=false

# -----------------------------------------------------------------------------
# Future Quick Configuration switches
# These do nothing yet. They reserve the structure for the bootstrap stage.
# -----------------------------------------------------------------------------
QUICK_CONFIG_QBITTORRENT=false
QUICK_CONFIG_SONARR=false
QUICK_CONFIG_RADARR=false
QUICK_CONFIG_PROWLARR=false
QUICK_CONFIG_SEERR=false
QUICK_CONFIG_JELLYFIN=false
QUICK_CONFIG_TRAWL=false
"@

    Set-Content -Path $EnvFile -Value $content -Encoding UTF8
    Write-Info "Created $EnvFile"
}

# ==============================================================================
# Storage initialization
# ==============================================================================
function Initialize-Directories {
    Write-Heading "INITIALIZING DIRECTORIES"

    $configRoot = Get-EnvValue "CONFIG_ROOT"
    $dataRoot   = Get-EnvValue "DATA_ROOT"

    if ([string]::IsNullOrWhiteSpace($configRoot)) { Stop-WithError "CONFIG_ROOT is missing from .env." }
    if ([string]::IsNullOrWhiteSpace($dataRoot))   { Stop-WithError "DATA_ROOT is missing from .env." }

    New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null

    foreach ($relative in $ConfigDirectories) {
        New-Item -ItemType Directory -Force -Path (Join-Path $configRoot $relative) | Out-Null
    }

    foreach ($relative in $DataDirectories) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot $relative) | Out-Null
    }

    Write-Info "Config root: $configRoot"
    Write-Info "Data root:   $dataRoot"
}

# ==============================================================================
# Quick Setup manifest
# ==============================================================================
function Get-QuickComposeFiles {
    if (-not (Test-Path $QuickManifest)) {
        Stop-WithError "Missing quick-stack.txt."
    }

    $files = @()

    foreach ($rawLine in Get-Content $QuickManifest) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }

        $path = Join-Path $ProjectRoot $line

        if (-not (Test-Path $path)) {
            Stop-WithError "Missing Compose file: $line"
        }

        $files += (Resolve-Path $path).Path
    }

    if ($files.Count -eq 0) {
        Stop-WithError "quick-stack.txt does not contain any Compose files."
    }

    return $files
}

function Invoke-QuickCompose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComposeFiles,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$ComposeArguments
    )

    $arguments = @(
        "compose",
        "--project-directory", $ProjectRoot,
        "--env-file", $EnvFile
    )

    foreach ($file in $ComposeFiles) {
        $arguments += @("-f", $file)
    }

    $arguments += $ComposeArguments

    & docker @arguments

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Docker Compose command failed."
    }
}

# ==============================================================================
# Exact Quick Setup summary
# ==============================================================================
function Show-QuickPlan([string[]]$ComposeFiles) {
    Write-Heading "QUICK SETUP - EVERYTHING BELOW WILL BE INSTALLED"

    Write-Host "Modules:"
    Write-Host "  - Reverse Proxy       (NPM, DuckDNS)"
    Write-Host "  - Media Management    (Jellyfin, Sonarr, Radarr, Bazarr, Prowlarr)"
    Write-Host "  - Bypass              (TRAWL, TRAWL Redis)"
    Write-Host "  - Downloads           (qBittorrent)"
    Write-Host "  - Request System      (Seerr)"

    Write-Heading "SERVICES"
    Invoke-QuickCompose -ComposeFiles $ComposeFiles config --services

    Write-Heading "IMAGES TO DOWNLOAD / USE"
    Invoke-QuickCompose -ComposeFiles $ComposeFiles config --images
}

function Test-QuickCompose([string[]]$ComposeFiles) {
    Write-Heading "VALIDATING COMPOSE"
    Invoke-QuickCompose -ComposeFiles $ComposeFiles config --quiet
    Write-Info "Compose configuration is valid."
}

# ==============================================================================
# Future application-level bootstrap
# ==============================================================================
function Invoke-QuickConfiguration {
    # FUTURE IMPLEMENTATION:
    # - Configure qBittorrent categories and paths
    # - Connect Sonarr -> qBittorrent
    # - Connect Radarr -> qBittorrent
    # - Connect Prowlarr -> Sonarr/Radarr
    # - Configure TRAWL proxy in Prowlarr
    # - Connect Seerr -> Sonarr/Radarr
    # - Initialize Jellyfin libraries
}

# ==============================================================================
# Quick Setup
# ==============================================================================
function Start-QuickSetup {
    Test-Docker
    Initialize-Environment
    Initialize-Directories

    $composeFiles = Get-QuickComposeFiles

    Test-QuickCompose $composeFiles
    Show-QuickPlan $composeFiles

    $answer = Read-Host "`nQuick Setup installs the entire registered stack. Continue? [Y/n]"
    if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer -notmatch '^(y|yes)$') {
        Write-Info "Cancelled."
        return
    }

    Write-Heading "PULLING IMAGES"
    Invoke-QuickCompose -ComposeFiles $composeFiles pull

    Write-Heading "STARTING CONTAINERS"
    Invoke-QuickCompose -ComposeFiles $composeFiles up -d

    Invoke-QuickConfiguration

    Write-Heading "STACK STATUS"
    Invoke-QuickCompose -ComposeFiles $composeFiles ps

    Write-Heading "QUICK SETUP COMPLETE"
    Write-Info "The Docker infrastructure is running."
    Write-Info "Application-level Quick Configuration will be added in the bootstrap stage."
}

# ==============================================================================
# Main menu
# ==============================================================================
function Main {
    param([string]$Mode)

    switch ($Mode) {
        "quick" {
            Start-QuickSetup
            return
        }
        "custom" {
            Stop-WithError "Custom Setup is reserved for the next stage. Use Quick Setup for now."
        }
        "" {
            Write-Heading "MASTERBUILDER"
            Write-Host "1) Quick Setup  - install everything currently registered"
            Write-Host "2) Custom Setup - future"

            $choice = Read-Host "`nSelect [1]"
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

            switch ($choice) {
                "1" { Start-QuickSetup }
                "2" { Stop-WithError "Custom Setup is reserved for the next stage." }
                default { Stop-WithError "Invalid selection." }
            }
            return
        }
        default {
            Stop-WithError "Usage: .\setup.ps1 [quick|custom]"
        }
    }
}

$mode = if ($args.Count -gt 0) { [string]$args[0] } else { "" }
Main $mode
