///|
fn macos_text_fixture(value : String) -> @text.TextDocument {
  match @text.TextDocument::new(value) {
    Ok(document) => document
    Err(_) => abort("valid CoreText fixture rejected")
  }
}

///|
fn macos_text_point(x : Double, y : Double) -> @primitives.Point {
  match @primitives.Point::new(x, y) {
    Ok(point) => point
    Err(_) => abort("finite CoreText point rejected")
  }
}

///|
fn macos_text_rect(
  x : Double,
  y : Double,
  width : Double,
  height : Double,
) -> @primitives.Rect {
  match @primitives.Rect::new(x, y, width, height) {
    Ok(rect) => rect
    Err(_) => abort("valid CoreText bounds rejected")
  }
}

///|
test "macOS CoreText provider is explicit off Darwin and bounded on Darwin" {
  match @macos_text.require_grayscale_raster() {
    Err(UnsupportedPlatform) => {
      assert_true(
        @macos_text.measure(macos_text_fixture("A"), "sans", 16.0)
        is Err(UnsupportedPlatform),
      )
      assert_true(
        @macos_text.hit_test(
          macos_text_fixture("A"),
          "sans",
          16.0,
          macos_text_point(0.0, 0.0),
        )
        is Err(UnsupportedPlatform),
      )
      assert_true(
        @macos_text.admit_scene_text_run_at(
          macos_text_fixture("A"),
          16.0,
          macos_text_point(0.0, 0.0),
          macos_text_rect(0.0, 0.0, 40.0, 24.0),
        )
        is Err(UnsupportedPlatform),
      )
    }
    Ok(_) => {
      let latin = @macos_text.measure(macos_text_fixture("Hello"), "sans", 18.0).unwrap()
      assert_eq(latin.line_count(), 1)
      assert_true(latin.logical_rect().size().width() > 0.0)
      assert_true(latin.first_line_baseline() > 0.0)
      assert_eq(latin.unknown_glyph_count(), 0)

      let japanese = @macos_text.measure(
        macos_text_fixture("日本語かな"),
        "sans",
        18.0,
      ).unwrap()
      assert_eq(japanese.unknown_glyph_count(), 0)
      assert_true(japanese.logical_rect().size().width() > 0.0)

      let combining = @macos_text.measure(
        macos_text_fixture("a\u{301}"),
        "sans",
        18.0,
      ).unwrap()
      assert_eq(combining.carets().length(), 3)
      assert_false(combining.caret_at(1).unwrap().is_cursor_position())
      assert_true(combining.caret_at(2).unwrap().is_cursor_position())

      let supplementary = @macos_text.measure(
        macos_text_fixture("A𝟙B"),
        "sans",
        18.0,
      ).unwrap()
      assert_true(supplementary.caret_at(1).unwrap().is_cursor_position())
      assert_true(supplementary.caret_at(2) is Err(_))
      assert_true(supplementary.caret_at(3).unwrap().is_cursor_position())
      let hit = @macos_text.hit_test(
        macos_text_fixture("A𝟙B"),
        "sans",
        18.0,
        macos_text_point(
          supplementary.caret_at(3).unwrap().strong().left(),
          5.0,
        ),
      ).unwrap()
      assert_true(hit.resolved_is_cursor_position())
      assert_true(hit.resolved_utf16_offset() >= 1)

      let empty = @macos_text.measure(macos_text_fixture(""), "sans", 18.0).unwrap()
      assert_eq(empty.carets().length(), 1)
      assert_eq(empty.logical_rect().size().width(), 0.0)
      assert_true(empty.logical_rect().size().height() > 0.0)

      assert_true(
        @macos_text.measure(macos_text_fixture("abc אבג"), "sans", 18.0)
        is Err(UnsupportedBidi),
      )
      assert_true(
        @macos_text.measure(macos_text_fixture("A\nB"), "sans", 18.0)
        is Err(UnsupportedMultiline),
      )
      assert_true(
        @macos_text.measure(macos_text_fixture("A\u{0}B"), "sans", 18.0)
        is Err(UnsupportedInput),
      )
      assert_true(
        @macos_text.measure(macos_text_fixture("A"), "", 18.0)
        is Err(InvalidFontFamily),
      )
      assert_true(
        @macos_text.measure(macos_text_fixture("A"), "sans", 0.0)
        is Err(InvalidFontSize),
      )
      assert_true(
        @macos_text.admit_scene_text_run_at(
          macos_text_fixture("👩‍💻"),
          18.0,
          macos_text_point(0.0, 0.0),
          macos_text_rect(0.0, 0.0, 128.0, 40.0),
        )
        is Err(UnsupportedColor),
      )
      let unsupported = @macos_text.measure(
        macos_text_fixture("\u{378}"),
        "sans",
        18.0,
      ).unwrap()
      assert_true(unsupported.unknown_glyph_count() > 0)
      assert_true(
        @macos_text.admit_scene_text_run_at(
          macos_text_fixture("\u{378}"),
          18.0,
          macos_text_point(0.0, 0.0),
          macos_text_rect(0.0, 0.0, 128.0, 40.0),
        )
        is Err(UnsupportedGlyph),
      )

      assert_true(
        @macos_text.admit_scene_text_run_at(
          macos_text_fixture("日本語 e\u{301}"),
          18.0,
          macos_text_point(10.0, 20.0),
          macos_text_rect(0.0, 0.0, 256.0, 48.0),
        )
        is Ok(_),
      )
      assert_true(
        @macos_text.admit_scene_text_run_at(
          macos_text_fixture("A"),
          18.0,
          macos_text_point(1000000001.0, 0.0),
          macos_text_rect(0.0, 0.0, 64.0, 32.0),
        )
        is Err(InvalidCoordinates),
      )

      let fonts = @macos_text.font_resolution_json(
        macos_text_fixture("Latin abc 日本語"),
        "sans",
        18.0,
      ).unwrap()
      assert_true(fonts.contains("\"segment\":\"latin\""))
      assert_true(fonts.contains("\"segment\":\"japanese\""))
      assert_true(fonts.contains("\"file_url\":\"/"))
    }
    Err(_) =>
      fail("CoreGraphics grayscale admission returned an unexpected error")
  }
}
