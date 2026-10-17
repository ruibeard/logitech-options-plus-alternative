#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "mouse_view.h"
#import "import_options.h"
#import "logi_controls.h"
#import "helper_drag_view.h"
#include "storage.h"
#include <libproc.h>
#include <signal.h>

static NSString *supportPath(NSString *name) {
    char path[PATH_MAX];
    return mx_path(path, name.UTF8String) ? @(path) : nil;
}

static NSDictionary *readDictionary(NSString *path) {
    if (!path) return @{};
    CFPropertyListRef value = mx_read_plist(path.fileSystemRepresentation);
    if (!value) return @{};
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSString *keyName(unsigned short code) {
    NSDictionary *special = @{@36:@"Return", @48:@"Tab", @49:@"Space", @50:@"`", @51:@"Delete", @53:@"Esc",
        @123:@"←", @124:@"→", @125:@"↓", @126:@"↑", @103:@"F11"};
    if (special[@(code)]) return special[@(code)];
    NSDictionary *keys = @{@0:@"A", @1:@"S", @2:@"D", @3:@"F", @4:@"H", @5:@"G", @6:@"Z", @7:@"X", @8:@"C", @9:@"V", @11:@"B",
        @12:@"Q", @13:@"W", @14:@"E", @15:@"R", @16:@"Y", @17:@"T", @18:@"1", @19:@"2", @20:@"3", @21:@"4", @22:@"6", @23:@"5",
        @24:@"=", @25:@"9", @26:@"7", @27:@"−", @28:@"8", @29:@"0", @30:@"]", @31:@"O", @32:@"U", @33:@"[", @34:@"I", @35:@"P",
        @37:@"L", @38:@"J", @39:@"'", @40:@"K", @41:@";", @42:@"\\", @43:@",", @44:@"/", @45:@"N", @46:@"M", @47:@"."};
    return keys[@(code)] ?: [NSString stringWithFormat:@"Key %hu", code];
}

static NSString *shortcutLabel(unsigned short code, NSEventModifierFlags flags) {
    NSMutableString *label = [NSMutableString string];
    if (flags & NSEventModifierFlagControl) [label appendString:@"⌃"];
    if (flags & NSEventModifierFlagOption) [label appendString:@"⌥"];
    if (flags & NSEventModifierFlagShift) [label appendString:@"⇧"];
    if (flags & NSEventModifierFlagCommand) [label appendString:@"⌘"];
    [label appendString:keyName(code)];
    return label;
}

@interface MXRecorder : NSButton
@property unsigned short keyCode;
@property NSEventModifierFlags shortcutModifiers;
@property BOOL recording;
@property (copy) void (^didChange)(void);
@end

@implementation MXRecorder
- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.bezelStyle = NSBezelStyleRounded;
        self.target = self; self.action = @selector(beginRecording:);
        self.toolTip = @"Click, then press a keyboard shortcut. Escape cancels.";
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)beginRecording:(id)sender {
    (void)sender;
    self.recording = YES; self.title = @"Press shortcut…";
    [self.window makeFirstResponder:self];
}
- (void)updateTitle { self.title = shortcutLabel(self.keyCode, self.shortcutModifiers); }
- (BOOL)capture:(NSEvent *)event {
    if (!self.recording) return NO;
    if (event.keyCode != 53) {
        self.keyCode = event.keyCode;
        self.shortcutModifiers = event.modifierFlags &
            (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption);
    }
    self.recording = NO; [self updateTitle];
    if (self.didChange) self.didChange();
    return YES;
}
- (void)keyDown:(NSEvent *)event { if (![self capture:event]) [super keyDown:event]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { return [self capture:event] || [super performKeyEquivalent:event]; }
- (BOOL)resignFirstResponder { self.recording = NO; [self updateTitle]; return [super resignFirstResponder]; }
@end

@interface MXWindow : NSWindow
@end
@implementation MXWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([self.firstResponder isKindOfClass:MXRecorder.class] && [(MXRecorder *)self.firstResponder recording])
        return [(MXRecorder *)self.firstResponder performKeyEquivalent:event];
    return [super performKeyEquivalent:event];
}
@end

@interface MXCallout : NSButton
@property BOOL selected;
@end
@implementation MXCallout
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];
    if(self) self.focusRingType=NSFocusRingTypeNone;
    return self;
}
- (BOOL)becomeFirstResponder { BOOL result=[super becomeFirstResponder]; self.needsDisplay=YES; return result; }
- (BOOL)resignFirstResponder { BOOL result=[super resignFirstResponder]; self.needsDisplay=YES; return result; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    NSRect card=NSInsetRect(self.bounds,6,6);
    NSBezierPath *shape=[NSBezierPath bezierPathWithRoundedRect:card xRadius:4 yRadius:4];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowColor=[NSColor colorWithCalibratedWhite:0 alpha:self.selected ? 0.14 : 0.09];
    shadow.shadowBlurRadius=10; shadow.shadowOffset=NSMakeSize(0,-3); [shadow set];
    BOOL active=self.selected || self.highlighted;
    [(active ? NSColor.selectedContentBackgroundColor : NSColor.controlBackgroundColor) setFill]; [shape fill];
    [NSGraphicsContext restoreGraphicsState];
    [[NSColor.separatorColor colorWithAlphaComponent:0.15] setStroke]; shape.lineWidth=0.5; [shape stroke];
    NSArray *parts=[self.title componentsSeparatedByString:@"\n"];
    CGFloat y=card.origin.y+11;
    for(NSUInteger i=0;i<parts.count;++i) {
        [parts[i] drawAtPoint:NSMakePoint(card.origin.x+13,y) withAttributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:i==0 ? 13.5 : 12 weight:i==0 ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName:active ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor}];
        y+=i==0 ? 20 : 17;
    }
}
@end

@interface MXDiagram : NSView
@property NSArray<NSValue *> *anchors;
@property NSArray<NSValue *> *ends;
@property BOOL compactMouse;
@property NSIndexSet *visibleControls;
@end
@implementation MXDiagram
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    NSColor *ink = [NSColor.secondaryLabelColor colorWithAlphaComponent:0.48];
    for (NSUInteger i = 0; i < self.anchors.count; ++i) {
        if (self.visibleControls && ![self.visibleControls containsIndex:i]) continue;
        if (self.compactMouse && i >= 4) continue;
        NSPoint point = self.anchors[i].pointValue, start = self.ends[i].pointValue;
        if(self.compactMouse) {
            NSPoint compactAnchors[]={NSMakePoint(338,337),NSMakePoint(289,253),NSMakePoint(266,286),NSMakePoint(275,183)};
            point=compactAnchors[i];
        }
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:start];
        [line lineToPoint:point];
        [ink setStroke]; line.lineWidth = 0.8; [line stroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x - 6, point.y - 6, 12, 12)];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.85] setStroke]; ring.lineWidth = 2.2; [ring stroke];
        [ink setStroke]; ring.lineWidth = 0.8; [ring stroke];
    }
}
@end

