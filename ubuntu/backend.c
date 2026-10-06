#define _POSIX_C_SOURCE 200809L
#include "backend.h"
#include "../platform/linux_text/linux_text.h"
#include "xdg-shell-client-protocol.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-cursor.h>
#include <wayland-egl.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>

#define QUEUE_CAPACITY 1024
#define OUTPUT_CAPACITY 16
#define CLIPBOARD_LIMIT (16 * 1024 * 1024)
#define CLIPBOARD_TIMEOUT_MS 3000
#define SOURCE_TRANSFER_CAPACITY 8
#define UNUSED(x) (void)(x)
struct host;
struct clipboard_source {
  struct host *host;
  struct wl_data_source *proxy;
  uint8_t *bytes;
  size_t length, transfers;
  int cancelled;
  struct clipboard_source *next;
};
struct source_transfer {
  struct clipboard_source *source;
  int fd;
  size_t offset;
};
struct output {
  struct wl_output *proxy;
  uint32_t name;
  int scale, entered;
};
struct direct_event_meta {
  int epoch, direct_origin, text_length;
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES + 1];
};
struct direct_key_state {
  int epoch, direct_origin, swallowed, pressed;
};
enum input_serial_origin {
  INPUT_SERIAL_NONE,
  INPUT_SERIAL_POINTER,
  INPUT_SERIAL_KEYBOARD
};
struct host {
  int token, window, state, wake_fd, error;
  pthread_t owner;
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_compositor *compositor;
  struct xdg_wm_base *shell;
  struct wl_shm *shm;
  struct wl_data_device_manager *data_manager;
  struct wl_data_device *data_device;
  struct wl_data_offer *selection_offer, *pending_offer;
  uint32_t compositor_name, shell_name, shm_name, data_manager_name;
  uint32_t seat_name;
  struct wl_seat *seat;
  struct wl_pointer *pointer;
  struct wl_keyboard *keyboard;
  uint32_t pointer_serial, input_serial;
  int input_serial_window;
  enum input_serial_origin input_serial_origin;
  int pointer_inside, pointer_focus_current, keyboard_focus_current;
  struct wl_cursor_theme *cursor_theme;
  struct wl_cursor *cursors[3];
  struct wl_surface *cursor_surface;
  int cursor_kind, cursor_scale;
  int clipboard_has_utf8, clipboard_has_plain;
  int pending_has_utf8, pending_has_plain;
  uint8_t *clipboard_result;
  size_t clipboard_result_length;
  struct clipboard_source *sources;
  struct source_transfer transfers[SOURCE_TRANSFER_CAPACITY];
  struct xkb_context *xkb;
  struct xkb_keymap *keymap;
  struct xkb_state *keys;
  struct xkb_compose_table *compose_table;
  struct xkb_compose_state *compose;
  int compose_attempted, direct_keymap_valid;
  int direct_enabled, direct_epoch, direct_exhausted, direct_ever_enabled;
  struct output outputs[OUTPUT_CAPACITY];
  struct wl_surface *surface;
  struct xdg_surface *xdg;
  struct xdg_toplevel *toplevel;
  struct wl_callback *frame;
  struct wl_egl_window *egl_window;
  EGLDisplay egl;
  EGLContext context;
  EGLSurface egl_surface;
  EGLConfig config;
  GLuint program, mask_program;
  GLint color_uniform, mask_color_uniform, mask_sampler_uniform;
  int width, height, pending_width, pending_height, scale, configured, seq;
  double px, py;
  int modifiers;
  double queue[QUEUE_CAPACITY][10];
  struct direct_event_meta direct_queue[QUEUE_CAPACITY];
  struct direct_key_state direct_keys[GPUI_DIRECT_KEY_CAPACITY];
  int read, count;
};
static struct host *active;
static pthread_mutex_t registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static int next_host = 1;
static int next_window = 1;
static void flush_transfers(struct host *h);
static void collect_source(struct clipboard_source *source);
static void remember_input_serial(struct host *h, uint32_t serial,
                                  enum input_serial_origin origin) {
  int focused = origin == INPUT_SERIAL_POINTER
                    ? h->pointer_focus_current
                    : (origin == INPUT_SERIAL_KEYBOARD
                           ? h->keyboard_focus_current
                           : 0);
  if (!serial || !focused || !h->seat_name)
    return;
  h->input_serial = serial;
  h->input_serial_window = h->window;
  h->input_serial_origin = origin;
}
static void invalidate_input_serial(struct host *h,
                                    enum input_serial_origin origin) {
  if (origin == INPUT_SERIAL_NONE || h->input_serial_origin == origin) {
    h->input_serial = 0;
    h->input_serial_window = 0;
    h->input_serial_origin = INPUT_SERIAL_NONE;
  }
}
static int has_input_serial(const struct host *h) {
  return h->seat_name && h->window && h->input_serial &&
         h->input_serial_window == h->window &&
         ((h->input_serial_origin == INPUT_SERIAL_POINTER &&
           h->pointer_focus_current) ||
          (h->input_serial_origin == INPUT_SERIAL_KEYBOARD &&
           h->keyboard_focus_current));
}
static int valid_size(int w, int h, int scale) {
  return w > 0 && h > 0 && scale > 0 && w <= 16384 / scale &&
         h <= 16384 / scale;
}
static int check(int token, struct host **out) {
  /* Wrong-thread callers never acquire a native object that can be torn down.
   * The UI owner serializes operations; this lock only protects registry reads
   * from simultaneous startup/stop attempts on other threads. */
  pthread_mutex_lock(&registry_mutex);
  int status = GPUI_OK;
  if (!active || active->token != token)
    status = GPUI_STALE;
  else if (!pthread_equal(active->owner, pthread_self()))
    status = GPUI_WRONG_THREAD;
  else
    *out = active;
  pthread_mutex_unlock(&registry_mutex);
  return status;
}
static int window_check(int token, int window, struct host **out) {
  int s = check(token, out);
  if (s)
    return s;
  return (*out)->window && (*out)->window == window ? GPUI_OK : GPUI_STALE;
}
static void event(struct host *h, int kind, double detail, double x, double y) {
  if (!h->window)
    return;
  if (h->count == QUEUE_CAPACITY || h->seq == INT_MAX) {
    h->error = GPUI_RESOURCE;
    return;
  }
  int slot = (h->read + h->count++) % QUEUE_CAPACITY;
  double *e = h->queue[slot];
  memset(&h->direct_queue[slot], 0, sizeof(h->direct_queue[slot]));
  e[0] = kind;
  e[1] = h->window;
  e[2] = ++h->seq;
  e[3] = h->scale;
  e[4] = h->width;
  e[5] = h->height;
  e[6] = x;
  e[7] = y;
  e[8] = detail;
  e[9] = h->modifiers;
}
static void reset_compose(struct host *h) {
  if (h->compose)
    xkb_compose_state_reset(h->compose);
}
/* A target generation is never reused, including on resource exhaustion. */
static int advance_direct_epoch(struct host *h) {
  reset_compose(h);
  if (h->direct_exhausted || h->direct_epoch == INT_MAX) {
    h->direct_exhausted = 1;
    h->direct_enabled = 0;
    return GPUI_RESOURCE;
  }
  ++h->direct_epoch;
  return GPUI_OK;
}
static void reset_direct_text(struct host *h, int disable, int clear_device) {
  /* The same physical keyboard's consumed releases survive focus/keymap
   * resets. Removing that keyboard excludes old callbacks before clearing. */
  if (clear_device)
    memset(h->direct_keys, 0, sizeof(h->direct_keys));
  if (disable)
    h->direct_enabled = 0;
  (void)advance_direct_epoch(h);
}
static void quiesce_host(struct host *h) {
  /* All transitions out of Running revoke the editor target exactly once.
   * Repeated exit/error handling must not consume more generations. */
  if (h->state == 0 || h->direct_enabled)
    reset_direct_text(h, 1, 0);
  h->state = 1;
}
static void release_compose(struct host *h) {
  xkb_compose_state_unref(h->compose);
  xkb_compose_table_unref(h->compose_table);
  h->compose = NULL;
  h->compose_table = NULL;
  h->compose_attempted = 0;
}
static int require_direct_keyboard(struct host *h) {
  if (h->direct_exhausted)
    return GPUI_RESOURCE;
  if (h->state != 0)
    return GPUI_STOPPING;
  if (!h->seat_name || !h->keyboard || !h->direct_keymap_valid ||
      !h->keymap || !h->keys || !h->xkb ||
      xkb_keymap_max_keycode(h->keymap) >= GPUI_DIRECT_KEY_CAPACITY + 8)
    return GPUI_UNSUPPORTED;
  if (!h->compose_table && !h->compose_attempted) {
    const char *locale = getenv("LC_ALL");
    if (!locale || !*locale)
      locale = getenv("LC_CTYPE");
    if (!locale || !*locale)
      locale = getenv("LANG");
    if (!locale || !*locale)
      locale = "C";
    h->compose_attempted = 1;
    h->compose_table = xkb_compose_table_new_from_locale(
        h->xkb, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
  }
  if (!h->compose_table)
    return GPUI_UNSUPPORTED;
  if (!h->compose) {
    h->compose = xkb_compose_state_new(h->compose_table,
                                      XKB_COMPOSE_STATE_NO_FLAGS);
    if (!h->compose)
      return GPUI_RESOURCE;
  }
  return GPUI_OK;
}
/* Strict UTF8, independent of text-field policy. The producer omits action
 * controls as text, while the reusable field validates all committed inputs. */
static int direct_utf8_valid(const uint8_t *text, int length) {
  int i = 0;
  while (i < length) {
    uint32_t value;
    int count;
    uint8_t first = text[i];
    if (first < 0x80) {
      value = first;
      count = 1;
    } else if (first >= 0xc2 && first <= 0xdf) {
      value = first & 0x1f;
      count = 2;
    } else if (first >= 0xe0 && first <= 0xef) {
      value = first & 0x0f;
      count = 3;
    } else if (first >= 0xf0 && first <= 0xf4) {
      value = first & 0x07;
      count = 4;
    } else {
      return 0;
    }
    if (count > length - i)
      return 0;
    for (int j = 1; j < count; ++j) {
      uint8_t next = text[i + j];
      if ((next & 0xc0) != 0x80)
        return 0;
      value = (value << 6) | (next & 0x3f);
    }
    if ((count == 2 && value < 0x80) ||
        (count == 3 && value < 0x800) ||
        (count == 4 && value < 0x10000) || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff))
      return 0;
    i += count;
  }
  return 1;
}
static int direct_has_control(const uint8_t *text, int length) {
  for (int i = 0; i < length; ++i) {
    if (text[i] < 0x20 || text[i] == 0x7f)
      return 1;
    if (text[i] == 0xc2 && i + 1 < length &&
        text[i + 1] >= 0x80 && text[i + 1] <= 0x9f)
      return 1;
    if (text[i] == 0xe2 && i + 2 < length && text[i + 1] == 0x80 &&
        (text[i + 2] == 0xa8 || text[i + 2] == 0xa9))
      return 1;
  }
  return 0;
}
static void direct_key_record(struct host *h, int kind, xkb_keysym_t sym,
                               uint32_t scalar, int epoch, int origin) {
  int slot = (h->read + h->count) % QUEUE_CAPACITY;
  int prior = h->count;
  event(h, kind, sym, scalar, 0);
  if (h->count != prior) {
    h->direct_queue[slot].epoch = epoch;
    h->direct_queue[slot].direct_origin = origin;
  }
}
static void direct_text_record(struct host *h, const uint8_t *text, int length) {
  int slot = (h->read + h->count) % QUEUE_CAPACITY;
  int prior = h->count;
  event(h, 13, length, 0, 0);
  if (h->count != prior) {
    struct direct_event_meta *meta = &h->direct_queue[slot];
    meta->epoch = h->direct_epoch;
    meta->direct_origin = 1;
    meta->text_length = length;
    memcpy(meta->text, text, (size_t)length);
    meta->text[length] = 0;
  }
}
static void direct_keyboard_key(struct host *h, uint32_t key, uint32_t state,
                                 xkb_keysym_t sym) {
  struct direct_key_state *pressed = key < GPUI_DIRECT_KEY_CAPACITY
                                         ? &h->direct_keys[key]
                                         : NULL;
  uint32_t scalar = xkb_keysym_to_utf32(sym);
  if (h->state != 0 && h->direct_ever_enabled) {
    if (pressed && state == WL_KEYBOARD_KEY_STATE_RELEASED)
      memset(pressed, 0, sizeof(*pressed));
    return;
  }
  if (h->direct_exhausted && h->direct_ever_enabled) {
    if (pressed && state == WL_KEYBOARD_KEY_STATE_RELEASED)
      memset(pressed, 0, sizeof(*pressed));
    h->error = GPUI_RESOURCE;
    return;
  }
  if (state == WL_KEYBOARD_KEY_STATE_RELEASED) {
    int epoch = pressed && pressed->pressed ? pressed->epoch : 0;
    int origin = pressed && pressed->pressed ? pressed->direct_origin : 0;
    int swallowed = pressed && pressed->swallowed;
    if (pressed)
      memset(pressed, 0, sizeof(*pressed));
    if (!swallowed)
      direct_key_record(h, 12, sym, scalar, epoch, origin);
    return;
  }
  if (pressed) {
    pressed->pressed = 1;
    pressed->epoch = h->direct_epoch;
    pressed->direct_origin = h->direct_enabled;
    pressed->swallowed = 0;
  }
  if (!h->direct_enabled) {
    direct_key_record(h, 11, sym, scalar, h->direct_epoch, 0);
    return;
  }
  if (!h->keyboard_focus_current)
    return;
  if (!pressed || state != WL_KEYBOARD_KEY_STATE_PRESSED) {
    h->error = GPUI_INVALID;
    return;
  }
  int admission = require_direct_keyboard(h);
  if (admission != GPUI_OK) {
    h->error = admission;
    return;
  }
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES + 1];
  int length = 0;
  int emit_key = 1;
  if (h->modifiers & (2 | 8)) {
    reset_compose(h);
  } else {
    enum xkb_compose_feed_result feed = xkb_compose_state_feed(h->compose, sym);
    enum xkb_compose_status status = xkb_compose_state_get_status(h->compose);
    if (feed == XKB_COMPOSE_FEED_ACCEPTED &&
        status != XKB_COMPOSE_NOTHING) {
      emit_key = 0;
      pressed->swallowed = 1;
      if (status == XKB_COMPOSE_COMPOSED) {
        length = xkb_compose_state_get_utf8(h->compose, (char *)text,
                                           sizeof(text));
        reset_compose(h);
      } else if (status == XKB_COMPOSE_CANCELLED) {
        reset_compose(h);
      }
    } else {
      length = xkb_state_key_get_utf8(h->keys, key + 8, (char *)text,
                                      sizeof(text));
    }
  }
  if (length < 0 || length > GPUI_DIRECT_TEXT_MAX_BYTES) {
    h->error = GPUI_RESOURCE;
    return;
  }
  if (!direct_utf8_valid(text, length)) {
    h->error = GPUI_INVALID;
    return;
  }
  if (direct_has_control(text, length))
    length = 0;
  int records = emit_key + (length > 0);
  if (records > QUEUE_CAPACITY - h->count || records > INT_MAX - h->seq) {
    h->error = GPUI_RESOURCE;
    return;
  }
  if (emit_key)
    direct_key_record(h, 11, sym, scalar, h->direct_epoch, 1);
  if (length > 0)
    direct_text_record(h, text, length);
}
static ssize_t write_without_sigpipe(int fd, const void *bytes, size_t length) {
  sigset_t blocked, old_mask, pending;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  if (pthread_sigmask(SIG_BLOCK, &blocked, &old_mask) != 0) {
    errno = EINVAL;
    return -1;
  }
  int had_pending = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE);
  ssize_t written = write(fd, bytes, length);
  int saved_errno = errno;
  if (written < 0 && saved_errno == EPIPE && !had_pending) {
    struct timespec zero = {0, 0};
    while (sigtimedwait(&blocked, NULL, &zero) < 0 && errno == EINTR) {
    }
  }
  pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
  errno = saved_errno;
  return written;
}
static void finish_transfer(struct source_transfer *transfer) {
  struct clipboard_source *source = transfer->source;
  if (transfer->fd >= 0)
    close(transfer->fd);
  transfer->fd = -1;
  transfer->offset = 0;
  transfer->source = NULL;
  if (source) {
    if (source->transfers)
      --source->transfers;
    collect_source(source);
  }
}
static void flush_transfer(struct source_transfer *transfer) {
  struct clipboard_source *source = transfer->source;
  if (!source || transfer->fd < 0)
    return;
  while (transfer->offset < source->length) {
    ssize_t count = write_without_sigpipe(
        transfer->fd, source->bytes + transfer->offset,
        source->length - transfer->offset);
    if (count > 0) {
      transfer->offset += (size_t)count;
      continue;
    }
    if (count < 0 && (errno == EINTR))
      continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return;
    finish_transfer(transfer);
    return;
  }
  finish_transfer(transfer);
}
static void flush_transfers(struct host *h) {
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    if (h->transfers[i].fd >= 0)
      flush_transfer(&h->transfers[i]);
}
static void unlink_source(struct clipboard_source *source) {
  struct clipboard_source **item = &source->host->sources;
  while (*item && *item != source)
    item = &(*item)->next;
  if (*item == source)
    *item = source->next;
  free(source->bytes);
  free(source);
}
static void collect_source(struct clipboard_source *source) {
  if (source->cancelled && source->transfers == 0)
    unlink_source(source);
}
static void source_target(void *d, struct wl_data_source *proxy,
                          const char *mime) {
  UNUSED(d);
  UNUSED(proxy);
  UNUSED(mime);
}
static void source_send(void *d, struct wl_data_source *proxy, const char *mime,
                        int32_t fd) {
  UNUSED(proxy);
  struct clipboard_source *source = d;
  if (!source || source->cancelled ||
      (strcmp(mime, "text/plain;charset=utf-8") &&
       strcmp(mime, "text/plain"))) {
    close(fd);
    return;
  }
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    close(fd);
    return;
  }
  struct source_transfer *transfer = NULL;
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    if (source->host->transfers[i].fd < 0) {
      transfer = &source->host->transfers[i];
      break;
    }
  if (!transfer) {
    close(fd);
    return;
  }
  transfer->source = source;
  transfer->fd = fd;
  transfer->offset = 0;
  ++source->transfers;
  flush_transfer(transfer);
}
static void source_cancelled(void *d, struct wl_data_source *proxy) {
  struct clipboard_source *source = d;
  if (!source)
    return;
  if (source->proxy == proxy) {
    source->proxy = NULL;
    wl_data_source_destroy(proxy);
  }
  source->cancelled = 1;
  collect_source(source);
}
static const struct wl_data_source_listener source_listener = {
    .target = source_target,
    .send = source_send,
    .cancelled = source_cancelled};
