#ifndef GPUI_IME_TRANSPORT_PRIVATE_H
#define GPUI_IME_TRANSPORT_PRIVATE_H
/* Private state, bounded copies only. No caller/protocol string is retained. */
struct ime_style { int index, length, style; };
struct ime_payload {
  int kind, window, epoch, proxy_generation, serial;
  uint32_t seat;
  int text_length, fallback_length, cursor_present, cursor;
  int delete_present, delete_index, delete_length;
  int position_present, index, anchor, style_count;
  struct ime_style styles[GPUI_IME_MAX_STYLES];
  uint8_t text[GPUI_IME_MAX_BYTES + 1];
  uint8_t fallback[GPUI_IME_MAX_BYTES + 1];
};
enum ime_phase { IME_INACTIVE, IME_ACTIVATING, IME_ACTIVE, IME_DEACTIVATING };
struct ime_state {
  struct zwp_text_input_manager_v1 *manager;
  struct zwp_text_input_v1 *proxy;
  uint32_t manager_name;
  int proxy_generation, epoch, exhausted, requested, ever_enabled;
  int phase, wire_epoch, wire_window, panel_requested;
  uint32_t wire_seat;
  int latest_serial, serial_floor;
  int document_length, cursor, anchor, rect[4];
  uint8_t document[GPUI_IME_MAX_BYTES + 1];
  struct ime_payload stage;
  uint32_t modifier_masks[4], known_modifier_mask;
  int modifiers_valid;
};
#endif
