# Verification

package は、決定的な native Julia tests と、固定した圧縮済みの言語非依存 corpus を含みます。検証は実際の Julia 実行ファイルを呼び出します。候補の結果を生成するために、transpiler、互換 interpreter、QR wrapper、リモートの QR service を使うことはありません。

## Exact corpus

- 公開 API の 5,610 operations: 生成 3,028 件、計画 1,920 件、容量 640 件、Structured Append 22 件
- 内部の 4,576 operations: raw matrix/codeword/mask の 4,320 件、Reed–Solomon の全 255 次数、全 65,536 項目の GF 乗算表
- corpus の 2,400 matrices は、独立した Nayuki の参照結果と一致
- version 1–40、ECC L/M/Q/H、mask 0–7 をすべて含む

`verification/fixtures/manifest.json` は、圧縮ファイルを SHA-256 で固定します。圧縮した corpus files は両方とも同梱しているため、core の検証はオフラインで行えます。

```sh
julia --startup-file=no --project=. test/runtests.jl
python3 scripts/verify_reference.py --julia /absolute/path/to/julia --output reference.json
```

verifier は、必須 field、行の寸法、matrix hashes、正確な件数、process の正常終了、stream hashes、source が変更されていないことを検査します。比較が成功しても、source tree が変更された場合は、その source と結び付いた実行結果は無効です。

## Independent decoding and rendering

任意の開発用 scripts は、独立にインストールした ZXing-C++ 3.1.1 と ZXing Java 3.5.4 を呼び出します。生成した PNG はすべて、独立した CRC、DEFLATE、寸法、全 pixel の再構成を検査してから、実際の画像認識を行います。GS1/FNC1、ECI、Kanji、binary bytes、全 mode、mask/ECC の組合せ、高水準の Structured Append を対象にします。Java では、実 PNG の検出とは別に、SA metadata、codeword bytes、matrix の decode も検査します。

SVG は独立した librsvg で raster 化し、純 Julia による PNG 出力と全 pixel を比較して、両方の画像を decode します。PNG/SVG data URLs は round-trip を確認します。decoder/rasterizer/Python libraries は任意の検証用 tools であり、`Project.toml` の runtime 依存に含めることはありません。

既知の scanner の制限は、その特定の構成での失敗として報告する必要があります。別の pixel scale で成功しても、元の scale で成功した証拠にはなりません。corpus の合格は、正式な規格認証ではありません。

## Review and native proof

成果物には、実際の version、commands、source/archive hashes、比較件数、SDK checksums、テスト結果を記録します。最終 source は、決定的な順序と timestamp で archive にします。別の native harness が、その archive を source inventory 全体と照合し、native 実行ファイルの header、実際の OS/architecture、Julia 自身の runtime 識別情報、unit tests、全 corpus、CLI の制御 byte/Unicode I/O、クリーンなオフラインのローカル package consumer を検査します。[native 検証](native-platform-validation.md)を参照してください。
