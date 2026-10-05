# Portable text value model

The `text/` package is a platform-neutral value layer. Text offsets are UTF-16
code units. It validates well-formed surrogate pairs and rejects ranges or
selection endpoints that split a supplementary scalar. It preserves the input
text exactly; it does not segment graphemes or clip offsets for a host API.

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
for the remaining evidence boundary.
