///|
/// An opaque handle to app-owned state. Copying the handle refers to the same
/// state; access is mediated by `App::read` or `App::update`.
pub struct Entity[T] {
  priv app_id : AppId
  priv id : EntityId
  priv cell : Ref[EntityCell[T]]
}

///|
priv struct EntityCell[T] {
  mut value : T?
  mut revision : UInt64
  mut alive : Bool
  mut dirty : Bool
  listeners : Array[Listener]
  owned_subscriptions : Array[Subscription]
}

///|
/// A change or release notification for one entity.
pub struct EntityEvent {
  priv entity_id : EntityId
  priv revision : UInt64
  priv kind : EntityEventKind
}

///|
/// Kind of entity lifecycle notification.
pub(all) enum EntityEventKind {
  Changed
  Released
}

///|
/// Return the source entity identity.
pub fn EntityEvent::entity_id(self : EntityEvent) -> EntityId {
  self.entity_id
}

///|
/// Return the revision associated with the event.
pub fn EntityEvent::revision(self : EntityEvent) -> UInt64 {
  self.revision
}

///|
/// Return whether this event reports a change or final release.
pub fn EntityEvent::kind(self : EntityEvent) -> EntityEventKind {
  self.kind
}

///|
priv struct Listener {
  state : Ref[SubscriptionState]
}

///|
priv struct SubscriptionState {
  mut active : Bool
  mut callback : ((EntityEvent) -> Result[Unit, @diagnostics.FrameworkError])?
}

///|
/// A cancellable registration. MoonBit has no deterministic destructors, so
/// call `unsubscribe`; destroying its owner also deactivates it.
pub struct Subscription {
  priv state : Ref[SubscriptionState]
}

///|
/// Deactivate this subscription. Repeated calls are harmless and release the
/// callback closure immediately.
pub fn Subscription::unsubscribe(self : Subscription) -> Unit {
  self.state.val.active = false
  self.state.val.callback = None
}

///|
/// Return whether this registration can still receive a callback.
pub fn Subscription::is_active(self : Subscription) -> Bool {
  self.state.val.active
}

///|
/// Return this entity's stable identity.
pub fn[T] Entity::id(self : Entity[T]) -> EntityId {
  self.id
}

///|
/// Return whether the app has released this entity.
pub fn[T] Entity::is_live(self : Entity[T]) -> Bool {
  self.cell.val.alive
}

///|
/// A context capability valid only during one `App::update` callback.
pub struct Context[T] {
  priv app : App
  priv entity : Entity[T]
  priv active : Ref[Bool]
}

///|
/// Return the entity identity authorized by this context.
pub fn[T] Context::entity_id(self : Context[T]) -> EntityId {
  self.entity.id
}

///|
/// Read the current entity value while the context is active.
pub fn[T] Context::get(
  self : Context[T],
) -> Result[T, @diagnostics.FrameworkError] {
  match self.validate("Context::get") {
    Err(error) => Err(error)
    Ok(_) =>
      match self.entity.cell.val.value {
        Some(value) => Ok(value)
        None => Err(entity_not_live(self.app, self.entity.id, "Context::get"))
      }
  }
}

///|
/// Replace the entity value. Notification remains explicit through `notify`.
pub fn[T] Context::set(
  self : Context[T],
  value : T,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.validate("Context::set") {
    Err(error) => Err(error)
    Ok(_) => {
      self.entity.cell.val.value = Some(value)
      Ok(())
    }
  }
}

///|
/// Mark this entity dirty. Multiple calls in one update produce one event.
pub fn[T] Context::notify(
  self : Context[T],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.validate("Context::notify") {
    Err(error) => Err(error)
    Ok(_) => {
      self.entity.cell.val.dirty = true
      Ok(())
    }
  }
}

