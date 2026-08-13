# What the installer does today

## Why this file exists

This file describes the code as it works now. It is not a future design.

We will use it to check that the new shared installer does not forget anything
the current Linux Quick installer already does.


## Commands that exist

| Command | What it does now |
|---|---|
| `./linux-setup.sh quick` | Starts the full Linux stack and configures the main apps. |
| `./linux-setup.sh verify` | Checks seven containers and their config folders. It does not recheck every app setting. |
| `./linux-setup.sh custom` | Stops with a message. Custom Setup is not built yet. |
| `./windows-setup.ps1 quick` | Starts the same Compose stack on Windows. It does not configure the apps. |
| `./remove-containers.sh` | Stops and removes the Quick containers and network. It does not pass `-v`, so Docker volumes and saved files are kept. |

Linux is the only complete setup today. The Windows script is an early test of
starting the containers.


## What Linux Quick does

`linux-setup.sh quick` currently runs these steps:

1. Check or install `curl`, `jq`, Docker, and Docker Compose.
2. Create `.env` if it does not exist.
3. Create the config, download, and media folders.
4. Read the Compose file list from `quick-stack.txt`.
5. Ask Docker Compose to check those files.
6. Show the services and images that will be used.
7. Ask the user before continuing.
8. Pull the images and start all containers.
9. Check seven important containers and their config folders.
10. Configure Prowlarr.
11. Configure qBittorrent.
12. Configure Sonarr.
13. Configure Radarr.
14. Configure Bazarr.
15. Configure Jellyfin and its plugins.
16. Configure Seerr.
17. Show container status and the local web addresses.

All containers start before any app is configured.


## Compose files used by Quick

`quick-stack.txt` contains these files:

| Order | File | Docker service names |
|---:|---|---|
| 1 | `compose/base.yml` | Creates `media_network`. |
| 2 | `compose/reverse-proxy/npm.yml` | `npm` |
| 3 | `compose/reverse-proxy/duckdns.yml` | `duckdns` |
| 4 | `compose/media-management/jellyfin.yml` | `jellyfin` |
| 5 | `compose/media-management/sonarr.yml` | `sonarr` |
| 6 | `compose/media-management/radarr.yml` | `radarr` |
| 7 | `compose/media-management/bazarr.yml` | `bazarr` |
| 8 | `compose/media-management/prowlarr.yml` | `prowlarr` |
| 9 | `compose/bypass/trawl.yml` | `trawl-redis`, `trawl` |
| 10 | `compose/downloads/qbittorrent.yml` | `qbittorrent` |
| 11 | `compose/request-system/seerr.yml` | `seerr` |

Every service joins the same Docker network: `media_network`.


## Containers started by Quick

| Service | Image | Web or host ports | Saved files | Automatic app setup |
|---|---|---|---|---|
| Nginx Proxy Manager | `jc21/nginx-proxy-manager:latest` | HTTP `80`, HTTPS `4443`, admin `81` | `${CONFIG_ROOT}/npm/data`, `${CONFIG_ROOT}/npm/letsencrypt` | No |
| DuckDNS | `lscr.io/linuxserver/duckdns:latest` | None | None | Uses the two DuckDNS values from `.env`, but there is no setup script. |
| Jellyfin | `lscr.io/linuxserver/jellyfin:latest` | `8096` | `${CONFIG_ROOT}/jellyfin`, `${DATA_ROOT}/media` | Yes |
| Sonarr | `lscr.io/linuxserver/sonarr:latest` | `8989` | `${CONFIG_ROOT}/sonarr`, all of `${DATA_ROOT}` | Yes |
| Radarr | `lscr.io/linuxserver/radarr:latest` | `7878` | `${CONFIG_ROOT}/radarr`, all of `${DATA_ROOT}` | Yes |
| Bazarr | `lscr.io/linuxserver/bazarr:latest` | `6767` | `${CONFIG_ROOT}/bazarr`, `${DATA_ROOT}/media` | Yes |
| Prowlarr | `lscr.io/linuxserver/prowlarr:latest` | `9696` | `${CONFIG_ROOT}/prowlarr` | Yes |
| TRAWL | `ghcr.io/germondai/trawl:latest` | No host port | `${CONFIG_ROOT}/trawl/proxy-ca` | Prowlarr adds it as a proxy. TRAWL has no separate setup script. |
| TRAWL Redis | `redis:8.8-alpine` | No host port | Docker volume `trawl_redis_data` | No |
| qBittorrent | `lscr.io/linuxserver/qbittorrent:latest` | Web `8080`, torrent TCP and UDP `6881` | `${CONFIG_ROOT}/qbittorrent`, `${DATA_ROOT}/torrents` | Yes |
| Seerr | `ghcr.io/seerr-team/seerr:latest` | `5055` | `${CONFIG_ROOT}/seerr` | Yes |

