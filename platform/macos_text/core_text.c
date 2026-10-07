#include "macos_text.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#define ABI 1
#define MAX_TEXT 16384
#define MAX_FAMILY 256
#define MAX_SCENE_TEXT 4096
#define MAX_FONT_SIZE 512.0
#define MAX_SCENE_SIZE 32.0
#define MAX_SCENE_WIDTH 2048.0
#define MAX_SCENE_HEIGHT 128.0
#define HEADER 12
#define CARET 10

enum { OK=0, BAD_ABI=1, UNSUPPORTED_INPUT=2, TOO_LARGE=3, SMALL_BUFFER=4,
  INVALID_RESULT=6, BAD_COORDINATE=7, COLOR_GLYPH=8,
  RASTER_UNAVAILABLE=10, BAD_FONT=11, BAD_SIZE=12, NATIVE_FAILURE=13,
  UNSUPPORTED_BIDI=14, UNSUPPORTED_MULTILINE=15, UNSUPPORTED_GLYPH=16,
  RESOURCE_LIMIT=17 };

typedef struct { int32_t byte; int32_t utf16; int cursor; } Boundary;

static int finite_bounded(double value, double limit) {
  return isfinite(value) && fabs(value) <= limit;
}

static int utf8_scalar(const uint8_t *s, int32_t length, int32_t *at, uint32_t *out) {
  if (*at >= length) return 0;
  uint8_t a=s[(*at)++];
  if (a < 0x80) { *out=a; return 1; }
  int count; uint32_t value;
  if (a >= 0xC2 && a <= 0xDF) { count=1; value=a&0x1F; }
  else if (a >= 0xE0 && a <= 0xEF) { count=2; value=a&0x0F; }
  else if (a >= 0xF0 && a <= 0xF4) { count=3; value=a&0x07; }
  else return -1;
  if (length-*at < count) return -1;
  for (int i=0;i<count;i++) {
    uint8_t b=s[(*at)++];
    if ((b&0xC0)!=0x80) return -1;
    if (i==0 && ((a==0xE0 && b<0xA0) || (a==0xED && b>=0xA0) ||
                 (a==0xF0 && b<0x90) || (a==0xF4 && b>=0x90))) return -1;
    value=(value<<6)|(b&0x3F);
  }
  if (value>0x10FFFF || (value>=0xD800 && value<=0xDFFF)) return -1;
  *out=value; return 1;
}

static int rejected_scalar(uint32_t cp) {
  if (cp=='\n' || cp=='\r' || cp==0x2028 || cp==0x2029) return 15;
  if ((cp>=0x202A && cp<=0x202E) || (cp>=0x2066 && cp<=0x2069) ||
      cp==0x061C || cp==0x200E || cp==0x200F) return 14;
  if (cp==0 || cp<0x20 || (cp>=0x7F && cp<=0x9F)) return 2;
  return 0;
}

static int make_boundaries(const uint8_t *bytes, int32_t length,
                           Boundary **out, int32_t *count, int32_t *utf16_length) {
  if (length<0 || length>MAX_TEXT || (length && !bytes)) return TOO_LARGE;
  Boundary *items=calloc((size_t)length+1,sizeof(*items));
  if (!items) return RESOURCE_LIMIT;
  int32_t at=0, scalars=0, units=0;
  items[0]=(Boundary){0,0,1};
  while (at<length) {
    int32_t start=at; uint32_t cp=0;
    if (utf8_scalar(bytes,length,&at,&cp)<0) { free(items); return UNSUPPORTED_INPUT; }
    int rejected=rejected_scalar(cp);
    if (rejected) { free(items); return rejected; }
    units += cp>0xFFFF ? 2 : 1;
    items[++scalars]=(Boundary){at,units,0};
    (void)start;
  }
  items[scalars].cursor=1;
  *out=items; *count=scalars+1; *utf16_length=units;
  return OK;
}

static CFStringRef cf_string(const uint8_t *bytes, int32_t length) {
  const uint8_t *safe=length==0 ? (const uint8_t *)"" : bytes;
  return CFStringCreateWithBytes(kCFAllocatorDefault,safe,length,kCFStringEncodingUTF8,false);
}

