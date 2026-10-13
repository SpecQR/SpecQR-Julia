# Rendering and geometry

SpecQR は、1 始まりで行を `matrix[y, x]` と参照する正方形の boolean matrix から直接描画します。encoder の結果は通常の `Matrix{Bool}` に格納します。直接呼び出す renderer は、ほかの 1 始まりの `AbstractMatrix{Bool}` も受け付けます。matrix の一辺は 1–177 である必要があります。既定は margin 4 modules、scale は 1 module あたり 8 pixels、前景は黒、背景は白です。

```julia
using SpecQR
q = generate("Hello, Julia!")
svg = to_svg(q)
png = to_png(q)                 # Vector{UInt8}, standard RGBA PNG
url = to_data_url(q; format="png")
write("hello.svg", svg)
write("hello.png", png)
```

matrix を直接渡す場合も、同じ `margin`、`scale`、`foreground`、`background` の keyword 引数を使います。`to_svg_data_url` と `to_png_data_url` は、`to_data_url` の出力形式を明示する別の選択肢です。SVG data URLs は UTF-8 の percent encoding、PNG data URLs は標準の Base64 を使います。ネットワーク要求や外部 codec は使いません。

## Supported colors

* SVG: `#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA`、または単純な ASCII の CSS 色名
* PNG/RGBA: 上記の十六進表現、`black`、`white`、`transparent`
* raster の十六進色と色名は、大文字・小文字を区別しない
* 前後の空白を除去する。指定する各色は、空白除去前で 64 UTF-8 bytes に制限する

SVG は、任意の CSS 式、URL paints、`var(...)`、関数、markup を意図的に除外します。受理した色の text も、挿入前にすべて XML escape します。認識していない単純な CSS 色名は、SVG consumer によって描画が異なる場合があります。`parse_color(name; strict=false)` は、raster の色として解釈できない場合に `nothing` を返します。不正または安全でない色文字列は、常に失敗します。

`to_pixels(matrix; ...)` は `Pixels` 値を返します。`width`、`height`、`pixels` を持ち、最後の field は alpha を事前乗算していない RGBA bytes を row-major で格納した `Vector{UInt8}` です。
`render_rgba` は同等の `(width, height, data)` fields を返します。

`contrast_ratio(foreground, background)` は、raster の色文字列または整数の channel 値 4 個を受け付けます。白に背景の alpha を合成し、その結果に前景の alpha を合成してから、相対輝度の contrast を計算します。そのため、透明色に不透明色の contrast score を誤って与えることはありません。

## PNG implementation

PNG はフルスクラッチで実装しています。8 bit RGBA、scanline ごとの filter type 0、1 個の IDAT chunk、最大 65,535 bytes の決定的な stored-DEFLATE blocks を含む zlib wrapper を使います。CRC-32 と Adler-32 はローカルの Julia routines で計算します。PNG 出力は timestamp や非決定的な metadata を含みません。汎用 DEFLATE encoder で圧縮した PNG より、意図的に大きい出力になります。製品の描画に必要なのは Base と Base64 標準ライブラリだけで、image package、JLL 依存、codec FFI、shell command、remote service は不要です。

## Resource limits and print sizes

`margin` は非負の整数、`scale` は正の整数である必要があります。boolean と浮動小数点の値は拒否します。各値と最終寸法の上限は 1,000,000,000 で、乗算は実行前に検査します。

raster 出力の上限は 4,194,304 pixels です（正方形なら 2048 × 2048）。SVG の文字数予算は 8 MiB、data URLs の文字数予算は 32 MiB です。出力サイズに応じたメモリ確保の前に上限を検査します。不正な geometry や資源上限には `InvalidInputError`、安全でない色や未対応の色には `InvalidColorError`、未対応の data URL 形式には `InvalidOutputError` を投げます。

`render_dimensions(matrix; margin=4, scale=8, dpi=nothing)` は pixel の geometry を報告します。正の有限な `dpi` を指定すると、1 inch を 25.4 mm として `module_size_mm` と `symbol_size_mm` も報告します。変換後の物理寸法がゼロまたは非有限になる場合は拒否します。印刷寸法は出力の geometry を示すものであり、scanner の性能や GS1 の印刷品質への適合を保証するものではありません。