static void reset_pending_mime_types(struct host *h) {
  h->pending_has_utf8 = 0;
  h->pending_has_plain = 0;
}
static void note_pending_mime_type(struct host *h, const char *mime) {
  if (!strcmp(mime, "text/plain;charset=utf-8"))
    h->pending_has_utf8 = 1;
  else if (!strcmp(mime, "text/plain"))
    h->pending_has_plain = 1;
}
static void commit_pending_mime_types(struct host *h) {
  h->clipboard_has_utf8 = h->pending_has_utf8;
  h->clipboard_has_plain = h->pending_has_plain;
}
static void clear_selection_mime_types(struct host *h) {
  h->clipboard_has_utf8 = 0;
  h->clipboard_has_plain = 0;
}
static void offer_mime(void *d, struct wl_data_offer *offer, const char *mime) {
  struct host *h = d;
  if (offer != h->pending_offer)
    return;
  note_pending_mime_type(h, mime);
}
static const struct wl_data_offer_listener offer_listener = {.offer =
                                                                  offer_mime};
static void data_offer(void *d, struct wl_data_device *device,
                       struct wl_data_offer *offer) {
  struct host *h = d;
  if (device != h->data_device) {
    /* This event introduces a fresh proxy, unlike selection/MIME callbacks
     * which may name already-retired offers. Release the orphan exactly once. */
    if (offer)
      wl_data_offer_destroy(offer);
    return;
  }
  if (h->pending_offer && h->pending_offer != h->selection_offer)
    wl_data_offer_destroy(h->pending_offer);
  h->pending_offer = offer;
  reset_pending_mime_types(h);
  wl_data_offer_add_listener(offer, &offer_listener, h);
}
static void data_enter(void *d, struct wl_data_device *device,
                       uint32_t serial, struct wl_surface *surface,
                       wl_fixed_t x, wl_fixed_t y,
                       struct wl_data_offer *offer) {
  UNUSED(d);
  UNUSED(device);
  UNUSED(serial);
  UNUSED(surface);
  UNUSED(x);
  UNUSED(y);
  UNUSED(offer);
}
static void data_leave(void *d, struct wl_data_device *device) {
  UNUSED(d);
  UNUSED(device);
}
static void data_motion(void *d, struct wl_data_device *device, uint32_t time,
                        wl_fixed_t x, wl_fixed_t y) {
  UNUSED(d);
  UNUSED(device);
  UNUSED(time);
  UNUSED(x);
  UNUSED(y);
}
static void data_drop(void *d, struct wl_data_device *device) {
  UNUSED(d);
  UNUSED(device);
}
static void data_selection(void *d, struct wl_data_device *device,
                           struct wl_data_offer *offer) {
  struct host *h = d;
  if (device != h->data_device)
    return;
  struct wl_data_offer *previous = h->selection_offer;
  struct wl_data_offer *pending = h->pending_offer;
  if (offer && offer != previous && offer != pending)
    return;
  if (previous && previous != offer)
    wl_data_offer_destroy(previous);
  if (pending && pending != previous && pending != offer)
    wl_data_offer_destroy(pending);
  if (offer && offer == pending) {
    /* The data_offer MIME events may describe a drag-and-drop offer rather
     * than the clipboard selection. Publish staged types only when the
     * compositor identifies this offer as the selection. */
    commit_pending_mime_types(h);
  } else if (offer == previous) {
    /* A repeated selection notification keeps the selected offer's MIME
     * types. Discard staged types from any intervening drag offer. */
    h->pending_has_utf8 = h->clipboard_has_utf8;
    h->pending_has_plain = h->clipboard_has_plain;
  } else {
    clear_selection_mime_types(h);
    reset_pending_mime_types(h);
  }
  h->selection_offer = offer;
  h->pending_offer = offer;
  if (!offer) {
    h->pending_has_utf8 = 0;
    h->pending_has_plain = 0;
  }
}
static const struct wl_data_device_listener data_device_listener = {
    .data_offer = data_offer,
    .enter = data_enter,
    .leave = data_leave,
    .motion = data_motion,
    .drop = data_drop,
    .selection = data_selection};
