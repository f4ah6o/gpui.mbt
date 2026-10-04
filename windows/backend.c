#include "backend.h"

#if defined(_WIN32)

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define GPUI_EVENT_CAPACITY 4096
#define GPUI_MAX_QUADS 100000
#define GPUI_WAKE_MESSAGE (WM_APP + 0x41)
#define GPUI_EXIT_MESSAGE (WM_APP + 0x42)
#define GPUI_CLASS_NAME L"gpui_mbt_windows_host_v1"

typedef struct gpui_vertex {
  float position[2];
  float color[4];
} gpui_vertex;

typedef BOOL(WINAPI *fn_set_process_dpi_awareness_context)(DPI_AWARENESS_CONTEXT);
typedef DPI_AWARENESS_CONTEXT(WINAPI *fn_get_thread_dpi_awareness_context)(void);
typedef BOOL(WINAPI *fn_are_dpi_awareness_contexts_equal)(
    DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT);
typedef UINT(WINAPI *fn_get_dpi_for_system)(void);
typedef UINT(WINAPI *fn_get_dpi_for_window)(HWND);
typedef ATOM(WINAPI *fn_register_class_ex_w)(const WNDCLASSEXW *);
typedef BOOL(WINAPI *fn_unregister_class_w)(LPCWSTR, HINSTANCE);
typedef HWND(WINAPI *fn_create_window_ex_w)(DWORD, LPCWSTR, LPCWSTR, DWORD,
                                            int, int, int, int, HWND, HMENU,
                                            HINSTANCE, LPVOID);
typedef BOOL(WINAPI *fn_destroy_window)(HWND);
typedef LRESULT(WINAPI *fn_def_window_proc_w)(HWND, UINT, WPARAM, LPARAM);
typedef LONG_PTR(WINAPI *fn_set_window_long_ptr_w)(HWND, int, LONG_PTR);
typedef LONG_PTR(WINAPI *fn_get_window_long_ptr_w)(HWND, int);
typedef BOOL(WINAPI *fn_show_window)(HWND, int);
typedef BOOL(WINAPI *fn_update_window)(HWND);
typedef BOOL(WINAPI *fn_set_window_text_w)(HWND, LPCWSTR);
typedef BOOL(WINAPI *fn_set_window_pos)(HWND, HWND, int, int, int, int, UINT);
typedef BOOL(WINAPI *fn_get_client_rect)(HWND, LPRECT);
typedef BOOL(WINAPI *fn_get_window_rect)(HWND, LPRECT);
typedef LRESULT(WINAPI *fn_send_message_w)(HWND, UINT, WPARAM, LPARAM);
typedef HWND(WINAPI *fn_get_capture)(void);
typedef BOOL(WINAPI *fn_adjust_window_rect_ex_for_dpi)(LPRECT, DWORD, BOOL,
                                                       DWORD, UINT);
typedef BOOL(WINAPI *fn_adjust_window_rect_ex)(LPRECT, DWORD, BOOL, DWORD);
typedef BOOL(WINAPI *fn_screen_to_client)(HWND, LPPOINT);
typedef BOOL(WINAPI *fn_client_to_screen)(HWND, LPPOINT);
typedef BOOL(WINAPI *fn_peek_message_w)(LPMSG, HWND, UINT, UINT, UINT);
typedef BOOL(WINAPI *fn_translate_message)(const MSG *);
typedef LRESULT(WINAPI *fn_dispatch_message_w)(const MSG *);
typedef BOOL(WINAPI *fn_post_thread_message_w)(DWORD, UINT, WPARAM, LPARAM);
typedef BOOL(WINAPI *fn_post_message_w)(HWND, UINT, WPARAM, LPARAM);
typedef HWND(WINAPI *fn_set_capture)(HWND);
typedef BOOL(WINAPI *fn_release_capture)(void);
typedef BOOL(WINAPI *fn_track_mouse_event)(LPTRACKMOUSEEVENT);
typedef SHORT(WINAPI *fn_get_key_state)(int);
typedef HCURSOR(WINAPI *fn_load_cursor_w)(HINSTANCE, LPCWSTR);
typedef HCURSOR(WINAPI *fn_set_cursor)(HCURSOR);
typedef HDC(WINAPI *fn_get_dc)(HWND);
typedef int(WINAPI *fn_release_dc)(HWND, HDC);
typedef HDC(WINAPI *fn_begin_paint)(HWND, LPPAINTSTRUCT);
typedef BOOL(WINAPI *fn_end_paint)(HWND, const PAINTSTRUCT *);
typedef DWORD(WINAPI *fn_msg_wait_for_multiple_objects)(DWORD, const HANDLE *,
                                                       BOOL, DWORD, DWORD);
typedef BOOL(WINAPI *fn_open_clipboard)(HWND);
typedef HANDLE(WINAPI *fn_get_clipboard_data)(UINT);
typedef BOOL(WINAPI *fn_close_clipboard)(void);
typedef BOOL(WINAPI *fn_empty_clipboard)(void);
typedef HANDLE(WINAPI *fn_set_clipboard_data)(UINT, HANDLE);

typedef HRESULT(WINAPI *fn_d3d11_create_device_and_swap_chain)(
    IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT, const DXGI_SWAP_CHAIN_DESC *,
    IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *,
    ID3D11DeviceContext **);
typedef HRESULT(WINAPI *fn_d3d_compile)(LPCVOID, SIZE_T, LPCSTR,
                                       const D3D_SHADER_MACRO *,
                                       ID3DInclude *, LPCSTR, LPCSTR, UINT,
                                       UINT, ID3DBlob **, ID3DBlob **);

typedef struct gpui_windows_api {
  HMODULE user32;
  HMODULE d3d11;
  HMODULE d3dcompiler;
  fn_set_process_dpi_awareness_context set_process_dpi_awareness_context;
  fn_get_thread_dpi_awareness_context get_thread_dpi_awareness_context;
  fn_are_dpi_awareness_contexts_equal are_dpi_awareness_contexts_equal;
  fn_get_dpi_for_system get_dpi_for_system;
  fn_get_dpi_for_window get_dpi_for_window;
  fn_register_class_ex_w register_class_ex_w;
  fn_unregister_class_w unregister_class_w;
  fn_create_window_ex_w create_window_ex_w;
  fn_destroy_window destroy_window;
  fn_def_window_proc_w def_window_proc_w;
  fn_set_window_long_ptr_w set_window_long_ptr_w;
  fn_get_window_long_ptr_w get_window_long_ptr_w;
  fn_show_window show_window;
  fn_update_window update_window;
  fn_set_window_text_w set_window_text_w;
  fn_set_window_pos set_window_pos;
  fn_get_client_rect get_client_rect;
  fn_get_window_rect get_window_rect;
  fn_send_message_w send_message_w;
  fn_get_capture get_capture;
  fn_adjust_window_rect_ex_for_dpi adjust_window_rect_ex_for_dpi;
  fn_adjust_window_rect_ex adjust_window_rect_ex;
  fn_screen_to_client screen_to_client;
  fn_client_to_screen client_to_screen;
  fn_peek_message_w peek_message_w;
  fn_translate_message translate_message;
  fn_dispatch_message_w dispatch_message_w;
  fn_post_thread_message_w post_thread_message_w;
  fn_post_message_w post_message_w;
  fn_set_capture set_capture;
  fn_release_capture release_capture;
  fn_track_mouse_event track_mouse_event;
  fn_get_key_state get_key_state;
  fn_load_cursor_w load_cursor_w;
  fn_set_cursor set_cursor;
  fn_get_dc get_dc;
  fn_release_dc release_dc;
  fn_begin_paint begin_paint;
  fn_end_paint end_paint;
  fn_msg_wait_for_multiple_objects msg_wait_for_multiple_objects;
  fn_open_clipboard open_clipboard;
  fn_get_clipboard_data get_clipboard_data;
  fn_close_clipboard close_clipboard;
  fn_empty_clipboard empty_clipboard;
  fn_set_clipboard_data set_clipboard_data;
  fn_d3d11_create_device_and_swap_chain d3d11_create_device_and_swap_chain;
  fn_d3d_compile d3d_compile;
} gpui_windows_api;

typedef struct gpui_windows_host {
  gpui_windows_api api;
  int32_t token;
  int32_t window_id;
  int32_t last_destroyed_window;
  DWORD owner_thread;
  volatile LONG state; /* 0 running, 1 quiescing, 2 stopped */
  volatile LONG error;
  HWND hwnd;
  HINSTANCE instance;
  UINT dpi;
  double scale;
  double logical_width;
  double logical_height;
  int32_t pixel_width;
  int32_t pixel_height;
  int64_t sequence;
  double events[GPUI_EVENT_CAPACITY][10];
  int32_t event_read;
  int32_t event_count;
  BOOL class_registered;
  BOOL destroying;
  BOOL mouse_tracking;
  UINT mouse_buttons;
  WCHAR pending_high_surrogate;
  HCURSOR cursor;

  IDXGISwapChain *swap_chain;
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  ID3D11RenderTargetView *render_target;
  ID3D11VertexShader *vertex_shader;
  ID3D11PixelShader *pixel_shader;
  ID3D11InputLayout *input_layout;
  ID3D11Buffer *vertex_buffer;
  ID3D11Query *frame_query;
  ID3D11BlendState *blend_state;
  ID3D11RasterizerState *rasterizer_state;
  ID3D11Texture2D *staging_texture;
  UINT vertex_capacity;
  UINT staging_width;
  UINT staging_height;
  BOOL readback_enabled;
  BOOL readback_valid;
  BOOL frame_pending;
  double readback_rgba[12];
} gpui_windows_host;

static gpui_windows_host g_host;
static volatile LONG g_host_claimed;
static volatile LONG g_next_host;
static volatile LONG g_next_window;
/* Wake and lifecycle calls can arrive on different threads. Keep the loaded
 * user32 function pointer and owner-thread ID alive while a wake is posted. */
static SRWLOCK g_host_lifecycle_lock = SRWLOCK_INIT;
static const GUID gpui_iid_texture2d =
    {0x6f15aaf2, 0xd208, 0x4e89, {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}};

#define GPUI_MOUSE_LEFT (1u << 0)
#define GPUI_MOUSE_RIGHT (1u << 1)
#define GPUI_MOUSE_MIDDLE (1u << 2)
#define GPUI_MOUSE_X1 (1u << 3)
#define GPUI_MOUSE_X2 (1u << 4)

static LRESULT CALLBACK gpui_window_proc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam);

#define GPUI_LOAD(module, field, type, name)                                 \
  do {                                                                        \
    g_host.api.field = (type)(uintptr_t)GetProcAddress((module), (name));      \
    if (!g_host.api.field)                                                    \
      return GPUI_WINDOWS_UNSUPPORTED;                                        \
  } while (0)

#define GPUI_RELEASE(type, value)                                             \
  do {                                                                        \
    if ((value) != NULL) {                                                     \
      type##_Release(value);                                                   \
      (value) = NULL;                                                          \
    }                                                                          \
  } while (0)

static BOOL valid_token(int32_t token) {
  return token > 0 && g_host_claimed != 0 && g_host.token == token;
}

