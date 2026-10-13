# Security and resource limits

payload 全体の公開を意図している場合を除き、秘密情報を QR に入れないでください。QR は符号化であり、暗号化ではありません。復号したリンクは開く前に確認してください。SpecQR は Digital Link の取得やアクセスを行いません。

入力と描画の geometry は、負荷の大きいメモリ確保の前に上限を検査します。不正な UTF-8 や mode/control の並びには型付きのエラーを返します。CLI JSON は、非有限数、重複 key、対になっていない UTF-16 escape、過度なネスト、過大入力を拒否します。公開する配列は、利用者が所有する可変の結果です。配列を変更しても、その結果だけが変わります。描画中の結果を同時に変更しないでください。

符号化、データ損失、入力検証、サービス拒否、出力の escaping に不具合が疑われる場合は、repository の maintainer へ非公開で報告してください。Julia の版、OS/architecture、機密情報を含まない最小入力、実際の結果と期待する結果、source manifest hash を含めてください。同じ process 内で Julia の内部を変更したり、method を上書きしたりする悪意ある呼出し側に対して、package が安全を保証することはできません。