static void detach_seat_data_device(struct host *h) {
  struct wl_data_device *device = h->data_device;
  struct wl_data_offer *selection = h->selection_offer;
  struct wl_data_offer *pending = h->pending_offer;
  h->data_device = NULL;
  h->selection_offer = h->pending_offer = NULL;
  clear_selection_mime_types(h);
  reset_pending_mime_types(h);
  if (selection)
    wl_data_offer_destroy(selection);
  if (pending && pending != selection)
    wl_data_offer_destroy(pending);
  if (device)
    wl_data_device_destroy(device);
  /* Owned sources and active transfers retain their existing cancel/refcount
   * cleanup. A completed read result keeps its documented next-read lifetime. */
}
static void maybe_create_data_device(struct host *h) {
  if (!h->data_device && h->data_manager && h->seat && h->seat_name) {
    h->data_device =
        wl_data_device_manager_get_data_device(h->data_manager, h->seat);
    if (h->data_device)
      wl_data_device_add_listener(h->data_device, &data_device_listener, h);
    else
      h->error = GPUI_RESOURCE;
  }
}
static struct wl_cursor *find_cursor(struct wl_cursor_theme *theme,
                                     const char *first, const char *second,
                                     const char *third) {
  struct wl_cursor *cursor = wl_cursor_theme_get_cursor(theme, first);
  if (!cursor && second)
    cursor = wl_cursor_theme_get_cursor(theme, second);
  if (!cursor && third)
    cursor = wl_cursor_theme_get_cursor(theme, third);
  return cursor;
}
static int load_cursors(struct host *h) {
  if (!h->shm || !h->compositor)
    return GPUI_UNSUPPORTED;
  h->cursor_theme = wl_cursor_theme_load(NULL, 24, h->shm);
  if (!h->cursor_theme)
    return GPUI_RESOURCE;
  h->cursors[0] = find_cursor(h->cursor_theme, "left_ptr", "default", NULL);
  h->cursors[1] = find_cursor(h->cursor_theme, "pointer", "hand2", "hand1");
  h->cursors[2] = find_cursor(h->cursor_theme, "text", "xterm", NULL);
  if (!h->cursors[0] || !h->cursors[1] || !h->cursors[2])
    return GPUI_UNSUPPORTED;
  h->cursor_surface = wl_compositor_create_surface(h->compositor);
  if (!h->cursor_surface)
    return GPUI_RESOURCE;
  h->cursor_kind = 0;
  return GPUI_OK;
}
static int apply_cursor(struct host *h, int kind) {
  if (!h->pointer || !h->pointer_inside || !h->pointer_serial ||
      !h->cursor_surface || kind < 0 || kind >= 3)
    return GPUI_UNSUPPORTED;
  struct wl_cursor *cursor = h->cursors[kind];
  if (!cursor || cursor->image_count == 0)
    return GPUI_UNSUPPORTED;
  struct wl_cursor_image *image = cursor->images[0];
  struct wl_buffer *buffer = wl_cursor_image_get_buffer(image);
  if (!buffer)
    return GPUI_RESOURCE;
  wl_pointer_set_cursor(h->pointer, h->pointer_serial, h->cursor_surface,
                        image->hotspot_x, image->hotspot_y);
  wl_surface_attach(h->cursor_surface, buffer, 0, 0);
  wl_surface_damage(h->cursor_surface, 0, 0, image->width, image->height);
  wl_surface_commit(h->cursor_surface);
  h->cursor_kind = kind;
  return GPUI_OK;
}
static void apply_size(struct host *h) {
  if (!valid_size(h->width, h->height, h->scale)) {
    h->error = GPUI_INVALID;
    return;
  }
  if (h->surface)
    wl_surface_set_buffer_scale(h->surface, h->scale);
  if (h->egl_window)
    wl_egl_window_resize(h->egl_window, h->width * h->scale,
                         h->height * h->scale, 0, 0);
}
static void update_scale(struct host *h) {
  int scale = 1;
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].entered && h->outputs[i].scale > scale)
      scale = h->outputs[i].scale;
  if (scale != h->scale) {
    h->scale = scale;
    apply_size(h);
    event(h, 2, 0, 0, 0);
  }
}
static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                            int32_t pw, int32_t ph, int32_t sub,
                            const char *make, const char *model, int32_t tr) {
  UNUSED(d);
  UNUSED(o);
  UNUSED(x);
  UNUSED(y);
  UNUSED(pw);
  UNUSED(ph);
  UNUSED(sub);
  UNUSED(make);
  UNUSED(model);
  UNUSED(tr);
}
static void output_mode(void *d, struct wl_output *o, uint32_t f, int32_t w,
                        int32_t hh, int32_t r) {
  UNUSED(d);
  UNUSED(o);
  UNUSED(f);
  UNUSED(w);
  UNUSED(hh);
  UNUSED(r);
}
static void output_done(void *d, struct wl_output *o) {
  UNUSED(o);
  update_scale(d);
}
static void output_scale(void *d, struct wl_output *o, int32_t scale) {
  struct host *h = d;
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].proxy == o)
      h->outputs[i].scale = scale > 0 ? scale : 1;
}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale};
static void surface_enter(void *d, struct wl_surface *s, struct wl_output *o) {
  UNUSED(s);
  struct host *h = d;
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].proxy == o)
      h->outputs[i].entered = 1;
  update_scale(h);
}
static void surface_leave(void *d, struct wl_surface *s, struct wl_output *o) {
  UNUSED(s);
  struct host *h = d;
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].proxy == o)
      h->outputs[i].entered = 0;
  update_scale(h);
}
static const struct wl_surface_listener surface_listener = {
    .enter = surface_enter, .leave = surface_leave};
static void ping(void *d, struct xdg_wm_base *s, uint32_t serial) {
  UNUSED(d);
  xdg_wm_base_pong(s, serial);
}
static const struct xdg_wm_base_listener shell_listener = {.ping = ping};
static void configured(void *d, struct xdg_surface *s, uint32_t serial) {
  struct host *h = d;
  xdg_surface_ack_configure(s, serial);
  if (h->pending_width > 0)
    h->width = h->pending_width;
  if (h->pending_height > 0)
    h->height = h->pending_height;
  h->pending_width = h->pending_height = 0;
  h->configured = 1;
  apply_size(h);
  event(h, 1, 0, 0, 0);
}
static const struct xdg_surface_listener xdg_listener = {.configure =
                                                             configured};