@interface SettingsDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property NSWindow *window;
@property NSTextField *deviceTitle;
@property NSTextField *deviceSubtitle;
@property NSTextField *batteryLabel;
@property NSImageView *batteryIcon;
@property MXMouseView *mouseView;
@property MXDiagram *diagramLines;
@property NSMutableArray<NSView *> *masterOnlyViews;
@property BOOL compactMouse;
@property BOOL genericMouse;
@property NSPopUpButton *deviceSelector;
@property NSPopUpButton *controlSelector;
@property NSTableView *controlTable;
@property NSScrollView *controlList;
@property NSView *buttonEditor;
@property NSTextField *genericHint;
@property NSArray<NSDictionary *> *devices;
@property NSDictionary *selectedDevice;
@property NSString *selectedDeviceID;
@property NSArray<NSDictionary *> *availableControls;
@property NSDictionary *capabilities;
@property NSMutableArray<NSView *> *wheelViews;
@property NSMutableArray<NSView *> *horizontalViews;
@property NSMutableArray<NSView *> *verticalViews;
@property NSMutableArray<NSView *> *dpiViews;
@property NSTextField *statusLabel;
@property NSMutableArray<NSPopUpButton *> *modes;
@property NSMutableArray<MXRecorder *> *recorders;
@property NSPopUpButton *wheelMode;
@property int smartShiftThreshold;
@property NSPopUpButton *dpi;
@property NSSlider *verticalSpeed;
@property NSSlider *horizontalSpeed;
@property NSTextField *verticalValue;
@property NSTextField *horizontalValue;
@property NSButton *invertVertical;
@property NSButton *invertHorizontal;
@property NSButton *smooth;
@property NSButton *permissionsButton;
@property NSWindow *permissionSheet;
@property NSButton *quitOptionsButton;
@property NSButton *importOptionsButton;
@property NSButton *uninstallOptionsButton;
@property BOOL quittingOptions;
@property NSButton *inputPermissionButton;
@property NSButton *accessibilityPermissionButton;
@property NSArray<NSImageView *> *permissionIndicators;
@property NSArray<NSTextField *> *permissionStates;
@property NSButton *requestAccessButton;
@property BOOL checkingPermissions;
@property CFAbsoluteTime permissionsRequestedAt;
@property NSInteger helperTransition;
@property CFAbsoluteTime transitionStartedAt;
@property NSRunningApplication *launchedHelper;
@property BOOL autoStartAttempted;
@property NSTextField *selectionTitle;
@property NSMutableArray<NSView *> *buttonPanes;
@property NSMutableArray<MXCallout *> *callouts;
@property NSInteger selectedButton;
@property SMAppService *loginService;
@property NSTimer *statusTimer;
@property id keyMonitor;
@property BOOL loadingSettings;
@property BOOL pendingApply;
@end