The port numbers above are the defaults. Most can be changed in `.env`.


## Folders created by Linux Quick

The default roots are `runtime/config` and `runtime/data`. The user can choose
different roots when `.env` is first created.

Config folders:

```text
npm/data
npm/letsencrypt
jellyfin
sonarr
radarr
bazarr
prowlarr
trawl/proxy-ca
qbittorrent
seerr
```

Data folders:

```text
torrents/movies
torrents/tv
torrents/anime
usenet/incomplete
usenet/complete/movies
usenet/complete/tv
media/movies
media/tv
media/anime
```

The Usenet folders are created, but no Usenet download service is included yet.


## Values written to `.env`

The Linux installer creates `.env` only when the file is missing. If `.env`
already exists, it is reused without adding new missing keys.

| Group | Keys |
|---|---|
| Linux user and paths | `PUID`, `PGID`, `TZ`, `CONFIG_ROOT`, `DATA_ROOT` |
| Nginx Proxy Manager ports | `NPM_HTTP_PORT`, `NPM_HTTPS_PORT`, `NPM_ADMIN_PORT` |
| App ports | `JELLYFIN_PORT`, `SONARR_PORT`, `RADARR_PORT`, `BAZARR_PORT`, `PROWLARR_PORT`, `SEERR_PORT` |
| qBittorrent ports | `QBITTORRENT_WEBUI_PORT`, `QBITTORRENT_TORRENTING_PORT` |
| Jellyfin setup | `JELLYFIN_ADMIN_USERNAME`, `JELLYFIN_ADMIN_PASSWORD`, `JELLYFIN_SERVER_NAME`, `JELLYFIN_ENABLE_REMOTE_ACCESS` |
| qBittorrent login | `QBITTORRENT_USERNAME`, `QBITTORRENT_PASSWORD` |
| Seerr | `SEERR_ADMIN_EMAIL`, `SEERR_LOG_LEVEL` |
| Optional Bazarr login | `BAZARR_OPENSUBTITLES_USERNAME`, `BAZARR_OPENSUBTITLES_PASSWORD` |
| Optional private indexers | `ANIMETOSHO_API_KEY`, `FUZER_COOKIE`, `HEBITS_COOKIE` |
| Optional DuckDNS login | `DUCKDNS_SUBDOMAINS`, `DUCKDNS_TOKEN` |
| TRAWL | `TRAWL_BROWSER_POOL_SIZE`, `TRAWL_PROXY_URL`, `TRAWL_RESIDENTIAL_PROXY_URL`, `TRAWL_MITM_ENABLED`, `TRAWL_MITM_MAX_TIER`, `TRAWL_MITM_DEBUG` |
| App setup switches | `QUICK_CONFIG_QBITTORRENT`, `QUICK_CONFIG_SONARR`, `QUICK_CONFIG_RADARR`, `QUICK_CONFIG_PROWLARR`, `QUICK_CONFIG_BAZARR`, `QUICK_CONFIG_JELLYFIN`, `QUICK_CONFIG_SEERR`, `QUICK_CONFIG_TRAWL` |

The Jellyfin and qBittorrent passwords are randomly made during a new Linux
setup. `.env` is ignored by Git.

The Seerr script also accepts these optional overrides, even though a new
`.env` does not write them:

```text
SEERR_JELLYFIN_HOST
SEERR_JELLYFIN_PORT
SEERR_SONARR_HOST
SEERR_SONARR_PORT
SEERR_RADARR_HOST
SEERR_RADARR_PORT
SEERR_SONARR_STANDARD_PROFILE
```


