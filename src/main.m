// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Shader lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
#import "PaperGraph.h"
#import <Carbon/Carbon.h>

static const NSWindowCollectionBehavior OverlaySpaceBehavior =
    NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary |
    NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;

static NSArray<NSDictionary *> *AdvancedRows(void) {
    return @[
        @{@"key":@"dark",@"title":@"1. Darkening",@"unavailable":@"Unavailable — no validated native power stage"},
        @{@"key":@"correction",@"title":@"2. GBA color correction",@"help":@"Apply the original fixed RGB correction matrix."},
        @{@"key":@"clamp1",@"title":@"3. Color-range clamp",@"automatic":@YES},
        @{@"key":@"grey",@"title":@"4. Grayscale",@"min":@0,@"max":@1,@"amount":@1,@"neutral":@0},
        @{@"key":@"contrast",@"title":@"5. Contrast",@"min":@.5,@"max":@2,@"amount":@1,@"neutral":@1},
        @{@"key":@"brightness",@"title":@"6. Brightness",@"min":@(-.5),@"max":@.5,@"amount":@0,@"neutral":@0},
        @{@"key":@"black",@"title":@"7. Black level",@"min":@0,@"max":@.3,@"amount":@.05,@"neutral":@0},
        @{@"key":@"tint",@"title":@"8. Warm paper tint",@"min":@0,@"max":@1,@"amount":@0,@"neutral":@0},
        @{@"key":@"clamp2",@"title":@"9. Final color clamp",@"automatic":@YES},
        @{@"key":@"texture",@"title":@"10. Original paper texture",@"min":@0,@"max":@1,@"amount":@1,@"neutral":@0},
        @{@"key":@"overlay",@"title":@"11a. Overlay branch",@"help":@"Unchecked: substitute corrected color for this branch."},
        @{@"key":@"multiply",@"title":@"11b. Luminance multiply",@"help":@"Unchecked: substitute corrected color for this branch."},
        @{@"key":@"mix",@"title":@"12. Final luminance mix",@"help":@"Mix both branches by luminance; turn off to inspect one branch below."}
    ];
}