static void toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w,
                               int32_t hh, struct wl_array *states) {
  UNUSED(t);
  UNUSED(states);
  struct host *h = d;
  h->pending_width = w;
  h->pending_height = hh;
}
static void toplevel_close(void *d, struct xdg_toplevel *t) {
  UNUSED(t);
  event(d, 3, 0, 0, 0);
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure, .close = toplevel_close};
static void frame_done(void *d, struct wl_callback *c, uint32_t time) {
  UNUSED(time);
  struct host *h = d;
  wl_callback_destroy(c);
  h->frame = NULL;
  event(h, 5, 0, 0, 0);
}
static const struct wl_callback_listener frame_listener = {.done = frame_done};
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  UNUSED(serial);
  struct host *h = d;
  if (p != h->pointer)
    return;
  invalidate_input_serial(h, INPUT_SERIAL_POINTER);
  h->pointer_serial = serial;
  h->pointer_inside = 1;
  h->pointer_focus_current = h->surface && s == h->surface;
  h->px = wl_fixed_to_double(x);
  h->py = wl_fixed_to_double(y);
  if (h->cursor_surface)
    (void)apply_cursor(h, h->cursor_kind);
  event(h, 7, 0, h->px, h->py);
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s) {
  UNUSED(s);
  struct host *h = d;
  if (p != h->pointer)
    return;
  h->pointer_inside = 0;
  h->pointer_focus_current = 0;
  h->pointer_serial = serial;
  invalidate_input_serial(h, INPUT_SERIAL_POINTER);
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y) {
  UNUSED(time);
  struct host *h = d;
  if (p != h->pointer)
    return;
  h->px = wl_fixed_to_double(x);
  h->py = wl_fixed_to_double(y);
  event(h, 7, 0, h->px, h->py);
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state) {
  UNUSED(time);
  struct host *h = d;
  if (p != h->pointer)
    return;
  if (state == WL_POINTER_BUTTON_STATE_PRESSED)
    remember_input_serial(h, serial, INPUT_SERIAL_POINTER);
  if (button >= 0x110 && button <= 0x114)
    event(h, state ? 8 : 9, button - 0x110, h->px, h->py);
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t time,
                         uint32_t axis, wl_fixed_t value) {
  UNUSED(time);
  struct host *h = d;
  if (p != h->pointer)
    return;
  event(h, 10, axis, h->px, h->py);
  if (h->count)
    h->queue[(h->read + h->count - 1) % QUEUE_CAPACITY][4] =
        wl_fixed_to_double(value);
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis};
static void keyboard_keymap(void *d, struct wl_keyboard *k, uint32_t format,
                             int32_t fd, uint32_t size) {
  struct host *h = d;
  if (k != h->keyboard) {
    close(fd);
    return;
  }
  int was_enabled = h->direct_enabled;
  reset_direct_text(h, 1, 0);
  h->direct_keymap_valid = 0;
  if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || size == 0) {
    close(fd);
    return;
  }
  char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    h->error = GPUI_NATIVE;
    return;
  }
  struct xkb_keymap *keymap =
      map[size - 1] == 0 ? xkb_keymap_new_from_string(
                               h->xkb, map, XKB_KEYMAP_FORMAT_TEXT_V1, 0)
                         : NULL;
  munmap(map, size);
  struct xkb_state *keys = keymap ? xkb_state_new(keymap) : NULL;
  if (!keys) {
    xkb_keymap_unref(keymap);
    h->error = GPUI_NATIVE;
    return;
  }
  xkb_state_unref(h->keys);
  xkb_keymap_unref(h->keymap);
  h->keymap = keymap;
  h->keys = keys;
  h->direct_keymap_valid = 1;
  if (!h->compose_table)
    h->compose_attempted = 0;
  if (was_enabled && require_direct_keyboard(h) == GPUI_OK)
    h->direct_enabled = 1;
}
static void keyboard_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s, struct wl_array *keys) {
  UNUSED(serial);
  UNUSED(keys);
  struct host *h = d;
  if (k != h->keyboard)
    return;
  reset_direct_text(h, 1, 0);
  invalidate_input_serial(h, INPUT_SERIAL_KEYBOARD);
  h->keyboard_focus_current = h->surface && s == h->surface;
  event(h, 6, 1, 0, 0);
}
static void keyboard_leave(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s) {
  UNUSED(serial);
  UNUSED(s);
  struct host *h = d;
  if (k != h->keyboard)
    return;
  reset_direct_text(h, 1, 0);
  h->modifiers = 0;
  h->keyboard_focus_current = 0;
  invalidate_input_serial(h, INPUT_SERIAL_KEYBOARD);
  event(h, 6, 0, 0, 0);
}
static void keyboard_key(void *d, struct wl_keyboard *k, uint32_t serial,
                         uint32_t time, uint32_t key, uint32_t state) {
  UNUSED(time);
  struct host *h = d;
  if (k != h->keyboard)
    return;
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED)
    remember_input_serial(h, serial, INPUT_SERIAL_KEYBOARD);
  if (!h->keys)
    return;
  if (h->direct_enabled && key >= GPUI_DIRECT_KEY_CAPACITY) {
    h->error = GPUI_INVALID;
    return;
  }
  xkb_keysym_t sym = xkb_state_key_get_one_sym(h->keys, key + 8);
  direct_keyboard_key(h, key, state, sym);
}
static void keyboard_modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                               uint32_t dep, uint32_t lat, uint32_t lock,
                               uint32_t group) {
  UNUSED(serial);
  struct host *h = d;
  if (k != h->keyboard)
    return;
  if (!h->keys)
    return;
  xkb_state_update_mask(h->keys, dep, lat, lock, 0, 0, group);
  h->modifiers = (xkb_state_mod_name_is_active(h->keys, XKB_MOD_NAME_SHIFT,
                                               XKB_STATE_MODS_EFFECTIVE)
                      ? 1
                      : 0) |
                 (xkb_state_mod_name_is_active(h->keys, XKB_MOD_NAME_CTRL,
                                               XKB_STATE_MODS_EFFECTIVE)
                      ? 2
                      : 0) |
                 (xkb_state_mod_name_is_active(h->keys, XKB_MOD_NAME_ALT,
                                               XKB_STATE_MODS_EFFECTIVE)
                      ? 4
                      : 0) |
                 (xkb_state_mod_name_is_active(h->keys, XKB_MOD_NAME_LOGO,
                                               XKB_STATE_MODS_EFFECTIVE)
                      ? 8
                      : 0);
}
static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers};
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
  struct host *h = d;
  if (s != h->seat)
    return;
  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !h->pointer) {
    h->pointer = wl_seat_get_pointer(s);
    wl_pointer_add_listener(h->pointer, &pointer_listener, h);
    h->pointer_inside = 0;
    h->pointer_serial = 0;
  } else if (!(caps & WL_SEAT_CAPABILITY_POINTER)) {
    invalidate_input_serial(h, INPUT_SERIAL_POINTER);
    h->pointer_focus_current = 0;
    if (h->pointer) {
      h->pointer_inside = 0;
      h->pointer_serial = 0;
      wl_pointer_destroy(h->pointer);
      h->pointer = NULL;
    }
  }
  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !h->keyboard) {
    h->keyboard = wl_seat_get_keyboard(s);
    wl_keyboard_add_listener(h->keyboard, &keyboard_listener, h);
  } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD)) {
    invalidate_input_serial(h, INPUT_SERIAL_KEYBOARD);
    h->keyboard_focus_current = 0;
    if (h->keyboard) {
      event(h, 6, 0, 0, 0);
      wl_keyboard_destroy(h->keyboard);
      h->keyboard = NULL;
    }
    reset_direct_text(h, 1, 1);
    h->direct_keymap_valid = 0;
  }
}
static const struct wl_seat_listener seat_listener = {.capabilities =
                                                          seat_caps};
static void global(void *d, struct wl_registry *r, uint32_t name,
                   const char *interface, uint32_t version) {
  struct host *h = d;
  if (!strcmp(interface, "wl_compositor") && version >= 3 && !h->compositor) {
    h->compositor = wl_registry_bind(r, name, &wl_compositor_interface, 3);
    h->compositor_name = name;
  } else if (!strcmp(interface, "xdg_wm_base") && !h->shell) {
    h->shell = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    h->shell_name = name;
    xdg_wm_base_add_listener(h->shell, &shell_listener, h);
  } else if (!strcmp(interface, "wl_seat") && !h->seat) {
    h->seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    h->seat_name = name;
    wl_seat_add_listener(h->seat, &seat_listener, h);
    maybe_create_data_device(h);
  } else if (!strcmp(interface, "wl_shm") && !h->shm) {
    h->shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    h->shm_name = name;
  } else if (!strcmp(interface, "wl_data_device_manager") &&
             !h->data_manager) {
    h->data_manager = wl_registry_bind(
        r, name, &wl_data_device_manager_interface, 1);
    h->data_manager_name = name;
    maybe_create_data_device(h);
  } else if (!strcmp(interface, "wl_output") && version >= 2) {
    for (int i = 0; i < OUTPUT_CAPACITY; ++i)
      if (!h->outputs[i].proxy) {
        h->outputs[i].proxy =
            wl_registry_bind(r, name, &wl_output_interface, 2);
        h->outputs[i].name = name;
        h->outputs[i].scale = 1;
        wl_output_add_listener(h->outputs[i].proxy, &output_listener, h);
        break;
      }
  }
}
static void global_remove(void *d, struct wl_registry *r, uint32_t name) {
  UNUSED(r);
  struct host *h = d;
  if (name == h->compositor_name || name == h->shell_name)
    h->error = GPUI_NATIVE;
  if (name == h->shm_name) {
    h->shm_name = 0;
  }
  if (name == h->data_manager_name) {
    h->data_manager_name = 0;
  }
  if (h->seat_name && name == h->seat_name) {
    detach_seat_data_device(h);
    /* Remove the proxies before a later seat can bind. Their callbacks must
     * not repopulate focus/key state or re-arm this removed input device. */
    seat_caps(h, h->seat, 0);
    if (h->seat)
      wl_seat_destroy(h->seat);
    h->seat = NULL;
    h->seat_name = 0;
    invalidate_input_serial(h, INPUT_SERIAL_NONE);
    h->pointer_inside = 0;
    h->pointer_focus_current = 0;
    h->keyboard_focus_current = 0;
  }
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].name == name) {
      wl_output_destroy(h->outputs[i].proxy);
      memset(&h->outputs[i], 0, sizeof(h->outputs[i]));
    }
  update_scale(h);
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_remove};
static void release_window_gpu(struct host *h) {
  if (h->egl != EGL_NO_DISPLAY)
    eglMakeCurrent(h->egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (h->egl != EGL_NO_DISPLAY && h->egl_surface != EGL_NO_SURFACE)
    eglDestroySurface(h->egl, h->egl_surface);
  if (h->egl_window)
    wl_egl_window_destroy(h->egl_window);
  h->egl_window = NULL;
  h->egl_surface = EGL_NO_SURFACE;
}
static void release_renderer(struct host *h, int terminate_display) {
  release_window_gpu(h);
  if (h->egl != EGL_NO_DISPLAY && h->context != EGL_NO_CONTEXT)
    eglDestroyContext(h->egl, h->context);
  h->context = EGL_NO_CONTEXT;
  h->program = h->mask_program = 0;
  h->color_uniform = h->mask_color_uniform = h->mask_sampler_uniform = -1;
  if (terminate_display && h->egl != EGL_NO_DISPLAY) {
    eglTerminate(h->egl);
    h->egl = EGL_NO_DISPLAY;
    h->config = NULL;
  }
}
/* Renderer recovery resets context/surface state but keeps the EGLDisplay tied
 * to the externally owned wl_display alive for the host lifetime. */
static void release_gpu(struct host *h) { release_renderer(h, 0); }
static void release_window(struct host *h) {
  if (h->state == 0)
    reset_direct_text(h, 1, 0);
  else {
    h->direct_enabled = 0;
    reset_compose(h);
  }
  invalidate_input_serial(h, INPUT_SERIAL_NONE);
  h->pointer_focus_current = 0;
  h->keyboard_focus_current = 0;
  if (h->frame) {
    wl_callback_destroy(h->frame);
    h->frame = NULL;
  }
  release_window_gpu(h);
  if (h->toplevel)
    xdg_toplevel_destroy(h->toplevel);
  if (h->xdg)
    xdg_surface_destroy(h->xdg);
  if (h->surface)
    wl_surface_destroy(h->surface);
  h->toplevel = NULL;
  h->xdg = NULL;
  h->surface = NULL;
  h->window = 0;
  h->configured = 0;
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    h->outputs[i].entered = 0;
}
static void release_host(struct host *h) {
  release_window(h);
  release_renderer(h, 1);
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i) {
    if (h->transfers[i].fd >= 0)
      close(h->transfers[i].fd);
    h->transfers[i].fd = -1;
    h->transfers[i].source = NULL;
  }
  while (h->sources) {
    struct clipboard_source *source = h->sources;
    h->sources = source->next;
    if (source->proxy)
      wl_data_source_destroy(source->proxy);
    free(source->bytes);
    free(source);
  }
  free(h->clipboard_result);
  detach_seat_data_device(h);
  if (h->data_manager)
    wl_data_device_manager_destroy(h->data_manager);
  if (h->cursor_surface)
    wl_surface_destroy(h->cursor_surface);
  if (h->cursor_theme)
    wl_cursor_theme_destroy(h->cursor_theme);
  if (h->shm)
    wl_shm_destroy(h->shm);
  if (h->pointer)
    wl_pointer_destroy(h->pointer);
  if (h->keyboard)
    wl_keyboard_destroy(h->keyboard);
  if (h->seat)
    wl_seat_destroy(h->seat);
  release_compose(h);
  xkb_state_unref(h->keys);
  xkb_keymap_unref(h->keymap);
  xkb_context_unref(h->xkb);
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].proxy)
      wl_output_destroy(h->outputs[i].proxy);
  if (h->shell)
    xdg_wm_base_destroy(h->shell);
  if (h->compositor)
    wl_compositor_destroy(h->compositor);
  if (h->registry)
    wl_registry_destroy(h->registry);
  if (h->display)
    wl_display_disconnect(h->display);
  if (h->wake_fd >= 0)
    close(h->wake_fd);
  free(h);
}
/* Roundtrips are bounded: a connected but unresponsive compositor must not
 * hang initialization. Startup and creation share the dispatch poll path. */
