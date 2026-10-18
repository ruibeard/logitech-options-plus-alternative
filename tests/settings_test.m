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
    ui.deviceSidebar=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,164,650)];
    ui.showSavedDevices=[NSButton checkboxWithTitle:@"Show previous pairings" target:nil action:nil];
    ui.deviceSidebar.documentView=[[NSView alloc] initWithFrame:ui.deviceSidebar.bounds];
    ui.mouseView=[[MXMouseView alloc] initWithFrame:NSZeroRect];
    ui.diagramLines=[[MXDiagram alloc] initWithFrame:NSZeroRect];
    ui.controlList=[[NSScrollView alloc] initWithFrame:NSZeroRect];
    ui.callouts=[NSMutableArray new]; ui.extraCallouts=[NSMutableArray new];
    for(NSUInteger i=0;i<6;++i) {
        MXCallout *callout=[MXCallout new]; callout.tag=(NSInteger)i; [ui.callouts addObject:callout];
    }
    for(NSUInteger i=0;i<MX_EXTRA_BUTTON_COUNT;++i) {
        MXCallout *callout=[MXCallout new]; callout.tag=(NSInteger)(i+MX_BUTTON_COUNT); [ui.extraCallouts addObject:callout];
    }
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
        [ui.deviceButtons[1] performClick:nil];
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
        // A disappearing mouse remains selected with its saved layout and profile.
        NSDictionary *savedMX4=after[@"devices"][@"mx4"];
        ui.testStatus=@{@"devices":@[mx4]}; [ui refresh:nil];
        assert([ui.selectedDeviceID isEqual:@"m705"] && ![ui.selectedDevice[@"connected"] boolValue]);
        assert(ui.availableControls.count==3 && !ui.mouseView.hidden);
        ui.selectedDeviceID=@"mx4"; ui.selectedDevice=nil; [ui refresh:nil];
        assert([ui.selectedDeviceID isEqual:@"mx4"] && ui.verticalSpeed.integerValue==79);
        assert([readDictionary(supportPath(@"settings.plist"))[@"devices"][@"mx4"] isEqual:savedMX4]);
        // Existing explicit overrides must be updated when editing a legacy-slot control.
        setShortcut(ui,0xc3,50); assert([ui save]); assert(mx_load_device_config(&config,"mx4",error,sizeof(error)));
        assert(mx_binding_for_control(&config,0xc3,3)->key==50);
        assert(![ui canImportOptions]);
        NSDictionary *master3=device(@"master3",@"MX Master 3 for Mac",@[control(0xc3,3,@"Gesture")]);
        ui.selectedDeviceID=@"master3"; ui.selectedDevice=nil; ui.testStatus=@{@"devices":@[master3]}; [ui refresh:nil]; assert([ui canImportOptions]);
        NSDictionary *imported=[ui settingsByImportingProfile:@{@"buttons":@{@"thumb":binding(49)}} intoSettings:after];
        assert([imported[@"buttons"] isEqual:legacy[@"buttons"]] && [imported[@"devices"][@"mx4"] isEqual:after[@"devices"][@"mx4"]]);
        assert([imported[@"devices"][@"master3"][@"buttons"][@"thumb"][@"keyCode"] intValue]==49);
        // Fresh settings windows prefer a connected mouse over stale offline entries.
        NSMutableDictionary *offlineMaster=[master3 mutableCopy]; offlineMaster[@"connected"]=@NO; offlineMaster[@"state"]=@"error";
        SettingsTestDelegate *fresh=editor(); fresh.testStatus=@{@"devices":@[offlineMaster,m705]}; [fresh refresh:nil];
        assert([fresh.selectedDeviceID isEqual:@"m705"] && fresh.deviceButtons[1].state==NSControlStateValueOn);
        // A deliberate selection of an offline mouse remains stable while another is active.
        [fresh.deviceButtons[0] performClick:nil]; [fresh refresh:nil];
        assert([fresh.selectedDeviceID isEqual:@"master3"] && ![fresh.selectedDevice[@"connected"] boolValue]);
        // Wheel tilt requires the list while retaining the known M705 artwork.
        NSDictionary *tiltM705=device(@"m705",@"M705",@[control(0x52,0,@"Middle"),control(0x5b,-1,@"Wheel tilt left"),control(0x5d,-1,@"Wheel tilt right")]);
        fresh.selectedDeviceID=@"m705"; fresh.testStatus=@{@"devices":@[tiltM705]}; [fresh refresh:nil];
        assert(!fresh.genericMouse && !fresh.mouseView.hidden && fresh.mouseView.compactMouse);
        assert(fresh.controlList.hidden && !fresh.diagramLines.hidden);
        assert(fresh.diagramLines.mappedControls.count==3);
        assert(!fresh.extraCallouts[0].hidden && !fresh.extraCallouts[1].hidden);
        [fresh selectButton:fresh.extraCallouts[1]];
        assert([fresh controlForSlot:(NSUInteger)fresh.selectedButton][@"cid"] && fresh.selectedButton==6);
        fresh.selectedDeviceID=@"master3"; fresh.testStatus=@{@"devices":@[master3]}; [fresh refresh:nil];
        assert(!fresh.genericMouse && !fresh.mouseView.hidden && fresh.controlList.hidden);
        assert(fresh.extraCallouts[0].hidden && !fresh.diagramLines.mappedControls);
        assert(NSEqualRects(fresh.callouts[0].frame,NSMakeRect(432,340,177,72)));
        fresh.selectedDeviceID=@"mx4"; fresh.testStatus=@{@"devices":@[mx4]}; [fresh refresh:nil];
        assert(fresh.genericMouse && fresh.mouseView.hidden && !fresh.controlList.hidden);
        // Known mice keep inline editors for extra controls without a side table.
        NSMutableDictionary *extendedMaster=[master3 mutableCopy];
        extendedMaster[@"controls"]=@[control(0x52,0,@"Middle"),control(0xc3,3,@"Gesture"),control(0xd7,-1,@"Additional control")];
        fresh.selectedDeviceID=@"master3"; fresh.testStatus=@{@"devices":@[extendedMaster]}; [fresh refresh:nil];
        assert(!fresh.genericMouse && !fresh.mouseView.hidden && !fresh.diagramLines.hidden);
        assert(fresh.controlList.hidden && !fresh.extraCallouts[0].hidden);
        assert(!fresh.callouts[0].hidden && !fresh.callouts[3].hidden);
        assert(NSEqualRects(fresh.mouseView.frame,NSMakeRect(205,10,270,430)));
        [fresh selectButton:fresh.extraCallouts[0]];
        assert(fresh.selectedButton==MX_BUTTON_COUNT);
        [fresh selectButton:fresh.callouts[3]];
        assert(fresh.selectedButton==3);
        NSMutableDictionary *offlineExtended=[extendedMaster mutableCopy]; offlineExtended[@"connected"]=@NO;
        offlineExtended[@"controls"]=@[]; offlineExtended[@"capabilities"]=@{};
        fresh.testStatus=@{@"devices":@[offlineExtended]}; [fresh refresh:nil];
        assert(!fresh.diagramLines.hidden && !fresh.callouts[3].hidden);
        assert(fresh.availableControls.count==3);
        // A fresh window after helper restart restores the layout with empty offline status.
        SettingsTestDelegate *reopened=editor(); reopened.selectedDeviceID=@"m705";
        NSMutableDictionary *sleeping=[tiltM705 mutableCopy]; sleeping[@"connected"]=@NO;
        sleeping[@"controls"]=@[]; sleeping[@"capabilities"]=@{};
        reopened.testStatus=@{@"devices":@[sleeping]}; [reopened refresh:nil];
        assert(reopened.availableControls.count==3 && reopened.diagramLines.mappedControls.count==3);
        assert([reopened hasCapability:@"verticalScroll"] && ![reopened.selectedDevice[@"connected"] boolValue]);
        assert(mx_load_device_config(&config,"m705",error,sizeof(error)) && config.vertical_speed==140);
        // Offline shortcut edits survive restart and use the same profile on reconnect.
        setShortcut(reopened,0x52,42); assert([reopened save]);
        assert(mx_load_device_config(&config,"m705",error,sizeof(error)));
        assert(mx_binding_for_control(&config,0x52,0)->key==42);
        SettingsTestDelegate *offlineEditor=editor(); offlineEditor.selectedDeviceID=@"m705";
        offlineEditor.testStatus=@{@"devices":@[sleeping]}; [offlineEditor refresh:nil];
        assert(offlineEditor.recorders[0].keyCode==42);
        offlineEditor.testStatus=@{@"devices":@[tiltM705]}; [offlineEditor refresh:nil];
        assert(offlineEditor.recorders[0].keyCode==42);
        // New live discovery replaces cached controls, including removal of a thumb.
        reopened.testStatus=@{@"devices":@[m705]}; [reopened refresh:nil];
        assert(![reopened controlForSlot:5] && reopened.availableControls.count==3);
        // A never-seen variant gets no guessed controls.
        NSDictionary *unseen=@{@"id":@"unknown-m705",@"name":@"M705",@"connected":@NO,@"controls":@[]};
        reopened.selectedDeviceID=@"unknown-m705"; reopened.testStatus=@{@"devices":@[unseen]}; [reopened refresh:nil];
        assert(reopened.availableControls.count==0);
        NSDictionary *legacyOffline=@{@"id":@"logitech-4082-old-install-2",@"name":@"MX Master 3",@"connected":@NO,@"controls":@[],@"capabilities":@{}};
        reopened.selectedDeviceID=legacyOffline[@"id"]; reopened.testStatus=@{@"devices":@[legacyOffline]}; [reopened refresh:nil];
        assert(reopened.availableControls.count==5 && [reopened hasCapability:@"horizontalScroll"]);
        assert(!reopened.mouseView.hidden && !reopened.diagramLines.hidden);
        // With no connected devices, the first saved device remains a useful fallback.
        SettingsTestDelegate *allOffline=editor(); NSMutableDictionary *offlineM705=[m705 mutableCopy]; offlineM705[@"connected"]=@NO;
        allOffline.testStatus=@{@"devices":@[offlineMaster,offlineM705]}; [allOffline refresh:nil];
        assert([allOffline.selectedDeviceID isEqual:@"master3"]);
        // Historical pairings stay cached but never inflate the current device list.
        SettingsTestDelegate *sidebar=editor(); sidebar.testStatus=@{@"devices":@[m705,m705]};
        [sidebar refresh:nil];
        assert(sidebar.devices.count==1 && [sidebar.devices[0][@"id"] isEqual:@"m705"]);
        [sidebar refresh:nil];
        assert(sidebar.devices.count==1 && readDictionary(supportPath(@"known-devices.plist"))[@"mx4"]);
        sidebar.testStatus=@{@"devices":@[offlineM705]}; [sidebar refresh:nil];
        assert(sidebar.devices.count==1 && ![sidebar.selectedDevice[@"connected"] boolValue]);
        assert(sidebar.availableControls.count==3);
        NSDictionary *secondM705=device(@"second-m705",@"Logitech M705",m705[@"controls"]);
        sidebar.testStatus=@{@"devices":@[m705,secondM705]}; [sidebar refresh:nil];
        assert(sidebar.devices.count==2);
        assert(readDictionary(supportPath(@"known-devices.plist"))[@"mx4"]);
        // History must not repeat current models under their old connection IDs.
        NSDictionary *oldM705=device(@"old-receiver-m705",@"M705",m705[@"controls"]);
        NSDictionary *oldMaster=device(@"old-receiver-master",@"MX Master 3",master3[@"controls"]);
        NSDictionary *oldBluetooth=device(@"old-bluetooth-master",@"MX Master 3 for Mac",master3[@"controls"]);
        NSDictionary *cache=@{@"old-receiver-m705":oldM705,@"old-receiver-master":oldMaster,@"old-bluetooth-master":oldBluetooth};
        assert(mx_write_plist(supportPath(@"known-devices.plist").fileSystemRepresentation,(__bridge CFDictionaryRef)cache));
        sidebar.selectedDeviceID=nil; sidebar.selectedDevice=nil;
        sidebar.testStatus=@{@"devices":@[m705,master3]};
        sidebar.showSavedDevices.state=NSControlStateValueOn; [sidebar savedDevicesChanged:sidebar.showSavedDevices];
        assert(sidebar.devices.count==2);
        sidebar.testStatus=@{@"devices":@[m705,secondM705,master3]}; [sidebar refresh:nil];
        assert(sidebar.devices.count==3); // Distinct current mice of the same model remain separate.
        sidebar.testStatus=@{@"devices":@[m705]}; [sidebar refresh:nil];
        assert(sidebar.devices.count==2); // One saved Master model, not three old connection profiles.
        sidebar.showSavedDevices.state=NSControlStateValueOff; [sidebar savedDevicesChanged:sidebar.showSavedDevices];
        assert(sidebar.devices.count==1);
        assert(readDictionary(supportPath(@"known-devices.plist"))[@"old-bluetooth-master"]);
        [NSObject cancelPreviousPerformRequestsWithTarget:ui];
        [[NSFileManager defaultManager] removeItemAtPath:@(temporary) error:nil];
        puts("Settings profile, discovered control, switching, and import tests passed.");
    }
    return 0;
}
