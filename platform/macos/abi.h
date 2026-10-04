#ifndef GPUI_MACOS_ABI_H
#define GPUI_MACOS_ABI_H
#include <stdint.h>
// Versioned function table, borrowed only by the native loader. Payload bytes
// are borrowed for one call. No MoonBit address is retained by the dylib.
typedef struct {
  uint32_t abi_version, struct_size;
  int32_t (*call)(int32_t, int64_t, double, double, const uint8_t *, int32_t);
  int64_t (*integer)(int32_t);
  double (*number)(int32_t);
} GpuiApi;
// 0 success; otherwise diagnostics.ErrorCode ordinal + 1.
// Ops: 0 validate host epoch, 1 start, 2 stop, 3 create, 4 title, 5 size, 6 pump,
// 7 request-close, 8 destroy, 9 present, 10 wake, 11 request-exit,
// 12 cursor, 13 read clipboard, 14 write clipboard, 15 window metrics,
// 16 explicit renderer recreation.
// Integer fields: 0 result token, 1 event kind, 2 event token, 3 sequence,
// 4 modifiers, 5 button/key, 6 repeat, 7 ABI version, 8 UTF-8 output length, 9 host epoch,
// 100+i UTF-8 output byte i. Output remains owned by the shim until the next call.
// Number fields: 0 scale, 1 x, 2 y, 3 width, 4 height.
#endif