static int display_failure(struct host *h, const char *where) {
  int display_error = wl_display_get_error(h->display);
  const struct wl_interface *interface = NULL;
  uint32_t object_id = 0;
  uint32_t protocol_error =
      display_error == EPROTO
          ? wl_display_get_protocol_error(h->display, &interface, &object_id)
          : 0;
  fprintf(stderr,
          "gpui-wayland: %s failed: display_error=%d protocol_error=%u "
          "object_id=%u interface=%s errno=%d\n",
          where, display_error, protocol_error, object_id,
          interface ? interface->name : "-", errno);
  // Clipboard flush calls this path directly as well as the pump consumers.
  // A verified display failure always revokes the admitted editor target.
  if (!h->error)
    h->error = GPUI_NATIVE;
  quiesce_host(h);
  return h->error;
}
static int pump_impl(struct host *h, int timeout) {
  if (h->error)
    return h->error;
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    if (h->transfers[i].fd >= 0 && timeout > 16)
      timeout = 16;
  while (wl_display_prepare_read(h->display) != 0) {
    if (wl_display_dispatch_pending(h->display) < 0)
      return display_failure(h, "dispatch_pending/prepare");
    if (h->error)
      return h->error;
    flush_transfers(h);
  }
  /* Dispatching pending source callbacks above can add a transfer after the
   * initial timeout check. Bound the next wake so nonblocking writes resume. */
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    if (h->transfers[i].fd >= 0 && timeout > 16)
      timeout = 16;
  int flush = wl_display_flush(h->display);
  if (flush < 0 && errno != EAGAIN) {
    wl_display_cancel_read(h->display);
    return display_failure(h, "flush");
  }
  struct pollfd fds[2] = {
      {wl_display_get_fd(h->display), POLLIN | (flush < 0 ? POLLOUT : 0), 0},
      {h->wake_fd, POLLIN, 0}};
  int result = poll(fds, 2, timeout);
  if (result < 0) {
    int poll_error = errno;
    wl_display_cancel_read(h->display);
    if (poll_error == EINTR)
      return GPUI_OK;
    fprintf(stderr, "gpui-wayland: poll failed: errno=%d\n", poll_error);
    return GPUI_NATIVE;
  }
  short display_revents = fds[0].revents;
  if ((display_revents & POLLOUT) && flush < 0) {
    if (wl_display_flush(h->display) < 0 && errno != EAGAIN) {
      wl_display_cancel_read(h->display);
      return display_failure(h, "flush/pollout");
    }
  }
  if (display_revents & POLLIN) {
    if (wl_display_read_events(h->display) < 0) {
      fprintf(stderr, "gpui-wayland: read after revents=0x%x failed\n",
              (unsigned)display_revents);
      return display_failure(h, "read_events");
    }
  } else {
    wl_display_cancel_read(h->display);
  }
  if (display_revents & (POLLERR | POLLHUP | POLLNVAL)) {
    fprintf(stderr, "gpui-wayland: poll display revents=0x%x\n",
            (unsigned)display_revents);
    return display_failure(h, "poll");
  }
  if (fds[1].revents & POLLIN) {
    uint64_t value;
    UNUSED(read(h->wake_fd, &value, sizeof(value)));
  }
  if (wl_display_dispatch_pending(h->display) < 0)
    return display_failure(h, "dispatch_pending");
  flush_transfers(h);
  return h->error;
}
static int pump(struct host *h, int timeout) {
  int status = pump_impl(h, timeout);
  if (status) {
    /* Native event-loop failures revoke the target for every consumer,
     * including present, clipboard and teardown/sync paths. Normal no-event
     * timeout is OK; frame preflight/Busy errors do not pass this boundary. */
    if (!h->error)
      h->error = status;
    quiesce_host(h);
    return h->error;
  }
  return GPUI_OK;
}
static int settle_frame(struct host *h) {
  int status = GPUI_OK;
  for (int i = 0; i < 10 && h->frame && !status; ++i)
    status = pump(h, 100);
  return status ? status : (h->frame ? GPUI_BUSY : GPUI_OK);
}
static void sync_done(void *d, struct wl_callback *c, uint32_t serial) {
  UNUSED(serial);
  *(int *)d = 1;
  wl_callback_destroy(c);
}
static const struct wl_callback_listener sync_listener = {.done = sync_done};
static int bounded_sync(struct host *h) {
  int done = 0;
  struct wl_callback *c = wl_display_sync(h->display);
  wl_callback_add_listener(c, &sync_listener, &done);
  int status = GPUI_OK;
  for (int i = 0; i < 30 && !done && !status; ++i)
    status = pump(h, 100);
  if (!done) {
    wl_callback_destroy(c);
    return status ? status : GPUI_NATIVE;
  }
  return status;
}
static GLuint shader(GLenum type, const char *src) {
  GLuint sh = glCreateShader(type);
  glShaderSource(sh, 1, &src, NULL);
  glCompileShader(sh);
  GLint ok;
  glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(sh);
    return 0;
  }
  return sh;
}
static int create_gpu(struct host *h) {
  if (h->egl == EGL_NO_DISPLAY) {
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
            "eglGetPlatformDisplayEXT");
    h->egl =
        get_display ? get_display(EGL_PLATFORM_WAYLAND_EXT, h->display, NULL)
                    : EGL_NO_DISPLAY;
    if (h->egl == EGL_NO_DISPLAY || !eglInitialize(h->egl, NULL, NULL) ||
        !eglBindAPI(EGL_OPENGL_ES_API)) {
      release_renderer(h, 1);
      return GPUI_DEVICE_LOST;
    }
    const EGLint attrs[] = {EGL_SURFACE_TYPE,
                            EGL_WINDOW_BIT,
                            EGL_RENDERABLE_TYPE,
                            EGL_OPENGL_ES2_BIT,
                            EGL_RED_SIZE,
                            8,
                            EGL_GREEN_SIZE,
                            8,
                            EGL_BLUE_SIZE,
                            8,
                            EGL_ALPHA_SIZE,
                            8,
                            EGL_NONE};
    EGLint n;
    if (!eglChooseConfig(h->egl, attrs, &h->config, 1, &n) || !n) {
      release_renderer(h, 1);
      return GPUI_DEVICE_LOST;
    }
  }
  h->egl_window = wl_egl_window_create(h->surface, h->width * h->scale,
                                       h->height * h->scale);
  if (!h->egl_window)
    return GPUI_RESOURCE;
  if (h->context == EGL_NO_CONTEXT) {
    const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    h->context = eglCreateContext(h->egl, h->config, EGL_NO_CONTEXT, ctx);
    if (h->context == EGL_NO_CONTEXT)
      return GPUI_DEVICE_LOST;
  }
  h->egl_surface = eglCreateWindowSurface(
      h->egl, h->config, (EGLNativeWindowType)h->egl_window, NULL);
  if (h->egl_surface == EGL_NO_SURFACE ||
      !eglMakeCurrent(h->egl, h->egl_surface, h->egl_surface, h->context))
    return GPUI_SURFACE_LOST;
  if (!h->program) {
    GLuint v =
        shader(GL_VERTEX_SHADER,
               "attribute vec2 pos; void main(){gl_Position=vec4(pos,0.,1.);}");
    GLuint f = shader(
        GL_FRAGMENT_SHADER,
        "precision mediump float; uniform vec4 color; "
        "void main(){gl_FragColor=color;}");
    if (!v || !f) {
      if (v)
        glDeleteShader(v);
      if (f)
        glDeleteShader(f);
      return GPUI_DEVICE_LOST;
    }
    h->program = glCreateProgram();
    glAttachShader(h->program, v);
    glAttachShader(h->program, f);
    glBindAttribLocation(h->program, 0, "pos");
    glLinkProgram(h->program);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok;
    glGetProgramiv(h->program, GL_LINK_STATUS, &ok);
    if (!ok)
      return GPUI_DEVICE_LOST;
    h->color_uniform = glGetUniformLocation(h->program, "color");
  }
  if (!h->mask_program) {
    GLuint v = shader(GL_VERTEX_SHADER,
        "attribute vec2 pos; attribute vec2 uv; varying vec2 texcoord; "
        "void main(){gl_Position=vec4(pos,0.,1.);texcoord=uv;}");
    GLuint f = shader(GL_FRAGMENT_SHADER,
        "precision mediump float; uniform vec4 color; uniform sampler2D mask; "
        "varying vec2 texcoord; "
        "void main(){gl_FragColor=color*texture2D(mask,texcoord).a;}");
    if (!v || !f) {
      if (v) glDeleteShader(v);
      if (f) glDeleteShader(f);
      return GPUI_DEVICE_LOST;
    }
    h->mask_program = glCreateProgram();
    glAttachShader(h->mask_program, v);
    glAttachShader(h->mask_program, f);
    glBindAttribLocation(h->mask_program, 0, "pos");
    glBindAttribLocation(h->mask_program, 1, "uv");
    glLinkProgram(h->mask_program);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok;
    glGetProgramiv(h->mask_program, GL_LINK_STATUS, &ok);
    if (!ok) return GPUI_DEVICE_LOST;
    h->mask_color_uniform = glGetUniformLocation(h->mask_program, "color");
    h->mask_sampler_uniform = glGetUniformLocation(h->mask_program, "mask");
  }
  return GPUI_OK;
}
static int32_t start_impl(int32_t abi) {
  if (abi != GPUI_UBUNTU_ABI)
    return -GPUI_INVALID;
  if (active)
    return -GPUI_BUSY;
  const char *session = getenv("XDG_SESSION_TYPE");
  if ((session && strcmp(session, "wayland")) || !getenv("WAYLAND_DISPLAY"))
    return -GPUI_UNSUPPORTED;
  if (next_host == INT_MAX)
    return -GPUI_RESOURCE;
  struct host *h = calloc(1, sizeof(*h));
  if (!h)
    return -GPUI_RESOURCE;
  h->wake_fd = -1;
  h->owner = pthread_self();
  h->scale = 1;
  h->egl = EGL_NO_DISPLAY;
  h->context = EGL_NO_CONTEXT;
  h->egl_surface = EGL_NO_SURFACE;
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    h->transfers[i].fd = -1;
  h->display = wl_display_connect(NULL);
  h->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  h->xkb = xkb_context_new(0);
  if (!h->display || h->wake_fd < 0 || !h->xkb) {
    release_host(h);
    return -GPUI_NATIVE;
  }
  h->registry = wl_display_get_registry(h->display);
  wl_registry_add_listener(h->registry, &registry_listener, h);
  int s = bounded_sync(h);
  if (!s)
    s = bounded_sync(h);
  if (s || !h->compositor || !h->shell) {
    release_host(h);
    return -(s ? s : GPUI_UNSUPPORTED);
  }
  /* Cursor assets are optional compositor services. A missing theme does not
   * prevent windows from starting; require_capability reports the absence. */
  (void)load_cursors(h);
  h->token = next_host++;
  active = h;
  return h->token;
}
int32_t gpui_start(int32_t abi) {
  pthread_mutex_lock(&registry_mutex);
  int32_t result = start_impl(abi);
  pthread_mutex_unlock(&registry_mutex);
  return result;
}
int32_t gpui_state(int32_t token) {
  struct host *h;
  return check(token, &h) ? 2 : h->state;
}
int32_t gpui_stop(int32_t token) {
  struct host *h;
  int s = check(token, &h);
  if (s == GPUI_STALE)
    return GPUI_OK;
  if (s)
    return s;
  quiesce_host(h);
  pthread_mutex_lock(&registry_mutex);
  active = NULL;
  pthread_mutex_unlock(&registry_mutex);
  release_host(h);
  return GPUI_OK;
}
int32_t gpui_wake(int32_t token) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  uint64_t value = 1;
  return write(h->wake_fd, &value, sizeof(value)) < 0 && errno != EAGAIN
             ? GPUI_NATIVE
             : GPUI_OK;
}
int32_t gpui_exit(int32_t token) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  quiesce_host(h);
  return gpui_wake(token);
}
static int title_valid(const uint8_t *title, int length) {
  return length >= 0 && length <= 4096 && (title || !length) &&
         !(length && memchr(title, 0, length));
}
static char *copy_title(const uint8_t *title, int length) {
  char *s = malloc((size_t)length + 1);
  if (s) {
    if (length)
      memcpy(s, title, length);
    s[length] = 0;
  }
  return s;
}
int32_t gpui_create(int32_t token, int32_t w, int32_t hh, const uint8_t *title,
                    int32_t length) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return -s;
  if (h->state)
    return -GPUI_STOPPING;
  if (h->window)
    return -GPUI_BUSY;
  if (!valid_size(w, hh, 1) || next_window == INT_MAX)
    return -GPUI_INVALID;
  if (!title_valid(title, length))
    return -GPUI_INVALID;
  char *text = copy_title(title, length);
  if (!text)
    return -GPUI_RESOURCE;
  h->width = w;
  h->height = hh;
  h->scale = 1;
  h->seq = 0;
  h->surface = wl_compositor_create_surface(h->compositor);
  if (!h->surface) {
    free(text);
    return -GPUI_RESOURCE;
  }
  wl_surface_add_listener(h->surface, &surface_listener, h);
  h->xdg = xdg_wm_base_get_xdg_surface(h->shell, h->surface);
  h->toplevel = h->xdg ? xdg_surface_get_toplevel(h->xdg) : NULL;
  if (!h->toplevel) {
    free(text);
    release_window(h);
    return -GPUI_RESOURCE;
  }
  xdg_surface_add_listener(h->xdg, &xdg_listener, h);
  xdg_toplevel_add_listener(h->toplevel, &toplevel_listener, h);
  xdg_toplevel_set_title(h->toplevel, text);
  free(text);
  xdg_toplevel_set_app_id(h->toplevel, "gpui.mbt");
  wl_surface_commit(h->surface);
  s = bounded_sync(h);
  for (int i = 0; i < 30 && !h->configured && !s; ++i)
    s = pump(h, 100);
  if (!s && !h->configured)
    s = GPUI_NATIVE;
  if (!s)
    s = create_gpu(h);
  if (s) {
    release_window(h);
    return -s;
  }
  h->window = next_window++;
  event(h, 1, 0, 0, 0);
  return h->window;
}
int32_t gpui_close(int32_t token, int32_t window) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  event(h, 3, 0, 0, 0);
  return h->error;
}
int32_t gpui_destroy(int32_t token, int32_t window) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (window > 0 && window < next_window && h->window != window)
    return GPUI_OK;
  if (!window || h->window != window)
    return GPUI_STALE;
  /* Do not tear EGL/surface resources out from under a submitted buffer. The
   * callback is compositor readiness, not presentation timing, but it gives the
   * first native slice a bounded ownership handoff before native teardown. */
  s = settle_frame(h);
  if (s)
    return s;
  /* Drop queued old callbacks, then publish one terminal notification. */
  int count = h->count, kept = 0;
  for (int i = 0; i < count; ++i) {
    double *e = h->queue[(h->read + i) % QUEUE_CAPACITY];
    if ((int)e[1] != window) {
      memcpy(h->queue[(h->read + kept++) % QUEUE_CAPACITY], e,
             sizeof(h->queue[0]));
    }
  }
  h->count = kept;
  event(h, 4, 0, 0, 0);
  release_window(h);
  return GPUI_OK;
}
int32_t gpui_title(int32_t token, int32_t window, const uint8_t *title,
                   int32_t length) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (!title_valid(title, length))
    return GPUI_INVALID;
  char *text = copy_title(title, length);
  if (!text)
    return GPUI_RESOURCE;
  xdg_toplevel_set_title(h->toplevel, text);
  free(text);
  return GPUI_OK;
}
int32_t gpui_size(int32_t token, int32_t window, int32_t w, int32_t hh) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (!valid_size(w, hh, h->scale))
    return GPUI_INVALID;
  h->width = w;
  h->height = hh;
  apply_size(h);
  xdg_surface_set_window_geometry(h->xdg, 0, 0, w, hh);
  event(h, 1, 0, 0, 0);
  return GPUI_OK;
}
int32_t gpui_metrics(int32_t token, int32_t window, double *metrics) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (!metrics)
    return GPUI_INVALID;
  metrics[0] = h->width;
  metrics[1] = h->height;
  metrics[2] = h->scale;
  return GPUI_OK;
}
int32_t gpui_dispatch(int32_t token, int32_t timeout) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (timeout < 0 || timeout > 60000)
    return GPUI_INVALID;
  s = pump(h, h->count || h->state ? 0 : timeout);
  return s;
}
int32_t gpui_next(int32_t token, double *out) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return -s;
  if (!out)
    return -GPUI_INVALID;
  if (h->direct_exhausted && h->direct_ever_enabled)
    return -GPUI_RESOURCE;
  if (h->direct_enabled)
    return -GPUI_UNSUPPORTED;
  for (int i = 0; i < h->count; ++i) {
    int slot = (h->read + i) % QUEUE_CAPACITY;
    if (h->queue[slot][0] == 13 || h->direct_queue[slot].direct_origin)
      return -GPUI_UNSUPPORTED;
  }
  if (!h->count)
    return 0;
  memcpy(out, h->queue[h->read], sizeof(h->queue[0]));
  h->read = (h->read + 1) % QUEUE_CAPACITY;
  --h->count;
  return 1;
}
static int stale_direct_record(const struct host *h, int slot) {
  double kind = h->queue[slot][0];
  if (kind != 11 && kind != 12 && kind != 13)
    return 0;
  const struct direct_event_meta *meta = &h->direct_queue[slot];
  if (h->state != 0 && meta->direct_origin)
    return 1;
  if (meta->direct_origin && h->direct_exhausted)
    return 1;
  if ((meta->direct_origin || h->direct_enabled) &&
      meta->epoch != h->direct_epoch)
    return 1;
  return meta->direct_origin &&
         (!h->direct_enabled || !h->keyboard_focus_current);
}
static void consume_event(struct host *h) {
  memset(&h->direct_queue[h->read], 0, sizeof(h->direct_queue[h->read]));
  h->read = (h->read + 1) % QUEUE_CAPACITY;
  --h->count;
}
int32_t gpui_next_v2(int32_t abi, int32_t token, double *out,
                     int32_t out_capacity, uint8_t *text,
                     int32_t text_capacity) {
  if (abi != GPUI_DIRECT_TEXT_ABI)
    return -GPUI_UNSUPPORTED;
  if (!out || out_capacity < 0 || text_capacity < 0 ||
      (!text && text_capacity > 0))
    return -GPUI_INVALID;
  if (out_capacity < 10)
    return -GPUI_RESOURCE;
  struct host *h;
  int status = check(token, &h);
  if (status)
    return -status;
  if (h->direct_exhausted && h->direct_ever_enabled)
    return -GPUI_RESOURCE;
  int skipped = 0;
  while (skipped < h->count &&
         stale_direct_record(h, (h->read + skipped) % QUEUE_CAPACITY))
    ++skipped;
  if (skipped == h->count) {
    while (h->count)
      consume_event(h);
    return 0;
  }
  int slot = (h->read + skipped) % QUEUE_CAPACITY;
  const struct direct_event_meta *meta = &h->direct_queue[slot];
  if (h->queue[slot][0] == 13) {
    if (meta->text_length <= 0 ||
        meta->text_length > GPUI_DIRECT_TEXT_MAX_BYTES ||
        h->queue[slot][8] != meta->text_length ||
        !direct_utf8_valid(meta->text, meta->text_length))
      return -GPUI_INVALID;
    if (text_capacity < meta->text_length)
      return -GPUI_RESOURCE;
  }
  memcpy(out, h->queue[slot], sizeof(h->queue[slot]));
  if (h->queue[slot][0] == 13)
    memcpy(text, meta->text, (size_t)meta->text_length);
  for (int i = 0; i <= skipped; ++i)
    consume_event(h);
  return 1;
}
int32_t gpui_direct_keyboard_text_mode(int32_t token, int32_t window,
                                      int32_t enabled) {
  struct host *h;
  int status = check(token, &h);
  if (status)
    return status;
  if (!h->window || window != h->window)
    return GPUI_STALE;
  if (enabled != 0 && enabled != 1)
    return GPUI_INVALID;
  if (h->direct_exhausted)
    return GPUI_RESOURCE;
  if (enabled) {
    if (h->state != 0)
      return GPUI_STOPPING;
    if (!h->keyboard_focus_current)
      return GPUI_UNSUPPORTED;
    status = require_direct_keyboard(h);
    if (status)
      return status;
  }
  status = advance_direct_epoch(h);
  if (status)
    return status;
  h->direct_enabled = enabled;
  if (enabled)
    h->direct_ever_enabled = 1;
  return GPUI_OK;
}
int32_t gpui_direct_keyboard_text_epoch(int32_t token, int32_t window) {
  struct host *h;
  int status = check(token, &h);
  if (status)
    return -status;
  if (!h->window || window != h->window)
    return -GPUI_STALE;
  if (h->direct_exhausted)
    return -GPUI_RESOURCE;
  if (h->state != 0)
    return -GPUI_STOPPING;
  if (!h->direct_enabled || !h->keyboard_focus_current)
    return -GPUI_UNSUPPORTED;
  return h->direct_epoch;
}
int32_t gpui_direct_keyboard_text_active(int32_t token) {
  struct host *h;
  int status = check(token, &h);
  return status ? -status : h->state == 0 && h->direct_enabled;
}
struct staged_text {
  int item_index;
  struct gpui_linux_text_mask mask;
  GLuint texture;
};