static void InspectGraph(CALayer *layer, NSMutableSet *groups, NSUInteger *backdrops, NSUInteger *controls, float strength) {
    if ([layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) {
        (*backdrops)++;
        [groups addObject:[layer valueForKey:@"groupName"]];
        NSCAssert([[layer valueForKey:@"scale"] doubleValue] == 1, @"Backdrop was downsampled");
    }
    if ([layer.name isEqualToString:@"texture-strength"] || [layer.name isEqualToString:@"luma-strength"]) {
        (*controls)++;
        NSCAssert(fabsf(layer.opacity - strength) < .0001f, @"Strength control differs");
    }
    for (CALayer *child in layer.sublayers) InspectGraph(child, groups, backdrops, controls, strength);
    if (layer.mask) InspectGraph(layer.mask, groups, backdrops, controls, strength);
}

static BOOL SelfCheck(CGImageRef image) {
    @try {
        NSCAssert(!(OverlaySpaceBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces), @"Backdrop groups must not be cloned across Spaces");
        NSCAssert((OverlaySpaceBehavior & NSWindowCollectionBehaviorMoveToActiveSpace) && (OverlaySpaceBehavior & NSWindowCollectionBehaviorTransient), @"Overlay must follow the active Space without joining transition snapshots");
        for (NSNumber *backingScale in @[@1, @2]) {
            CGRect bounds = CGRectMake(0, 0, 320, 180);
            CGFloat scale = backingScale.doubleValue;
            CALayer *graph = PGCreateGraph(bounds, scale, image, CGSizeMake(4096, 4096), PGColorFilters(NO), NO);
            NSString *group = [graph.sublayers.firstObject valueForKey:@"groupName"];
            for (NSNumber *value in @[@0, @.5, @1]) {
                PGSetStrength(graph, value.floatValue);
                NSMutableSet *groups = [NSMutableSet set];
                NSUInteger backdrops = 0, controls = 0;
                InspectGraph(graph, groups, &backdrops, &controls, value.floatValue);
                NSCAssert(backdrops == 6 && groups.count == 1 && [groups containsObject:group], @"Backdrop source is not shared");
                NSCAssert(controls == 2, @"Missing nonlinear blend strength controls");
            }
            CALayer *paper = PGPaper(image, bounds, scale, CGSizeMake(4096, 4096));
            CGRect pixels = paper.sublayers.firstObject.frame;
            NSCAssert(fabs(CGRectGetMaxY(pixels) - bounds.size.height) < .001, @"Paper is not top-aligned");
            NSCAssert(pixels.size.width == 4096 / scale, @"Paper pixel scale differs");
            CALayer *color = PGCreateGraph(bounds, scale, image, CGSizeMake(4096, 4096), PGColorFilters(NO), YES);
            NSCAssert(color.sublayers.count == 1, @"Color-only mode builds unnecessary blend branches");
            (void)PGCreateGraph(bounds, scale, image, CGSizeMake(4096, 4096), PGColorFilters(YES), NO);
        }
        float presetTone[20], advancedTone[20];
        [[PGColorFilters(NO).lastObject valueForKey:@"inputColorMatrix"] getValue:presetTone size:sizeof(presetTone)];
        [[PGStageFilters(PGDefaultStages()).lastObject valueForKey:@"inputColorMatrix"] getValue:advancedTone size:sizeof(advancedTone)];
        NSCAssert(memcmp(presetTone,advancedTone,sizeof(presetTone))==0, @"Advanced defaults changed the validated preset matrix");
        // Compare the composed affine stages with the shader's sequential operations.
        for (int variant=0; variant<32; variant++) {
            PGStages s = PGDefaultStages();
            s.grey = variant&1 ? .35 : 0; s.contrast = variant&2 ? 1.7 : 1;
            s.brightness = variant&4 ? -.2 : 0; s.black = variant&8 ? .2 : 0; s.tint = variant&16 ? .8 : 0;
            s.correction = NO;
            NSArray *filters = PGStageFilters(s);
            for (int sample=0; sample<33; sample++) {
                double c[3] = {sample/32.0,(32-sample)/32.0,(sample%11)/10.0};
                double grey = .2126*c[0]+.7152*c[1]+.0722*c[2];
                const double warmth[3] = {.95,.93,.88};
                float matrix[20];
                if (variant) [[filters.lastObject valueForKey:@"inputColorMatrix"] getValue:matrix size:sizeof(matrix)];
                for (int row=0; row<3; row++) {
                    double expected = c[row]*(1-s.grey)+grey*s.grey;
                    expected = (expected-.5)*s.contrast+.5+s.brightness;
                    expected = (s.black+(1-s.black)*expected)*(1+(warmth[row]-1)*s.tint);
                    double actual = variant ? matrix[row*5+4]+matrix[row*5]*c[0]+matrix[row*5+1]*c[1]+matrix[row*5+2]*c[2] : c[row];
                    NSCAssert(fabs(actual-expected)<.000001, @"Composed color stages changed shader order");
                }
            }
            PGStages b = PGDefaultStages(); b.texture=variant&1; b.overlay=variant&2; b.multiply=variant&4; b.mix=variant&8; b.inspectMultiply=variant&16;
            CALayer *graph = PGCreateStageGraph(CGRectMake(0,0,64,64),2,image,CGSizeMake(4096,4096),PGStageFilters(b),NO,b,.5);
            NSUInteger sources=0,controls=0; NSMutableSet *groups=NSMutableSet.set;
            InspectGraph(graph,groups,&sources,&controls,b.texture ? .5 : 0);
            NSCAssert(sources==(b.mix ? 6U : 5U) && groups.count==1 && controls==2, @"Advanced graph lost shared sources or texture bypass");
            CALayer *overlay=graph.sublayers[1], *luma=graph.sublayers[2], *multiply=luma.sublayers[1];
            NSCAssert(overlay.hidden==(!b.overlay || (!b.mix && b.inspectMultiply)), @"Overlay isolation differs");
            NSCAssert(luma.hidden==(!b.mix && !b.inspectMultiply) && (luma.mask!=nil)==b.mix, @"Final mix isolation differs");
            NSCAssert(multiply.hidden==!b.multiply, @"Multiply bypass differs");
            NSString *group=[graph.sublayers.firstObject valueForKey:@"groupName"];
            PGUpdateColorFilters(graph,PGColorFilters(YES),NO);
            NSCAssert([[graph.sublayers.firstObject valueForKey:@"groupName"] isEqual:group], @"Color drag rebuilt the backdrop group");
        }
        puts("PASS: 32 affine-stage combinations and 32 texture/branch configurations.");
        puts("PASS: active-Space overlay policy excludes sticky backdrop clones.");
        puts("PASS: shared native-scale backdrops, both strength controls, pixel alignment, and modes at 1x/2x.");
        puts("This checks graph structure, not byte-exact rendering or power consumption.");
        return YES;
    } @catch (NSException *exception) {
        fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String);
        return NO;
    }
}

