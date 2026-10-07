# macOS TextField / Kotoeri A/B investigation — NOT Product Green

調査・診断追加まで完了。Return の根本原因は未確定で、製品修正は適用していません。
PR #45 の証跡は変更していません。調査 branch は `fix/20261007-kotoeri-return`。

## 再現対象と変更の分離

作業開始時の worktree は `/Users/fu2hito/.codex/worktrees/17c6/gpui.mbt`、
branch は PR #40 の `codex/feat/20261006-macos-text-ime-quality`、HEAD は
`7232061f83769214843a2ccfa18f1e1a4d989031`、未コミット変更はありませんでした。
他の既存 worktree を reset/checkout/stash/clean/削除していません。

- `c61bd52`: PR #45 の `tested-source.diff` を適用した再現 baseline。
  `git write-tree` および commit tree は指定の `49af3730fac01fe35f07cf644a58811babb1ef3c` と完全一致。
- `1c2df6e`: PR #46 の `1b0e7d222f82a098821ce5ba03c1421f21b27a35` を独立して cherry-pick。
  Bash 3.2 の空配列 build failure の既存修正であり、IME の修正ではありません。
- `8a7cf7c30a4e51862484818200f2fb3dcf8e57ce`: 今回の診断追加。
  即時 preview collector、最小 NSTextView control、opt-in の時間/pump 計測、診断を Green と数えない guard。
  既存のキー列・Return 1回・200 iteration上限・callback/ACK/order・製品受入条件は維持。

再現 baseline の大きな差分と、今回の診断差分は別 commit です。
最終 A/通常 E2E は診断 commit の clean source に対して実行しました。
各 run の before/after source snapshot は一致しています。
実行 binary/dylib は保管時にも SHA256 を再検証しました。`provenance.json` を参照。

## 最終 A/B 観測

| Run | 判定 | composition-ready → preview | Return 観測実時間 | native/AppKit pumps | callback |
| --- | --- | ---: | ---: | ---: | --- |
| A: composition capture を省略 | FAIL | 0.042 ms | 3330.027 ms | 200 / 200 | commit 0 |
| 通常 screenshot E2E | FAIL | 826.222 ms | 3309.945 ms | 200 / 200 | commit 0 |
| B: 最小 NSTextView | FAIL | screenshot/handshake なし | 3369.665 ms | 200 / 200 | insert 0 / unmark 0 |

A と通常 run は同じ executable、dylib、source、Kotoeri、producer、キー列です。
A は initial capture を維持し、composition checkpoint の検証後に即座に preview。
composition を撮らない診断は Product Green には数えません。

GPUI の Return は keycode 36 / dispatch 9、down/up posted と dispatched が全て true。
`handleEvent=true`、interpret fallback=false。timeout 時は composing=true、
pending_batch=false、pending_owner_sync=false、pending_ack_sequence=null、accepted sequence=11。
時間 snapshot は timeout 境界の read-only hook で、復元処理より前に取得。

| Run | Return down から timeout | Return up から timeout |
| --- | ---: | ---: |
| A | 3329.831 ms | 3315.250 ms |
| 通常 | 3308.828 ms | 3300.960 ms |
| B（control 観測終了時） | 3369.289 ms | 3362.310 ms |

Return 後の insert/unmark callback は観測されなかったため、その発生時刻はありません。
`handleEvent=true` は消費の証拠であり、確定成功の証拠ではありません。
GPView/標準 view への KeyUp 配送も、IME 内部の KeyUp 処理完了とは区別します。

B は最小 standard control の新しい run です。正確な `Hello 日本語` の marked
composition、Kotoeri/current input context/focus/first responder の条件を満たし、
Return down/up を配送しても確定しませんでした。source restoration/window closure は true。
以前の KeyUp 未確認の control 結果は再利用していません。

大きい既存 contrast fixture も今回再実行しました。標準 arm は同じ failure を示しましたが、
GPView adapter arm は最初の prefix キー後に停止したため、全体は `not_comparable`。
この fixture 全体を GPUI/標準の比較 PASS として扱っていません。

## 原因境界と追加の対照実験

観測から、composition screenshot 待機を省いても failure は残り、標準 NSTextView
でも同じ Return failure が起きます。「届いた commit の GPUI ACK が詰まった」とする
証拠はありません。共通の synthetic input/AppKit/IME/実行条件を優先すべき境界です。
GPUI の NSTextInputClient に別の欠陥がないことまでは証明していません。

