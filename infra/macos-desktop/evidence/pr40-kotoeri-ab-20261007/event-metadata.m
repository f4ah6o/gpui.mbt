#define GPUI_TESTING 1
#import "/Users/fu2hito/.codex/worktrees/17c6/gpui.mbt/platform/macos/native.m"
#import <Carbon/Carbon.h>
int main(void) { @autoreleasepool {
 [NSApplication sharedApplication];
 int codes[]={45,49,36}; NSString *chars[]={@"n",@" ",@"\r"};
 for (int i=0;i<3;i++) {int s=0; NSArray *pair=create_app_local_key_events(codes[i],0,i+1,chars[i],chars[i],&s);
 for(NSEvent *e in pair) {EventRef r=(EventRef)e.eventRef; UInt32 c=0,k=0; char ch=0; UniChar u=0;
 OSStatus a=GetEventParameter(r,kEventParamKeyMacCharCodes,typeChar,NULL,sizeof(ch),NULL,&ch);
 OSStatus b=GetEventParameter(r,kEventParamKeyCode,typeUInt32,NULL,sizeof(c),NULL,&c);
 OSStatus d=GetEventParameter(r,kEventParamKeyboardType,typeUInt32,NULL,sizeof(k),NULL,&k);
 OSStatus f=GetEventParameter(r,kEventParamKeyUnicodes,typeUnicodeText,NULL,sizeof(u),NULL,&u);
 printf("key=%d type=%ld timestamp=%f cgTimestamp=%llu flags=%llx keyCode=%u status=%d macchar=%d status=%d unicode=%u status=%d keyboard=%u status=%d\n",codes[i],(long)e.type,e.timestamp,(unsigned long long)CGEventGetTimestamp(e.CGEvent),(unsigned long long)e.modifierFlags,c,b,ch,a,u,f,k,d);
 }}
 }return 0;}
