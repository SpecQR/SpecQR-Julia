# Linux continuous integration

The workflow runs the existing source-bound verifiers on real GitHub-hosted
Ubuntu 24.04 x86-64 runners, with official Julia **1.10.12 LTS** and **1.13.1
stable** Linux binaries pinned by SHA-256. No Windows, macOS or other-architecture
pass is implied. A workflow definition or local rehearsal is not a remote CI
pass: inspect the checks on the exact published commit.

Both lanes run the native unit suite (92,637 checks in the reviewed baseline),
10,186 golden requests including 2,400 independent Nayuki matrices, all 27 CLI
checks, clean offline Pkg and separate direct-include consumers, and 38 harness
self-tests. They also run ZXing-C++ 3.1.1 actual PNG decoding, ZXing Java 3.5.4
PNG and matrix decoding, librsvg SVG rasterization/pixel comparison, and shared
regression checks. Decoder scales are the existing reviewed defaults (C++ 8,
Java 3); these results do not assert Java passes the default library scale 8.

Only Julia Base and bundled Base64 are package runtime dependencies. CPython,
ZXing, Pillow, Java and librsvg are verification tools only. PyPI binary wheels
and the Maven Central ZXing jar have exact version/SHA-256 pins. Ubuntu's
official apt repositories supply Java 17 and librsvg; their installed versions
are recorded, not frozen. The Ubuntu runner image and its system Python 3.12
can receive patches. Julia checksums originate from the official
[versions feed](https://julialang-s3.julialang.org/bin/versions.json); the exact
download URL and checksum are retained in each lane. Action commit pins were
verified through official GitHub release metadata and pinned action definitions
for actions/checkout v7.0.1 and actions/upload-artifact v7.0.1; both use Node 24. No cache, repository write permission, persistent
checkout credential, secret or OIDC grant is configured. Artifact upload uses
GitHub's per-job artifact service; the workflow does not publish releases.

## Source changes and archive identity

CI validates the committed `SOURCE-SHA256.json`; it never silently regenerates
that manifest. `scripts/prepare_ci.py stage` rejects a missing, additional or
modified source file, copies exactly the validated inventory into a separate
temporary directory, rechecks both trees, and creates a deterministic ZIP with
fixed timestamps, permissions and sorted members. The native verifier runs
from that copy and checks its archive. CI includes this workflow, CI helper,
test lockfile and documentation in the manifest, rather than exempting them.
The historical 52-file release remains a separate immutable artifact.

When intentionally changing source, review the edits and regenerate the
manifest explicitly, then include it in the same commit:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/prepare_ci.py manifest > /tmp/SpecQR-SOURCE-SHA256.json
cp /tmp/SpecQR-SOURCE-SHA256.json SOURCE-SHA256.json
python3 scripts/prepare_ci.py stage --output /tmp/specqr-check
```

Use a fresh output directory. Do not generate the temporary manifest inside
the source tree: it would become an unwanted inventory entry. A digest binds
evidence to bytes, not publisher authenticity. The current source's manifest
and archive hashes change after an intentional edit; CI is not permanently
pinned to the historical release archive hash.

## Evidence and required checks

Both Julia lanes continue independent checks after a test failure where their
prerequisites are available. Failed steps are never marked successful.
Artifacts upload on success or failure, retaining the source archive, commit,
host/tool versions, reports, complete reference transcripts and process
receipts. Compiled Julia depots are omitted; the consumer's explicit empty
registry, Project and Manifest are retained. Evidence paths are original
runner paths and are preserved as execution provenance. Artifacts expire after
14 days; retain a downloaded copy if release evidence is needed longer.

The `Required Linux checks` aggregate fails if any matrix lane fails, is
cancelled or is skipped. Select this check in branch protection if desired;
the workflow alone does not configure repository policy. See
[native validation](native-platform-validation.md) for exact evidence scope and
offline limitations. Environment flags are not an OS-level network sandbox.