以下は exploratory な別 run です。全て Return 1回、callback 直接注入なし。
製品 producer の変更は残していません。

| 変更条件 | 観測 |
| --- | --- |
| CGEvent timestamp 0 → 起動後の現在時刻 | 標準 control の Return FAIL（3338.608 ms / 200 pumps） |
| dispatch nonce/userData を除去 | 最小 control の Return FAIL |
| CGEventPostToPid（所有 PID のみ） | 最小 control の Return FAIL |
| HID 経由、所有 active/key window を確認 | 最小 control の Return FAIL |
| HID Return up を down 処理後に配送 | 最小 control の Return FAIL |
| 標準 NSApplication.run + 16 ms NSTimer | Return 200 ticks で FAIL。stop 後の wake-up が必要で、観測終了の elapsed は timeout として使えない |
| LaunchServices 経由の .app 起動（source settling も試行） | composition 前提未成立。Return 未送信、比較対象外 |
| Return の keyboard type 198 → ANSI 40 | 最小 control の Return FAIL |

`NSApplication.run` run は timer 上限後の stop で待機したため、所有 PID と executable
を照合した helper が mouse-moved event 1件で wake-up し finally を完了しました。
キーは追加していません。この run の source restoration はログで確認済みです。
secondary logs/temporary source variants は探索の記録であり、bit-identical な製品の
証明には使いません。最終 A/通常 run と最小 B を主証跡とします。

Apple の documented behavior とも比較しました。
[handleEvent は event 消費を報告する](https://developer.apple.com/documentation/appkit/nstextinputcontext/handleevent(_:))。
[CGEvent timestamp は起動後のナノ秒](https://developer.apple.com/documentation/coregraphics/cgeventtimestamp)。
[日本語変換確定は Return](https://support.apple.com/guide/japanese-input-method/keyboard-shortcuts-jpim10263/mac)。
これらは上記の観測を置き換えるものではありません。

## 実行した検証

| # | 検証 | 最終結果 |
| --- | --- | --- |
| 1 | 関連 unit/wbtest | PASS: TextField 28/28、Python 38/38、native callback/contrast contract/timing の3 fixture |
| 2 | native macOS package tests | PASS: platform/macos 5/5、platform/macos_text 1/1 |
| 3 | `moon check --target native --deny-warn` | PASS |
| 4 | `moon check --target all --deny-warn` | PASS |
| 5 | `./script/build_and_run.sh --build` | PASS（quad、加えて test-hook TextField を再build） |
| 6 | `./script/test_macos.sh --build-only` | PASS（native runner build、package/model tests、app bundle build） |
| 7 | live Kotoeri E2E | FAIL: Return timeout |
| 8 | initial screenshot | PASS: owned-window capture、frame binding、目視確認 |
| 9 | composition screenshot | PASS: 通常 run の owned-window capture、frame binding、目視確認 |
| 10 | Return commit | FAIL: commit callbacks=0 |
| 11 | follow-up composition | NOT REACHED |
| 12 | Escape cancellation | NOT REACHED |
| 13 | final screenshot | NOT REACHED |
| 14 | source restoration | PASS: abort receipt restored=true、source before/after一致 |
| 15 | session closure | PASS: abort receipt session_closed=true、process reaped |
| 16 | evidence validation | Product Green validator: FAIL（正しく拒否）。失敗 archive validator: PASS |
| 17 | `moon fmt --check` | PASS |

通常 app の exit code は -6（既存の failure panic）。正常終了とは報告していません。
abort receipt はその前に一度だけ出力され、collector で検証されています。
最小 B も failure の exit code 1。cleanup の成功と E2E の成功を混同していません。

## 差分レビュー

Target: `1c2df6e..8a7cf7c` の診断追加（再現 baseline と既存 build fix は別）。
Verdict: approve for diagnostics; NOT a product fix or Product Green approval.

正しさ、境界/cleanup/opt-in、安全性、API互換性、並行・順序・lifetime、テスト、保守性を
3回の確認でレビュー。通常 build には timing code を含めず、trace は64 records以内。
診断で omitted composition capture を passed report に偽装しても validator が拒否する
テストを実施。再帰 pump、callback生成、ACK bypass、追加 Return、上限増量なし。
残る主要問題は real Kotoeri Return failure の未解決です。
