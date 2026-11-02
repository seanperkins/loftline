# The update feed's G-code-change warning is signed (issue #123, item 3)

Status: not implemented (2026-11-02). DECISIONS `updater-trust-boundary` keeps the feed fields unsigned: whoever can edit latest.json can already read the signing secrets. Kept for the day that changes (a collaborator is added). Open review points if revived: sign a notes hash and hide notes when unverified; pass the controller's key to parse; define absent-field encoding; list the existing assertions that flip.

## Problem

`latest.json` carries, per platform, a version, a URL, the archive's SHA-256, `sig` (an RSA-4096 signature over the
archive), `gcodeChanged`, `gcodeChangedIn` and `notes`. Only the archive is signed.

Someone who controls the feed can keep an authentic release and clear `gcodeChanged` and `gcodeChangedIn`. The
"re-export and check your G-code" warning (`UpdatePresentation.swift:46`) then disappears, and the operator runs
old programs on a release whose posted output changed. They cannot install unsigned code, but they can remove a
safety warning.

## Design

### The signed statement

Each entry gains `metaSig`: base64 of an RSA-4096 PKCS#1 v1.5 SHA-256 signature, under the same key as `sig`, over
these UTF-8 bytes (each line ends in `\n`):

```
LoftLine update entry v1
version=<version>
sha256=<sha256>
gcodeChanged=<true|false>
gcodeChangedIn=<gcodeChangedIn, or empty>
```

`version` and `sha256` are in it, so a statement cannot be moved onto another release.

- `UpdateManifest.metadataStatement(version:sha256:gcodeChanged:gcodeChangedIn:) -> Data` builds the bytes.
- `scripts/update-feed.sh` and `scripts/verify-feed.sh` build the same bytes. A test compares the script's output
  with the Swift function's.

### The client fails safe

`UpdateManifest.parse(_:platform:publicKeyPEM:)`, with the key defaulting to `UpdateSignature.publicKeyPEM`,
verifies `metaSig`. It hashes the statement with SHA-256 and calls `UpdateSignature.verify(digestHex:...)`.

- **When it verifies,** `gcodeChanged` and `gcodeChangedIn` are taken as written.
- **When it is missing, malformed or wrong,** the entry still parses, because the archive signature still guards the
  install. But its G-code fields are replaced with the safe answer: `gcodeChanged = true` and
  `gcodeChangedIn = version`. `changesPostOutput(since:)` is then true for anyone updating to it, so the warning
  shows.
- **Stripping or forging `metaSig` can only add the warning, never remove it.**
- **Feeds published before this change** have no `metaSig`, so a new client shows the warning for them. That
  errs the safe way.
- **Old clients** ignore the unknown key and behave as today.
- `UpdateEntry` gains `metadataVerified: Bool`, so tests and diagnostics can tell the two cases apart.

### The release scripts

- **`scripts/update-feed.sh`** signs the statement with `openssl dgst -sha256 -sign "$KEY" -binary` and writes
  `metaSig` beside `sig`.
- **`scripts/verify-feed.sh`** rebuilds the statement from the feed's own fields, verifies `metaSig` with the
  public key it already converts, and fails if `metaSig` is missing or does not verify. The release workflow
  already runs it before publishing, so an unsigned feed is never released.

## Not in scope

- **Signing `notes` or `url`.**
  - `url` must already match the download URL for `version`, and the archive's signature guards its bytes.
  - `notes` is shown as text and makes no safety claim.
- **Replacing the feed format or the key.**

## Tests

**UpdateCoreTests, `UpdateManifestTests`,** using the throwaway key that `UpdateSignatureTests` already makes with
openssl:
- **A valid `metaSig`** keeps `gcodeChanged=false` and `metadataVerified` is true.
- **Missing, garbage, or signed over different flags** gives `gcodeChanged=true`, `gcodeChangedIn == version`,
  `metadataVerified` false, and `changesPostOutput(since: "0.0.1")` true.
- **Moved between releases:** a `metaSig` copied from an entry with a different version or sha256 does not verify.
- **The statement's bytes** for a fixed entry are pinned exactly.

**LoftLineAppTests, `ReleaseScriptsTests`** (existing feed round-trip tests):
- `update-feed.sh` writes a `metaSig` that `UpdateManifest.parse` verifies with the test key.
- `verify-feed.sh` fails on a feed whose `gcodeChanged` was flipped after signing, and on one with `metaSig` removed.

## Docs

- DECISIONS: a new entry, `signed-gcode-flag`, which refines `feed-signature`.
- The comments in `UpdateManifest`, `update-feed.sh` and `verify-feed.sh`.