///|
/// Observe another entity by scheduling this entity's update after each source
/// change. A release event does not run an observer update; use `subscribe` to
/// receive release notifications. The returned registration belongs to this
/// entity and is cancelled when it is released.
pub fn[T, U] Context::observe(
  self : Context[T],
  source : Entity[U],
  callback : (Context[T]) -> Result[Unit, @diagnostics.FrameworkError],
) -> Result[Subscription, @diagnostics.FrameworkError] {
  match self.validate("Context::observe") {
    Err(error) => Err(error)
    Ok(_) =>
      if source.app_id != self.entity.app_id {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.WrongApp,
            "Context::observe",
            app_id=self.app.id().value(),
            entity_id=source.id.value(),
            subsystem="core",
            message="source and observer belong to different apps",
          ),
        )
      } else if !source.cell.val.alive {
        Err(entity_not_live(self.app, source.id, "Context::observe"))
      } else {
        let observer = self.entity
        let app = self.app
        let state = Ref({ active: true, callback: None, })
        let listener = (event : EntityEvent) => {
          if event.kind is Changed {
            let observer = observer
            let callback = callback
            let state = state
            app.enqueue_update(() => {
              if state.val.active && observer.cell.val.alive {
                ignore(app.run_update_now(observer, callback))
              }
            })
          }
          Ok(())
        }
        state.val.callback = Some(listener)
        register_listener_with_state(self, source, state, "Context::observe")
      }
  }
}

///|
/// Subscribe to source change and release events in registration order.
pub fn[T, U] Context::subscribe(
  self : Context[T],
  source : Entity[U],
  callback : (EntityEvent) -> Result[Unit, @diagnostics.FrameworkError],
) -> Result[Subscription, @diagnostics.FrameworkError] {
  match self.validate("Context::subscribe") {
    Err(error) => Err(error)
    Ok(_) =>
      if source.app_id != self.entity.app_id {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.WrongApp,
            "Context::subscribe",
            app_id=self.app.id().value(),
            entity_id=source.id.value(),
            subsystem="core",
            message="source and subscriber belong to different apps",
          ),
        )
      } else if !source.cell.val.alive {
        Err(entity_not_live(self.app, source.id, "Context::subscribe"))
      } else {
        let state = Ref({ active: true, callback: Some(callback), })
        register_listener_with_state(self, source, state, "Context::subscribe")
      }
  }
}

///|
fn[T, U] register_listener_with_state(
  context : Context[T],
  source : Entity[U],
  state : Ref[SubscriptionState],
  operation : String,
) -> Result[Subscription, @diagnostics.FrameworkError] {
  match context.validate(operation) {
    Err(error) => Err(error)
    Ok(_) => {
      source.cell.val.listeners.retain(listener => {
        let has_callback = match listener.state.val.callback {
          Some(_) => true
          None => false
        }
        listener.state.val.active && has_callback
      })
      context.entity.cell.val.owned_subscriptions.retain(subscription => {
        subscription.is_active()
      })
      let subscription = Subscription::{ state, }
      source.cell.val.listeners.push({ state, })
      context.entity.cell.val.owned_subscriptions.push(subscription)
      Ok(subscription)
    }
  }
}

///|
fn[T] Context::validate(
  self : Context[T],
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  if !self.active.val {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.ContextExpired,
        operation,
        app_id=self.app.id().value(),
        entity_id=self.entity.id.value(),
        subsystem="core",
        message="context is outside its update callback",
      ),
    )
  } else if !(self.app.inner.val.lifecycle is Running) {
    Err(
      @diagnostics.FrameworkError::new(
        @diagnostics.AppNotRunning,
        operation,
        app_id=self.app.id().value(),
        entity_id=self.entity.id.value(),
        subsystem="core",
        message="app stopped during the update callback",
      ),
    )
  } else if !self.entity.cell.val.alive {
    Err(entity_not_live(self.app, self.entity.id, operation))
  } else {
    Ok(())
  }
}

