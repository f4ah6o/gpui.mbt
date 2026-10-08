#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include "abi.h"
#include "../macos_text/macos_text.h"

@interface GPWindow : NSObject <NSWindowDelegate>
@property NSWindow *window;
@property CAMetalLayer *surface;
@property int64_t token, sequence;
@property double scale;
@property BOOL closing;
@end
@interface GPView : NSView
@property(weak) GPWindow *owner;
@end
static NSMutableDictionary<NSNumber *, GPWindow *> *windows;
static NSMutableArray<NSDictionary *> *events;
static NSDictionary *current;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static id<MTLTexture> white_mask_texture;
static int64_t next_token, result_token, host_epoch;
static NSData *text_result;
static int state; // 0 uninitialized/stopped, 1 running, 2 quiescing
static BOOL overflow;
#ifdef GPUI_TESTING
static NSData *frame_pixels;
static NSUInteger frame_width, frame_height, frame_stride;
static int64_t frame_window_token;
static double frame_scale;
static double test_scale_override;
#endif
static void emit(GPWindow *w, int kind, double x, double y, int mods, int code, int repeat) {
  if (w.closing && kind != 13) return;
  if (events.count >= 4096) { overflow = YES; return; }
  int64_t sequence = w ? ++w.sequence : 0;
  [events addObject:@{@"kind":@(kind), @"token":@(w ? w.token : 0), @"seq":@(sequence),
    @"scale":@(w ? w.scale : 1), @"x":@(x), @"y":@(y), @"mods":@(mods), @"code":@(code), @"repeat":@(repeat),
    @"width":@(w ? w.window.contentView.bounds.size.width : 0), @"height":@(w ? w.window.contentView.bounds.size.height : 0)}];
}
static void resize_surface(GPWindow *w) {
  double scale = w.window.backingScaleFactor;
#ifdef GPUI_TESTING
  if (test_scale_override > 0) scale = test_scale_override;
#endif
  BOOL changed = scale != w.scale;
  w.scale = scale;
  w.surface.contentsScale = scale;
  NSSize size = w.window.contentView.bounds.size;
  w.surface.drawableSize = CGSizeMake(MAX(1, ceil(size.width * scale)), MAX(1, ceil(size.height * scale)));
  if (changed) emit(w, 4, 0, 0, 0, 0, 0);
}
@implementation GPWindow
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; emit(self, 12, 0, 0, 0, 0, 0); return NO; }
- (void)windowDidResize:(NSNotification *)note { (void)note; resize_surface(self); emit(self, 2, 0, 0, 0, 0, 0); }
- (void)windowDidMove:(NSNotification *)note { (void)note; resize_surface(self); emit(self, 3, self.window.frame.origin.x, self.window.frame.origin.y, 0, 0, 0); }
- (void)windowDidChangeBackingProperties:(NSNotification *)note { (void)note; resize_surface(self); }
- (void)windowDidBecomeKey:(NSNotification *)note { (void)note; emit(self, 5, 0, 0, 0, 0, 0); }
- (void)windowDidResignKey:(NSNotification *)note { (void)note; emit(self, 6, 0, 0, 0, 0, 0); }
@end
static int modifiers(NSEvent *event) {
  NSUInteger f = event.modifierFlags;
  return ((f & NSEventModifierFlagShift) ? 1 : 0) | ((f & NSEventModifierFlagControl) ? 2 : 0) |
    ((f & NSEventModifierFlagOption) ? 4 : 0) | ((f & NSEventModifierFlagCommand) ? 8 : 0);
}
@implementation GPView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
  for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
  [super updateTrackingAreas];
}
- (void)pointer:(NSEvent *)event kind:(int)kind {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  emit(owner, kind, p.x, p.y, modifiers(event), (int)event.buttonNumber, 0);
}
- (void)mouseMoved:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)mouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)rightMouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)otherMouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)mouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)rightMouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)otherMouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)mouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)rightMouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)otherMouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)keyDown:(NSEvent *)e { [self key:e kind:10]; }
- (void)keyUp:(NSEvent *)e { [self key:e kind:11]; }
- (void)key:(NSEvent *)e kind:(int)kind {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  NSUInteger before = events.count;
  emit(owner, kind, 0, 0, modifiers(e), e.keyCode, e.isARepeat);
  if (events.count > before) {
    NSMutableDictionary *event = [events.lastObject mutableCopy];
    event[@"text"] = [e.charactersIgnoringModifiers dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    events[events.count-1] = event;
  }
}
@end
@interface GPApplicationDelegate : NSObject <NSApplicationDelegate>
@end
@implementation GPApplicationDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  (void)sender;
  if (state == 1) { state = 2; emit(nil, 15, 0, 0, 0, 0, 0); }
  return NSTerminateCancel;
}
@end
static GPApplicationDelegate *app_delegate;
static void destroy(GPWindow *w) {
  w.closing = YES;
  // Drop queued callbacks for this generation before the terminal notification.
  NSIndexSet *indices = [events indexesOfObjectsPassingTest:^BOOL(NSDictionary *e, NSUInteger i, BOOL *stop) {
    (void)i; (void)stop; return [e[@"token"] longLongValue] == w.token;
  }];
  [events removeObjectsAtIndexes:indices];
  w.window.delegate = nil;
  ((GPView *)w.window.contentView).owner = nil;
  w.window.contentView.layer = nil;
  w.surface = nil;
  [w.window close];
  emit(w, 13, 0, 0, 0, 0, 0);
  [windows removeObjectForKey:@(w.token)];
  w.window = nil;
}
static int setup_gpu(void) {
  white_mask_texture = nil;
  device = MTLCreateSystemDefaultDevice();
  if (!device) return 16;
  queue = [device newCommandQueue];
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p; float4 c; float2 uv; uint textured; uint padding; };\nstruct O { float4 p [[position]]; float4 c; float2 uv; uint textured [[flat]]; };\nvertex O vmain(const device V *v [[buffer(0)]], uint i [[vertex_id]]) { O o; o.p=v[i].p; o.c=v[i].c; o.uv=v[i].uv; o.textured=v[i].textured; return o; }\nfragment float4 fmain(O o [[stage_in]], texture2d<float> mask [[texture(0)]]) { constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear); float coverage=o.textured ? mask.sample(s,o.uv).r : 1.0; return float4(o.c.rgb,o.c.a*coverage); }";
  NSError *error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  if (!library || !queue) return 16;
  MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
  desc.vertexFunction = [library newFunctionWithName:@"vmain"];
  desc.fragmentFunction = [library newFunctionWithName:@"fmain"];
  MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingEnabled = YES;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (!pipeline) return 16;
  MTLTextureDescriptor *white_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
  white_desc.usage = MTLTextureUsageShaderRead;
  white_desc.storageMode = MTLStorageModeShared;
  white_mask_texture = [device newTextureWithDescriptor:white_desc];
  if (!white_mask_texture) return 16;
  const uint8_t white = 255;
  [white_mask_texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:1];
  return 0;
}
static int recover_renderer(void) {
  /* Frames are submitted synchronously, so no command buffer retains a layer
   * or drawable when this operation begins. Replace the shared device graph,
   * then attach the new device to every live window before publishing success. */
  pipeline = nil;
  queue = nil;
  device = nil;
  white_mask_texture = nil;
  int status = setup_gpu();
  if (status) {
    pipeline = nil;
    queue = nil;
    device = nil;
    white_mask_texture = nil;
    return status;
  }
  for (GPWindow *window in windows.allValues) {
    window.surface.device = device;
    resize_surface(window);
  }
  return 0;
}
typedef struct { float position[4], color[4], uv[2]; uint32_t textured, padding; } Vertex;
_Static_assert(sizeof(Vertex) == 48, "Metal vertex layout must be 48 bytes");
typedef struct { Vertex v[6]; MTLScissorRect clip; NSUInteger texture_index; } Draw;
static double n(NSDictionary *d, NSString *key) { return [d[key] doubleValue]; }
static CGRect rect(NSDictionary *d) { return CGRectMake(n(d,@"x"), n(d,@"y"), n(d,@"width"), n(d,@"height")); }
static BOOL valid_json_number(id value) {
  return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static BOOL valid_json_numeric_fields(NSDictionary *object, NSArray<NSString *> *keys) {
  if (![object isKindOfClass:NSDictionary.class]) return NO;
  for (NSString *key in keys) if (!valid_json_number(object[key])) return NO;
  return YES;
}
static int text_native_status(int status) {
  if (status == 3 || status == 17) return 13;
  if (status == 7 || status == 11 || status == 12 || status == 15 || status == 16) return 5;
  if (status == 14 || status == 8 || status == 10) return 9;
  return status ? 16 : 0;
}
static id<MTLTexture> text_mask_texture(NSString *text, double font_size, double scale,
                                        CGRect bounds, NSPoint origin, CGRect *draw_bounds,
                                        float uv[4], BOOL *empty, int *error) {
  NSData *utf8 = nil;
  *empty = NO;
  *error = 0;
  if (![text isKindOfClass:NSString.class] || text.length > 4096 ||
      !isfinite(font_size) || font_size <= 0 || font_size > 32 ||
      !isfinite(scale) || scale < 1 || scale > 8) {
    *error = 5; return nil;
  }
  utf8 = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  if (!utf8 || utf8.length > 4096) { *error = 5; return nil; }
  GpuiMacosTextMask mask = {0};
  int native_status = gpui_macos_text_raster_v1(utf8.bytes, (int32_t)utf8.length, font_size, scale, &mask);
  if (native_status) { *error = text_native_status(native_status); gpui_macos_text_raster_free(&mask); return nil; }
  if (!mask.width || !mask.height || !mask.pixels) {
    *empty = YES; gpui_macos_text_raster_free(&mask); return nil;
  }
  if (mask.width > 16384 || mask.height > 2048 || (int64_t)mask.width * mask.height > 8 * 1024 * 1024 || mask.stride < mask.width) {
    *error = 13; gpui_macos_text_raster_free(&mask); return nil;
  }
  double left = origin.x + mask.left, top = origin.y + mask.top;
  double right = left + (double)mask.width / scale, bottom = top + (double)mask.height / scale;
  if (!isfinite(left) || !isfinite(top) || !isfinite(right) || !isfinite(bottom)) {
    *error = 5; gpui_macos_text_raster_free(&mask); return nil;
  }
  double crop_left = MAX(0, ceil((CGRectGetMinX(bounds) - left) * scale - 0.5));
  double crop_top = MAX(0, ceil((CGRectGetMinY(bounds) - top) * scale - 0.5));
  double crop_right = MIN(mask.width, ceil((CGRectGetMaxX(bounds) - left) * scale - 0.5));
  double crop_bottom = MIN(mask.height, ceil((CGRectGetMaxY(bounds) - top) * scale - 0.5));
  if (crop_right <= crop_left || crop_bottom <= crop_top) {
    *empty = YES; gpui_macos_text_raster_free(&mask); return nil;
  }
  NSUInteger x0 = (NSUInteger)crop_left, y0 = (NSUInteger)crop_top;
  NSUInteger width = (NSUInteger)(crop_right - crop_left), height = (NSUInteger)(crop_bottom - crop_top);
  if ((int64_t)width * height > 8 * 1024 * 1024) { *error = 13; gpui_macos_text_raster_free(&mask); return nil; }
  NSMutableData *cropped = [NSMutableData dataWithLength:width * height];
  if (!cropped) { *error = 13; gpui_macos_text_raster_free(&mask); return nil; }
  const uint8_t *source = mask.pixels;
  uint8_t *destination = cropped.mutableBytes;
  for (NSUInteger y = 0; y < height; y++)
    memcpy(destination + y * width, source + (y0 + y) * (NSUInteger)mask.stride + x0, width);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  if (!texture) { *error = 13; gpui_macos_text_raster_free(&mask); return nil; }
  [texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:cropped.bytes bytesPerRow:width];
  *draw_bounds = CGRectMake(left + (double)x0 / scale, top + (double)y0 / scale,
                            (double)width / scale, (double)height / scale);
  uv[0] = 0; uv[1] = 0; uv[2] = 1; uv[3] = 1;
  gpui_macos_text_raster_free(&mask);
  return texture;
}
static int present(GPWindow *w, const uint8_t *bytes, int32_t len) {
  if (!device || !queue || !pipeline) return 16;
  NSDictionary *scene = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:len] options:0 error:nil];
  if (![scene isKindOfClass:NSDictionary.class] || [scene[@"schema_version"] intValue] != 1) return 5;
  if ([scene[@"resources"] count] != 0) return 9;
  resize_surface(w);
  CGRect viewport = rect(scene[@"viewport"]);
  if (viewport.origin.x != 0 || viewport.origin.y != 0 || viewport.size.width <= 0 || viewport.size.height <= 0 ||
      viewport.size.width != w.window.contentView.bounds.size.width || viewport.size.height != w.window.contentView.bounds.size.height ||
      n(scene,@"scale") != w.scale) return 5;
  NSArray *items = scene[@"items"];
  if (items.count > 65536) return 13;
  NSMutableData *data = [NSMutableData dataWithLength:sizeof(Draw) * items.count];
  if (!data) return 13;
  Draw *draws = data.mutableBytes;
  NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray new];
  if (!white_mask_texture) return 16;
  [textures addObject:white_mask_texture];
  NSUInteger count = 0;
  NSUInteger text_allocation = 0;
  for (NSDictionary *item in items) {
    if (![item isKindOfClass:NSDictionary.class]) return 5;
    NSString *kind = item[@"kind"];
    if (![kind isKindOfClass:NSString.class]) return 5;
    BOOL is_text_run = [kind isEqual:@"text_run"];
    BOOL is_text = is_text_run || [kind isEqual:@"text"];
    if (!is_text && ![kind isEqual:@"quad"]) return 9;
    NSDictionary *bounds_value = item[@"bounds"];
    if (!valid_json_numeric_fields(bounds_value, @[@"x", @"y", @"width", @"height"])) return 5;
    CGRect item_bounds = rect(bounds_value), bounds = item_bounds, clip = viewport;
    if (CGRectGetWidth(item_bounds) < 0 || CGRectGetHeight(item_bounds) < 0 ||
        CGRectGetWidth(item_bounds) > 1e9 || CGRectGetHeight(item_bounds) > 1e9 ||
        fabs(CGRectGetMinX(item_bounds)) > 1e9 || fabs(CGRectGetMinY(item_bounds)) > 1e9) return 5;
    NSDictionary *transform = item[@"transform"], *color = item[@"color"];
    if (!valid_json_numeric_fields(transform, @[@"a", @"b", @"c", @"d", @"tx", @"ty"]) ||
        !valid_json_numeric_fields(color, @[@"red", @"green", @"blue", @"alpha"]) ||
        !valid_json_number(item[@"opacity"])) return 5;
    float uv[4] = {0, 0, 1, 1};
    NSUInteger texture_index = 0;
    if (is_text) {
      NSDictionary *origin_value = is_text_run ? item[@"text_origin"] : nil;
      if ((is_text_run && !valid_json_numeric_fields(origin_value, @[@"x", @"y"])) ||
          ![item[@"text"] isKindOfClass:NSString.class] || !valid_json_number(item[@"font_size"])) return 5;
      double origin_x = is_text_run ? n(origin_value, @"x") : CGRectGetMinX(item_bounds);
      double origin_y = is_text_run ? n(origin_value, @"y") : CGRectGetMinY(item_bounds);
      if (!isfinite(origin_x) || !isfinite(origin_y) || fabs(origin_x) > 1e9 || fabs(origin_y) > 1e9 ||
          CGRectGetWidth(item_bounds) > 2048 || CGRectGetHeight(item_bounds) > 128) return 13;
      double font_size = n(item, @"font_size");
      if (font_size <= 0 || font_size > 32) return 5;
      CGRect text_bounds = item_bounds;
      BOOL empty = NO;
      int text_error = 0;
      id<MTLTexture> texture = text_mask_texture(item[@"text"], font_size, w.scale,
          item_bounds, NSMakePoint(origin_x, origin_y), &text_bounds, uv, &empty, &text_error);
      if (text_error) return text_error;
      if (empty) continue;
      NSUInteger allocation = (NSUInteger)texture.width * texture.height;
      if (allocation > 8 * 1024 * 1024 - text_allocation) return 13;
      text_allocation += allocation;
      bounds = text_bounds;
      [textures addObject:texture];
      texture_index = textures.count - 1;
    }
    if (item[@"clip_chain_id"] != NSNull.null) {
      BOOL found = NO;
      for (NSDictionary *chain in scene[@"clip_chains"]) {
        if ([chain[@"id"] isEqual:item[@"clip_chain_id"]]) {
          found = YES;
          for (NSDictionary *r in chain[@"rects"]) clip = CGRectIntersection(clip, rect(r));
          break;
        }
      }
      if (!found) return 5;
    }
    if (CGRectIsEmpty(clip) || CGRectIsNull(clip)) continue;
    double s = w.scale;
    // A scissor pixel is covered when its sample center (i + 0.5) lies in the
    // logical half-open clip. Convert both edges against that sample lattice.
    long long left_i = (long long)ceil(CGRectGetMinX(clip)*s - 0.5);
    long long top_i = (long long)ceil(CGRectGetMinY(clip)*s - 0.5);
    long long right_i = (long long)ceil(CGRectGetMaxX(clip)*s - 0.5);
    long long bottom_i = (long long)ceil(CGRectGetMaxY(clip)*s - 0.5);
    long long width_i = (long long)w.surface.drawableSize.width;
    long long height_i = (long long)w.surface.drawableSize.height;
    if (left_i < 0) left_i = 0; if (top_i < 0) top_i = 0;
    if (right_i < 0) right_i = 0; if (bottom_i < 0) bottom_i = 0;
    if (left_i > width_i) left_i = width_i; if (right_i > width_i) right_i = width_i;
    if (top_i > height_i) top_i = height_i; if (bottom_i > height_i) bottom_i = height_i;
    if (right_i <= left_i || bottom_i <= top_i) continue;
    NSUInteger left = (NSUInteger)left_i, top = (NSUInteger)top_i;
    NSUInteger right = (NSUInteger)right_i, bottom = (NSUInteger)bottom_i;
    Draw *draw = &draws[count++];
    draw->clip = (MTLScissorRect){left,top,right-left,bottom-top};
    draw->texture_index = texture_index;
    NSDictionary *t = transform, *c = color;
    double opacity = n(item, @"opacity");
    double red = n(c, @"red"), green = n(c, @"green");
    double blue = n(c, @"blue"), alpha = n(c, @"alpha");
    if (opacity < 0 || opacity > 1 || red < 0 || red > 255 || green < 0 || green > 255 ||
        blue < 0 || blue > 255 || alpha < 0 || alpha > 255) return 5;
    double xs[] = {CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMinX(bounds),CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMaxX(bounds)};
    double ys[] = {CGRectGetMinY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds),CGRectGetMaxY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds)};
    float us[] = {uv[0], uv[2], uv[0], uv[0], uv[2], uv[2]};
    float vs[] = {uv[1], uv[1], uv[3], uv[3], uv[1], uv[3]};
    for (int i = 0; i < 6; i++) {
      double x = n(t,@"a")*xs[i] + n(t,@"c")*ys[i] + n(t,@"tx");
      double y = n(t,@"b")*xs[i] + n(t,@"d")*ys[i] + n(t,@"ty");
      double px = 2*x/viewport.size.width-1, py = 1-2*y/viewport.size.height;
      if (!isfinite(px) || !isfinite(py) || fabs(px)>1e20 || fabs(py)>1e20) return 5;
      draw->v[i] = (Vertex){{(float)px,(float)py,0,1}, {(float)(red/255),(float)(green/255),(float)(blue/255),(float)(alpha/255*opacity)}, {us[i],vs[i]}, is_text ? 1u : 0u, 0};
    }
  }
  id<CAMetalDrawable> drawable = [w.surface nextDrawable];
  if (!drawable) return 15;
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.035,0.05,0.075,1);
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  if (!command || !encoder) return 13;
  [encoder setRenderPipelineState:pipeline];
  for (NSUInteger i = 0; i < count; i++) {
    [encoder setScissorRect:draws[i].clip];
    [encoder setVertexBytes:draws[i].v length:sizeof(draws[i].v) atIndex:0];
    [encoder setFragmentTexture:textures[draws[i].texture_index] atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }
  [encoder endEncoding];
#ifdef GPUI_TESTING
  NSUInteger readback_width=drawable.texture.width, readback_height=drawable.texture.height;
  NSUInteger readback_stride=((readback_width*4+255)/256)*256;
  if (!readback_width || !readback_height || readback_width > 16384 || readback_height > 16384 ||
      readback_width * readback_height > 16 * 1024 * 1024) return 13;
  id<MTLBuffer> readback=[device newBufferWithLength:readback_stride*readback_height options:MTLResourceStorageModeShared];
  if (!readback) return 13;
  id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
  [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
    sourceSize:MTLSizeMake(readback_width,readback_height,1) toBuffer:readback destinationOffset:0
    destinationBytesPerRow:readback_stride destinationBytesPerImage:readback_stride*readback_height];
  [blit endEncoding];
#endif
  [command presentDrawable:drawable];
  [command commit];
  // First slice deliberately keeps one synchronous in-flight frame. No closure
  // retains MoonBit memory; teardown cannot race frame completion.
  [command waitUntilCompleted];
#ifdef GPUI_TESTING
  if (command.status == MTLCommandBufferStatusCompleted) {
    frame_width=readback_width; frame_height=readback_height; frame_stride=readback_stride;
    frame_pixels=[NSData dataWithBytes:readback.contents length:frame_stride*frame_height];
    frame_window_token=w.token; frame_scale=w.scale;
  }
#endif
  return command.status == MTLCommandBufferStatusCompleted ? 0 : 16;
}
static int32_t native_call(int32_t op, int64_t token, double x, double y, const uint8_t *bytes, int32_t len) {
  if (![NSThread isMainThread]) return 18;
  if (len < 0 || len > 16*1024*1024 || (len && !bytes)) return 5;
  @autoreleasepool {
    if (op == 1) {
      if (state) return state == 2 ? 19 : 12;
      int status = setup_gpu();
      if (status) { pipeline=nil; queue=nil; device=nil; return status; }
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      app_delegate = [GPApplicationDelegate new]; NSApp.delegate = app_delegate;
      windows = [NSMutableDictionary new]; events = [NSMutableArray new]; current=nil; overflow=NO;
      [NSApp finishLaunching]; state = 1; host_epoch++;
      return 0;
    }
    if (op == 0) return token == host_epoch ? 0 : 10;
    if (op == 2) {
      if (!state) return 0;
      for (GPWindow *w in windows.allValues) destroy(w);
      events=nil; current=nil; text_result=nil; windows=nil; white_mask_texture=nil; pipeline=nil; queue=nil; device=nil;
      NSApp.delegate=nil; app_delegate=nil; state=0;
      return 0;
    }
    if (!state) return 1;
    if (op == 3) {
      if (state == 2) return 19;
      if (!isfinite(x) || !isfinite(y) || x < 1 || y < 1 || x > 8192 || y > 8192) return 5;
      if (next_token == INT64_MAX || windows.count >= 64) return 13;
      NSString *title = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
      if (!title) return 17;
      GPWindow *w = [GPWindow new];
      w.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,x,y) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
      if (!w.window) return 14;
      w.window.releasedWhenClosed = NO;
      w.window.animationBehavior = NSWindowAnimationBehaviorNone;
      w.window.contentMinSize = NSMakeSize(128,128);
      w.token = ++next_token; w.scale = w.window.backingScaleFactor;
      GPView *view = [[GPView alloc] initWithFrame:NSMakeRect(0,0,x,y)];
      view.owner=w; view.wantsLayer=YES;
      w.surface=[CAMetalLayer layer]; w.surface.device=device; w.surface.pixelFormat=MTLPixelFormatBGRA8Unorm;
      w.surface.allowsNextDrawableTimeout=YES;
#ifdef GPUI_TESTING
      w.surface.framebufferOnly=NO;
#endif
      view.layer=w.surface;
      w.window.contentView=view; w.window.delegate=w; w.window.title=title;
      windows[@(w.token)]=w; result_token=w.token;
      resize_surface(w); emit(w,1,0,0,0,0,0);
      [w.window center]; [w.window makeKeyAndOrderFront:nil]; [w.window makeFirstResponder:view];
      [NSApp activateIgnoringOtherApps:YES];
      return 0;
    }
    if (op == 6) {
      if (!isfinite(x) || x < 0 || x > 250) return 5;
      current=nil;
      if (!events.count) {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:x/1000];
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [NSApp updateWindows];
      }
      if (overflow) { overflow=NO; return 13; }
      if (events.count) { current=events[0]; [events removeObjectAtIndex:0]; }
      return 0;
    }
    if (op == 10) { emit(nil,14,0,0,0,0,0); return 0; }
    if (op == 12) {
      switch ((int)x) { case 0: [[NSCursor arrowCursor] set]; break; case 1: [[NSCursor pointingHandCursor] set]; break; case 2: [[NSCursor IBeamCursor] set]; break; default: return 9; }
      return 0;
    }
    if (op == 13) {
      current=nil;
      NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"";
      text_result = [text dataUsingEncoding:NSUTF8StringEncoding];
      return text_result.length <= 16*1024*1024 ? 0 : 13;
    }
    if (op == 14) {
      NSString *text = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
      if (!text) return 17;
      [NSPasteboard.generalPasteboard clearContents];
      return [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString] ? 0 : 12;
    }
    if (op == 11) { if (state == 1) { state=2; emit(nil,15,0,0,0,0,0); } return 0; }
    GPWindow *w=windows[@(token)];
    if (!w) return op == 8 && token > 0 && token <= next_token ? 0 : 10;
    switch (op) {
      case 4: {
        NSString *title=[[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
        if (!title) return 17; w.window.title=title; return 0;
      }
      case 5:
        if (!isfinite(x) || !isfinite(y) || x < 1 || y < 1 || x > 8192 || y > 8192) return 5;
        [w.window setContentSize:NSMakeSize(x,y)]; return 0;
      case 7: [w.window performClose:nil]; return 0;
      case 8:
        // Keep the window live if its terminal event cannot be queued. Events
        // for this token will be removed during destruction, freeing a slot.
        if (events.count >= 4096) {
          BOOL frees_slot = NO;
          for (NSDictionary *event in events) {
            if ([event[@"token"] longLongValue] == token) { frees_slot = YES; break; }
          }
          if (!frees_slot) return 13;
        }
        destroy(w); return 0;
      case 9: return present(w,bytes,len);
      case 16: return recover_renderer();
      case 15: resize_surface(w); current=@{@"width":@(w.window.contentView.bounds.size.width), @"height":@(w.window.contentView.bounds.size.height), @"scale":@(w.scale)}; return 0;
      default: return 9;
    }
  }
}
static int64_t native_integer(int32_t field) {
  if (![NSThread isMainThread]) return 0;
  if (field >= 100) { NSData *text = current[@"text"] ?: text_result; return field-100 < (int)text.length ? ((const uint8_t *)text.bytes)[field-100] : 0; }
  switch(field) {
    case 0:return result_token; case 1:return [current[@"kind"] longLongValue];
    case 2:return [current[@"token"] longLongValue]; case 3:return [current[@"seq"] longLongValue];
    case 4:return [current[@"mods"] longLongValue]; case 5:return [current[@"code"] longLongValue];
    case 6:return [current[@"repeat"] longLongValue]; case 7:return 1;
    case 8:return [(current[@"text"] ?: text_result) length]; case 9:return host_epoch; default:return 0;
  }
}
static double native_number(int32_t field) {
  if (![NSThread isMainThread]) return 0;
  NSArray *keys=@[@"scale",@"x",@"y",@"width",@"height"];
  return field >= 0 && field < 5 ? [current[keys[field]] doubleValue] : 0;
}
const GpuiApi *gpui_macos_api_v1(void) {
  static const GpuiApi api={1,sizeof(GpuiApi),native_call,native_integer,native_number};
  return &api;
}

