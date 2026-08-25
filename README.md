# KLICKIFAX.R4X

`KLICKIFAX.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.29.7`
- Image target: `/R4OS/SOFTWARE/INTERNET/KLICKIFAX.R4X`
- Image scope: `none` (on-demand)
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

Regular workspace builds and image plans omit this large application. After
changes to Klickifax, KlickifaxLive, or their browser protocol chain, run
`Tools/Build.bat -testbrowser` or `./Tools/Build.sh -testbrowser` from the
workspace root. That explicit path runs the repository tests and includes the
browser bundle in the headless Test image.

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
