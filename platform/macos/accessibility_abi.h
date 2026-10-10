#ifndef GPUI_MACOS_ACCESSIBILITY_ABI_H
#define GPUI_MACOS_ACCESSIBILITY_ABI_H

#include <stdint.h>

/* Byte-oriented, versioned extensions kept outside the shared GpuiApi table. */
int32_t gpui_macos_ax_publish_v1(int64_t window_token,
                                 int64_t existing_binding_token,
                                 const uint8_t *bytes, int32_t length,
                                 int64_t *out_binding_token);
int32_t gpui_macos_ax_revoke_v1(int64_t window_token,
                                int64_t binding_token);
int32_t gpui_macos_ax_take_request_v1(int64_t window_token,
                                     int64_t *out_binding_token);

/* Stable loader shims called by the macOS package FFI. */
int32_t gpui_macos_ax_publish(int64_t window_token,
                              int64_t existing_binding_token,
                              const uint8_t *bytes, int32_t length,
                              int64_t *out_binding_token);
int32_t gpui_macos_ax_revoke(int64_t window_token, int64_t binding_token);
int32_t gpui_macos_ax_take_request(int64_t window_token,
                                   int64_t *out_binding_token);

#endif
