///|
test "headless example increments and delivers its notification" {
  let app = match @core.App::new() {
    Ok(app) => app
    Err(_) => fail("headless app allocation should succeed")
  }
  assert_true(app.start() is Ok(_))
  let entity = match app.create_entity(0) {
    Ok(entity) => entity
    Err(_) => fail("running app should create an entity")
  }
  let seen = Ref(false)
  let subscriber = match app.create_entity(()) {
    Ok(observer) =>
      match
        app.update(observer, context => {
          match
            context.subscribe(entity, _event => {
              seen.val = true
              Ok(())
            }) {
            Ok(_) => Ok(())
            Err(error) => Err(error)
          }
        }) {
        Ok(_) => observer
        Err(_) => fail("observer should subscribe")
      }
    Err(_) => fail("running app should create an observer")
  }

  assert_true(@headless.increment(app, entity) is Ok(_))
  assert_true(app.read(entity, value => value) is Ok(1))
  assert_true(!seen.val)
  assert_true(app.run_ready(16) is Ok(1))
  assert_true(seen.val)
  assert_true(app.destroy_entity(subscriber) is Ok(_))
  assert_true(app.run_ready(16) is Ok(1))
}