static CTFontRef make_font(const uint8_t *family, int32_t family_len, double size) {
  CFStringRef name=cf_string(family,family_len);
  if (!name) return NULL;
  CTFontRef font=NULL;
  if (family_len==4 && memcmp(family,"sans",4)==0)
    font=CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,(CGFloat)size,NULL);
  else
    font=CTFontCreateWithName(name,(CGFloat)size,NULL);
  CFRelease(name);
  return font;
}

static int line_has_unsupported_glyphs(CTLineRef line, int *unknown) {
  CFArrayRef runs=CTLineGetGlyphRuns(line);
  *unknown=0;
  for (CFIndex r=0;r<CFArrayGetCount(runs);r++) {
    CTRunRef run=(CTRunRef)CFArrayGetValueAtIndex(runs,r);
    if (CTRunGetStatus(run)&kCTRunStatusRightToLeft) return 14;
    CFDictionaryRef attrs=CTRunGetAttributes(run);
    CTFontRef font=(CTFontRef)CFDictionaryGetValue(attrs,kCTFontAttributeName);
    if (font && (CTFontGetSymbolicTraits(font)&kCTFontTraitColorGlyphs)) return COLOR_GLYPH;
    CFIndex count=CTRunGetGlyphCount(run);
    if (count>MAX_TEXT) return RESOURCE_LIMIT;
    int last_resort=0;
    if (font) {
      CFStringRef postscript=CTFontCopyPostScriptName(font);
      if (postscript && CFStringCompare(postscript,CFSTR("LastResort"),0)==kCFCompareEqualTo) last_resort=1;
      if (postscript) CFRelease(postscript);
    }
    if (last_resort) *unknown += (int)count;
    CGGlyph *glyphs=count ? malloc((size_t)count*sizeof(*glyphs)) : NULL;
    if (count && !glyphs) return RESOURCE_LIMIT;
    if (count) CTRunGetGlyphs(run,CFRangeMake(0,0),glyphs);
    for (CFIndex i=0;i<count;i++) if (!last_resort&&glyphs[i]==0) (*unknown)++;
    free(glyphs);
  }
  return OK;
}

