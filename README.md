# KLICKIFAX.R4X

`KLICKIFAX.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.29.29`
- Image target: `/R4OS/SOFTWARE/INTERNET/KLICKIFAX.R4X`
- Image scope: `none` (on-demand)
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

Regular workspace builds and image plans omit this large application. After
changes to Klickifax, KlickifaxLive, or their browser protocol chain, run
`Tools/Build.bat -testbrowser` or `./Tools/Build.sh -testbrowser` from the
workspace root. That explicit path runs the repository tests and includes the
browser bundle in the headless Test image.

`Settings.R4S` selects the SDK tool owner. Its profiles define the verified
SDK, Contract and system library sources. `build.zig.zon` records the exact
standalone archive identities. The shared PowerShell build path binds the
actual selected sources and records its normal or explicit development mode.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

0.85.44: Rebuilt with SDK0.64.57 and the shared R4STD Unicode17.0.0
extended grapheme editing boundaries. Byte offsets, scalar font advances
and grapheme clusters are distinct; no shaping or BiDi support is implied.

API migration0.90.75 uses SDK0.64.208 with `r4os-zig-generation2`.

Page work waits for the earliest live timer, resource progress, queued job or
bounded font-display deadline across the document and its subdocuments.
Settled recurring script work keeps its 50 ms foreground slice; active
resource progress uses 10 ms until complete. Static pages without pending
work wait indefinitely in EventLoop. GUI input, close and font-change events
remain independent wake sources. The existing test step covers this policy
and exact font-demand epoch retirement.
