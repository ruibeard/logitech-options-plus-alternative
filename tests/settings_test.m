#define main mx_settings_application_main
#import "../src/settings.m"
#undef main
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>

@interface SettingsTestDelegate : SettingsDelegate
@property NSDictionary *testStatus;
@end
@implementation SettingsTestDelegate
- (void)alert:(NSString *)message { fprintf(stderr,"Unexpected alert: %s\n",message.UTF8String); abort(); }
- (void)post:(NSString *)name { (void)name; }
- (void)refresh:(id)sender { (void)sender; [self updateDevice:self.testStatus]; }
@end

static NSDictionary *control(unsigned cid, int slot, NSString *name) {
    return @{@"cid":@(cid),@"slot":@(slot),@"name":name,@"divertible":@YES};
}
static NSDictionary *device(NSString *identity, NSString *name, NSArray *controls) {
    return @{@"id":identity,@"name":name,@"connected":@YES,@"controls":controls,@"capabilities":@{@"verticalScroll":@YES,@"wheelMode":@YES,@"smartShift":@YES,@"dpi":@YES,@"horizontalScroll":@YES}};
}
static SettingsTestDelegate *editor(void) {
    SettingsTestDelegate *ui=[SettingsTestDelegate new];
    ui.deviceSelector=[[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    ui.modes=[NSMutableArray new]; ui.recorders=[NSMutableArray new]; ui.buttonPanes=[NSMutableArray new];
    for(NSUInteger i=0;i<MX_BUTTON_COUNT+MX_EXTRA_BUTTON_COUNT;++i) {
        NSPopUpButton *mode=[[NSPopUpButton alloc] initWithFrame:NSZeroRect];
        [mode addItemsWithTitles:@[@"Mouse default",@"Keyboard shortcut",@"Do nothing"]]; mode.tag=(NSInteger)i;
        [ui.modes addObject:mode]; [ui.recorders addObject:[MXRecorder new]]; [ui.buttonPanes addObject:[NSView new]];
    }
    ui.wheelMode=[[NSPopUpButton alloc] initWithFrame:NSZeroRect]; [ui.wheelMode addItemsWithTitles:@[@"Leave unchanged",@"Ratchet",@"Free spin",@"SmartShift"]];
    ui.dpi=[[NSPopUpButton alloc] initWithFrame:NSZeroRect]; ui.verticalSpeed=[NSSlider new]; ui.verticalSpeed.maxValue=300;
    ui.horizontalSpeed=[NSSlider new]; ui.horizontalSpeed.maxValue=300;
    ui.invertVertical=[NSButton new]; ui.invertHorizontal=[NSButton new]; ui.smooth=[NSButton new];
    ui.verticalValue=[NSTextField new]; ui.deviceSubtitle=[NSTextField new];
    ui.verticalViews=[@[ui.verticalSpeed,ui.verticalValue,ui.invertVertical,ui.smooth] mutableCopy];
    ui.selectedButton=3;
    return ui;
}
static NSDictionary *binding(int key) { return @{@"mode":@1,@"keyCode":@(key),@"modifiers":@(1<<20)}; }
static void setShortcut(SettingsTestDelegate *ui, unsigned cid, int key) {
    for(NSDictionary *item in ui.availableControls) if([item[@"cid"] unsignedIntValue]==cid) {
        NSUInteger slot=[item[@"slot"] unsignedIntegerValue]; [ui.modes[slot] selectItemAtIndex:MX_SHORTCUT]; ui.recorders[slot].keyCode=key; ui.recorders[slot].shortcutModifiers=1<<20; return;
    }
    assert(!"Missing expected discovered control");
}
int main(void) {
    @autoreleasepool {
        char temporary[]="/tmp/mx-settings-test-XXXXXX"; assert(mkdtemp(temporary)); assert(!setenv("HOME",temporary,1));
        assert([[NSFileManager defaultManager] createDirectoryAtPath:[@(temporary) stringByAppendingPathComponent:@"Library/Application Support"] withIntermediateDirectories:YES attributes:nil error:nil]);
        [NSApplication sharedApplication];
        NSDictionary *legacy=@{@"buttons":@{@"thumb":binding(21),@"back":binding(33)},@"verticalSpeed":@79,@"smooth":@YES,@"invertVertical":@YES,@"devices":@{@"mx4":@{@"dpi":@8000},@"m705":@{@"controls":@{@"00c3":binding(49)}},@"other":@{@"verticalSpeed":@123}}};
        assert(mx_write_plist(supportPath(@"settings.plist").fileSystemRepresentation,(__bridge CFDictionaryRef)legacy));
        NSDictionary *mx4=device(@"mx4",@"MX Master 4",@[control(0x52,0,@"Middle"),control(0x53,1,@"Back"),control(0xc3,3,@"Gesture"),control(0x1a0,-1,@"Haptic panel"),control(0x1ff,-1,@"Additional control"),control(0xbd,1,@"Second back")]);
        NSDictionary *m705=device(@"m705",@"Logitech M705",@[control(0x52,0,@"Middle"),control(0x53,1,@"Back"),control(0x56,2,@"Forward")]);
        SettingsTestDelegate *ui=editor(); ui.testStatus=@{@"devices":@[mx4,m705]}; [ui refresh:nil];
        assert([ui.selectedDeviceID isEqual:@"mx4"] && ui.genericMouse);
        assert(ui.availableControls.count==6 && ui.dpi.titleOfSelectedItem.intValue==8000);
        NSDictionary *unknown=ui.availableControls[4], *duplicate=ui.availableControls[5];
        NSUInteger unknownSlot=[unknown[@"slot"] unsignedIntegerValue], duplicateSlot=[duplicate[@"slot"] unsignedIntegerValue];
        assert(ui.modes[unknownSlot].indexOfSelectedItem==MX_NATIVE);
        assert(duplicateSlot>=MX_BUTTON_COUNT && ui.modes[duplicateSlot].indexOfSelectedItem==MX_SHORTCUT);
        setShortcut(ui,0xc3,21); setShortcut(ui,0x1a0,49); setShortcut(ui,0xbd,30);
        [ui settingsChanged:nil]; assert(ui.pendingApply);
        NSDictionary *after=readDictionary(supportPath(@"settings.plist"));
        assert([after[@"buttons"] isEqual:legacy[@"buttons"]] && [after[@"devices"][@"other"] isEqual:legacy[@"devices"][@"other"]]);
        MXConfig config; char error[256]; assert(mx_load_device_config(&config,"mx4",error,sizeof(error)));
        assert(mx_binding_for_control(&config,0xc3,3)->key==21 && mx_binding_for_control(&config,0x1a0,-1)->key==49);
        assert(mx_binding_for_control(&config,0xbd,1)->key==30 && mx_binding_for_control(&config,0x53,1)->key==33);
        // Switching flushes the previous profile's pending reload, then loads the selected profile.
        [ui.deviceSelector selectItemAtIndex:1]; [ui deviceChanged:ui.deviceSelector];
        assert(!ui.pendingApply && [ui.selectedDeviceID isEqual:@"m705"] && ![ui controlForSlot:3]);
        [ui.modes[3] selectItemAtIndex:MX_DISABLED]; ui.verticalSpeed.integerValue=140; assert([ui save]);
        after=readDictionary(supportPath(@"settings.plist"));
        assert([after[@"devices"][@"m705"][@"buttons"][@"thumb"] isEqual:legacy[@"buttons"][@"thumb"]]);
        assert([after[@"devices"][@"m705"][@"controls"][@"00c3"] isEqual:binding(49)] && [after[@"devices"][@"mx4"][@"dpi"] intValue]==8000);
        assert(mx_load_device_config(&config,"m705",error,sizeof(error)) && config.vertical_speed==140);
        assert(!ui.verticalSpeed.hidden && !ui.smooth.hidden);
        NSMutableDictionary *unsupported=[m705 mutableCopy];
        NSMutableDictionary *unsupportedCapabilities=[m705[@"capabilities"] mutableCopy]; unsupportedCapabilities[@"verticalScroll"]=@NO;
        unsupported[@"capabilities"]=unsupportedCapabilities; unsupported[@"transport"]=@"Unifying receiver";
        ui.testStatus=@{@"devices":@[mx4,unsupported]}; [ui refresh:nil];
        for(NSView *view in ui.verticalViews) assert(view.hidden);
        assert([ui.deviceSubtitle.stringValue containsString:@"UNIFYING RECEIVER"]);
        ui.verticalSpeed.integerValue=200; ui.invertVertical.state=NSControlStateValueOff; ui.smooth.state=NSControlStateValueOff;
        assert([ui save] && mx_load_device_config(&config,"m705",error,sizeof(error)));
        assert(config.vertical_speed==140 && config.invert_vertical && config.smooth);
        // If the selected mouse disappears, fallback loads the remaining profile without saving stale UI values into it.
        NSDictionary *savedMX4=after[@"devices"][@"mx4"];
        ui.testStatus=@{@"devices":@[mx4]}; [ui refresh:nil];
        assert([ui.selectedDeviceID isEqual:@"mx4"] && ui.verticalSpeed.integerValue==79);
        assert([readDictionary(supportPath(@"settings.plist"))[@"devices"][@"mx4"] isEqual:savedMX4]);
        // Existing explicit overrides must be updated when editing a legacy-slot control.
        setShortcut(ui,0xc3,50); assert([ui save]); assert(mx_load_device_config(&config,"mx4",error,sizeof(error)));
        assert(mx_binding_for_control(&config,0xc3,3)->key==50);
        assert(![ui canImportOptions]);
        NSDictionary *master3=device(@"master3",@"MX Master 3 for Mac",@[control(0xc3,3,@"Gesture")]);
        ui.testStatus=@{@"devices":@[master3]}; [ui refresh:nil]; assert([ui canImportOptions]);
        NSDictionary *imported=[ui settingsByImportingProfile:@{@"buttons":@{@"thumb":binding(49)}} intoSettings:after];
        assert([imported[@"buttons"] isEqual:legacy[@"buttons"]] && [imported[@"devices"][@"mx4"] isEqual:after[@"devices"][@"mx4"]]);
        assert([imported[@"devices"][@"master3"][@"buttons"][@"thumb"][@"keyCode"] intValue]==49);
        // Fresh settings windows prefer a connected mouse over stale offline entries.
        NSMutableDictionary *offlineMaster=[master3 mutableCopy]; offlineMaster[@"connected"]=@NO; offlineMaster[@"state"]=@"error";
        SettingsTestDelegate *fresh=editor(); fresh.testStatus=@{@"devices":@[offlineMaster,m705]}; [fresh refresh:nil];
        assert([fresh.selectedDeviceID isEqual:@"m705"] && fresh.deviceSelector.indexOfSelectedItem==1);
        // A deliberate selection of an offline mouse remains stable while another is active.
        [fresh.deviceSelector selectItemAtIndex:0]; [fresh deviceChanged:fresh.deviceSelector]; [fresh refresh:nil];
        assert([fresh.selectedDeviceID isEqual:@"master3"] && ![fresh.selectedDevice[@"connected"] boolValue]);
        // With no connected devices, the first saved device remains a useful fallback.
        SettingsTestDelegate *allOffline=editor(); NSMutableDictionary *offlineM705=[m705 mutableCopy]; offlineM705[@"connected"]=@NO;
        allOffline.testStatus=@{@"devices":@[offlineMaster,offlineM705]}; [allOffline refresh:nil];
        assert([allOffline.selectedDeviceID isEqual:@"master3"]);
        [NSObject cancelPreviousPerformRequestsWithTarget:ui];
        [[NSFileManager defaultManager] removeItemAtPath:@(temporary) error:nil];
        puts("Settings profile, discovered control, switching, and import tests passed.");
    }
    return 0;
}