/* Caller holds g_host_lifecycle_lock in shared or exclusive mode. */
static int32_t check_host_locked(int32_t token, BOOL owner_thread) {
  if (!valid_token(token))
    return GPUI_WINDOWS_STALE;
  if (owner_thread && GetCurrentThreadId() != g_host.owner_thread)
    return GPUI_WINDOWS_WRONG_THREAD;
  return GPUI_WINDOWS_OK;
}

static int32_t check_host(int32_t token, BOOL owner_thread) {
  AcquireSRWLockShared(&g_host_lifecycle_lock);
  int32_t status = check_host_locked(token, owner_thread);
  ReleaseSRWLockShared(&g_host_lifecycle_lock);
  return status;
}

static int32_t check_window(int32_t token, int32_t window) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (window != g_host.window_id || !g_host.hwnd)
    return GPUI_WINDOWS_STALE;
  if (g_host.state != 0)
    return GPUI_WINDOWS_STOPPING;
  return GPUI_WINDOWS_OK;
}

static void emit_event_for(gpui_windows_host *host, int32_t window_id,
                           int32_t kind, double x, double y, int32_t detail,
                           int32_t mods) {
  if (!host || host->state == 2)
    return;
  if (host->event_count >= GPUI_EVENT_CAPACITY) {
    InterlockedExchange(&host->error, GPUI_WINDOWS_RESOURCE);
    InterlockedExchange(&host->state, 1);
    return;
  }
  int32_t at = (host->event_read + host->event_count) % GPUI_EVENT_CAPACITY;
  double *event = host->events[at];
  event[0] = kind;
  event[1] = window_id;
  event[2] = window_id ? (double)++host->sequence : 0;
  event[3] = host->scale > 0.0 ? host->scale : 1.0;
  event[4] = host->logical_width;
  event[5] = host->logical_height;
  event[6] = x;
  event[7] = y;
  event[8] = detail;
  event[9] = mods;
  host->event_count++;
}

static void emit_event(gpui_windows_host *host, int32_t kind, double x,
                       double y, int32_t detail, int32_t mods) {
  emit_event_for(host, host ? host->window_id : 0, kind, x, y, detail, mods);
}

static void discard_events_for(gpui_windows_host *host, int32_t window_id) {
  int32_t kept_count = 0;
  int32_t old_read = host->event_read;
  for (int32_t i = 0; i < host->event_count; ++i) {
    int32_t at = (old_read + i) % GPUI_EVENT_CAPACITY;
    if ((int32_t)host->events[at][1] == window_id)
      continue;
    int32_t destination = (old_read + kept_count++) % GPUI_EVENT_CAPACITY;
    if (destination != at)
      memcpy(host->events[destination], host->events[at],
             sizeof(host->events[0]));
  }
  host->event_read = old_read;
  host->event_count = kept_count;
}

static int32_t utf8_to_wide(const uint8_t *bytes, int32_t length,
                            WCHAR **output, int32_t *wide_length) {
  if (length < 0 || length > 1024 * 1024 || (length && !bytes))
    return GPUI_WINDOWS_INVALID;
  if (length && memchr(bytes, 0, (size_t)length))
    return GPUI_WINDOWS_CONVERSION;
  *output = NULL;
  *wide_length = 0;
  if (length == 0) {
    WCHAR *empty = (WCHAR *)calloc(1, sizeof(WCHAR));
    if (!empty)
      return GPUI_WINDOWS_RESOURCE;
    *output = empty;
    return GPUI_WINDOWS_OK;
  }
  int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   (LPCCH)bytes, length, NULL, 0);
  if (needed <= 0)
    return GPUI_WINDOWS_CONVERSION;
  WCHAR *wide = (WCHAR *)calloc((size_t)needed + 1, sizeof(WCHAR));
  if (!wide)
    return GPUI_WINDOWS_RESOURCE;
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (LPCCH)bytes, length,
                          wide, needed) != needed) {
    free(wide);
    return GPUI_WINDOWS_CONVERSION;
  }
  *output = wide;
  *wide_length = needed;
  return GPUI_WINDOWS_OK;
}

static int32_t api_init(gpui_windows_host *host) {
  (void)host;
  HMODULE user32 = LoadLibraryW(L"user32.dll");
  HMODULE d3d11 = LoadLibraryW(L"d3d11.dll");
  HMODULE d3dcompiler = LoadLibraryW(L"d3dcompiler_47.dll");
  if (!user32 || !d3d11 || !d3dcompiler) {
    if (user32)
      FreeLibrary(user32);
    if (d3d11)
      FreeLibrary(d3d11);
    if (d3dcompiler)
      FreeLibrary(d3dcompiler);
    return GPUI_WINDOWS_UNSUPPORTED;
  }
  g_host.api.user32 = user32;
  g_host.api.d3d11 = d3d11;
  g_host.api.d3dcompiler = d3dcompiler;
  GPUI_LOAD(user32, set_process_dpi_awareness_context,
            fn_set_process_dpi_awareness_context,
            "SetProcessDpiAwarenessContext");
  GPUI_LOAD(user32, get_thread_dpi_awareness_context,
            fn_get_thread_dpi_awareness_context,
            "GetThreadDpiAwarenessContext");
  GPUI_LOAD(user32, are_dpi_awareness_contexts_equal,
            fn_are_dpi_awareness_contexts_equal,
            "AreDpiAwarenessContextsEqual");
  GPUI_LOAD(user32, get_dpi_for_system, fn_get_dpi_for_system,
            "GetDpiForSystem");
  GPUI_LOAD(user32, get_dpi_for_window, fn_get_dpi_for_window,
            "GetDpiForWindow");
  GPUI_LOAD(user32, register_class_ex_w, fn_register_class_ex_w,
            "RegisterClassExW");
  GPUI_LOAD(user32, unregister_class_w, fn_unregister_class_w,
            "UnregisterClassW");
  GPUI_LOAD(user32, create_window_ex_w, fn_create_window_ex_w,
            "CreateWindowExW");
  GPUI_LOAD(user32, destroy_window, fn_destroy_window, "DestroyWindow");
  GPUI_LOAD(user32, def_window_proc_w, fn_def_window_proc_w,
            "DefWindowProcW");
  GPUI_LOAD(user32, set_window_long_ptr_w, fn_set_window_long_ptr_w,
            "SetWindowLongPtrW");
  GPUI_LOAD(user32, get_window_long_ptr_w, fn_get_window_long_ptr_w,
            "GetWindowLongPtrW");
  GPUI_LOAD(user32, show_window, fn_show_window, "ShowWindow");
  GPUI_LOAD(user32, update_window, fn_update_window, "UpdateWindow");
  GPUI_LOAD(user32, set_window_text_w, fn_set_window_text_w, "SetWindowTextW");
  GPUI_LOAD(user32, set_window_pos, fn_set_window_pos, "SetWindowPos");
  GPUI_LOAD(user32, get_client_rect, fn_get_client_rect, "GetClientRect");
  GPUI_LOAD(user32, get_window_rect, fn_get_window_rect, "GetWindowRect");
  GPUI_LOAD(user32, send_message_w, fn_send_message_w, "SendMessageW");
  GPUI_LOAD(user32, get_capture, fn_get_capture, "GetCapture");
  g_host.api.adjust_window_rect_ex_for_dpi =
      (fn_adjust_window_rect_ex_for_dpi)(uintptr_t)GetProcAddress(
          user32, "AdjustWindowRectExForDpi");
  GPUI_LOAD(user32, adjust_window_rect_ex, fn_adjust_window_rect_ex,
            "AdjustWindowRectEx");
  GPUI_LOAD(user32, screen_to_client, fn_screen_to_client, "ScreenToClient");
  GPUI_LOAD(user32, client_to_screen, fn_client_to_screen, "ClientToScreen");
  GPUI_LOAD(user32, peek_message_w, fn_peek_message_w, "PeekMessageW");
  GPUI_LOAD(user32, translate_message, fn_translate_message,
            "TranslateMessage");
  GPUI_LOAD(user32, dispatch_message_w, fn_dispatch_message_w,
            "DispatchMessageW");
  GPUI_LOAD(user32, post_thread_message_w, fn_post_thread_message_w,
            "PostThreadMessageW");
  GPUI_LOAD(user32, post_message_w, fn_post_message_w, "PostMessageW");
  GPUI_LOAD(user32, set_capture, fn_set_capture, "SetCapture");
  GPUI_LOAD(user32, release_capture, fn_release_capture, "ReleaseCapture");
  GPUI_LOAD(user32, track_mouse_event, fn_track_mouse_event,
            "TrackMouseEvent");
  GPUI_LOAD(user32, get_key_state, fn_get_key_state, "GetKeyState");
  GPUI_LOAD(user32, load_cursor_w, fn_load_cursor_w, "LoadCursorW");
  GPUI_LOAD(user32, set_cursor, fn_set_cursor, "SetCursor");
  GPUI_LOAD(user32, get_dc, fn_get_dc, "GetDC");
  GPUI_LOAD(user32, release_dc, fn_release_dc, "ReleaseDC");
  GPUI_LOAD(user32, begin_paint, fn_begin_paint, "BeginPaint");
  GPUI_LOAD(user32, end_paint, fn_end_paint, "EndPaint");
  GPUI_LOAD(user32, msg_wait_for_multiple_objects,
            fn_msg_wait_for_multiple_objects, "MsgWaitForMultipleObjects");
  GPUI_LOAD(user32, open_clipboard, fn_open_clipboard, "OpenClipboard");
  GPUI_LOAD(user32, get_clipboard_data, fn_get_clipboard_data,
            "GetClipboardData");
  GPUI_LOAD(user32, close_clipboard, fn_close_clipboard, "CloseClipboard");
  GPUI_LOAD(user32, empty_clipboard, fn_empty_clipboard, "EmptyClipboard");
  GPUI_LOAD(user32, set_clipboard_data, fn_set_clipboard_data,
            "SetClipboardData");
  GPUI_LOAD(d3d11, d3d11_create_device_and_swap_chain,
            fn_d3d11_create_device_and_swap_chain,
            "D3D11CreateDeviceAndSwapChain");
  GPUI_LOAD(d3dcompiler, d3d_compile, fn_d3d_compile, "D3DCompile");
  return GPUI_WINDOWS_OK;
}

static void api_release(gpui_windows_host *host) {
  if (host->api.d3dcompiler)
    FreeLibrary(host->api.d3dcompiler);
  if (host->api.d3d11)
    FreeLibrary(host->api.d3d11);
  if (host->api.user32)
    FreeLibrary(host->api.user32);
  ZeroMemory(&host->api, sizeof(host->api));
}

static HRESULT create_render_target(gpui_windows_host *host) {
  ID3D11Texture2D *back_buffer = NULL;
  HRESULT hr = IDXGISwapChain_GetBuffer(host->swap_chain, 0,
                                        &gpui_iid_texture2d,
                                        (void **)&back_buffer);
  if (FAILED(hr))
    return hr;
  hr = ID3D11Device_CreateRenderTargetView(host->device,
                                           (ID3D11Resource *)back_buffer, NULL,
                                           &host->render_target);
  ID3D11Texture2D_Release(back_buffer);
  return hr;
}

