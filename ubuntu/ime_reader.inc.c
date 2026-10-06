static int ime_queued_valid(const struct host *h, int slot) {
  const struct ime_payload *data = h->ime_queue[slot];
  const double *event_data = h->queue[slot];
  if (!data || !ime_payload_valid(data) || event_data[0] != data->kind ||
      event_data[1] != data->window || !isfinite(event_data[2]) ||
      event_data[2] < 1 ||
      event_data[2] > INT_MAX || event_data[2] != (int)event_data[2] ||
      !isfinite(event_data[3]) || event_data[3] <= 0 ||
      event_data[4] != 0 || event_data[5] != 0 ||
      event_data[6] != 0 || event_data[7] != 0 ||
      !isfinite(event_data[9]) || event_data[9] < 0 || event_data[9] > 15 ||
      event_data[9] != (int)event_data[9])
    return 0;
  if (data->kind == 24 || data->kind == 25)
    return isfinite(event_data[8]) && event_data[8] >= 0 &&
           event_data[8] <= 0x1fffffff &&
           event_data[8] == (int)event_data[8];
  return event_data[8] == 0 && event_data[9] == 0;
}
static int ime_queued_stale(const struct host *h, int slot) {
  const struct ime_payload *data = h->ime_queue[slot];
  /* Left is cancellation of the captured target, deliberately deliverable
   * before blur and after the epoch advances. Consumer still checks target. */
  if (data->kind == 23)
    return 0;
  return !h->ime.requested || h->ime.exhausted || h->state ||
         data->epoch != h->ime.epoch || data->window != h->window ||
         data->seat != h->seat_name ||
         data->proxy_generation != h->ime.proxy_generation ||
         (data->kind != 22 && !ime_serial_current((struct host *)h,
                                                (uint32_t)data->serial));
}
static int editor_exact_int(double value, int low, int high) {
  return isfinite(value) && value >= low && value <= high && value == (int)value;
}
static int editor_ordinary_valid(const struct host *h, int slot) {
  const double *data = h->queue[slot];
  if (!editor_exact_int(data[0], 1, 13) ||
      !editor_exact_int(data[1], 1, INT_MAX) ||
      !editor_exact_int(data[2], 1, INT_MAX) ||
      !isfinite(data[3]) || data[3] <= 0 ||
      !editor_exact_int(data[9], 0, 15))
    return 0;
  int kind = (int)data[0];
  if (kind == 11 || kind == 12)
    return editor_exact_int(data[6], 0, 0x10ffff) &&
        !(data[6] >= 0xd800 && data[6] <= 0xdfff) &&
        editor_exact_int(data[8], 0, 0x1fffffff) &&
        editor_exact_int(data[7], 0, kind == 11 ? 1 : 0);
  if (kind == 13) {
    const struct direct_event_meta *direct = &h->direct_queue[slot];
    return direct->text_length > 0 && direct->text_length <= GPUI_DIRECT_TEXT_MAX_BYTES &&
        data[8] == direct->text_length && !data[6] && !data[7] &&
        direct_utf8_valid(direct->text, direct->text_length);
  }
  if (!editor_exact_int(data[8], 0, INT_MAX))
    return 0;
  if (kind == 1)
    return isfinite(data[4]) && isfinite(data[5]);
  if (kind >= 7 && kind <= 10)
    return isfinite(data[6]) && isfinite(data[7]) &&
           (kind != 10 || isfinite(data[4]));
  return 1;
}
int32_t gpui_next_editor(int32_t abi, int32_t token, double *out,
                         int32_t out_capacity, uint8_t *text,
                         int32_t text_capacity) {
  if (abi != GPUI_EDITOR_ABI)
    return -GPUI_UNSUPPORTED;
  if (!out || out_capacity < 0 || text_capacity < 0 ||
      (!text && text_capacity > 0))
    return -GPUI_INVALID;
  if (out_capacity < GPUI_EDITOR_EVENT_FIELDS)
    return -GPUI_RESOURCE;
  struct host *h;
  int status = check(token, &h);
  if (status)
    return -status;
  if ((h->ime.exhausted && h->ime.ever_enabled) ||
      (h->direct_exhausted && h->direct_ever_enabled))
    return -GPUI_RESOURCE;
  int skipped = 0;
  while (skipped < h->count) {
    int slot = (h->read + skipped) % QUEUE_CAPACITY;
    if (h->ime_queue[slot] || h->queue[slot][0] >= 20) {
      if (!ime_queued_valid(h, slot))
        return -GPUI_INVALID;
      if (!ime_queued_stale(h, slot))
        break;
    } else {
      if (!editor_ordinary_valid(h, slot))
        return -GPUI_INVALID;
      if (!stale_direct_record(h, slot))
        break;
    }
    ++skipped;
  }
  if (skipped == h->count) {
    while (h->count)
      consume_event(h);
    return 0;
  }
  int slot = (h->read + skipped) % QUEUE_CAPACITY;
  const struct ime_payload *data = h->ime_queue[slot];
  const struct direct_event_meta *direct = &h->direct_queue[slot];
  int required = data ? data->text_length + data->fallback_length :
                 h->queue[slot][0] == 13 ? direct->text_length : 0;
  if (!data && h->queue[slot][0] == 13 &&
      (direct->text_length <= 0 || direct->text_length > GPUI_DIRECT_TEXT_MAX_BYTES ||
       h->queue[slot][8] != direct->text_length ||
       !direct_utf8_valid(direct->text, direct->text_length)))
    return -GPUI_INVALID;
  if (text_capacity < required)
    return -GPUI_RESOURCE;
  double encoded[GPUI_EDITOR_EVENT_FIELDS] = {0};
  memcpy(encoded, h->queue[slot], sizeof(h->queue[slot]));
  if (data) {
    encoded[10] = data->epoch; encoded[11] = data->seat;
    encoded[12] = data->proxy_generation; encoded[13] = data->serial;
    encoded[14] = data->text_length; encoded[15] = data->fallback_length;
    encoded[16] = data->cursor_present; encoded[17] = data->cursor;
    encoded[18] = data->delete_present; encoded[19] = data->delete_index;
    encoded[20] = data->delete_length; encoded[21] = data->position_present;
    encoded[22] = data->index; encoded[23] = data->anchor;
    encoded[24] = data->style_count;
    for (int i = 0; i < data->style_count; ++i) {
      encoded[25 + 3 * i] = data->styles[i].index;
      encoded[26 + 3 * i] = data->styles[i].length;
      encoded[27 + 3 * i] = data->styles[i].style;
    }
  }
  /* No output write occurs before complete admission, including stale prefix. */
  memcpy(out, encoded, sizeof(encoded));
  if (data) {
    if (data->text_length)
      memcpy(text, data->text, (size_t)data->text_length);
    if (data->fallback_length)
      memcpy(text + data->text_length, data->fallback,
             (size_t)data->fallback_length);
  } else if (required) {
    memcpy(text, direct->text, (size_t)required);
  }
  for (int i = 0; i <= skipped; ++i)
    consume_event(h);
  return 1;
}
