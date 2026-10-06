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
  let hit = (document, point) => {
    match @linux_text.hit_test(document, "sans", 18.0, point) {
      Ok(value) => Ok(value)
      Err(_) => Err(@field.HitTestFailed)
    }
  }
  let bounds = @primitives.Rect::new(24.0, 24.0, 512.0, 36.0).unwrap()
  let viewport = @primitives.Rect::new(0.0, 0.0, 640.0, 480.0).unwrap()
  let initial = @field.TextField::new(
    2UL,
    bounds,
    18.0,
    @text.TextDocument::new("").unwrap(),
    measured,
    admitted,
  ).unwrap()
  let metadata = []
  let commands = []
  for index in 0..<128 {
    let id = "command.\{index}"
    let label = if index % 3 == 0 {
      "日本 コマンド \{index}"
    } else {
      "Open command \{index}"
    }
    let row = @palette.CommandMetadata::new(id, label, index % 7 != 0).unwrap()
    metadata.push(row)
    let descriptor = @capability.Descriptor::new(
      id,
      label,
      "CPU profiling fixture",
      @capability.Command,
      @capability.Schema::unit(),
      @capability.Schema::unit(),
      @capability.StateChange,
      false,
      @capability.Local,
      None,
      1,
    ).unwrap()
    let binding = @capability.TypedCapability::new(
      descriptor,
      _ => Ok(()),
      _ => Ok(@capability.Value::unit()),
      _ => Ok(()),
      () => Ok(()),
      _ => Ok(()),
    ).gui_binding()
    commands.push(@palette.PaletteCommand::new(row, binding))
  }
  let palette = @palette.CommandPalette::new(initial, commands).unwrap()
  let tree = Ref(
    @element.ElementTree::new([
      @element.ElementNode::new(1UL, None, viewport),
      initial.element_node(Some(1UL)),
    ]).unwrap(),
  )
  palette.open(tree).unwrap()
  let epoch = palette.open_epoch()
  let typed = spans
    .run("input.handle", () => {
      palette.handle_input(
        @primitives.TextInput(text="日"),
        measured,
        admitted,
        hit,
      )
    })
    .unwrap()
  guard typed.consumed && palette.picker().query() == "日" else {
    abort("typed query")
  }
  let preview = spans
    .run("composition.update", () => {
      palette.field().update_composition_utf8("に", 3, 3, measured, admitted)
    })
    .unwrap()
  palette.install_field_at(epoch, preview).unwrap()
  guard palette.picker().query() == "日" && palette.field().is_composing() else {
    abort("preview must not filter")
  }
  let committed = spans
    .run("composition.commit", () => {
      palette.field().commit_composition("本", measured, admitted)
    })
    .unwrap()
  palette.install_field_at(epoch, committed).unwrap()
  guard palette.picker().query() == "日本" && !palette.field().is_composing() else {
    abort("committed query")
  }
  let source_picker = @palette.Picker::new(metadata).unwrap()
  let filtered = spans
    .run("picker.filter", () => source_picker.filter("日本"))
    .unwrap()
  guard filtered.match_count() == palette.picker().match_count() else {
    abort("filter agreement")
  }
  let moved = spans
    .run("input.handle", () => {
      palette.handle_input(
        @primitives.KeyPressed(
          key=@primitives.ArrowDown,
          modifiers=@primitives.Modifiers::none(),
          repeat=false,
        ),
        measured,
        admitted,
        hit,
      )
    })
    .unwrap()
  guard moved.consumed && palette.is_open() else { abort("navigation") }
  let visible = spans.run("picker.visible", () => {
    palette.picker().visible_commands()
  })
  guard visible.length() == 8 else { abort("bounded visible list") }
  let (field_clip, field_items) = spans
    .run("scene.field", () => palette.field().paint_items(100UL, 7))
    .unwrap()
  // The same row builder is used by the actual native palette fixture.
  let (list_clip, list_items) = spans
    .run("scene.list", () => {
      palette
      .picker()
      .paint_items(
        200UL,
        8,
        @primitives.Rect::new(24.0, 84.0, 512.0, 288.0).unwrap(),
        36.0,
        (id, command, position, clip) => {
          let document = @text.TextDocument::new(command.label()).unwrap()
          let measurement = measured(document).unwrap()
          admitted(document, measurement).unwrap()
          let (origin, bounds) = @field.scene_text_run_geometry(measurement).unwrap()
          let color = @primitives.Color::rgba(
            if command.is_enabled() {
              238
            } else {
              128
            },
            132,
            140,
            255,
          ).unwrap()
          match
            @scene.SceneItem::text_run(
              id,
              bounds,
              origin,
              command.label(),
              18.0,
              color,
              @scene.AffineTransform::new(
                1.0,
                0.0,
                0.0,
                1.0,
                position.x(),
                position.y(),
              ).unwrap(),
              1.0,
              Some(clip),
            ) {
            Ok(item) => Ok(item)
            Err(_) => Err(@palette.InvalidMetadata)
          }
        },
      )
    })
    .unwrap()
  let scene = spans
    .run("scene.build", () => {
      let items = field_items.copy()
      for item in list_items {
        items.push(item)
      }
      @scene.SceneSnapshot::new(
        viewport,
        1.0,
        [],
        [field_clip, list_clip],
        items,
      )
    })
    .unwrap()
  let mut fingerprint = 14695981039346656037UL
  for c in scene.canonical_json() {
    fingerprint = (fingerprint ^ c.to_int().to_uint64()) * 1099511628211UL
  }
  (
    palette.field().revision() * 100 +
    palette.picker().match_count() * 10 +
    scene.items().length(),
    fingerprint,
  )
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
