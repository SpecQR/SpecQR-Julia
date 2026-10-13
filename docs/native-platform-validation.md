# Native platform validation

## Claims and release gates

`scripts/verify_native.py` の合格 report が対象とするのは、その report に記録した実際の OS、
architecture、Julia version、厳密に同一の source archive、bounds-checking profile のみです。
配布に必須の検証 lane は、公式 Julia **1.13.1 stable** と **1.10.12 LTS** runtimes を使う
native Linux x86-64 です。Linux での成功は Windows や macOS での実行を証明しません。
Windows と macOS の lanes は、**対応する実機の native reports がなければ未検証**のままです。
それらがないことだけで、承認済みの 2 つの Linux release gates が自動的に止まるわけではありません。
emulator、mock runtime、生成した platform label、shell wrapper では native platform の合格を証明できません。

report は再現可能な実行証拠であり、電子署名や、敵対的なマシンに対する証明ではありません。
実行ファイルの hash と併せて、toolchain の download metadata と公式 archive の checksums を確認してください。
harness 単独では、任意の実行ファイルの発行者の同一性を証明しません。

## Requirements and invocation

Python 3.9+ と、公式 Julia の native 実行ファイルを直接使ってください。
検証 harness は Python 標準ライブラリだけを使います。対象 package は Julia Base と
同梱の Base64 標準ライブラリを使い、Test と SHA はテスト専用の追加依存です。

release source archive を展開し、別途提供された SHA-256 を確認してから、その `SpecQR-Julia`
ディレクトリで実行してください。出力先は source tree の外に置いてください。
inventory は、source の変更や source files の追加を意図的に拒否します。
archive と展開済み tree は、同一の `SOURCE-SHA256.json` と、その manifest に記載したすべての同一 bytes を含む必要があります。

```sh
python3 scripts/test_verify_native.py
python3 scripts/verify_native.py \
  --julia /absolute/path/to/julia-1.13.1/bin/julia \
  --expect-version 1.13.1 --expect-platform linux --expect-arch x86_64 \
  --check-bounds yes \
  --source-archive /absolute/path/to/SpecQR-Julia-source.zip \
  --archive-sha256 EXACT_ARCHIVE_SHA256 \
  --output /absolute/path/to/evidence/linux-x86_64-1.13.1
```

LTS gate では、Julia 1.10.12 と新しい出力ディレクトリで繰り返してください。
実際の Windows または macOS runner では、`windows` または `darwin`、対応する native architecture、
その Julia 実行ファイルを直接使ってください。Python の引数処理は空白と Unicode paths に対応します。
既存の出力ディレクトリは再利用しないでください。
失敗または中断した lane を合格と付け替えてはいけません。原因を調べ、同じ source に対して
新たに完全な lane を実行するか、修正で source が変わる場合は新しい固定済み source archive を作成してください。

## What a complete lane checks

1. **実際の host と runtime の識別情報。** Python は現在の OS と host architecture を読み取ります。
   Windows では `IsWow64Process2` を呼び出し、結果の `nativeMachine` を使います。
   これにより、Windows ARM 上で emulation された x64 Python process が x64 host を名乗ることを防ぎます。
   macOS では process 内から `sysctl.proc_translated` API を呼び出し、Rosetta での実行を拒否します。
   直接指定した ELF、PE、thin Mach-O image の headers は、要求した OS、architecture、pointer width と一致する必要があります。
   shell launchers と universal binaries は拒否します。Julia は別途、実際の version、kernel、architecture、
   pointer width、thread 数を報告します。WSL は Linux lane であり、Windows lane ではありません。
   これらの確認は、あり得るすべての仮想化・変換された Linux 環境を検出するものではありません。
   runner の運用者は、実際に条件に合う native runtime を使う必要があります。
2. **不変の source との対応付け。** 自動生成物を除くすべての source files を、実行前後に SHA-256 で確認します。
   固定した圧縮 fixture corpus は独立に確認します。archive の bytes は提供された hash と一致し、
   archive 内の source subtree は、manifest 自身も含め、展開済み manifest と厳密に一致する必要があります。
   安全でない archive paths、symlinks、重複 entries は拒否します。`.git`、build/output directories、
   Python bytecode caches は source inventory から除外し、source の証拠として使いません。
3. **実際の multithreaded unit suite。** harness は `test/runtests.jl` を Julia の 4 threads で実行し、
   空でない completion marker がちょうど 1 個、合格 checks が 90,000 以上、failed/error/broken checks が 0、
   Julia version が期待どおりであることを要求します。完了件数の集計は、Julia 1.10 の tuple API と
   Julia 1.13 の `TestCounts` API の両方に対応します。この marker がない log は不完全です。
4. **source に対応付けた全 reference cases。** 実際の Julia bridge が全 **10,186** requests を実行します。
   内訳は generation 3,028、estimate 1,920、capacity 640、Structured Append 22、raw-core 4,320、
   Reed–Solomon 255、finite-field の全数確認 1 request です。
   generation corpus には **2,400 件の独立した Nayuki 行列比較**が含まれます。
   responses の欠落・余分・形式不正・型違い・不一致、空でない stderr、timeout、0 以外の終了コードはすべて失敗です。
   JSON の真偽値を整数として扱うことはできず、重複 keys と非有限数も拒否します。
   lane の bounds profile は bridge にも適用します。
