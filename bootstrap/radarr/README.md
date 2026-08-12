# Radarr Bootstrap Customization

The Radarr bootstrap is data-driven.

Custom Formats and Quality Profiles are defined as JSON files rather than being hard-coded into the Bash scripts.

The bootstrap automatically scans the following directories:

```text
bootstrap/radarr/custom-formats/
bootstrap/radarr/profiles/
```

Every `*.json` file in those directories is processed automatically.

No Radarr database IDs should be stored in these files. IDs and API schemas are resolved dynamically from the running Radarr instance.

## Custom Formats

Custom Format definitions belong in:

```text
bootstrap/radarr/custom-formats/
```

A simple Custom Format looks like:

```json
{
  "name": "Example Format",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "Example",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": false,
      "fields": {
        "value": "\\bEXAMPLE\\b"
      }
    }
  ]
}
```

The filename itself is not used as the Radarr Custom Format name.

This is valid:

```text
my-example.json
```

because the actual name comes from:

```json
"name": "Example Format"
```

## Custom Format Fields

Each Custom Format contains:

### `name`

The Radarr Custom Format name.

It is also used to detect an existing format when the bootstrap is run again.

### `includeCustomFormatWhenRenaming`

Controls Radarr's corresponding Custom Format option.

Usually:

```json
false
```

### `specifications`

An array containing one or more Radarr specifications.

Example:

```json
{
  "name": "Codec",
  "implementation": "ReleaseTitleSpecification",
  "negate": false,
  "required": false,
  "fields": {
    "value": "\\bHEVC\\b"
  }
}
```

The bootstrap requests the current specification schema from Radarr and fills the requested fields by name.

This is why schema-generated IDs and other Radarr-specific runtime values do not need to be stored in the repository.

## Multiple Specifications

Radarr definitions may contain multiple specifications.

For example:

```json
{
  "name": "Example HDR Format",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "HDR",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": false,
      "fields": {
        "value": "\\bHDR\\b"
      }
    },
    {
      "name": "HDR10",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": false,
      "fields": {
        "value": "\\bHDR10\\b"
      }
    }
  ]
}
```

See the existing definitions in:

```text
bootstrap/radarr/custom-formats/
```

for working examples.

## Updating a Custom Format

Custom Formats are matched by `name`.

If a definition with the same name already exists in Radarr:

- an identical definition is left unchanged;
- a changed definition is updated;
- a duplicate is not created.

Therefore, editing the JSON definition and running the bootstrap again is sufficient.

## Quality Profiles

Quality Profile definitions belong in:

```text
bootstrap/radarr/profiles/
```

Example:

```json
{
  "name": "Example Profile",
  "baseProfile": "Any",

  "upgradeAllowed": true,
  "upgradeUntilQuality": "Bluray-2160p",

  "manageQualitiesExactly": true,

  "enableQualities": [
    "WEB 1080p",
    "Bluray-1080p",
    "WEB 2160p",
    "Bluray-2160p"
  ],

  "language": "English",

  "minFormatScore": 0,
  "cutoffFormatScore": 1000,
  "minUpgradeFormatScore": 1,

  "customFormatScores": {
    "Example Format": 500
  }
}
```

## Profile Fields

### `name`

Name of the Quality Profile that will be created or updated.

### `baseProfile`

Existing Radarr profile to use as the starting structure when creating a new profile.

Usually:

```json
"baseProfile": "Any"
```

### `upgradeAllowed`

Controls whether Radarr may upgrade an existing file.

### `upgradeUntilQuality`

Quality used as Radarr's normal Quality cutoff.

The value must match a Quality name that exists in Radarr.

### `manageQualitiesExactly`

When set to:

```json
true
```

the bootstrap enables only the qualities listed in `enableQualities`.

Other qualities are disabled.

When set to:

```json
false
```

the listed qualities are enabled additively and existing enabled qualities are preserved.

### `enableQualities`

Quality names to enable.

Example:

```json
[
  "WEB 1080p",
  "Bluray-1080p"
]
```

Use names from the running Radarr instance rather than numeric IDs.

### `language`

Language assigned to the Radarr profile.

The language must already exist in Radarr.

Example:

```json
"language": "English"
```

### `minFormatScore`

Minimum Custom Format score accepted by the profile.

### `cutoffFormatScore`

Custom Format score at which upgrades stop.

### `minUpgradeFormatScore`

Minimum score improvement required before Radarr upgrades an existing file.

### `customFormatScores`

Maps Custom Format names to profile scores.

Example:

```json
{
  "x265": 3,
  "10bit": 2,
  "HDR": 1
}
```

The names must exactly match Custom Formats that exist in Radarr.

If a profile references a Custom Format that does not exist, the bootstrap stops rather than silently creating an incomplete profile.

## Adding a New Radarr Profile

1. Add any required Custom Format JSON files to:

   ```text
   bootstrap/radarr/custom-formats/
   ```

2. Add a profile JSON file to:

   ```text
   bootstrap/radarr/profiles/
   ```

3. Reference Custom Formats by their exact `name`.

4. Run the Radarr bootstrap or the complete Quick Setup.

From the project root:

```bash
bash bootstrap/radarr/setup.sh
```

or:

```bash
./linux-setup.sh quick
```

The bootstrap will create missing definitions, update changed managed definitions, and verify the result.

## Important Design Rule

Do not hard-code:

- Radarr Quality Profile IDs;
- Custom Format IDs;
- specification IDs;
- root-folder IDs.

The bootstrap is intentionally designed to resolve installation-specific values through the Radarr API.