## What each app setup script does

### Prowlarr

File: `bootstrap/prowlarr/setup.sh`

- Reads the Prowlarr, Sonarr, and Radarr API keys from their `config.xml` files.
- Waits for Prowlarr, Sonarr, Radarr, and TRAWL.
- Adds Sonarr to Prowlarr.
- Adds Radarr to Prowlarr.
- Adds TRAWL as a FlareSolverr-compatible proxy.
- Adds the public indexers `1337x`, `nekoBT`, `Nyaa.si`, `The Pirate Bay`, and
  `Shana Project`.
- Gives `1337x` the TRAWL tag.
- Adds Anime Tosho, Fuzer, and Hebits only when their `.env` value is present.

Prowlarr runs first, even though it needs Sonarr, Radarr, and TRAWL to be ready.
This works because all containers were already started.


### qBittorrent

File: `bootstrap/qbittorrent/setup.sh`

- Waits for the Web API.
- Logs in with the temporary first-run password when needed.
- Sets the permanent username and generated password from `.env`.
- Sets the default download path to `/data/torrents`.
- Enables Automatic Torrent Management.
- Creates or updates these categories:

| Category | Folder |
|---|---|
| `sonarr` | `/data/torrents/tv` |
| `anime` | `/data/torrents/anime` |
| `radarr` | `/data/torrents/movies` |


### Sonarr

Main file: `bootstrap/sonarr/setup.sh`

- Adds `/data/media/tv` and `/data/media/anime` as root folders.
- Enables episode renaming and sets names for normal, daily, and anime shows.
- Loads every JSON file from `bootstrap/sonarr/custom-formats/`:
  `AV1`, `HEVC`, `v1`, `v2`, `v3`, `v4`, `No Español`, and
  `NO KAF, NO FRENCH`.
- Loads the `Anime` quality profile from `bootstrap/sonarr/profiles/anime.json`.
- Creates the `anime` tag and the `MasterBuilder Anime Routing` rule.
- Applies the tag to existing anime series.
- Adds one qBittorrent client for normal TV using category `sonarr`.
- Adds a second qBittorrent client for anime using category `anime` and the
  `anime` tag.
- Checks the managed folders, naming, formats, profile, routing, and download
  clients.


### Radarr

Main file: `bootstrap/radarr/setup.sh`

- Adds `/data/media/movies` as its root folder.
- Enables movie renaming.
- Loads `10bit`, `HDR`, and `x265` from
  `bootstrap/radarr/custom-formats/`.
- Loads two quality profiles: `Smart Downloader \\ הורדה חכמה` and
  `סרטים הורדה בעברית`.
- Adds qBittorrent using Docker name `qbittorrent` and category `radarr`.
- Tests and checks the managed settings.


### Bazarr

File: `bootstrap/bazarr/setup.sh`

- Creates an `English + Hebrew` language profile.
- Makes it the default for new series and movies.
- Treats embedded subtitles as already downloaded.
- Enables hearing-impaired subtitle cleanup.
- Connects Bazarr to Sonarr at `sonarr:8989`.
- Connects Bazarr to Radarr at `radarr:7878`.
- Enables OpenSubtitles.com only when both login values exist in `.env`.
- Checks the language profile, subtitle settings, and Arr connections.


### Jellyfin

Main file: `bootstrap/jellyfin/setup.sh`

- Uses the existing admin when the `.env` login works.
- Otherwise, completes a new Jellyfin setup with the name, admin, password, and
  remote-access choice from `.env`.
- Creates these libraries:

| Library | Folder | Jellyfin type |
|---|---|---|
| Movies | `/data/media/movies` | Movies |
| TV Shows | `/data/media/tv` | TV shows |
| Anime | `/data/media/anime` | TV shows |

- Gives the admin permission to delete media.
- Reads one plugin list from `bootstrap/jellyfin/plugins/plugins.json`.
- Installs every plugin in that file: `Jellyfin Enhanced` and `Intro Skipper`.
- Restarts Jellyfin once if plugin changes need it.
- Checks that both plugins are active.

