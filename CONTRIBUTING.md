# Contributing

Keep runtime dependencies limited to Julia Base and bundled Base64. New package
or JLL dependencies, foreign QR implementations and network runtime resources
are out of scope. Match strict UTF-8 and arbitrary binary-byte contracts.

Run the complete native suite and the pinned reference corpus on Julia stable
and LTS. Add regression tests for failures; use actual native execution rather
than interpreting, transpiling, or emulating Julia. Keep optional decoder tools
outside runtime dependencies. Test source-level public APIs, not only the JSON
adapter. Regenerate the source manifest only after review, then re-run the
source-bound native harness against the exact source archive.

Do not claim platform support from a cross-compiler, container architecture
label, compatibility layer, or a script that did not run the intended Julia
runtime. Native execution reports describe only their actual OS/architecture.
