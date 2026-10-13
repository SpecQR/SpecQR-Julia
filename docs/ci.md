# Linux continuous integration

workflow は、実際の GitHub-hosted Ubuntu 24.04 x86-64 runners で、既存の source に結び付いた verifiers を実行します。公式 Julia の **1.10.12 LTS** と **1.13.1 stable** の Linux binaries を SHA-256 で固定して使用します。Windows、macOS、ほかの architecture での成功を意味しません。workflow の定義やローカルでの予行実行は、リモート CI の成功ではありません。公開した正確な commit の checks を確認してください。

両 lanes は、native unit suite（レビューした baseline で 92,637 checks）、独立した Nayuki matrices 2,400 件を含む golden requests 10,186 件、全 27 CLI checks、クリーンなオフラインの Pkg consumer と別の direct-include consumer、38 harness self-tests を実行します。ZXing-C++ 3.1.1 による実 PNG decode、ZXing Java 3.5.4 による PNG と matrix の decode、librsvg による SVG の raster 化と pixel 比較、共有の回帰検査も実行します。さらに、元の GS1 requests 1,411 件、独立した TypeScript の positive targets 80 件、全 49 authority/Digital Link operations、fail-closed の GS1 harness self-tests を実行します。decoder の scale は、レビュー済みの既存の既定値（C++ 8、Java 3）です。これらの結果は、ライブラリの既定 scale 8 で Java が成功するという主張ではありません。

package の runtime 依存は Julia Base と同梱 Base64 だけです。CPython、ZXing、Pillow、Java、librsvg は検証用 tools に限ります。PyPI binary wheels と Maven Central の ZXing jar は、正確な version/SHA-256 で固定します。Java 17 と librsvg は Ubuntu の公式 apt repositories から導入し、インストールした版を記録しますが、版の固定はしません。Ubuntu runner image と system Python 3.12 には patch が適用される場合があります。Julia の checksums は公式の [versions feed](https://julialang-s3.julialang.org/bin/versions.json) に由来し、各 lane は正確な download URL と checksum を保持します。Action の commit 固定は、actions/checkout v7.0.1 と actions/upload-artifact v7.0.1 の公式 GitHub release metadata と固定した action 定義で確認しています。両方とも Node 24 を使います。cache、repository の書込み権限、永続する checkout credential、secret、OIDC grant は設定していません。artifact upload は GitHub の job ごとの artifact service を使い、workflow は release を公開しません。

## Source changes and archive identity

CI は commit 済みの `SOURCE-SHA256.json` を検証し、その manifest を黙って再生成することはありません。`scripts/prepare_ci.py stage` は、source file の欠落・追加・変更を拒否し、検証した inventory だけを別の一時ディレクトリへコピーして、両 tree を再検査します。そのうえで、timestamp と permissions を固定し、member を整列した決定的な ZIP を作ります。native verifier はそのコピーから実行し、archive を検査します。CI の manifest は、この workflow、CI helper、test lockfile、文書も含め、除外しません。過去の 52 ファイルの release は、別の不変な artifact として維持します。

source を意図的に変更するときは、変更をレビューしてから manifest を明示的に再生成し、同じ commit に含めます。

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/prepare_ci.py manifest > /tmp/SpecQR-SOURCE-SHA256.json
cp /tmp/SpecQR-SOURCE-SHA256.json SOURCE-SHA256.json
python3 scripts/prepare_ci.py stage --output /tmp/specqr-check
```

新しい出力ディレクトリを使ってください。一時的な manifest を source tree 内に生成すると、不要な inventory entry になるため、tree の外で生成してください。digest は証拠を bytes に結び付けるものであり、公開者の真正性を証明しません。意図的な変更の後は、現在の source の manifest と archive hashes が変わります。CI を過去の release archive hash へ恒久的に固定しているわけではありません。

## Evidence and required checks

両 Julia lanes は、テストが失敗しても、前提条件が利用できる独立した検査を続けます。失敗した step を成功と表示することはありません。artifact は成功・失敗のどちらでも upload し、source archive、commit、host/tool の版、reports、完全な参照 transcripts、process receipts を保持します。コンパイル済み Julia depots は除外し、consumer の明示的な空 registry、Project、Manifest は保持します。証拠の path は元の runner の path であり、実行の出典として保存します。artifact は 14 日後に期限切れになるため、release の証拠がそれ以上必要な場合は、download したコピーを保持してください。

`Required Linux checks` の aggregate は、matrix lane のどれかが失敗・取消し・skip になれば失敗します。必要に応じて branch protection でこの check を選択してください。workflow だけで repository policy が設定されるわけではありません。証拠の正確な範囲とオフラインの制限は [native 検証](native-platform-validation.md)を参照してください。環境 flag は OS レベルのネットワーク sandbox ではありません。
