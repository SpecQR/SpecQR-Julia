# SpecQR Julia

日本語 | [English](README.en.md) | [日本語の使い方](docs/getting-started.ja.md)

Julia でフルスクラッチ実装した QR Code Model 2 エンコーダーです。
実行時に必要なのは Julia Base と同梱の Base64 標準ライブラリだけです。
外部パッケージ、JLL、FFI、別の QR ライブラリやネットワークサービスは使いません。

GitHub のソースから利用できます。パッケージの版は `0.1.0` です。
Julia のパッケージレジストリへの登録、リリースタグ、安定版としての認定は行っていません。
API 名とオプション名は英語のままです。

## 最短の使い方

Julia を用意し、リポジトリを取得して、そのルートで Julia を起動します。
以下のシェル例は Linux で確認しています。

```sh
git clone https://github.com/SpecQR/SpecQR-Julia.git
cd SpecQR-Julia
julia --startup-file=no --project=.
```

Julia のプロンプトで実行します。追加パッケージのインストールは不要です。

```julia
using SpecQR

qr = generate("こんにちは、世界 🌍"; error_correction_level="Q")
write("hello.svg", to_svg(qr))
write("hello.png", to_png(qr))
println(qr.version, " / ", qr.mask_pattern)
```

`hello.svg` と `hello.png` が現在のディレクトリに作成されます。
Julia の `write` は同名ファイルを上書きします。上書きを避けたい場合は別名を使うか、
既存ファイルを既定で拒否する下記の CLI を利用してください。
別の Julia プロジェクトからの利用、`include` だけで読み込む方法、各機能の例は
[日本語の入門ガイド](docs/getting-started.ja.md)を参照してください。

## 対応機能

- Version 1–40、誤り訂正 L / M / Q / H、8 マスクと自動選択
- 数字、英数字、UTF-8 テキスト、任意のバイト列、漢字モード
- 文字数フィールドと version の範囲を考慮した混在モードの最適化
- ECI、FNC1 第1 / 第2位置、手動セグメント
- GS1 element string、チェックディジット、限定 AI カタログ、Digital Link
- Structured Append の分割、parity、計画、完全性を確認した再結合
- 純 Julia による SVG、PNG、RGBA pixels、data URL
- 容量計算、生成前の計画・見積り、診断、ECC 強化、CLI

QR の読み取り機能、Micro QR、rMQR は含みません。GS1 全仕様の実装や
ISO / GS1 認証、すべてのスキャナーでの読み取りを保証するものではありません。

## CLI

リポジトリのルートで実行します。

```sh
julia --startup-file=no bin/specqr.jl --text 'こんにちは、世界' --output hello-cli.svg
julia --startup-file=no bin/specqr.jl --text '123456789' --plan
julia --startup-file=no bin/specqr.jl --hex 00ff1d --format png --output bytes.png
julia --startup-file=no bin/specqr.jl --help
```

`--input FILE` はファイル、`--stdin` は標準入力を読みます。
ファイル / 標準入力に `--binary` を付けると生バイトとして扱います。
テキストの改行、末尾の改行、NUL を勝手に削除せず、不正な UTF-8 は拒否します。
入力元は1つだけ指定してください。出力先が存在する場合は `--force` なしでは上書きせず、
シンボリックリンクを出力先にすることも拒否します。詳細は
[CLI の使い方](docs/getting-started.ja.md#cli-の使い方)を参照してください。

## 検証済みの環境

ソースは可搬性を意識した Julia 実装で、OS を制限していません。
実際に検証済みなのは **Linux x86_64 / Julia 1.10.12 LTS・1.13.1 stable** です。
両版で 92,637 件の単体チェックと 10,186 件の参照ケース、独立デコーダーによる
画像検証、CLI、別プロジェクトからの利用を確認しています。
[CI](https://github.com/SpecQR/SpecQR-Julia/actions)で各コミットの結果を確認できます。

**Windows、macOS、その他のアーキテクチャ、32-bit は未検証です。**
特に日本語ファイル名、標準入出力のバイト保持、出力ファイルの排他的作成、
パッケージ利用は、それぞれの OS で実行するまで検証済みとは扱いません。

## 文字コードと制限

- テキストは厳密な UTF-8 として扱い、不正な文字列やサロゲート符号化を拒否します。
  Unicode 正規化は行いません。任意のバイト列は `UInt8` 配列で渡せます。
- ECI はバイトの解釈を示すラベルであり、文字コードを変換しません。
  テキストの byte セグメントは常に UTF-8 です。
- 行列は `matrix[y, x]`、`module_at(qr, x, y)` は1始まりです。
  QR のマスク番号は 0–7、Structured Append の公開部番号は 1–16 です。
- 入力や出力に資源上限があります。入力は通常最大 1,000,000 文字またはバイト、
  手動セグメントは最大 16,384 個、単一シンボルの厳密な最適化は最大 7,089 Unicode scalar です。
  実際の QR 容量はこれより小さく、モードや誤り訂正によって変わります。
- PNG / RGBA は最大 4,194,304 pixels です。PNG は stored-DEFLATE を使うため、
  汎用圧縮器を使う PNG より大きくなります。SVG と data URL にも出力上限があります。
- GS1 Digital Link は明示した ASCII authority の範囲を扱います。
  ブラウザーの URL 処理全体や IDNA 変換との互換は提供しません。

## ドキュメントとテスト

- [日本語の使い方](docs/getting-started.ja.md): 導入、画像生成、GS1、分割、CLI、エラー対応
- [English README](README.en.md)
- [API の詳細（英語）](docs/native-api.md)、[API 概要（英語）](docs/api.md)
- [GS1 / Digital Link の範囲（英語）](docs/gs1.md)、[描画とサイズ（英語）](docs/rendering.md)
- [検証方法（英語）](docs/verification.md)、[OS ごとの検証手順（英語）](docs/native-platform-validation.md)
- [CI の構成（英語）](docs/ci.md)

```sh
julia --startup-file=no --project=. test/runtests.jl
```

`Test` と `SHA` は Julia 同梱のテスト用標準ライブラリです。
Python の検証スクリプトや独立デコーダーは開発時の検証用で、
SpecQR の実行時依存ではありません。ライセンスは [MIT](LICENSE) です。

GS1 URL の受理範囲を TypeScript の独立結果に合わせて復元しました。通常 QR の生成処理は変更していません。[変更範囲と検証](docs/url-compatibility.ja.md)。