static void release_gpu(gpui_windows_host *host) {
  if (host->context)
    ID3D11DeviceContext_ClearState(host->context);
  GPUI_RELEASE(ID3D11Texture2D, host->staging_texture);
  GPUI_RELEASE(ID3D11Buffer, host->vertex_buffer);
  GPUI_RELEASE(ID3D11Query, host->frame_query);
  GPUI_RELEASE(ID3D11RasterizerState, host->rasterizer_state);
  GPUI_RELEASE(ID3D11BlendState, host->blend_state);
  GPUI_RELEASE(ID3D11InputLayout, host->input_layout);
  GPUI_RELEASE(ID3D11PixelShader, host->pixel_shader);
  GPUI_RELEASE(ID3D11VertexShader, host->vertex_shader);
  GPUI_RELEASE(ID3D11RenderTargetView, host->render_target);
  GPUI_RELEASE(ID3D11DeviceContext, host->context);
  GPUI_RELEASE(ID3D11Device, host->device);
  GPUI_RELEASE(IDXGISwapChain, host->swap_chain);
  host->vertex_capacity = 0;
  host->staging_width = 0;
  host->staging_height = 0;
  host->readback_valid = FALSE;
  host->frame_pending = FALSE;
}

static HRESULT compile_shader(gpui_windows_host *host, const char *source,
                              LPCSTR entry, LPCSTR target, ID3DBlob **result) {
  ID3DBlob *errors = NULL;
  HRESULT hr = host->api.d3d_compile(
      source, strlen(source), "gpui_windows_shader", NULL, NULL, entry, target,
      0, 0, result, &errors);
  if (errors)
    ID3D10Blob_Release(errors);
  return hr;
}

static HRESULT create_pipeline(gpui_windows_host *host) {
  static const char vertex_source[] =
      "struct V { float2 position : POSITION; float4 color : COLOR; };\n"
      "struct O { float4 position : SV_POSITION; float4 color : COLOR; };\n"
      "O main(V v) { O o; o.position=float4(v.position,0.0,1.0); "
      "o.color=v.color; return o; }\n";
  static const char pixel_source[] =
      "float4 main(float4 position : SV_POSITION, float4 color : COLOR) "
      ": SV_TARGET { return color; }\n";
  ID3DBlob *vertex_blob = NULL;
  ID3DBlob *pixel_blob = NULL;
  HRESULT hr = compile_shader(host, vertex_source, "main", "vs_4_0",
                              &vertex_blob);
  if (FAILED(hr))
    goto done;
  hr = compile_shader(host, pixel_source, "main", "ps_4_0", &pixel_blob);
  if (FAILED(hr))
    goto done;
  hr = ID3D11Device_CreateVertexShader(
      host->device, ID3D10Blob_GetBufferPointer(vertex_blob),
      ID3D10Blob_GetBufferSize(vertex_blob), NULL, &host->vertex_shader);
  if (FAILED(hr))
    goto done;
  hr = ID3D11Device_CreatePixelShader(
      host->device, ID3D10Blob_GetBufferPointer(pixel_blob),
      ID3D10Blob_GetBufferSize(pixel_blob), NULL, &host->pixel_shader);
  if (FAILED(hr))
    goto done;
  D3D11_INPUT_ELEMENT_DESC elements[2] = {
      {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0,
       (UINT)offsetof(gpui_vertex, position), D3D11_INPUT_PER_VERTEX_DATA, 0},
      {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0,
       (UINT)offsetof(gpui_vertex, color), D3D11_INPUT_PER_VERTEX_DATA, 0},
  };
  hr = ID3D11Device_CreateInputLayout(
      host->device, elements, 2, ID3D10Blob_GetBufferPointer(vertex_blob),
      ID3D10Blob_GetBufferSize(vertex_blob), &host->input_layout);
  if (FAILED(hr))
    goto done;

  D3D11_BLEND_DESC blend;
  ZeroMemory(&blend, sizeof(blend));
  blend.RenderTarget[0].BlendEnable = TRUE;
  blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
  blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  hr = ID3D11Device_CreateBlendState(host->device, &blend,
                                     &host->blend_state);
  if (FAILED(hr))
    goto done;

  D3D11_RASTERIZER_DESC rasterizer;
  ZeroMemory(&rasterizer, sizeof(rasterizer));
  rasterizer.FillMode = D3D11_FILL_SOLID;
  rasterizer.CullMode = D3D11_CULL_NONE;
  rasterizer.ScissorEnable = TRUE;
  rasterizer.DepthClipEnable = TRUE;
  hr = ID3D11Device_CreateRasterizerState(host->device, &rasterizer,
                                          &host->rasterizer_state);

done:
  if (vertex_blob)
    ID3D10Blob_Release(vertex_blob);
  if (pixel_blob)
    ID3D10Blob_Release(pixel_blob);
  return hr;
}

static HRESULT create_gpu(gpui_windows_host *host) {
  if (!host->hwnd || host->pixel_width <= 0 || host->pixel_height <= 0)
    return E_INVALIDARG;
  DXGI_SWAP_CHAIN_DESC swap_desc;
  ZeroMemory(&swap_desc, sizeof(swap_desc));
  swap_desc.BufferDesc.Width = (UINT)host->pixel_width;
  swap_desc.BufferDesc.Height = (UINT)host->pixel_height;
  swap_desc.BufferDesc.RefreshRate.Numerator = 60;
  swap_desc.BufferDesc.RefreshRate.Denominator = 1;
  swap_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  swap_desc.SampleDesc.Count = 1;
  swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  swap_desc.BufferCount = 2;
  swap_desc.OutputWindow = host->hwnd;
  swap_desc.Windowed = TRUE;
  swap_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL actual_level = D3D_FEATURE_LEVEL_10_0;
  HRESULT hr = host->api.d3d11_create_device_and_swap_chain(
      NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels,
      (UINT)(sizeof(levels) / sizeof(levels[0])), D3D11_SDK_VERSION,
      &swap_desc, &host->swap_chain, &host->device, &actual_level,
      &host->context);
  if (FAILED(hr)) {
    release_gpu(host);
    hr = host->api.d3d11_create_device_and_swap_chain(
        NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, levels,
        (UINT)(sizeof(levels) / sizeof(levels[0])), D3D11_SDK_VERSION,
        &swap_desc, &host->swap_chain, &host->device, &actual_level,
        &host->context);
  }
  if (FAILED(hr)) {
    release_gpu(host);
    return hr;
  }
  hr = create_pipeline(host);
  if (SUCCEEDED(hr))
    hr = create_render_target(host);
  if (SUCCEEDED(hr)) {
    D3D11_QUERY_DESC query_desc;
    query_desc.Query = D3D11_QUERY_EVENT;
    query_desc.MiscFlags = 0;
    hr = ID3D11Device_CreateQuery(host->device, &query_desc,
                                  &host->frame_query);
  }
  if (FAILED(hr))
    release_gpu(host);
  return hr;
}

static HRESULT resize_gpu(gpui_windows_host *host, int32_t width,
                          int32_t height) {
  if (!host->swap_chain || width <= 0 || height <= 0)
    return S_OK;
  if (width == host->pixel_width && height == host->pixel_height &&
      host->render_target)
    return S_OK;
  GPUI_RELEASE(ID3D11Texture2D, host->staging_texture);
  host->staging_width = 0;
  host->staging_height = 0;
  ID3D11DeviceContext_ClearState(host->context);
  GPUI_RELEASE(ID3D11RenderTargetView, host->render_target);
  HRESULT hr = IDXGISwapChain_ResizeBuffers(host->swap_chain, 0,
                                             (UINT)width, (UINT)height,
                                             DXGI_FORMAT_UNKNOWN, 0);
  if (FAILED(hr))
    return hr;
  host->pixel_width = width;
  host->pixel_height = height;
  hr = create_render_target(host);
  return hr;
}

static BOOL finite_frame_value(double value) {
  return isfinite(value) && fabs(value) <= 1.0e20;
}

static int32_t ensure_vertex_capacity(gpui_windows_host *host, UINT vertices) {
  if (vertices <= host->vertex_capacity)
    return GPUI_WINDOWS_OK;
  UINT capacity = host->vertex_capacity ? host->vertex_capacity : 64;
  while (capacity < vertices) {
    if (capacity > (UINT)(GPUI_MAX_QUADS * 6) / 2) {
      capacity = (UINT)(GPUI_MAX_QUADS * 6);
      break;
    }
    capacity *= 2;
  }
  if (capacity < vertices || capacity > (UINT)(GPUI_MAX_QUADS * 6))
    return GPUI_WINDOWS_RESOURCE;
  uint64_t byte_width = (uint64_t)capacity * sizeof(gpui_vertex);
  if (byte_width > UINT32_MAX)
    return GPUI_WINDOWS_RESOURCE;
  D3D11_BUFFER_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.ByteWidth = (UINT)byte_width;
  desc.Usage = D3D11_USAGE_DYNAMIC;
  desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ID3D11Buffer *buffer = NULL;
  HRESULT hr = ID3D11Device_CreateBuffer(host->device, &desc, NULL, &buffer);
  if (FAILED(hr))
    return GPUI_WINDOWS_RESOURCE;
  GPUI_RELEASE(ID3D11Buffer, host->vertex_buffer);
  host->vertex_buffer = buffer;
  host->vertex_capacity = capacity;
  return GPUI_WINDOWS_OK;
}

static int32_t map_hresult(HRESULT hr) {
  if (SUCCEEDED(hr))
    return GPUI_WINDOWS_OK;
  if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET ||
      hr == DXGI_ERROR_DEVICE_HUNG || hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR)
    return GPUI_WINDOWS_DEVICE_LOST;
  return GPUI_WINDOWS_SURFACE_LOST;
}

static int32_t logical_to_physical_floor(double value, double scale) {
  double result = value * scale;
  if (!isfinite(result) || result < -1.0e7 || result > 1.0e7)
    return 0;
  return (int32_t)floor(result);
}

static int32_t logical_to_physical_ceil(double value, double scale) {
  double result = value * scale;
  if (!isfinite(result) || result < -1.0e7 || result > 1.0e7)
    return 0;
  return (int32_t)ceil(result);
}