static void release_staged_text(struct staged_text *texts, int count,
                                 int textures_current) {
  for (int i = 0; i < count; ++i) {
    if (textures_current && texts[i].texture)
      glDeleteTextures(1, &texts[i].texture);
    gpui_linux_text_mask_release_v1(&texts[i].mask);
  }
}

static int text_status(int status) {
  switch (status) {
  case GPUI_LINUX_TEXT_OK:
    return GPUI_OK;
  case GPUI_LINUX_TEXT_UNSUPPORTED_INPUT:
  case GPUI_LINUX_TEXT_UNSUPPORTED_COLOR:
  case GPUI_LINUX_TEXT_UNSUPPORTED_RASTER:
    return GPUI_UNSUPPORTED;
  case GPUI_LINUX_TEXT_INPUT_TOO_LARGE:
  case GPUI_LINUX_TEXT_RESOURCE_LIMIT:
  case GPUI_LINUX_TEXT_CAPACITY_TOO_SMALL:
    return GPUI_RESOURCE;
  case GPUI_LINUX_TEXT_INVALID_ARGUMENT:
  case GPUI_LINUX_TEXT_INVALID_COORDINATES:
    return GPUI_INVALID;
  default:
    return GPUI_NATIVE;
  }
}

/* Validate all common fields and every transformed corner before rasterizing
 * or touching GL. Same limits as the original private quad ABI. */