5. **CLI 実行。** すべての CLI checks で実際の実行ファイルを起動します。
   report は固定の見積り件数ではなく、実際に完了した呼出しを数えます。
   対象には、Unicode の入出力 paths、files と raw stdin を通した NUL・CR・LF・GS・UTF-8 の保持、
   binary stdin と hexadecimal input を通した全 256 byte values、SVG/PNG structure、上書き拒否と明示的な置換、
   計画、manual ECI、Structured Append の full split と symbol diagnostics、
   不正な options、不正な UTF-8、file 不在の errors が含まれます。
6. **隔離した local Pkg consumer と、別の Pkg を使わない runtime consumer。** 詳細は下記の offline 説明を参照してください。
   両方とも、厳密に指定した success marker を出して完了する必要があります。

## Offline consumer details

新しい Julia Pkg depot は、`JULIA_PKG_OFFLINE=true` でも、local path を解決する前に
既定の General registry を install しようとする場合があります。そのため harness は、
新しい隔離済み consumer depot に、登録 packages も remote sources もない**明示的に空の local registry** を作成します。
これは文書化した bootstrap 手順であり、未操作の depot を使うという主張ではありません。
`Registry.toml` は、正確な byte 数と SHA-256 を report に記録して保持します。
隔離環境では `JULIA_PKG_SERVER=''`、`JULIA_PKG_OFFLINE=true` を設定し、
script は `Pkg.offline(true)` を呼び出してから `Pkg.develop(path=exact_source)` を実行します。

consumer は、直接依存が SpecQR であり、解決済み依存先の全名称が厳密に `SpecQR` と `Base64` であることを確認します。
Unicode を encode し、SVG と PNG を描画します。Project.toml と Manifest.toml を保持して hash を記録します。
Pkg は Julia 自身のテスト時 tooling です。Pkg が内部で使う標準ライブラリや JLL modules は、
SpecQR の実行時 package 依存にはなりません。consumer は外部の runtime package を download も解決もしません。

2 つ目の process は、別の未作成 depot と、`JULIA_LOAD_PATH` を `@stdlib` に制限した環境で開始します。
厳密に同一の `src/SpecQR.jl` を直接 include し、Pkg を呼ばず、同じ Unicode payload を encode して SVG/PNG を描画します。
新たに外部から load された module が Base64 以外にないことを確認します。
Julia 自身が初期状態で load した sysimage modules は baseline として扱い、SpecQR によるものとは数えません。
この別のテストにより、package manager を使わない source の利用を確認します。

環境 flags は、OS による network sandbox ではありません。air-gap を主張するには、
運用者が runner の network access も無効にする必要があります。
この再現可能なテストは registry や外部 package が不要であることを確認するもので、
すべての network syscalls を調査したとは主張しません。

## Receipts, replay, and review

`report.json` の `status: "passed"` は、全段階と実行後の source check が成功した場合にだけ設定します。
report には、厳密に同一の source archive/hash、source manifest、fixture hashes、実際の host、
Julia native image/hash、runtime response、unit 件数、全 reference 件数、CLI 件数、consumer artifacts を記録します。
失敗時は error と、それまでに書き出した receipts を保持します。

各 process receipt は、正確な引数 vector、作業ディレクトリ、関連する Julia 環境、source manifest の hash、
直接指定した実行ファイルの hash、期待・実際の終了状態、所要時間、raw stdin/stdout/stderr との対応を保持します。
reference bridge はさらに、**完全で欠損のない stdin と stdout の JSONL streams を gzip companion files として**、
raw stderr とともに保持します。圧縮 artifacts の hashes は report に対応付けます。
verifier は stream として展開し、元の bytes/hash が実行時に計測したものと同じであることを確認します。
これらの実行記録は、同じ source に対応付けた実際の bridge に再入力できます。
mock responses ではなく、進捗だけの logs で置き換えることもありません。

reports、receipt JSON files、raw streams、圧縮 reference streams、consumer の scripts/project/manifest/empty registry、
固定済み source archive、公式 toolchain metadata を保持してください。
再現可能な `depot/compiled` caches は release evidence ではなく、検証後に削除できます。
report が参照する空の registry と consumer manifest は削除しないでください。
変更可能な source に対する診断的な試行は暫定と表示し、source に対応付けた完全な最終 lane の代わりにはできません。

## Harness self-tests are separate

`python3 scripts/test_verify_native.py` は、不正な source/archive の対応付け、破損した fixtures と実行記録、
誤った runtime/test markers、誤った JSON 型、native headers の拒否、Windows の native machine の処理、
Rosetta の拒否、0 以外の process 終了コード、stderr errors、timeouts を検査します。
合成した image headers と mock platform APIs は、**この自己テスト内だけ**にあります。
自己テストの合格は OS や Julia での実行を主張するものではなく、どちらの native release gate も満たしません。
