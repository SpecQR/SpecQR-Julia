# Security and resource limits

Do not put secrets in QR codes unless exposing the complete payload is intended.
A QR code is an encoding, not encryption. Inspect decoded links before opening.
SpecQR never fetches or visits a Digital Link.

Inputs and rendering geometry are bounded before expensive allocations. Invalid
UTF-8 and invalid mode/control sequences raise typed errors. CLI JSON rejects
non-finite numbers, duplicate keys, unpaired UTF-16 escapes, excessive nesting,
and oversized inputs. Public arrays remain user-owned mutable results; changing
them changes that result only. Do not concurrently mutate a result while
rendering it.

Report suspected encoding, data-loss, validation, denial-of-service, or output
escaping defects privately to the repository maintainer. Include Julia version,
OS/architecture, a minimal non-sensitive input, actual/expected results, and the
source manifest hash. No package is a guarantee against malicious callers
modifying Julia internals or overriding methods in the same process.
