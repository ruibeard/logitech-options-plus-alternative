#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "mouse_view.h"
#import "import_options.h"
#import "logi_controls.h"
#import "helper_drag_view.h"
#include "storage.h"
#include <libproc.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

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
    if(self) { self.focusRingType=NSFocusRingTypeNone; self.toolTip=@"Click to change this button’s action and keyboard shortcut."; }
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

@interface MXDeviceListView : NSView
@end
@implementation MXDeviceListView
- (BOOL)isFlipped { return YES; }
@end

// Native buttons keep picture-based device selection keyboard accessible.
@interface MXDeviceButton : NSButton
@property NSString *connectionLabel;
@property NSImage *connectionImage;
@property BOOL connected;
@property NSString *batteryText;
@property NSImage *batteryImage;
@end
@implementation MXDeviceButton
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    if(self.state==NSControlStateValueOn || self.highlighted) {
        [[NSColor.labelColor colorWithAlphaComponent:self.highlighted ? 0.12 : 0.07] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,4,3) xRadius:9 yRadius:9] fill];
    }
    NSSize size=self.image.size;
    CGFloat scale=size.width>0 && size.height>0 ? MIN(68/size.width,76/size.height) : 1;
    NSRect picture=NSMakeRect((164-size.width*scale)/2,12+(76-size.height*scale)/2,size.width*scale,size.height*scale);
    [self.image drawInRect:picture fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
    paragraph.alignment=NSTextAlignmentCenter; paragraph.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.title drawInRect:NSMakeRect(10,96,144,18) withAttributes:@{
        NSFontAttributeName:[NSFont systemFontOfSize:12 weight:self.state==NSControlStateValueOn ? NSFontWeightSemibold : NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:paragraph}];
    NSDictionary *caption=@{NSFontAttributeName:[NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:paragraph};
    NSImage *statusIcon=self.connectionImage;
    NSColor *statusColor=self.connected ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    statusIcon=[statusIcon copy]; statusIcon.template=YES;
    NSImage *tinted=[[NSImage alloc] initWithSize:NSMakeSize(16,16)];
    [tinted lockFocus];
    [statusIcon drawInRect:NSMakeRect(0,0,16,16)];
    [statusColor setFill]; NSRectFillUsingOperation(NSMakeRect(0,0,16,16),NSCompositingOperationSourceIn);
    [tinted unlockFocus];
    CGFloat statusWidth=MIN(126,[self.connectionLabel sizeWithAttributes:caption].width);
    CGFloat statusX=(164-statusWidth-16)/2;
    NSRect iconRect=NSMakeRect(statusX,116,14,14);
    [tinted drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.connectionLabel drawInRect:NSMakeRect(statusX+16,116,statusWidth,15) withAttributes:caption];
    CGFloat batteryWidth=MIN(124,[self.batteryText sizeWithAttributes:caption].width);
    CGFloat batteryX=(164-batteryWidth-22)/2;
    [self.batteryImage drawInRect:NSMakeRect(batteryX,134,18,10) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.batteryText drawInRect:NSMakeRect(batteryX+22,132,batteryWidth,15) withAttributes:caption];
}
@end

// Positions from the installed M705 Options+ core_metadata.json; controls still
// come from HID++ discovery, so variants never acquire absent buttons.
static BOOL m705Layout(unsigned cid, NSPoint *marker, NSRect *callout) {
    switch(cid) {
        case 0x52: *marker=NSMakePoint(66.5,18); *callout=NSMakeRect(450,340,200,72); break;
        case 0x53: *marker=NSMakePoint(43,60); *callout=NSMakeRect(0,175,195,72); break;
        case 0x56: *marker=NSMakePoint(35,47); *callout=NSMakeRect(0,275,195,72); break;
        case 0x59: *marker=NSMakePoint(6,54.5); *callout=NSMakeRect(0,75,195,72); break;
        case 0x5b: *marker=NSMakePoint(63,24.5); *callout=NSMakeRect(450,245,200,72); break;
        case 0x5d: *marker=NSMakePoint(75,21); *callout=NSMakeRect(450,150,200,72); break;
        default: return NO;
    }
    return YES;
}

@interface MXDiagram : NSView
@property NSArray<NSValue *> *anchors;
@property NSArray<NSValue *> *ends;
@property BOOL compactMouse;
@property NSIndexSet *visibleControls;
@property NSArray<NSDictionary *> *mappedControls;
@end
@implementation MXDiagram
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    NSColor *ink = [NSColor.secondaryLabelColor colorWithAlphaComponent:0.48];
    NSMutableArray<NSValue *> *anchors=[self.anchors mutableCopy], *ends=[self.ends mutableCopy];
    if(self.mappedControls) {
        anchors=[NSMutableArray new]; ends=[NSMutableArray new];
        for(NSDictionary *control in self.mappedControls) {
            NSPoint marker; NSRect card;
            if(!m705Layout([control[@"cid"] unsignedIntValue],&marker,&card)) continue;
            // The 1169×1916 image is centered in the 270×430 view at (205,10).
            NSPoint point=NSMakePoint(208.82+262.36*marker.x/100,440-430*marker.y/100);
            [anchors addObject:[NSValue valueWithPoint:point]];
            [ends addObject:[NSValue valueWithPoint:NSMakePoint(card.origin.x<200 ? NSMaxX(card)-6 : card.origin.x+6,NSMidY(card))]];
        }
    }
    for (NSUInteger i = 0; i < anchors.count; ++i) {
        if (!self.mappedControls && self.visibleControls && ![self.visibleControls containsIndex:i]) continue;
        if (!self.mappedControls && self.compactMouse && i >= 4) continue;
        NSPoint point = anchors[i].pointValue, start = ends[i].pointValue;
        if(self.compactMouse && !self.mappedControls) {
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
@property NSTextField *deviceSubtitle;
@property MXMouseView *mouseView;
@property MXDiagram *diagramLines;
@property NSMutableArray<NSView *> *masterOnlyViews;
@property BOOL compactMouse;
@property BOOL genericMouse;
@property NSScrollView *deviceSidebar;
@property NSMutableArray<MXDeviceButton *> *deviceButtons;
@property NSImage *masterThumbnail;
@property NSImage *compactThumbnail;
@property NSPopUpButton *controlSelector;
@property NSTableView *controlTable;
@property NSScrollView *controlList;
@property NSView *buttonEditor;
@property NSPopover *shortcutPopover;
@property NSView *scrollSection;
@property NSTextField *scrollSectionTitle;
@property NSArray<NSTextField *> *scrollRowLabels;
@property NSDictionary<NSString *,NSImage *> *connectionImages;
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
@property NSMutableArray<MXCallout *> *extraCallouts;
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
    [self.window setContentSize:NSMakeSize(1050, 588)];
    NSView *canvas=self.window.contentView;
    NSView *root=[[NSView alloc] initWithFrame:NSMakeRect(180,0,870,588)];
    [canvas addSubview:root];
    NSTextField *devicesHeading=[self label:@"Your mice" size:13 weight:NSFontWeightSemibold];
    devicesHeading.frame=NSMakeRect(20,534,144,22); [canvas addSubview:devicesHeading];
    NSBox *sidebarDivider=[[NSBox alloc] initWithFrame:NSMakeRect(179,18,1,552)];
    sidebarDivider.boxType=NSBoxSeparator; [canvas addSubview:sidebarDivider];
    self.deviceSidebar=[[NSScrollView alloc] initWithFrame:NSMakeRect(8,18,164,498)];
    self.deviceSidebar.drawsBackground=NO; self.deviceSidebar.hasVerticalScroller=YES;
    self.deviceSidebar.autohidesScrollers=YES;
    self.deviceSidebar.documentView=[[MXDeviceListView alloc] initWithFrame:self.deviceSidebar.bounds];
    [canvas addSubview:self.deviceSidebar];
    self.deviceButtons=[NSMutableArray new];
    self.masterThumbnail=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"mx-master-3" ofType:@"png"]];
    self.compactThumbnail=[[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"m705" ofType:@"png"]];
    self.window.backgroundColor=[NSColor colorWithName:@"MXCanvas" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return [NSColor colorWithCalibratedWhite:dark ? 0.12 : 0.975 alpha:1];
    }];
    self.masterOnlyViews=[NSMutableArray new];
    self.wheelViews=[NSMutableArray new]; self.horizontalViews=[NSMutableArray new]; self.verticalViews=[NSMutableArray new]; self.dpiViews=[NSMutableArray new];
    self.importOptionsButton=[self button:@"Import from Options+…" action:@selector(importOptions:)];
    self.importOptionsButton.frame=NSMakeRect(30,625,200,28); [root addSubview:self.importOptionsButton];
    self.quitOptionsButton=[self button:@"Quit Options+" action:@selector(quitOptions:)];
    self.quitOptionsButton.frame=NSMakeRect(236,625,114,28); [root addSubview:self.quitOptionsButton];
    self.quitOptionsButton.toolTip=@"Quit Options+ and stop its mouse agent for this login session.";
    self.uninstallOptionsButton=[self button:@"Uninstall Options+…" action:@selector(uninstallOptions:)];
    self.uninstallOptionsButton.frame=NSMakeRect(354,625,166,28); [root addSubview:self.uninstallOptionsButton];
    NSView *diagram = [[NSView alloc] initWithFrame:NSMakeRect(26, 168, 820, 440)]; [root addSubview:diagram];
    MXMouseView *mouse = [[MXMouseView alloc] initWithFrame:NSMakeRect(205, 10, 270, 430)]; [diagram addSubview:mouse]; self.mouseView=mouse;
    MXDiagram *arrows=[[MXDiagram alloc] initWithFrame:diagram.bounds]; [diagram addSubview:arrows]; self.diagramLines=arrows;
    self.callouts = [NSMutableArray new]; self.extraCallouts=[NSMutableArray new];
    NSArray *names = @[@"Middle button", @"Back", @"Forward", @"Thumb button", @"Top button"];
    NSArray<NSValue *> *frames = @[[NSValue valueWithRect:NSMakeRect(432,340,177,72)], [NSValue valueWithRect:NSMakeRect(270,75,174,72)], [NSValue valueWithRect:NSMakeRect(94,235,176,72)], [NSValue valueWithRect:NSMakeRect(0,145,211,90)], [NSValue valueWithRect:NSMakeRect(452,250,185,90)]];
    self.modes = [NSMutableArray new]; self.recorders = [NSMutableArray new]; self.buttonPanes = [NSMutableArray new];
    NSView *buttonEditor = [[NSView alloc] initWithFrame:NSMakeRect(12,12,240,120)];
    self.buttonEditor=buttonEditor;
    self.controlSelector=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(60,526,580,32) pullsDown:NO];
    self.controlSelector.target=self; self.controlSelector.action=@selector(controlChanged:);
    self.controlSelector.hidden=YES;
    self.controlList=[[NSScrollView alloc] initWithFrame:NSMakeRect(60,228,600,330)];
    self.controlList.drawsBackground=NO; self.controlList.hasVerticalScroller=YES;
    self.controlTable=[[NSTableView alloc] initWithFrame:self.controlList.bounds];
    self.controlTable.target=self; self.controlTable.action=@selector(editSelectedControl:);
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
        MXCallout *callout=[[MXCallout alloc] initWithFrame:NSZeroRect]; callout.bordered=NO;
        callout.tag=(NSInteger)i; callout.target=self; callout.action=@selector(selectButton:); callout.hidden=YES;
        [diagram addSubview:callout]; [self.extraCallouts addObject:callout];
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
    NSView *scrollEditor=[[NSView alloc] initWithFrame:NSMakeRect(555,5,250,162)];
    self.scrollSection=scrollEditor; [diagram addSubview:scrollEditor];
    NSTextField *scrollTitle=[self label:@"Point & Scroll" size:14 weight:NSFontWeightSemibold]; self.scrollSectionTitle=scrollTitle; scrollTitle.frame=NSMakeRect(0,260,240,26); [scrollEditor addSubview:scrollTitle];
    self.wheelMode=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,208,235,28) pullsDown:NO]; [self.wheelMode addItemsWithTitles:@[@"Leave unchanged", @"Ratchet", @"Free spin", @"SmartShift"]]; [scrollEditor addSubview:self.wheelMode];
    NSArray *sectionNames=@[@"Wheel", @"Vertical", @"Horizontal", @"Pointer"];
    NSMutableArray *scrollLabels=[NSMutableArray new];
    for(NSUInteger i=0;i<4;++i) {
        NSTextField *label=[self label:sectionNames[i] size:11 weight:NSFontWeightRegular];
        [scrollEditor addSubview:label]; [scrollLabels addObject:label];
        if(i==0) [self.wheelViews addObject:label];
        if(i==1) [self.verticalViews addObject:label];
        if(i==2) [self.horizontalViews addObject:label];
        if(i==3) [self.dpiViews addObject:label];
    }
    self.scrollRowLabels=scrollLabels;
    self.verticalSpeed=[NSSlider sliderWithValue:100 minValue:10 maxValue:300 target:self action:@selector(speedChanged:)]; self.verticalSpeed.frame=NSMakeRect(0,157,177,22); [scrollEditor addSubview:self.verticalSpeed];
    self.horizontalSpeed=[NSSlider sliderWithValue:100 minValue:10 maxValue:300 target:self action:@selector(speedChanged:)]; self.horizontalSpeed.frame=NSMakeRect(0,88,177,22); [scrollEditor addSubview:self.horizontalSpeed];
    self.verticalValue=[self label:@"100%" size:10 weight:NSFontWeightRegular]; self.verticalValue.frame=NSMakeRect(184,157,54,22); [scrollEditor addSubview:self.verticalValue];
    self.horizontalValue=[self label:@"100%" size:10 weight:NSFontWeightRegular]; self.horizontalValue.frame=NSMakeRect(184,88,54,22); [scrollEditor addSubview:self.horizontalValue];
    self.invertVertical=[NSButton checkboxWithTitle:@"↕" target:nil action:nil]; self.invertVertical.frame=NSMakeRect(0,135,104,22); [scrollEditor addSubview:self.invertVertical];
    self.invertHorizontal=[NSButton checkboxWithTitle:@"↔" target:nil action:nil]; self.invertHorizontal.frame=NSMakeRect(0,66,235,22); [scrollEditor addSubview:self.invertHorizontal];
    self.smooth=[NSButton checkboxWithTitle:@"Smooth scrolling" target:nil action:nil]; self.smooth.frame=NSMakeRect(110,135,130,22); [scrollEditor addSubview:self.smooth];
    self.dpi=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,10,235,28) pullsDown:NO]; [self.dpi addItemsWithTitles:@[@"Leave unchanged", @"400 DPI", @"800 DPI", @"1000 DPI", @"1600 DPI", @"2000 DPI", @"3200 DPI", @"4000 DPI"]]; [scrollEditor addSubview:self.dpi];
    self.invertVertical.toolTip=@"Reverse vertical scroll direction";
    self.invertVertical.accessibilityLabel=@"Reverse vertical scroll direction";
    self.invertHorizontal.toolTip=@"Reverse horizontal scroll direction";
    self.invertHorizontal.accessibilityLabel=@"Reverse horizontal scroll direction";
    self.smooth.font=[NSFont systemFontOfSize:11];
    [self.masterOnlyViews addObjectsFromArray:@[self.wheelMode,self.horizontalSpeed,self.horizontalValue,self.invertHorizontal,self.dpi]];
    [self.wheelViews addObject:self.wheelMode]; [self.dpiViews addObject:self.dpi];
    [self.horizontalViews addObjectsFromArray:@[self.horizontalSpeed,self.horizontalValue,self.invertHorizontal]];
    [self.verticalViews addObjectsFromArray:@[self.verticalSpeed,self.verticalValue,self.invertVertical,self.smooth]];
    NSBox *footerLine=[[NSBox alloc] initWithFrame:NSMakeRect(32,155,796,1)]; footerLine.boxType=NSBoxSeparator; [root addSubview:footerLine];
    self.statusLabel=[NSTextField wrappingLabelWithString:@"Helper stopped."]; self.statusLabel.font=[NSFont systemFontOfSize:12]; self.statusLabel.frame=NSMakeRect(34,38,690,26); [root addSubview:self.statusLabel];
    self.loginService=[SMAppService loginItemServiceWithIdentifier:@"local.mxmouse.helper"];
    NSButton *login=[NSButton checkboxWithTitle:@"Start at login" target:self action:@selector(loginChanged:)]; login.font=[NSFont systemFontOfSize:12]; login.state=self.loginService.status==SMAppServiceStatusEnabled; login.frame=NSMakeRect(34,10,160,24); [root addSubview:login];
    NSArray<NSString *> *permissionNames=@[@"Input Monitoring",@"Accessibility"];
    NSMutableArray *indicators=[NSMutableArray new];
    for(NSUInteger i=0;i<permissionNames.count;++i) {
        NSView *group=[[NSView alloc] initWithFrame:NSMakeRect(230+i*170,10,160,24)];
        NSImageView *indicator=[[NSImageView alloc] initWithFrame:NSMakeRect(0,5,14,14)];
        indicator.imageScaling=NSImageScaleProportionallyDown; [indicators addObject:indicator]; [group addSubview:indicator];
        NSTextField *name=[self label:permissionNames[i] size:12 weight:NSFontWeightRegular];
        name.frame=NSMakeRect(20,0,140,24); [group addSubview:name]; [root addSubview:group];
    }
    self.permissionIndicators=indicators;
    self.permissionsButton=[self button:@"Set Up…" action:@selector(permissions:)];
    self.permissionsButton.frame=NSMakeRect(740,10,114,28); [root addSubview:self.permissionsButton];
    self.shortcutPopover=[NSPopover new]; self.shortcutPopover.behavior=NSPopoverBehaviorTransient;
    NSViewController *shortcutController=[NSViewController new];
    shortcutController.view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,264,144)];
    [shortcutController.view addSubview:buttonEditor]; self.shortcutPopover.contentViewController=shortcutController;
    // Keep the main controls in place relative to the top as the footer shrinks.
    for(NSView *view in root.subviews) if(view.frame.origin.y>=155) {
        NSRect frame=view.frame; frame.origin.y-=88; view.frame=frame;
    }
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
        NSUInteger deviceSelection=[arguments indexOfObject:@"--preview-device"];
        if(deviceSelection!=NSNotFound && deviceSelection+1<arguments.count) self.selectedDeviceID=arguments[deviceSelection+1];
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
- (void)deviceChanged:(NSButton *)sender {
    [self.shortcutPopover close];
    [self cancelRecording]; [self applyPendingSettings];
    NSInteger index=sender.tag;
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
- (NSArray *)rememberedDevices:(NSDictionary *)status {
    NSString *path=supportPath(@"known-devices.plist");
    NSDictionary *saved=readDictionary(path);
    NSMutableDictionary *known=[saved mutableCopy];
    NSMutableArray *entries=[NSMutableArray new]; NSMutableSet *seen=[NSMutableSet new];
    NSArray *live=[status[@"devices"] isKindOfClass:NSArray.class] ? status[@"devices"] : @[];
    for(id item in live) {
        if(![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *device=item;
        NSString *identity=[device[@"id"] isKindOfClass:NSString.class] ? device[@"id"] : nil;
        if(!identity.length) continue;
        [seen addObject:identity];
        NSDictionary *previous=[known[identity] isKindOfClass:NSDictionary.class] ? known[identity] : nil;
        NSArray *controls=[device[@"controls"] isKindOfClass:NSArray.class] ? device[@"controls"] : @[];
        NSMutableDictionary *entry=[device mutableCopy];
        if([device[@"connected"] boolValue] && controls.count) {
            // Persist layout only, never stale live connection/battery state or bindings.
            NSMutableDictionary *layout=[NSMutableDictionary new];
            for(NSString *key in @[@"id",@"name",@"transport",@"controls",@"capabilities"]) if(device[key]) layout[key]=device[key];
            known[identity]=layout;
        } else if(![device[@"connected"] boolValue]) {
            if(previous) {
                for(NSString *key in @[@"name",@"transport",@"controls",@"capabilities"]) if(previous[key]) entry[key]=previous[key];
            } else if(!controls.count && ([identity hasPrefix:@"logitech-4082-"] || [identity hasPrefix:@"logitech-b023-"])) {
                // Existing MX Master 3 installs predate the cache. These exact
                // model IDs have a known layout; live discovery supersedes it.
                NSMutableArray *legacy=[NSMutableArray new];
                const MXDeviceDefinition *model=mx_device_lookup(0x046d,0xb023);
                for(NSUInteger slot=0;model && slot<MX_BUTTON_COUNT;++slot) {
                    unsigned cid=model->button_controls[slot]; if(!cid) continue;
                    const char *name=mx_control_name(cid);
                    [legacy addObject:@{@"cid":@(cid),@"slot":@(slot),@"name":name ? @(name) : @"Mouse control",@"divertible":@YES}];
                }
                entry[@"controls"]=legacy;
                entry[@"capabilities"]=@{@"buttons":@YES,@"verticalScroll":@YES,@"horizontalScroll":@YES,
                    @"dpi":@YES,@"wheelMode":@YES,@"smartShift":@YES,@"battery":@YES};
                NSMutableDictionary *layout=[NSMutableDictionary new];
                for(NSString *key in @[@"id",@"name",@"transport",@"controls",@"capabilities"]) if(entry[key]) layout[key]=entry[key];
                known[identity]=layout;
            }
        }
        [entries addObject:entry];
    }
    // A receiver or Bluetooth removal must not remove the saved mouse from Settings.
    for(NSString *identity in [[known allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if([seen containsObject:identity] || ![known[identity] isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry=[known[identity] mutableCopy];
        entry[@"connected"]=@NO; entry[@"state"]=@"waiting"; entry[@"detail"]=@"Mouse is offline. Showing saved settings.";
        [entries addObject:entry];
    }
    if(path && ![known isEqual:saved]) mx_write_plist(path.fileSystemRepresentation,(__bridge CFDictionaryRef)known);
    return entries;
}
- (NSDictionary *)updateDevice:(NSDictionary *)status {
    NSArray *entries=[self rememberedDevices:status];
    self.devices=entries;
    NSDictionary *device=nil;
    for(NSDictionary *candidate in entries) if([candidate[@"id"] isEqual:self.selectedDeviceID]) { device=candidate; break; }
    if(!device) for(NSDictionary *candidate in entries) if([candidate[@"connected"] boolValue]) { device=candidate; break; }
    if(!device) device=entries.firstObject;
    BOOL changed=![self.selectedDeviceID ?: @"" isEqual:device[@"id"] ?: @""] || !self.selectedDevice;
    self.selectedDeviceID=[device[@"id"] isKindOfClass:NSString.class] ? device[@"id"] : nil;
    self.selectedDevice=device;
    if(!self.deviceButtons) self.deviceButtons=[NSMutableArray new];
    while(self.deviceButtons.count>entries.count) {
        [self.deviceButtons.lastObject removeFromSuperview]; [self.deviceButtons removeLastObject];
    }
    CGFloat height=MAX(self.deviceSidebar.contentSize.height,entries.count*158.0);
    [self.deviceSidebar.documentView setFrameSize:NSMakeSize(164,height)];
    for(NSUInteger i=0;i<entries.count;++i) {
        NSDictionary *candidate=entries[i];
        MXDeviceButton *button;
        if(i<self.deviceButtons.count) button=self.deviceButtons[i];
        else {
            button=[[MXDeviceButton alloc] initWithFrame:NSZeroRect];
            button.bordered=NO; [button setButtonType:NSButtonTypePushOnPushOff];
            button.target=self; button.action=@selector(deviceChanged:);
            [self.deviceButtons addObject:button]; [self.deviceSidebar.documentView addSubview:button];
        }
        button.frame=NSMakeRect(0,i*158,164,154); button.tag=(NSInteger)i;
        button.title=[candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : @"Logitech mouse";
        button.connected=[candidate[@"connected"] boolValue];
        NSString *transport=[candidate[@"transport"] isKindOfClass:NSString.class] ? candidate[@"transport"] : @"";
        NSString *kind=[transport rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch].location!=NSNotFound ? @"bluetooth" :
            [transport rangeOfString:@"Unifying" options:NSCaseInsensitiveSearch].location!=NSNotFound ? @"unifying" :
            [transport rangeOfString:@"Bolt" options:NSCaseInsensitiveSearch].location!=NSNotFound ? @"bolt" : nil;
        if(!self.connectionImages) {
            NSMutableDictionary *icons=[NSMutableDictionary new];
            for(NSString *name in @[@"bluetooth",@"unifying",@"bolt"]) {
                NSString *path=[NSBundle.mainBundle pathForResource:[@"connection-" stringByAppendingString:name] ofType:@"pdf"];
                NSImage *icon=path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
                if(icon) icons[name]=icon;
            }
            self.connectionImages=icons;
        }
        button.connectionImage=kind ? self.connectionImages[kind] : nil;
        if(!button.connectionImage) button.connectionImage=[NSImage imageWithSystemSymbolName:@"cable.connector" accessibilityDescription:@"Connection"];
        NSString *connection=[kind isEqualToString:@"unifying"] ? @"Unifying" : [kind isEqualToString:@"bluetooth"] ? @"Bluetooth" : [kind isEqualToString:@"bolt"] ? @"Bolt" : [transport isEqualToString:@"USB"] ? @"USB" : @"Direct";
        BOOL receiver=[kind isEqualToString:@"unifying"] || [kind isEqualToString:@"bolt"];
        button.connectionLabel=!button.connected && receiver ? @"Paired · Offline" : [NSString stringWithFormat:@"%@ · %@",connection,button.connected ? @"Connected" : @"Offline"];
        NSNumber *battery=[candidate[@"batteryPercent"] isKindOfClass:NSNumber.class] ? candidate[@"batteryPercent"] : nil;
        BOOL percentage=button.connected && battery && battery.integerValue>=0 && battery.integerValue<=100;
        BOOL charging=button.connected && [candidate[@"batteryCharging"] boolValue];
        NSString *batteryState=[candidate[@"batteryStatus"] isKindOfClass:NSString.class] ? candidate[@"batteryStatus"] : @"";
        button.batteryText=percentage ? [NSString stringWithFormat:@"%ld%%%@",battery.integerValue,charging ? @" · Charging" : @""] :
            button.connected && batteryState.length ? batteryState : @"Battery unavailable";
        NSString *batterySymbol=charging ? @"battery.100percent.bolt" : !percentage ? @"battery.0percent" :
            battery.integerValue<=10 ? @"battery.0percent" : battery.integerValue<=35 ? @"battery.25percent" :
            battery.integerValue<=65 ? @"battery.50percent" : battery.integerValue<=85 ? @"battery.75percent" : @"battery.100percent";
        NSColor *batteryColor=percentage && battery.integerValue<=10 ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
        button.batteryImage=[[NSImage imageWithSystemSymbolName:batterySymbol accessibilityDescription:@"Battery"]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[batteryColor]]];
        BOOL compact=[button.title rangeOfString:@"M705" options:NSCaseInsensitiveSearch].location!=NSNotFound;
        BOOL master=[button.title rangeOfString:@"Master 3" options:NSCaseInsensitiveSearch].location!=NSNotFound;
        button.image=compact ? self.compactThumbnail : master ? self.masterThumbnail : [NSImage imageWithSystemSymbolName:@"computermouse" accessibilityDescription:@"Mouse"];
        button.state=candidate==device ? NSControlStateValueOn : NSControlStateValueOff;
        button.toolTip=!button.connected && receiver ? [NSString stringWithFormat:@"%@ — saved %@ receiver pairing. No active connection.",button.title,connection] :
            [NSString stringWithFormat:@"%@ — %@",button.title,button.connectionLabel];
        [button setAccessibilityLabel:[NSString stringWithFormat:@"%@, %@, %@",button.title,button.connectionLabel,button.batteryText]];
        button.needsDisplay=YES;
    }
    NSDictionary *active=device ?: status;
    NSString *name=[active[@"name"] isKindOfClass:NSString.class] ? active[@"name"] : active[@"deviceName"];
    if(![name isKindOfClass:NSString.class] || !name.length) name=@"Logitech mouse";
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
    BOOL mappedM705=compact;
    for(NSDictionary *control in editable) {
        NSPoint marker; NSRect frame;
        if(!m705Layout([control[@"cid"] unsignedIntValue],&marker,&frame)) mappedM705=NO;
    }
    if(mappedM705) self.genericMouse=NO;
    self.diagramLines.mappedControls=mappedM705 ? editable : nil;
    // Extra controls need the list, but do not remove artwork for known models.
    BOOL artworkWithList=self.genericMouse && (compact || master3);
    self.mouseView.hidden=!(compact || master3);
    self.diagramLines.hidden=self.genericMouse;
    self.mouseView.frame=artworkWithList ? (compact ? NSMakeRect(0,70,280,300) : NSMakeRect(30,20,220,380)) :
        (mappedM705 ? NSMakeRect(205,10,270,430) : compact ? NSMakeRect(155,50,400,350) : NSMakeRect(205,10,270,430));
    self.controlList.frame=artworkWithList ? NSMakeRect(320,270,360,200) : NSMakeRect(60,270,600,200);
    self.genericHint.frame=NSMakeRect(64,224,360,40);
    if(self.controlTable.tableColumns.count==2) {
        self.controlTable.tableColumns[0].width=artworkWithList ? 175 : 285;
        self.controlTable.tableColumns[1].width=artworkWithList ? 155 : 285;
    }
    self.mouseView.compactMouse=compact; self.mouseView.needsDisplay=YES;
    self.diagramLines.compactMouse=compact;
    NSMutableIndexSet *visible=[NSMutableIndexSet new];
    NSArray<NSValue *> *defaultFrames=@[[NSValue valueWithRect:NSMakeRect(432,340,177,72)], [NSValue valueWithRect:NSMakeRect(270,75,174,72)], [NSValue valueWithRect:NSMakeRect(94,235,176,72)], [NSValue valueWithRect:NSMakeRect(0,145,211,90)], [NSValue valueWithRect:NSMakeRect(452,250,185,90)]];
    for(NSUInteger i=0;i<MX_BUTTON_COUNT;++i) {
        if(i<self.callouts.count) self.callouts[i].frame=defaultFrames[i].rectValue;
        BOOL present=[self controlForSlot:i]!=nil;
        self.callouts[i].hidden=self.genericMouse || !present;
        if(present) [visible addIndex:i];
    }
    if([self hasCapability:@"horizontalScroll"]) [visible addIndex:5];
    for(MXCallout *callout in self.extraCallouts) callout.hidden=YES;
    if(mappedM705) for(NSDictionary *control in editable) {
        NSUInteger slot=[control[@"slot"] unsignedIntegerValue]; NSPoint marker; NSRect frame;
        if(!m705Layout([control[@"cid"] unsignedIntValue],&marker,&frame)) continue;
        MXCallout *callout=slot<MX_BUTTON_COUNT ? (slot<self.callouts.count ? self.callouts[slot] : nil) :
            (slot-MX_BUTTON_COUNT<self.extraCallouts.count ? self.extraCallouts[slot-MX_BUTTON_COUNT] : nil);
        callout.frame=frame; callout.hidden=NO;
    }
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
    [self layoutScrollSection];
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
    for(NSUInteger i=0;i<self.extraCallouts.count;++i) {
        NSUInteger slot=i+MX_BUTTON_COUNT; NSDictionary *control=[self controlForSlot:slot];
        MXCallout *callout=self.extraCallouts[i];
        if(control) {
            NSInteger mode=self.modes[slot].indexOfSelectedItem;
            NSString *action=mode==MX_SHORTCUT ? shortcutLabel(self.recorders[slot].keyCode,self.recorders[slot].shortcutModifiers) : mode==MX_DISABLED ? @"Do nothing" : @"Mouse default";
            callout.title=[NSString stringWithFormat:@"%@\n%@",control[@"name"] ?: @"Mouse control",action];
            callout.accessibilityLabel=[callout.title stringByReplacingOccurrencesOfString:@"\n" withString:@", "];
            callout.selected=(NSInteger)slot==self.selectedButton; callout.needsDisplay=YES;
        }
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
- (void)selectButton:(NSButton *)sender {
    [self cancelRecording]; self.selectedButton=sender.tag; [self updateCallouts];
    if(sender.window && self.shortcutPopover) {
        [self.shortcutPopover close];
        [self.shortcutPopover showRelativeToRect:NSInsetRect(sender.bounds,6,6) ofView:sender preferredEdge:NSMaxYEdge];
    }
}
- (void)editSelectedControl:(NSTableView *)sender {
    NSInteger row=sender.clickedRow;
    if(row<0 || (NSUInteger)row>=self.availableControls.count) return;
    [self cancelRecording]; self.selectedButton=[self.availableControls[(NSUInteger)row][@"slot"] integerValue]; [self updateCallouts];
    [self.shortcutPopover close];
    [self.shortcutPopover showRelativeToRect:[sender rectOfRow:row] ofView:sender preferredEdge:NSMaxXEdge];
}
- (void)showScroll:(NSView *)sender {
    (void)sender; [self cancelRecording]; [self.shortcutPopover close];
    [self.window makeFirstResponder:[self hasCapability:@"wheelMode"] ? self.wheelMode : self.verticalSpeed];
}
- (void)layoutScrollSection {
    if(!self.scrollSection) return;
    BOOL enabled[4]={[self hasCapability:@"wheelMode"],[self hasCapability:@"verticalScroll"],
        [self hasCapability:@"horizontalScroll"],[self hasCapability:@"dpi"]};
    NSUInteger count=0; for(NSUInteger i=0;i<4;++i) if(enabled[i]) ++count;
    self.scrollSection.hidden=count==0;
    CGFloat height=28+count*28+(enabled[1] ? 22 : 0);
    self.scrollSection.frame=NSMakeRect(555,5,250,height);
    self.scrollSectionTitle.frame=NSMakeRect(0,height-22,250,20);
    CGFloat y=height-48;
    const NSUInteger order[]={0,3,1,2};
    for(NSUInteger j=0;j<4;++j) {
        NSUInteger i=order[j];
        self.scrollRowLabels[i].hidden=!enabled[i];
        if(!enabled[i]) continue;
        self.scrollRowLabels[i].frame=NSMakeRect(0,y+3,62,18);
        if(i==0) self.wheelMode.frame=NSMakeRect(64,y-1,186,26);
        else if(i==3) self.dpi.frame=NSMakeRect(64,y-1,186,26);
        else {
            NSSlider *slider=i==1 ? self.verticalSpeed : self.horizontalSpeed;
            NSTextField *value=i==1 ? self.verticalValue : self.horizontalValue;
            NSButton *reverse=i==1 ? self.invertVertical : self.invertHorizontal;
            slider.frame=NSMakeRect(64,y+1,108,22);
            value.frame=NSMakeRect(174,y+2,34,18);
            reverse.frame=NSMakeRect(210,y,40,22);
        }
        y-=28;
    }
    self.smooth.frame=NSMakeRect(64,0,186,22);
}
- (void)startHelperIfReady {
    if(self.autoStartAttempted || self.helperTransition || self.checkingPermissions || [self helperRunning]) return;
    if([NSProcessInfo.processInfo.arguments containsObject:@"--render-preview"]) return;
    NSDictionary *permissions=[self permissionSnapshot];
    if(![permissions[@"inputMonitoring"] boolValue] || ![permissions[@"postEventAccess"] boolValue]) return;
    char conflict[256];
    if(mx_conflicting_process(conflict)) {
        if ([MXLogiControls running]) {
            self.autoStartAttempted=YES;
            [self quitOptions:nil];
        }
        return;
    }
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
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
        // A login helper can survive replacement of its bundle. Its executable
        // path then disappears, but its lifetime lock still identifies a resident.
        int fd=open(supportPath(@"helper.lock").fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
        if(fd<0) return NO;
        BOOL locked=flock(fd, LOCK_EX | LOCK_NB)!=0 && errno==EWOULDBLOCK;
        close(fd);
        return locked;
    }
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
    // Discovery needs the helper running before a mouse profile can be selected.
    if (!self.selectedDeviceID.length || [self save]) [self launchHelper:@[]];
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
        self.quittingOptions=NO; self.autoStartAttempted=error!=nil; [self refresh:nil];
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
