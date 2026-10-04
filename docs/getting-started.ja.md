# 日本語の使い方

[日本語 README](../README.md) | [English README](../README.en.md)

このガイドは、ソースを取得して最初の QR を生成するまでと、よく使う機能を説明します。
API 名、キーワード引数、CLI オプションは翻訳せず、そのまま入力してください。
詳細な全オプションは [API 仕様（英語）](native-api.md)を参照してください。

## 1. ソースを読み込む

Julia が必要です。実行確認済みの版は Linux x86_64 の Julia 1.10.12 と 1.13.1 です。
Windows / macOS での実行確認はまだ行っていません。
ソースの取得にはネットワークを使いますが、QR の生成はオフラインで行えます。

```sh
git clone https://github.com/SpecQR/SpecQR-Julia.git
cd SpecQR-Julia
julia --startup-file=no --project=.
```

このリポジトリをアクティブなプロジェクトにすると、`using SpecQR` で読み込めます。
`Pkg.add("SpecQR")` でレジストリから入れる手順ではありません。
再現性が必要な場合は、利用するコミットを記録し、そのコミットに固定してください。

パッケージ管理機能を使わず、リポジトリのルートから直接読み込む方法もあります。
上の方法とは別の Julia セッションで実行します。

```julia
include("src/SpecQR.jl")
using .SpecQR
qr = generate("HELLO 123")
```

別の Julia プロジェクトから使う場合は、そのプロジェクトで次を実行します。
パスは取得したソースの絶対パスに置き換えてください。

```julia
using Pkg
Pkg.develop(path="/absolute/path/to/SpecQR-Julia")
using SpecQR
```

`Pkg.develop` は呼び出し元のプロジェクトにローカル依存を登録します。
初めて Pkg を使う環境ではレジストリの初期化でネットワークアクセスが発生する場合があります。
パッケージ管理もネットワークも避けたい場合は、上の `include` の方法を使ってください。

## 2. 日本語を SVG / PNG にする

以下は `using SpecQR` で読み込み済みの Julia セッションで実行します。

```julia
qr = generate("こんにちは、世界 🌍"; error_correction_level="Q")
write("hello.svg", to_svg(qr))
write("hello.png", to_png(qr; scale=6, margin=4))
png_url = to_data_url(qr; format="png")
println(qr.version, " / ", qr.error_correction_level, " / ", qr.mask_pattern)
```

- `error_correction_level` は `"L"` / `"M"` / `"Q"` / `"H"` です。
  誤り訂正を強くすると同じ version に入るデータ量は減ります。
- `scale` は1モジュールあたりの pixels、`margin` は周囲の余白をモジュール単位で指定します。
  既定値は `scale=8`、`margin=4`、黒と白です。
- `to_svg` は文字列、`to_png` は `Vector{UInt8}` を返します。
  Julia の `write` は同名ファイルを上書きするので、保存先には注意してください。
- PNG は純 Julia の stored-DEFLATE 方式で、汎用圧縮器を使う PNG よりファイルが大きくなります。

テキストは UTF-8 です。モードの自動選択では、対応する文字に漢字モードを使うこともあります。
UTF-8 の byte モードと ECI 26 を明示する場合は、次のようにします。

```julia
utf8_qr = generate("日本語 😀"; mode="byte", eci=26)
binary_qr = generate(UInt8[0x00, 0xff, 0x1d]; mode="byte")
```

ECI は文字コード変換ではありません。UTF-8 以外の文字コードを使うときは、
呼び出し側で変換したバイト列と適切な ECI 番号を指定します。
スキャナー側の ECI / 漢字モード対応によって読み取り結果は変わります。

## 3. 生成前に容量を確認する

```julia
preview = plan("HELLO 123"; version=1, error_correction_level="L")
println(preview.ok, " / ", preview.data_bit_length, " / ", preview.capacity_bits)
capacity = get_capacity(1, "L"; mode="numeric").maximum
@assert capacity == 41
```

`plan` と `estimate` は行列や誤り訂正コードを作らずに計画を返します。
容量が足りない計画では `ok` が `false` になります。
実際の生成で収まらなければ `DataTooLongError` が発生します。
version を自動選択させるには `version` を省略し、必要なら
`min_version` / `max_version` で範囲を指定します。