static int32_t readback_frame(gpui_windows_host *host) {
  if (!host->readback_enabled)
    return GPUI_WINDOWS_OK;
  ID3D11Texture2D *back_buffer = NULL;
  HRESULT hr = IDXGISwapChain_GetBuffer(host->swap_chain, 0,
                                        &gpui_iid_texture2d,
                                        (void **)&back_buffer);
  if (FAILED(hr))
    return map_hresult(hr);
  D3D11_TEXTURE2D_DESC desc;
  ID3D11Texture2D_GetDesc(back_buffer, &desc);
  if (!host->staging_texture || host->staging_width != desc.Width ||
      host->staging_height != desc.Height) {
    GPUI_RELEASE(ID3D11Texture2D, host->staging_texture);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    hr = ID3D11Device_CreateTexture2D(host->device, &desc, NULL,
                                      &host->staging_texture);
    if (FAILED(hr)) {
      ID3D11Texture2D_Release(back_buffer);
      return GPUI_WINDOWS_RESOURCE;
    }
    host->staging_width = desc.Width;
    host->staging_height = desc.Height;
  }
  ID3D11DeviceContext_CopyResource(host->context,
                                   (ID3D11Resource *)host->staging_texture,
                                   (ID3D11Resource *)back_buffer);
  ID3D11Texture2D_Release(back_buffer);
  ID3D11DeviceContext_Flush(host->context);
  D3D11_MAPPED_SUBRESOURCE mapped;
  hr = ID3D11DeviceContext_Map(host->context,
                               (ID3D11Resource *)host->staging_texture, 0,
                               D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr))
    return map_hresult(hr);
  const int32_t samples[3][2] = {
      {1, 1},
      {host->pixel_width / 4, host->pixel_height / 3},
      {host->pixel_width - 2, host->pixel_height - 2},
  };
  for (int32_t i = 0; i < 3; ++i) {
    int32_t x = samples[i][0];
    int32_t y = samples[i][1];
    if (x < 0)
      x = 0;
    if (y < 0)
      y = 0;
    if (x >= host->pixel_width)
      x = host->pixel_width - 1;
    if (y >= host->pixel_height)
      y = host->pixel_height - 1;
    const uint8_t *pixel = (const uint8_t *)mapped.pData +
                           (size_t)y * mapped.RowPitch + (size_t)x * 4;
    for (int32_t channel = 0; channel < 4; ++channel)
      host->readback_rgba[i * 4 + channel] = pixel[channel];
  }
  ID3D11DeviceContext_Unmap(host->context,
                            (ID3D11Resource *)host->staging_texture, 0);
  host->readback_valid = TRUE;
  return GPUI_WINDOWS_OK;
}

static int32_t present_frame(gpui_windows_host *host, const double *data,
                             int32_t length) {
  if (host->state != 0)
    return GPUI_WINDOWS_STOPPING;
  if (host->error)
    return (int32_t)host->error;
  if (host->frame_pending)
    return GPUI_WINDOWS_BUSY;
  if (length < 5 || (length - 5) % GPUI_WINDOWS_QUAD_STRIDE != 0 || !data)
    return GPUI_WINDOWS_INVALID;
  int32_t item_count = (length - 5) / GPUI_WINDOWS_QUAD_STRIDE;
  if (item_count > GPUI_MAX_QUADS)
    return GPUI_WINDOWS_RESOURCE;
  for (int32_t i = 0; i < length; ++i)
    if (!finite_frame_value(data[i]))
      return GPUI_WINDOWS_INVALID;
  if (data[0] != 0 || data[1] != 0)
    return GPUI_WINDOWS_UNSUPPORTED;
  if (data[2] <= 0 || data[3] <= 0 || data[4] <= 0)
    return GPUI_WINDOWS_INVALID;
  if (data[2] != host->logical_width || data[3] != host->logical_height ||
      data[4] != host->scale)
    return GPUI_WINDOWS_BUSY;
  RECT client;
  if (!host->api.get_client_rect(host->hwnd, &client))
    return GPUI_WINDOWS_NATIVE;
  int32_t pixel_width = client.right - client.left;
  int32_t pixel_height = client.bottom - client.top;
  HRESULT hr = resize_gpu(host, pixel_width, pixel_height);
  if (FAILED(hr))
    return map_hresult(hr);
  if (!host->render_target || pixel_width <= 0 || pixel_height <= 0)
    return GPUI_WINDOWS_BUSY;
  int32_t status = ensure_vertex_capacity(host, (UINT)item_count * 6);
  if (status != GPUI_WINDOWS_OK)
    return status;
  D3D11_MAPPED_SUBRESOURCE mapped;
  ZeroMemory(&mapped, sizeof(mapped));
  if (item_count > 0) {
    hr = ID3D11DeviceContext_Map(host->context,
                                 (ID3D11Resource *)host->vertex_buffer, 0,
                                 D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr))
      return map_hresult(hr);
  }
  gpui_vertex *vertices = (gpui_vertex *)mapped.pData;
  for (int32_t item = 0; item < item_count; ++item) {
    const double *q = data + 5 + item * GPUI_WINDOWS_QUAD_STRIDE;
    if (q[2] < 0 || q[3] < 0 || q[14] < 0 || q[14] > 1 || q[17] < 0 ||
        q[18] < 0) {
      if (item_count > 0)
        ID3D11DeviceContext_Unmap(host->context,
                                  (ID3D11Resource *)host->vertex_buffer, 0);
      return GPUI_WINDOWS_INVALID;
    }
    for (int32_t c = 4; c < 8; ++c)
      if (q[c] < 0 || q[c] > 255) {
        if (item_count > 0)
          ID3D11DeviceContext_Unmap(host->context,
                                    (ID3D11Resource *)host->vertex_buffer, 0);
        return GPUI_WINDOWS_INVALID;
      }
    float alpha = (float)(q[7] / 255.0 * q[14]);
    float color[4] = {(float)(q[4] / 255.0) * alpha,
                      (float)(q[5] / 255.0) * alpha,
                      (float)(q[6] / 255.0) * alpha, alpha};
    const double corners[6][2] = {
        {q[0], q[1]}, {q[0] + q[2], q[1]},
        {q[0] + q[2], q[1] + q[3]}, {q[0], q[1]},
        {q[0] + q[2], q[1] + q[3]}, {q[0], q[1] + q[3]},
    };
    for (int32_t v = 0; v < 6; ++v) {
      double x = corners[v][0];
      double y = corners[v][1];
      double tx = q[8] * x + q[10] * y + q[12];
      double ty = q[9] * x + q[11] * y + q[13];
      if (!finite_frame_value(tx) || !finite_frame_value(ty)) {
        if (item_count > 0)
          ID3D11DeviceContext_Unmap(host->context,
                                    (ID3D11Resource *)host->vertex_buffer, 0);
        return GPUI_WINDOWS_INVALID;
      }
      gpui_vertex *vertex = &vertices[item * 6 + v];
      vertex->position[0] = (float)(2.0 * tx / host->logical_width - 1.0);
      vertex->position[1] = (float)(1.0 - 2.0 * ty / host->logical_height);
      memcpy(vertex->color, color, sizeof(color));
    }
  }
  if (item_count > 0)
    ID3D11DeviceContext_Unmap(host->context,
                              (ID3D11Resource *)host->vertex_buffer, 0);

  ID3D11DeviceContext_OMSetRenderTargets(host->context, 1,
                                         &host->render_target, NULL);
  const float clear[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  ID3D11DeviceContext_ClearRenderTargetView(host->context,
                                            host->render_target, clear);
  D3D11_VIEWPORT viewport;
  viewport.TopLeftX = 0.0f;
  viewport.TopLeftY = 0.0f;
  viewport.Width = (float)pixel_width;
  viewport.Height = (float)pixel_height;
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;
  ID3D11DeviceContext_RSSetViewports(host->context, 1, &viewport);
  ID3D11DeviceContext_RSSetState(host->context, host->rasterizer_state);
  ID3D11DeviceContext_OMSetBlendState(host->context, host->blend_state, NULL,
                                      0xffffffffu);
  ID3D11DeviceContext_VSSetShader(host->context, host->vertex_shader, NULL, 0);
  ID3D11DeviceContext_PSSetShader(host->context, host->pixel_shader, NULL, 0);
  ID3D11DeviceContext_IASetInputLayout(host->context, host->input_layout);
  ID3D11DeviceContext_IASetPrimitiveTopology(
      host->context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  if (item_count > 0) {
    UINT stride = sizeof(gpui_vertex);
    UINT offset = 0;
    ID3D11DeviceContext_IASetVertexBuffers(host->context, 0, 1,
                                           &host->vertex_buffer, &stride,
                                           &offset);
  }
  for (int32_t item = 0; item < item_count; ++item) {
    const double *q = data + 5 + item * GPUI_WINDOWS_QUAD_STRIDE;
    double left = fmin(host->logical_width, fmax(0.0, q[15]));
    double top = fmin(host->logical_height, fmax(0.0, q[16]));
    double right = fmax(0.0, fmin(host->logical_width, q[15] + q[17]));
    double bottom = fmax(0.0, fmin(host->logical_height, q[16] + q[18]));
    D3D11_RECT scissor;
    scissor.left = logical_to_physical_floor(left, host->scale);
    scissor.top = logical_to_physical_floor(top, host->scale);
    scissor.right = logical_to_physical_ceil(right, host->scale);
    scissor.bottom = logical_to_physical_ceil(bottom, host->scale);
    if (scissor.left < 0)
      scissor.left = 0;
    if (scissor.top < 0)
      scissor.top = 0;
    if (scissor.right > pixel_width)
      scissor.right = pixel_width;
    if (scissor.bottom > pixel_height)
      scissor.bottom = pixel_height;
    ID3D11DeviceContext_RSSetScissorRects(host->context, 1, &scissor);
    if (scissor.right > scissor.left && scissor.bottom > scissor.top)
      ID3D11DeviceContext_Draw(host->context, 6, (UINT)item * 6);
  }
  status = readback_frame(host);
  if (status != GPUI_WINDOWS_OK)
    return status;
  ID3D11DeviceContext_End(host->context, (ID3D11Asynchronous *)host->frame_query);
  hr = IDXGISwapChain_Present(host->swap_chain, 1, 0);
  if (FAILED(hr)) {
    host->frame_pending = FALSE;
    return map_hresult(hr);
  }
  host->frame_pending = TRUE;
  return GPUI_WINDOWS_OK;
}

static int32_t poll_frame_completion(gpui_windows_host *host) {
  if (!host->frame_pending || !host->context || !host->frame_query)
    return GPUI_WINDOWS_OK;
  BOOL complete = FALSE;
  HRESULT hr = ID3D11DeviceContext_GetData(
      host->context, (ID3D11Asynchronous *)host->frame_query, &complete,
      sizeof(complete), D3D11_ASYNC_GETDATA_DONOTFLUSH);
  if (hr == S_OK && complete) {
    host->frame_pending = FALSE;
    emit_event(host, 5, 0, 0, 0, 0);
    return GPUI_WINDOWS_OK;
  }
  if (hr == S_FALSE)
    return GPUI_WINDOWS_OK;
  if (FAILED(hr))
    return map_hresult(hr);
  return GPUI_WINDOWS_OK;
}

static int32_t modifiers_from_message(gpui_windows_host *host, WPARAM wparam) {
  SHORT shift = host->api.get_key_state(VK_SHIFT);
  SHORT control = host->api.get_key_state(VK_CONTROL);
  SHORT alt = host->api.get_key_state(VK_MENU);
  SHORT meta_left = host->api.get_key_state(VK_LWIN);
  SHORT meta_right = host->api.get_key_state(VK_RWIN);
  return (((wparam & MK_SHIFT) || (shift & 0x8000)) ? 1 : 0) |
         (((wparam & MK_CONTROL) || (control & 0x8000)) ? 2 : 0) |
         ((alt & 0x8000) ? 4 : 0) |
         (((meta_left | meta_right) & 0x8000) ? 8 : 0);
}

static int32_t key_symbol_from_vk(WPARAM key) {
  switch (key) {
  case VK_RETURN:
    return 0xff0d;
  case VK_ESCAPE:
    return 0xff1b;
  case VK_BACK:
    return 0xff08;
  case VK_DELETE:
    return 0xffff;
  case VK_TAB:
    return 0xff09;
  case VK_SPACE:
    return 0x20;
  case VK_LEFT:
    return 0xff51;
  case VK_UP:
    return 0xff52;
  case VK_RIGHT:
    return 0xff53;
  case VK_DOWN:
    return 0xff54;
  case VK_HOME:
    return 0xff50;
  case VK_END:
    return 0xff57;
  case VK_PRIOR:
    return 0xff55;
  case VK_NEXT:
    return 0xff56;
  default:
    return 0;
  }
}

static void emit_character(gpui_windows_host *host, uint32_t scalar,
                            int32_t mods) {
  if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
    InterlockedExchange(&host->error, GPUI_WINDOWS_INVALID);
    return;
  }
  emit_event(host, 11, (double)scalar, 0, 0, mods);
}

