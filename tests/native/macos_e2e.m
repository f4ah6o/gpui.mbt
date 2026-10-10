// Black-box native event delivery plus test-only GPU readback and fault injection.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#include <assert.h>
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <stdlib.h>
static const GpuiApi *api;
@interface GPScrollProbe : NSObject
@property NSPoint locationInWindow;
@property CGFloat scrollingDeltaX, scrollingDeltaY;
@property NSEventModifierFlags modifierFlags;
@property BOOL hasPreciseScrollingDeltas;
@end
@implementation GPScrollProbe
@end
static int call_op(int op, int64_t token, double x, double y, NSString *text) {
  NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
  return api->call(op,token,x,y,data.bytes,(int32_t)data.length);
}
static NSData *read_clipboard_bytes(void) {
  int64_t length=api->integer(8);
  assert(length>=0 && length<=16*1024*1024);
  NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)length];
  uint8_t *bytes=data.mutableBytes;
  for (int64_t i=0;i<length;i++) bytes[i]=(uint8_t)api->integer((int32_t)(100+i));
  return data;
}
static void verify_clipboard_and_cursors(void) {
  test_clipboard=[NSPasteboard pasteboardWithUniqueName];
  assert(test_clipboard);
  assert(call_op(13,0,0,0,nil)==0 && api->integer(8)==0);
  NSString *expected=@"macOS service smoke: 日本語 🙂";
  assert(call_op(14,0,0,0,expected)==0);
  assert(call_op(13,0,0,0,nil)==0);
  assert([read_clipboard_bytes() isEqualToData:[expected dataUsingEncoding:NSUTF8StringEncoding]]);
  for (int cursor=0;cursor<=2;cursor++) assert(call_op(12,0,cursor,0,nil)==0);
  assert(call_op(12,0,3,0,nil)==9);
  assert(call_op(12,0,0,0,nil)==0);
}
static void verify_scroll_delivery(int64_t token, CGScrollEventUnit units,
                                   BOOL precise, int32_t delta_x, int32_t delta_y) {
  GPWindow *window=windows[@(token)]; assert(window && window.window.contentView);
  GPView *view=(GPView *)window.window.contentView;
  NSPoint expected_view=NSMakePoint(33.5,44.25);
  CGEventRef cg_event=CGEventCreateScrollWheelEvent(NULL,units,2,delta_x,delta_y);
  assert(cg_event);
  CGEventSetFlags(cg_event,kCGEventFlagMaskShift|kCGEventFlagMaskCommand);
  NSEvent *event=[NSEvent eventWithCGEvent:cg_event];
  CFRelease(cg_event);
  assert(event && event.hasPreciseScrollingDeltas==precise);
  GPScrollProbe *probe=[GPScrollProbe new];
  probe.locationInWindow=NSMakePoint(expected_view.x,
      view.bounds.size.height-expected_view.y);
  probe.scrollingDeltaX=event.scrollingDeltaX;
  probe.scrollingDeltaY=event.scrollingDeltaY;
  probe.modifierFlags=event.modifierFlags;
  probe.hasPreciseScrollingDeltas=event.hasPreciseScrollingDeltas;
  [view scrollWheel:(NSEvent *)probe];
  assert(call_op(6,0,0,0,nil)==0);
  assert(api->integer(1)==16 && api->integer(2)==token);
  assert(api->integer(4)==9);
  assert(fabs(api->number(1)-expected_view.x)<0.0001);
  assert(fabs(api->number(2)-expected_view.y)<0.0001);
  assert(fabs(api->number(3)-event.scrollingDeltaX)<0.0001);
  assert(fabs(api->number(4)-event.scrollingDeltaY)<0.0001);
}
static void *wrong_thread(void *unused) {
  (void)unused; assert(call_op(3,0,320,240,@"wrong thread") == 18); return NULL;
}
static void drain(void) {
  for(int i=0;i<256;i++) { assert(call_op(6,0,0,0,nil)==0); if (!api->integer(1)) return; }
  assert(!"event queue did not drain");
}
static void pixel(int x, int y, int red, int green, int blue) {
  const uint8_t *p=frame_pixels.bytes;
  NSUInteger offset=(NSUInteger)(y*windows.allValues[0].scale)*frame_stride+(NSUInteger)(x*windows.allValues[0].scale)*4;
  assert(offset+3 < frame_pixels.length);
  assert(abs(p[offset]-blue)<=2 && abs(p[offset+1]-green)<=2 && abs(p[offset+2]-red)<=2);
}
static void device_pixel(int x, int y, int red, int green, int blue) {
  const uint8_t *p=frame_pixels.bytes;
  NSUInteger offset=(NSUInteger)y*frame_stride+(NSUInteger)x*4;
  assert(offset+3 < frame_pixels.length);
  assert(abs(p[offset]-blue)<=2 && abs(p[offset+1]-green)<=2 && abs(p[offset+2]-red)<=2);
}
static int non_background_pixels(int x, int y, int width, int height) {
  const uint8_t *p=frame_pixels.bytes;
  int count=0;
  int scale=(int)windows.allValues[0].scale;
  for (int yy=y*scale; yy<(y+height)*scale; yy++) {
    for (int xx=x*scale; xx<(x+width)*scale; xx++) {
      NSUInteger offset=(NSUInteger)yy*frame_stride+(NSUInteger)xx*4;
      assert(offset+3 < frame_pixels.length);
      if (abs(p[offset]-19)>2 || abs(p[offset+1]-13)>2 || abs(p[offset+2]-9)>2)
        count++;
    }
  }
  return count;
}
static void verify_rgba_capture(int64_t token) {
  double metrics[3]={0};
  assert(gpui_macos_test_frame_meta_v1(token,metrics)==0);
  assert(metrics[0]==frame_width && metrics[1]==frame_height);
  assert(metrics[2]==windows[@(token)].scale);
  NSUInteger length=(NSUInteger)metrics[0]*(NSUInteger)metrics[1]*4;
  uint8_t *rgba=malloc(length);
  assert(rgba);
  assert(gpui_macos_test_frame_copy_v1(token,rgba,(int32_t)length)==0);
  int scale=(int)metrics[2];
  NSUInteger red_offset=((NSUInteger)(70*scale)*(NSUInteger)metrics[0]+(NSUInteger)(70*scale))*4;
  assert(rgba[red_offset]>250 && rgba[red_offset+1]<2 && rgba[red_offset+2]<2 && rgba[red_offset+3]>250);
  free(rgba);
}
int main(void) {
  @autoreleasepool {
    api=gpui_macos_api_v1(); assert(api->abi_version==1 && api->struct_size==sizeof(GpuiApi));
    assert(call_op(2,0,0,0,nil)==0);
    assert(call_op(3,0,320,240,@"before start")==1);
    assert(call_op(1,0,0,0,nil)==0);
    assert(call_op(1,0,0,0,nil)==12);
    assert(call_op(3,0,NAN,240,@"invalid")==5);
    uint8_t invalid[]={0xff}; assert(api->call(3,0,320,240,invalid,1)==17);
    pthread_t thread; assert(!pthread_create(&thread,NULL,wrong_thread,NULL)); pthread_join(thread,NULL);
    assert(call_op(3,0,320,240,@"gpui.mbt native E2E")==0);
    int64_t token=api->integer(0), previous=0;
    GPWindow *w=windows[@(token)];
    assert(w && w.surface && w.window.visible);
    double disabled_metrics[3]={0};
    unsetenv("GPUI_NATIVE_E2E");
    assert(gpui_macos_test_frame_meta_v1(token,disabled_metrics)==9);
    assert(gpui_macos_test_post_click_v1(token,90,70)==9);
    assert(gpui_macos_test_post_escape_v1(token)==9);
    setenv("GPUI_NATIVE_E2E","1",1);
    drain();
    verify_clipboard_and_cursors();
    verify_scroll_delivery(token,kCGScrollEventUnitLine,NO,1,-2);
    verify_scroll_delivery(token,kCGScrollEventUnitPixel,YES,-4,7);
    NSString *snapshot=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[{\"id\":0,\"rects\":[{\"x\":60,\"y\":60,\"width\":80,\"height\":40}]}],\"items\":[{\"kind\":\"quad\",\"bounds\":{\"x\":40,\"y\":40,\"width\":40,\"height\":80},\"color\":{\"red\":255,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":20,\"ty\":0},\"opacity\":1,\"clip_chain_id\":0},{\"kind\":\"quad\",\"bounds\":{\"x\":80,\"y\":60,\"width\":60,\"height\":40},\"color\":{\"red\":0,\"green\":0,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":0.5,\"clip_chain_id\":null}]}",w.scale];
    assert(call_op(9,token,0,0,snapshot)==0);
    verify_rgba_capture(token);
    pixel(70,70,255,0,0); pixel(90,70,128,0,128); pixel(50,70,9,13,19); pixel(110,70,4,6,137);
    assert(frame_width==(NSUInteger)(320*w.scale) && frame_height==(NSUInteger)(240*w.scale));
    NSString *text_snapshot=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[],\"items\":[{\"kind\":\"text\",\"bounds\":{\"x\":20,\"y\":20,\"width\":180,\"height\":40},\"color\":{\"red\":255,\"green\":255,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null,\"text\":\"Native GPUI\",\"font_size\":20},{\"kind\":\"text_run\",\"bounds\":{\"x\":20,\"y\":60,\"width\":180,\"height\":40},\"color\":{\"red\":80,\"green\":220,\"blue\":120,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null,\"text\":\"Text Run\",\"font_size\":18,\"text_origin\":{\"x\":20,\"y\":60}}]}",w.scale];
    assert(call_op(9,token,0,0,text_snapshot)==0);
    assert(non_background_pixels(20,20,180,40)>20);
    assert(non_background_pixels(20,60,180,40)>20);
    NSString *color_text=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[],\"items\":[{\"kind\":\"text\",\"bounds\":{\"x\":20,\"y\":20,\"width\":100,\"height\":40},\"color\":{\"red\":255,\"green\":255,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null,\"text\":\"👩‍💻\",\"font_size\":20}]}",w.scale];
    NSData *last_text_frame=[frame_pixels copy];
    assert(call_op(9,token,0,0,color_text)==9);
    assert([frame_pixels isEqualToData:last_text_frame]);
    NSString *control_text=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[],\"items\":[{\"kind\":\"text\",\"bounds\":{\"x\":20,\"y\":20,\"width\":100,\"height\":40},\"color\":{\"red\":255,\"green\":255,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null,\"text\":\"Control\\tText\",\"font_size\":20}]}",w.scale];
    assert(call_op(9,token,0,0,control_text)==9);
    assert([frame_pixels isEqualToData:last_text_frame]);
    // Fractional clip regression: [0.2, 1.2) covers device pixel 0 at 1x,
    // and device pixels 0..1 at 2x. The next sample center must stay clear.
    for (int scale=1; scale<=2; scale++) {
      test_scale_override=scale; resize_surface(w);
      NSString *fractional=[NSString stringWithFormat:
        @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%d,\"resources\":[],\"clip_chains\":[{\"id\":1,\"rects\":[{\"x\":0.2,\"y\":10,\"width\":1.0,\"height\":10}]}],\"items\":[{\"kind\":\"quad\",\"bounds\":{\"x\":0,\"y\":0,\"width\":4,\"height\":30},\"color\":{\"red\":0,\"green\":255,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":1}]}",scale];
      assert(call_op(9,token,0,0,fractional)==0);
      int row=15*scale;
      device_pixel(0,row,0,255,0);
      if (scale==2) device_pixel(1,row,0,255,0);
      device_pixel(scale,row,9,13,19);
    }
    test_scale_override=0; resize_surface(w);
    pipeline=nil; queue=nil; device=nil;
    assert(call_op(9,token,0,0,snapshot)==16);
    assert(call_op(16,token,0,0,nil)==0);
    assert(w.surface.device==device && device && queue && pipeline);
    assert(call_op(9,token,0,0,snapshot)==0);
    pixel(70,70,255,0,0); pixel(90,70,128,0,128);
    for (int i=0;i<50;i++) assert(call_op(6,0,10,0,nil)==0);
    drain();
    assert(gpui_macos_test_post_click_v1(token,90,70)==0);
    assert(gpui_macos_test_post_escape_v1(token)==0);
    BOOL pointer_down=NO, pointer_up=NO, escape_down=NO, escape_up=NO;
    for(int i=0;i<100 && (!pointer_down || !pointer_up || !escape_down || !escape_up);i++) {
      assert(call_op(6,0,1,0,nil)==0);
      int kind=(int)api->integer(1);
      if (!kind) continue;
      assert(api->integer(2)==token); assert(api->integer(3)>previous); previous=api->integer(3);
      assert(api->number(0)==w.scale);
      if(kind==8) { pointer_down=YES; assert(api->number(1)==90 && api->number(2)==70); assert(api->integer(4)==0); }
      if(kind==9) { pointer_up=YES; assert(api->number(1)==90 && api->number(2)==70); assert(api->integer(4)==0); }
      if(kind==10) { escape_down=YES; assert(api->integer(5)==53); }
      if(kind==11) { escape_up=YES; assert(api->integer(5)==53); }
    }
    assert(pointer_down && pointer_up && escape_down && escape_up);
    assert(call_op(5,token,400,300,nil)==0);
    BOOL resized=NO;
    for(int i=0;i<100 && !resized;i++) {
      assert(call_op(6,0,1,0,nil)==0);
      resized=api->integer(1)==2 && api->number(3)==400 && api->number(4)==300;
    }
    assert(resized); assert(w.surface.drawableSize.width==400*w.scale);
    assert(call_op(7,token,0,0,nil)==0);
    BOOL requested=NO;
    for(int i=0;i<100 && !requested;i++) { assert(call_op(6,0,1,0,nil)==0); requested=api->integer(1)==12; }
    assert(requested && windows[@(token)]);
    GPView *detached_view=(GPView *)w.window.contentView;
    assert(call_op(8,token,0,0,nil)==0); assert(call_op(8,token,0,0,nil)==0);
    assert(call_op(4,token,0,0,@"stale")==10);
    assert(call_op(6,0,0,0,nil)==0 && api->integer(1)==13);
    NSEvent *stale_mouse=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(90,170) modifierFlags:0 timestamp:0 windowNumber:w.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
    NSEvent *stale_key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:w.window.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [detached_view mouseDown:stale_mouse]; [detached_view keyDown:stale_key];
    emit(w,7,1,1,0,0,0); assert(call_op(6,0,0,0,nil)==0 && api->integer(1)==0);
    // Independent simultaneous windows remain live after their peer is destroyed.
    assert(call_op(3,0,320,240,@"first")==0); int64_t first=api->integer(0);
    assert(call_op(3,0,400,300,@"second")==0); int64_t second=api->integer(0);
    assert(first != second && windows.count==2);
    assert(call_op(8,first,0,0,nil)==0 && windows.count==1);
    assert(call_op(4,second,0,0,@"second still live")==0);
    assert(call_op(8,second,0,0,nil)==0); drain();
    for(int i=0;i<32;i++) {
      assert(call_op(3,0,320,240,@"churn")==0);
      int64_t next=api->integer(0); assert(next>token); token=next;
      assert(call_op(8,next,0,0,nil)==0);
      assert(windows.count==0); drain();
    }
    // A full unrelated queue rejects destruction without losing the window or
    // its eventual terminal notification. Drain one slot, then retry.
    assert(call_op(3,0,320,240,@"queue saturation")==0);
    int64_t saturated=api->integer(0); drain();
    for (int i=0;i<4096;i++) assert(call_op(10,0,0,0,nil)==0);
    assert(call_op(8,saturated,0,0,nil)==13 && windows[@(saturated)]);
    assert(call_op(6,0,0,0,nil)==0 && api->integer(1)==14);
    assert(call_op(8,saturated,0,0,nil)==0);
    int destroyed=0;
    for (int i=0;i<4096;i++) { assert(call_op(6,0,0,0,nil)==0); if(api->integer(1)==13) destroyed++; }
    assert(destroyed==1 && windows.count==0);
    assert(call_op(10,0,0,0,nil)==0); assert(call_op(6,0,0,0,nil)==0 && api->integer(1)==14);
    int64_t epoch=api->integer(9);
    assert(call_op(11,0,0,0,nil)==0); assert(call_op(3,0,320,240,@"quiescing")==19);
    assert(call_op(6,0,0,0,nil)==0 && api->integer(1)==15);
    assert(call_op(2,0,0,0,nil)==0); assert(call_op(2,0,0,0,nil)==0);
    assert(call_op(1,0,0,0,nil)==0); assert(call_op(0,epoch,0,0,nil)==10);
    assert(call_op(2,0,0,0,nil)==0);
    puts("GPUI_MACOS_E2E {\"gpu_pixels\":true,\"grayscale_text\":true,\"unsupported_control_text_preserves_frame\":true,\"frame_readback\":true,\"test_input\":true,\"scroll_responder_precise_and_coarse\":true,\"clipboard_utf8_isolated\":true,\"cursor_kinds\":true,\"logical_coordinates\":true,\"resize\":true,\"wrong_thread\":true,\"churn\":32,\"stale_callbacks\":true,\"device_loss\":true,\"device_recovery\":true}");
  }
  return 0;
}