static int create_line(const uint8_t *text, int32_t text_len,
                       const uint8_t *family, int32_t family_len, double size,
                       CFStringRef *string_out, CTFontRef *font_out, CTLineRef *line_out,
                       Boundary **boundaries_out, int32_t *boundary_count_out,
                       int32_t *utf16_length_out, int *unknown_out) {
  if (!isfinite(size) || size<=0.0 || size>MAX_FONT_SIZE) return BAD_SIZE;
  if (family_len<=0 || family_len>MAX_FAMILY || !family) return BAD_FONT;
  Boundary *boundaries=NULL; int32_t boundary_count=0, units=0;
  int status=make_boundaries(text,text_len,&boundaries,&boundary_count,&units);
  if (status) return status;
  CFStringRef string=cf_string(text,text_len);
  CTFontRef font=make_font(family,family_len,size);
  if (!string || !font) {
    if (string) CFRelease(string); if (font) CFRelease(font); free(boundaries); return BAD_FONT;
  }
  const void *keys[]={kCTFontAttributeName,kCTForegroundColorFromContextAttributeName};
  const void *values[]={font,kCFBooleanTrue};
  CFDictionaryRef attrs=CFDictionaryCreate(kCFAllocatorDefault,keys,values,2,
    &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef attributed=attrs ? CFAttributedStringCreate(kCFAllocatorDefault,string,attrs) : NULL;
  CTLineRef line=attributed ? CTLineCreateWithAttributedString(attributed) : NULL;
  if (attrs) CFRelease(attrs); if (attributed) CFRelease(attributed);
  if (!line) { CFRelease(string); CFRelease(font); free(boundaries); return NATIVE_FAILURE; }
  int unknown=0;
  status=line_has_unsupported_glyphs(line,&unknown);
  if (status) { CFRelease(line); CFRelease(string); CFRelease(font); free(boundaries); return status; }
  for (int32_t i=1;i<boundary_count-1;i++) {
    CFRange composed=CFStringGetRangeOfComposedCharactersAtIndex(string,boundaries[i].utf16);
    boundaries[i].cursor=(composed.location==boundaries[i].utf16);
  }
  *string_out=string; *font_out=font; *line_out=line;
  *boundaries_out=boundaries; *boundary_count_out=boundary_count;
  *utf16_length_out=units; *unknown_out=unknown;
  return OK;
}

static void release_line(CFStringRef string, CTFontRef font, CTLineRef line, Boundary *boundaries) {
  if (line) CFRelease(line); if (font) CFRelease(font); if (string) CFRelease(string); free(boundaries);
}

static void layout_metrics(CTLineRef line, CTFontRef font, double *width, double *ascent,
                           double *descent, double *leading, CGRect *ink) {
  *width=CTLineGetTypographicBounds(line,ascent,descent,leading);
  *ink=CTLineGetImageBounds(line,NULL);
  if (*ascent+*descent+*leading<=0) {
    *ascent=CTFontGetAscent(font); *descent=CTFontGetDescent(font); *leading=CTFontGetLeading(font);
  }
  if (*ascent+*descent+*leading<=0) *ascent=1;
  if (CGRectIsNull(*ink)) *ink=CGRectMake(0,0,0,0);
}

int32_t gpui_macos_text_require_raster_v1(int32_t abi) {
  if (abi!=ABI) return BAD_ABI;
  CGColorSpaceRef color_space=CGColorSpaceCreateDeviceGray();
  if (!color_space) return RASTER_UNAVAILABLE;
  CGColorSpaceRelease(color_space);
  return OK;
}

int32_t gpui_macos_text_measure_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, double *out, int32_t cap) {
  if (abi!=ABI) return BAD_ABI;
  if (!out || cap<HEADER) return BAD_COORDINATE;
  if (!isfinite(size) || size<=0.0 || size>MAX_FONT_SIZE) return BAD_SIZE;
  CFStringRef string=NULL; CTFontRef font=NULL; CTLineRef line=NULL; Boundary *boundaries=NULL;
  int32_t count=0,units=0; int unknown=0;
  int status=create_line(text,text_len,family,family_len,size,&string,&font,&line,&boundaries,&count,&units,&unknown);
  if (status) return status;
  if ((int64_t)HEADER+(int64_t)CARET*count>cap) { release_line(string,font,line,boundaries); return SMALL_BUFFER; }
  double width=0,ascent=0,descent=0,leading=0; CGRect ink;
  layout_metrics(line,font,&width,&ascent,&descent,&leading,&ink);
  double height=ascent+descent+leading;
  if (!isfinite(width)||!isfinite(height)||width<0||height<0||height>1e6) {
    release_line(string,font,line,boundaries); return INVALID_RESULT;
  }
  out[0]=0; out[1]=0; out[2]=width; out[3]=height;
  out[4]=CGRectGetMinX(ink); out[5]=ascent-CGRectGetMaxY(ink);
  out[6]=CGRectGetWidth(ink); out[7]=CGRectGetHeight(ink);
  out[8]=ascent; out[9]=1; out[10]=unknown; out[11]=count;
  for (int32_t i=0;i<count;i++) {
    double secondary=0;
    double x=CTLineGetOffsetForStringIndex(line,boundaries[i].utf16,&secondary);
    if (!isfinite(x)||!isfinite(secondary)) { release_line(string,font,line,boundaries); return INVALID_RESULT; }
    if (fabs(x-secondary)>1.0/1024.0) { release_line(string,font,line,boundaries); return 14; }
    int at=HEADER+i*CARET;
    out[at]=(double)boundaries[i].byte; out[at+1]=boundaries[i].cursor?1:0;
    out[at+2]=x; out[at+3]=0; out[at+4]=0; out[at+5]=height;
    out[at+6]=x; out[at+7]=0; out[at+8]=0; out[at+9]=height;
  }
  release_line(string,font,line,boundaries); return OK;
}