static UINT mouse_button_bit(UINT message, WPARAM wparam) {
  switch (message) {
  case WM_LBUTTONDOWN:
  case WM_LBUTTONUP:
    return GPUI_MOUSE_LEFT;
  case WM_RBUTTONDOWN:
  case WM_RBUTTONUP:
    return GPUI_MOUSE_RIGHT;
  case WM_MBUTTONDOWN:
  case WM_MBUTTONUP:
    return GPUI_MOUSE_MIDDLE;
  case WM_XBUTTONDOWN:
  case WM_XBUTTONUP:
    return HIWORD(wparam) == XBUTTON1 ? GPUI_MOUSE_X1
                                     : HIWORD(wparam) == XBUTTON2
                                           ? GPUI_MOUSE_X2
                                           : 0;
  default:
    return 0;
  }
}

static UINT update_mouse_buttons(UINT buttons, UINT message, WPARAM wparam) {
  UINT bit = mouse_button_bit(message, wparam);
  switch (message) {
  case WM_LBUTTONDOWN:
  case WM_RBUTTONDOWN:
  case WM_MBUTTONDOWN:
  case WM_XBUTTONDOWN:
    return buttons | bit;
  case WM_LBUTTONUP:
  case WM_RBUTTONUP:
  case WM_MBUTTONUP:
  case WM_XBUTTONUP:
    return buttons & ~bit;
  default:
    return buttons;
  }
}

static LRESULT CALLBACK gpui_window_proc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  gpui_windows_host *host = (gpui_windows_host *)
      g_host.api.get_window_long_ptr_w(hwnd, GWLP_USERDATA);
  if (message == WM_NCCREATE) {
    CREATESTRUCTW *create = (CREATESTRUCTW *)lparam;
    host = (gpui_windows_host *)create->lpCreateParams;
    if (host)
      g_host.api.set_window_long_ptr_w(hwnd, GWLP_USERDATA,
                                       (LONG_PTR)host);
  }
  if (!host || host != &g_host || host->hwnd != hwnd ||
      host->window_id <= 0) {
    if (message == WM_NCCREATE)
      return TRUE;
    return host ? host->api.def_window_proc_w(hwnd, message, wparam, lparam)
                : 0;
  }
  if (host->destroying && message != WM_NCDESTROY)
    return host->api.def_window_proc_w(hwnd, message, wparam, lparam);
  switch (message) {
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT: {
    PAINTSTRUCT paint;
    host->api.begin_paint(hwnd, &paint);
    host->api.end_paint(hwnd, &paint);
    return 0;
  }
  case WM_SIZE: {
    int32_t width = LOWORD(lparam);
    int32_t height = HIWORD(lparam);
    if (wparam != SIZE_MINIMIZED && width > 0 && height > 0) {
      HRESULT hr = resize_gpu(host, width, height);
      if (FAILED(hr))
        InterlockedExchange(&host->error, map_hresult(hr));
      host->pixel_width = width;
      host->pixel_height = height;
      host->logical_width = (double)width / host->scale;
      host->logical_height = (double)height / host->scale;
      emit_event(host, 1, 0, 0, 0, 0);
    }
    return 0;
  }
  case WM_DPICHANGED: {
    UINT dpi = HIWORD(wparam);
    if (dpi == 0)
      dpi = LOWORD(wparam);
    if (dpi == 0)
      dpi = 96;
    double scale = (double)dpi / 96.0;
    BOOL changed = scale != host->scale;
    host->dpi = dpi;
    host->scale = scale;
    if (changed)
      emit_event(host, 2, 0, 0, 0, 0);
    RECT *suggested = (RECT *)lparam;
    host->api.set_window_pos(hwnd, NULL, suggested->left, suggested->top,
                             suggested->right - suggested->left,
                             suggested->bottom - suggested->top,
                             SWP_NOZORDER | SWP_NOACTIVATE);
    return 0;
  }
  case WM_SETFOCUS:
    emit_event(host, 6, 0, 0, 1, 0);
    return 0;
  case WM_KILLFOCUS:
    emit_event(host, 6, 0, 0, 0, 0);
    host->pending_high_surrogate = 0;
    host->mouse_buttons = 0;
    return 0;
  case WM_CAPTURECHANGED:
    host->mouse_buttons = 0;
    return 0;
  case WM_CLOSE:
    emit_event(host, 3, 0, 0, 0, 0);
    return 0;
  case WM_MOUSEMOVE: {
    if (!host->mouse_tracking) {
      TRACKMOUSEEVENT tracking;
      tracking.cbSize = sizeof(tracking);
      tracking.dwFlags = TME_LEAVE;
      tracking.hwndTrack = hwnd;
      tracking.dwHoverTime = 0;
      host->api.track_mouse_event(&tracking);
      host->mouse_tracking = TRUE;
    }
    double x = (double)(short)LOWORD(lparam) / host->scale;
    double y = (double)(short)HIWORD(lparam) / host->scale;
    emit_event(host, 7, x, y, 0, modifiers_from_message(host, wparam));
    return 0;
  }
  case WM_MOUSELEAVE:
    host->mouse_tracking = FALSE;
    return 0;
  case WM_LBUTTONDOWN:
  case WM_RBUTTONDOWN:
  case WM_MBUTTONDOWN:
  case WM_XBUTTONDOWN: {
    host->mouse_buttons =
        update_mouse_buttons(host->mouse_buttons, message, wparam);
    host->api.set_capture(hwnd);
    int32_t button = message == WM_LBUTTONDOWN ? 0
                     : message == WM_RBUTTONDOWN ? 1
                     : message == WM_MBUTTONDOWN ? 2
                     : HIWORD(wparam) == XBUTTON1 ? 3
                                                  : 4;
    emit_event(host, 8, (double)(short)LOWORD(lparam) / host->scale,
               (double)(short)HIWORD(lparam) / host->scale, button,
               modifiers_from_message(host, wparam));
    return message == WM_XBUTTONDOWN ? TRUE : 0;
  }
  case WM_LBUTTONUP:
  case WM_RBUTTONUP:
  case WM_MBUTTONUP:
  case WM_XBUTTONUP: {
    int32_t button = message == WM_LBUTTONUP ? 0
                     : message == WM_RBUTTONUP ? 1
                     : message == WM_MBUTTONUP ? 2
                     : HIWORD(wparam) == XBUTTON1 ? 3
                                                  : 4;
    emit_event(host, 9, (double)(short)LOWORD(lparam) / host->scale,
               (double)(short)HIWORD(lparam) / host->scale, button,
               modifiers_from_message(host, wparam));
    host->mouse_buttons =
        update_mouse_buttons(host->mouse_buttons, message, wparam);
    if (host->mouse_buttons == 0)
      host->api.release_capture();
    return message == WM_XBUTTONUP ? TRUE : 0;
  }
  case WM_MOUSEWHEEL:
  case WM_MOUSEHWHEEL: {
    POINT point = {(short)LOWORD(lparam), (short)HIWORD(lparam)};
    host->api.screen_to_client(hwnd, &point);
    double delta = (double)(short)HIWORD(wparam) / WHEEL_DELTA * 40.0;
    int32_t horizontal = message == WM_MOUSEHWHEEL ? 1 : 0;
    emit_event(host, 10, (double)point.x / host->scale,
               (double)point.y / host->scale, horizontal,
               modifiers_from_message(host, wparam));
    int32_t at = (host->event_read + host->event_count - 1) %
                GPUI_EVENT_CAPACITY;
    host->events[at][4] = delta;
    return 0;
  }
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN:
  case WM_KEYUP:
  case WM_SYSKEYUP: {
    int32_t symbol = key_symbol_from_vk(wparam);
    if (symbol != 0)
      emit_event(host,
                 (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) ? 11 : 12,
                 0, 0, symbol,
                 modifiers_from_message(host, 0));
    if (message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)
      return host->api.def_window_proc_w(hwnd, message, wparam, lparam);
    return 0;
  }
  case WM_CHAR: {
    WCHAR unit = (WCHAR)wparam;
    int32_t mods = modifiers_from_message(host, 0);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      host->pending_high_surrogate = unit;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      if (host->pending_high_surrogate) {
        uint32_t scalar = 0x10000u +
                          (((uint32_t)host->pending_high_surrogate - 0xd800u)
                           << 10) +
                          ((uint32_t)unit - 0xdc00u);
        host->pending_high_surrogate = 0;
        emit_character(host, scalar, mods);
      } else {
        InterlockedExchange(&host->error, GPUI_WINDOWS_INVALID);
      }
    } else {
      host->pending_high_surrogate = 0;
      emit_character(host, unit, mods);
    }
    return 0;
  }
  case WM_UNICHAR:
    if (wparam == UNICODE_NOCHAR)
      return TRUE;
    emit_character(host, (uint32_t)wparam, modifiers_from_message(host, 0));
    return 0;
  case WM_SETCURSOR:
    if (LOWORD(lparam) == HTCLIENT) {
      host->api.set_cursor(host->cursor);
      return TRUE;
    }
    break;
  case WM_NCDESTROY:
    host->mouse_buttons = 0;
    host->mouse_tracking = FALSE;
    host->api.set_window_long_ptr_w(hwnd, GWLP_USERDATA, 0);
    break;
  default:
    break;
  }
  return host->api.def_window_proc_w(hwnd, message, wparam, lparam);
}

