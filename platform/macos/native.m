#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <math.h>
#include "abi.h"

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
static int64_t next_token, result_token, host_epoch;
static NSData *text_result;
static int state; // 0 uninitialized/stopped, 1 running, 2 quiescing
static BOOL overflow;
#ifdef GPUI_TESTING
static NSData *frame_pixels;
static NSUInteger frame_width, frame_height, frame_stride;
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
  device = MTLCreateSystemDefaultDevice();
  if (!device) return 16;
  queue = [device newCommandQueue];
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p; float4 c; };\nstruct O { float4 p [[position]]; float4 c; };\nvertex O vmain(const device V *v [[buffer(0)]], uint i [[vertex_id]]) { O o; o.p=v[i].p; o.c=v[i].c; return o; }\nfragment float4 fmain(O o [[stage_in]]) { return o.c; }";
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
  return pipeline ? 0 : 16;
}
typedef struct { float position[4], color[4]; } Vertex;
typedef struct { Vertex v[6]; MTLScissorRect clip; } Draw;
static double n(NSDictionary *d, NSString *key) { return [d[key] doubleValue]; }
static CGRect rect(NSDictionary *d) { return CGRectMake(n(d,@"x"), n(d,@"y"), n(d,@"width"), n(d,@"height")); }
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
  NSUInteger count = 0;
  for (NSDictionary *item in items) {
    if (![item[@"kind"] isEqual:@"quad"]) return 9;
    CGRect bounds = rect(item[@"bounds"]), clip = viewport;
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
    NSUInteger left = (NSUInteger)ceil(CGRectGetMinX(clip)*s), top = (NSUInteger)ceil(CGRectGetMinY(clip)*s);
    NSUInteger right = MIN((NSUInteger)ceil(CGRectGetMaxX(clip)*s), (NSUInteger)w.surface.drawableSize.width);
    NSUInteger bottom = MIN((NSUInteger)ceil(CGRectGetMaxY(clip)*s), (NSUInteger)w.surface.drawableSize.height);
    if (right <= left || bottom <= top) continue;
    Draw *draw = &draws[count++];
    draw->clip = (MTLScissorRect){left,top,right-left,bottom-top};
    NSDictionary *t = item[@"transform"], *c = item[@"color"];
    double xs[] = {CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMinX(bounds),CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMaxX(bounds)};
    double ys[] = {CGRectGetMinY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds),CGRectGetMaxY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds)};
    for (int i = 0; i < 6; i++) {
      double x = n(t,@"a")*xs[i] + n(t,@"c")*ys[i] + n(t,@"tx");
      double y = n(t,@"b")*xs[i] + n(t,@"d")*ys[i] + n(t,@"ty");
      double px = 2*x/viewport.size.width-1, py = 1-2*y/viewport.size.height;
      if (!isfinite(px) || !isfinite(py) || fabs(px)>1e20 || fabs(py)>1e20) return 5;
      draw->v[i] = (Vertex){{(float)px,(float)py,0,1}, {(float)(n(c,@"red")/255),(float)(n(c,@"green")/255),(float)(n(c,@"blue")/255),(float)(n(c,@"alpha")/255*n(item,@"opacity"))}};
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
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }
  [encoder endEncoding];
#ifdef GPUI_TESTING
  frame_width=drawable.texture.width; frame_height=drawable.texture.height;
  frame_stride=((frame_width*4+255)/256)*256;
  id<MTLBuffer> readback=[device newBufferWithLength:frame_stride*frame_height options:MTLResourceStorageModeShared];
  if (!readback) return 13;
  id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
  [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
    sourceSize:MTLSizeMake(frame_width,frame_height,1) toBuffer:readback destinationOffset:0
    destinationBytesPerRow:frame_stride destinationBytesPerImage:frame_stride*frame_height];
  [blit endEncoding];
#endif
  [command presentDrawable:drawable];
  [command commit];
  // First slice deliberately keeps one synchronous in-flight frame. No closure
  // retains MoonBit memory; teardown cannot race frame completion.
  [command waitUntilCompleted];
#ifdef GPUI_TESTING
  frame_pixels=[NSData dataWithBytes:readback.contents length:frame_stride*frame_height];
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
      events=nil; current=nil; text_result=nil; windows=nil; pipeline=nil; queue=nil; device=nil;
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
