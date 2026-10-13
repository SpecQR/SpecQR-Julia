# Native Julia API

SpecQR はすべて Julia で動作し、実行時の依存は `Base64` 標準ライブラリのみです。
配列は通常の Julia の添字規則に従います。QR 行列は quiet zone を含まない正方形の
`Matrix{Bool}` で、`matrix[y, x]` として参照します。
`module_at(code, x, y)` の座標は **1 始まり**です。

```julia
using SpecQR

options = Options(error_correction_level="M", min_version=1, max_version=40)
preview = plan("Hello, 世界", options)
preview.ok || error("Payload does not fit")
code = generate("Hello, 世界", options; mask_pattern=2)
write("hello.svg", to_svg(code))
write("hello.png", to_png(code; scale=6))
```

`estimate` と `plan` は、コード語、Reed–Solomon parity、mask、行列を構築せずに
`Plan` を返します。fields には `ok`、`version`、
`capacity_version`、`error_correction_level`、`data_bit_length`、`capacity_bits`、
`remaining_bits`、`segments`、`diagnostics` があります。自動計画が失敗すると
`version === nothing` になり、容量は要求範囲の上限である `capacity_version` を参照します。
固定 version は範囲の上下限に優先します。
`overflow_bits`、`capacity_utilization`、`warnings`、`selected_version` は
便宜用 properties です。どのシンボルにも収まらない場合、`generate` は `DataTooLongError` を送出します。

`get_capacity(1, "L"; mode="byte").maximum == 17` です。容量計算は numeric、
alphanumeric、byte、Kanji modes と、`control_bits` による制御ビット分の確保に対応します。

## Input and ownership

テキストは Unicode として厳密に検証され、byte mode のテキストは常に UTF-8 です。
ネイティブの byte vectors と tuples は、不正な UTF-8 を含む任意の bytes を許容します。
各値は `0:255` の整数である必要があり、`Bool` は除外されます。Options も真偽値と整数を区別します。
ECI は後続 bytes の符号化方式を示すだけで、変換は行いません。
UTF-8 以外の符号化にはネイティブの bytes を使ってください。

`Segment` は不変の payload storage を所有し、binary の `data` と `logical_bytes`
properties はコピーを返します。各 encoder result は、自身の行列、コード語、segment collection、
diagnostics を所有します。変更可能なグローバル cache はありません。
結果は独立して変更できます。変更可能な結果を threads 間で共有する呼出側は、
自身の変更を同期する責任を負います。

リソース上限は、入力 scalars または binary bytes が 1,000,000、manual payload units の合計が
1,000,000、manual segments が 16,384 です。単一シンボルの厳密な自動最適化は
7,089 scalars までです。高水準 API で上限を超える入力を計画する場合は、処理量を制限した未最適化の見積りを使います。
最適化の計算量はテキスト長に対して線形で、segment の文字数 field の上限を守り、
3 つの QR version bands ごとにローカルで cache します。同率時の決定規則は、まず bits、
次に segment 数を最小化し、numeric/alphanumeric/Kanji/byte の mode 順と、
同等なら先行する開始位置を優先します。この規則により、他の移植版の従来の同率時規則とは
異なる、同じく最適な分割を選ぶことがあります。

## Manual segments and controls

```julia
segments = [Segment("numeric", "1234567890"), Segment("byte", UInt8[0xff, 0x00])]
preview = analyze_segments(segments)
code = generate_segments(segments)
```

制御 segment の modes は `eci`、`fnc1`、`fnc1-second`、
`structured-append` です。FNC1 と Structured Append の headers は先頭に置き、
重複させないでください。ECI は data の後にも置け、後続の byte segments の符号化方式を再指定するために繰り返せます。
この実装では、異なる制御系統は併用できません。`Options(eci=true)` は UTF-8 ECI 26 を選択し、
整数の `0` も有効な割当値です。`Options(fnc1_second="00")` は indicator を保持します。

`gs1=true` は高水準の GS1 element string を検証し、第 1 位置の FNC1 を出力します。
`fnc1=true` は GS1 AI 検証を呼ばず、呼出側が管理するテキストに対して同じ header を出力します。
高水準 FNC1 data にリテラルの percent があると byte mode を選択します
（alphanumeric mode を明示的に強制した場合は拒否します）。U+001D group separators は、
連続する場合も実際の bytes として保持します。manual FNC1 alphanumeric segments は
すでに escape 済みの QR data として扱い、書き換えません。
reader にとって、`%` は区切り、`%%` はリテラルの percent を示します。

## Structured Append

```julia
set = generate_structured_append("HELLO WORLD "^40;
    version=2, error_correction_level="M", max_symbols=16)

manual = generate_segments_structured_append(
    [Segment("numeric", "12345"), Segment("byte", "é😀"^30)];
    version=2, diagnostics=(split_units="full", symbol_results="diagnostics"))
```

1 set は 2–16 個のシンボルを含み、すべて同じ選択済み version を使います。
自動選択では、設定した最大個数以内に payload を分割できる、許可範囲内の最小 version を選びます。
各 part は、次の入力位置から収まる最大の prefix です。テキストは Unicode scalar の境界でのみ分割します。
manual numeric、alphanumeric、Kanji segments は分割せず、manual byte segments だけを分割します。

選択範囲内の 1 シンボルに入力全体が収まる場合は、`generate` または明示的な低水準 header を使ってください。
Structured Append 生成は自身の headers を管理し、FNC1、GS1、ECI、ECC boosting、parity の上書きを受け付けません。
indices と totals は 1 始まりです。canonical parity は、元の UTF-8 text または raw bytes の XOR です。
Kanji text も Shift JIS ではなく UTF-8 を使います。

`SAResult` は `symbols`、`total`、`parity`、`input_length`、`byte_length`、
`diagnostics` を公開します。offset diagnostics は、元入力に対する 0 始まりの offset であることを明示します。
`merge_structured_append_parts` は `index`、`total`、`parity`、`data` を含む decode 済みの mappings を受け取り、
連結前に完全性、重複、型の整合、parity を確認します。parts は任意の順序で渡せます。
XOR parity は一部の破損を検出しますが、認証ではありません。

## Diagnostics and rendering

`diagnostics(result)` は deep copy を返します。計画と生成の diagnostics は、segment costs、
version/ECC 選択、容量、controls、GS1 検証、quiet zone の十分性、コントラスト、透明度、
任意指定の印刷サイズを報告します。`print_dpi` を渡す場合、そこから導出する寸法は有限の正の値である必要があります。
警告コードには `QUIET_ZONE_TOO_SMALL`、`COLOR_CONTRAST_LOW`、`COLOR_ALPHA_USED`、
`PRINT_MODULE_TOO_SMALL`、`CAPACITY_NEAR_LIMIT`、`SCAN_RISK` があります。

QR result には `to_svg`、`to_png`、`to_pixels`、`to_svg_data_url`、`to_png_data_url` を使います。
result methods は元の margin、scale、colors を継承し、keyword で上書きできます。
`render(code, "matrix")` は行列のコピーを返します。他の出力は
`"svg"`、`"png"`、`"pixels"`、`"svg-data-url"`、`"png-data-url"` です。