int32_t gpui_windows_start(int32_t abi_version) {
  if (abi_version != GPUI_WINDOWS_ABI)
    return -GPUI_WINDOWS_INVALID;
  AcquireSRWLockExclusive(&g_host_lifecycle_lock);
  if (InterlockedCompareExchange(&g_host_claimed, 1, 0) != 0)
    goto busy;
  ZeroMemory(&g_host, sizeof(g_host));
  g_host.token = InterlockedIncrement(&g_next_host);
  if (g_host.token <= 0) {
    InterlockedExchange(&g_host_claimed, 0);
    ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
    return -GPUI_WINDOWS_RESOURCE;
  }
  g_host.owner_thread = GetCurrentThreadId();
  g_host.instance = GetModuleHandleW(NULL);
  g_host.scale = 1.0;
  g_host.dpi = 96;
  const char *readback = getenv("GPUI_WINDOWS_READBACK");
  g_host.readback_enabled = readback && strcmp(readback, "1") == 0;
  int32_t status = api_init(&g_host);
  if (status != GPUI_WINDOWS_OK)
    goto fail;
  DPI_AWARENESS_CONTEXT per_monitor_v2 =
      (DPI_AWARENESS_CONTEXT)(intptr_t)-4;
  if (!g_host.api.set_process_dpi_awareness_context(per_monitor_v2)) {
    /* Windows rejects a second process-awareness assignment. Allow restart
     * and embedding only when the existing thread context is already exactly
     * per-monitor-v2; a merely system-aware process would corrupt our logical
     * pixel/scale contract. */
    DPI_AWARENESS_CONTEXT current =
        g_host.api.get_thread_dpi_awareness_context();
    if (!g_host.api.are_dpi_awareness_contexts_equal(current,
                                                      per_monitor_v2)) {
      status = GPUI_WINDOWS_UNSUPPORTED;
      goto fail;
    }
  }
  UINT dpi = g_host.api.get_dpi_for_system();
  if (dpi != 0) {
    g_host.dpi = dpi;
    g_host.scale = (double)dpi / 96.0;
  }
  WNDCLASSEXW klass;
  ZeroMemory(&klass, sizeof(klass));
  klass.cbSize = sizeof(klass);
  klass.style = CS_OWNDC;
  klass.lpfnWndProc = gpui_window_proc;
  klass.hInstance = g_host.instance;
  klass.lpszClassName = GPUI_CLASS_NAME;
  if (!g_host.api.register_class_ex_w(&klass)) {
    status = GetLastError() == ERROR_CLASS_ALREADY_EXISTS
                 ? GPUI_WINDOWS_BUSY
                 : GPUI_WINDOWS_NATIVE;
    goto fail;
  }
  g_host.class_registered = TRUE;
  MSG message;
  g_host.api.peek_message_w(&message, NULL, WM_USER, WM_USER, PM_NOREMOVE);
  InterlockedExchange(&g_host.state, 0);
  int32_t token = g_host.token;
  ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
  return token;

fail:
  if (g_host.class_registered)
    g_host.api.unregister_class_w(GPUI_CLASS_NAME, g_host.instance);
  api_release(&g_host);
  InterlockedExchange(&g_host.state, 2);
  InterlockedExchange(&g_host_claimed, 0);
  ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
  return -status;

busy:
  ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
  return -GPUI_WINDOWS_BUSY;
}

int32_t gpui_windows_state(int32_t token) {
  AcquireSRWLockShared(&g_host_lifecycle_lock);
  int32_t result = valid_token(token)
                       ? (int32_t)InterlockedCompareExchange(&g_host.state, 0, 0)
                       : 2;
  ReleaseSRWLockShared(&g_host_lifecycle_lock);
  return result;
}

int32_t gpui_windows_wake(int32_t token) {
  AcquireSRWLockShared(&g_host_lifecycle_lock);
  int32_t status = check_host_locked(token, FALSE);
  if (status == GPUI_WINDOWS_OK &&
      !g_host.api.post_thread_message_w(g_host.owner_thread,
                                        GPUI_WAKE_MESSAGE, (WPARAM)token, 0))
    status = GPUI_WINDOWS_NATIVE;
  ReleaseSRWLockShared(&g_host_lifecycle_lock);
  return status;
}

int32_t gpui_windows_exit(int32_t token) {
  AcquireSRWLockShared(&g_host_lifecycle_lock);
  int32_t status = check_host_locked(token, FALSE);
  if (status == GPUI_WINDOWS_OK) {
    InterlockedCompareExchange(&g_host.state, 1, 0);
    if (!g_host.api.post_thread_message_w(g_host.owner_thread,
                                          GPUI_EXIT_MESSAGE, (WPARAM)token,
                                          0))
      status = GPUI_WINDOWS_NATIVE;
  }
  ReleaseSRWLockShared(&g_host_lifecycle_lock);
  return status;
}

static BOOL adjust_outer_rect(gpui_windows_host *host, RECT *rect, DWORD style,
                              DWORD ex_style) {
  if (host->api.adjust_window_rect_ex_for_dpi)
    return host->api.adjust_window_rect_ex_for_dpi(rect, style, FALSE, ex_style,
                                                    host->dpi);
  return host->api.adjust_window_rect_ex(rect, style, FALSE, ex_style);
}

int32_t gpui_windows_create(int32_t token, int32_t width, int32_t height,
                            const uint8_t *title, int32_t title_length) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (g_host.state != 0)
    return -GPUI_WINDOWS_STOPPING;
  if (g_host.hwnd)
    return -GPUI_WINDOWS_BUSY;
  if (width < 1 || height < 1 || width > 16384 || height > 16384)
    return -GPUI_WINDOWS_INVALID;
  WCHAR *wide_title = NULL;
  int32_t wide_length = 0;
  status = utf8_to_wide(title, title_length, &wide_title, &wide_length);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  int32_t window_id = InterlockedIncrement(&g_next_window);
  if (window_id <= 0) {
    free(wide_title);
    return -GPUI_WINDOWS_RESOURCE;
  }
  g_host.window_id = window_id;
  g_host.sequence = 0;
  g_host.mouse_buttons = 0;
  g_host.pending_high_surrogate = 0;
  RECT outer = {0, 0, (LONG)ceil(width * g_host.scale),
                (LONG)ceil(height * g_host.scale)};
  DWORD style = WS_OVERLAPPEDWINDOW;
  if (!adjust_outer_rect(&g_host, &outer, style, 0)) {
    free(wide_title);
    g_host.window_id = 0;
    return -GPUI_WINDOWS_NATIVE;
  }
  HWND hwnd = g_host.api.create_window_ex_w(
      0, GPUI_CLASS_NAME, wide_title, style, CW_USEDEFAULT, CW_USEDEFAULT,
      outer.right - outer.left, outer.bottom - outer.top, NULL, NULL,
      g_host.instance, &g_host);
  free(wide_title);
  if (!hwnd) {
    g_host.window_id = 0;
    return -GPUI_WINDOWS_NATIVE;
  }
  g_host.hwnd = hwnd;
  UINT dpi = g_host.api.get_dpi_for_window(hwnd);
  if (dpi != 0) {
    g_host.dpi = dpi;
    g_host.scale = (double)dpi / 96.0;
  }
  RECT client;
  if (!g_host.api.get_client_rect(hwnd, &client)) {
    g_host.destroying = TRUE;
    g_host.api.destroy_window(hwnd);
    g_host.hwnd = NULL;
    g_host.window_id = 0;
    g_host.destroying = FALSE;
    return -GPUI_WINDOWS_NATIVE;
  }
  g_host.pixel_width = client.right - client.left;
  g_host.pixel_height = client.bottom - client.top;
  g_host.logical_width = (double)g_host.pixel_width / g_host.scale;
  g_host.logical_height = (double)g_host.pixel_height / g_host.scale;
  HRESULT hr = create_gpu(&g_host);
  if (FAILED(hr)) {
    g_host.destroying = TRUE;
    release_gpu(&g_host);
    g_host.api.destroy_window(hwnd);
    g_host.hwnd = NULL;
    g_host.window_id = 0;
    g_host.destroying = FALSE;
    return -map_hresult(hr);
  }
  emit_event(&g_host, 0, 0, 0, 0, 0);
  g_host.api.show_window(hwnd, SW_SHOW);
  g_host.api.update_window(hwnd);
  return window_id;
}

int32_t gpui_windows_close(int32_t token, int32_t window) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return g_host.api.post_message_w(g_host.hwnd, WM_CLOSE, 0, 0)
             ? GPUI_WINDOWS_OK
             : GPUI_WINDOWS_NATIVE;
}

int32_t gpui_windows_destroy(int32_t token, int32_t window) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (window <= 0)
    return GPUI_WINDOWS_STALE;
  if (window == g_host.last_destroyed_window)
    return GPUI_WINDOWS_OK;
  if (g_host.window_id != window || !g_host.hwnd)
    return GPUI_WINDOWS_STALE;
  HWND hwnd = g_host.hwnd;
  g_host.destroying = TRUE;
  discard_events_for(&g_host, window);
  release_gpu(&g_host);
  if (!g_host.api.destroy_window(hwnd)) {
    g_host.destroying = FALSE;
    return GPUI_WINDOWS_NATIVE;
  }
  emit_event_for(&g_host, window, 4, 0, 0, 0, 0);
  g_host.last_destroyed_window = window;
  g_host.hwnd = NULL;
  g_host.window_id = 0;
  g_host.destroying = FALSE;
  g_host.mouse_buttons = 0;
  g_host.pixel_width = 0;
  g_host.pixel_height = 0;
  g_host.logical_width = 0;
  g_host.logical_height = 0;
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_title(int32_t token, int32_t window,
                           const uint8_t *title, int32_t title_length) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  WCHAR *wide_title = NULL;
  int32_t wide_length = 0;
  status = utf8_to_wide(title, title_length, &wide_title, &wide_length);
  if (status != GPUI_WINDOWS_OK)
    return status;
  BOOL ok = g_host.api.set_window_text_w(g_host.hwnd, wide_title);
  free(wide_title);
  return ok ? GPUI_WINDOWS_OK : GPUI_WINDOWS_NATIVE;
}

int32_t gpui_windows_size(int32_t token, int32_t window, int32_t width,
                          int32_t height) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (width < 1 || height < 1 || width > 16384 || height > 16384)
    return GPUI_WINDOWS_INVALID;
  RECT outer = {0, 0, (LONG)ceil(width * g_host.scale),
                (LONG)ceil(height * g_host.scale)};
  if (!adjust_outer_rect(&g_host, &outer, WS_OVERLAPPEDWINDOW, 0))
    return GPUI_WINDOWS_NATIVE;
  if (!g_host.api.set_window_pos(
          g_host.hwnd, NULL, 0, 0, outer.right - outer.left,
          outer.bottom - outer.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    return GPUI_WINDOWS_NATIVE;
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_metrics(int32_t token, int32_t window, double *metrics) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (!metrics)
    return GPUI_WINDOWS_INVALID;
  metrics[0] = g_host.logical_width;
  metrics[1] = g_host.logical_height;
  metrics[2] = g_host.scale;
  return GPUI_WINDOWS_OK;
}

/* CI-only deterministic WM_SIZE probe. phase 0 sends SIZE_MINIMIZED, phase 1
 * sends a zero-sized restore message, and phase 2 restores the cached size. */
int32_t gpui_windows_test_size_message(int32_t token, int32_t window,
                                       int32_t phase) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  int32_t old_width = g_host.pixel_width;
  int32_t old_height = g_host.pixel_height;
  double old_logical_width = g_host.logical_width;
  double old_logical_height = g_host.logical_height;
  int32_t old_event_count = g_host.event_count;
  if (phase == 0) {
    g_host.api.send_message_w(g_host.hwnd, WM_SIZE, SIZE_MINIMIZED, 0);
  } else if (phase == 1) {
    g_host.api.send_message_w(g_host.hwnd, WM_SIZE, SIZE_RESTORED, 0);
  } else if (phase == 2) {
    if (old_width <= 0 || old_height <= 0 || old_width > 65535 ||
        old_height > 65535)
      return GPUI_WINDOWS_INVALID;
    g_host.api.send_message_w(g_host.hwnd, WM_SIZE, SIZE_RESTORED,
                              MAKELPARAM(old_width, old_height));
  } else {
    return GPUI_WINDOWS_INVALID;
  }

  if (phase < 2) {
    return g_host.pixel_width == old_width &&
                   g_host.pixel_height == old_height &&
                   g_host.logical_width == old_logical_width &&
                   g_host.logical_height == old_logical_height &&
                   g_host.event_count == old_event_count
               ? GPUI_WINDOWS_OK
               : GPUI_WINDOWS_NATIVE;
  }
  int32_t at = (g_host.event_read + g_host.event_count - 1) %
               GPUI_EVENT_CAPACITY;
  return g_host.pixel_width == old_width &&
                 g_host.pixel_height == old_height &&
                 g_host.logical_width == old_logical_width &&
                 g_host.logical_height == old_logical_height &&
                 g_host.event_count == old_event_count + 1 &&
                 (int32_t)g_host.events[at][0] == 1
             ? GPUI_WINDOWS_OK
             : GPUI_WINDOWS_NATIVE;
}