static int valid_common_item(const double *q) {
  if (q[2] < 0 || q[3] < 0 || q[14] < 0 || q[14] > 1 || q[17] < 0 ||
      q[18] < 0)
    return 0;
  for (int c = 4; c < 8; ++c)
    if (q[c] < 0 || q[c] > 255)
      return 0;
  for (int j = 0; j < 4; ++j) {
    double px = q[0] + ((j == 1 || j == 3) ? q[2] : 0);
    double py = q[1] + ((j >= 2) ? q[3] : 0);
    double tx = q[8] * px + q[10] * py + q[12];
    double ty = q[9] * px + q[11] * py + q[13];
    if (!isfinite(tx) || !isfinite(ty) || fabs(tx) > 1e20 || fabs(ty) > 1e20)
      return 0;
  }
  return 1;
}

static int item_scissor(struct host *h, const double *q) {
  double left = fmax(0, q[15]), top = fmax(0, q[16]);
  double right = fmin(h->width, q[15] + q[17]);
  double bottom = fmin(h->height, q[16] + q[18]);
  if (right <= left || bottom <= top)
    return 0;
  /* Device sample centers inside the logical half-open viewport-space clip. */
  int x = (int)ceil(left * h->scale - 0.5);
  int y = (int)ceil(top * h->scale - 0.5);
  int r = (int)ceil(right * h->scale - 0.5);
  int b = (int)ceil(bottom * h->scale - 0.5);
  int dw = h->width * h->scale, dh = h->height * h->scale;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (r < 0) r = 0;
  if (b < 0) b = 0;
  if (x > dw) x = dw;
  if (r > dw) r = dw;
  if (y > dh) y = dh;
  if (b > dh) b = dh;
  if (r <= x || b <= y)
    return 0;
  glScissor(x, dh - b, r - x, b - y);
  return 1;
}

int32_t gpui_present_v2(int32_t abi, int32_t token, int32_t window,
                        const double *data, int32_t length,
                        const uint8_t *text, int32_t text_length) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (h->state)
    return GPUI_STOPPING;
  if (h->error)
    return h->error;
  s = pump(h, 0);
  if (s)
    return s;
  if (abi != GPUI_MIXED_FRAME_ABI || !data || length < 5 ||
      (length - 5) % GPUI_MIXED_STRIDE || text_length < 0 ||
      (text_length && !text))
    return GPUI_INVALID;
  if ((length - 5) / GPUI_MIXED_STRIDE > GPUI_MAX_ITEMS ||
      text_length > GPUI_MAX_FRAME_TEXT_BYTES)
    return GPUI_RESOURCE;
  for (int i = 0; i < length; ++i)
    if (!isfinite(data[i]) || fabs(data[i]) > 1e20)
      return GPUI_INVALID;
  int text_count = 0;
  for (int i = 5; i < length; i += GPUI_MIXED_STRIDE) {
    const double *record = data + i, *q = record + 1;
    if (record[0] != 0 && record[0] != 1)
      return GPUI_UNSUPPORTED;
    if (!valid_common_item(q))
      return GPUI_INVALID;
    if (record[0] == 0) {
      if (record[20] != 0 || record[21] != 0 || record[22] != 0)
        return GPUI_INVALID;
    } else {
      if (++text_count > GPUI_MAX_TEXT_ITEMS)
        return GPUI_RESOURCE;
      if (record[20] < 0 || record[21] < 0 ||
          record[20] > text_length || record[21] > text_length - record[20] ||
          floor(record[20]) != record[20] || floor(record[21]) != record[21] ||
          record[22] <= 0)
        return GPUI_INVALID;
      if (record[21] > GPUI_LINUX_TEXT_MAX_TEXT_BYTES)
        return GPUI_RESOURCE;
      if (record[22] > GPUI_LINUX_TEXT_MAX_FONT_SIZE_PX)
        return GPUI_UNSUPPORTED;
    }
  }
  if (data[0] != 0 || data[1] != 0)
    return GPUI_UNSUPPORTED;
  if (data[2] != h->width || data[3] != h->height || data[4] != h->scale)
    return GPUI_BUSY;
  if (!h->configured || h->frame)
    return GPUI_BUSY;

  struct staged_text texts[GPUI_MAX_TEXT_ITEMS] = {0};
  int staged = 0;
  size_t total_mask_bytes = 0;
  static const uint8_t sans[] = "sans";
  for (int i = 5; i < length; i += GPUI_MIXED_STRIDE) {
    const double *record = data + i, *q = record + 1;
    if (record[0] == 0)
      continue;
    struct staged_text *item = texts + staged;
    item->item_index = (i - 5) / GPUI_MIXED_STRIDE;
    ++staged;
    int offset = (int)record[20], bytes = (int)record[21];
    const uint8_t *span = bytes ? text + offset : (const uint8_t *)"";
    s = text_status(gpui_linux_text_raster_v1(
        GPUI_LINUX_TEXT_ABI, span, bytes, sans, 4, record[22], q[2], q[3],
        (int32_t)(GPUI_MAX_FRAME_MASK_BYTES - total_mask_bytes), &item->mask));
    if (s)
      goto preflight_failure;
    size_t mask_bytes = (size_t)item->mask.width * (size_t)item->mask.height;
    if (mask_bytes > GPUI_MAX_FRAME_MASK_BYTES - total_mask_bytes) {
      s = GPUI_RESOURCE;
      goto preflight_failure;
    }
    total_mask_bytes += mask_bytes;
  }
  if (h->egl_surface == EGL_NO_SURFACE ||
      !eglMakeCurrent(h->egl, h->egl_surface, h->egl_surface, h->context)) {
    s = GPUI_SURFACE_LOST;
    goto preflight_failure;
  }
  if (glGetError() != GL_NO_ERROR) {
    s = GPUI_DEVICE_LOST;
    goto preflight_failure;
  }
  GLint maximum_texture = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum_texture);
  if (maximum_texture <= 0 || glGetError() != GL_NO_ERROR) {
    s = GPUI_DEVICE_LOST;
    goto preflight_failure;
  }
  glActiveTexture(GL_TEXTURE0);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  for (int i = 0; i < staged; ++i) {
    struct staged_text *item = texts + i;
    if (!item->mask.pixels)
      continue;
    if (item->mask.width > maximum_texture || item->mask.height > maximum_texture) {
      s = GPUI_RESOURCE;
      goto texture_failure;
    }
    glGenTextures(1, &item->texture);
    glBindTexture(GL_TEXTURE_2D, item->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, item->mask.width, item->mask.height,
                 0, GL_ALPHA, GL_UNSIGNED_BYTE, item->mask.pixels);
    GLenum error = glGetError();
    if (!item->texture || error != GL_NO_ERROR) {
      s = error == GL_OUT_OF_MEMORY ? GPUI_RESOURCE : GPUI_DEVICE_LOST;
      goto texture_failure;
    }
  }

  /* All inputs, Pango layouts, allocations and uploads passed before clear.
   * Device/surface failures after this point retain the existing typed recovery
   * semantics; they are not an atomic-display guarantee. */
  glViewport(0, 0, h->width * h->scale, h->height * h->scale);
  glDisable(GL_SCISSOR_TEST);
  glClearColor(0, 0, 0, 0);
  glClear(GL_COLOR_BUFFER_BIT);
  glEnable(GL_BLEND);
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  glEnableVertexAttribArray(0);
  glEnable(GL_SCISSOR_TEST);
  int text_index = 0;
  for (int i = 5; i < length; i += GPUI_MIXED_STRIDE) {
    const double *record = data + i, *q = record + 1;
    struct staged_text *item = NULL;
    if (record[0] == 1)
      item = texts + text_index++;
    if (!item_scissor(h, q) || (item && !item->texture))
      continue;
    double left = q[0], top = q[1], right = q[0] + q[2], bottom = q[1] + q[3];
    GLfloat uvs[8];
    GLint color_uniform;
    if (item) {
      const struct gpui_linux_text_mask *mask = &item->mask;
      left += mask->left;
      top += mask->top;
      right = q[0] + mask->right;
      bottom = q[1] + mask->bottom;
      GLfloat u = (GLfloat)((mask->right - mask->left) / mask->width);
      GLfloat v = (GLfloat)((mask->bottom - mask->top) / mask->height);
      GLfloat mapped[8] = {0, 0, u, 0, 0, v, u, v};
      memcpy(uvs, mapped, sizeof(uvs));
      glUseProgram(h->mask_program);
      glUniform1i(h->mask_sampler_uniform, 0);
      glBindTexture(GL_TEXTURE_2D, item->texture);
      glEnableVertexAttribArray(1);
      glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, uvs);
      color_uniform = h->mask_color_uniform;
    } else {
      glUseProgram(h->program);
      glDisableVertexAttribArray(1);
      color_uniform = h->color_uniform;
    }
    GLfloat vertices[8];
    for (int j = 0; j < 4; ++j) {
      double px = (j == 1 || j == 3) ? right : left;
      double py = j >= 2 ? bottom : top;
      double tx = q[8] * px + q[10] * py + q[12];
      double ty = q[9] * px + q[11] * py + q[13];
      vertices[j * 2] = (GLfloat)(2 * tx / h->width - 1);
      vertices[j * 2 + 1] = (GLfloat)(1 - 2 * ty / h->height);
    }
    float alpha = (float)(q[7] / 255.0 * q[14]);
    glUniform4f(color_uniform, (float)(q[4] / 255.0) * alpha,
                (float)(q[5] / 255.0) * alpha, (float)(q[6] / 255.0) * alpha,
                alpha);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  }
  glDisableVertexAttribArray(0);
  glDisableVertexAttribArray(1);
  glDisable(GL_SCISSOR_TEST);
  glBindTexture(GL_TEXTURE_2D, 0);
  release_staged_text(texts, staged, 1);
  if (glGetError() != GL_NO_ERROR)
    return GPUI_DEVICE_LOST;
  h->frame = wl_surface_frame(h->surface);
  wl_callback_add_listener(h->frame, &frame_listener, h);
  if (!eglSwapBuffers(h->egl, h->egl_surface)) {
    wl_callback_destroy(h->frame);
    h->frame = NULL;
    return eglGetError() == EGL_CONTEXT_LOST ? GPUI_DEVICE_LOST
                                             : GPUI_SURFACE_LOST;
  }
  return GPUI_OK;

