///|
fn macos_text_test_document(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid macOS test document rejected")
  }
}

///|
test "CoreText measure returns copied metrics and scalar carets" {
  match require_grayscale_raster() {
    Err(UnsupportedPlatform) => ()
    Err(_) => abort("CoreText grayscale raster unavailable")
    Ok(_) => {
      let document = macos_text_test_document("office e\u{301}")
      let measurement = match measure(document, "sans", 16.0) {
        Ok(value) => value
        Err(_) => abort("CoreText measurement failed")
      }
      assert_eq(measurement.document().text(), document.text())
      assert_eq(measurement.line_count(), 1)
      assert_eq(measurement.unknown_glyph_count(), 0)
      assert_true(measurement.logical_rect().size().width() > 0.0)
      assert_eq(measurement.carets().length(), 10)
      assert_true(measurement.caret_at(0).unwrap().is_cursor_position())
      assert_true(measurement.caret_at(9).unwrap().is_cursor_position())
    }
  }
}

///|
test "CoreText measure rejects multiline and preserves empty text" {
  match require_grayscale_raster() {
    Err(UnsupportedPlatform) => ()
    Err(_) => abort("CoreText grayscale raster unavailable")
    Ok(_) => {
      assert_true(
        measure(macos_text_test_document("first\nsecond"), "sans", 16.0)
        is Err(UnsupportedMultiline),
      )
      let empty = match measure(macos_text_test_document(""), "sans", 16.0) {
        Ok(value) => value
        Err(_) => abort("empty CoreText measurement failed")
      }
      assert_eq(empty.line_count(), 1)
      assert_eq(empty.carets().length(), 1)
      assert_eq(empty.carets()[0].utf16_offset(), 0)
    }
  }
}