@implementation SettingsDelegate
- (void)alert:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"MX Mouse"; alert.informativeText = message;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}
- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    return label;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *item = [NSMenuItem new]; [menu addItem:item];
    NSMenu *applicationMenu = [NSMenu new];
    [applicationMenu addItemWithTitle:@"Quit MX Mouse Settings" action:@selector(terminate:) keyEquivalent:@"q"];
    item.submenu = applicationMenu;
    NSMenuItem *fileItem = [NSMenuItem new]; [menu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu; NSApp.mainMenu = menu;
    self.window = [[MXWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"MX Mouse Settings";
    self.window.releasedWhenClosed = NO;
    [self.window setContentSize:NSMakeSize(1000, 740)];
    NSView *root = self.window.contentView;
    self.window.backgroundColor=[NSColor colorWithName:@"MXCanvas" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return [NSColor colorWithCalibratedWhite:dark ? 0.12 : 0.975 alpha:1];
    }];
    NSTextField *title = [self label:@"MX Master 3" size:27 weight:NSFontWeightSemibold];
    self.deviceTitle=title;
    title.frame = NSMakeRect(32, 676, 400, 36); [root addSubview:title];
    NSTextField *subtitle = [self label:@"FOR MAC  /  BLUETOOTH" size:11 weight:NSFontWeightMedium];
    self.deviceSubtitle=subtitle;
    self.batteryIcon=[[NSImageView alloc] initWithFrame:NSMakeRect(454,684,24,16)];
    self.batteryIcon.hidden=YES; [root addSubview:self.batteryIcon];
    self.batteryLabel=[self label:@"" size:12 weight:NSFontWeightRegular];
    self.batteryLabel.frame=NSMakeRect(484,679,145,24);
    self.batteryLabel.hidden=YES; [root addSubview:self.batteryLabel];
    self.masterOnlyViews=[NSMutableArray new];
    self.wheelViews=[NSMutableArray new]; self.horizontalViews=[NSMutableArray new]; self.verticalViews=[NSMutableArray new]; self.dpiViews=[NSMutableArray new];
    self.deviceSelector=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(270,613,412,28) pullsDown:NO];
    self.deviceSelector.target=self; self.deviceSelector.action=@selector(deviceChanged:);
    self.deviceSelector.hidden=YES; [root addSubview:self.deviceSelector];
    subtitle.textColor = NSColor.secondaryLabelColor; subtitle.frame = NSMakeRect(34, 654, 400, 18); [root addSubview:subtitle];
    self.importOptionsButton=[self button:@"Import from Options+…" action:@selector(importOptions:)];
    self.importOptionsButton.frame=NSMakeRect(30,610,211,32); [root addSubview:self.importOptionsButton];
    self.quitOptionsButton=[self button:@"Quit Options+" action:@selector(quitOptions:)];
    self.quitOptionsButton.frame=NSMakeRect(638,677,142,32); [root addSubview:self.quitOptionsButton];
    self.quitOptionsButton.toolTip=@"Quit Options+ and stop its mouse agent for this login session.";
    self.uninstallOptionsButton=[self button:@"Uninstall Options+…" action:@selector(uninstallOptions:)];
    self.uninstallOptionsButton.frame=NSMakeRect(786,677,184,32); [root addSubview:self.uninstallOptionsButton];
    NSView *diagram = [[NSView alloc] initWithFrame:NSMakeRect(26, 168, 660, 440)]; [root addSubview:diagram];
    MXMouseView *mouse = [[MXMouseView alloc] initWithFrame:NSMakeRect(205, 10, 270, 430)]; [diagram addSubview:mouse]; self.mouseView=mouse;
    MXDiagram *arrows=[[MXDiagram alloc] initWithFrame:diagram.bounds]; [diagram addSubview:arrows]; self.diagramLines=arrows;
    self.callouts = [NSMutableArray new];
    NSArray *names = @[@"Middle button", @"Back", @"Forward", @"Thumb button", @"Top button"];
    NSArray<NSValue *> *frames = @[[NSValue valueWithRect:NSMakeRect(432,340,177,72)], [NSValue valueWithRect:NSMakeRect(270,75,174,72)], [NSValue valueWithRect:NSMakeRect(94,235,176,72)], [NSValue valueWithRect:NSMakeRect(0,145,211,90)], [NSValue valueWithRect:NSMakeRect(452,250,185,90)]];
    self.modes = [NSMutableArray new]; self.recorders = [NSMutableArray new]; self.buttonPanes = [NSMutableArray new];
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(703, 191, 1, 390)]; divider.boxType = NSBoxSeparator; [root addSubview:divider];
    NSView *buttonEditor = [[NSView alloc] initWithFrame:NSMakeRect(731, 490, 240, 120)]; [root addSubview:buttonEditor];
    self.buttonEditor=buttonEditor;
    self.controlSelector=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(60,526,580,32) pullsDown:NO];
    self.controlSelector.target=self; self.controlSelector.action=@selector(controlChanged:);
    self.controlSelector.hidden=YES;
    self.controlList=[[NSScrollView alloc] initWithFrame:NSMakeRect(60,228,600,330)];
    self.controlList.drawsBackground=NO; self.controlList.hasVerticalScroller=YES;
    self.controlTable=[[NSTableView alloc] initWithFrame:self.controlList.bounds];
    self.controlTable.backgroundColor=NSColor.clearColor; self.controlTable.rowHeight=42;
    self.controlTable.intercellSpacing=NSMakeSize(10,0); self.controlTable.dataSource=self; self.controlTable.delegate=self;
    NSTableColumn *controlColumn=[[NSTableColumn alloc] initWithIdentifier:@"name"]; controlColumn.title=@"Control"; controlColumn.width=285; [self.controlTable addTableColumn:controlColumn];
    NSTableColumn *actionColumn=[[NSTableColumn alloc] initWithIdentifier:@"action"]; actionColumn.title=@"Action"; actionColumn.width=285; [self.controlTable addTableColumn:actionColumn];
    self.controlList.documentView=self.controlTable; self.controlList.hidden=YES; [root addSubview:self.controlList];
    self.genericHint=[NSTextField wrappingLabelWithString:@"Select a control to customize its action. Controls are discovered from this mouse."];
    self.genericHint.frame=NSMakeRect(64,176,590,40); self.genericHint.textColor=NSColor.secondaryLabelColor; self.genericHint.hidden=YES; [root addSubview:self.genericHint];
    self.selectionTitle = [self label:@"Thumb button" size:21 weight:NSFontWeightSemibold]; self.selectionTitle.frame = NSMakeRect(0,94,240,26); [buttonEditor addSubview:self.selectionTitle];
    __weak SettingsDelegate *layoutSelf = self;
    for (NSUInteger i=0; i<MX_BUTTON_COUNT; ++i) {
        MXCallout *callout = [[MXCallout alloc] initWithFrame:frames[i].rectValue]; callout.bordered = NO; callout.tag = (NSInteger)i; callout.target = self; callout.action = @selector(selectButton:); callout.title = names[i]; [diagram addSubview:callout]; [self.callouts addObject:callout];
        NSView *pane = [[NSView alloc] initWithFrame:NSMakeRect(0,0,240,88)]; [buttonEditor addSubview:pane]; [self.buttonPanes addObject:pane];
        NSPopUpButton *mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,46,232,30) pullsDown:NO];
        [mode addItemsWithTitles:@[@"Mouse default", @"Keyboard shortcut", @"Do nothing"]]; mode.tag=(NSInteger)i; mode.target=self; mode.action=@selector(modeChanged:); [pane addSubview:mode]; [self.modes addObject:mode];
        MXRecorder *recorder=[MXRecorder new]; recorder.frame=NSMakeRect(0,4,232,36); recorder.didChange=^{ [layoutSelf updateCallouts]; [layoutSelf settingsChanged:nil]; }; [pane addSubview:recorder]; [self.recorders addObject:recorder];
    }
    // Additional HID++ controls share the same editor, without adding a fixed model layout.
    for(NSUInteger i=MX_BUTTON_COUNT;i<MX_BUTTON_COUNT+MX_EXTRA_BUTTON_COUNT;++i) {
        NSView *pane=[[NSView alloc] initWithFrame:NSMakeRect(0,0,240,88)]; pane.hidden=YES; [buttonEditor addSubview:pane]; [self.buttonPanes addObject:pane];
        NSPopUpButton *mode=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,46,232,30) pullsDown:NO];
        [mode addItemsWithTitles:@[@"Mouse default",@"Keyboard shortcut",@"Do nothing"]]; mode.tag=(NSInteger)i; mode.target=self; mode.action=@selector(modeChanged:); [pane addSubview:mode]; [self.modes addObject:mode];
        MXRecorder *recorder=[MXRecorder new]; recorder.frame=NSMakeRect(0,4,232,36);
        recorder.didChange=^{ [layoutSelf updateCallouts]; [layoutSelf settingsChanged:nil]; }; [pane addSubview:recorder]; [self.recorders addObject:recorder];
    }
    MXCallout *thumbWheel=[[MXCallout alloc] initWithFrame:NSMakeRect(405,173,206,72)]; thumbWheel.title=@"Horizontal scroll\nThumb wheel"; thumbWheel.bordered=NO; thumbWheel.target=self; thumbWheel.action=@selector(showScroll:); [diagram addSubview:thumbWheel]; [self.callouts addObject:thumbWheel]; [self.masterOnlyViews addObject:thumbWheel]; [self.horizontalViews addObject:thumbWheel];
    /* Logitech core_metadata.json marker percentages, mapped into the image frame. */
    arrows.anchors=@[[NSValue valueWithPoint:NSMakePoint(396.1,375.5)], [NSValue valueWithPoint:NSMakePoint(326.65,182)], [NSValue valueWithPoint:NSMakePoint(299.14,255.1)], [NSValue valueWithPoint:NSMakePoint(227.84,190.6)], [NSValue valueWithPoint:NSMakePoint(422.39,293.8)], [NSValue valueWithPoint:NSMakePoint(353.36,218.55)]];
    arrows.ends=@[[NSValue valueWithPoint:NSMakePoint(438,376)], [NSValue valueWithPoint:NSMakePoint(338,141)], [NSValue valueWithPoint:NSMakePoint(256,264)], [NSValue valueWithPoint:NSMakePoint(205,190)], [NSValue valueWithPoint:NSMakePoint(458,294)], [NSValue valueWithPoint:NSMakePoint(411,209)]];
    NSView *scrollEditor=[[NSView alloc] initWithFrame:NSMakeRect(731,188,240,286)]; [root addSubview:scrollEditor];
    NSTextField *scrollTitle=[self label:@"Point & Scroll" size:21 weight:NSFontWeightSemibold]; scrollTitle.frame=NSMakeRect(0,260,240,26); [scrollEditor addSubview:scrollTitle];
    self.wheelMode=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,208,235,28) pullsDown:NO]; [self.wheelMode addItemsWithTitles:@[@"Leave unchanged", @"Ratchet", @"Free spin", @"SmartShift"]]; [scrollEditor addSubview:self.wheelMode];
    NSArray *sectionNames=@[@"Wheel mode", @"Main wheel speed", @"Thumb wheel speed", @"Pointer speed"];
    CGFloat sectionY[]={235,180,111,40};
    for(NSUInteger i=0;i<4;++i) { NSTextField *l=[self label:sectionNames[i] size:12 weight:NSFontWeightSemibold]; l.frame=NSMakeRect(0,sectionY[i],235,19); [scrollEditor addSubview:l]; if(i!=1) [self.masterOnlyViews addObject:l]; if(i==0) [self.wheelViews addObject:l]; if(i==1) [self.verticalViews addObject:l]; if(i==2) [self.horizontalViews addObject:l]; if(i==3) [self.dpiViews addObject:l]; }
    self.verticalSpeed=[NSSlider sliderWithValue:100 minValue:10 maxValue:300 target:self action:@selector(speedChanged:)]; self.verticalSpeed.frame=NSMakeRect(0,157,177,22); [scrollEditor addSubview:self.verticalSpeed];
    self.horizontalSpeed=[NSSlider sliderWithValue:100 minValue:10 maxValue:300 target:self action:@selector(speedChanged:)]; self.horizontalSpeed.frame=NSMakeRect(0,88,177,22); [scrollEditor addSubview:self.horizontalSpeed];
    self.verticalValue=[self label:@"100%" size:12 weight:NSFontWeightRegular]; self.verticalValue.frame=NSMakeRect(184,157,54,22); [scrollEditor addSubview:self.verticalValue];
    self.horizontalValue=[self label:@"100%" size:12 weight:NSFontWeightRegular]; self.horizontalValue.frame=NSMakeRect(184,88,54,22); [scrollEditor addSubview:self.horizontalValue];
    self.invertVertical=[NSButton checkboxWithTitle:@"Reverse" target:nil action:nil]; self.invertVertical.frame=NSMakeRect(0,135,104,22); [scrollEditor addSubview:self.invertVertical];
    self.invertHorizontal=[NSButton checkboxWithTitle:@"Reverse direction" target:nil action:nil]; self.invertHorizontal.frame=NSMakeRect(0,66,235,22); [scrollEditor addSubview:self.invertHorizontal];
    self.smooth=[NSButton checkboxWithTitle:@"Smooth scroll" target:nil action:nil]; self.smooth.frame=NSMakeRect(110,135,130,22); [scrollEditor addSubview:self.smooth];
    self.dpi=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,10,235,28) pullsDown:NO]; [self.dpi addItemsWithTitles:@[@"Leave unchanged", @"400 DPI", @"800 DPI", @"1000 DPI", @"1600 DPI", @"2000 DPI", @"3200 DPI", @"4000 DPI"]]; [scrollEditor addSubview:self.dpi];
    [self.masterOnlyViews addObjectsFromArray:@[self.wheelMode,self.horizontalSpeed,self.horizontalValue,self.invertHorizontal,self.dpi]];
    [self.wheelViews addObject:self.wheelMode]; [self.dpiViews addObject:self.dpi];
    [self.horizontalViews addObjectsFromArray:@[self.horizontalSpeed,self.horizontalValue,self.invertHorizontal]];
    [self.verticalViews addObjectsFromArray:@[self.verticalSpeed,self.verticalValue,self.invertVertical,self.smooth]];
    NSBox *footerLine=[[NSBox alloc] initWithFrame:NSMakeRect(32,155,936,1)]; footerLine.boxType=NSBoxSeparator; [root addSubview:footerLine];
    self.statusLabel=[NSTextField wrappingLabelWithString:@"Helper stopped."]; self.statusLabel.font=[NSFont systemFontOfSize:12]; self.statusLabel.frame=NSMakeRect(34,110,710,34); [root addSubview:self.statusLabel];
    self.loginService=[SMAppService loginItemServiceWithIdentifier:@"local.mxmouse.helper"];
    NSButton *login=[NSButton checkboxWithTitle:@"Start at login" target:self action:@selector(loginChanged:)]; login.state=self.loginService.status==SMAppServiceStatusEnabled; login.frame=NSMakeRect(34,68,160,24); [root addSubview:login];
    NSArray<NSString *> *permissionNames=@[@"Input Monitoring",@"Accessibility"];
    NSMutableArray *indicators=[NSMutableArray new];
    for(NSUInteger i=0;i<permissionNames.count;++i) {
        CGFloat x=430+i*200;
        NSImageView *indicator=[[NSImageView alloc] initWithFrame:NSMakeRect(x,72,16,16)];
        indicator.imageScaling=NSImageScaleProportionallyDown; [root addSubview:indicator]; [indicators addObject:indicator];
        NSTextField *name=[self label:permissionNames[i] size:12 weight:NSFontWeightRegular];
        name.frame=NSMakeRect(x+24,68,170,24); [root addSubview:name];
    }
    self.permissionIndicators=indicators;
    self.permissionsButton=[self button:@"Set Up…" action:@selector(permissions:)];
    self.permissionsButton.frame=NSMakeRect(850,66,114,28); [root addSubview:self.permissionsButton];
    self.selectedButton=3;
    for (NSControl *control in @[self.wheelMode, self.dpi, self.invertVertical, self.invertHorizontal, self.smooth]) {
        control.target=self; control.action=@selector(settingsChanged:);
    }
    self.verticalSpeed.continuous=NO; self.horizontalSpeed.continuous=NO;
    [self load];
    [self updateCallouts];
    /* Export this application's own view for documentation without opening a window. */
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    NSUInteger preview=[arguments indexOfObject:@"--render-preview"];
    if(preview!=NSNotFound) {
        if(preview+1>=arguments.count) { fprintf(stderr,"Missing preview output path.\n"); exit(64); }
        NSUInteger selection=[arguments indexOfObject:@"--preview-button"];
        if(selection!=NSNotFound && selection+1<arguments.count) {
            NSInteger index=arguments[selection+1].integerValue;
            if(index>=0 && index<MX_BUTTON_COUNT) { self.selectedButton=index; [self updateCallouts]; }
        }
        [self refresh:nil];
        NSView *view=self.window.contentView;
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        /* Window backing normally supplies this opaque background. */
        NSBitmapImageRep *opaque=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:bitmap.pixelsWide pixelsHigh:bitmap.pixelsHigh bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        opaque.size=view.bounds.size;
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:opaque];
        [self.window.backgroundColor setFill]; NSRectFill(view.bounds);
        NSImage *rendered=[[NSImage alloc] initWithSize:view.bounds.size];
        [rendered addRepresentation:bitmap];
        [rendered drawInRect:view.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png=[opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if(![png writeToFile:arguments[preview+1] atomically:YES]) { fprintf(stderr,"Could not save preview.\n"); exit(74); }
        [NSApp terminate:nil]; return;
    }
    [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self checkPermissions:nil];
    [self refresh:nil];
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    __weak SettingsDelegate *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        for (MXRecorder *recorder in weakSelf.recorders) if ([recorder capture:event]) return nil;
        return event;
    }];
}
- (void)deviceChanged:(NSPopUpButton *)sender {
    [self cancelRecording]; [self applyPendingSettings];
    NSInteger index=sender.indexOfSelectedItem;
    if(index>=0 && (NSUInteger)index<self.devices.count) {
        self.selectedDeviceID=self.devices[(NSUInteger)index][@"id"];
        self.selectedDevice=nil;
        [self refresh:nil];
    }
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView; return (NSInteger)self.availableControls.count;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    NSDictionary *control=self.availableControls[(NSUInteger)row];
    if([column.identifier isEqualToString:@"name"]) return control[@"name"] ?: @"Mouse control";
    NSUInteger slot=[control[@"slot"] unsignedIntegerValue];
    NSInteger mode=self.modes[slot].indexOfSelectedItem;
    return mode==MX_SHORTCUT ? shortcutLabel(self.recorders[slot].keyCode,self.recorders[slot].shortcutModifiers) : mode==MX_DISABLED ? @"Do nothing" : @"Mouse default";
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    NSInteger row=self.controlTable.selectedRow;
    if(row<0 || (NSUInteger)row>=self.availableControls.count) return;
    NSInteger slot=[self.availableControls[(NSUInteger)row][@"slot"] integerValue];
    if(slot==self.selectedButton) return;
    [self cancelRecording]; self.selectedButton=slot; [self updateCallouts];
}
- (void)controlChanged:(NSPopUpButton *)sender {
    [self cancelRecording];
    NSNumber *slot=sender.selectedItem.representedObject;
    if(slot) self.selectedButton=slot.integerValue;
    [self updateCallouts];
}
- (BOOL)hasCapability:(NSString *)name {
    return [self.capabilities[name] boolValue];
}
- (NSDictionary *)controlForSlot:(NSUInteger)slot {
    for(NSDictionary *control in self.availableControls) if([control[@"slot"] unsignedIntegerValue]==slot) return control;
    return nil;
}
- (NSDictionary *)updateDevice:(NSDictionary *)status {
    NSArray *entries=[status[@"devices"] isKindOfClass:NSArray.class] ? status[@"devices"] : @[];
    self.devices=entries;
    NSDictionary *device=nil;
    for(NSDictionary *candidate in entries) if([candidate[@"id"] isEqual:self.selectedDeviceID]) { device=candidate; break; }
    if(!device) for(NSDictionary *candidate in entries) if([candidate[@"connected"] boolValue]) { device=candidate; break; }
    if(!device) device=entries.firstObject;
    BOOL changed=![self.selectedDeviceID ?: @"" isEqual:device[@"id"] ?: @""] || !self.selectedDevice;
    self.selectedDeviceID=[device[@"id"] isKindOfClass:NSString.class] ? device[@"id"] : nil;
    self.selectedDevice=device;
    [self.deviceSelector removeAllItems];
    NSUInteger selection=0;
    for(NSUInteger i=0;i<entries.count;++i) {
        NSDictionary *candidate=entries[i];
        NSString *title=[candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : @"Logitech mouse";
        // Add a short identity so two identical models can still be distinguished.
        NSString *identity=[candidate[@"id"] isKindOfClass:NSString.class] ? candidate[@"id"] : @"";
        if(identity.length>8) identity=[identity substringFromIndex:identity.length-8];
        [self.deviceSelector addItemWithTitle:[NSString stringWithFormat:@"%@ · %@%@",title,identity,[candidate[@"connected"] boolValue] ? @"" : @" · Offline"]];
        if(candidate==device) selection=i;
    }
    if(entries.count) [self.deviceSelector selectItemAtIndex:selection];
    self.deviceSelector.hidden=entries.count<2;
    NSDictionary *active=device ?: status;
    NSString *name=[active[@"name"] isKindOfClass:NSString.class] ? active[@"name"] : active[@"deviceName"];
    if(![name isKindOfClass:NSString.class] || !name.length) name=@"Logitech mouse";
    self.deviceTitle.stringValue=name;
    NSString *transport=[device[@"transport"] isKindOfClass:NSString.class] ? [device[@"transport"] uppercaseString] : @"";
    self.deviceSubtitle.stringValue=device ? ([device[@"connected"] boolValue] ? (transport.length ? [NSString stringWithFormat:@"CONNECTED  /  %@",transport] : @"CONNECTED  /  DEVICE SETTINGS") : @"OFFLINE  /  SAVED SETTINGS") : @"CONNECT A LOGITECH MOUSE";
    BOOL compact=[name rangeOfString:@"M705" options:NSCaseInsensitiveSearch].location!=NSNotFound;
    BOOL master3=[name rangeOfString:@"Master 3" options:NSCaseInsensitiveSearch].location!=NSNotFound;
    self.compactMouse=compact;
    self.genericMouse=!compact && !master3;
    self.capabilities=[active[@"capabilities"] isKindOfClass:NSDictionary.class] ? active[@"capabilities"] : @{};
    NSArray *controls=[active[@"controls"] isKindOfClass:NSArray.class] ? active[@"controls"] : @[];
    NSMutableArray *editable=[NSMutableArray new];
    NSUInteger extraSlot=MX_BUTTON_COUNT;
    NSMutableIndexSet *usedSlots=[NSMutableIndexSet new];
    NSMutableSet *seenCIDs=[NSMutableSet new];
    for(NSDictionary *control in controls) {
        if(![control[@"divertible"] boolValue] || ![control[@"cid"] isKindOfClass:NSNumber.class]) continue;
        if([seenCIDs containsObject:control[@"cid"]]) continue;
        [seenCIDs addObject:control[@"cid"]];
        NSInteger slot=[control[@"slot"] isKindOfClass:NSNumber.class] ? [control[@"slot"] integerValue] : -1;
        if(slot<0 || slot>=MX_BUTTON_COUNT || [usedSlots containsIndex:(NSUInteger)slot]) {
            if(extraSlot>=self.modes.count) continue;
            NSMutableDictionary *extra=[control mutableCopy]; extra[@"bindingSlot"]=@(slot); extra[@"slot"]=@(extraSlot++); [editable addObject:extra];
        } else { [usedSlots addIndex:(NSUInteger)slot]; [editable addObject:control]; }
    }
    changed=changed || ![self.availableControls isEqualToArray:editable];
    self.availableControls=editable;
    if(extraSlot>MX_BUTTON_COUNT) self.genericMouse=YES;
    self.mouseView.hidden=self.diagramLines.hidden=self.genericMouse;
    self.mouseView.frame=compact ? NSMakeRect(155,50,400,350) : NSMakeRect(205,10,270,430);
    self.mouseView.compactMouse=compact; self.mouseView.needsDisplay=YES;
    self.diagramLines.compactMouse=compact;
    NSMutableIndexSet *visible=[NSMutableIndexSet new];
    for(NSUInteger i=0;i<MX_BUTTON_COUNT;++i) {
        BOOL present=[self controlForSlot:i]!=nil;
        self.callouts[i].hidden=self.genericMouse || !present;
        if(present) [visible addIndex:i];
    }
    if([self hasCapability:@"horizontalScroll"]) [visible addIndex:5];
    self.diagramLines.visibleControls=visible; self.diagramLines.needsDisplay=YES;
    for(NSView *view in self.wheelViews) view.hidden=![self hasCapability:@"wheelMode"];
    [self.wheelMode itemAtIndex:3].enabled=[self hasCapability:@"smartShift"];
    for(NSView *view in self.dpiViews) view.hidden=![self hasCapability:@"dpi"];
    for(NSView *view in self.horizontalViews) view.hidden=![self hasCapability:@"horizontalScroll"];
    for(NSView *view in self.verticalViews) view.hidden=![self hasCapability:@"verticalScroll"];
    self.callouts[5].hidden=self.genericMouse || ![self hasCapability:@"horizontalScroll"];
    [self.controlSelector removeAllItems];
    for(NSDictionary *control in editable) {
        NSString *controlName=[control[@"name"] isKindOfClass:NSString.class] ? control[@"name"] : [NSString stringWithFormat:@"Control %@",control[@"cid"]];
        [self.controlSelector addItemWithTitle:controlName]; self.controlSelector.lastItem.representedObject=control[@"slot"];
    }
    self.controlSelector.hidden=YES;
    self.controlList.hidden=!self.genericMouse;
    self.controlSelector.enabled=editable.count>0;
    self.genericHint.hidden=!self.genericMouse;
    self.genericHint.stringValue=editable.count ? @"Select a control to customize its action. Controls are discovered from this mouse." : @"No customizable controls reported yet. The mouse may be asleep or still connecting.";
    if(![self controlForSlot:(NSUInteger)self.selectedButton]) self.selectedButton=editable.count ? [editable.firstObject[@"slot"] integerValue] : -1;
    if(changed) { [self cancelRecording]; [self load]; }
    [self updateCallouts];
    return active;
}
- (void)updateCallouts {
    NSArray *names=@[@"Middle button", @"Back", @"Forward", @"Thumb button", @"Top button"];
    for(NSUInteger i=0;i<MIN(MX_BUTTON_COUNT,self.callouts.count);++i) {
        NSInteger mode=self.modes[i].indexOfSelectedItem;
        NSString *action=mode==MX_DISABLED ? @"Do nothing" : i==4 ? @"Shift wheel mode" : names[i];
        NSString *physical=i==0 ? @"Wheel button" : i==1 ? @"Back button" : i==2 ? @"Forward button" : names[i];
        if(mode==MX_SHORTCUT) {
            MXRecorder *recorder=self.recorders[i];
            BOOL screenshot=recorder.keyCode==21 && recorder.shortcutModifiers==(NSEventModifierFlagCommand|NSEventModifierFlagShift);
            BOOL navigation=recorder.shortcutModifiers==NSEventModifierFlagCommand && ((i==1 && recorder.keyCode==33) || (i==2 && recorder.keyCode==30));
            action=screenshot ? @"Screen capture" : @"Keyboard shortcut";
            NSString *shortcut=screenshot ? @"Capture region · ⌘⇧4" : shortcutLabel(recorder.keyCode,recorder.shortcutModifiers);
            self.callouts[i].title=navigation ? [NSString stringWithFormat:@"%@\n%@",names[i],physical] : [NSString stringWithFormat:@"%@\n%@\n%@",action,shortcut,physical];
        } else self.callouts[i].title=[NSString stringWithFormat:@"%@\n%@",action,physical];
        NSRect frame=self.callouts[i].frame;
        CGFloat height=[self.callouts[i].title componentsSeparatedByString:@"\n"].count>2 ? 90 : 72;
        frame.origin.y+=(frame.size.height-height)/2; frame.size.height=height; self.callouts[i].frame=frame;
        self.callouts[i].accessibilityLabel=[self.callouts[i].title stringByReplacingOccurrencesOfString:@"\n" withString:@", "];
        self.callouts[i].selected=(NSInteger)i==self.selectedButton;
        self.callouts[i].needsDisplay=YES;

    }
    for(NSUInteger i=0;i<self.buttonPanes.count;++i) self.buttonPanes[i].hidden=(NSInteger)i!=self.selectedButton || ![self controlForSlot:i];
    NSDictionary *selected=self.selectedButton>=0 ? [self controlForSlot:(NSUInteger)self.selectedButton] : nil;
    self.selectionTitle.stringValue=selected[@"name"] ?: @"Mouse controls";
    [self.controlTable reloadData];
    for(NSUInteger row=0;row<self.availableControls.count;++row) if([self.availableControls[row][@"slot"] integerValue]==self.selectedButton) {
        if(self.controlTable.selectedRow!=(NSInteger)row) [self.controlTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        break;
    }
    for(NSMenuItem *item in self.controlSelector.itemArray) if([item.representedObject integerValue]==self.selectedButton) { [self.controlSelector selectItem:item]; break; }
}
- (void)cancelRecording {
    for (MXRecorder *recorder in self.recorders) if (recorder.recording) {
        recorder.recording=NO; [recorder updateTitle];
    }
}
- (void)selectButton:(NSButton *)sender { [self cancelRecording]; self.selectedButton=sender.tag; [self updateCallouts]; }
- (void)showScroll:(id)sender { (void)sender; [self cancelRecording]; [self.window makeFirstResponder:self.wheelMode]; }
- (void)startHelperIfReady {
    if(self.autoStartAttempted || self.helperTransition || self.checkingPermissions || [self helperRunning]) return;
    if([NSProcessInfo.processInfo.arguments containsObject:@"--render-preview"]) return;
    NSDictionary *permissions=[self permissionSnapshot];
    if(![permissions[@"inputMonitoring"] boolValue] || ![permissions[@"postEventAccess"] boolValue]) return;
    char conflict[256];
    if(mx_conflicting_process(conflict)) return;
    self.autoStartAttempted=YES;
    self.helperTransition=1;
    self.launchedHelper=nil;
    self.transitionStartedAt=CFAbsoluteTimeGetCurrent();
    [self startHelper:nil];
}
- (NSURL *)helperURL {
    return [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Library/LoginItems/MX Mouse Helper.app"];
}
- (BOOL)canImportOptions {
    NSString *name=self.selectedDevice[@"name"];
    return self.selectedDeviceID.length && [name isKindOfClass:NSString.class] &&
        [name rangeOfString:@"Master 3" options:NSCaseInsensitiveSearch].location!=NSNotFound &&
        [name rangeOfString:@"Master 3S" options:NSCaseInsensitiveSearch].location==NSNotFound;
}
- (NSDictionary *)settingsByImportingProfile:(NSDictionary *)imported intoSettings:(NSDictionary *)current {
    NSMutableDictionary *result=[current mutableCopy];
    NSMutableDictionary *profiles=[current[@"devices"] isKindOfClass:NSDictionary.class] ? [current[@"devices"] mutableCopy] : [NSMutableDictionary new];
    NSMutableDictionary *profile=[imported mutableCopy]; [profile removeObjectForKey:@"devices"];
    // The importer writes legacy logical buttons; remove stale CID overrides for those controls.
    NSMutableDictionary *overrides=[profile[@"controls"] isKindOfClass:NSDictionary.class] ? [profile[@"controls"] mutableCopy] : [NSMutableDictionary new];
    for(NSDictionary *control in self.availableControls) if([control[@"slot"] integerValue]<MX_BUTTON_COUNT)
        [overrides removeObjectForKey:[NSString stringWithFormat:@"%04x",[control[@"cid"] unsignedShortValue]]];
    profile[@"controls"]=overrides; profiles[self.selectedDeviceID]=profile; result[@"devices"]=profiles;
    return result;
}
- (void)importOptions:(id)sender {
    (void)sender;
    if(![self canImportOptions]) return;
    [self cancelRecording]; [self applyPendingSettings];
    NSDictionary *current=readDictionary(supportPath(@"settings.plist"));
    NSError *error=nil;
    NSString *database=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LogiOptionsPlus/settings.db"];
    NSMutableDictionary *effective=[current mutableCopy]; [effective removeObjectForKey:@"devices"];
    NSDictionary *profile=[current[@"devices"] isKindOfClass:NSDictionary.class] ? current[@"devices"][self.selectedDeviceID] : nil;
    if([profile isKindOfClass:NSDictionary.class]) [effective addEntriesFromDictionary:profile];
    NSDictionary *result=MXReadOptionsImport(database,effective,&error);
    if(!result) { [self alert:error.localizedDescription ?: @"Could not read Options+ settings."]; return; }
    NSDictionary *settings=[self settingsByImportingProfile:result[@"settings"] intoSettings:current];
    NSString *path=supportPath(@"settings.plist");
    NSString *backup=supportPath(@"settings.before-options-import.plist");
    if(!path || !backup || !mx_write_plist(backup.fileSystemRepresentation,(__bridge CFDictionaryRef)current) ||
       !mx_write_plist(path.fileSystemRepresentation,(__bridge CFDictionaryRef)settings)) {
        [self alert:@"Could not save the imported settings. Your Options+ settings have not been changed."]; return;
    }
    [self load]; [self post:@"local.mxmouse.reload"];
    NSArray *warnings=result[@"warnings"];
    NSString *message=result[@"summary"] ?: @"Options+ settings imported.";
    if(warnings.count) message=[message stringByAppendingFormat:@"\n\n%@",[warnings componentsJoinedByString:@"\n"]];
    [self alert:message];
}
- (void)load {
    self.loadingSettings=YES;
    MXConfig config; char error[256] = {0};
    if (!mx_load_device_config(&config, self.selectedDeviceID.UTF8String, error, sizeof(error))) {
        mx_defaults(&config); [self alert:@(error)];
    }
    for (NSUInteger i=0;i<self.modes.count;++i) {
        NSDictionary *control=[self controlForSlot:i];
        MXBinding binding=i<MX_BUTTON_COUNT ? config.buttons[i] : (MXBinding){0};
        if(control) {
            int slot=control[@"bindingSlot"] ? [control[@"bindingSlot"] intValue] : i<MX_BUTTON_COUNT ? (int)i : -1;
            const MXBinding *found=mx_binding_for_control(&config,[control[@"cid"] unsignedShortValue],slot);
            if(found) binding=*found;
        }
        [self.modes[i] selectItemAtIndex:binding.action];
        self.recorders[i].keyCode=binding.key; self.recorders[i].shortcutModifiers=binding.modifiers;
        [self.recorders[i] updateTitle]; [self modeChanged:self.modes[i]];
    }
    [self.wheelMode selectItemAtIndex:config.wheel_mode];
    self.smartShiftThreshold = config.smartshift;
    [self.dpi removeAllItems];
    [self.dpi addItemsWithTitles:@[@"Leave unchanged", @"400 DPI", @"800 DPI", @"1000 DPI", @"1600 DPI", @"2000 DPI", @"3200 DPI", @"4000 DPI"]];
    NSArray *dpis = @[@0, @400, @800, @1000, @1600, @2000, @3200, @4000];
    NSUInteger index = [dpis indexOfObject:@(config.dpi)];
    if (index == NSNotFound) {
        [self.dpi addItemWithTitle:[NSString stringWithFormat:@"%d DPI", config.dpi]];
        index = self.dpi.numberOfItems - 1;
    }
    [self.dpi selectItemAtIndex:(NSInteger)index];
    self.verticalSpeed.integerValue = config.vertical_speed;
    self.horizontalSpeed.integerValue = config.horizontal_speed;
    self.invertVertical.state = config.invert_vertical;
    self.invertHorizontal.state = config.invert_horizontal;
    self.smooth.state = config.smooth;
    [self speedChanged:nil];
    self.loadingSettings=NO;
}
- (void)modeChanged:(NSPopUpButton *)sender {
    MXRecorder *recorder = self.recorders[(NSUInteger)sender.tag];
    recorder.enabled = sender.indexOfSelectedItem == MX_SHORTCUT;
    if (recorder.enabled) [recorder updateTitle];
    else recorder.title = @"—";
    [self updateCallouts];
    if (!self.loadingSettings) [self settingsChanged:sender];
}
- (void)speedChanged:(id)sender {
    self.verticalValue.stringValue = [NSString stringWithFormat:@"%ld%%", self.verticalSpeed.integerValue];
    self.horizontalValue.stringValue = [NSString stringWithFormat:@"%ld%%", self.horizontalSpeed.integerValue];
    if (sender) [self settingsChanged:sender];
}
- (BOOL)save {
    if(!self.selectedDeviceID.length) return NO;
    for (MXRecorder *recorder in self.recorders) if (recorder.recording) {
        [self alert:@"Finish recording the shortcut first, or press Escape to cancel."]; return NO;
    }
    NSMutableDictionary *root = [readDictionary(supportPath(@"settings.plist")) mutableCopy];
    NSMutableDictionary *profiles=[root[@"devices"] isKindOfClass:NSDictionary.class] ? [root[@"devices"] mutableCopy] : [NSMutableDictionary new];
    NSDictionary *existing=self.selectedDeviceID ? profiles[self.selectedDeviceID] : root;
    NSMutableDictionary *profile=[root mutableCopy];
    [profile removeObjectForKey:@"devices"];
    if([existing isKindOfClass:NSDictionary.class]) [profile addEntriesFromDictionary:existing];
    NSMutableDictionary *buttons = [profile[@"buttons"] isKindOfClass:NSDictionary.class] ? [profile[@"buttons"] mutableCopy] : [NSMutableDictionary new];
    // Save the selected mouse's actual effective bindings; unrelated global CIDs stay global.
    NSMutableDictionary *controls=[existing[@"controls"] isKindOfClass:NSDictionary.class] ? [existing[@"controls"] mutableCopy] : [NSMutableDictionary new];
    for(NSDictionary *control in self.availableControls) {
        NSUInteger i=[control[@"slot"] unsignedIntegerValue];
        if(i>=self.modes.count) continue;
        NSDictionary *binding=@{@"mode":@(self.modes[i].indexOfSelectedItem),@"keyCode":@(self.recorders[i].keyCode),@"modifiers":@(self.recorders[i].shortcutModifiers)};
        if(i<MX_BUTTON_COUNT) buttons[@(mx_button_keys[i])]=binding;
        controls[[NSString stringWithFormat:@"%04x",[control[@"cid"] unsignedShortValue]]]=binding;
    }
    profile[@"controls"]=controls;
    profile[@"buttons"] = buttons;
    if([self hasCapability:@"wheelMode"]) {
        profile[@"wheelMode"] = @(self.wheelMode.indexOfSelectedItem);
        profile[@"smartShift"] = @(self.smartShiftThreshold);
    }
    if([self hasCapability:@"dpi"]) profile[@"dpi"] = self.dpi.indexOfSelectedItem == 0 ? @0 : @(self.dpi.titleOfSelectedItem.intValue);
    if([self hasCapability:@"verticalScroll"]) profile[@"verticalSpeed"] = @(self.verticalSpeed.integerValue);
    if([self hasCapability:@"horizontalScroll"]) profile[@"horizontalSpeed"] = @(self.horizontalSpeed.integerValue);
    if([self hasCapability:@"verticalScroll"]) profile[@"invertVertical"] = self.invertVertical.state == NSControlStateValueOn ? @YES : @NO;
    if([self hasCapability:@"horizontalScroll"]) profile[@"invertHorizontal"] = self.invertHorizontal.state == NSControlStateValueOn ? @YES : @NO;
    if([self hasCapability:@"verticalScroll"]) profile[@"smooth"] = self.smooth.state == NSControlStateValueOn ? @YES : @NO;
    if(self.selectedDeviceID) { profiles[self.selectedDeviceID]=profile; root[@"devices"]=profiles; }
    else [root addEntriesFromDictionary:profile];
    NSString *path = supportPath(@"settings.plist");
    if (!path || !mx_write_plist(path.fileSystemRepresentation, (__bridge CFDictionaryRef)root)) {
        [self alert:@"Could not save settings. Check that your Application Support folder is writable."]; return NO;
    }
    return YES;
}
- (void)post:(NSString *)name {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:nil deliverImmediately:YES];
}
- (void)settingsChanged:(id)sender {
    (void)sender;
    if (self.loadingSettings) return;
    [self cancelRecording];
    if (![self save]) return;
    self.pendingApply=YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPendingSettings) object:nil];
    [self performSelector:@selector(applyPendingSettings) withObject:nil afterDelay:0.15];
}
- (void)applyPendingSettings {
    if (!self.pendingApply) return;
    self.pendingApply=NO;
    [self post:@"local.mxmouse.reload"];
}
- (BOOL)helperRunning {
    NSDictionary *status = readDictionary(supportPath(@"status.plist"));
    pid_t pid = [status[@"pid"] intValue];
    if (pid <= 0 || kill(pid, 0)) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    return [@(path).lastPathComponent isEqualToString:@"mxmouse-helper"];
}
- (void)launchHelper:(NSArray<NSString *> *)arguments {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = NO; configuration.arguments = arguments;
    configuration.allowsRunningApplicationSubstitution=NO;
    configuration.createsNewApplicationInstance=arguments.count>0;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:self.helperURL configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.helperTransition=0; self.checkingPermissions=NO;
                [self refresh:nil]; [self alert:error.localizedDescription];
            } else {
                if (!arguments.count) self.launchedHelper=application;
                [self performSelector:@selector(refresh:) withObject:nil afterDelay:0.5];
            }
        });
    }];
}
- (void)startHelper:(id)sender {
    (void)sender;
    if ([self helperRunning]) { [self settingsChanged:nil]; return; }
    char conflict[256];
    if (mx_conflicting_process(conflict)) { self.helperTransition=0; [self refresh:nil]; [self alert:@(conflict)]; return; }
    if ([self save]) [self launchHelper:@[]];
    else { self.helperTransition=0; [self refresh:nil]; }
}
- (void)permissions:(id)sender {
    (void)sender;
    if(self.permissionSheet) return;
    NSWindow *sheet=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,320) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    sheet.title=@"Set Up Permissions";
    self.permissionSheet=sheet;
    NSView *content=sheet.contentView;
    NSTextField *intro=[NSTextField wrappingLabelWithString:@"Enable MX Mouse Helper in both permission lists. If an enabled entry does not work, remove it and drag the helper below into the list again."];
    intro.font=[NSFont systemFontOfSize:13]; intro.frame=NSMakeRect(24,244,472,52); [content addSubview:intro];
    self.inputPermissionButton=[self button:@"Open Settings…" action:@selector(openInputMonitoring:)];
    self.accessibilityPermissionButton=[self button:@"Open Settings…" action:@selector(openAccessibility:)];
    NSArray *buttons=@[self.inputPermissionButton,self.accessibilityPermissionButton];
    NSArray *names=@[@"Input Monitoring",@"Accessibility"];
    NSMutableArray *states=[NSMutableArray new];
    for(NSUInteger i=0;i<2;++i) {
        CGFloat y=198-i*42;
        NSTextField *name=[self label:names[i] size:13 weight:NSFontWeightMedium]; name.frame=NSMakeRect(24,y,150,24); [content addSubview:name];
        NSTextField *state=[self label:@"Checking…" size:12 weight:NSFontWeightRegular]; state.frame=NSMakeRect(180,y,140,24); [content addSubview:state]; [states addObject:state];
        NSButton *button=buttons[i]; button.frame=NSMakeRect(338,y-2,158,28); [content addSubview:button];
    }
    self.permissionStates=states;
    MXHelperDragView *helperDragView=[[MXHelperDragView alloc] initWithFrame:NSMakeRect(24,64,240,76)]; helperDragView.helperURL=self.helperURL; [content addSubview:helperDragView];
    self.requestAccessButton=[self button:@"Request Access…" action:@selector(requestPermissions:)]; self.requestAccessButton.frame=NSMakeRect(338,88,158,28); [content addSubview:self.requestAccessButton];
    NSButton *done=[self button:@"Done" action:@selector(closePermissionSheet:)]; done.frame=NSMakeRect(406,20,90,28); done.keyEquivalent=@"\r"; [content addSubview:done];
    [self updatePermissionLabels];
    [self.window beginSheet:sheet completionHandler:^(NSModalResponse response) { (void)response; self.permissionSheet=nil; }];
}
- (void)closePermissionSheet:(id)sender {
    (void)sender;
    [self.window endSheet:self.permissionSheet];
    [self checkPermissions:nil];
}
- (void)quitOptions:(id)sender {
    (void)sender; if(self.quittingOptions) return;
    self.quittingOptions=YES; [self refresh:nil];
    [MXLogiControls quitOptionsWithCompletion:^(NSString *error) {
        self.quittingOptions=NO; self.autoStartAttempted=NO; [self refresh:nil];
        if(error) [self alert:error];
    }];
}
- (void)uninstallOptions:(id)sender {
    (void)sender;
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Uninstall Logi Options+?";
    alert.informativeText=@"This starts Logitech’s installed uninstaller. It may ask for your administrator password. Import your Options+ settings first if you want to keep them in MX Mouse.";
    [alert addButtonWithTitle:@"Uninstall"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if(response!=NSAlertFirstButtonReturn) return;
        NSError *error=nil;
        if(![MXLogiControls openUninstallerWithError:&error]) [self alert:error.localizedDescription];
    }];
}
- (NSDictionary *)permissionSnapshot {
    if ([self helperRunning]) return readDictionary(supportPath(@"status.plist"));
    NSDictionary *value=readDictionary(supportPath(@"permissions.plist"));
    return [value[@"checkedAt"] doubleValue]>=self.permissionsRequestedAt ? value : @{};
}
- (void)updatePermissionLabels {
    NSDictionary *snapshot=[self permissionSnapshot];
    BOOL known=[snapshot[@"inputMonitoring"] isKindOfClass:NSNumber.class] && [snapshot[@"accessibility"] isKindOfClass:NSNumber.class];
    if(self.checkingPermissions && !known && CFAbsoluteTimeGetCurrent()-self.permissionsRequestedAt>8) self.checkingPermissions=NO;
    if(known) self.checkingPermissions=NO;
    BOOL canPost=[snapshot[@"postEventAccess"] boolValue];
    BOOL allReady=known && [snapshot[@"inputMonitoring"] boolValue] && [snapshot[@"accessibility"] boolValue] && canPost;
    self.permissionsButton.hidden=allReady;
    self.requestAccessButton.enabled=!self.checkingPermissions;
    NSArray<NSButton *> *buttons=self.permissionSheet ? @[self.inputPermissionButton,self.accessibilityPermissionButton] : @[];
    NSArray<NSString *> *keys=@[@"inputMonitoring",@"accessibility"], *names=@[@"Input Monitoring",@"Accessibility"];
    for(NSUInteger i=0;i<2;++i) {
        BOOL enabled=known && [snapshot[keys[i]] boolValue];
        NSString *state=known ? (enabled ? @"Access granted" : @"Access denied") : (self.checkingPermissions ? @"Checking…" : @"Unknown");
        BOOL functional=enabled && (i==0 || canPost);
        if(i==1 && enabled && !canPost) state=@"Input blocked";
        NSString *symbol=known ? (functional ? @"checkmark.circle.fill" : @"exclamationmark.circle") : @"clock";
        self.permissionIndicators[i].image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:state];
        self.permissionIndicators[i].contentTintColor=known ? (functional ? NSColor.systemGreenColor : NSColor.systemOrangeColor) : NSColor.secondaryLabelColor;
        if(!self.permissionSheet) continue;
        self.permissionStates[i].stringValue=state;
        self.permissionStates[i].textColor=NSColor.secondaryLabelColor;
        buttons[i].toolTip=[NSString stringWithFormat:@"Open %@ in System Settings. Grant access to MX Mouse Helper. Status: %@.",names[i],state];
        if(i==1 && enabled && !canPost) buttons[i].toolTip=@"Accessibility is granted, but macOS is denying simulated input. Use Request Access; if still denied, remove and re-add the current MX Mouse Helper.";
    }
}
- (void)checkPermissions:(id)sender {
    (void)sender;
    if(!self.window || self.checkingPermissions) return;
    if([self helperRunning]) { [self post:@"local.mxmouse.status"]; [self updatePermissionLabels]; return; }
    self.checkingPermissions=YES; self.permissionsRequestedAt=CFAbsoluteTimeGetCurrent();
    [self updatePermissionLabels]; [self launchHelper:@[@"--check-permissions"]];
}
- (void)requestPermissions:(id)sender {
    (void)sender;
    self.checkingPermissions=YES; self.permissionsRequestedAt=CFAbsoluteTimeGetCurrent();
    [self updatePermissionLabels]; [self launchHelper:@[@"--permissions"]];
}
- (void)openInputMonitoring:(id)sender { (void)sender; [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]]; }
- (void)openAccessibility:(id)sender { (void)sender; [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]]; }
- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if(!self.helperTransition) self.autoStartAttempted=NO;
    [self checkPermissions:nil];
}
- (void)loginChanged:(NSButton *)sender {
    NSError *error = nil;
    BOOL success = sender.state == NSControlStateValueOn ? [self.loginService registerAndReturnError:&error] : [self.loginService unregisterAndReturnError:&error];
    if (!success) {
        sender.state = self.loginService.status == SMAppServiceStatusEnabled;
        [self alert:error.localizedDescription ?: @"Could not change the login item. Install MX Mouse Settings in Applications first."];
    } else if (self.loginService.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
}
- (void)refresh:(id)sender {
    (void)sender;
    BOOL optionsInstalled=[MXLogiControls installed];
    BOOL optionsRunning=[MXLogiControls running];
    self.quitOptionsButton.hidden=!optionsInstalled;
    self.importOptionsButton.hidden=!optionsInstalled || ![self canImportOptions];
    self.quitOptionsButton.enabled=optionsRunning && !self.quittingOptions;
    self.quitOptionsButton.title=self.quittingOptions ? @"Quitting…" : @"Quit Options+";
    self.uninstallOptionsButton.hidden=!optionsInstalled;
    BOOL running = [self helperRunning];
    if (running) [self post:@"local.mxmouse.status"];
    NSDictionary *status = readDictionary(supportPath(@"status.plist"));
    NSDictionary *active=[self updateDevice:status];
    self.importOptionsButton.hidden=!optionsInstalled || ![self canImportOptions];
    NSNumber *battery=[active[@"batteryPercent"] isKindOfClass:NSNumber.class] ? active[@"batteryPercent"] : nil;
    NSString *batteryState=[active[@"batteryStatus"] isKindOfClass:NSString.class] ? active[@"batteryStatus"] : @"";
    BOOL knownBattery=running && [active[@"connected"] boolValue] &&
        ((battery && battery.integerValue>=0 && battery.integerValue<=100) || batteryState.length);
    self.batteryLabel.hidden=self.batteryIcon.hidden=!knownBattery;
    if (knownBattery) {
        self.batteryLabel.stringValue=battery ? [NSString stringWithFormat:@"%ld%%%@",battery.integerValue,[active[@"batteryCharging"] boolValue] ? @" · Charging" : @""] : batteryState;
        NSString *symbol=[active[@"batteryCharging"] boolValue] ? @"battery.100percent.bolt" :
            !battery ? @"battery.50percent" : battery.integerValue<=10 ? @"battery.0percent" :
            battery.integerValue<=35 ? @"battery.25percent" : battery.integerValue<=65 ? @"battery.50percent" :
            battery.integerValue<=85 ? @"battery.75percent" : @"battery.100percent";
        self.batteryIcon.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Mouse battery"];
        self.batteryIcon.contentTintColor=battery && battery.integerValue<=10 ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
        self.batteryLabel.toolTip=@"Battery level reported by the connected mouse.";
    }

    NSString *state = [active[@"state"] isKindOfClass:NSString.class] ? active[@"state"] : @"";
    NSString *detail = [active[@"detail"] isKindOfClass:NSString.class] ? active[@"detail"] : @"";
    NSString *failure=nil;
    CFAbsoluteTime elapsed=CFAbsoluteTimeGetCurrent()-self.transitionStartedAt;
    if(self.helperTransition==1) {
        if(running) self.helperTransition=0;
        else if(self.launchedHelper.terminated || elapsed>5) {
            self.helperTransition=0;
            BOOL current=[status[@"pid"] intValue]==self.launchedHelper.processIdentifier;
            failure=current && detail.length ? detail : @"Mouse controls could not start. Check Permissions and try again.";
            [self checkPermissions:nil];
        }
    }
    char conflict[256];
    if(self.helperTransition) self.statusLabel.stringValue=@"Starting mouse controls…";
    else if (running) self.statusLabel.stringValue = detail;
    else if (mx_conflicting_process(conflict)) self.statusLabel.stringValue = @(conflict);
    else if ([state isEqualToString:@"permission"] || [state isEqualToString:@"error"])
        self.statusLabel.stringValue = detail;
    else {
        NSDictionary *permissions=[self permissionSnapshot];
        BOOL ready=[permissions[@"inputMonitoring"] boolValue] && [permissions[@"postEventAccess"] boolValue];
        self.statusLabel.stringValue=self.checkingPermissions ? @"Checking permissions…" : ready ? @"Mouse controls start automatically." : @"Permissions required.";
    }
    self.statusLabel.hidden=!self.helperTransition && !failure.length && ![state isEqualToString:@"error"] && ![state isEqualToString:@"waiting"] && [active[@"connected"] boolValue] && !mx_conflicting_process(conflict);
    [self updatePermissionLabels];
    /* Keep the visible status fresh while the user changes System Settings.
       This runs only with this Settings window open, never in the resident helper. */
    NSDictionary *permissions=[self permissionSnapshot];
    BOOL ready=[permissions[@"inputMonitoring"] boolValue] && [permissions[@"postEventAccess"] boolValue];
    if(!running && !ready && !self.checkingPermissions && CFAbsoluteTimeGetCurrent()-self.permissionsRequestedAt>=5 &&
       ![NSProcessInfo.processInfo.arguments containsObject:@"--render-preview"])
        [self checkPermissions:nil];
    if(failure) [self alert:failure];
    else [self startHelperIfReady];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application { (void)application; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPendingSettings) object:nil];
    [self applyPendingSettings];
    [self.statusTimer invalidate];
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        SettingsDelegate *delegate = [SettingsDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