texture_failure:
  glBindTexture(GL_TEXTURE_2D, 0);
  release_staged_text(texts, staged, 1);
  return s;
preflight_failure:
  release_staged_text(texts, staged, 0);
  return s;
}

int32_t gpui_present(int32_t token, int32_t window, const double *data,
                     int32_t length) {
  if (!data || length < 5 || (length - 5) % GPUI_QUAD_STRIDE)
    return GPUI_INVALID;
  int count = (length - 5) / GPUI_QUAD_STRIDE;
  if (count > GPUI_MAX_ITEMS)
    return GPUI_RESOURCE;
  int mixed_length = 5 + count * GPUI_MIXED_STRIDE;
  double *mixed = malloc((size_t)mixed_length * sizeof(double));
  if (!mixed)
    return GPUI_RESOURCE;
  memcpy(mixed, data, 5 * sizeof(double));
  for (int i = 0; i < count; ++i) {
    double *record = mixed + 5 + i * GPUI_MIXED_STRIDE;
    record[0] = 0;
    memcpy(record + 1, data + 5 + i * GPUI_QUAD_STRIDE,
            GPUI_QUAD_STRIDE * sizeof(double));
    record[20] = record[21] = record[22] = 0;
  }
  int status = gpui_present_v2(GPUI_MIXED_FRAME_ABI, token, window, mixed,
                               mixed_length, NULL, 0);
  free(mixed);
  return status;
}
int32_t gpui_recover(int32_t token, int32_t window) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (h->state)
    return GPUI_STOPPING;
  if (h->frame) {
    wl_callback_destroy(h->frame);
    h->frame = NULL;
  }
  release_gpu(h);
  s = create_gpu(h);
  if (s)
    release_gpu(h);
  return s;
}
int32_t gpui_capability(int32_t token, int32_t capability) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (capability == 1)
    return h->data_device && h->data_manager ? GPUI_OK : GPUI_UNSUPPORTED;
  if (capability == 2)
    return h->pointer && h->cursor_surface && h->cursors[0] && h->cursors[1] &&
                   h->cursors[2]
               ? GPUI_OK
               : GPUI_UNSUPPORTED;
  if (capability == 3)
    return require_direct_keyboard(h);
  return GPUI_UNSUPPORTED;
}
static int64_t monotonic_milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return -1;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
int32_t gpui_read_clipboard(int32_t token) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  free(h->clipboard_result);
  h->clipboard_result = NULL;
  h->clipboard_result_length = 0;
  if (!h->window || !h->data_device || !h->selection_offer)
    return GPUI_UNSUPPORTED;
  const char *mime = h->clipboard_has_utf8
                         ? "text/plain;charset=utf-8"
                         : (h->clipboard_has_plain ? "text/plain" : NULL);
  if (!mime)
    return GPUI_UNSUPPORTED;
  int descriptors[2];
  if (pipe(descriptors) != 0)
    return GPUI_RESOURCE;
  if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) < 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    return GPUI_NATIVE;
  }
  int flags = fcntl(descriptors[0], F_GETFL);
  if (flags < 0 || fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) < 0) {
    close(descriptors[0]);
    close(descriptors[1]);
    return GPUI_NATIVE;
  }
  wl_data_offer_receive(h->selection_offer, mime, descriptors[1]);
  close(descriptors[1]);
  if (wl_display_flush(h->display) < 0 && errno != EAGAIN) {
    close(descriptors[0]);
    return display_failure(h, "clipboard_flush");
  }
  uint8_t *bytes = malloc((size_t)CLIPBOARD_LIMIT + 1);
  if (!bytes) {
    close(descriptors[0]);
    return GPUI_RESOURCE;
  }
  int64_t start = monotonic_milliseconds();
  if (start < 0) {
    free(bytes);
    close(descriptors[0]);
    return GPUI_NATIVE;
  }
  size_t length = 0;
  int complete = 0;
  while (!complete) {
    for (;;) {
      ssize_t count = read(descriptors[0], bytes + length,
                           (size_t)CLIPBOARD_LIMIT + 1 - length);
      if (count > 0) {
        length += (size_t)count;
        if (length > CLIPBOARD_LIMIT) {
          close(descriptors[0]);
          free(bytes);
          return GPUI_RESOURCE;
        }
      } else if (count == 0) {
        complete = 1;
        break;
      } else if (errno == EINTR) {
        continue;
      } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
        break;
      } else {
        close(descriptors[0]);
        free(bytes);
        return GPUI_NATIVE;
      }
    }
    if (complete)
      break;
    int64_t now = monotonic_milliseconds();
    if (now < 0 || now - start >= CLIPBOARD_TIMEOUT_MS) {
      close(descriptors[0]);
      free(bytes);
      return GPUI_BUSY;
    }
    s = pump(h, 10);
    if (s) {
      close(descriptors[0]);
      free(bytes);
      return s;
    }
  }
  close(descriptors[0]);
  h->clipboard_result = bytes;
  h->clipboard_result_length = length;
  return GPUI_OK;
}
int32_t gpui_clipboard_length(int32_t token) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return -s;
  if (!h->clipboard_result || h->clipboard_result_length > INT_MAX)
    return -GPUI_STALE;
  return (int32_t)h->clipboard_result_length;
}
int32_t gpui_clipboard_copy(int32_t token, uint8_t *bytes, int32_t capacity) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (!h->clipboard_result || capacity < 0 ||
      (size_t)capacity < h->clipboard_result_length ||
      (h->clipboard_result_length && !bytes))
    return GPUI_INVALID;
  if (h->clipboard_result_length)
    memcpy(bytes, h->clipboard_result, h->clipboard_result_length);
  return GPUI_OK;
}
int32_t gpui_write_clipboard(int32_t token, const uint8_t *bytes,
                             int32_t length) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (h->state)
    return GPUI_STOPPING;
  if (!h->window || !h->data_device || !h->data_manager)
    return GPUI_UNSUPPORTED;
  if (!has_input_serial(h))
    return GPUI_UNSUPPORTED;
  if (length < 0 || length > CLIPBOARD_LIMIT || (length && !bytes) ||
      (length && memchr(bytes, 0, (size_t)length)))
    return length > CLIPBOARD_LIMIT ? GPUI_RESOURCE : GPUI_INVALID;
  size_t source_count = 0;
  for (struct clipboard_source *item = h->sources; item; item = item->next)
    ++source_count;
  if (source_count >= 16)
    return GPUI_BUSY;
  struct clipboard_source *source = calloc(1, sizeof(*source));
  if (!source)
    return GPUI_RESOURCE;
  source->bytes = malloc(length ? (size_t)length : 1);
  if (!source->bytes) {
    free(source);
    return GPUI_RESOURCE;
  }
  if (length)
    memcpy(source->bytes, bytes, (size_t)length);
  source->length = (size_t)length;
  source->host = h;
  source->proxy = wl_data_device_manager_create_data_source(h->data_manager);
  if (!source->proxy) {
    free(source->bytes);
    free(source);
    return GPUI_RESOURCE;
  }
  wl_data_source_add_listener(source->proxy, &source_listener, source);
  wl_data_source_offer(source->proxy, "text/plain;charset=utf-8");
  wl_data_source_offer(source->proxy, "text/plain");
  source->next = h->sources;
  h->sources = source;
  wl_data_device_set_selection(h->data_device, source->proxy, h->input_serial);
  if (wl_display_flush(h->display) < 0 && errno != EAGAIN)
    return display_failure(h, "clipboard_set_selection");
  return GPUI_OK;
}
int32_t gpui_set_cursor(int32_t token, int32_t cursor) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (!h->window)
    return GPUI_UNSUPPORTED;
  if (cursor < 0 || cursor >= 3)
    return GPUI_INVALID;
  return apply_cursor(h, cursor);
}
