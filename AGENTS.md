# AGENTS.md

## Purpose

This file defines how humans and AI agents must work in this repository.

The project deploys and configures a modular Jellyfin media stack. Linux is the
currently supported installation target. The Windows repository checkout is a
development copy; `windows-setup.ps1` is still an incomplete prototype and must
not be treated as equivalent to the Linux installer.

Read this file before planning or changing code. User instructions for a
specific task take precedence, but these project rules remain the default.


## Understand the project before editing

Before making changes:

1. Run `git status --short --branch` and preserve unrelated work.
2. Read the relevant recent commits with `git log` to understand the project's
   language, direction, and commit-message style.
3. Trace the complete path affected by the change: selection, Compose,
   bootstrap, configuration, restart behavior, and verification.
4. Read the owning service's complete bootstrap and any files it sources.
5. Check callers and downstream consumers before changing a shared variable,
   JSON field, function, path, service name, or execution order.

Do not implement from assumptions when the current source or upstream API can
answer the question.


## Current repository structure

```text
compose/                 Docker Compose modules; one service or tightly related
                         service group per file.

bootstrap/<service>/     Application-level configuration owned by that service.

bootstrap/sonarr/        Sonarr setup, Custom Formats, profiles, routing, and
                         download-client configuration.

bootstrap/radarr/        Radarr setup, Custom Formats, profiles, and
                         download-client configuration.

bootstrap/jellyfin/      Jellyfin server, libraries, permissions, and plugin
                         management.

lib/                     Shared installer helpers that do not belong to one
                         application.

linux-setup.sh           Linux entry point and current Quick orchestration.

quick-stack.txt          Current Quick Compose selection.
```

Compose files start containers. Bootstrap files configure applications. Keep
those responsibilities separate.


## Non-negotiable product rules

### 1. Quick Setup is fully preconfigured

Quick Setup must produce a usable, connected installation with the recommended
services, settings, plugins, integrations, and verification already applied.

Quick is a preset. It must not become a second implementation of installation
logic.


### 2. Custom Setup uses the same engine

Custom Setup may choose different services, plugins, integrations, and options,
but it must execute the same component code used by Quick Setup.

Do not create `quick-*` and `custom-*` versions of the same bootstrap behavior.
The selector changes; the executor does not.


### 3. A future GUI must use the same orchestration

Design orchestration as:

```text
Quick preset --+
Custom CLI ----+--> installation plan --> validator --> executor
Future GUI ----+
```

Interactive prompts belong in selectors. Service bootstraps and the executor
must remain usable non-interactively from a validated plan.

Do not embed terminal menus, GUI assumptions, or presentation state inside
service configuration logic. A future GUI should only need to build and submit
the same plan, observe structured progress, and display the result.


### 4. Rules must be visible in the repository

Do not rely on conversation history or agent memory for architectural rules.
Record important conventions in `AGENTS.md`, relevant READMEs, schemas, file
names, and validation code.


## Ownership rules

Configuration belongs to the component whose settings are being changed.

Examples:

- A Prowlarr application connection belongs to Prowlarr.
- A Bazarr connection to Sonarr belongs to Bazarr.
- Seerr media-server settings belong to Seerr.
- Jellyfin Enhanced settings belong to the Jellyfin Enhanced plugin.
- Shokofin settings belong to the Shokofin plugin.

Do not create a global `bootstrap/integrations/` directory. It becomes an
ownerless collection of unrelated cross-service scripts.

Service-local integration modules are acceptable when that service owns the
setting. Plugin-specific post-install configuration belongs inside that
plugin's Jellyfin subsystem, not in a global folder.

The orchestrator owns only selection, dependency validation, phase ordering,
and progress. It must not contain application-specific API payloads.


## Required lifecycle boundaries

New orchestration should move toward these explicit phases:

1. Build the selected installation plan.
2. Validate component IDs, options, and dependencies before changing state.
3. Create storage and start selected containers.
4. Configure selected core services.
5. Install selected extensions and plugins.
6. Restart each affected service at most once per phase when practical.
7. Configure selected component-owned integrations.
8. Verify the complete selected plan.

Do not solve an ordering problem by adding a one-off call in an unrelated
bootstrap. Fix ownership or phase ordering.

Existing working behavior should be migrated incrementally. Do not rewrite the
whole installer merely to introduce these boundaries.


## Selection and component definitions

Definitions describe what is available. Installation plans describe what is
selected.

Therefore:

- use stable machine IDs for selectable services, plugins, and integrations;
- keep display names separate from stable IDs;
- do not add fields such as `quick: true` to reusable component definitions;
- do not install every discovered definition automatically unless the selected
  plan explicitly contains every definition;
- reject unknown or duplicate selected IDs before making changes;
- distinguish hard dependencies from optional integrations or optional
  features;
- do not remove an unselected existing component unless the user explicitly
  requested removal.

Adding a definition file should normally extend discovery without requiring a
large central conditional block.


## Engineering principles

### SOLID

