// Black-box native event delivery plus test-only GPU readback and fault injection.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#include <assert.h>
#include <pthread.h>
static const GpuiApi *api;
static int call_op(int op, int64_t token, double x, double y, NSString *text) {
  NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
  return api->call(op,token,x,y,data.bytes,(int32_t)data.length);
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
    drain();
    NSString *snapshot=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[{\"id\":0,\"rects\":[{\"x\":60,\"y\":60,\"width\":80,\"height\":40}]}],\"items\":[{\"kind\":\"quad\",\"bounds\":{\"x\":40,\"y\":40,\"width\":40,\"height\":80},\"color\":{\"red\":255,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":20,\"ty\":0},\"opacity\":1,\"clip_chain_id\":0},{\"kind\":\"quad\",\"bounds\":{\"x\":80,\"y\":60,\"width\":60,\"height\":40},\"color\":{\"red\":0,\"green\":0,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":0.5,\"clip_chain_id\":null}]}",w.scale];
    assert(call_op(9,token,0,0,snapshot)==0);
    pixel(70,70,255,0,0); pixel(90,70,128,0,128); pixel(50,70,9,13,19); pixel(110,70,4,6,137);
    assert(frame_width==(NSUInteger)(320*w.scale) && frame_height==(NSUInteger)(240*w.scale));
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
    pipeline=nil; assert(call_op(9,token,0,0,snapshot)==16); assert(setup_gpu()==0);
    for (int i=0;i<50;i++) assert(call_op(6,0,10,0,nil)==0);
    drain();
    NSEvent *mouse=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(90,170) modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:w.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:w.window.windowNumber context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [w.window sendEvent:mouse]; [NSApp postEvent:key atStart:NO];
    BOOL pointer=NO, keyboard=NO;
    for(int i=0;i<100 && (!pointer || !keyboard);i++) {
      assert(call_op(6,0,1,0,nil)==0);
      int kind=(int)api->integer(1);
      if (!kind) continue;
      assert(api->integer(2)==token); assert(api->integer(3)>previous); previous=api->integer(3);
      assert(api->number(0)==w.scale);
      if(kind==8) { pointer=YES; assert(api->number(1)==90 && api->number(2)==70); assert(api->integer(4)==1); }
      if(kind==10) { keyboard=YES; assert(api->integer(5)==49); }
    }
    assert(pointer && keyboard);
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
    [detached_view mouseDown:mouse]; [detached_view keyDown:key];
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
    puts("GPUI_MACOS_E2E {\"gpu_pixels\":true,\"input\":true,\"logical_coordinates\":true,\"resize\":true,\"wrong_thread\":true,\"churn\":32,\"stale_callbacks\":true,\"device_loss\":true}");
  }
  return 0;
}
