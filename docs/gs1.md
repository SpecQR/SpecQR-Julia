# GS1 and Digital Link

SpecQR は、50 種の AI に限定した catalog、check digits、element strings、オフラインの Digital Link adapter を実装しています。GS1 General Specifications 全体の validator ではありません。日付は固定の 6 桁表現を検査するだけで、暦としての妥当性は検査しません。用途別の AI の組合せや、現在の GS1 dictionary 全体はこの catalog の対象外です。

```julia
using SpecQR
items = parse_gs1_human_readable("(01)09506000134352(10)LOT%1(17)251231")
raw = create_gs1_element_string(items)
# raw contains ASCII GS (0x1d) after variable-length AI 10.
link = create_gs1_digital_link(items; base_url="https://id.gs1.org")
parsed = parse_gs1_digital_link(link)
checked = validate_gs1_digital_link(link)
```

要素は `GS1Element(ai, value)` 値です。helpers は、`"10" => "LOT"` のような pairs、named tuples の `(ai="10", value="LOT")`、文字列または symbol の `ai` と `value` を key に持つ dictionary も受け付けます。AI と value は両方とも文字列である必要があるため、数値変換で先頭ゼロが失われることはありません。上限を設けた iterable は逐次処理し、無限の iterable は全体を実体化せず、要素数の上限で失敗します。

## Catalog and validation

`get_supported_gs1_ais()` は、次の AI の immutable な metadata を返します。

* `00`, `01`, `02`, `10`, `11`, `12`, `13`, `15`, `16`, `17`, `20`, `21`, `22`
* `30`, `37`, `240`, `241`, `400`, `410`–`415`, `420`, `422`, `424`–`426`
* 具体的な `3100`–`3105`、`3200`–`3205`、`91`–`99`

`get_gs1_ai_info(ai)` は 1 件の entry または `nothing` を返します。metadata は固定長・可変長、numeric/text の種類、check-digit の規則、separator の規則、Digital Link の役割、使用可能な primary key を含みます。汎用 GS1、GTIN、SSCC の check digit helpers は modulo-10 の digit を計算し、適用可能な場合に付加し、検証します。AI `01`/`02` は GTIN check digits、`00` は SSCC check digits を必須にします。この限定 profile では、AI `414` は 13 桁の primary key です。追加の GLN check-digit 規則を実施するとは主張しません。

`parse_gs1_human_readable`、`parse_gs1_element_string`、`create_gs1_element_string` は、括弧付きと raw の表現を変換します。`normalize_gs1_elements` は、どちらの入力表現も element objects も受け付けます。`gs1_to_human_readable` は括弧付き表現を生成します。

値は printable ASCII を使い、括弧と ASCII GS を含めてはいけません。literal の percent 記号は、そのまま percent 記号として保持します。可変長 field には、後続要素がある場合だけ ASCII GS を付けます。想定外の位置、二重、末尾の separator は失敗します。最後の可変長値の末尾が、固定長の AI/value を連結したように見える場合は、separator の欠落による曖昧さとして拒否します。これは接尾部に範囲を限定した保守的な heuristic です。

`validate_gs1_elements` と `validate_gs1_element_string` は、構造化した `GS1ValidationResult` 値を返します。`collect_all_errors=false` は要素検証のエラーを最初の失敗に限定します。`context="digital-link"` は、対応する primary AI を必須にします。`allow_unsupported_ai` で未対応の AI を有効にはできません。呼出し側が提供する custom iterator の例外を握りつぶすことはありません。

## Digital Link profile

`create_gs1_digital_link`、`parse_gs1_digital_link`、`validate_gs1_digital_link`、`normalize_gs1_digital_link` は URL を取得しません。オフラインの HTTP(S) adapter は、通常の QR 生成を変更せず、browser と互換性のある字句・authority の受理を復元します。完全な WHATWG または UTS46/IDNA の実装ではありません。

* HTTP(S) slash の不足・過剰、前後の ASCII 空白、authority/path の backslash を補正する。query の backslash は literal な payload bytes のまま保持する
* 空 fragment は受理する。builder は末尾の空 `#` を保持し、正規化では除去する。非空 fragment は引き続き拒否する。builder の空 base query は受理し、非空 base query は引き続き拒否する
* credentials は URL userinfo escaping で直列化し、元の有効な percent escape を保持する。エラーメッセージに credentials を再出力しない
* ASCII percent-encoded host と URL reg-name を受理する。数値 IPv4 の整数・短縮・8 進・16 進の別表記は、上限を検査しながら値を累積して正規化する。従来の bare-hex host 6 件は現在受理するが、`example.0x` は引き続き拒否する
* 角括弧付きの RFC IPv6 を検証し、最初の最長のゼロ列を圧縮して小文字の十六進表現に正規化する。埋込みの dotted IPv4 は十六進 group として直列化する
* 空 port は省略する。10 進 port は逐次範囲検査し、既定の HTTP/HTTPS port は省略する。任意の長さの先頭ゼロで parser が overflow することはない
* percent escape と復号した UTF-8 は厳密に扱う。Julia は、GDScript の host profile と異なり、復号した NUL を未知 query に損失なく保持する既存契約を維持する。raw NUL 入力は引き続き拒否する。通常の QR text と binary の NUL は引き続き対応する
* Unicode/IDNA host は引き続き未対応。対応する Julia Base/Base64 runtime には UTS46 mapping service がない。Unicode 正規化だけでは不十分で、部分的な IDNA 実装を装ったものや、新たな runtime 依存を含めない

