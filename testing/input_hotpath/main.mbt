///|
extern "C" fn now_ns() -> Int64 = "gpui_hotpath_now_ns"

///|
extern "C" fn resolution_ns() -> Int64 = "gpui_hotpath_resolution_ns"

///|
struct Sample {
  label : String
  ns : Int64
}

///|
struct Spans {
  enabled : Bool
  profiler : @hotpath.ProfilerNs
  samples : Array[Sample]
  mut collect : Bool
}

///|
fn[T] Spans::run(self : Spans, label : String, body : () -> T) -> T {
  if !self.enabled || !self.collect {
    return body()
  }
  let started = Ref(0L)
  let elapsed = Ref(-1L)
  let reads = Ref(0)
  let value = self.profiler.measure_ns_with(
    label,
    fn() {
      let value = now_ns()
      if reads.val == 0 {
        started.val = value
      } else if started.val >= 0L && value >= started.val {
        elapsed.val = value - started.val
      }
      reads.val += 1
      value
    },
    body,
  )
  // At most32 cycles, fixed25 measured calls/cycle; printed only after work.
  self.samples.push({ label, ns: elapsed.val, })
  value
}

///|
fn measure(
  spans : Spans,
  document : @text.TextDocument,
) -> Result[@text_layout.TextMeasurement, @field.TextFieldError] {
  spans.run("text.measure", () => {
    match @linux_text.measure(document, "sans", 18.0) {
      Ok(value) => Ok(value)
      Err(_) => Err(@field.MeasurementFailed)
    }
  })
}

///|
fn admit(
  spans : Spans,
  document : @text.TextDocument,
  measurement : @text_layout.TextMeasurement,
) -> Result[Unit, @field.TextFieldError] {
  spans.run("text.admit", () => {
    let (origin, bounds) = @field.scene_text_run_geometry(measurement).unwrap()
    match @linux_text.admit_scene_text_run_at(document, 18.0, origin, bounds) {
      Ok(_) => Ok(())
      Err(_) => Err(@field.AdmissionFailed)
    }
  })
}

///|
fn cycle(spans : Spans) -> (Int, UInt64) {
  let measured = document => measure(spans, document)
  let admitted = (document, measurement) => admit(spans, document, measurement)
  let original = @field.TextField::new(
      2UL,
      @primitives.Rect::new(0.0, 0.0, 240.0, 36.0).unwrap(),
      18.0,
      @text.TextDocument::new("abcd")
      .unwrap()
      .with_selection(@text.TextSelection::new(3, 1).unwrap())
      .unwrap(),
      measured,
      admitted,
    )
    .unwrap()
    .with_focus(true)
    .unwrap()
  let first = spans
    .run("composition.update", () => {
      original.update_composition_utf8("に", 3, 3, measured, admitted)
    })
    .unwrap()
  let second = spans
    .run("composition.update", () => {
      first.update_composition_utf8("にほん", 9, 9, measured, admitted)
    })
    .unwrap()
  let committed = spans
    .run("composition.commit", () => {
      second.commit_composition("日本", measured, admitted)
    })
    .unwrap()
  guard committed.document().text() == "a日本d" && !committed.is_composing() else {
    abort("commit invariant")
  }
  let undone = spans
    .run("history.undo", () => committed.undo(measured, admitted))
    .unwrap()
  guard undone.document() == original.document() else {
    abort("undo invariant")
  }
  let redone = spans
    .run("history.redo", () => undone.redo(measured, admitted))
    .unwrap()
  guard redone.document() == committed.document() else {
    abort("redo invariant")
  }
  let cancelled = spans
    .run("composition.cancel", () => {
      second.cancel_composition(measured, admitted)
    })
    .unwrap()
  guard cancelled.document() == original.document() &&
    !cancelled.is_composing() &&
    !cancelled.can_undo() else {
    abort("cancel invariant")
  }
  let (typed, action) = spans
    .run("input.handle", () => {
      cancelled.handle_input(
        @primitives.TextInput(text="X"),
        measured,
        admitted,
        (document, point) => {
          match @linux_text.hit_test(document, "sans", 18.0, point) {
            Ok(value) => Ok(value)
            Err(_) => Err(@field.HitTestFailed)
          }
        },
      )
    })
    .unwrap()
  guard typed.document().text() == "aXd" && action is None else {
    abort("input invariant")
  }
  let (clip, items) = spans
    .run("scene.paint", () => typed.paint_items(100UL, 7))
    .unwrap()
  let scene = spans
    .run("scene.build", () => {
      @scene.SceneSnapshot::new(
        @primitives.Rect::new(0.0, 0.0, 240.0, 36.0).unwrap(),
        1.0,
        [],
        [clip],
        items,
      )
    })
    .unwrap()
  // Numeric digest consumed by the runner, never text, selection or scene JSON.
  let mut fingerprint = 14695981039346656037UL
  for c in scene.canonical_json() {
    fingerprint = (fingerprint ^ c.to_int().to_uint64()) * 1099511628211UL
  }
  (typed.revision() * 100 + scene.items().length(), fingerprint)
}

