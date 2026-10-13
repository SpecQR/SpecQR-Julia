# Contributing

runtime の依存関係は Julia Base と同梱の Base64 に限定してください。新たな package や JLL への依存、外部の QR 実装、runtime で使うネットワークリソースは対象外です。厳密な UTF-8 と任意のバイナリバイト列の契約を維持してください。

Julia stable と LTS で、完全な native suite と固定した参照 corpus を実行してください。失敗には回帰テストを追加し、Julia を別の処理系で解釈・変換・エミュレートせず、実際の native 実行を使ってください。任意の decoder tools は runtime の依存関係に含めないでください。JSON adapter だけでなく、ソースの公開 API もテストしてください。source manifest はレビュー後にのみ再生成し、その正確な source archive を対象に、source と結び付いた native harness を再実行してください。

cross-compiler、container の architecture label、互換レイヤー、意図した Julia runtime を実行していない script を根拠に、platform 対応を主張しないでください。native 実行の report は、実際に使った OS/architecture だけを説明します。
