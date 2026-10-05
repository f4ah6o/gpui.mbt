# Portable text value model

The `text/` package is a platform-neutral value layer. Text and selection
offsets are UTF-16 code units. It validates well-formed surrogate pairs and
rejects ranges or selection endpoints that split a supplementary scalar. The
strict `utf8_length`, `utf8_offset`, and `utf16_offset` methods translate
between UTF-16 offsets and UTF-8 byte offsets at Unicode scalar boundaries.
They reject a byte offset inside a scalar with `SplitUtf8`, preserve the input
text exactly, and do not segment graphemes or clip offsets for a host API.
Negative offsets return `NegativeOffset`; offsets past their coordinate space
return `OutOfBounds`; and a UTF-16 offset inside a surrogate pair returns
`SplitSurrogate`. UTF-8 byte-length overflow returns `LengthOverflow` before
byte out-of-bounds or split-scalar errors. Each conversion scans the document
in O(n) time using safe scalar iteration; no UTF-8 copy or cached offset table
is stored. `TextError` now has the additional `SplitUtf8` variant, so exhaustive
matches must handle that case.

`TextDocument` stores immutable text and a directional selection. Its
range-based replacement returns a new document and collapses the selection
after the inserted text.

`TextComposition.begin(document, range)` stores the exact original document,
including its selection, and marks the validated target range without editing
text. Every `update(preedit, selection)` replaces that same original range,
even after earlier previews. The update selection is relative to the preedit;
its validated UTF-16 endpoints are rebased into the resulting document while
preserving direction. `commit(text)` replaces the original range with the
final text and collapses selection after it. `cancel()` restores the exact
original document and selection. These operations return new values, and
existing snapshots remain unchanged. Committed and cancelled values reject
further transitions.

This model has no mutable session IDs or freshness guarantees. A host must own
the current value and enforce event sequencing and composition ownership; an
old snapshot remains a separate branch. This is not an input-method adapter and
does not establish Japanese IME support.

Still open are host event sequencing, actual Japanese IME behavior, text layout,
candidate-window placement, shaping/rendering, undo, multi-cursor editing,
accessibility, and production platform gates. See the [codebase gap
analysis](codebase-gap-analysis.md) and [issue 0004](../issues/open/0004-platform-rendering-and-native-boundaries.md)
for the remaining evidence boundary. The offset bridge does not provide
shaping, caret geometry, hit testing, grapheme navigation, or runtime IME
behavior.
