# GS1 and Digital Link

SpecQR implements a bounded 50-AI catalog, check digits, element strings and an
offline Digital Link adapter. It is not a complete GS1 General Specifications
validator. Dates are checked for their fixed six-digit representation, not
calendar validity; application-specific AI associations and the entire current
GS1 dictionary are outside this catalog.

```julia
using SpecQR
items = parse_gs1_human_readable("(01)09506000134352(10)LOT%1(17)251231")
raw = create_gs1_element_string(items)
# raw contains ASCII GS (0x1d) after variable-length AI 10.
link = create_gs1_digital_link(items; base_url="https://id.gs1.org")
parsed = parse_gs1_digital_link(link)
checked = validate_gs1_digital_link(link)
```

Elements are `GS1Element(ai, value)` values. Helpers also accept pairs such as
`"10" => "LOT"`, named tuples `(ai="10", value="LOT")`, and dictionaries with
string or symbol `ai` and `value` keys. AI and value must both be strings, so
leading zeroes cannot be lost through numeric conversion. Bounded iterables are
consumed incrementally; an infinite iterable fails at the element limit rather
than being fully materialized.

## Catalog and validation

`get_supported_gs1_ais()` returns immutable metadata for:

* `00`, `01`, `02`, `10`, `11`, `12`, `13`, `15`, `16`, `17`, `20`, `21`, `22`
* `30`, `37`, `240`, `241`, `400`, `410`–`415`, `420`, `422`, `424`–`426`
* Concrete `3100`–`3105`, `3200`–`3205`, and `91`–`99`

`get_gs1_ai_info(ai)` returns one entry or `nothing`. Metadata includes fixed or
variable length, numeric/text kind, check-digit rule, separator rule, Digital
Link role, and eligible primary key. Generic GS1, GTIN, and SSCC check digit
helpers calculate, append where applicable, and validate the modulo-10 digit.
AI `01`/`02` enforce GTIN check digits and `00` enforces SSCC check digits. AI
`414` is a 13-digit primary key in this bounded profile; no additional GLN
check-digit rule is claimed.

`parse_gs1_human_readable`, `parse_gs1_element_string`, and
`create_gs1_element_string` convert parenthesized/raw representations.
`normalize_gs1_elements` accepts either input representation or element objects;
`gs1_to_human_readable` produces the parenthesized representation.

Values must use printable ASCII and contain neither parentheses nor ASCII GS.
A literal percent sign remains a literal percent sign. Variable-length fields
receive ASCII GS only when another element follows. Unexpected, doubled, or
trailing separators fail. A final variable-length value that ends in an
apparently concatenated fixed-length AI/value is rejected as an ambiguous
missing separator; this is a conservative bounded suffix heuristic.

`validate_gs1_elements` and `validate_gs1_element_string` return structured
`GS1ValidationResult` values. `collect_all_errors=false` limits element-validation
errors to the first failure; `context="digital-link"` requires a supported
primary AI. Unsupported AIs cannot be enabled with `allow_unsupported_ai`.
Exceptions from caller-provided custom iterators are not swallowed.

## Digital Link profile

`create_gs1_digital_link`, `parse_gs1_digital_link`,
`validate_gs1_digital_link`, and `normalize_gs1_digital_link` never fetch URLs.
The offline HTTP(S) adapter restores browser-compatible lexical/authority
acceptance without changing ordinary QR generation. It is not a complete WHATWG
or UTS46/IDNA implementation:

* Missing/excess HTTP(S) slashes, edge ASCII whitespace, and authority/path
  backslashes are repaired. Query backslashes remain literal payload bytes
* Empty fragments are accepted; builders preserve a trailing empty `#`, while
  normalization omits it. Nonempty fragments remain rejected. Empty builder
  base queries are accepted; nonempty base queries remain rejected
* Credentials are serialized with URL userinfo escaping, with original valid
  percent escapes retained. Error messages do not echo credentials
* ASCII percent-encoded hosts and URL reg-names are accepted. Numeric IPv4
  integer/short/octal/hexadecimal aliases are canonicalized with checked bounded
  accumulation. Six legacy bare-hex hosts now accept; `example.0x` still rejects
* Bracketed RFC IPv6 is validated and normalized to lowercase hex, compressing
  the first longest zero run; embedded dotted IPv4 is serialized as hex groups
* Empty ports are omitted; decimal ports are range-checked incrementally and
  default HTTP/HTTPS ports are omitted. Arbitrarily long leading zeros cannot
  overflow the parser
* Percent escapes and decoded UTF-8 remain strict. Julia retains its existing
  lossless decoded-NUL unknown-query contract, unlike the GDScript host profile.
  Raw NUL input remains rejected. Ordinary QR text and binary NUL remain supported