static BOOL mouse_probe_matches(gpui_windows_host *host, UINT buttons,
                                BOOL captured) {
  return host->mouse_buttons == buttons &&
         ((host->api.get_capture() == host->hwnd) == captured);
}

/* CI-only probe that sends real Win32 input messages directly through the
 * current window procedure and checks capture retention after each release. */
int32_t gpui_windows_test_mouse_capture(int32_t token, int32_t window) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (g_host.mouse_buttons != 0 || g_host.api.get_capture() == g_host.hwnd)
    return GPUI_WINDOWS_BUSY;

#define GPUI_MOUSE_PROBE_STEP(message_value, wparam_value, buttons, captured)  \
  do {                                                                        \
    g_host.api.send_message_w(g_host.hwnd, (message_value), (wparam_value),   \
                              MAKELPARAM(12, 14));                              \
    if (!mouse_probe_matches(&g_host, (buttons), (captured)))                 \
      goto mouse_probe_failed;                                                \
  } while (0)

  GPUI_MOUSE_PROBE_STEP(WM_LBUTTONDOWN,
                        MK_LBUTTON | MK_SHIFT | MK_CONTROL,
                        GPUI_MOUSE_LEFT, TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_RBUTTONDOWN, MK_LBUTTON | MK_RBUTTON,
                        GPUI_MOUSE_LEFT | GPUI_MOUSE_RIGHT, TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_LBUTTONUP,
                        MK_RBUTTON | MK_SHIFT | MK_CONTROL,
                        GPUI_MOUSE_RIGHT, TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_RBUTTONUP, 0, 0, FALSE);
  GPUI_MOUSE_PROBE_STEP(WM_XBUTTONDOWN,
                        MAKEWPARAM(MK_XBUTTON1, XBUTTON1), GPUI_MOUSE_X1,
                        TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_XBUTTONDOWN,
                        MAKEWPARAM(MK_XBUTTON1 | MK_XBUTTON2, XBUTTON2),
                        GPUI_MOUSE_X1 | GPUI_MOUSE_X2, TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_XBUTTONUP,
                        MAKEWPARAM(MK_XBUTTON2, XBUTTON1), GPUI_MOUSE_X2,
                        TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_XBUTTONUP, MAKEWPARAM(0, XBUTTON2), 0, FALSE);
  GPUI_MOUSE_PROBE_STEP(WM_MBUTTONDOWN, MK_MBUTTON, GPUI_MOUSE_MIDDLE, TRUE);
  GPUI_MOUSE_PROBE_STEP(WM_MBUTTONUP, 0, 0, FALSE);

  GPUI_MOUSE_PROBE_STEP(WM_LBUTTONDOWN, MK_LBUTTON, GPUI_MOUSE_LEFT, TRUE);
  g_host.api.send_message_w(g_host.hwnd, WM_CAPTURECHANGED, 0, 0);
  if (g_host.mouse_buttons != 0)
    goto mouse_probe_failed;
  if (g_host.api.get_capture() == g_host.hwnd)
    g_host.api.release_capture();
  if (g_host.api.get_capture() == g_host.hwnd)
    goto mouse_probe_failed;

  GPUI_MOUSE_PROBE_STEP(WM_LBUTTONDOWN, MK_LBUTTON, GPUI_MOUSE_LEFT, TRUE);
  g_host.api.send_message_w(g_host.hwnd, WM_KILLFOCUS, 0, 0);
  if (g_host.mouse_buttons != 0)
    goto mouse_probe_failed;
  if (g_host.api.get_capture() == g_host.hwnd)
    g_host.api.release_capture();
  if (g_host.api.get_capture() == g_host.hwnd)
    goto mouse_probe_failed;

#undef GPUI_MOUSE_PROBE_STEP
  return GPUI_WINDOWS_OK;

mouse_probe_failed:
#undef GPUI_MOUSE_PROBE_STEP
  g_host.mouse_buttons = 0;
  if (g_host.api.get_capture() == g_host.hwnd)
    g_host.api.release_capture();
  return GPUI_WINDOWS_NATIVE;
}

/* Called after the E2E destroys its window to verify teardown cleared input. */
int32_t gpui_windows_test_mouse_destroy_reset(int32_t token, int32_t window) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return !g_host.hwnd && g_host.last_destroyed_window == window &&
                 g_host.mouse_buttons == 0
             ? GPUI_WINDOWS_OK
             : GPUI_WINDOWS_NATIVE;
}

/* Arms one held button immediately before the public destroy-path assertion. */
int32_t gpui_windows_test_mouse_arm_destroy(int32_t token, int32_t window) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (g_host.mouse_buttons != 0 || g_host.api.get_capture() == g_host.hwnd)
    return GPUI_WINDOWS_BUSY;
  g_host.api.send_message_w(g_host.hwnd, WM_LBUTTONDOWN, MK_LBUTTON,
                            MAKELPARAM(12, 14));
  if (mouse_probe_matches(&g_host, GPUI_MOUSE_LEFT, TRUE))
    return GPUI_WINDOWS_OK;
  g_host.mouse_buttons = 0;
  if (g_host.api.get_capture() == g_host.hwnd)
    g_host.api.release_capture();
  return GPUI_WINDOWS_NATIVE;
}

typedef struct gpui_wrong_thread_probe {
  int32_t token;
  int32_t window;
  int32_t result;
} gpui_wrong_thread_probe;

static DWORD WINAPI run_wrong_thread_probe(LPVOID opaque) {
  gpui_wrong_thread_probe *probe = (gpui_wrong_thread_probe *)opaque;
  double metrics[3];
  probe->result = gpui_windows_metrics(probe->token, probe->window, metrics);
  return 0;
}

int32_t gpui_windows_test_wrong_thread(int32_t token, int32_t window) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  gpui_wrong_thread_probe probe = {token, window, GPUI_WINDOWS_NATIVE};
  HANDLE thread = CreateThread(NULL, 0, run_wrong_thread_probe, &probe, 0, NULL);
  if (!thread)
    return GPUI_WINDOWS_RESOURCE;
  DWORD wait = WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
  if (wait != WAIT_OBJECT_0)
    return GPUI_WINDOWS_NATIVE;
  return probe.result == GPUI_WINDOWS_WRONG_THREAD ? GPUI_WINDOWS_OK
                                                   : GPUI_WINDOWS_NATIVE;
}

typedef struct gpui_wake_stop_probe {
  int32_t token;
  volatile LONG started;
  volatile LONG failure;
} gpui_wake_stop_probe;

static DWORD WINAPI run_wake_stop_probe(LPVOID opaque) {
  gpui_wake_stop_probe *probe = (gpui_wake_stop_probe *)opaque;
  int32_t status = gpui_windows_wake(probe->token);
  if (status != GPUI_WINDOWS_OK) {
    InterlockedExchange(&probe->failure, status + 1);
    InterlockedExchange(&probe->started, 1);
    return 0;
  }
  InterlockedExchange(&probe->started, 1);

  /* Keep wake calls in flight while the owner tears down the host. A wake may
   * either post before stop acquires the exclusive lifecycle lock or observe
   * the invalidated token after stop; no other status is valid. */
  for (int32_t attempt = 0; attempt < 2000; ++attempt) {
    status = gpui_windows_wake(probe->token);
    if (status == GPUI_WINDOWS_STALE)
      break;
    if (status != GPUI_WINDOWS_OK) {
      InterlockedExchange(&probe->failure, status + 1);
      break;
    }
    SwitchToThread();
  }
  return 0;
}

/* Opt-in E2E probe: a worker posts wake messages while the owner stops the
 * host. The caller should use this only after destroying any test window. */
int32_t gpui_windows_test_wake_stop_race(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  gpui_wake_stop_probe probe = {token, 0, 0};
  HANDLE thread = CreateThread(NULL, 0, run_wake_stop_probe, &probe, 0, NULL);
  if (!thread)
    return GPUI_WINDOWS_RESOURCE;
  while (InterlockedCompareExchange(&probe.started, 0, 0) == 0)
    SwitchToThread();

  int32_t stop_status = gpui_windows_stop(token);
  DWORD wait = WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
  if (wait != WAIT_OBJECT_0 || stop_status != GPUI_WINDOWS_OK ||
      InterlockedCompareExchange(&probe.failure, 0, 0) != 0)
    return GPUI_WINDOWS_NATIVE;
  return GPUI_WINDOWS_OK;
}

static int32_t dispatch_messages(gpui_windows_host *host, int32_t timeout_ms) {
  if (timeout_ms < 0 || timeout_ms > 60000)
    return GPUI_WINDOWS_INVALID;
  MSG message;
  int32_t completion_status = poll_frame_completion(host);
  if (completion_status != GPUI_WINDOWS_OK)
    return completion_status;
  /* Probe without consuming: the dispatch loop below must see the first
   * queued message too (notably a lone posted WM_CLOSE or host wake). */
  BOOL got = host->api.peek_message_w(&message, NULL, 0, 0, PM_NOREMOVE);
  DWORD wait_ms = (DWORD)timeout_ms;
  if (host->frame_pending && wait_ms > 8)
    wait_ms = 8;
  if (!got && wait_ms > 0)
    host->api.msg_wait_for_multiple_objects(0, NULL, FALSE,
                                           wait_ms, QS_ALLINPUT);
  while (host->api.peek_message_w(&message, NULL, 0, 0, PM_REMOVE)) {
    if (message.message == WM_QUIT) {
      InterlockedCompareExchange(&host->state, 1, 0);
      emit_event(host, 14, 0, 0, 0, 0);
      continue;
    }
    if (message.message == GPUI_WAKE_MESSAGE) {
      if (message.wParam != (WPARAM)host->token)
        continue;
      emit_event(host, 13, 0, 0, 0, 0);
      continue;
    }
    if (message.message == GPUI_EXIT_MESSAGE) {
      if (message.wParam != (WPARAM)host->token)
        continue;
      emit_event(host, 14, 0, 0, 0, 0);
      continue;
    }
    host->api.translate_message(&message);
    host->api.dispatch_message_w(&message);
  }
  completion_status = poll_frame_completion(host);
  if (completion_status != GPUI_WINDOWS_OK)
    return completion_status;
  if (host->error)
    return (int32_t)host->error;
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_dispatch(int32_t token, int32_t timeout_ms) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return dispatch_messages(&g_host, timeout_ms);
}

