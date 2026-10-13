# Public API

options、厳密な text/binary 入力、optimizer の正確な挙動、容量計画、結果の所有権、診断、Structured Append は [native API の契約](native-api.md)を参照してください。GS1 と描画は、それぞれ [GS1](gs1.md) と [描画](rendering.md)を参照してください。すべての例は、ローカルの開発用インストール後に `using SpecQR` を実行するか、`using .SpecQR` の前に `src/SpecQR.jl` を include して実行します。

エラーは `SpecQRError` から派生します。安定した機械用 code には `error_code(error)` を使ってください。不正な ECC 入力は `InvalidEccError` (`INVALID_ECC_LEVEL`) を発生させます。Digital Link/GS1 のエラーは、最上位の `INVALID_GS1` code と構造化した `detail_code` を公開します。Julia runtime やプログラムのエラーを、有効な QR 結果として扱うことはありません。

JSON は CLI/test I/O 向けの小さな内蔵の厳密な codec であり、汎用 JSON package としての機能を約束するものではありません。有限の JSON 浮動小数点数と native の範囲内の整数を受け付け、重複 key や不正 Unicode を拒否し、深さ・入力・値の件数に上限を設けます。公開 Julia 入力 API は、整数が必要な箇所で Bool を拒否します。

ソースと CLI の例には、意図的に private/non-sensitive なサンプルデータを使っています。