int32_t gpui_macos_text_hit_test_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, double x, double y,
  double *out, int32_t cap) {
  if (abi!=ABI) return BAD_ABI;
  if (!out || cap<5 || !finite_bounded(x,1e20)||!finite_bounded(y,1e20)) return BAD_COORDINATE;
  CFStringRef string=NULL; CTFontRef font=NULL; CTLineRef line=NULL; Boundary *boundaries=NULL;
  int32_t count=0,units=0; int unknown=0;
  int status=create_line(text,text_len,family,family_len,size,&string,&font,&line,&boundaries,&count,&units,&unknown);
  if (status) return status;
  double width=0,ascent=0,descent=0,leading=0; CGRect ink;
  layout_metrics(line,font,&width,&ascent,&descent,&leading,&ink);
  double height=ascent+descent+leading, best=INFINITY; int32_t selected=0;
  for (int32_t i=0;i<count;i++) {
    if (!boundaries[i].cursor) continue;
    double secondary=0, caret=CTLineGetOffsetForStringIndex(line,boundaries[i].utf16,&secondary);
    double distance=fabs(x-caret);
    if (distance<best) { best=distance; selected=i; }
  }
  out[0]=boundaries[selected].byte; out[1]=0; out[2]=boundaries[selected].byte;
  out[3]=(x>=0 && x<=width && y>=0 && y<=height)?1:0; out[4]=1;
  release_line(string,font,line,boundaries); return OK;
}

int32_t gpui_macos_text_admit_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  double size, double x, double y, double clip_x, double clip_y,
  double clip_width, double clip_height) {
  if (abi!=ABI) return BAD_ABI;
  if (!isfinite(size)||size<=0||size>MAX_SCENE_SIZE) return BAD_SIZE;
  if (!finite_bounded(x,1e9)||!finite_bounded(y,1e9)||
      !finite_bounded(clip_x,1e9)||!finite_bounded(clip_y,1e9)||
      !isfinite(clip_width)||!isfinite(clip_height)||clip_width<0||clip_height<0)
    return BAD_COORDINATE;
  if (clip_width>MAX_SCENE_WIDTH||clip_height>MAX_SCENE_HEIGHT||text_len>MAX_SCENE_TEXT)
    return RESOURCE_LIMIT;
  const uint8_t sans[]="sans";
  CFStringRef string=NULL; CTFontRef font=NULL; CTLineRef line=NULL; Boundary *boundaries=NULL;
  int32_t count=0,units=0; int unknown=0;
  int status=create_line(text,text_len,sans,4,size,&string,&font,&line,&boundaries,&count,&units,&unknown);
  if (status) return status;
  if (unknown) { release_line(string,font,line,boundaries); return UNSUPPORTED_GLYPH; }
  double width=0,ascent=0,descent=0,leading=0; CGRect ink;
  layout_metrics(line,font,&width,&ascent,&descent,&leading,&ink);
  if (!isfinite(width)||width>1048576.0||!isfinite(ascent+descent+leading)) status=RESOURCE_LIMIT;
  release_line(string,font,line,boundaries);
  if (status) return status;
  double clip_right=clip_x+clip_width, clip_bottom=clip_y+clip_height;
  if (!isfinite(clip_right)||!isfinite(clip_bottom)||
      fabs(clip_right)>1e9||fabs(clip_bottom)>1e9||
      (clip_width>0&&clip_right<=clip_x)||(clip_height>0&&clip_bottom<=clip_y))
    return BAD_COORDINATE;
  GpuiMacTextMask mask={0};
  status=gpui_macos_text_raster_v1(text,text_len,size,2.0,&mask);
  if (status) { gpui_macos_text_raster_free(&mask); return status; }
  if (mask.width>16384||mask.height>2048||(int64_t)mask.width*mask.height>8*1024*1024)
    status=RESOURCE_LIMIT;
  double mask_left=x+mask.left, mask_top=y+mask.top;
  double mask_right=mask_left+(double)mask.width/2.0;
  double mask_bottom=mask_top+(double)mask.height/2.0;
  if (!finite_bounded(mask_left,1e9)||!finite_bounded(mask_top,1e9)||
      !finite_bounded(mask_right,1e9)||!finite_bounded(mask_bottom,1e9))
    status=BAD_COORDINATE;
  if (mask.width>0&&mask.height>0&&
      (fmin(mask_right,clip_right)<=fmax(mask_left,clip_x)||
       fmin(mask_bottom,clip_bottom)<=fmax(mask_top,clip_y)))
    status=UNSUPPORTED_INPUT;
  gpui_macos_text_raster_free(&mask);
  return status;
}