int32_t gpui_windows_next(int32_t token, double *event_data) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (!event_data)
    return -GPUI_WINDOWS_INVALID;
  if (g_host.error)
    return -(int32_t)g_host.error;
  if (g_host.event_count == 0)
    return 0;
  memcpy(event_data, g_host.events[g_host.event_read],
         sizeof(g_host.events[g_host.event_read]));
  g_host.event_read = (g_host.event_read + 1) % GPUI_EVENT_CAPACITY;
  g_host.event_count--;
  return 1;
}

int32_t gpui_windows_present(int32_t token, int32_t window,
                             const double *frame_data, int32_t length) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  /* Process queued DPI/resize messages before deciding if this snapshot fits. */
  status = dispatch_messages(&g_host, 0);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return present_frame(&g_host, frame_data, length);
}

int32_t gpui_windows_recover(int32_t token, int32_t window) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (window != g_host.window_id || !g_host.hwnd)
    return GPUI_WINDOWS_STALE;
  if (g_host.state != 0)
    return GPUI_WINDOWS_STOPPING;
  release_gpu(&g_host);
  HRESULT hr = create_gpu(&g_host);
  if (FAILED(hr)) {
    release_gpu(&g_host);
    return map_hresult(hr);
  }
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_cursor(int32_t token, int32_t cursor) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (cursor < 0 || cursor > 2)
    return GPUI_WINDOWS_INVALID;
  LPCWSTR name = cursor == 1 ? MAKEINTRESOURCEW(32649)
                 : cursor == 2 ? MAKEINTRESOURCEW(32513)
                               : MAKEINTRESOURCEW(32512);
  HCURSOR native_cursor = g_host.api.load_cursor_w(NULL, name);
  if (!native_cursor)
    return GPUI_WINDOWS_NATIVE;
  g_host.cursor = native_cursor;
  if (g_host.hwnd)
    g_host.api.set_cursor(native_cursor);
  return GPUI_WINDOWS_OK;
}

static int32_t clipboard_utf16_to_utf8(const WCHAR *wide,
                                       SIZE_T allocated_bytes,
                                       uint8_t *output, int32_t capacity) {
  if (!wide || capacity < 0 || (capacity > 0 && !output))
    return -GPUI_WINDOWS_INVALID;
  if (allocated_bytes < sizeof(WCHAR) ||
      allocated_bytes % sizeof(WCHAR) != 0)
    return -GPUI_WINDOWS_CONVERSION;
  size_t allocated_units = allocated_bytes / sizeof(WCHAR);
  size_t wide_length = 0;
  while (wide_length < allocated_units &&
         wide_length < 16u * 1024u * 1024u && wide[wide_length] != 0)
    ++wide_length;
  if (wide_length == allocated_units)
    return -GPUI_WINDOWS_CONVERSION;
  if (wide_length >= 16u * 1024u * 1024u)
    return -GPUI_WINDOWS_RESOURCE;
  int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide,
                                     (int)wide_length, NULL, 0, NULL, NULL);
  if (required == 0 && wide_length > 0)
    return -GPUI_WINDOWS_CONVERSION;
  if (capacity == 0)
    return required;
  if (capacity < required)
    return -GPUI_WINDOWS_RESOURCE;
  if (required > 0 && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide,
                                          (int)wide_length, (LPSTR)output,
                                          capacity, NULL, NULL) != required)
    return -GPUI_WINDOWS_CONVERSION;
  return required;
}

int32_t gpui_windows_clipboard_read(int32_t token, uint8_t *output,
                                    int32_t capacity) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (capacity < 0 || (capacity > 0 && !output))
    return -GPUI_WINDOWS_INVALID;
  if (!g_host.api.open_clipboard(g_host.hwnd))
    return -GPUI_WINDOWS_BUSY;
  HANDLE handle = g_host.api.get_clipboard_data(CF_UNICODETEXT);
  if (!handle) {
    g_host.api.close_clipboard();
    return -GPUI_WINDOWS_UNSUPPORTED;
  }
  const WCHAR *wide = (const WCHAR *)GlobalLock(handle);
  if (!wide) {
    g_host.api.close_clipboard();
    return -GPUI_WINDOWS_NATIVE;
  }
  int32_t result = clipboard_utf16_to_utf8(
      wide, GlobalSize(handle), output, capacity);
  GlobalUnlock(handle);
  g_host.api.close_clipboard();
  return result;
}

int32_t gpui_windows_test_clipboard_validation(void) {
  const WCHAR unterminated[] = {(WCHAR)'x', (WCHAR)'y'};
  const WCHAR invalid_surrogate[] = {(WCHAR)0xd800, (WCHAR)0};
  uint8_t output[8];
  int32_t result = clipboard_utf16_to_utf8(
      unterminated, sizeof(unterminated), output, sizeof(output));
  if (result != -GPUI_WINDOWS_CONVERSION)
    return GPUI_WINDOWS_NATIVE;
  result = clipboard_utf16_to_utf8(invalid_surrogate,
                                   sizeof(invalid_surrogate), output,
                                   sizeof(output));
  return result == -GPUI_WINDOWS_CONVERSION ? GPUI_WINDOWS_OK
                                             : GPUI_WINDOWS_NATIVE;
}

int32_t gpui_windows_clipboard_write(int32_t token, const uint8_t *text,
                                     int32_t length) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  WCHAR *wide = NULL;
  int32_t wide_length = 0;
  status = utf8_to_wide(text, length, &wide, &wide_length);
  if (status != GPUI_WINDOWS_OK)
    return status;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE,
                               ((SIZE_T)wide_length + 1) * sizeof(WCHAR));
  if (!memory) {
    free(wide);
    return GPUI_WINDOWS_RESOURCE;
  }
  WCHAR *target = (WCHAR *)GlobalLock(memory);
  if (!target) {
    GlobalFree(memory);
    free(wide);
    return GPUI_WINDOWS_RESOURCE;
  }
  memcpy(target, wide, ((size_t)wide_length + 1) * sizeof(WCHAR));
  GlobalUnlock(memory);
  free(wide);
  if (!g_host.api.open_clipboard(g_host.hwnd)) {
    GlobalFree(memory);
    return GPUI_WINDOWS_BUSY;
  }
  if (!g_host.api.empty_clipboard()) {
    g_host.api.close_clipboard();
    GlobalFree(memory);
    return GPUI_WINDOWS_NATIVE;
  }
  HANDLE transferred = g_host.api.set_clipboard_data(CF_UNICODETEXT, memory);
  g_host.api.close_clipboard();
  if (!transferred) {
    GlobalFree(memory);
    return GPUI_WINDOWS_NATIVE;
  }
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_readback(int32_t token, int32_t window, double *rgba) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (window != g_host.window_id || !g_host.hwnd)
    return GPUI_WINDOWS_STALE;
  if (!rgba)
    return GPUI_WINDOWS_INVALID;
  if (!g_host.readback_enabled)
    return GPUI_WINDOWS_UNSUPPORTED;
  if (!g_host.readback_valid)
    return GPUI_WINDOWS_BUSY;
  memcpy(rgba, g_host.readback_rgba, sizeof(g_host.readback_rgba));
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_stop(int32_t token) {
  AcquireSRWLockExclusive(&g_host_lifecycle_lock);
  if (!valid_token(token)) {
    int32_t result = token > 0 && token == g_host.token && g_host.state == 2
                         ? GPUI_WINDOWS_OK
                         : GPUI_WINDOWS_STALE;
    ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
    return result;
  }
  int32_t status = check_host_locked(token, TRUE);
  if (status != GPUI_WINDOWS_OK) {
    ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
    return status;
  }
  InterlockedExchange(&g_host.state, 1);
  if (g_host.hwnd) {
    int32_t window_id = g_host.window_id;
    HWND hwnd = g_host.hwnd;
    g_host.destroying = TRUE;
    discard_events_for(&g_host, window_id);
    release_gpu(&g_host);
    if (!g_host.api.destroy_window(hwnd)) {
      g_host.destroying = FALSE;
      ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
      return GPUI_WINDOWS_NATIVE;
    }
    emit_event_for(&g_host, window_id, 4, 0, 0, 0, 0);
    g_host.hwnd = NULL;
    g_host.window_id = 0;
    g_host.destroying = FALSE;
  }
  if (g_host.class_registered) {
    g_host.api.unregister_class_w(GPUI_CLASS_NAME, g_host.instance);
    g_host.class_registered = FALSE;
  }
  api_release(&g_host);
  InterlockedExchange(&g_host.state, 2);
  InterlockedExchange(&g_host_claimed, 0);
  ReleaseSRWLockExclusive(&g_host_lifecycle_lock);
  return GPUI_WINDOWS_OK;
}

#else

/* Keep the public package and its deterministic event/scene tests buildable on
 * non-Windows native hosts. These stubs deliberately never claim a window or
 * GPU frame; native evidence is collected only by the Windows workflow. */
int32_t gpui_windows_start(int32_t abi_version) {
  (void)abi_version;
  return -GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_stop(int32_t host) {
  (void)host;
  return GPUI_WINDOWS_OK;
}
int32_t gpui_windows_state(int32_t host) {
  (void)host;
  return 2;
}
int32_t gpui_windows_wake(int32_t host) {
  (void)host;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_exit(int32_t host) {
  (void)host;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_create(int32_t host, int32_t width, int32_t height,
                            const uint8_t *title, int32_t title_length) {
  (void)host;
  (void)width;
  (void)height;
  (void)title;
  (void)title_length;
  return -GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_close(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_destroy(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_title(int32_t host, int32_t window, const uint8_t *title,
                           int32_t title_length) {
  (void)host;
  (void)window;
  (void)title;
  (void)title_length;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_size(int32_t host, int32_t window, int32_t width,
                          int32_t height) {
  (void)host;
  (void)window;
  (void)width;
  (void)height;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_metrics(int32_t host, int32_t window, double *metrics) {
  (void)host;
  (void)window;
  (void)metrics;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_dispatch(int32_t host, int32_t timeout_ms) {
  (void)host;
  (void)timeout_ms;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_next(int32_t host, double *event_data) {
  (void)host;
  (void)event_data;
  return -GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_present(int32_t host, int32_t window,
                             const double *frame_data, int32_t length) {
  (void)host;
  (void)window;
  (void)frame_data;
  (void)length;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_recover(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_cursor(int32_t host, int32_t cursor) {
  (void)host;
  (void)cursor;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_clipboard_read(int32_t host, uint8_t *output,
                                    int32_t capacity) {
  (void)host;
  (void)output;
  (void)capacity;
  return -GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_clipboard_write(int32_t host, const uint8_t *text,
                                     int32_t length) {
  (void)host;
  (void)text;
  (void)length;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_readback(int32_t host, int32_t window, double *rgba) {
  (void)host;
  (void)window;
  (void)rgba;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_wrong_thread(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_wake_stop_race(int32_t host) {
  (void)host;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_clipboard_validation(void) {
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_size_message(int32_t host, int32_t window,
                                       int32_t phase) {
  (void)host;
  (void)window;
  (void)phase;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_mouse_capture(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_mouse_arm_destroy(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}
int32_t gpui_windows_test_mouse_destroy_reset(int32_t host, int32_t window) {
  (void)host;
  (void)window;
  return GPUI_WINDOWS_UNSUPPORTED;
}

#endif