/* Opt-in E2E access to the last completed native Metal frame. Pixel copying
 * canonicalizes the private BGRA drawable bytes to top-left RGBA8. */
int32_t gpui_macos_test_frame_meta_v1(int64_t window, double *output) {
#ifdef GPUI_TESTING
  if (![NSThread isMainThread]) return 18;
  const char *enabled = getenv("GPUI_NATIVE_E2E");
  if (!enabled || strcmp(enabled, "1") != 0) return 9;
  if (!output) return 5;
  GPWindow *target = windows[@(window)];
  if (!target || !target.window) return 10;
  if (!frame_pixels || frame_window_token != window) return 12;
  if (!frame_width || !frame_height || frame_width > 16384 || frame_height > 16384 ||
      frame_width * frame_height > 16 * 1024 * 1024 || frame_stride < frame_width * 4 ||
      frame_pixels.length < frame_stride * frame_height) return 13;
  output[0] = (double)frame_width;
  output[1] = (double)frame_height;
  output[2] = frame_scale;
  return 0;
#else
  (void)window; (void)output;
  return 9;
#endif
}

int32_t gpui_macos_test_frame_copy_v1(int64_t window, uint8_t *output,
                                      int32_t capacity) {
#ifdef GPUI_TESTING
  if (![NSThread isMainThread]) return 18;
  const char *enabled = getenv("GPUI_NATIVE_E2E");
  if (!enabled || strcmp(enabled, "1") != 0) return 9;
  GPWindow *target = windows[@(window)];
  if (!target || !target.window) return 10;
  if (!frame_pixels || frame_window_token != window) return 12;
  NSUInteger pixels = frame_width * frame_height;
  if (!frame_width || !frame_height || frame_width > 16384 || frame_height > 16384 ||
      pixels > 16 * 1024 * 1024 || frame_stride < frame_width * 4 ||
      frame_pixels.length < frame_stride * frame_height || pixels * 4 > INT32_MAX) return 13;
  NSUInteger required = pixels * 4;
  if (!output || capacity < 0 || (NSUInteger)capacity != required) return 5;
  const uint8_t *source = frame_pixels.bytes;
  for (NSUInteger y = 0; y < frame_height; ++y) {
    for (NSUInteger x = 0; x < frame_width; ++x) {
      NSUInteger src = y * frame_stride + x * 4;
      NSUInteger dst = (y * frame_width + x) * 4;
      output[dst] = source[src + 2];
      output[dst + 1] = source[src + 1];
      output[dst + 2] = source[src];
      output[dst + 3] = source[src + 3];
    }
  }
  return 0;
#else
  (void)window; (void)output; (void)capacity;
  return 9;
#endif
}