///|
/// Create a new app-owned entity with revision zero.
pub fn[T] App::create_entity(
  self : App,
  value : T,
) -> Result[Entity[T], @diagnostics.FrameworkError] {
  match self.check_running("App::create_entity") {
    Err(error) => Err(error)
    Ok(_) => {
      let local_id = self.inner.val.next_entity_id
      let max_uint64 : UInt64 = 0xffff_ffff_ffff_ffff
      if local_id == max_uint64 {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.ResourceExhausted,
            "App::create_entity",
            app_id=self.id().value(),
            subsystem="core",
            message="entity identity space exhausted",
          ),
        )
      } else {
        self.inner.val.next_entity_id = local_id + 1
        let id = EntityId::{ app_id: self.id(), value: local_id, }
        let entity : Entity[T] = {
          app_id: self.id(),
          id,
          cell: Ref({
            value: Some(value),
            revision: 0,
            alive: true,
            dirty: false,
            listeners: [],
            owned_subscriptions: [],
          }),
        }
        let app = self
        self.inner.val.entities.push({
          id,
          release: () => release_entity(app, entity),
        })
        Ok(entity)
      }
    }
  }
}

///|
/// Read entity state through a synchronous callback. Reference-valued `T`
/// follows the immutable/copy-on-write discipline documented for M1.
pub fn[T, R] App::read(
  self : App,
  entity : Entity[T],
  callback : (T) -> R,
) -> Result[R, @diagnostics.FrameworkError] {
  match self.validate_entity(entity, "App::read") {
    Err(error) => Err(error)
    Ok(_) =>
      match self.inner.val.phase {
        Idle | Dispatching =>
          match entity.cell.val.value {
            None => Err(entity_not_live(self, entity.id, "App::read"))
            Some(value) => {
              let previous_phase = self.inner.val.phase
              self.inner.val.phase = Reading
              let result = callback(value)
              self.inner.val.phase = previous_phase
              Ok(result)
            }
          }
        Reading | Updating => Err(reentrant_error(self, "App::read", entity.id))
      }
  }
}

///|
/// Invoke one serialized synchronous update callback. Every entered callback
/// advances revision once, including an error. Calls made during notification
/// or task dispatch are queued FIFO; calls from a read/update callback fail.
pub fn[T] App::update(
  self : App,
  entity : Entity[T],
  callback : (Context[T]) -> Result[Unit, @diagnostics.FrameworkError],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.validate_entity(entity, "App::update") {
    Err(error) => Err(error)
    Ok(_) =>
      match self.inner.val.phase {
        Idle => self.run_update_now(entity, callback)
        Updating | Reading =>
          Err(reentrant_error(self, "App::update", entity.id))
        Dispatching => {
          let app = self
          let entity = entity
          self.enqueue_update(() => ignore(app.run_update_now(entity, callback)))
          Ok(())
        }
      }
  }
}

///|
fn[T] App::run_update_now(
  self : App,
  entity : Entity[T],
  callback : (Context[T]) -> Result[Unit, @diagnostics.FrameworkError],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.validate_entity(entity, "App::update") {
    Err(error) => Err(error)
    Ok(_) if entity.cell.val.revision == 0xffff_ffff_ffff_ffff =>
      Err(
        @diagnostics.FrameworkError::new(
          @diagnostics.ResourceExhausted,
          "App::update",
          app_id=self.id().value(),
          entity_id=entity.id.value(),
          subsystem="core",
          message="entity revision space exhausted",
        ),
      )
    Ok(_) => {
      let previous_phase = self.inner.val.phase
      self.inner.val.phase = Updating
      entity.cell.val.dirty = false
      let active = Ref(true)
      let context = Context::{ app: self, entity, active, }
      let callback_result = callback(context)
      active.val = false
      entity.cell.val.revision = entity.cell.val.revision + 1
      let revision = entity.cell.val.revision
      let dirty = entity.cell.val.dirty
      entity.cell.val.dirty = false
      self.inner.val.phase = previous_phase
      if dirty && entity.cell.val.alive {
        enqueue_entity_event(self, entity, EntityEvent::{
          entity_id: entity.id,
          revision,
          kind: Changed,
        })
      }
      match callback_result {
        Ok(_) => Ok(())
        Err(error) => {
          let wrapped = @diagnostics.FrameworkError::new(
            @diagnostics.CallbackFailure,
            "App::update",
            app_id=self.id().value(),
            entity_id=entity.id.value(),
            subsystem="core",
            message=callback_error_context(error),
          )
          self.record_error(wrapped)
          Err(wrapped)
        }
      }
    }
  }
}