///|
fn main {
  let enabled = @env.args().contains("--instrumented")
  let spans = {
    enabled,
    profiler: @hotpath.ProfilerNs::new(),
    samples: [],
    collect: false,
  }
  for _ in 0..<8 {
    cycle(spans) |> ignore
  }
  let mut observed_min = 9223372036854775807L
  let mut backwards = 0
  let mut previous = now_ns()
  for _ in 0..<4096 {
    let current = now_ns()
    if current < previous || previous < 0L {
      backwards += 1
    }
    if current > previous && current - previous < observed_min {
      observed_min = current - previous
    }
    previous = current
  }
  spans.collect = true
  let mut checksum = 0
  let mut fingerprint = 0UL
  let began = now_ns()
  for _ in 0..<32 {
    let (value, digest) = cycle(spans)
    checksum += value
    if fingerprint == 0UL {
      fingerprint = digest
    } else {
      guard fingerprint == digest else { abort("scene determinism") }
    }
  }
  let ended = now_ns()
  let workload_ns = if began >= 0L && ended >= began {
    ended - began
  } else {
    -1L
  }
  println(
    "{\"kind\":\"result\",\"instrumented\":\{enabled},\"cycles\":32,\"checksum\":\{checksum},\"fingerprint\":\{fingerprint},\"workload_ns\":\{workload_ns},\"clock_resolution_ns\":\{resolution_ns()},\"observed_min_tick_ns\":\{observed_min},\"backward_reads\":\{backwards},\"invalid_clocks\":\{spans.profiler.invalid_clock_samples()},\"dropped_samples\":\{spans.profiler.dropped_samples()}}",
  )
  for sample in spans.samples {
    println(
      "{\"kind\":\"sample\",\"label\":\"\{sample.label}\",\"ns\":\{sample.ns}}",
    )
  }
  for row in spans.profiler.snapshot() {
    println(
      "{\"kind\":\"aggregate\",\"label\":\"\{row.label}\",\"calls\":\{row.calls},\"total_ns\":\{row.total_ns},\"min_ns\":\{row.min_ns},\"max_ns\":\{row.max_ns},\"p50_estimate_ns\":\{row.p50_ns},\"p95_estimate_ns\":\{row.p95_ns},\"total_saturated\":\{row.total_saturated}}",
    )
  }
  if enabled {
    let calibration = @hotpath.ProfilerNs::new()
    let start = now_ns()
    for _ in 0..<4096 {
      calibration.measure_ns_with("empty", now_ns, () => ())
    }
    let end = now_ns()
    let wrapper = {
      enabled: true,
      profiler: @hotpath.ProfilerNs::new(),
      samples: [],
      collect: true,
    }
    let wrapper_start = now_ns()
    for _ in 0..<4096 {
      wrapper.run("empty", () => ())
    }
    let wrapper_end = now_ns()
    println(
      "{\"kind\":\"calibration\",\"calls\":4096,\"span_total_ns\":\{calibration.snapshot()[0].total_ns},\"full_ns\":\{end - start},\"wrapper_full_ns\":\{wrapper_end - wrapper_start}}",
    )
  }
}
