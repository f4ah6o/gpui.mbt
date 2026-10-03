#define _POSIX_C_SOURCE 200809L
#include "backend.h"
#include "xdg-shell-client-protocol.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <xkbcommon/xkbcommon.h>

#define QUEUE_CAPACITY 1024
#define OUTPUT_CAPACITY 16
#define UNUSED(x) (void)(x)
struct output {
  struct wl_output *proxy;
  uint32_t name;
  int scale, entered;
};
struct host {
  int token, window, state, wake_fd, error;
  pthread_t owner;
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_compositor *compositor;
  struct xdg_wm_base *shell;
  uint32_t compositor_name, shell_name;
  struct wl_seat *seat;
  struct wl_pointer *pointer;
  struct wl_keyboard *keyboard;
  struct xkb_context *xkb;
  struct xkb_keymap *keymap;
  struct xkb_state *keys;
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
  GLuint program;
  GLint color_uniform;
  int width, height, pending_width, pending_height, scale, configured, seq;
  double px, py;
  int modifiers;
  double queue[QUEUE_CAPACITY][10];
  int read, count;
};
static struct host *active;
static pthread_mutex_t registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static int next_host = 1;
static int next_window = 1;
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
  double *e = h->queue[(h->read + h->count++) % QUEUE_CAPACITY];
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
  UNUSED(p);
  UNUSED(serial);
  UNUSED(s);
  struct host *h = d;
  h->px = wl_fixed_to_double(x);
  h->py = wl_fixed_to_double(y);
  event(h, 7, 0, h->px, h->py);
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s) {
  UNUSED(d);
  UNUSED(p);
  UNUSED(serial);
  UNUSED(s);
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t time,
                           wl_fixed_t x, wl_fixed_t y) {
  UNUSED(p);
  UNUSED(time);
  struct host *h = d;
  h->px = wl_fixed_to_double(x);
  h->py = wl_fixed_to_double(y);
  event(h, 7, 0, h->px, h->py);
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t serial,
                           uint32_t time, uint32_t button, uint32_t state) {
  UNUSED(p);
  UNUSED(serial);
  UNUSED(time);
  struct host *h = d;
  if (button >= 0x110 && button <= 0x114)
    event(h, state ? 8 : 9, button - 0x110, h->px, h->py);
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t time,
                         uint32_t axis, wl_fixed_t value) {
  UNUSED(p);
  UNUSED(time);
  struct host *h = d;
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
  UNUSED(k);
  struct host *h = d;
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
}
static void keyboard_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s, struct wl_array *keys) {
  UNUSED(k);
  UNUSED(serial);
  UNUSED(s);
  UNUSED(keys);
  event(d, 6, 1, 0, 0);
}
static void keyboard_leave(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s) {
  UNUSED(k);
  UNUSED(serial);
  UNUSED(s);
  struct host *h = d;
  h->modifiers = 0;
  event(h, 6, 0, 0, 0);
}
static void keyboard_key(void *d, struct wl_keyboard *k, uint32_t serial,
                         uint32_t time, uint32_t key, uint32_t state) {
  UNUSED(k);
  UNUSED(serial);
  UNUSED(time);
  struct host *h = d;
  if (!h->keys)
    return;
  xkb_keysym_t sym = xkb_state_key_get_one_sym(h->keys, key + 8);
  event(h, state ? 11 : 12, sym, xkb_keysym_to_utf32(sym), 0);
}
static void keyboard_modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                               uint32_t dep, uint32_t lat, uint32_t lock,
                               uint32_t group) {
  UNUSED(k);
  UNUSED(serial);
  struct host *h = d;
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
  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !h->pointer) {
    h->pointer = wl_seat_get_pointer(s);
    wl_pointer_add_listener(h->pointer, &pointer_listener, h);
  } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && h->pointer) {
    wl_pointer_destroy(h->pointer);
    h->pointer = NULL;
  }
  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !h->keyboard) {
    h->keyboard = wl_seat_get_keyboard(s);
    wl_keyboard_add_listener(h->keyboard, &keyboard_listener, h);
  } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && h->keyboard) {
    event(h, 6, 0, 0, 0);
    wl_keyboard_destroy(h->keyboard);
    h->keyboard = NULL;
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
    wl_seat_add_listener(h->seat, &seat_listener, h);
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
  for (int i = 0; i < OUTPUT_CAPACITY; ++i)
    if (h->outputs[i].name == name) {
      wl_output_destroy(h->outputs[i].proxy);
      memset(&h->outputs[i], 0, sizeof(h->outputs[i]));
    }
  update_scale(h);
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_remove};
static void release_gpu(struct host *h) {
  if (h->egl != EGL_NO_DISPLAY) {
    if (h->context != EGL_NO_CONTEXT && h->egl_surface != EGL_NO_SURFACE &&
        eglMakeCurrent(h->egl, h->egl_surface, h->egl_surface, h->context) &&
        h->program)
      glDeleteProgram(h->program);
    eglMakeCurrent(h->egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (h->egl_surface != EGL_NO_SURFACE)
      eglDestroySurface(h->egl, h->egl_surface);
    if (h->context != EGL_NO_CONTEXT)
      eglDestroyContext(h->egl, h->context);
    eglTerminate(h->egl);
  }
  if (h->egl_window)
    wl_egl_window_destroy(h->egl_window);
  h->egl_window = NULL;
  h->egl = EGL_NO_DISPLAY;
  h->context = EGL_NO_CONTEXT;
  h->egl_surface = EGL_NO_SURFACE;
  h->program = 0;
}
static void release_window(struct host *h) {
  if (h->frame) {
    wl_callback_destroy(h->frame);
    h->frame = NULL;
  }
  release_gpu(h);
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
  if (h->pointer)
    wl_pointer_destroy(h->pointer);
  if (h->keyboard)
    wl_keyboard_destroy(h->keyboard);
  if (h->seat)
    wl_seat_destroy(h->seat);
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
static int pump(struct host *h, int timeout) {
  if (h->error)
    return h->error;
  while (wl_display_prepare_read(h->display) != 0) {
    if (wl_display_dispatch_pending(h->display) < 0)
      return GPUI_NATIVE;
    if (h->error)
      return h->error;
  }
  int flush = wl_display_flush(h->display);
  if (flush < 0 && errno != EAGAIN) {
    wl_display_cancel_read(h->display);
    return GPUI_NATIVE;
  }
  struct pollfd fds[2] = {
      {wl_display_get_fd(h->display), POLLIN | (flush < 0 ? POLLOUT : 0), 0},
      {h->wake_fd, POLLIN, 0}};
  int result = poll(fds, 2, timeout);
  if (result < 0) {
    wl_display_cancel_read(h->display);
    return errno == EINTR ? GPUI_OK : GPUI_NATIVE;
  }
  if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
    wl_display_cancel_read(h->display);
    return GPUI_NATIVE;
  }
  if (fds[0].revents & POLLIN) {
    if (wl_display_read_events(h->display) < 0)
      return GPUI_NATIVE;
  } else
    wl_display_cancel_read(h->display);
  if (fds[1].revents & POLLIN) {
    uint64_t value;
    UNUSED(read(h->wake_fd, &value, sizeof(value)));
  }
  if (wl_display_dispatch_pending(h->display) < 0)
    return GPUI_NATIVE;
  return h->error;
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
  h->egl_window = wl_egl_window_create(h->surface, h->width * h->scale,
                                       h->height * h->scale);
  if (!h->egl_window)
    return GPUI_RESOURCE;
  PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
          "eglGetPlatformDisplayEXT");
  h->egl = get_display ? get_display(EGL_PLATFORM_WAYLAND_EXT, h->display, NULL)
                       : EGL_NO_DISPLAY;
  if (h->egl == EGL_NO_DISPLAY || !eglInitialize(h->egl, NULL, NULL) ||
      !eglBindAPI(EGL_OPENGL_ES_API))
    return GPUI_DEVICE_LOST;
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
  if (!eglChooseConfig(h->egl, attrs, &h->config, 1, &n) || !n)
    return GPUI_DEVICE_LOST;
  const EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  h->context = eglCreateContext(h->egl, h->config, EGL_NO_CONTEXT, ctx);
  h->egl_surface = eglCreateWindowSurface(
      h->egl, h->config, (EGLNativeWindowType)h->egl_window, NULL);
  if (h->context == EGL_NO_CONTEXT || h->egl_surface == EGL_NO_SURFACE ||
      !eglMakeCurrent(h->egl, h->egl_surface, h->egl_surface, h->context))
    return GPUI_SURFACE_LOST;
  GLuint v =
      shader(GL_VERTEX_SHADER,
             "attribute vec2 pos; void main(){gl_Position=vec4(pos,0.,1.);}");
  GLuint f =
      shader(GL_FRAGMENT_SHADER, "precision mediump float; uniform vec4 color; "
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
  h->color_uniform = glGetUniformLocation(h->program, "color");
  return ok ? GPUI_OK : GPUI_DEVICE_LOST;
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
  h->state = 1;
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
int32_t gpui_dispatch(int32_t token, int32_t timeout) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return s;
  if (timeout < 0 || timeout > 60000)
    return GPUI_INVALID;
  s = pump(h, h->count || h->state ? 0 : timeout);
  if (s) {
    h->state = 1;
    h->error = s;
  }
  return s;
}
int32_t gpui_next(int32_t token, double *out) {
  struct host *h;
  int s = check(token, &h);
  if (s)
    return -s;
  if (!h->count)
    return 0;
  memcpy(out, h->queue[h->read], sizeof(h->queue[0]));
  h->read = (h->read + 1) % QUEUE_CAPACITY;
  --h->count;
  return 1;
}
int32_t gpui_present(int32_t token, int32_t window, const double *data,
                     int32_t length) {
  struct host *h;
  int s = window_check(token, window, &h);
  if (s)
    return s;
  if (h->state)
    return GPUI_STOPPING;
  if (h->error)
    return h->error;
  /* Dispatch queued configure/scale events before checking the snapshot. */
  s = pump(h, 0);
  if (s)
    return s;
  if (length < 5 || (length - 5) % GPUI_QUAD_STRIDE)
    return GPUI_INVALID;
  for (int i = 0; i < length; ++i)
    if (!isfinite(data[i]) || fabs(data[i]) > 1e20)
      return GPUI_INVALID;
  for (int i = 5; i < length; i += GPUI_QUAD_STRIDE) {
    const double *q = data + i;
    if (q[2] < 0 || q[3] < 0 || q[14] < 0 || q[14] > 1 || q[17] < 0 ||
        q[18] < 0)
      return GPUI_INVALID;
    for (int c = 4; c < 8; ++c)
      if (q[c] < 0 || q[c] > 255)
        return GPUI_INVALID;
    for (int j = 0; j < 4; ++j) {
      double px = q[0] + ((j == 1 || j == 3) ? q[2] : 0);
      double py = q[1] + ((j >= 2) ? q[3] : 0);
      double tx = q[8] * px + q[10] * py + q[12];
      double ty = q[9] * px + q[11] * py + q[13];
      if (!isfinite(tx) || !isfinite(ty) || fabs(tx) > 1e20 || fabs(ty) > 1e20)
        return GPUI_INVALID;
    }
  }
  if (data[0] != 0 || data[1] != 0)
    return GPUI_UNSUPPORTED;
  if (data[2] != h->width || data[3] != h->height || data[4] != h->scale)
    return GPUI_BUSY;
  if (!h->configured || h->frame)
    return GPUI_BUSY;
  if (h->egl_surface == EGL_NO_SURFACE ||
      !eglMakeCurrent(h->egl, h->egl_surface, h->egl_surface, h->context))
    return GPUI_SURFACE_LOST;
  glViewport(0, 0, h->width * h->scale, h->height * h->scale);
  glDisable(GL_SCISSOR_TEST);
  glClearColor(0, 0, 0, 0);
  glClear(GL_COLOR_BUFFER_BIT);
  glUseProgram(h->program);
  glEnable(GL_BLEND);
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  glEnableVertexAttribArray(0);
  glEnable(GL_SCISSOR_TEST);
  for (int i = 5; i < length; i += GPUI_QUAD_STRIDE) {
    const double *q = data + i;
    double left = fmax(0, q[15]), top = fmax(0, q[16]);
    double right = fmin(h->width, q[15] + q[17]),
           bottom = fmin(h->height, q[16] + q[18]);
    if (right <= left || bottom <= top)
      continue;
    int x = (int)ceil(left * h->scale), y = (int)ceil(top * h->scale);
    int r = (int)floor(right * h->scale), b = (int)floor(bottom * h->scale);
    if (r <= x || b <= y)
      continue;
    glScissor(x, h->height * h->scale - b, r - x, b - y);
    GLfloat vertices[8];
    for (int j = 0; j < 4; ++j) {
      double px = q[0] + ((j == 1 || j == 3) ? q[2] : 0);
      double py = q[1] + ((j >= 2) ? q[3] : 0);
      double tx = q[8] * px + q[10] * py + q[12];
      double ty = q[9] * px + q[11] * py + q[13];
      vertices[j * 2] = (GLfloat)(2 * tx / h->width - 1);
      vertices[j * 2 + 1] = (GLfloat)(1 - 2 * ty / h->height);
    }
    float alpha = (float)(q[7] / 255.0 * q[14]);
    glUniform4f(h->color_uniform, (float)(q[4] / 255.0) * alpha,
                (float)(q[5] / 255.0) * alpha, (float)(q[6] / 255.0) * alpha,
                alpha);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  }
  glDisableVertexAttribArray(0);
  glDisable(GL_SCISSOR_TEST);
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