///|
/// Return the entity's latest update revision.
pub fn[T] App::revision(
  self : App,
  entity : Entity[T],
) -> Result[UInt64, @diagnostics.FrameworkError] {
  match self.validate_entity(entity, "App::revision") {
    Err(error) => Err(error)
    Ok(_) =>
      match self.inner.val.phase {
        Reading | Updating =>
          Err(reentrant_error(self, "App::revision", entity.id))
        Idle | Dispatching => Ok(entity.cell.val.revision)
      }
  }
}

///|
/// Release an entity. It becomes unavailable before release observers are
/// queued for delivery. Destruction during read/update callbacks is rejected.
pub fn[T] App::destroy_entity(
  self : App,
  entity : Entity[T],
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.validate_entity(entity, "App::destroy_entity") {
    Err(error) => Err(error)
    Ok(_) =>
      match self.inner.val.phase {
        Reading | Updating =>
          Err(reentrant_error(self, "App::destroy_entity", entity.id))
        Idle | Dispatching => {
          release_entity(self, entity)
          self.inner.val.entities.retain(control => control.id != entity.id)
          Ok(())
        }
      }
  }
}

///|
fn[T] App::validate_entity(
  self : App,
  entity : Entity[T],
  operation : String,
) -> Result[Unit, @diagnostics.FrameworkError] {
  match self.check_running(operation) {
    Err(error) => Err(error)
    Ok(_) =>
      if entity.app_id != self.id() {
        Err(
          @diagnostics.FrameworkError::new(
            @diagnostics.WrongApp,
            operation,
            app_id=self.id().value(),
            entity_id=entity.id.value(),
            subsystem="core",
            message="entity belongs to a different app",
          ),
        )
      } else if !entity.cell.val.alive {
        Err(entity_not_live(self, entity.id, operation))
      } else {
        Ok(())
      }
  }
}

///|
fn[T] release_entity(app : App, entity : Entity[T]) -> Unit {
  if entity.cell.val.alive {
    entity.cell.val.alive = false
    for subscription in entity.cell.val.owned_subscriptions {
      subscription.unsubscribe()
    }
    entity.cell.val.owned_subscriptions.clear()
    let event = EntityEvent::{
      entity_id: entity.id,
      revision: entity.cell.val.revision,
      kind: Released,
    }
    enqueue_entity_event(app, entity, event)
  }
}

///|
fn[T] enqueue_entity_event(
  app : App,
  entity : Entity[T],
  event : EntityEvent,
) -> Unit {
  let listeners = entity.cell.val.listeners.copy()
  app.enqueue_notification(() => {
    if event.kind is Released || entity.cell.val.alive {
      for listener in listeners {
        let state = listener.state
        if state.val.active {
          match state.val.callback {
            None => ()
            Some(callback) =>
              match callback(event) {
                Ok(_) => ()
                Err(error) =>
                  app.record_error(
                    @diagnostics.FrameworkError::new(
                      @diagnostics.CallbackFailure,
                      "EntityEvent::listener",
                      app_id=app.id().value(),
                      entity_id=event.entity_id.value(),
                      subsystem="core",
                      message=callback_error_context(error),
                    ),
                  )
              }
          }
        }
      }
    }
    if event.kind is Released {
      for listener in listeners {
        Subscription::{ state: listener.state, }.unsubscribe()
      }
      entity.cell.val.value = None
      entity.cell.val.listeners.clear()
      entity.cell.val.owned_subscriptions.clear()
    }
  })
}

///|
fn entity_not_live(
  app : App,
  entity_id : EntityId,
  operation : String,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.EntityNotLive,
    operation,
    app_id=app.id().value(),
    entity_id=entity_id.value(),
    subsystem="core",
    message="entity has been released",
  )
}

///|
fn reentrant_error(
  app : App,
  operation : String,
  entity_id : EntityId,
) -> @diagnostics.FrameworkError {
  @diagnostics.FrameworkError::new(
    @diagnostics.ReentrantUpdate,
    operation,
    app_id=app.id().value(),
    entity_id=entity_id.value(),
    subsystem="core",
    message="a state operation cannot re-enter an active callback",
  )
}