/* Opt-in, window-scoped E2E events. They travel through NSWindow's normal
 * dispatch path and cannot target arbitrary desktop windows. */
int32_t gpui_macos_test_post_click_v1(int64_t token, double x, double y) {
#ifdef GPUI_TESTING
  if (![NSThread isMainThread]) return 18;
  const char *enabled = getenv("GPUI_NATIVE_E2E");
  if (!enabled || strcmp(enabled, "1") != 0) return 9;
  GPWindow *target = windows[@(token)];
  if (!target || !target.window || target.closing) return 10;
  NSView *content = target.window.contentView;
  if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0 ||
      x >= content.bounds.size.width || y >= content.bounds.size.height)
    return 5;
  NSPoint location = [content convertPoint:NSMakePoint(x, y) toView:nil];
  NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
  NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
      location:location modifierFlags:0 timestamp:timestamp
      windowNumber:target.window.windowNumber context:nil eventNumber:1
      clickCount:1 pressure:1.0];
  NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
      location:location modifierFlags:0 timestamp:timestamp + 0.001
      windowNumber:target.window.windowNumber context:nil eventNumber:1
      clickCount:1 pressure:0.0];
  if (!down || !up) return 16;
  [target.window sendEvent:down];
  [target.window sendEvent:up];
  return 0;
#else
  (void)token; (void)x; (void)y;
  return 9;
#endif
}

int32_t gpui_macos_test_post_escape_v1(int64_t token) {
#ifdef GPUI_TESTING
  if (![NSThread isMainThread]) return 18;
  const char *enabled = getenv("GPUI_NATIVE_E2E");
  if (!enabled || strcmp(enabled, "1") != 0) return 9;
  GPWindow *target = windows[@(token)];
  if (!target || !target.window || target.closing) return 10;
  NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
  NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:timestamp
      windowNumber:target.window.windowNumber context:nil characters:@"\e"
      charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];
  NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp
      location:NSZeroPoint modifierFlags:0 timestamp:timestamp + 0.001
      windowNumber:target.window.windowNumber context:nil characters:@"\e"
      charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];
  if (!down || !up) return 16;
  [target.window sendEvent:down];
  [target.window sendEvent:up];
  return 0;
#else
  (void)token;
  return 9;
#endif
}