## 4. GS1 を生成する

AI と値は文字列で渡します。数値として扱うと先頭のゼロが失われます。

```julia
items = [(ai="01", value="09506000134352"),
         (ai="10", value="BATCH%ONE")]
element_string = create_gs1_element_string(items)
gs1_qr = generate(element_string; gs1=true)
write("gs1.png", to_png(gs1_qr))
link = create_gs1_digital_link(items; base_url="https://id.gs1.org")
parsed = parse_gs1_digital_link(link)
```

`gs1=true` は element string を検証し、FNC1 第1位置を付けます。
AI 値は許可された printable ASCII の範囲で、値に括弧や ASCII GS を直接入れられません。
可変長フィールドの区切りはヘルパーに任せてください。
上の `%` は文字そのものとして保持されます。

一方、低水準の手動 FNC1 英数字セグメントは QR のエスケープ表現をそのまま受け取り、
`%` は区切り、`%%` は文字の `%` を意味します。高水準 API と混同しないでください。

GS1 は限定した50種の AI カタログを対象とし、全仕様の検証や認証ではありません。
Digital Link も厳密な ASCII authority プロファイルで、URL を取得せずに処理します。
日付は6桁の表現を確認しますが、実在する暦日かどうかまでは確認しません。
詳しくは [GS1 の仕様と制限（英語）](gs1.md)を参照してください。

## 5. Structured Append で分割する

```julia
parts = generate_structured_append(repeat("SPECQR ", 20); version=1)
for (i, symbol) in enumerate(parts.symbols)
    write("part-$i.png", to_png(symbol))
end
println(parts.total, " / ", parts.parity)
```

2–16個の QR に分割します。1個に収まる場合は `generate` を使ってください。
テキストは Unicode scalar の途中で切りません。公開する部番号は1始まりです。
この高水準の分割 API では GS1 / FNC1 / ECI と組み合わせられません。
読み取り・再結合には対応したスキャナーやアプリが必要で、一般的なスマートフォンの
カメラが自動で結合するとは限りません。

## CLI の使い方

次はリポジトリのルートで実行する Linux シェルの例です。

```sh
julia --startup-file=no bin/specqr.jl --text '日本語の QR' --format png --output cli.png
julia --startup-file=no bin/specqr.jl --input '入力.txt' --output file.svg
julia --startup-file=no bin/specqr.jl --input payload.bin --binary --format png --output binary.png
printf 'HELLO\n' | julia --startup-file=no bin/specqr.jl --stdin --output stdin.svg
julia --startup-file=no bin/specqr.jl --text '123456789' --plan
julia --startup-file=no bin/specqr.jl --help
```

`入力.txt` は UTF-8、`payload.bin` は生バイトの入力ファイルをあらかじめ用意してください。
`--text` / `--input` / `--stdin` / `--hex` / 手動 `--segment` の入力元から1つを選びます。
手動セグメントを使うときだけ `--segment` を複数回指定できます。

テキストを勝手にトリミングしないため、`printf` の例では最後の改行も QR の内容です。
`--binary` は `--input` または `--stdin` と組み合わせます。
`--output` の既存ファイルは通常拒否されます。意図して置き換えるときだけ `--force` を付けてください。
不正なオプションや入力では stderr にエラーを出し、終了コードは2です。

## エラーと診断

```julia
try
    generate("HELLO"; error_correction_level="X")
catch err
    err isa SpecQRError || rethrow()
    println(error_code(err))  # INVALID_ECC_LEVEL
end
```

`SpecQRError` から派生する型と `error_code` でエラーを識別できます。
`diagnostics(qr)` は診断のコピーを返します。余白不足、コントラスト、透明度、
容量や印刷サイズの警告は、実際の読み取り品質を保証するものではありません。
印刷用に `print_dpi` を指定する場合は、有限で正の値が必要です。

## 次に読むもの

- [API の全体像（英語）](api.md) / [Julia API の詳細（英語）](native-api.md)
- [描画、色、資源上限（英語）](rendering.md)
- [検証範囲と実行方法（英語）](verification.md)
- [Windows / macOS を含むネイティブ検証手順（英語）](native-platform-validation.md)

現時点で日本語になっているのは README とこの入門ガイドです。
詳細仕様、CLI の `--help` とエラーメッセージは英語です。
