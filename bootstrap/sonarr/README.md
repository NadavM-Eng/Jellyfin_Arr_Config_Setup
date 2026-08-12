# Sonarr Bootstrap Customization

The Sonarr bootstrap uses JSON definition files for Custom Formats and Quality Profiles.

The bootstrap automatically scans:

```text
bootstrap/sonarr/custom-formats/
bootstrap/sonarr/profiles/
```

Every `*.json` file in those directories is discovered automatically.

Runtime Sonarr IDs are resolved through the API and should not be hard-coded in the JSON files.

## Custom Formats

Custom Format definitions belong in:

```text
bootstrap/sonarr/custom-formats/
```

Example:

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

The actual Sonarr Custom Format name comes from:

```json
"name": "Example Format"
```

and not from the filename.

## Current Sonarr Custom Format Definition Format

The current Sonarr loader supports one specification per JSON definition and currently manages the specification's `value` field.

For example:

```json
{
  "name": "AV1",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [
    {
      "name": "AV1",
      "implementation": "ReleaseTitleSpecification",
      "negate": false,
      "required": false,
      "fields": {
        "value": "\\b(AV1)\\b"
      }
    }
  ]
}
```

Existing files in:

```text
bootstrap/sonarr/custom-formats/
```

can be used as templates.

## Custom Format Fields

### `name`

Sonarr Custom Format name.

This name is used to determine whether the format already exists.

### `includeCustomFormatWhenRenaming`

Controls the corresponding Sonarr option.

### `specifications`

Currently expected to contain one specification.

### `implementation`

Sonarr specification implementation.

For the existing release-title definitions:

```json
"implementation": "ReleaseTitleSpecification"
```

### `negate`

Whether the specification result is inverted.

### `required`

Whether this specification is required for the Custom Format to match.

### `fields.value`

Value passed into the current Sonarr specification schema.

For a release-title specification, this is normally a regular expression.

## Updating a Custom Format

Definitions are matched using their `name`.

Running the bootstrap again:

- creates a missing Custom Format;
- leaves an identical one unchanged;
- updates a changed one;
- does not create another copy with the same managed name.

## Quality Profiles

Quality Profile definitions belong in:

```text
bootstrap/sonarr/profiles/
```

Example:

```json
{
  "name": "Example Profile",
  "baseProfile": "Any",

  "upgradeAllowed": true,
  "upgradeUntilQuality": "Bluray-2160p",

  "enableQualities": [
    "WEB 1080p",
    "Bluray-1080p",
    "WEB 2160p",
    "Bluray-2160p"
  ],

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

Name of the Sonarr Quality Profile.

### `baseProfile`

Existing Sonarr profile used as the template when creating a new profile.

The normal default is:

```json
"baseProfile": "Any"
```

### `upgradeAllowed`

Controls whether Sonarr may upgrade existing episodes.

### `upgradeUntilQuality`

Normal Sonarr Quality cutoff.

The value must match an existing Sonarr Quality name.

### `enableQualities`

Qualities that should be enabled.

The current Sonarr loader treats this list additively.

Qualities listed here are enabled without intentionally disabling unrelated existing qualities.

### `minFormatScore`

Minimum Custom Format score accepted by the profile.

### `cutoffFormatScore`

Custom Format score at which upgrades stop.

### `minUpgradeFormatScore`

Minimum score improvement required before an upgrade is accepted.

### `customFormatScores`

Maps Custom Format names to profile scores.

Example:

```json
{
  "AV1": 1000,
  "HEVC": 700
}
```

Every existing Sonarr Custom Format is included in the managed profile.

Formats not explicitly listed in `customFormatScores` receive score `0`.

A profile referencing a Custom Format that does not exist causes the bootstrap to stop with an error.

## Anime Profile

The project currently includes a dedicated Anime Quality Profile definition:

```text
bootstrap/sonarr/profiles/anime.json
```

Seerr also resolves this profile by name when it configures Anime requests.

Because other parts of the stack reference this managed profile, renaming it should be treated as a coordinated configuration change.

## Adding a New Sonarr Profile

1. Add required Custom Format JSON files to:

   ```text
   bootstrap/sonarr/custom-formats/
   ```

2. Add the Quality Profile JSON file to:

   ```text
   bootstrap/sonarr/profiles/
   ```

3. Reference Custom Formats using their exact `name`.

4. Run:

   ```bash
   bash bootstrap/sonarr/setup.sh
   ```

   or rerun the complete installer:

   ```bash
   ./linux-setup.sh quick
   ```

The bootstrap will create or update the managed definitions and run its verification afterward.

## Important Design Rule

Do not hard-code:

- Sonarr Quality Profile IDs;
- Custom Format IDs;
- specification IDs;
- root-folder IDs.

The scripts resolve these values dynamically from Sonarr.
