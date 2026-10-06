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
static BOOL same_nullable_string(NSString *left, NSString *right) {
  return left == right || [left isEqualToString:right];
}
static void test_input_source_selection(GPWindow *w) {
  GPView *view = (GPView *)w.window.contentView;
  NSTextInputContext *context = view.inputContext;
  NSString *original = [context.selectedKeyboardInputSource copy];
  NSString *hiragana = @"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
  NSString *romaji_bundle = @"com.apple.inputmethod.Kotoeri.RomajiTyping";

  assert(!testing_select_input_source(w, @"org.gpui.missing.input-source"));
  assert(same_nullable_string(context.selectedKeyboardInputSource, original));
  assert(!w.testingInputSourceSaved && !w.testingOriginalInputSource);

  if ([context.keyboardInputSources containsObject:hiragana]) {
    assert(testing_select_input_source(w, hiragana));
    assert([context.selectedKeyboardInputSource isEqualToString:hiragana]);
    assert(w.testingInputSourceSaved);
    assert(call_op(32, w.token, 0, 0, nil) == 0);
    assert(same_nullable_string(context.selectedKeyboardInputSource, original));
    assert(!w.testingInputSourceSaved && !w.testingOriginalInputSource);
  }

  // The method's bundle identifier can be advertised but rejected as a
  // selected mode. Such a failed assignment must restore the exact previous
  // source, and keep retry state only when restoration itself fails.
  if ([context.keyboardInputSources containsObject:romaji_bundle]) {
    BOOL selected = testing_select_input_source(w, romaji_bundle);
    if (selected) {
      assert([context.selectedKeyboardInputSource isEqualToString:romaji_bundle]);
      assert(w.testingInputSourceSaved);
      assert(call_op(32, w.token, 0, 0, nil) == 0);
    } else {
      assert(same_nullable_string(context.selectedKeyboardInputSource, original));
      assert(!w.testingInputSourceSaved && !w.testingOriginalInputSource);
    }
    assert(same_nullable_string(context.selectedKeyboardInputSource, original));
  }
}
static void assert_focus_event_once(GPWindow *w, int expected_kind) {
  int seen = 0;
  BOOL drained = NO;
  for (int i = 0; i < 256; i++) {
    assert(call_op(6, 0, 0, 0, nil) == 0);
    int kind = (int)api->integer(1);
    if (kind == expected_kind) seen++;
    if (!kind) { drained = YES; break; }
  }
  assert(drained && seen == 1);
  assert(w.reportedKeyFocus == (expected_kind == 5));
  for (int i = 0; i < 4; i++) {
    assert(call_op(6, 0, 0, 0, nil) == 0);
    assert(api->integer(1) != expected_kind);
  }
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
static NSString *scene_json(NSString *resources, NSString *chains, NSString *items) {
  GPWindow *window = windows.allValues[0];
  return [NSString stringWithFormat:
    @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":%@,\"clip_chains\":%@,\"items\":%@}",
    window.scale, resources, chains, items];
}
static void malformed_scene_preflight(int64_t token) {
  NSString *valid_text_run = @"{\"kind\":\"text_run\",\"bounds\":{\"x\":20,\"y\":20,\"width\":120,\"height\":32},\"text_origin\":{\"x\":20,\"y\":20},\"text\":\"ok\",\"font_size\":18,\"color\":{\"red\":255,\"green\":255,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null}";
  NSString *null_origin = [valid_text_run stringByReplacingOccurrencesOfString:@"\"text_origin\":{\"x\":20,\"y\":20}" withString:@"\"text_origin\":null"];
  NSString *string_origin = [valid_text_run stringByReplacingOccurrencesOfString:@"\"text_origin\":{\"x\":20,\"y\":20}" withString:@"\"text_origin\":\"bad\""];
  NSString *null_font_size = [valid_text_run stringByReplacingOccurrencesOfString:@"\"font_size\":18" withString:@"\"font_size\":null"];
  NSString *boolean_font_size = [valid_text_run stringByReplacingOccurrencesOfString:@"\"font_size\":18" withString:@"\"font_size\":true"];
  NSString *invalid_items[] = {
    null_origin, string_origin, null_font_size, boolean_font_size,
    @"{\"kind\":\"quad\",\"bounds\":null,\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null}",
    @"{\"kind\":\"quad\",\"bounds\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1},\"color\":null,\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null}",
    @"{\"kind\":\"quad\",\"bounds\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1},\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":null,\"opacity\":1,\"clip_chain_id\":null}",
    @"{\"kind\":\"quad\",\"bounds\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1},\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":true,\"clip_chain_id\":null}"
  };
  NSUInteger item_count = sizeof(invalid_items) / sizeof(invalid_items[0]);
  for (NSUInteger i = 0; i < item_count; i++) {
    NSString *scene = scene_json(@"[]", @"[]", [NSString stringWithFormat:@"[%@]", invalid_items[i]]);
    assert(call_op(9, token, 0, 0, scene) == 5);
  }
  assert(call_op(9, token, 0, 0, scene_json(@"null", @"[]", @"[]")) == 5);
  assert(call_op(9, token, 0, 0, scene_json(@"[]", @"[]", @"null")) == 5);
  assert(call_op(9, token, 0, 0, scene_json(@"[]", @"{}", @"[]")) == 5);
  assert(call_op(9, token, 0, 0, scene_json(@"[]", @"[{\"id\":1,\"rects\":null}]", @"[]")) == 5);
  assert(call_op(9, token, 0, 0, scene_json(@"[]", @"[{\"id\":1,\"rects\":[null]}]", @"[]")) == 5);
  assert(call_op(9, token, 0, 0, scene_json(@"[]", @"[{\"id\":2147483648,\"rects\":[]}]", @"[]")) == 5);
  for (NSString *chain_id in @[@"-7", @"2147483647"]) {
    NSString *chains = [NSString stringWithFormat:
      @"[{\"id\":%@,\"rects\":[{\"x\":30,\"y\":30,\"width\":20,\"height\":20}]}]", chain_id];
    NSString *quad = [NSString stringWithFormat:
      @"{\"kind\":\"quad\",\"bounds\":{\"x\":20,\"y\":20,\"width\":40,\"height\":40},\"color\":{\"red\":255,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":%@}", chain_id];
    assert(call_op(9, token, 0, 0, scene_json(@"[]", chains, [NSString stringWithFormat:@"[%@]", quad])) == 0);
    NSUInteger scale = (NSUInteger)windows.allValues[0].scale;
    device_pixel(35 * scale, 35 * scale, 255, 0, 0);
  }
}
static NSUInteger count_mask_color(NSUInteger x0, NSUInteger y0, NSUInteger x1, NSUInteger y1,
                                   NSUInteger scale, int min_green) {
  const uint8_t *pixels=frame_pixels.bytes;
  NSUInteger count=0;
  for (NSUInteger y=y0*scale; y<y1*scale && y<frame_height; y++) {
    for (NSUInteger x=x0*scale; x<x1*scale && x<frame_width; x++) {
      NSUInteger offset=y*frame_stride+x*4;
      if (pixels[offset+1]>=min_green && pixels[offset+2]<32 && pixels[offset]<32) count++;
    }
  }
  return count;
}
static NSUInteger count_white_glyphs(NSUInteger x0, NSUInteger y0, NSUInteger x1, NSUInteger y1,
                                     NSUInteger scale) {
  const uint8_t *pixels=frame_pixels.bytes;
  NSUInteger count=0;
  for (NSUInteger y=y0*scale; y<y1*scale && y<frame_height; y++) {
    for (NSUInteger x=x0*scale; x<x1*scale && x<frame_width; x++) {
      NSUInteger offset=y*frame_stride+x*4;
      if (pixels[offset]>190 && pixels[offset+1]>190 && pixels[offset+2]>190) count++;
    }
  }
  return count;
}
static void text_provider_bounds(void) {
  static const uint8_t latin_japanese[]="Hello 日本";
  static const uint8_t family[]="sans";
  assert(gpui_macos_text_require_raster_v1(1)==0);
  double measurement[12+10*32];
  assert(gpui_macos_text_measure_v1(1,latin_japanese,(int32_t)sizeof(latin_japanese)-1,
    family,4,24,measurement,(int32_t)(sizeof(measurement)/sizeof(measurement[0])))==0);
  assert(measurement[10]==0 && measurement[2]>0 && measurement[3]>0);
  double hit[6];
  assert(gpui_macos_text_hit_test_v1(1,latin_japanese,(int32_t)sizeof(latin_japanese)-1,
    family,4,24,measurement[2],measurement[8]/2,hit,5)==0);
  assert(hit[0]>=0 && hit[0]<=sizeof(latin_japanese)-1);
  NSUInteger previous_width=0;
  for (double scale=1;scale<=2;scale+=1) {
    GpuiMacTextMask mask={0};
    assert(gpui_macos_text_raster_v1(latin_japanese,(int32_t)sizeof(latin_japanese)-1,24,scale,&mask)==0);
    assert(mask.pixels && mask.width>0 && mask.height>0 && mask.stride>=mask.width);
    NSUInteger ink_rows=0,ink_pixels=0;
    for (int y=0;y<mask.height;y++) {
      BOOL row=NO;
      for (int x=0;x<mask.width;x++) if (mask.pixels[y*mask.stride+x]) { row=YES; ink_pixels++; }
      if (row) ink_rows++;
    }
    assert(ink_rows>8 && ink_pixels>32);
    if (previous_width) assert((NSUInteger)mask.width>=previous_width*2-2);
    previous_width=mask.width;
    gpui_macos_text_raster_free(&mask);
  }
  static const uint8_t missing[]="\xcd\xb8"; // U+0378, unassigned in Unicode.
  double missing_measurement[12+10*4];
  assert(gpui_macos_text_measure_v1(1,missing,2,family,4,18,missing_measurement,52)==0);
  assert(missing_measurement[10]>0);
  assert(gpui_macos_text_admit_v1(1,missing,2,18,0,0,0,0,128,40)==16);
  GpuiMacTextMask rejected={0};
  assert(gpui_macos_text_raster_v1(missing,2,18,1,&rejected)==16);
  assert(gpui_macos_text_measure_v1(1,(const uint8_t*)"abc \xd7\x90",6,family,4,18,measurement,332)==14);
  assert(gpui_macos_text_measure_v1(1,(const uint8_t*)"a\nb",3,family,4,18,measurement,332)==15);
  const uint8_t malformed[]={0xff};
  assert(gpui_macos_text_measure_v1(1,malformed,1,family,4,18,measurement,332)==2);
  uint8_t json[131072];
  int32_t json_length=gpui_macos_text_fonts_json_v1((const uint8_t*)"Latin abc 日本語",(int32_t)strlen("Latin abc 日本語"),family,4,18,json,sizeof(json));
  assert(json_length>0 && json_length<(int32_t)sizeof(json));
  NSData *json_data=[NSData dataWithBytes:json length:(NSUInteger)json_length];
  NSDictionary *font_info=[NSJSONSerialization JSONObjectWithData:json_data options:0 error:nil];
  assert([font_info isKindOfClass:NSDictionary.class]);
  NSArray *fonts=font_info[@"fonts"];
  assert([fonts isKindOfClass:NSArray.class] && fonts.count>=2);
  BOOL latin=NO,japanese=NO;
  for (NSDictionary *font in fonts) {
    assert([font[@"file_url"] isKindOfClass:NSString.class]);
    assert([font[@"postscript_name"] isKindOfClass:NSString.class]);
    latin|=[font[@"segment"] isEqual:@"latin"];
    japanese|=[font[@"segment"] isEqual:@"japanese"];
  }
  assert(latin && japanese);
}
static NSString *session_payload(NSString *text, NSInteger cursor, NSInteger anchor,
                                int64_t revision, int64_t ack, double caret_x,
                                double caret_y, BOOL update) {
  NSMutableDictionary *payload = [@{
    @"text": text, @"cursor": @(cursor), @"anchor": @(anchor),
    @"utf16_length": @(text.length), @"owner_revision": @(revision),
    @"rect": @{ @"x": @(caret_x), @"y": @(caret_y), @"width": @1.0, @"height": @18.0 },
  } mutableCopy];
  if (update) {
    payload[@"external_edit"] = @NO;
    payload[@"acknowledged_sequence"] = ack > 0 ? @(ack) : NSNull.null;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingFragmentsAllowed error:nil];
  assert(data);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static NSDictionary *current_text_json(void) {
  NSData *data = current[@"text"];
  assert([data isKindOfClass:NSData.class] && data.length > 0);
  id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
  assert([value isKindOfClass:NSDictionary.class]);
  return value;
}
static void assert_json_bool(id value) {
  assert(value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID());
}
static NSDictionary *deliver_text_batch(void) {
  current = nil;
  assert(api->call(23, 0, 0, 0, NULL, 0) == 0);
  NSDictionary *batch = current_text_json();
  assert([batch[@"events"] isKindOfClass:NSArray.class]);
  return batch;
}
static void assert_text_callback(NSDictionary *batch, NSString *kind, NSString *text,
                                 NSUInteger count) {
  NSArray *callbacks = batch[@"events"];
  assert(callbacks.count == count);
  for (NSDictionary *callback in callbacks) assert([callback[@"kind"] isEqualToString:kind]);
  if (count == 1 && text) assert([callbacks[0][@"text"] isEqualToString:text]);
}
static void make_test_window_key(GPWindow *w) {
  // The application-driven Kotoeri acceptance exercises real key-window
  // ownership. This test-only override isolates copied callback/ACK logic in
  // the native harness, which does not enter NSApplication's modal run loop.
  w.testingTextFocusOverride = YES;
}
static NSDictionary *accept_batch_and_present(GPWindow *w, int epoch,
                                              NSDictionary *batch, NSString *text,
                                              NSInteger cursor, NSInteger anchor,
                                              int64_t revision, double caret_x,
                                              double caret_y, NSString *snapshot) {
  int64_t sequence = [batch[@"sequence"] longLongValue];
  NSString *payload = session_payload(text, cursor, anchor, revision, sequence, caret_x, caret_y, YES);
  assert(call_op(20, w.token, epoch, 0, payload) == 0);
  assert(call_op(9, w.token, 0, 0, snapshot) == 0);
  assert(api->call(26, w.token, 0, 0, NULL, 0) == 0);
  NSDictionary *identity = current_text_json();
  assert([identity[@"batch_sequence"] longLongValue] == sequence);
  assert([identity[@"accepted_revision"] longLongValue] == revision);
  assert([identity[@"session_epoch"] intValue] == epoch);
  return identity;
}
static void native_text_session_bounds(GPWindow *w, NSString *snapshot) {
  w.testingFocusOverrideEnabled = YES;
  w.testingFocusOverride = NO;
  reconcile_window_focus(w);
  drain();
  w.testingFocusOverride = YES;
  assert_focus_event_once(w, 5);
  make_test_window_key(w);
  GPView *view = (GPView *)w.window.contentView;
  NSString *boolean_cursor = @"{\"text\":\"ab\",\"cursor\":true,\"anchor\":1,\"utf16_length\":2,\"owner_revision\":1,\"rect\":{\"x\":20,\"y\":20,\"width\":1,\"height\":18}}";
  NSString *boolean_rect = @"{\"text\":\"ab\",\"cursor\":1,\"anchor\":1,\"utf16_length\":2,\"owner_revision\":1,\"rect\":{\"x\":true,\"y\":20,\"width\":1,\"height\":18}}";
  assert(call_op(19, w.token, 0, 0, boolean_cursor) == 5);
  assert(call_op(19, w.token, 0, 0, boolean_rect) == 5);
  assert(!w.sessionActive && w.sessionEpoch == 0);

  NSString *begin = session_payload(@"ab", 1, 1, 7, 0, 72, 54, NO);
  assert(call_op(19, w.token, 0, 0, begin) == 0);
  int epoch = (int)api->integer(0);
  assert(epoch > 0 && w.sessionActive && w.lastPresentedBatchSequence == 0);
  assert(call_op(33, w.token, 0, 0, nil) == 0);
  NSDictionary *window_state = current_text_json();
  assert_json_bool(window_state[@"window_key"]);
  assert_json_bool(window_state[@"app_key_matches"]);
  assert_json_bool(window_state[@"first_responder_is_content_view"]);
  assert_json_bool(window_state[@"window_visible"]);
  assert_json_bool(window_state[@"session_active"]);
  assert_json_bool(window_state[@"direct_text"]);
  assert([window_state[@"window_id"] longLongValue] == w.token);
  assert([window_state[@"host_epoch"] longLongValue] == host_epoch);
  assert([window_state[@"native_window_id"] longLongValue] == w.window.windowNumber);
  NSDictionary *content_origin = window_state[@"content_origin_in_window"];
  NSDictionary *content_size = window_state[@"content_size"];
  NSDictionary *window_size = window_state[@"window_size"];
  assert([window_state[@"coordinate_space"] isEqual:@"top_left_window_points"]);
  assert([content_origin isKindOfClass:NSDictionary.class] && [content_size isKindOfClass:NSDictionary.class] &&
         [window_size isKindOfClass:NSDictionary.class]);
  assert(fabs([content_origin[@"x"] doubleValue]) < 1.0 && [content_origin[@"y"] doubleValue] > 0.0);
  assert([content_size[@"width"] doubleValue] == 320.0 && [content_size[@"height"] doubleValue] == 240.0);
  assert([window_size[@"width"] doubleValue] >= 320.0 && [window_size[@"height"] doubleValue] > 240.0);
  assert(api->call(26, w.token, 0, 0, NULL, 0) == 0);
  NSDictionary *identity = current_text_json();
  assert([identity[@"accepted_revision"] longLongValue] == 7);
  assert([identity[@"batch_sequence"] longLongValue] == 0);

  NSString *bad_external = @"{\"text\":\"changed\",\"cursor\":true,\"anchor\":0,\"utf16_length\":7,\"owner_revision\":8,\"rect\":{\"x\":22,\"y\":20,\"width\":1,\"height\":18},\"external_edit\":true,\"acknowledged_sequence\":null}";
  assert(call_op(20, w.token, epoch, 0, bad_external) == 5);
  assert(w.sessionActive && w.sessionEpoch == epoch && [w.visibleText isEqualToString:@"ab"]);

  [view setMarkedText:@"に" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  assert(view.hasMarkedText && [w.visibleText isEqualToString:@"aにb"]);
  flush_text_batch(w);
  assert(w.sessionAwaitingAck && !w.batchDelivered && w.awaitingSequence > 0);
  NSString *early_ack = session_payload(@"ab", 1, 1, 8, w.awaitingSequence, 74, 54, YES);
  assert(call_op(20, w.token, epoch, 0, early_ack) == 12);
  assert(w.sessionAwaitingAck && !w.batchDelivered);
  NSDictionary *preedit = deliver_text_batch();
  assert_text_callback(preedit, @"preedit", @"に", 1);
  assert([preedit[@"host_epoch"] longLongValue] == host_epoch);
  assert([preedit[@"epoch"] intValue] == epoch);
  int64_t first_sequence = [preedit[@"sequence"] longLongValue];
  identity = accept_batch_and_present(w, epoch, preedit, @"ab", 1, 1, 8, 74, 54, snapshot);
  assert([identity[@"text"] isEqualToString:@"aにb"]);

  assert(api->call(27, w.token, 0, 0, NULL, 0) == 0);
  NSRect expected_local = NSMakeRect(74, 54, 1, api->number(4));
  NSRect expected_screen = [w.window convertRectToScreen:[view convertRect:expected_local toView:nil]];
  assert(fabs(api->number(1) - expected_screen.origin.x) < 1.0);
  assert(fabs(api->number(2) - expected_screen.origin.y) < 1.0);
  assert(api->number(3) == 1.0 && api->number(4) > 0.0);

  [view setMarkedText:@"かな" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  flush_text_batch(w);
  NSDictionary *second_preedit = deliver_text_batch();
  assert_text_callback(second_preedit, @"preedit", @"かな", 1);
  int64_t second_sequence = [second_preedit[@"sequence"] longLongValue];
  identity = accept_batch_and_present(w, epoch, second_preedit, @"ab", 1, 1, 9, 88, 56, snapshot);
  assert([identity[@"text"] isEqualToString:@"aかなb"]);

  // Insert in the same dispatch wins over a pending unmark commit.
  w.textDispatchActive = YES;
  w.textDispatchCommitted = NO;
  w.textCallbacks = [NSMutableArray new];
  [view unmarkText];
  [view insertText:@"日本" replacementRange:NSMakeRange(NSNotFound, 0)];
  [view flushPendingUnmark];
  flush_text_batch(w);
  NSDictionary *commit = deliver_text_batch();
  assert_text_callback(commit, @"commit", @"日本", 1);
  assert([commit[@"sequence"] longLongValue] > second_sequence);
  identity = accept_batch_and_present(w, epoch, commit, @"a日本b", 3, 3, 10, 92, 56, snapshot);
  assert([identity[@"text"] isEqualToString:@"a日本b"]);

  [view setMarkedText:@"と" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  flush_text_batch(w);
  NSDictionary *third_preedit = deliver_text_batch();
  assert_text_callback(third_preedit, @"preedit", @"と", 1);
  accept_batch_and_present(w, epoch, third_preedit, @"a日本b", 3, 3, 11, 96, 56, snapshot);
  // A standalone unmark commits the currently visible preview exactly once.
  w.textDispatchActive = YES;
  w.textDispatchCommitted = NO;
  w.textCallbacks = [NSMutableArray new];
  [view unmarkText];
  [view flushPendingUnmark];
  flush_text_batch(w);
  NSDictionary *unmark_commit = deliver_text_batch();
  assert_text_callback(unmark_commit, @"commit", @"と", 1);
  assert([unmark_commit[@"sequence"] longLongValue] > first_sequence);
  accept_batch_and_present(w, epoch, unmark_commit, @"a日本とb", 4, 4, 12, 98, 56, snapshot);

  // AppKit may deliver composition callbacks outside keyDown. The owner must
  // receive one batch at the next safe event-reader boundary instead of
  // silently losing the pending callback when a later key starts.
  [view setMarkedText:@"外" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  assert(w.textDispatchActive && !w.sessionAwaitingAck);
  NSDictionary *async_preedit = deliver_text_batch();
  assert_text_callback(async_preedit, @"preedit", @"外", 1);
  accept_batch_and_present(w, epoch, async_preedit, @"a日本とb", 4, 4, 13, 100, 56, snapshot);

  [view setMarkedText:@"x" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  flush_text_batch(w);
  assert(w.sessionAwaitingAck);
  assert(call_op(21, w.token, epoch, 0, nil) == 0);
  int next_epoch = (int)api->integer(0);
  assert(next_epoch == epoch + 1 && w.sessionActive && !w.hasMarkedText);
  assert([w.visibleText isEqualToString:@"a日本とb"]);
  for (NSDictionary *event in events) assert([event[@"kind"] intValue] != 18);
  NSString *stale_update = session_payload(@"a日本とb", 4, 4, 13, 0, 98, 56, YES);
  assert(call_op(20, w.token, epoch, 0, stale_update) == 10);
  assert(call_op(22, w.token, next_epoch, 0, nil) == 0);

  // Direct committed-text mirror rejects boolean ABI values without mutation.
  assert(call_op(17, w.token, 1, 0, nil) == 0);
  assert(call_op(18, w.token, 0, 0, nil) == 0);
  int direct_epoch = (int)api->integer(0);
  NSString *direct = session_payload(@"ready", 5, 5, 0, 0, 40, 30, NO);
  assert(call_op(28, w.token, direct_epoch, 0, direct) == 0);
  NSString *invalid_direct = @"{\"text\":\"lost\",\"cursor\":true,\"anchor\":0,\"utf16_length\":4,\"owner_revision\":0,\"rect\":{\"x\":1,\"y\":1,\"width\":1,\"height\":18}}";
  assert(call_op(28, w.token, direct_epoch, 0, invalid_direct) == 5);
  assert([w.visibleText isEqualToString:@"ready"]);
  [view setMarkedText:@"x" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  [view insertText:@"bad" replacementRange:NSMakeRange(NSNotFound, 0)];
  assert([w.visibleText isEqualToString:@"readybad"]);
  assert(events.count > 0 && [events.lastObject[@"kind"] intValue] == 16);
  assert(call_op(17, w.token, 0, 0, nil) == 0);
  assert(!w.hasMarkedText && [w.visibleText isEqualToString:@"ready"]);
  for (NSDictionary *event in events) assert([event[@"kind"] intValue] != 16);
  NSString *focus_session = session_payload(@"ready", 5, 5, 14, 0, 40, 30, NO);
  assert(call_op(19, w.token, 0, 0, focus_session) == 0 && w.sessionActive);
  assert(api->integer(0) > 0);
  test_input_source_selection(w);
  w.testingOriginalInputSource = [view.inputContext.selectedKeyboardInputSource copy];
  w.testingInputSourceSaved = YES;
  w.testingTextFocusOverride = NO;
  NSWindow *peer = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,160,120)
    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(peer);
  peer.releasedWhenClosed = NO;
  [peer makeKeyAndOrderFront:nil];
  assert(!key_window_owns_view(w));
  assert(call_op(32, w.token, 0, 0, nil) == 0 && !w.testingInputSourceSaved);
  w.testingFocusOverrideEnabled = NO;
  assert_focus_event_once(w, 6);
  assert(!w.sessionActive && !w.directText);
  [peer close];
  [w.window makeKeyAndOrderFront:nil];
  [w.window makeFirstResponder:view];
  w.testingFocusOverrideEnabled = YES;
  w.testingFocusOverride = YES;
  assert_focus_event_once(w, 5);
}
int main(void) {
  @autoreleasepool {
    api=gpui_macos_api_v1(); assert(api->abi_version==1 && api->struct_size==sizeof(GpuiApi));
    text_provider_bounds();
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
    assert(w.reportedKeyFocus == window_is_key_focus(w));
    drain();
    NSString *snapshot=[NSString stringWithFormat:
      @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%g,\"resources\":[],\"clip_chains\":[{\"id\":0,\"rects\":[{\"x\":60,\"y\":60,\"width\":80,\"height\":40}]}],\"items\":[{\"kind\":\"quad\",\"bounds\":{\"x\":40,\"y\":40,\"width\":40,\"height\":80},\"color\":{\"red\":255,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":20,\"ty\":0},\"opacity\":1,\"clip_chain_id\":0},{\"kind\":\"quad\",\"bounds\":{\"x\":80,\"y\":60,\"width\":60,\"height\":40},\"color\":{\"red\":0,\"green\":0,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":0.5,\"clip_chain_id\":null}]}",w.scale];
    malformed_scene_preflight(token);
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
    for (int text_scale=1;text_scale<=2;text_scale++) {
      test_scale_override=text_scale; resize_surface(w);
      NSString *text_scene=[NSString stringWithFormat:
        @"{\"schema_version\":1,\"viewport\":{\"x\":0,\"y\":0,\"width\":320,\"height\":240},\"scale\":%d,\"resources\":[],\"clip_chains\":[{\"id\":1,\"rects\":[{\"x\":45,\"y\":20,\"width\":100,\"height\":50}]}],\"items\":[{\"kind\":\"quad\",\"bounds\":{\"x\":200,\"y\":20,\"width\":80,\"height\":40},\"color\":{\"red\":0,\"green\":0,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null},{\"kind\":\"text\",\"bounds\":{\"x\":200,\"y\":20,\"width\":80,\"height\":40},\"text\":\"A\",\"font_size\":24,\"color\":{\"red\":255,\"green\":255,\"blue\":255,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null},{\"kind\":\"quad\",\"bounds\":{\"x\":200,\"y\":20,\"width\":10,\"height\":40},\"color\":{\"red\":255,\"green\":0,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":0,\"ty\":0},\"opacity\":1,\"clip_chain_id\":null},{\"kind\":\"text_run\",\"bounds\":{\"x\":20,\"y\":20,\"width\":180,\"height\":40},\"text_origin\":{\"x\":20,\"y\":20},\"text\":\"Hello 日本\",\"font_size\":24,\"color\":{\"red\":0,\"green\":255,\"blue\":0,\"alpha\":255},\"transform\":{\"a\":1,\"b\":0,\"c\":0,\"d\":1,\"tx\":15,\"ty\":5},\"opacity\":0.5,\"clip_chain_id\":1}]}",text_scale];
      assert(call_op(9,token,0,0,text_scene)==0);
      assert(count_mask_color(45,20,145,70,(NSUInteger)text_scale,32)>16);
      assert(count_mask_color(0,0,45,240,(NSUInteger)text_scale,32)==0);
      assert(count_mask_color(145,0,320,240,(NSUInteger)text_scale,32)==0);
      assert(count_white_glyphs(210,20,280,60,(NSUInteger)text_scale)>4);
      device_pixel(205*text_scale,25*text_scale,255,0,0);
    }
    test_scale_override=0; resize_surface(w);
    native_text_session_bounds(w,snapshot);
    pipeline=nil; queue=nil; device=nil;
    assert(call_op(9,token,0,0,snapshot)==16);
    assert(call_op(16,token,0,0,nil)==0);
    assert(w.surface.device==device && device && queue && pipeline);
    assert(call_op(9,token,0,0,snapshot)==0);
    pixel(70,70,255,0,0); pixel(90,70,128,0,128);
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
    puts("GPUI_MACOS_E2E {\"gpu_pixels\":true,\"text_pixels_1x_2x\":true,\"scene_preflight\":true,\"synthetic_ime_transactions\":true,\"async_callback_batching\":true,\"direct_text_rollback\":true,\"input\":true,\"logical_coordinates\":true,\"resize\":true,\"wrong_thread\":true,\"churn\":32,\"stale_callbacks\":true,\"device_loss\":true,\"device_recovery\":true}");
  }
  return 0;
}