primary AI は `00`、`01`（builder の既定）、`414` です。qualifier の `10`、`21`、`22` は、`01` の後ろに限り path に置けます。ほかの対応 AI は query data です。Digital Link 内で AI を重複させることはできません。`path_ais=[]` はすべての qualifier を query に保持します。dot-only の qualifier 値 `.` と `..` は、path に選択した場合も常に query に保持します。primary AI より後ろの実際の path dot segment は、AI/value pair を解釈する前に拒否します。その位置の percent-encoded dot も拒否します。literal 値 `%2e` は `%252e` として符号化し、保持します。

builder は resolver-prefix の dot segment を正規化してから、残った prefix component のうち、1 回の復号で primary AI になるものを `%30%31` も含めて拒否します。これにより、生成したリンクの payload 開始位置が曖昧になることを防ぎます。先行する dot 正規化で除去される primary に見える component は許可します。ほかの prefix component は既存 escape を保持し、raw の非 ASCII path text は URL の直列化で UTF-8 percent encoding します。

query の復号は form の意味論（`+` は空白）を使い、percent/UTF-8 を厳密に検証します。`unknown_query="preserve"` は非 GS1 key、重複、順序、空の値、復号した空白を保持し、`"reject"` はそれらを拒否します。数値で AI の形をした key は、引き続き catalog の対応が必要です。正規化は `"specqr-deterministic"` mode を使い、配置可能な qualifier を path に置き、GS1 query attributes を AI/value の辞書順に並べ、未知 query pair を元の順序で末尾に追加します。dot-only の query qualifier は query に残します。受理した正規化出力に対して冪等です。

検証は HTTP と、保持した未知 query の警告を報告します。検証 option の `normalize=true` は未対応なので、明示的な normalizer を呼び出してください。失敗は `InvalidGs1Error` を投げ、安定した `error_code(error) == "INVALID_GS1"` と、より詳細な `detail_code` を持ちます。validation issue は、その詳細 code、message、reason、適用可能な context fields を公開します。

## Bounds

text は有効な UTF-8 で、最大 1,000,000 UTF-16 code units です（事前の上限は 4,000,000 bytes）。element iterable の AI/value を合わせた処理量は 1,000,000 bytes に制限し、有効な AI/value text は ASCII です。element と query pair の件数は 16,384、path component の件数は 32,769 に制限します。無制限の反復、数値解析、大きな出力の増加が起こる前に上限を検査します。

## Source-bound compatibility evidence

`verification/fixtures/gs1-upstream.json` は、過去の全 1,411 requests と assertions を保持します。現在の TypeScript oracle は、独立に `SpecQR/SpecQR@16efc6c0a8e397c9df3d051d20fce6c1eebdfad7` へ固定しています。不変の Julia baseline は `SpecQR-Julia@ffb95d10cd1c585421cb3a52a43a9e657d000a29` で、両 Julia lanes で新たに実行したものです。baseline の内訳は一致 1,167 件、診断のみの差 131 件、より狭い受理範囲 108 件、安全な query-dot の受理 2 件、IPv6 出力の差 3 件です。source に結び付いた positive targets 80 件は、現在すべて TypeScript と一致します。残る差分 164 件は、診断 131 件、より狭い受理範囲 31 件、安全な query-dot の成功 2 件です。31 件の内訳は、厳密な不正 percent/UTF-8 の検査 17 件、未対応の Unicode host 12 件、context-primary の 2 件です。この corpus では、受理した出力の差分は残っていません。

検証の優先順位を移行した 4 件 (930, 1038, 1056, 1269) は、公開済み Julia の独立した意味上の証拠を使い、候補から期待出力を作ってはいません。NUL の成功 1331–1333 と native NUL の診断 1359 は不変です。元の共有 Digital Link/authority operations 49 件と、全 102 FNC1 percent vectors は引き続き検査します。assertion の移行と範囲の詳細は `url-compatibility.ja.md` を参照してください。診断比較は厳密な code/reason/count と全 payload fields を維持します。文言、任意の null fields、補助的な error context は transcript に保持しますが、契約の比較からは除外します。

### Additional bounded-profile limits outside the 1,411-request corpus

引き継いだ builder の resolver-prefix 整理処理は、空の path segment をまとめます（例えば base の `/a//b` は `/a/b` になります）。ASCII の `xn--` label は内容を解釈しない reg-name として扱い、IDNA/ACE の妥当性は検査しません。そのため、`xn--a` や `xn--` のような不正な ACE label を、TypeScript が拒否する場合でも受理できます。これらは別途文書化した制限であり、完全な URL 一致の主張ではなく、corpus の差分 164 件にも含めません。全 ACE host を一括拒否すると、有効な punycode domain も誤って拒否します。角括弧付き IPv6 内の不正な Unicode は、multibyte の接尾部も含め、`InvalidGs1Error` で拒否します。
