///|
/// Replace an entity with its incremented value and explicitly notify listeners.
pub fn increment(
  app : @core.App,
  entity : @core.Entity[Int],
) -> Result[Unit, @diagnostics.FrameworkError] {
  app.update(entity, context => {
    match context.get() {
      Err(error) => Err(error)
      Ok(value) =>
        match context.set(value + 1) {
          Err(error) => Err(error)
          Ok(_) => context.notify()
        }
    }
  })
}