@interface PaperWindow : NSWindow
@end
@implementation PaperWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface ChartView : NSView
@end
@implementation ChartView
- (void)drawRect:(NSRect)dirty {
    [NSColor.whiteColor setFill]; NSRectFill(self.bounds);
    NSArray *colors = @[NSColor.redColor, NSColor.greenColor, NSColor.blueColor,
                        NSColor.blackColor, [NSColor colorWithWhite:.5 alpha:1], NSColor.whiteColor];
    CGFloat width = self.bounds.size.width / colors.count;
    for (NSUInteger i = 0; i < colors.count; i++) {
        [colors[i] setFill]; NSRectFill(NSMakeRect(i * width, 140, width, 180));
    }
    [@"Original-formula compositor test\nText should remain sharp; paper stays fixed while content moves.\nControl–Option–Command–P toggles the effect."
        drawInRect:NSMakeRect(24, 24, self.bounds.size.width - 48, 100)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:16], NSForegroundColorAttributeName:NSColor.blackColor}];
}
@end

@interface App : NSObject <NSApplicationDelegate>
@property NSStatusItem *status;
@property NSMutableArray<NSWindow *> *windows;
@property NSMutableArray<CALayer *> *graphs;
@property NSImage *texture;
@property BOOL enabled;
@property NSInteger mode; // 0: preset, 1: color, 2: matte, 3: advanced stages
@property NSMutableDictionary<NSString *, NSNumber *> *stageOn;
@property NSMutableDictionary<NSString *, NSNumber *> *stageAmounts;
@property BOOL inspectMultiply;
@property (readonly) PGStages stageOptions;
@property NSPanel *advancedPanel;
@property NSButton *advancedEnable;
@property NSTextField *advancedStatus;
@property NSMutableDictionary<NSString *, NSButton *> *stageSwitches;
@property NSMutableDictionary<NSString *, NSSlider *> *stageSliders;
@property NSMutableDictionary<NSString *, NSTextField *> *stageLabels;
@property NSPopUpButton *branchControl;
@property float strength;
@property NSWindow *chart;
@property NSPanel *controls;
@property NSButton *enableControl;
@property NSSlider *strengthControl;
@property NSTextField *strengthLabel;
@property NSPopUpButton *modeControl;
@property NSMenuItem *toggleItem;
@property EventHotKeyRef hotkey;
@property EventHandlerRef hotkeyHandler;
- (void)toggle:(id)sender;
@end

static OSStatus ToggleHotkey(EventHandlerCallRef next, EventRef event, void *context) {
    [(__bridge App *)context toggle:nil];
    return noErr;
}