The current plugin setup does not let Quick or Custom choose one plugin without
the other. It also does not configure Jellyfin Enhanced to use Seerr.


### Seerr

File: `bootstrap/seerr/setup.sh`

- Connects to Jellyfin with the Jellyfin admin login.
- Creates or logs in to the Seerr admin.
- Enables the Jellyfin Movies, TV Shows, and Anime libraries in Seerr.
- Adds Radarr with `/data/media/movies` and the
  `Smart Downloader \\ הורדה חכמה` profile.
- Adds normal Sonarr requests with `/data/media/tv` and profile `Any`.
- Adds anime Sonarr requests with `/data/media/anime` and profile `Anime`.
- Enables automatic searches and syncing.
- Marks Seerr as initialized.
- Checks the login, media-server type, libraries, Sonarr, Radarr, and initialized
  state.

Seerr runs after Jellyfin, so the Jellyfin admin and libraries already exist.


## What the infrastructure check covers

Before app setup, Linux Quick checks these services:

```text
prowlarr
qbittorrent
sonarr
radarr
bazarr
jellyfin
seerr
```

For each one, it checks that:

- the container exists;
- the container is running;
- Docker does not report it as unhealthy;
- it has restarted fewer than five times;
- its host config folder exists and is writable;
- a small test file written on the host appears inside the container.

Nginx Proxy Manager, DuckDNS, TRAWL, and TRAWL Redis are not included in this
general check. Prowlarr waits for TRAWL separately during Prowlarr setup.

`./linux-setup.sh verify` runs this same seven-service check. It does not rerun
the app setup checks listed in the sections above.


## What Windows can do today

`windows-setup.ps1` currently:

- checks Docker and Docker Compose;
- creates a Windows `.env` if one is missing;
- changes Windows paths to a form Docker Compose can use;
- creates config and data folders;
- reads the same `quick-stack.txt` as Linux;
- checks and shows the Compose plan;
- pulls images and starts all containers;
- shows `docker compose ps`.

It does not:

- install or configure Docker Desktop;
- create Jellyfin or qBittorrent passwords;
- run any app setup script;
- check container health and config mounts like Linux;
- show the service links;
- support Custom Setup.

There is also one folder difference today: Linux creates `torrents/anime`, but
the Windows script does not.


## Code that is already shared

| Code or data | Used by |
|---|---|
| `quick-stack.txt` | Linux and Windows use the same Compose file list. |
| `compose/**/*.yml` | Linux and Windows start the same containers from the same files. |
| Sonarr and Radarr JSON files | Linux setup scripts load these files instead of storing every rule in Bash. A future GUI can also read them. |
| Jellyfin plugin JSON | The data can be reused, but it must later be split into one file per plugin. |


## Code that is repeated today

These are possible small Linux helpers later. Nothing is moved yet.

| Repeated job | Where it appears |
|---|---|
| Print info, warnings, and errors | Almost every Bash setup script. |
| Load `.env` | Every main app setup script. |
| Wait for a config file or API | Prowlarr, Sonarr, Radarr, Bazarr, Jellyfin, Seerr, and qBittorrent. |
| Send an API request and check the reply | Repeated inside each app, with app-specific details. |
| Load and check Custom Format JSON | Sonarr and Radarr have very similar code. |
| Load and check quality-profile JSON | Sonarr and Radarr have very similar code. |

We should move code only after checking that the behavior is truly the same.
Similar-looking code is not always safe to join.


## Important limits in the current code

- Linux Quick is one fixed selection. It starts every file in `quick-stack.txt`.
- Custom Setup does not work yet.
- Windows starts containers but does not configure apps.
- An existing `.env` is never updated with newly added keys.
- Jellyfin installs every plugin from one shared list.
- Jellyfin Enhanced has no Seerr setup yet.
- Nginx Proxy Manager and DuckDNS are not configured for a domain or
  certificate.
- There is no separate TRAWL app setup.
- The general infrastructure check covers seven of the eleven services.
- Most images use the moving `latest` tag.

These are facts to preserve or improve deliberately. They are not permission to
change several behaviors at once.