Apply SOLID pragmatically to Bash, PowerShell, Compose, and JSON:

- **Single Responsibility:** each script or function should have one clear
  reason to change. Selection, orchestration, API transport, configuration, and
  verification should not be mixed without need.
- **Open/Closed:** prefer adding a definition or an owned module over editing a
  growing central list of service-specific branches.
- **Liskov Substitution:** components participating in a shared lifecycle must
  honor the same documented inputs, exit behavior, and verification contract.
- **Interface Segregation:** expose small phase-specific operations instead of
  requiring every component to implement unrelated behavior.
- **Dependency Inversion:** orchestration depends on component IDs, plans, and
  lifecycle contracts; it must not depend on internal API payload details.


### KISS

Choose the smallest design that satisfies the current requirement and preserves
the shared Quick/Custom/GUI path. Prefer readable shell and JSON over a custom
framework.

An abstraction must remove real duplication or enable a known variation. Do not
add layers only because they might be useful someday.


### DRY

Keep one implementation for behavior shared by Quick, Custom, and a future GUI.
Extract shared API/authentication helpers when multiple scripts genuinely need
the same behavior.

Do not force unrelated services into one generic function merely because their
code looks similar.


### YAGNI

Do not implement speculative services, plugin features, removal behavior,
rollback engines, or generic dependency systems before they are required.

Design clean extension points, then implement the current feature through them.


## Idempotency and user-state safety

Bootstrap operations must be safe to run more than once.

Prefer this behavior:

- create missing managed state;
- leave matching state unchanged;
- update only fields the project intentionally manages;
- preserve unrelated user settings;
- verify after writes;
- fail on ambiguous conflicts instead of silently overwriting them.

Never print secrets, API keys, passwords, cookies, or complete authenticated
responses containing credentials. Keep `.env` private and out of Git.

Do not delete containers, configuration, media, plugins, or user-created state
unless removal is explicitly requested and its scope is verified.


## Error handling and verification

- Keep `set -Eeuo pipefail` on executable Bash entry points.
- Validate required files and tools before modifying application state.
- Use bounded waits with useful failure messages.
- A successful API response is not always successful configuration; read the
  resulting state and verify managed fields.
- Verification for a required managed component must fail the run when the
  component is missing or incorrect. Warnings are for genuinely optional
  behavior.
- Restart only when state changed, and batch related changes before restarting
  when possible.


## Scope and change discipline

- Preserve unrelated user changes in a dirty worktree.
- Keep changes focused on the requested behavior.
- Avoid opportunistic repository-wide rewrites.
- Do not introduce a new top-level architectural category without being able to
  state exactly what belongs there and what does not.
- Avoid line-ending-only changes when editing the Windows checkout. Git stores
  the Linux shell files with LF endings; do not create noisy whole-file diffs.
- Update documentation when a convention, schema, file layout, or supported
  workflow changes.


## Commit policy

Review recent commit history before composing every commit message. Match the
project's plain-language style while keeping spelling and intent clear.

Every commit subject must begin with exactly one of these lowercase words:

- `added` - a new file, definition, component, or capability;
- `modified` - changed behavior, configuration, structure, or documentation;
- `fixed` - correction of a defect or regression;
- `finished` - completion of a feature developed across multiple commits.

Examples:

```text
added AGENTS.md with architecture and commit rules
modified Jellyfin plugin orchestration to run after Seerr
fixed plugin selection installing unselected definitions
finished Jellyfin Enhanced and Seerr integration
```

Use commits extensively. Create a commit whenever a meaningful, independently
understandable unit is complete, including:

- adding a substantial new file or definition;
- completing a focused refactor;
- changing a meaningful behavior;
- fixing a specific problem;
- completing and verifying a feature.

Do not combine unrelated work in one commit. Do not create broken checkpoint
commits merely to increase the commit count. Each commit should be reviewable,
revertible, and pass the checks relevant to its scope.

Before committing:

1. Inspect `git status`.
2. Inspect the complete diff.
3. Stage explicit intended paths rather than unrelated work.
4. Inspect the staged diff.
5. Run relevant validation.
6. Write a subject beginning with the correct required word.

Never rewrite published history or force-push unless the user explicitly asks.


## Minimum validation

For shell changes, run at minimum:

```bash
bash -n linux-setup.sh
find bootstrap lib -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Use ShellCheck when available.

For JSON changes, parse every affected definition with `jq`. For Compose
changes, validate the complete selected Compose configuration, not only the
edited YAML file.

For bootstrap behavior, test both:

- a fresh or missing-state path;
- an existing matching-state rerun.

If live service validation cannot be run in the current environment, state that
clearly and provide the exact remaining verification.


## Definition of done

A change is done only when:

- ownership and lifecycle placement are correct;
- Quick remains preconfigured;
- Custom and future GUI paths can reuse the same implementation;
- managed state is idempotent and verified;
- secrets and unrelated user state are preserved;
- documentation reflects new conventions;
- relevant checks pass or remaining environment-only checks are reported;
- commits are focused and follow the required message prefixes.