@implementation App
- (NSArray<NSString *> *)modes { return @[@"E-Ink — Original Blend", @"Color Only", @"Matte Only — Keep Color", @"Advanced — Stage Explorer"]; }
- (NSMenuItem *)item:(NSString *)title action:(SEL)action tag:(NSInteger)tag menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.tag = tag; [menu addItem:item];
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windows = [NSMutableArray array]; self.graphs = [NSMutableArray array];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"graphStrength": @1, @"graphMode": @0}];
    [self loadAdvanced];
    double strength = [defaults doubleForKey:@"graphStrength"];
    self.strength = isfinite(strength) ? fmin(1, fmax(0, strength)) : 1;
    self.mode = [defaults integerForKey:@"graphMode"];
    if (self.mode < 0 || self.mode >= (NSInteger)self.modes.count) self.mode = 0;
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"--color-only"]) self.mode = 1;
    if ([args containsObject:@"--paper-only"]) self.mode = 2;
    if ([args containsObject:@"--advanced"]) self.mode = 3;
    self.texture = [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"paper" ofType:@"png"]];
    if (!self.texture || self.texture.size.width <= 0 || self.texture.size.height <= 0) {
        [self fail:@"The bundled paper PNG could not be decoded."]; return;
    }
    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.status.button.title = @"Paper: Off";
    self.status.button.toolTip = @"Original-formula paper graph — no recording stream";
    NSMenu *menu = [NSMenu new];
    self.toggleItem = [self item:@"Enable (⌃⌥⌘P)" action:@selector(toggle:) tag:0 menu:menu];
    [self item:@"Controls…" action:@selector(showControls:) tag:0 menu:menu];
    [self item:@"Advanced…" action:@selector(showAdvanced:) tag:0 menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSUInteger index = 0; index < self.modes.count; index++)
        [self item:self.modes[index] action:@selector(selectMode:) tag:index menu:menu];
    [self item:@"Show Test Chart" action:@selector(showChart:) tag:0 menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self item:@"Quit Paper Compositor" action:@selector(quit:) tag:0 menu:menu];
    self.status.menu = menu;
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus handler = InstallApplicationEventHandler(ToggleHotkey, 1, &type, (__bridge void *)self, &_hotkeyHandler);
    OSStatus key = handler == noErr ? RegisterEventHotKey(kVK_ANSI_P, controlKey | optionKey | cmdKey,
        (EventHotKeyID){'Papr', 1}, GetApplicationEventTarget(), 0, &_hotkey) : handler;
    if (key != noErr) NSLog(@"Global shortcut unavailable (%d); use Controls or the Paper menu.", (int)key);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(rebuild:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [self rebuild:nil];
    if ([args containsObject:@"--chart"]) [self showChart:nil];
    if ([args containsObject:@"--enable"]) [self toggle:nil];
    if ([args containsObject:@"--controls"]) [self showControls:nil];
    if ([args containsObject:@"--advanced"]) [self showAdvanced:nil];
    NSLog(@"Ready: %@, strength %.2f, %@. No capture stream; use Control–Option–Command–P.", self.modes[self.mode], self.strength, self.enabled ? @"enabled" : @"disabled");
}
- (void)rebuild:(id)sender {
    @try {
        for (NSWindow *window in self.windows) { [window orderOut:nil]; [window close]; }
        [self.windows removeAllObjects]; [self.graphs removeAllObjects];
        for (NSScreen *screen in NSScreen.screens) {
            PaperWindow *window = [[PaperWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO; window.opaque = NO; window.backgroundColor = NSColor.clearColor;
            window.hasShadow = NO; window.ignoresMouseEvents = YES; window.level = NSStatusWindowLevel + 1;
            window.colorSpace = NSColorSpace.sRGBColorSpace;
            window.animationBehavior = NSWindowAnimationBehaviorNone;
            // Sticky windows clone one backdrop group into multiple Spaces; during
            // a swipe those copies lose their source and render only opaque paper.
            // Host only the current Space, then rebuild when the destination settles.
            window.collectionBehavior = OverlaySpaceBehavior;
            NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, screen.frame.size.width, screen.frame.size.height)];
            view.layer = CALayer.layer; view.wantsLayer = YES; view.layerUsesCoreImageFilters = NO;
            view.layer.masksToBounds = YES; view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
            window.contentView = view;
            [self.windows addObject:window];
        }
        [self rebuildGraphs];
    } @catch (NSException *exception) { [self fail:exception.reason]; }
}
- (void)rebuildGraphs {
    NSString *failure = nil;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    @try {
        CGImageRef image = [self.texture CGImageForProposedRect:NULL context:nil hints:nil];
        [self.graphs removeAllObjects];
        for (NSWindow *window in self.windows) {
            CALayer *graph;
            if (self.mode == 3) {
                PGStages stages = self.stageOptions;
                graph = PGCreateStageGraph(window.contentView.bounds,window.backingScaleFactor,image,
                    CGSizeMake(4096,4096),PGStageFilters(stages),NO,stages,self.strength);
            } else {
                graph = PGCreateGraph(window.contentView.bounds, window.backingScaleFactor, image,
                    CGSizeMake(4096, 4096), PGColorFilters(self.mode == 2), self.mode == 1);
                PGSetStrength(graph, self.strength);
            }
            window.contentView.layer.sublayers = @[graph];
            [self.graphs addObject:graph];
        }
        [self apply];
    } @catch (NSException *exception) { failure = exception.reason ?: exception.name; }
    @finally { [CATransaction commit]; }
    if (failure) [self fail:failure];
}
- (void)apply {
    for (NSWindow *window in self.windows) {
        if (self.enabled) [window orderFrontRegardless]; else [window orderOut:nil];
    }
    self.status.button.title = self.enabled ? @"Paper: On" : @"Paper: Off";
    self.toggleItem.title = self.enabled ? @"Disable (⌃⌥⌘P)" : @"Enable (⌃⌥⌘P)";
    for (NSMenuItem *item in self.status.menu.itemArray)
        if (item.action == @selector(selectMode:)) item.state = item.tag == self.mode ? NSControlStateValueOn : NSControlStateValueOff;
    self.enableControl.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.strengthControl.doubleValue = self.strength;
    self.strengthControl.enabled = self.mode != 1 && (self.mode != 3 || self.stageOptions.texture);
    self.strengthLabel.stringValue = [NSString stringWithFormat:@"Paper strength: %.0f%%", self.strength * 100];
    [self.modeControl selectItemAtIndex:self.mode];
    [self syncAdvanced];
}
- (void)toggle:(id)sender { self.enabled = !self.enabled; [self apply]; }
- (void)selectMode:(id)sender {
    self.mode = [sender isKindOfClass:NSPopUpButton.class] ? [sender indexOfSelectedItem] : [sender tag];
    [NSUserDefaults.standardUserDefaults setInteger:self.mode forKey:@"graphMode"];
    [self rebuildGraphs];
    if (self.mode == 3) [self showAdvanced:nil];
}
- (void)changeStrength:(NSSlider *)sender {
    self.strength = sender.floatValue;
    NSString *failure = nil;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    @try { for (CALayer *graph in self.graphs) PGSetStrength(graph, self.mode == 3 && !self.stageOptions.texture ? 0 : self.strength); }
    @catch (NSException *exception) { failure = exception.reason ?: exception.name; }
    @finally { [CATransaction commit]; }
    if (failure) { [self fail:failure]; return; }
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"graphStrength"];
    [self apply];
}
- (void)loadAdvanced {
    self.stageOn = NSMutableDictionary.dictionary; self.stageAmounts = NSMutableDictionary.dictionary;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"advancedStages"];
    NSDictionary *enabled = [saved[@"enabled"] isKindOfClass:NSDictionary.class] ? saved[@"enabled"] : @{};
    NSDictionary *amounts = [saved[@"amounts"] isKindOfClass:NSDictionary.class] ? saved[@"amounts"] : @{};
    self.inspectMultiply = [saved[@"inspectMultiply"] isKindOfClass:NSNumber.class] && [saved[@"inspectMultiply"] boolValue];
    for (NSDictionary *row in AdvancedRows()) {
        NSString *key = row[@"key"];
        if (row[@"unavailable"] || row[@"automatic"]) continue;
        self.stageOn[key] = [enabled[key] isKindOfClass:NSNumber.class] ? @([enabled[key] boolValue]) : @YES;
        if (row[@"amount"] && ![key isEqual:@"texture"]) {
            double value = [amounts[key] isKindOfClass:NSNumber.class] ? [amounts[key] doubleValue] : [row[@"amount"] doubleValue];
            if (!isfinite(value)) value = [row[@"amount"] doubleValue];
            self.stageAmounts[key] = @(fmin([row[@"max"] doubleValue],fmax([row[@"min"] doubleValue],value)));
        }
    }
}
- (PGStages)stageOptions {
    PGStages s = PGDefaultStages();
    s.correction = [self.stageOn[@"correction"] boolValue];
    s.grey = [self.stageOn[@"grey"] boolValue] ? [self.stageAmounts[@"grey"] doubleValue] : 0;
    s.contrast = [self.stageOn[@"contrast"] boolValue] ? [self.stageAmounts[@"contrast"] doubleValue] : 1;
    s.brightness = [self.stageOn[@"brightness"] boolValue] ? [self.stageAmounts[@"brightness"] doubleValue] : 0;
    s.black = [self.stageOn[@"black"] boolValue] ? [self.stageAmounts[@"black"] doubleValue] : 0;
    s.tint = [self.stageOn[@"tint"] boolValue] ? [self.stageAmounts[@"tint"] doubleValue] : 0;
    s.texture = [self.stageOn[@"texture"] boolValue]; s.overlay = [self.stageOn[@"overlay"] boolValue];
    s.multiply = [self.stageOn[@"multiply"] boolValue]; s.mix = [self.stageOn[@"mix"] boolValue];
    s.inspectMultiply = self.inspectMultiply;
    return s;
}
- (void)saveAdvanced {
    [NSUserDefaults.standardUserDefaults setObject:@{@"enabled":self.stageOn.copy,@"amounts":self.stageAmounts.copy,@"inspectMultiply":@(self.inspectMultiply)} forKey:@"advancedStages"];
}
- (void)syncAdvanced {
    self.advancedEnable.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.advancedStatus.stringValue = self.mode != 3 ? @"Advanced settings are inactive. Editing a row selects Advanced mode." :
        (self.enabled ? @"Live on the desktop · Unchecked stages retain their amounts but are bypassed." : @"Effect is OFF · Enable above or press ⌃⌥⌘P to see changes on your desktop.");
    for (NSDictionary *row in AdvancedRows()) {
        NSString *key = row[@"key"];
        if (!self.stageSwitches[key]) continue;
        BOOL on = [self.stageOn[key] boolValue]; self.stageSwitches[key].state = on ? NSControlStateValueOn : NSControlStateValueOff;
        if (row[@"amount"]) {
            double value = [key isEqual:@"texture"] ? self.strength : [self.stageAmounts[key] doubleValue];
            self.stageSliders[key].doubleValue = value; self.stageSliders[key].enabled = on;
            self.stageLabels[key].stringValue = [NSString stringWithFormat:@"%.2f%@",value,on && fabs(value-[row[@"neutral"] doubleValue])<.000001 ? @" · neutral" : @""];
        }
    }
    [self.branchControl selectItemAtIndex:self.inspectMultiply ? 1 : 0]; self.branchControl.enabled = ![self.stageOn[@"mix"] boolValue];
}
- (void)changeStage:(NSControl *)sender {
    NSString *key = sender.identifier;
    BOOL topology = [@[@"overlay",@"multiply",@"mix",@"inspectMultiply"] containsObject:key];
    if ([key isEqual:@"inspectMultiply"]) self.inspectMultiply = [(NSPopUpButton *)sender indexOfSelectedItem] == 1;
    else if ([sender isKindOfClass:NSButton.class]) self.stageOn[key] = @([(NSButton *)sender state] == NSControlStateValueOn);
    else {
        for (NSDictionary *row in AdvancedRows()) if ([row[@"key"] isEqual:key]) {
            double value = sender.doubleValue;
            if (!isfinite(value)) value = [row[@"amount"] doubleValue];
            value = fmin([row[@"max"] doubleValue],fmax([row[@"min"] doubleValue],value));
            if ([key isEqual:@"texture"]) self.strength = value; else self.stageAmounts[key] = @(value);
        }
    }
    if (self.mode != 3) { self.mode = 3; topology = YES; }
    [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"graphMode"];
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"graphStrength"]; [self saveAdvanced];
    if (topology) { [self rebuildGraphs]; return; }
    NSString *failure = nil;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    @try {
        PGStages stages = self.stageOptions; NSArray *filters = PGStageFilters(stages);
        for (CALayer *graph in self.graphs) { PGUpdateColorFilters(graph,filters,NO); PGSetStrength(graph,stages.texture ? self.strength : 0); }
    } @catch (NSException *exception) { failure = exception.reason ?: exception.name; }
    @finally { [CATransaction commit]; }
    if (failure) { [self fail:failure]; return; }
    [self apply];
}
- (void)resetStages:(NSButton *)sender {
    BOOL preset = sender.tag == 1;
    for (NSDictionary *row in AdvancedRows()) {
        if (row[@"unavailable"] || row[@"automatic"]) continue;
        self.stageOn[row[@"key"]] = @(preset);
        if (preset && row[@"amount"] && ![row[@"key"] isEqual:@"texture"]) self.stageAmounts[row[@"key"]] = row[@"amount"];
    }
    if (preset) self.strength = 1;
    self.inspectMultiply = NO; self.mode = 3;
    [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"graphMode"];
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"graphStrength"]; [self saveAdvanced]; [self rebuildGraphs];
}
- (void)showAdvanced:(id)sender {
    BOOL changedMode = self.mode != 3; self.mode = 3;
    [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"graphMode"];
    if (changedMode) [self rebuildGraphs];
    if (!self.advancedPanel) {
        CGFloat height = fmin(740,fmax(360,NSScreen.mainScreen.visibleFrame.size.height-48));
        self.advancedPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,680,height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.advancedPanel.title = @"Advanced — Shader Stage Explorer"; self.advancedPanel.releasedWhenClosed = NO;
        self.advancedPanel.hidesOnDeactivate = NO; self.advancedPanel.level = NSStatusWindowLevel+2;
        self.advancedPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.advancedPanel.contentView.bounds];
        scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES;
        scroll.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable; scroll.drawsBackground = NO;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,740)];
        scroll.documentView = view; [self.advancedPanel.contentView addSubview:scroll];
        self.advancedEnable = [NSButton checkboxWithTitle:@"Enable desktop effect (⌃⌥⌘P)" target:self action:@selector(toggle:)];
        self.advancedEnable.frame = NSMakeRect(20,702,640,26); [view addSubview:self.advancedEnable];
        self.advancedStatus = [NSTextField labelWithString:@""]; self.advancedStatus.frame = NSMakeRect(20,671,640,24);
        self.advancedStatus.font = [NSFont systemFontOfSize:12]; self.advancedStatus.textColor = NSColor.secondaryLabelColor; [view addSubview:self.advancedStatus];
        self.stageSwitches = NSMutableDictionary.dictionary; self.stageSliders = NSMutableDictionary.dictionary; self.stageLabels = NSMutableDictionary.dictionary;
        CGFloat y = 634;
        for (NSDictionary *row in AdvancedRows()) {
            NSString *key = row[@"key"];
            NSButton *check = [NSButton checkboxWithTitle:row[@"title"] target:self action:@selector(changeStage:)];
            check.identifier = key; check.frame = NSMakeRect(20,y,300,26); check.toolTip = row[@"help"] ?: @"Change the amount, or uncheck to bypass this stage without losing its value.";
            [view addSubview:check];
            if (row[@"unavailable"] || row[@"automatic"]) {
                check.enabled = NO; check.state = row[@"automatic"] ? NSControlStateValueOn : NSControlStateValueOff;
                NSTextField *info = [NSTextField labelWithString:row[@"unavailable"] ?: @"Compositor-managed — not a shader-exact clamp"];
                info.frame = NSMakeRect(328,y,335,24); info.font = [NSFont systemFontOfSize:11]; info.textColor = NSColor.secondaryLabelColor;
                info.toolTip = @"The compositor cannot independently reproduce this shader operation; this row is informational, not a fake toggle."; [view addSubview:info];
            } else {
                self.stageSwitches[key] = check;
                if (row[@"amount"]) {
                    NSSlider *slider = [NSSlider sliderWithValue:[row[@"amount"] doubleValue] minValue:[row[@"min"] doubleValue] maxValue:[row[@"max"] doubleValue] target:self action:@selector(changeStage:)];
                    slider.identifier = key; slider.continuous = YES; slider.frame = NSMakeRect(328,y,215,26);
                    slider.accessibilityLabel = [row[@"title"] stringByAppendingString:@" amount"]; [view addSubview:slider]; self.stageSliders[key] = slider;
                    NSTextField *value = [NSTextField labelWithString:@""]; value.frame = NSMakeRect(550,y,110,24);
                    value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; value.alignment = NSTextAlignmentRight;
                    [view addSubview:value]; self.stageLabels[key] = value;
                }
            }
            y -= 34;
        }
        NSTextField *inspect = [NSTextField labelWithString:@"When final mix is off, inspect:"]; inspect.frame = NSMakeRect(20,177,300,26); [view addSubview:inspect];
        self.branchControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(328,177,332,28) pullsDown:NO];
        [self.branchControl addItemsWithTitles:@[@"Overlay branch",@"Luminance multiply branch"]];
        self.branchControl.identifier = @"inspectMultiply"; self.branchControl.target = self; self.branchControl.action = @selector(changeStage:);
        self.branchControl.accessibilityLabel = @"Isolated blend branch"; [view addSubview:self.branchControl];
        NSTextField *branches = [NSTextField wrappingLabelWithString:@"The two blend branches run in parallel. An unchecked branch supplies corrected color; the final mix weights them by luminance."];
        branches.frame = NSMakeRect(20,126,640,42); branches.font = [NSFont systemFontOfSize:12]; branches.textColor = NSColor.secondaryLabelColor; [view addSubview:branches];
        for (NSArray *item in @[@[@"Preset defaults",@1,@20],@[@"Bypass all stages",@0,@180]]) {
            NSButton *button = [NSButton buttonWithTitle:item[0] target:self action:@selector(resetStages:)];
            button.tag = [item[1] integerValue]; button.frame = NSMakeRect([item[2] doubleValue],85,150,30); [view addSubview:button];
        }
        NSButton *chart = [NSButton buttonWithTitle:@"Show test chart" target:self action:@selector(showChart:)]; chart.frame = NSMakeRect(510,85,150,30); [view addSubview:chart];
        NSTextField *note = [NSTextField wrappingLabelWithString:@"Experimental compositor explorer—not literal shader execution. Neutral amounts do not change the image. Color/clamp precision can differ (especially with grayscale off). Darkening and clamp bypass are unavailable. No recording stream."];
        note.frame = NSMakeRect(20,12,640,60); note.font = [NSFont systemFontOfSize:11]; note.textColor = NSColor.secondaryLabelColor; [view addSubview:note];
        [view scrollPoint:NSMakePoint(0,740-height)];
        [self.advancedPanel center];
    }
    [self apply]; [self.advancedPanel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self.advancedPanel orderFrontRegardless];
}
- (void)showControls:(id)sender {
    if (!self.controls) {
        self.controls = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,420,250) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.controls.releasedWhenClosed = NO; self.controls.title = @"Paper Compositor";
        self.controls.hidesOnDeactivate = NO;
        self.controls.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.controls.level = NSStatusWindowLevel + 2;
        NSView *view = self.controls.contentView;
        self.enableControl = [NSButton checkboxWithTitle:@"Enable paper effect (⌃⌥⌘P)" target:self action:@selector(toggle:)];
        self.enableControl.frame = NSMakeRect(20,207,380,24); [view addSubview:self.enableControl];
        self.modeControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,164,265,28) pullsDown:NO];
        [self.modeControl addItemsWithTitles:self.modes]; self.modeControl.target = self; self.modeControl.action = @selector(selectMode:);
        self.modeControl.accessibilityLabel = @"Effect mode"; [view addSubview:self.modeControl];
        NSButton *advanced = [NSButton buttonWithTitle:@"Advanced…" target:self action:@selector(showAdvanced:)];
        advanced.frame = NSMakeRect(290,164,110,28); [view addSubview:advanced];
        self.strengthLabel = [NSTextField labelWithString:@""];
        self.strengthLabel.frame = NSMakeRect(20,130,380,20); [view addSubview:self.strengthLabel];
        self.strengthControl = [NSSlider sliderWithValue:self.strength minValue:0 maxValue:1 target:self action:@selector(changeStrength:)];
        self.strengthControl.frame = NSMakeRect(20,96,380,26); self.strengthControl.continuous = YES;
        self.strengthControl.accessibilityLabel = @"Paper texture strength"; [view addSubview:self.strengthControl];
        NSTextField *note = [NSTextField wrappingLabelWithString:@"Original texture and nonlinear blend formula.\nPrivate compositor APIs; not a byte-exact shader replacement.\nNo screen-recording stream. Power savings are not measured."];
        note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize]; note.textColor = NSColor.secondaryLabelColor;
        note.frame = NSMakeRect(20,15,380,65); [view addSubview:note];
        [self.controls center];
    }
    [self apply]; [self.controls makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self.controls orderFrontRegardless];
}
- (void)showChart:(id)sender {
    if (!self.chart) {
        self.chart = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 840, 360) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.chart.releasedWhenClosed = NO; self.chart.title = @"Paper Compositor Test Chart";
        self.chart.contentView = [[ChartView alloc] initWithFrame:NSMakeRect(0, 0, 840, 360)];
        [self.chart center];
    }
    [self.chart makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)fail:(NSString *)reason {
    for (NSWindow *window in self.windows) [window orderOut:nil];
    NSLog(@"Compositor failed: %@", reason);
    NSAlert *alert = NSAlert.new; alert.messageText = @"Paper compositor unavailable"; alert.informativeText = reason ?: @"Unknown private API failure.";
    [alert runModal]; [NSApp terminate:nil];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    if (self.mode == 3) [self showAdvanced:nil]; else [self showControls:nil]; return NO;
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    for (NSWindow *window in self.windows) [window orderOut:nil];
    if (self.hotkey) UnregisterEventHotKey(self.hotkey);
    if (self.hotkeyHandler) RemoveEventHandler(self.hotkeyHandler);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSSet *allowed = [NSSet setWithArray:@[@"--self-check", @"--enable", @"--controls", @"--chart", @"--color-only", @"--paper-only", @"--advanced"]];
        for (NSString *arg in [args subarrayWithRange:NSMakeRange(1,args.count-1)]) {
            if (![allowed containsObject:arg]) { fprintf(stderr,"Unknown option: %s\n",arg.UTF8String); return 2; }
        }
        if ((int)[args containsObject:@"--color-only"] + (int)[args containsObject:@"--paper-only"] + (int)[args containsObject:@"--advanced"] > 1) {
            fputs("Choose only one effect mode.\n",stderr); return 2;
        }
        if ([args containsObject:@"--self-check"]) {
            NSImage *texture = [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"paper" ofType:@"png"]];
            return SelfCheck([texture CGImageForProposedRect:NULL context:nil hints:nil]) ? 0 : 1;
        }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        App *delegate = App.new;
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
