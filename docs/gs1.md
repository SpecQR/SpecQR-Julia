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
They use an intentionally strict profile, not universal WHATWG URL or IDNA
normalization:

* Absolute `http://` or `https://` only; no raw whitespace, control bytes,
  backslashes, fragments (including an empty fragment), or user credentials
* ASCII DNS labels of at most 63 bytes, full name at most 253 bytes; letters,
  digits and internal hyphens only. DNS case is lowered; a DNS trailing dot is
  retained
* Canonical four-component decimal IPv4 only. Integer, short, octal,
  hexadecimal, leading-zero and trailing-dot IPv4 aliases are rejected. This
  includes `0x`, `0X`, `1.0x`, `example.0x`, `0x.`, `1.0X`, and `1.2.3.0x`
* Bracketed RFC IPv6, including canonical dotted-decimal IPv4 tails, is accepted;
  hexadecimal case is lowered. IPv6 is validated without DNS or socket access,
  and is not recompressed. Zone IDs and percent-encoded hosts are rejected
* Ports must have 1–5 decimal digits and be 0–65535; default HTTP/HTTPS ports
  are omitted and other ports rendered in decimal
* Percent escapes and decoded UTF-8 are strict throughout path and query.
  Unicode resolver-prefix and unknown-query data preserve exact UTF-8, with no
  Unicode normalization or surrogate replacement

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
components, including existing escapes and raw UTF-8, are preserved.

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
