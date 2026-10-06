/* Experimental Ubuntu v1 transport. Included after direct input helpers so
 * every producer uses the same owner-thread ordered event queue. */
static int ime_boundary(const uint8_t *bytes, int length, int offset) {
  return offset >= 0 && offset <= length &&
         (offset == length || (bytes[offset] & 0xc0) != 0x80);
}
static int ime_copy_string(uint8_t *out, const char *input, int *length) {
  if (!input)
    return GPUI_INVALID;
  size_t size = strnlen(input, GPUI_IME_MAX_BYTES + 1);
  if (size > GPUI_IME_MAX_BYTES)
    return GPUI_RESOURCE;
  if (!direct_utf8_valid((const uint8_t *)input, (int)size))
    return GPUI_INVALID;
  memcpy(out, input, size + 1);
  *length = (int)size;
  return GPUI_OK;
}
static void ime_clear_stage(struct host *h) {
  memset(&h->ime.stage, 0, sizeof(h->ime.stage));
}
static void ime_clear_preedit_stage(struct host *h) {
  h->ime.stage.cursor_present = h->ime.stage.cursor = 0;
  h->ime.stage.style_count = 0;
  memset(h->ime.stage.styles, 0, sizeof(h->ime.stage.styles));
}
static void ime_clear_commit_stage(struct host *h) {
  h->ime.stage.delete_present = h->ime.stage.delete_index = h->ime.stage.delete_length = 0;
  h->ime.stage.position_present = h->ime.stage.index = h->ime.stage.anchor = 0;
}
static void ime_free_slot(struct host *h, int slot) {
  if (h->ime_queue[slot]) {
    free(h->ime_queue[slot]);
    h->ime_queue[slot] = NULL;
    h->ime_queue_bytes -= sizeof(struct ime_payload);
  }
}
static int ime_advance_epoch(struct host *h) {
  cancel_key_repeat(h);
  reset_compose(h);
  ime_clear_stage(h);
  if (h->ime.exhausted || h->ime.epoch == INT_MAX) {
    h->ime.exhausted = 1;
    h->ime.requested = 0;
    return GPUI_RESOURCE;
  }
  ++h->ime.epoch;
  return GPUI_OK;
}
static int ime_record(struct host *h, struct ime_payload *data) {
  if (!h->window || h->count == QUEUE_CAPACITY || h->seq == INT_MAX ||
      h->ime_queue_bytes > GPUI_IME_QUEUE_BYTES - sizeof(*data))
    return input_failure(h, GPUI_RESOURCE);
  struct ime_payload *copy = malloc(sizeof(*copy));
  if (!copy)
    return input_failure(h, GPUI_RESOURCE);
  *copy = *data;
  copy->window = h->window;
  copy->epoch = h->ime.wire_epoch;
  copy->seat = h->ime.wire_seat;
  copy->proxy_generation = h->ime.proxy_generation;
  int slot = (h->read + h->count) % QUEUE_CAPACITY;
  event(h, copy->kind, 0, 0, 0);
  h->queue[slot][4] = h->queue[slot][5] = h->queue[slot][9] = 0;
  h->ime_queue[slot] = copy;
  h->ime_queue_bytes += sizeof(*copy);
  return GPUI_OK;
}
static int ime_lifecycle_record(struct host *h, int kind) {
  if (h->ime.wire_epoch <= 0 || !h->ime.wire_seat || !h->window)
    return GPUI_OK;
  struct ime_payload data = {0};
  data.kind = kind;
  return ime_record(h, &data);
}
static int ime_current(struct host *h, struct zwp_text_input_v1 *proxy) {
  return proxy == h->ime.proxy && h->ime.proxy && h->state == 0 && !h->error &&
         !h->ime.exhausted && h->ime.requested &&
         h->ime.phase == IME_ACTIVE && h->window && h->seat_name &&
         h->ime.wire_window == h->window &&
         h->ime.wire_seat == h->seat_name &&
         h->ime.wire_epoch == h->ime.epoch;
}
static int ime_serial_current(struct host *h, uint32_t serial) {
  return serial && serial <= INT_MAX && h->ime.serial_floor > 0 &&
         serial >= (uint32_t)h->ime.serial_floor &&
         serial <= (uint32_t)h->ime.latest_serial;
}
static int ime_send_state(struct host *h) {
  if (h->ime.latest_serial == INT_MAX) {
    h->ime.exhausted = 1;
    h->ime.requested = 0;
    ime_clear_stage(h);
    return input_failure(h, GPUI_RESOURCE);
  }
  int serial = ++h->ime.latest_serial;
  zwp_text_input_v1_set_surrounding_text(h->ime.proxy,
      (const char *)h->ime.document, (uint32_t)h->ime.cursor,
      (uint32_t)h->ime.anchor);
  zwp_text_input_v1_set_cursor_rectangle(h->ime.proxy, h->ime.rect[0],
      h->ime.rect[1], h->ime.rect[2], h->ime.rect[3]);
  zwp_text_input_v1_set_content_type(h->ime.proxy,
      ZWP_TEXT_INPUT_V1_CONTENT_HINT_NONE, ZWP_TEXT_INPUT_V1_CONTENT_PURPOSE_NORMAL);
  zwp_text_input_v1_commit_state(h->ime.proxy, (uint32_t)serial);
  return GPUI_OK;
}
static int ime_activate(struct host *h) {
  if (!h->ime.requested || h->ime.phase != IME_INACTIVE)
    return GPUI_OK;
  if (!h->seat || !h->seat_name || !h->surface || !h->window ||
      !h->keyboard_focus_current || !h->ime.proxy)
    return GPUI_UNSUPPORTED;
  if (h->ime.latest_serial == INT_MAX) {
    h->ime.exhausted = 1;
    h->ime.requested = 0;
    return input_failure(h, GPUI_RESOURCE);
  }
  h->ime.serial_floor = h->ime.latest_serial + 1;
  h->ime.wire_epoch = h->ime.epoch;
  h->ime.wire_window = h->window;
  h->ime.wire_seat = h->seat_name;
  h->ime.phase = IME_ACTIVATING;
  ime_clear_stage(h);
  h->ime.modifiers_valid = 0;
  h->ime.known_modifier_mask = 0;
  memset(h->ime.modifier_masks, 0, sizeof(h->ime.modifier_masks));
  zwp_text_input_v1_activate(h->ime.proxy, h->seat, h->surface);
  if (h->ime.panel_requested)
    zwp_text_input_v1_show_input_panel(h->ime.proxy);
  else
    zwp_text_input_v1_hide_input_panel(h->ime.proxy);
  return ime_send_state(h);
}
static void ime_deactivate(struct host *h) {
  if (h->ime.proxy && h->seat && h->ime.phase != IME_INACTIVE &&
      h->ime.phase != IME_DEACTIVATING) {
    /* Stock IBus1.5.32 reset does nothing. Re-enter is the verified fence.
     * Never send another activate until this exact proxy's leave arrives. */
    h->ime.phase = IME_DEACTIVATING;
    zwp_text_input_v1_deactivate(h->ime.proxy, h->seat);
    zwp_text_input_v1_hide_input_panel(h->ime.proxy);
  }
}
static void ime_invalidate(struct host *h, int emit_leave, int deactivate) {
  if (!h->ime.requested && h->ime.phase != IME_ACTIVE &&
      h->ime.phase != IME_ACTIVATING)
    return;
  if (emit_leave && (h->ime.phase == IME_ACTIVE ||
                     h->ime.phase == IME_ACTIVATING) &&
      h->ime.wire_epoch == h->ime.epoch)
    (void)ime_lifecycle_record(h, 23);
  h->ime.requested = 0;
  (void)ime_advance_epoch(h);
  h->ime.serial_floor = 0;
  if (deactivate)
    ime_deactivate(h);
  else
    h->ime.phase = IME_INACTIVE;
}
static void ime_drop_proxy(struct host *h) {
  ime_invalidate(h, 1, 0);
  ime_clear_stage(h);
  h->ime.requested = 0;
  h->ime.phase = IME_INACTIVE;
  h->ime.serial_floor = 0;
  h->ime.modifiers_valid = 0;
  if (h->ime.proxy)
    zwp_text_input_v1_destroy(h->ime.proxy);
  h->ime.proxy = NULL;
}
static void ime_enter(void *data, struct zwp_text_input_v1 *proxy,
                      struct wl_surface *surface) {
  struct host *h = data;
  if (proxy != h->ime.proxy || !h->ime.proxy ||
      h->ime.phase != IME_ACTIVATING || !h->ime.requested ||
      surface != h->surface || !h->surface || h->state ||
      h->ime.wire_window != h->window ||
      h->ime.wire_seat != h->seat_name ||
      h->ime.wire_epoch != h->ime.epoch)
    return;
  h->ime.phase = IME_ACTIVE;
  (void)ime_lifecycle_record(h, 22);
}
static void ime_leave(void *data, struct zwp_text_input_v1 *proxy) {
  struct host *h = data;
  if (proxy != h->ime.proxy || !h->ime.proxy)
    return;
  if (h->ime.phase == IME_DEACTIVATING) {
    h->ime.phase = IME_INACTIVE;
    ime_clear_stage(h);
    if (h->ime.requested)
      (void)ime_activate(h);
  } else if (h->ime.phase == IME_ACTIVE || h->ime.phase == IME_ACTIVATING) {
    ime_invalidate(h, 1, 0);
  }
}
static void ime_modifiers_map(void *data, struct zwp_text_input_v1 *proxy,
                              struct wl_array *map) {
  struct host *h = data;
  if (proxy != h->ime.proxy || !h->ime.proxy ||
      (h->ime.phase != IME_ACTIVE && h->ime.phase != IME_ACTIVATING))
    return;
  h->ime.modifiers_valid = 0;
  h->ime.known_modifier_mask = 0;
  memset(h->ime.modifier_masks, 0, sizeof(h->ime.modifier_masks));
  if (!map || map->size > GPUI_IME_MAX_BYTES || (!map->data && map->size)) {
    (void)input_failure(h, GPUI_INVALID);
    return;
  }
  const char *names[4] = {"Shift", "Control", "Mod1", "Mod4"};
  size_t offset = 0;
  unsigned index = 0;
  while (offset < map->size) {
    const char *name = (const char *)map->data + offset;
    size_t remaining = map->size - offset;
    const char *end = memchr(name, 0, remaining);
    if (!end || index >= 32) {
      (void)input_failure(h, GPUI_INVALID);
      return;
    }
    uint32_t bit = UINT32_C(1) << index;
    h->ime.known_modifier_mask |= bit;
    for (int i = 0; i < 4; ++i)
      if (!strcmp(name, names[i]))
        h->ime.modifier_masks[i] |= bit;
    offset += (size_t)(end - name) + 1;
    ++index;
  }
  h->ime.modifiers_valid = 1;
}
static void ime_panel_state(void *data, struct zwp_text_input_v1 *proxy,
                            uint32_t state) {
  UNUSED(data); UNUSED(proxy); UNUSED(state);
}
static void ime_preedit_styling(void *data, struct zwp_text_input_v1 *proxy,
                               uint32_t index, uint32_t length, uint32_t style) {
  struct host *h = data;
  if (!ime_current(h, proxy))
    return;
  struct ime_payload *stage = &h->ime.stage;
  if (stage->style_count == GPUI_IME_MAX_STYLES ||
      index > GPUI_IME_MAX_BYTES || length > GPUI_IME_MAX_BYTES - index ||
      style > ZWP_TEXT_INPUT_V1_PREEDIT_STYLE_INCORRECT) {
    ime_clear_stage(h);
    (void)input_failure(h, GPUI_INVALID);
    return;
  }
  stage->styles[stage->style_count++] =
      (struct ime_style){(int)index, (int)length, (int)style};
}
static void ime_preedit_cursor(void *data, struct zwp_text_input_v1 *proxy,
                              int32_t index) {
  struct host *h = data;
  if (!ime_current(h, proxy))
    return;
  h->ime.stage.cursor_present = 1;
  h->ime.stage.cursor = index;
}
static int ime_payload_valid(const struct ime_payload *data) {
  if (data->kind < 20 || data->kind > 25 || data->window <= 0 ||
      data->epoch <= 0 || !data->seat || data->proxy_generation <= 0 ||
      data->text_length < 0 || data->text_length > GPUI_IME_MAX_BYTES ||
      data->fallback_length < 0 || data->fallback_length > GPUI_IME_MAX_BYTES ||
      data->style_count < 0 || data->style_count > GPUI_IME_MAX_STYLES ||
      (data->cursor_present != 0 && data->cursor_present != 1) ||
      (data->delete_present != 0 && data->delete_present != 1) ||
      (data->position_present != 0 && data->position_present != 1) ||
      (!data->cursor_present && data->cursor != 0) ||
      (!data->delete_present && (data->delete_index || data->delete_length)) ||
      (!data->position_present && (data->index || data->anchor)) ||
      !direct_utf8_valid(data->text, data->text_length) ||
      !direct_utf8_valid(data->fallback, data->fallback_length) ||
      memchr(data->text, 0, (size_t)data->text_length) ||
      memchr(data->fallback, 0, (size_t)data->fallback_length))
    return 0;
  if (data->kind == 22 || data->kind == 23)
    return data->serial == 0 && data->text_length == 0 &&
           data->fallback_length == 0 && !data->cursor_present &&
           !data->delete_present && !data->position_present && !data->style_count;
  if (data->serial <= 0)
    return 0;
  if (data->kind == 24 || data->kind == 25)
    return data->text_length == 0 && data->fallback_length == 0 &&
           !data->cursor_present && !data->delete_present &&
           !data->position_present && !data->style_count;
  if (data->kind == 21)
    return data->fallback_length == 0 && !data->cursor_present &&
           !data->style_count && data->delete_length >= 0 &&
           data->delete_length <= GPUI_IME_MAX_BYTES;
  if (data->delete_present || data->position_present ||
      (data->cursor_present && data->cursor >= 0 &&
       !ime_boundary(data->text, data->text_length, data->cursor)))
    return 0;
  for (int i = 0; i < data->style_count; ++i) {
    const struct ime_style *style = &data->styles[i];
    if (style->length < 0 || style->style < 0 || style->style > 7 ||
        style->index < 0 || style->index > data->text_length ||
        style->length > data->text_length - style->index ||
        !ime_boundary(data->text, data->text_length, style->index) ||
        !ime_boundary(data->text, data->text_length, style->index + style->length))
      return 0;
  }
  return 1;
}
static void ime_preedit_string(void *data, struct zwp_text_input_v1 *proxy,
                              uint32_t serial, const char *text,
                              const char *fallback) {
  struct host *h = data;
  if (proxy != h->ime.proxy || !h->ime.proxy)
    return;
  if (!ime_current(h, proxy) || !ime_serial_current(h, serial)) {
    ime_clear_preedit_stage(h);
    return;
  }
  struct ime_payload transaction = h->ime.stage;
  /* Commit staging is independent: a preedit must never consume deletion. */
  transaction.delete_present = transaction.delete_index = transaction.delete_length = 0;
  transaction.position_present = transaction.index = transaction.anchor = 0;
  transaction.kind = 20;
  transaction.serial = (int)serial;
  transaction.window = h->window;
  transaction.epoch = h->ime.wire_epoch;
  transaction.seat = h->ime.wire_seat;
  transaction.proxy_generation = h->ime.proxy_generation;
  int status = ime_copy_string(transaction.text, text, &transaction.text_length);
  if (!status)
    status = ime_copy_string(transaction.fallback, fallback, &transaction.fallback_length);
  ime_clear_preedit_stage(h);
  if (!status && !ime_payload_valid(&transaction))
    status = GPUI_INVALID;
  if (status)
    (void)input_failure(h, status);
  else
    (void)ime_record(h, &transaction);
}
static void ime_cursor_position(void *data, struct zwp_text_input_v1 *proxy,
                               int32_t index, int32_t anchor) {
  struct host *h = data;
  if (!ime_current(h, proxy))
    return;
  h->ime.stage.position_present = 1;
  h->ime.stage.index = index;
  h->ime.stage.anchor = anchor;
}
static void ime_delete_surrounding(void *data, struct zwp_text_input_v1 *proxy,
                                  int32_t index, uint32_t length) {
  struct host *h = data;
  if (!ime_current(h, proxy))
    return;
  if (length > GPUI_IME_MAX_BYTES || h->ime.stage.delete_present) {
    ime_clear_stage(h);
    (void)input_failure(h, GPUI_INVALID);
    return;
  }
  h->ime.stage.delete_present = 1;
  h->ime.stage.delete_index = index;
  h->ime.stage.delete_length = (int)length;
}
static void ime_commit_string(void *data, struct zwp_text_input_v1 *proxy,
                             uint32_t serial, const char *text) {
  struct host *h = data;
  if (proxy != h->ime.proxy || !h->ime.proxy)
    return;
  if (!ime_current(h, proxy) || !ime_serial_current(h, serial)) {
    ime_clear_commit_stage(h);
    return;
  }
  struct ime_payload transaction = h->ime.stage;
  transaction.cursor_present = transaction.cursor = 0;
  transaction.style_count = 0;
  memset(transaction.styles, 0, sizeof(transaction.styles));
  transaction.kind = 21;
  transaction.serial = (int)serial;
  transaction.window = h->window;
  transaction.epoch = h->ime.wire_epoch;
  transaction.seat = h->ime.wire_seat;
  transaction.proxy_generation = h->ime.proxy_generation;
  int status = ime_copy_string(transaction.text, text, &transaction.text_length);
  ime_clear_commit_stage(h);
  if (!status && !ime_payload_valid(&transaction))
    status = GPUI_INVALID;
  if (status)
    (void)input_failure(h, status);
  else
    (void)ime_record(h, &transaction);
}
static void ime_raw_keyboard_key(struct host *h, uint32_t state,
                                  xkb_keysym_t symbol) {
  if (!h->ime.requested || h->ime.exhausted || h->state || h->error ||
      !h->keyboard_focus_current || !h->ime.proxy || !h->window ||
      !h->seat_name || (h->ime.phase != IME_ACTIVE &&
                       h->ime.phase != IME_ACTIVATING) ||
      h->ime.wire_epoch != h->ime.epoch ||
      h->ime.wire_window != h->window || h->ime.wire_seat != h->seat_name)
    return;
  if (state > WL_KEYBOARD_KEY_STATE_PRESSED || symbol > 0x1fffffff ||
      h->modifiers < 0 || h->modifiers > 15) {
    (void)input_failure(h, GPUI_INVALID);
    return;
  }
  struct ime_payload transaction = {0};
  transaction.kind = state == WL_KEYBOARD_KEY_STATE_PRESSED ? 24 : 25;
  transaction.serial = h->ime.latest_serial;
  int slot = (h->read + h->count) % QUEUE_CAPACITY;
  if (!ime_record(h, &transaction)) {
    h->queue[slot][8] = symbol;
    h->queue[slot][9] = h->modifiers;
  }
}
static void ime_keysym(void *data, struct zwp_text_input_v1 *proxy,
                       uint32_t serial, uint32_t time, uint32_t symbol,
                       uint32_t state, uint32_t modifiers) {
  UNUSED(time);
  struct host *h = data;
  if (!ime_current(h, proxy) || !ime_serial_current(h, serial))
    return;
  if (!h->ime.modifiers_valid || (modifiers & ~h->ime.known_modifier_mask) ||
      symbol > 0x1fffffff || state > WL_KEYBOARD_KEY_STATE_PRESSED) {
    (void)input_failure(h, GPUI_INVALID);
    return;
  }
  struct ime_payload transaction = {0};
  transaction.kind = state == WL_KEYBOARD_KEY_STATE_PRESSED ? 24 : 25;
  transaction.serial = (int)serial;
  int slot = (h->read + h->count) % QUEUE_CAPACITY;
  int status = ime_record(h, &transaction);
  if (status)
    return;
  h->queue[slot][8] = symbol;
  int bits = 0;
  for (int i = 0; i < 4; ++i)
    if (modifiers & h->ime.modifier_masks[i])
      bits |= 1 << i;
  h->queue[slot][9] = bits;
}
static void ime_language(void *data, struct zwp_text_input_v1 *proxy,
                         uint32_t serial, const char *language) {
  UNUSED(data); UNUSED(proxy); UNUSED(serial); UNUSED(language);
}
static void ime_direction(void *data, struct zwp_text_input_v1 *proxy,
                          uint32_t serial, uint32_t direction) {
  UNUSED(data); UNUSED(proxy); UNUSED(serial); UNUSED(direction);
}
static const struct zwp_text_input_v1_listener ime_listener = {
  .enter = ime_enter, .leave = ime_leave, .modifiers_map = ime_modifiers_map,
  .input_panel_state = ime_panel_state, .preedit_string = ime_preedit_string,
  .preedit_styling = ime_preedit_styling, .preedit_cursor = ime_preedit_cursor,
  .commit_string = ime_commit_string, .cursor_position = ime_cursor_position,
  .delete_surrounding_text = ime_delete_surrounding, .keysym = ime_keysym,
  .language = ime_language, .text_direction = ime_direction
};
static int ime_require_proxy(struct host *h) {
  if (!h->ime.manager || !h->ime.manager_name || !h->seat || !h->seat_name ||
      !h->keyboard || !h->surface || !h->keyboard_focus_current)
    return GPUI_UNSUPPORTED;
  if (h->ime.exhausted)
    return GPUI_RESOURCE;
  if (!h->ime.proxy) {
    if (h->ime.proxy_generation == INT_MAX) {
      h->ime.exhausted = 1;
      return GPUI_RESOURCE;
    }
    h->ime.proxy = zwp_text_input_manager_v1_create_text_input(h->ime.manager);
    if (!h->ime.proxy)
      return GPUI_RESOURCE;
    ++h->ime.proxy_generation;
    if (zwp_text_input_v1_add_listener(h->ime.proxy, &ime_listener, h) < 0) {
      zwp_text_input_v1_destroy(h->ime.proxy);
      h->ime.proxy = NULL;
      return GPUI_NATIVE;
    }
  }
  return GPUI_OK;
}
static int ime_document_valid(const uint8_t *text, int length, int cursor,
                              int anchor, int width, int height) {
  return length >= 0 && length <= GPUI_IME_MAX_BYTES &&
         (text || length == 0) && width > 0 && height > 0 &&
         (length == 0 || !memchr(text, 0, (size_t)length)) &&
         direct_utf8_valid(text, length) &&
         ime_boundary(text, length, cursor) && ime_boundary(text, length, anchor);
}
static void ime_set_document(struct host *h, const uint8_t *text, int length,
                             int cursor, int anchor, int x, int y,
                             int width, int height) {
  if (length)
    memmove(h->ime.document, text, (size_t)length);
  h->ime.document[length] = 0;
  h->ime.document_length = length;
  h->ime.cursor = cursor;
  h->ime.anchor = anchor;
  h->ime.rect[0] = x; h->ime.rect[1] = y;
  h->ime.rect[2] = width; h->ime.rect[3] = height;
}
int32_t gpui_text_session_begin(int32_t token, int32_t window,
    const uint8_t *text, int32_t length, int32_t cursor, int32_t anchor,
    int32_t x, int32_t y, int32_t width, int32_t height) {
  struct host *h;
  int status = window_check(token, window, &h);
  if (status)
    return -status;
  if (h->state)
    return -GPUI_STOPPING;
  if (h->error)
    return -h->error;
  if (!ime_document_valid(text, length, cursor, anchor, width, height))
    return -GPUI_INVALID;
  if (h->ime.requested || h->direct_enabled)
    return -GPUI_BUSY;
  status = ime_require_proxy(h);
  if (status)
    return -status;
  status = ime_advance_epoch(h);
  if (status)
    return -status;
  ime_set_document(h, text, length, cursor, anchor, x, y, width, height);
  h->ime.requested = h->ime.ever_enabled = 1;
  h->ime.panel_requested = 1;
  status = ime_activate(h);
  return status ? -status : h->ime.epoch;
}
static int ime_session_check(int token, int window, int epoch, struct host **out) {
  int status = window_check(token, window, out);
  if (status)
    return status;
  if ((*out)->ime.exhausted)
    return GPUI_RESOURCE;
  if ((*out)->state)
    return GPUI_STOPPING;
  if ((*out)->error)
    return (*out)->error;
  return epoch > 0 && (*out)->ime.requested && epoch == (*out)->ime.epoch
             ? GPUI_OK : GPUI_STALE;
}
int32_t gpui_text_session_update(int32_t token, int32_t window, int32_t epoch,
    const uint8_t *text, int32_t length, int32_t cursor, int32_t anchor,
    int32_t x, int32_t y, int32_t width, int32_t height, int32_t external_edit) {
  struct host *h;
  int status = ime_session_check(token, window, epoch, &h);
  if (status)
    return -status;
  if ((external_edit != 0 && external_edit != 1) ||
      !ime_document_valid(text, length, cursor, anchor, width, height))
    return -GPUI_INVALID;
  if (h->ime.latest_serial == INT_MAX ||
      (external_edit && h->ime.epoch == INT_MAX)) {
    h->ime.exhausted = 1;
    h->ime.requested = 0;
    h->ime.serial_floor = 0;
    ime_clear_stage(h);
    ime_deactivate(h);
    return -GPUI_RESOURCE;
  }
  if (external_edit) {
    if ((h->ime.phase == IME_ACTIVE || h->ime.phase == IME_ACTIVATING) &&
        h->ime.wire_epoch == h->ime.epoch) {
      status = ime_lifecycle_record(h, 23);
      if (status)
        return -status;
    }
    status = ime_advance_epoch(h);
    h->ime.serial_floor = 0;
    ime_deactivate(h);
  }
  if (status)
    return -status;
  ime_set_document(h, text, length, cursor, anchor, x, y, width, height);
  if (h->ime.phase == IME_ACTIVE || h->ime.phase == IME_ACTIVATING)
    status = ime_send_state(h);
  else if (h->ime.phase == IME_INACTIVE)
    status = ime_activate(h);
  return status ? -status : h->ime.epoch;
}
int32_t gpui_text_session_cancel(int32_t token, int32_t window, int32_t epoch) {
  struct host *h;
  int status = ime_session_check(token, window, epoch, &h);
  if (status)
    return -status;
  return gpui_text_session_update(token, window, epoch, h->ime.document,
      h->ime.document_length, h->ime.cursor, h->ime.anchor, h->ime.rect[0],
      h->ime.rect[1], h->ime.rect[2], h->ime.rect[3], 1);
}
int32_t gpui_text_session_end(int32_t token, int32_t window, int32_t epoch) {
  struct host *h;
  int status = ime_session_check(token, window, epoch, &h);
  if (status)
    return status;
  ime_invalidate(h, 1, 1);
  return h->ime.exhausted ? GPUI_RESOURCE : h->error;
}
/* Reader implementation is placed after ABI2 consume helpers below. */
int32_t gpui_text_session_panel(int32_t token, int32_t window, int32_t epoch,
                                int32_t visible) {
  struct host *h;
  int status = ime_session_check(token, window, epoch, &h);
  if (status)
    return status;
  if (visible != 0 && visible != 1)
    return GPUI_INVALID;
  h->ime.panel_requested = visible;
  if (h->ime.phase == IME_ACTIVE || h->ime.phase == IME_ACTIVATING) {
    if (visible)
      zwp_text_input_v1_show_input_panel(h->ime.proxy);
    else
      zwp_text_input_v1_hide_input_panel(h->ime.proxy);
  }
  return GPUI_OK;
}