* Unicode/IDNA hosts remain unsupported: the supported Julia Base/Base64 runtime
  has no UTS46 mapping service. Unicode normalization alone is insufficient and
  no fake partial IDNA implementation or added runtime dependency is included

Primary AIs are `00`, `01` (builder default), and `414`. Qualifiers `10`, `21`,
`22` can appear in the path only after `01`. Other supported AIs are query data.
AIs cannot repeat within a Digital Link. `path_ais=[]` keeps all qualifiers in
the query. Dot-only qualifier values `.` and `..` are always kept in the query,
even when selected for the path; actual path dot segments after the primary AI
are rejected before interpreting AI/value pairs. Percent-encoded dots are also
rejected there. A literal value `%2e` is encoded as `%252e` and preserved.

The builder normalizes resolver-prefix dot segments, then rejects any surviving
prefix component that decodes once to a primary AI, including `%30%31`. This
prevents generated links from having an ambiguous payload start. Primary-looking
components removed by preceding dot normalization are allowed. Other prefix
components preserve existing escapes; raw non-ASCII path text is UTF-8 percent
encoded during URL serialization.

Query decoding uses form semantics (`+` is a space), with strict percent/UTF-8
validation. `unknown_query="preserve"` retains non-GS1 keys, duplicates, order,
empty values, and decoded whitespace; `"reject"` fails on them. Numeric AI-shaped
keys still require catalog support. Normalization uses the
`"specqr-deterministic"` mode, places eligible qualifiers in the path, sorts GS1
query attributes lexically by AI/value, and appends unknown query pairs in their
original order. Dot-only query qualifiers remain in query. It is idempotent for
accepted normalized output.

Validation reports HTTP and preserved-unknown-query warnings. The
`normalize=true` validation option is unsupported; call the explicit normalizer.
Failures throw `InvalidGs1Error` with stable `error_code(error) == "INVALID_GS1"`
and a finer `detail_code`; validation issues expose that finer code, message,
reason and applicable context fields.

## Bounds

Text is valid UTF-8 and at most 1,000,000 UTF-16 code units (with a preliminary
4,000,000-byte ceiling). Element iterable aggregate AI/value work is capped at
1,000,000 bytes; valid AI/value text is ASCII. Element and query pair counts are
limited to 16,384, and path component counts to 32,769. Limits are checked before
unbounded iteration, numeric parsing, or large output growth.

## Source-bound compatibility evidence

`verification/fixtures/gs1-upstream.json` retains all 1,411 historical requests
and assertions. The current TypeScript oracle is independently pinned to
`SpecQR/SpecQR@16efc6c0a8e397c9df3d051d20fce6c1eebdfad7`. The immutable Julia
baseline is `SpecQR-Julia@ffb95d10cd1c585421cb3a52a43a9e657d000a29`, freshly run
on both Julia lanes. Baseline classifications are 1,167 aligned, 131 diagnostic
only, 108 narrower acceptances, two safe query-dot acceptances and three IPv6
output differences. All 80 source-bound positive targets now match TypeScript.
The remaining 164 differences are 131 diagnostic, 31 narrower acceptances and
two safe query-dot successes. The 31 comprise 17 strict malformed-percent/UTF-8
cases, 12 unsupported Unicode hosts and two context-primary cases. There are no
remaining accepted-output differences in this corpus.

Four validation precedence migrations (930, 1038, 1056, 1269) use independent
published-Julia semantic witnesses; there is no candidate-derived expected
output. NUL successes 1331–1333 and native NUL diagnostic 1359 remain unchanged.
The original shared 49 Digital Link/authority operations and all 102 FNC1
percent vectors remain checked. See `url-compatibility.ja.md` for assertion
migration and scope details. Diagnostic comparisons retain exact code/reason/
count and all payload fields; wording, optional null fields and auxiliary
error context are retained in transcripts but excluded from contract comparison.

### Additional bounded-profile limits outside the 1,411-request corpus

The inherited builder resolver-prefix cleanup collapses empty path segments
(e.g. a base `/a//b` becomes `/a/b`). ASCII `xn--` labels are treated as opaque
reg-names; there is no IDNA/ACE validity check, so invalid ACE labels such as
`xn--a` and `xn--` can be accepted even though TypeScript rejects them. These
are separately documented limitations, not claims of complete URL parity and
not included in the 164 corpus differences. Blanket rejection of all ACE hosts
would incorrectly reject valid punycode domains. Malformed Unicode inside
bracketed IPv6 is rejected through `InvalidGs1Error`, including multibyte suffixes.
