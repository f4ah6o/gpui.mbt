///|
test "output snapshot decoding is copied, committed and readiness-aware" {
  let records = FixedArray::make(OUTPUT_CAPACITY * OUTPUT_INFO_FIELDS, 0.0)
  records[0] = 1.0
  records[1] = 1.0
  records[2] = 1.0
  records[3] = 2.0
  records[4] = 600.0
  records[5] = 340.0
  records[6] = 2.0
  records[7] = 1.0
  records[8] = 2560.0
  records[9] = 1440.0
  records[10] = 59940.0
  records[11] = 1.0
  let first = match decode_output_snapshot(records, 1) {
    Ok(outputs) => outputs
    Err(_) => fail("valid output snapshot rejected")
  }
  assert_eq(first.length(), 1)
  assert_true(first[0].is_ready)
  assert_true(first[0].has_geometry && first[0].has_current_mode)
  assert_eq(first[0].scale, 2)
  assert_eq(first[0].physical_width_mm, 600)
  assert_eq(first[0].physical_height_mm, 340)
  assert_eq(first[0].transform, 1)
  assert_eq(first[0].mode_width_px, 2560)
  assert_eq(first[0].mode_height_px, 1440)
  assert_eq(first[0].refresh_millihz, 59940)
  assert_true(first[0].is_entered)

  // Decoded values do not alias the borrowed native records.
  records[3] = 4.0
  let second = match decode_output_snapshot(records, 1) {
    Ok(outputs) => outputs
    Err(_) => fail("updated output snapshot rejected")
  }
  assert_eq(first[0].scale, 2)
  assert_eq(second[0].scale, 4)

  // A bound output is visible as not-ready until its first done commit.
  for field = 0; field < OUTPUT_INFO_FIELDS; field = field + 1 {
    records[field] = 0.0
  }
  records[3] = 1.0
  records[11] = 1.0
  let pending = match decode_output_snapshot(records, 1) {
    Ok(outputs) => outputs
    Err(_) => fail("valid pending output rejected")
  }
  assert_true(!pending[0].is_ready)
  assert_true(!pending[0].has_geometry && !pending[0].has_current_mode)
  assert_true(pending[0].is_entered)
  assert_eq(pending[0].scale, 1)
  match decode_output_snapshot(records, 0) {
    Ok(outputs) => assert_eq(outputs.length(), 0)
    Err(_) => fail("empty output list rejected")
  }
}

///|
test "output snapshot decoder rejects malformed and stale metadata" {
  let records = FixedArray::make(OUTPUT_CAPACITY * OUTPUT_INFO_FIELDS, 0.0)
  records[3] = 1.0
  records[0] = 2.0
  match decode_output_snapshot(records, 1) {
    Err(error) => assert_eq(error.code().label(), "conversion_failed")
    Ok(_) => fail("non-boolean readiness accepted")
  }

  records[0] = 0.0
  records[3] = 2.0
  match decode_output_snapshot(records, 1) {
    Err(error) => assert_eq(error.code().label(), "conversion_failed")
    Ok(_) => fail("uncommitted scale accepted")
  }

  records[0] = 1.0
  records[3] = 1.0
  records[8] = 1920.0
  match decode_output_snapshot(records, 1) {
    Err(error) => assert_eq(error.code().label(), "conversion_failed")
    Ok(_) => fail("mode payload without current-mode flag accepted")
  }

  records[2] = 1.0
  records[9] = 1080.0
  records[10] = 60000.0
  match decode_output_snapshot(records, OUTPUT_CAPACITY + 1) {
    Err(error) => assert_eq(error.code().label(), "conversion_failed")
    Ok(_) => fail("output count overflow accepted")
  }

  records[2] = 0.0
  records[9] = 0.0
  records[10] = 0.0
  records[4] = 1.5
  match decode_output_snapshot(records, 1) {
    Err(error) => assert_eq(error.code().label(), "conversion_failed")
    Ok(_) => fail("fractional integer metadata accepted")
  }
}
