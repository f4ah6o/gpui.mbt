# PR #40: computer useを使わないE2E検証

2026-10-07 20:28–20:34 JST。primary agentが直接実行、サブエージェント・computer useなし。macOS 26.5.2 / arm64。最終結果は **FAIL / product Green未達**。

## 対象と再現手順

- source HEAD: `c7e6cae99ffd218320d0377a53ea3cd5218421b4`
- 隔離worktree: `/Users/fu2hito/.codex/worktrees/pr40-script-e2e/gpui.mbt`
- branch: `test/20261007-pr40-script-e2e`
- PR: https://github.com/gpui-mbt/gpui.mbt/pull/40（添付済み。変更・pushなし）
- 同一fresh buildの実行ファイルSHA256: `e4eb4e60a19fdce9cbe8bb5258a59244835b5047c3f5180f3c8310c92913f551`

worktreeで実行した既存のentrypoint（`--run-dir`は毎回新規の外部directoryを指定する）:

```sh
python3 infra/macos-desktop/actrun-feedback.py --root /private/tmp/gpui-macos-quality-profile --mode native --run-dir <new-external-evidence-directory>
/private/tmp/gpui-macos-quality-profile/moon/bin/moon fmt --check
```

`run_e2e.py`は実行コマンドとPID・開始/終了・exitを記録する外部ラッパー。既存fixtureのキー列・Return回数・200 iterationの上限・合否判定は変更していない。製品とrepository内のテストソースは無変更、前後source一致・worktree clean。

## 検証結果

| 検証 | 結果 |
| --- | --- |
| repository Python/contract tests | 成功 |
| macOS profile/runner/evidence tests | 成功 |
| native MoonBit check | 成功 |
| 全target check / warnings denied | 成功 |
| TextField owner/model tests | 成功（28 tests） |
| native synthetic E2E / smoke / CoreText / fresh app build | 成功 |
| live Kotoeri IME / 最終画像の受入 | 失敗 |
| MoonBit fmt --check | 成功 |

actrunは7項目中6成功、`partial_failed` / exit1。最初のrunは実アプリで `Hello 日本語` のmarked compositionまで到達、initial/ compositionをScreenCaptureKitで取得。caretを除外したtext ROI内で1535 pixelsの変化を確認。Return後の最終画像・以降のEscape/cancellationなど必要な受入項目は未完であり、Greenに数えていない。

## 配送と確定の切り分け

診断ログのみ有効にした同一binaryの追加runは、key windowが成立せず入力前に失敗（`ime-trace`）。その結果をReturn失敗の再現として扱わない。

続いて `run_ime_with_activation.py` と `activate_owned_app.m` で、spawnしたPIDと実行ファイルURLの一致を検証し、そのPIDだけに公開AppKit `NSRunningApplication.activateWithOptions:0` を1回要求した。キーボード/マウスの外部操作はなく、入力は既存のapp-local native producerと実際のKotoeriを使用した。helperのrequest成功だけではreadyと扱わず、既存driverがkey window/contextとowned frameを検証した。

この追加E2E (`ime-activated`) は入力準備・日本語変換を通過し、Return(keycode36 / dispatch9)について以下を確認した。

- frozen/current receiptともdown_posted/up_posted/down_dispatched/up_dispatchedがtrue。
- input contextあり、handleEventはtrue、interpretKeyEvents fallbackはfalse。
- 200 iterationの上限時点でfocused=true / composing=true、commit callbacks=0、pending batchなし、accepted sequence=11のまま。
- 結果: accepted IME operation observationがタイムアウト。Returnの配送後に確定が観測されない状態を再現した。gpui固有・OS・test producerのどれが原因かまでは断定していない。

従来の対照fixtureの最初のKeyUp未確認と違い、この実アプリE2EではReturnのdown/upまで証拠がある。標準NSTextViewとの対照比較を再実行したものではない。

## Cleanupと証跡

失敗処理で入力ソース復元・session_closedのapp-owned ACKを確認。その後テストのPanicErrorでSIGABRT(exit -6)になっており、正常終了として扱わない。全3runのowned app PIDは非稼働、親runner回収済み。現在残るownedプロセスなし。

主証跡: `native/summary.json`, `native/ime-acceptance/summary.json`, `ime-activated/summary.json`, `ime-activated/app.stdout.log`, `return-diagnostics.json`, `activation.json`, `verification.json`, `evidence-sha256.json`。独立レビューは今回未実施（ユーザーのno-subagent指示）。外部activation wrapperを新しい製品コード承認として扱わない。

残課題: ReturnをIMEがhandledとした後、commit/unmark callbackが観測されない理由の調査。最終画像・後続操作の受入を完了する必要がある。
