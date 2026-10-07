# macOS NSTextView contrast fixture

This standalone `GPUI_TESTING` fixture compares one Kotoeri Return operation in
the GPUI text client and a standard `NSTextView`. Normal validation only
compiles and links it. The fixture itself has not been run as part of this
change; launching it requires separate desktop authorization.

## Build and pure contract test

From the repository root, compile and link the fixture without launching it:

```sh
clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  tests/native/macos_nstextview_contrast.m platform/macos_text/core_text.c \
  -framework AppKit -framework QuartzCore -framework Metal \
  -framework CoreText -framework CoreGraphics -framework CoreFoundation \
  -o /tmp/macos_nstextview_contrast
```

The contract test is a separate pure C executable; it does not initialize
AppKit or create a window:

```sh
clang -Wall -Wextra -Werror -Itests/native \
  tests/native/macos_nstextview_contrast_contract_test.c \
  -o /tmp/macos_nstextview_contrast_contract_test
/tmp/macos_nstextview_contrast_contract_test
```

## Run gate and fixed operation

The binary refuses to initialize AppKit unless invoked with `--run` and the
process environment contains `GPUI_FIELD_MACOS_NSTEXTVIEW_CONTRAST=1`. It also
refuses to start when either legacy trace variable is set to `1`:
`GPUI_FIELD_MACOS_IME_DISPATCH_TRACE` or
`GPUI_FIELD_MACOS_IME_STYLE_TRACE`.

After separate authorization, a run uses one owned process and one owned
window. It runs the GPView arm, restores its source/session, then replaces the
content view in that same window with a standard text view for the comparison
arm. Both arms use the same native app-local key-event producer and the same
Kotoeri input source. The fixed sequence is keycodes
`45, 34, 4, 31, 45, 5, 31, 49, 36`; the final key is one Return with `\r`.
Each arm starts from `Hello ` with the caret at UTF-16 offset 6, uses a
640-by-240-point view and 18-point text, and must reach the exact pre-Return
composition `Hello 日本語`. If those preconditions fail, that arm does not post
Return.

Each arm gets a separate maximum of 200 prefix pump iterations and 200 Return
observation iterations. An iteration is one default-mode event pump with the
existing 16 ms pump parameter; the iteration count is not a wall-clock
duration. Return is posted once. A missing exact completion at the finite
limit is a failure, never a pass.

Before selecting the input source or posting any fixture key, each arm now
waits for its owned window/view, native host, first responder, and current input
context to agree. It uses at most 200 calls to the existing native event pump.
The GPView arm may drain only lifecycle events for its own window; the standard
view arm requires the native window registry to be empty. A key event, other
unexpected event, pump error, lost identity, or exhausted limit stops that arm
before source selection and key posting. The startup iteration count and
readiness result are included in the existing arm records. This bounded
readiness count is separate from the unchanged prefix and Return limits. The
200 calls are an iteration cap, not a wall-clock guarantee: the native pump
may drain a queued lifecycle event without waiting for the full 16 ms.

The baseline record also contains one `startup_observation` with the first
pre-pump evaluation and the terminal evaluation. It records fixed numeric
stages/reasons, booleans, and nulls. A component left null was not evaluated
because an earlier condition short-circuited; it is not a reported failure.
The record does not sample each poll, and it does not treat source selection
or the text session as failed when startup stopped before either began.
Stage values are 0 before a pump and 1 after it. Decision values are 0 stop,
1 wait, and 2 ready. Closed-reason values are 0 none, 1 ready, 2 owned
startup precheck, 3 host, 4 pump, 5 unexpected input, 6 unexpected event, 7
iteration limit, and 8 other. The owned-precheck field reports the existing
aggregate predicate, which also includes host and window conditions; it does
not claim to isolate an individual owner check.

The standard view forwards callback and query overrides to `super`. It does
not synthesize an IME callback or force a commit. It recognizes either one
`insertText` callback containing exactly `日本語`, or an `unmarkText`-only
completion, provided the document is exactly `Hello 日本語` with no marked
text. A final state change with no callback is recorded separately. The GPView
arm retains the stricter accepted-batch, presented-frame, and owner revision
checks. These adapter checks are diagnostic and do not constitute a product
acceptance result.

The output is prefixed `GPUI_MACOS_NSTEXTVIEW_CONTRAST` and limited to 64
records. It reports fixed enums, booleans, counts, UTF-16 lengths/ranges, and
geometry numbers; it does not emit text bodies, arbitrary selectors, source
names, or pointers. Natural text-client queries are summarized only during
the Return pump; the fixture does not issue extra queries for the summary.
The observer subclasses and the standalone GPView frame adapter are part of
the diagnostic setup, so a difference can identify a path to investigate but
is not by itself proof of a production defect.

## Interpretation

Only a result with valid observations for both arms and verified cleanup is
comparable:

| Standard `NSTextView` | GPView | Result |
| --- | --- | --- |
| Pass | Fail | `custom_integration` |
| Fail | Fail | `common_path_or_standard_adapter` |
| Pass | Pass | `source_app_loop_not_reproduced` |
| Reverse outcome, invalid preconditions, incomplete observation, or failed cleanup | Any | `not_comparable` |

Cleanup restores and reads back the original input source while each text
client is still alive, closes the owned window, and stops the native host.
Failed or unverified cleanup keeps the overall result non-comparable.