int32_t gpui_macos_text_raster_v1(const uint8_t *text, int32_t text_len, double size,
  double scale, GpuiMacTextMask *out) {
  if (!out) return BAD_COORDINATE;
  memset(out,0,sizeof(*out));
  if (!isfinite(scale)||scale<1||scale>2) return BAD_COORDINATE;
  const uint8_t sans[]="sans";
  CFStringRef string=NULL; CTFontRef font=NULL; CTLineRef line=NULL; Boundary *boundaries=NULL;
  int32_t count=0,units=0; int unknown=0;
  int status=create_line(text,text_len,sans,4,size,&string,&font,&line,&boundaries,&count,&units,&unknown);
  if (status) return status;
  if (unknown) { release_line(string,font,line,boundaries); return UNSUPPORTED_GLYPH; }
  double width=0,ascent=0,descent=0,leading=0; CGRect ink;
  layout_metrics(line,font,&width,&ascent,&descent,&leading,&ink);
  if (CGRectIsEmpty(ink)) { release_line(string,font,line,boundaries); return OK; }
  double left=floor(CGRectGetMinX(ink)*scale)/scale;
  double top=floor((ascent-CGRectGetMaxY(ink))*scale)/scale;
  double right=ceil(CGRectGetMaxX(ink)*scale)/scale;
  double bottom=ceil((ascent-CGRectGetMinY(ink))*scale)/scale;
  int w=(int)ceil((right-left)*scale), h=(int)ceil((bottom-top)*scale);
  if (w<=0||h<=0||w>16384||h>2048||(int64_t)w*h>8*1024*1024) {
    release_line(string,font,line,boundaries); return RESOURCE_LIMIT;
  }
  uint8_t *pixels=calloc((size_t)w,(size_t)h);
  CGColorSpaceRef gray=CGColorSpaceCreateDeviceGray();
  CGContextRef context=gray?CGBitmapContextCreate(pixels,w,h,8,w,gray,kCGImageAlphaNone):NULL;
  if (gray) CGColorSpaceRelease(gray);
  if (!pixels||!context) { free(pixels); if(context)CGContextRelease(context); release_line(string,font,line,boundaries); return RASTER_UNAVAILABLE; }
  CGContextSetAllowsAntialiasing(context,true); CGContextSetShouldAntialias(context,true);
  CGContextSetGrayFillColor(context,1,1);
  /* Make a top-left, logical-pixel mask while drawing the same CTLine/CTFont. */
  CGContextTranslateCTM(context,0,h); CGContextScaleCTM(context,scale,-scale);
  CGContextTranslateCTM(context,-left,-top);
  CGContextSetTextMatrix(context,CGAffineTransformMakeScale(1.0,-1.0));
  CGContextSetTextPosition(context,0,ascent);
  CTLineDraw(line,context);
  CGContextRelease(context);
  out->pixels=pixels; out->width=w; out->height=h; out->stride=w; out->left=left; out->top=top;
  release_line(string,font,line,boundaries); return OK;
}

void gpui_macos_text_raster_free(GpuiMacTextMask *mask) {
  if (!mask) return; free(mask->pixels); memset(mask,0,sizeof(*mask));
}

static int append_bytes(const void *bytes, int32_t length, uint8_t *out, int32_t cap, int32_t *at) {
  if (length<0 || *at>cap || length>cap-*at) return SMALL_BUFFER;
  if (length) memcpy(out+*at,bytes,(size_t)length);
  *at+=length; return OK;
}

static int append_json_string(CFStringRef string, uint8_t *out, int32_t cap, int32_t *at) {
  if (!string) return append_bytes("null",4,out,cap,at);
  CFIndex length=CFStringGetLength(string), max=CFStringGetMaximumSizeForEncoding(length,kCFStringEncodingUTF8);
  if (max<0||max>65536) return RESOURCE_LIMIT;
  uint8_t *utf8=malloc((size_t)max+1);
  if (!utf8) return RESOURCE_LIMIT;
  CFIndex used=0;
  if (!CFStringGetBytes(string,CFRangeMake(0,length),kCFStringEncodingUTF8,0,false,utf8,max,&used)) {
    free(utf8); return NATIVE_FAILURE;
  }
  int status=append_bytes("\"",1,out,cap,at);
  static const char hex[]="0123456789abcdef";
  for (CFIndex i=0;!status&&i<used;i++) {
    uint8_t c=utf8[i];
    if (c=='"'||c=='\\') {
      uint8_t escaped[2]={'\\',c}; status=append_bytes(escaped,2,out,cap,at);
    } else if (c<0x20) {
      uint8_t escaped[6]={'\\','u','0','0',(uint8_t)hex[c>>4],(uint8_t)hex[c&15]};
      status=append_bytes(escaped,6,out,cap,at);
    } else {
      status=append_bytes(&c,1,out,cap,at);
    }
  }
  if (!status) status=append_bytes("\"",1,out,cap,at);
  free(utf8); return status;
}

static const char *run_segment(CFStringRef text, CFRange range) {
  int latin=0, japanese=0;
  CFIndex end=range.location+range.length;
  if (range.location<0 || range.length<0 || end>CFStringGetLength(text)) return "other";
  for (CFIndex i=range.location;i<end;i++) {
    uint32_t cp=CFStringGetCharacterAtIndex(text,i);
    if ((cp>=0x3040&&cp<=0x30FF)||(cp>=0x3400&&cp<=0x9FFF)||
        (cp>=0xF900&&cp<=0xFAFF)||(cp>=0xFF66&&cp<=0xFF9D)) japanese=1;
    if ((cp>='A'&&cp<='Z')||(cp>='a'&&cp<='z')) latin=1;
  }
  if (japanese) return "japanese";
  if (latin) return "latin";
  return "other";
}

int32_t gpui_macos_text_fonts_json_v1(const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, uint8_t *out, int32_t cap) {
  if (!out) return -BAD_COORDINATE;
  if (cap<3) return -SMALL_BUFFER;
  CFStringRef string=NULL; CTFontRef font=NULL; CTLineRef line=NULL; Boundary *boundaries=NULL;
  int32_t count=0,units=0; int unknown=0;
  int status=create_line(text,text_len,family,family_len,size,&string,&font,&line,&boundaries,&count,&units,&unknown);
  if (status) return -status;
  int32_t at=0;
  const char prefix[]="{\"schema_version\":1,\"fonts\":[";
  status=append_bytes(prefix,(int32_t)sizeof(prefix)-1,out,cap,&at);
  CFArrayRef runs=CTLineGetGlyphRuns(line);
  CFMutableSetRef seen=CFSetCreateMutable(kCFAllocatorDefault,0,&kCFTypeSetCallBacks);
  if (!seen) status=RESOURCE_LIMIT;
  int wrote=0;
  for (CFIndex i=0;!status&&i<CFArrayGetCount(runs);i++) {
    CTRunRef run=(CTRunRef)CFArrayGetValueAtIndex(runs,i);
    CTFontRef run_font=(CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run),kCTFontAttributeName);
    if (!run_font) continue;
    const char *segment=run_segment(string,CTRunGetStringRange(run));
    CFStringRef family_name=CTFontCopyFamilyName(run_font);
    CFStringRef ps_name=CTFontCopyPostScriptName(run_font);
    CFURLRef url=(CFURLRef)CTFontCopyAttribute(run_font,kCTFontURLAttribute);
    CFStringRef url_text=url ? CFURLCopyFileSystemPath(url,kCFURLPOSIXPathStyle) : NULL;
    if (!family_name||!ps_name||!url_text) status=NATIVE_FAILURE;
    CFStringRef identity=NULL;
    if (!status) {
      CFStringRef segment_name=CFStringCreateWithCString(kCFAllocatorDefault,segment,kCFStringEncodingASCII);
      identity=segment_name ? CFStringCreateWithFormat(kCFAllocatorDefault,NULL,
        CFSTR("%@|%@|%@"),segment_name,ps_name,url_text) : NULL;
      if (segment_name) CFRelease(segment_name);
      if (!identity) status=RESOURCE_LIMIT;
    }
    if (!status&&CFSetContainsValue(seen,identity)) {
      CFRelease(identity);
      if (family_name) CFRelease(family_name); if (ps_name) CFRelease(ps_name);
      if (url_text) CFRelease(url_text); if (url) CFRelease(url);
      continue;
    }
    if (!status) CFSetAddValue(seen,identity);
    if (identity) CFRelease(identity);
    if (wrote&&!status) status=append_bytes(",",1,out,cap,&at);
    const char a[]={"{\"segment\":\""};
    if (!status) status=append_bytes(a,(int32_t)sizeof(a)-1,out,cap,&at);
    if (!status) status=append_bytes(segment,(int32_t)strlen(segment),out,cap,&at);
    if (!status) {
      const char family_key[]="\",\"family\":";
      status=append_bytes(family_key,(int32_t)sizeof(family_key)-1,out,cap,&at);
    }
    if (!status) status=append_json_string(family_name,out,cap,&at);
    if (!status) {
      const char b[]={",\"postscript_name\":"};
      status=append_bytes(b,(int32_t)sizeof(b)-1,out,cap,&at);
    }
    if (!status) status=append_json_string(ps_name,out,cap,&at);
    if (!status) {
      const char c[]={",\"file_url\":"};
      status=append_bytes(c,(int32_t)sizeof(c)-1,out,cap,&at);
    }
    if (!status) status=append_json_string(url_text,out,cap,&at);
    if (!status) {
      status=append_bytes("}",1,out,cap,&at);
    }
    if (family_name) CFRelease(family_name); if (ps_name) CFRelease(ps_name);
    if (url_text) CFRelease(url_text); if (url) CFRelease(url);
    if (!status) wrote++;
  }
  if (seen) CFRelease(seen);
  if (!status) {
    status=append_bytes("]}",2,out,cap,&at);
  }
  release_line(string,font,line,boundaries);
  return status?-status:at;
}

#else
enum { UNSUPPORTED=9 };
int32_t gpui_macos_text_require_raster_v1(int32_t abi){(void)abi;return UNSUPPORTED;}
int32_t gpui_macos_text_measure_v1(int32_t a,const uint8_t*t,int32_t tl,const uint8_t*f,int32_t fl,double s,double*o,int32_t c){(void)a;(void)t;(void)tl;(void)f;(void)fl;(void)s;(void)o;(void)c;return UNSUPPORTED;}
int32_t gpui_macos_text_hit_test_v1(int32_t a,const uint8_t*t,int32_t tl,const uint8_t*f,int32_t fl,double s,double x,double y,double*o,int32_t c){(void)a;(void)t;(void)tl;(void)f;(void)fl;(void)s;(void)x;(void)y;(void)o;(void)c;return UNSUPPORTED;}
int32_t gpui_macos_text_admit_v1(int32_t a,const uint8_t*t,int32_t tl,double s,double x,double y,double cx,double cy,double w,double h){(void)a;(void)t;(void)tl;(void)s;(void)x;(void)y;(void)cx;(void)cy;(void)w;(void)h;return UNSUPPORTED;}
int32_t gpui_macos_text_raster_v1(const uint8_t*t,int32_t l,double s,double sc,GpuiMacTextMask*o){(void)t;(void)l;(void)s;(void)sc;(void)o;return UNSUPPORTED;}
void gpui_macos_text_raster_free(GpuiMacTextMask*m){(void)m;}
int32_t gpui_macos_text_fonts_json_v1(const uint8_t*t,int32_t l,const uint8_t*f,int32_t fl,double s,uint8_t*o,int32_t c){(void)t;(void)l;(void)f;(void)fl;(void)s;(void)o;(void)c;return -UNSUPPORTED;}
#endif
