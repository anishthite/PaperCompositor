// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Source lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
#import "ReadingGraph.h"
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

static float StoredStrength(id value, float fallback) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return fallback;
    return fmin(1,fmax(0,[value doubleValue]));
}

static void SeedLookProfiles(NSUserDefaults *defaults) {
    id raw=[defaults objectForKey:@"readingStages"];
    NSDictionary *legacy=[raw isKindOfClass:NSDictionary.class] ? raw : @{};
    float strength=StoredStrength([defaults objectForKey:@"graphStrength"],1);
    for (NSString *key in @[@"softReadingStages",@"surfaceReadingStages"]) {
        if ([[defaults objectForKey:key] isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *seed=legacy.mutableCopy;
        seed[@"strength"]=@(strength); seed[@"softTone"]=@([key isEqual:@"softReadingStages"]);
        [defaults setObject:seed forKey:key];
    }
    if (![[defaults objectForKey:@"originalStrength"] isKindOfClass:NSNumber.class])
        [defaults setFloat:strength forKey:@"originalStrength"];
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
        NSString *suite=[@"local.screenslanger.look-check." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *test=[[NSUserDefaults alloc] initWithSuiteName:suite];
        @try {
            [test setObject:@{@"enabled":@{@"fibers":@NO},@"amounts":@{@"tone":@.4},@"softTone":@YES} forKey:@"readingStages"];
            [test setFloat:.65 forKey:@"graphStrength"]; SeedLookProfiles(test);
            NSMutableDictionary *soft=[[test dictionaryForKey:@"softReadingStages"] mutableCopy];
            NSDictionary *source=[test dictionaryForKey:@"surfaceReadingStages"];
            NSCAssert([soft[@"softTone"] boolValue] && ![source[@"softTone"] boolValue], @"Profile migration lost tone identity");
            NSCAssert([soft[@"amounts"] isEqual:source[@"amounts"]] && ![source[@"enabled"][@"fibers"] boolValue], @"Profile migration lost existing tuning");
            NSMutableDictionary *amounts=[soft[@"amounts"] mutableCopy]; amounts[@"tone"]=@.2; soft[@"amounts"]=amounts; soft[@"strength"]=@.25;
            [test setObject:soft forKey:@"softReadingStages"]; SeedLookProfiles(test);
            NSCAssert(fabs([[test dictionaryForKey:@"surfaceReadingStages"][@"amounts"][@"tone"] doubleValue]-.4)<.00001, @"Soft tuning leaked into Surface Dots");
            NSCAssert(fabs([[test dictionaryForKey:@"softReadingStages"][@"strength"] doubleValue]-.25)<.00001 && fabs([test floatForKey:@"originalStrength"]-.65)<.00001, @"Look strengths are not independent or migration overwrote tuning");
            NSCAssert([[test dictionaryForKey:@"readingStages"][@"softTone"] boolValue], @"Migration changed the active legacy selection");
            NSCAssert(StoredStrength(@(NAN),.5)==.5 && StoredStrength(@"invalid",.5)==.5 && StoredStrength(@2,.5)==1 && StoredStrength(@(-1),.5)==0, @"Stored look strength must be finite and bounded");
        } @finally { [test removePersistentDomainForName:suite]; }
        puts("PASS: one-time look migration, independent tuning/strength and invalid preference guards.");
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
        // Full grayscale must discard source chroma before the optional paper palette.
        for (NSNumber *tone in @[@0,@.5,@1]) {
            NSDictionary *settings = @{@"grey":@1,@"tone":tone,@"palette":@1};
            NSArray *filters = RGColorFilters(settings,YES);
            NSCAssert(filters.count==(tone.doubleValue>0 ? 3U : 2U), @"Keep grayscale, tone lookup and palette in source order");
            float matrix[20]; [[filters.firstObject valueForKey:@"inputColorMatrix"] getValue:matrix size:sizeof(matrix)];
            const double weights[3]={.299,.587,.114};
            for (int row=0;row<3;row++) for (int col=0;col<3;col++) {
                NSCAssert(fabs(matrix[row*5+col]-weights[col])<.000001, @"BT.601 grayscale weights changed or source chroma leaked");
                NSCAssert(matrix[row*5+col]==matrix[col], @"Grayscale RGB output rows must be identical");
            }
            NSCAssert(matrix[4]==matrix[9] && matrix[9]==matrix[14], @"Tone offsets must remain neutral before paper tint");
        }
        NSCAssert(RGToneMap()==RGToneMap() && CGImageGetWidth(RGToneMap())==1024, @"Cache the tone lookup once");
        const double anchors[5]={0,.046519955590136254,.4244152825944146,.8411514005140351,1};
        for (int i=0;i<5;i++) NSCAssert(fabs(RGTone(i/4.0)-anchors[i])<1e-12, @"Source gamma/S-curve/midboost changed");
        for (int i=1;i<=4096;i++) NSCAssert(RGTone(i/4096.0)>=RGTone((i-1)/4096.0), @"Tone lookup must be monotonic");
        NSCAssert(RGColorFilters(@{@"grey":@.5,@"tone":@1,@"palette":@0},NO).count==1, @"Partial-grayscale exploration must not be silently desaturated by luminanceMap");
        for (NSNumber *amount in @[@0,@.5,@1]) {
            NSArray *soft=RGColorFilters(@{@"grey":@1,@"tone":amount,@"palette":@0,@"softTone":@YES},NO);
            NSCAssert(soft.count==1, @"Soft tone must reuse the original affine path");
            float matrix[20]; [[soft.firstObject valueForKey:@"inputColorMatrix"] getValue:matrix size:sizeof(matrix)];
            const double luma[3]={.299,.587,.114};
            for (int row=0;row<3;row++) {
                for (int col=0;col<3;col++) NSCAssert(fabs(matrix[row*5+col]-(1+.18*amount.doubleValue)*luma[col])<.000001, @"Soft tone changed original contrast");
                NSCAssert(fabs(matrix[row*5+4]+.09*amount.doubleValue)<.000001, @"Soft tone changed original offset");
            }
        }
        NSArray *readingRows = ReadingRows();
        NSCAssert(RGAmount(@{@"grain":@(-1)},@"grain")==0 && RGAmount(@{@"grain":@2},@"grain")==1 &&
                  RGAmount(@{@"grain":@(NAN)},@"grain")==1 && RGAmount(@{@"grain":@"invalid"},@"grain")==1, @"Reading amounts must be finite and bounded");
        for (NSInteger kind=0;kind<3;kind++) {
            NSCAssert(RGTile(kind)==RGTile(kind) && CGImageGetWidth(RGTile(kind))==256, @"Reading tiles must be cached");
            double mean=0; unsigned low=255,high=0;
            for (uint32_t y=0;y<256;y++) for (uint32_t x=0;x<256;x++) {
                uint8_t byte = RGTileByte(kind,x,y); mean+=byte; low=MIN(low,byte); high=MAX(high,byte);
                NSCAssert(byte==RGTileByte(kind,x,y), @"Grain changed between calls");
                if (kind==2) NSCAssert(byte==RGTileByte(kind,x+4,y+4), @"Bayer period differs");
                if (kind==1) NSCAssert(byte==RGTileByte(kind,x-x%8,y-y%2), @"Fibers lost anisotropy");
            }
            NSCAssert(low<high && low>=246 && high<=255 && mean/65536>250 && mean/65536<254, @"Static grain range or bias differs");
        }
        for (int variant=0;variant<256;variant++) {
            NSMutableDictionary *settings = NSMutableDictionary.dictionary;
            for (NSUInteger i=0;i<readingRows.count;i++) settings[readingRows[i][@"key"]] = @((variant>>i)&1);
            for (NSNumber *scale in @[@1,@2]) {
                CALayer *graph = RGCreateGraph(CGRectMake(0,0,320,180),scale.doubleValue,settings,.5);
                NSUInteger sources=0,controls=0; NSMutableSet *groups=NSMutableSet.set;
                InspectGraph(graph,groups,&sources,&controls,0);
                NSUInteger textures = ((variant>>2)&1)+((variant>>3)&1)+((variant>>4)&1);
                NSCAssert(groups.count==1 && sources==1+((variant&32) ? textures : 0), @"Reading masks must share the backdrop group");
                NSCAssert(graph.sublayers.count==2+textures, @"Disabled reading textures must not allocate branches");
                for (CALayer *layer in graph.sublayers) {
                    if (![layer isKindOfClass:CAReplicatorLayer.class]) continue;
                    CAReplicatorLayer *rows=(id)layer, *columns=(id)rows.sublayers.firstObject;
                    NSCAssert(rows.instanceCount*256/scale.doubleValue>=180 && columns.instanceCount*256/scale.doubleValue>=320, @"Reading tiling does not cover the display");
                    NSCAssert(columns.sublayers.firstObject.frame.size.width==256/scale.doubleValue && fabs(layer.opacity-.5)<.00001, @"Reading native scale or strength differs");
                }
                CALayer *source=graph.sublayers.firstObject;
                float matrix[20]; [[source.filters.lastObject valueForKey:@"inputColorMatrix"] getValue:matrix size:sizeof(matrix)];
                if (variant==0) for (int row=0;row<4;row++) for (int col=0;col<5;col++)
                    NSCAssert(matrix[row*5+col]==(row==col ? 1 : 0), @"All-stage bypass is not identity");
                if (variant==64) for (int row=0;row<3;row++) {
                    const float ink[3]={.10,.10,.12},paper[3]={.94,.92,.86};
                    NSCAssert(fabs(matrix[row*5+4]-ink[row])<.000001 && fabs(matrix[row*5+row]+matrix[row*5+4]-paper[row])<.000001, @"Palette endpoints differ");
                }
                RGSetStrength(graph,settings,0);
                for (CALayer *layer in graph.sublayers) if ([layer isKindOfClass:CAReplicatorLayer.class]) NSCAssert(layer.opacity==0, @"Reading strength zero did not bypass texture");
            }
        }
        puts("PASS: Reading tiles, palette, identity bypass and 256 stage combinations at 1x/2x.");
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
@property NSInteger mode; // 0: Original Paper, 1/2: legacy color/matte, 3: legacy Original alias, 4: Reading
@property NSMutableDictionary<NSString *, NSNumber *> *readingAmounts;
@property NSMutableDictionary<NSString *, NSNumber *> *readingOn;
@property NSPanel *readingPanel;
@property NSPopUpButton *readingModeControl;
@property BOOL softReadingTone;
@property (readonly) NSInteger selectedLook;
@property NSButton *readingEnable;
@property NSTextField *readingStatus;
@property NSMutableDictionary<NSString *, NSButton *> *readingSwitches;
@property NSMutableDictionary<NSString *, NSSlider *> *readingSliders;
@property NSMutableDictionary<NSString *, NSTextField *> *readingLabels;
@property (readonly) NSDictionary *readingSettings;
@property NSMutableDictionary<NSString *, NSNumber *> *stageOn;
@property NSMutableDictionary<NSString *, NSNumber *> *stageAmounts;
@property BOOL inspectMultiply;
@property (readonly) PGStages stageOptions;
@property NSPanel *advancedPanel;
@property NSPopUpButton *advancedModeControl;
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
- (NSArray<NSString *> *)modes { return @[@"Original Paper", @"Color Only", @"Matte Only — Keep Color", @"Original Paper", @"Reading"]; }
- (NSArray<NSString *> *)looks { return @[@"Original Paper",@"Soft Reading",@"Surface Dots"]; }
- (NSInteger)selectedLook { return self.mode==4 ? (self.softReadingTone ? 1 : 2) : (self.mode==0 || self.mode==3 ? 0 : -1); }
- (NSMenuItem *)item:(NSString *)title action:(SEL)action tag:(NSInteger)tag menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.tag = tag; [menu addItem:item];
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windows = [NSMutableArray array]; self.graphs = [NSMutableArray array];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"graphStrength": @1, @"graphMode": @0}];
    SeedLookProfiles(defaults);
    [self loadAdvanced];
    NSDictionary *legacy=[defaults dictionaryForKey:@"readingStages"];
    self.softReadingTone=[legacy[@"softTone"] isKindOfClass:NSNumber.class] && [legacy[@"softTone"] boolValue];
    self.mode = [defaults integerForKey:@"graphMode"];
    if (self.mode < 0 || self.mode >= (NSInteger)self.modes.count) self.mode = 0;
    NSArray *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"--color-only"]) self.mode = 1;
    if ([args containsObject:@"--paper-only"]) self.mode = 2;
    if ([args containsObject:@"--advanced"]) self.mode = 3;
    if ([args containsObject:@"--reading"]) self.mode = 4;
    if (self.mode==3) self.mode=0; // The former Advanced mode is now Original Paper's breakdown.
    [self loadReading];
    if (self.mode!=4) self.strength=StoredStrength([defaults objectForKey:self.mode==0 ? @"originalStrength" : @"graphStrength"],1);
    self.texture = [[NSImage alloc] initWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"paper" ofType:@"png"]];
    if (!self.texture || self.texture.size.width <= 0 || self.texture.size.height <= 0) {
        [self fail:@"The bundled paper PNG could not be decoded."]; return;
    }
    self.status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.status.button.title = @"Paper: Off";
    self.status.button.toolTip = @"Paper and Reading Mode — no recording stream";
    NSMenu *menu = [NSMenu new];
    self.toggleItem = [self item:@"Enable (⌃⌥⌘P)" action:@selector(toggle:) tag:0 menu:menu];
    [self item:@"Controls…" action:@selector(showControls:) tag:0 menu:menu];
    [self item:@"Breakdown & Tune…" action:@selector(showBreakdown:) tag:0 menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSUInteger index=0;index<self.looks.count;index++)
        [self item:self.looks[index] action:@selector(selectLook:) tag:index menu:menu];
    NSMenuItem *other=[self item:@"Other modes" action:NULL tag:0 menu:menu];
    other.submenu=[NSMenu new];
    for (NSInteger index=1;index<=2;index++) [self item:self.modes[index] action:@selector(selectMode:) tag:index menu:other.submenu];
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
    if ([args containsObject:@"--reading"]) [self showReading:nil];
    NSLog(@"Ready: %@, strength %.2f, %@. No capture stream; use Control–Option–Command–P.", self.selectedLook>=0 ? self.looks[self.selectedLook] : self.modes[self.mode], self.strength, self.enabled ? @"enabled" : @"disabled");
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
            if (self.mode == 4) {
                graph = RGCreateGraph(window.contentView.bounds,window.backingScaleFactor,self.readingSettings,self.strength);
            } else if (self.mode == 0 || self.mode == 3) {
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
    for (NSMenuItem *item in self.status.menu.itemArray) {
        if (item.action==@selector(selectLook:)) item.state=item.tag==self.selectedLook ? NSControlStateValueOn : NSControlStateValueOff;
        for (NSMenuItem *legacy in item.submenu.itemArray)
            if (legacy.action==@selector(selectMode:)) legacy.state=legacy.tag==self.mode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.enableControl.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.strengthControl.doubleValue = self.strength;
    self.strengthControl.enabled = self.mode != 1 && ((self.mode != 0 && self.mode != 3) || self.stageOptions.texture);
    self.strengthLabel.stringValue = [NSString stringWithFormat:@"%@: %.0f%%", self.mode == 4 ? @"Grain / Bayer strength" : @"Paper strength", self.strength * 100];
    [self.modeControl selectItemAtIndex:self.selectedLook];
    [self.readingModeControl selectItemAtIndex:self.selectedLook];
    [self.advancedModeControl selectItemAtIndex:self.selectedLook];
    [self syncAdvanced];
    [self syncReading];
}
- (void)toggle:(id)sender { self.enabled = !self.enabled; [self apply]; }
- (void)saveCurrentLook {
    if (self.mode==4) [self saveReading]; else if (self.mode==0 || self.mode==3) [self saveAdvanced];
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"graphStrength"];
}
- (void)activateLook:(NSInteger)look {
    if (look<0 || look>2) return;
    [self saveCurrentLook];
    self.mode=look==0 ? 0 : 4;
    if (look==0) self.strength=StoredStrength([NSUserDefaults.standardUserDefaults objectForKey:@"originalStrength"],1);
    else { self.softReadingTone=look==1; [self loadReading]; }
    [NSUserDefaults.standardUserDefaults setInteger:self.mode forKey:@"graphMode"];
    [self saveCurrentLook]; [self rebuildGraphs];
}
- (void)selectLook:(id)sender {
    [self activateLook:[sender isKindOfClass:NSPopUpButton.class] ? [sender indexOfSelectedItem] : [sender tag]];
    [self showBreakdown:nil];
}
- (void)showBreakdown:(id)sender {
    if (self.mode==0 || self.mode==3) [self showAdvanced:nil];
    else if (self.mode==4) [self showReading:nil];
    else [self showControls:nil];
}
- (void)selectMode:(NSMenuItem *)sender {
    [self saveCurrentLook]; self.mode=sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.mode forKey:@"graphMode"];
    [self.readingPanel orderOut:nil]; [self.advancedPanel orderOut:nil];
    [self rebuildGraphs]; [self showControls:nil];
}
- (void)changeStrength:(NSSlider *)sender {
    self.strength = sender.floatValue;
    NSString *failure = nil;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    @try { for (CALayer *graph in self.graphs) {
        if (self.mode == 4) RGSetStrength(graph,self.readingSettings,self.strength);
        else PGSetStrength(graph, (self.mode == 0 || self.mode == 3) && !self.stageOptions.texture ? 0 : self.strength);
    } }
    @catch (NSException *exception) { failure = exception.reason ?: exception.name; }
    @finally { [CATransaction commit]; }
    if (failure) { [self fail:failure]; return; }
    [self saveCurrentLook];
    [self apply];
}
- (void)loadReading {
    self.readingOn = NSMutableDictionary.dictionary; self.readingAmounts = NSMutableDictionary.dictionary;
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:self.softReadingTone ? @"softReadingStages" : @"surfaceReadingStages"];
    NSDictionary *saved = [stored isKindOfClass:NSDictionary.class] ? stored : @{};
    NSDictionary *enabled = [saved[@"enabled"] isKindOfClass:NSDictionary.class] ? saved[@"enabled"] : @{};
    NSDictionary *amounts = [saved[@"amounts"] isKindOfClass:NSDictionary.class] ? saved[@"amounts"] : @{};
    self.strength=StoredStrength(saved[@"strength"],1);
    for (NSDictionary *row in ReadingRows()) {
        NSString *key = row[@"key"];
        self.readingOn[key] = [enabled[key] isKindOfClass:NSNumber.class] ? @([enabled[key] boolValue]) : @YES;
        self.readingAmounts[key] = @(RGAmount(amounts,key));
    }
}
- (NSDictionary *)readingSettings {
    NSMutableDictionary *settings = NSMutableDictionary.dictionary;
    for (NSDictionary *row in ReadingRows()) {
        NSString *key = row[@"key"];
        settings[key] = [self.readingOn[key] boolValue] ? self.readingAmounts[key] : @0;
    }
    settings[@"softTone"]=@(self.softReadingTone);
    return settings;
}
- (void)saveReading {
    NSDictionary *profile=@{@"enabled":self.readingOn.copy,@"amounts":self.readingAmounts.copy,@"softTone":@(self.softReadingTone),@"strength":@(self.strength)};
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setObject:profile forKey:self.softReadingTone ? @"softReadingStages" : @"surfaceReadingStages"];
    [defaults setObject:profile forKey:@"readingStages"]; // Keep the active profile readable by older builds.
    [defaults setFloat:self.strength forKey:@"graphStrength"];
    [defaults setInteger:4 forKey:@"graphMode"];
}
- (void)syncReading {
    self.readingEnable.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.readingPanel.title=[NSString stringWithFormat:@"%@ — Stage Breakdown",self.softReadingTone ? @"Soft Reading" : @"Surface Dots"];
    self.readingSwitches[@"tone"].title=self.softReadingTone ? @"2. Soft / Original Tone" : @"2. Surface Dots tone curve";
    self.readingStatus.stringValue = self.mode != 4 ? @"Reading settings inactive · Editing a row selects Reading Mode." :
        (self.enabled ? @"Live on desktop · Native approximation, not shader-exact." : @"Effect is OFF · Enable above or press ⌃⌥⌘P to preview.");
    if (self.mode==4 && RGAmount(self.readingSettings,@"grey")<1)
        self.readingStatus.stringValue = [NSString stringWithFormat:@"%@ · Color retained: enable Grayscale at 100%% for the Surface Dots look.",self.enabled ? @"Live" : @"Effect OFF"];
    for (NSDictionary *row in ReadingRows()) {
        NSString *key = row[@"key"]; BOOL on = [self.readingOn[key] boolValue];
        self.readingSwitches[key].state = on ? NSControlStateValueOn : NSControlStateValueOff;
        self.readingSliders[key].doubleValue = [self.readingAmounts[key] doubleValue]; self.readingSliders[key].enabled = on;
        self.readingLabels[key].stringValue = [NSString stringWithFormat:@"%.0f%%",100*[self.readingAmounts[key] doubleValue]];
    }
}
- (void)changeReading:(NSControl *)sender {
    if (self.mode!=4) [self activateLook:self.softReadingTone ? 1 : 2];
    NSString *key = sender.identifier;
    if ([sender isKindOfClass:NSButton.class]) self.readingOn[key] = @([(NSButton *)sender state] == NSControlStateValueOn);
    else self.readingAmounts[key] = @(RGAmount(@{key:@(sender.doubleValue)},key));
    self.mode = 4; [self saveReading]; [self rebuildGraphs];
}
- (void)resetReading:(NSButton *)sender {
    if (self.mode!=4) [self activateLook:self.softReadingTone ? 1 : 2];
    for (NSDictionary *row in ReadingRows()) {
        NSString *key = row[@"key"]; self.readingOn[key] = @(sender.tag==1);
        if (sender.tag==1) self.readingAmounts[key] = @1;
    }
    if (sender.tag==1) self.strength=1;
    self.mode = 4; [self saveReading]; [self rebuildGraphs];
}
- (void)showReading:(id)sender {
    if (self.mode!=4) [self activateLook:self.softReadingTone ? 1 : 2];
    [self.advancedPanel orderOut:nil];
    if (!self.readingPanel) {
        CGFloat height = fmin(680,fmax(360,NSScreen.mainScreen.visibleFrame.size.height-48));
        self.readingPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,680,height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.readingPanel.title = @"Reading Mode — Stage Breakdown"; self.readingPanel.releasedWhenClosed = NO;
        self.readingPanel.hidesOnDeactivate = NO; self.readingPanel.level = NSStatusWindowLevel+2;
        self.readingPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.readingPanel.contentView.bounds];
        scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.drawsBackground = NO;
        scroll.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,680)]; scroll.documentView = view;
        [self.readingPanel.contentView addSubview:scroll];
        self.readingEnable = [NSButton checkboxWithTitle:@"Enable desktop effect (⌃⌥⌘P)" target:self action:@selector(toggle:)];
        self.readingEnable.frame = NSMakeRect(20,641,305,26); [view addSubview:self.readingEnable];
        self.readingModeControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(330,641,330,28) pullsDown:NO];
        [self.readingModeControl addItemsWithTitles:self.looks];
        self.readingModeControl.target = self; self.readingModeControl.action = @selector(selectLook:);
        self.readingModeControl.accessibilityLabel = @"Look"; [view addSubview:self.readingModeControl];
        self.readingStatus = [NSTextField labelWithString:@""]; self.readingStatus.frame = NSMakeRect(20,610,640,24);
        self.readingStatus.font = [NSFont systemFontOfSize:12]; self.readingStatus.textColor = NSColor.secondaryLabelColor; [view addSubview:self.readingStatus];
        self.readingSwitches = NSMutableDictionary.dictionary; self.readingSliders = NSMutableDictionary.dictionary; self.readingLabels = NSMutableDictionary.dictionary;
        CGFloat y = 567;
        for (NSDictionary *row in ReadingRows()) {
            NSString *key = row[@"key"];
            NSButton *check = [NSButton checkboxWithTitle:row[@"title"] target:self action:@selector(changeReading:)];
            check.identifier = key; check.frame = NSMakeRect(20,y,315,26); check.toolTip = row[@"help"];
            [view addSubview:check]; self.readingSwitches[key] = check;
            if (row[@"amount"]) {
                NSSlider *slider = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(changeReading:)];
                slider.identifier = key; slider.frame = NSMakeRect(350,y,210,26); slider.continuous = NO; slider.toolTip = row[@"help"];
                slider.accessibilityLabel = [row[@"title"] stringByAppendingString:@" amount"];
                [view addSubview:slider]; self.readingSliders[key] = slider;
                NSTextField *label = [NSTextField labelWithString:@""]; label.frame = NSMakeRect(568,y,80,24);
                label.alignment = NSTextAlignmentRight; label.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
                [view addSubview:label]; self.readingLabels[key] = label;
            }
            y -= 46;
        }
        for (NSArray *item in @[@[@"Reading defaults",@1,@20],@[@"Bypass all stages",@0,@190]]) {
            NSButton *button = [NSButton buttonWithTitle:item[0] target:self action:@selector(resetReading:)];
            button.tag = [item[1] integerValue]; button.frame = NSMakeRect([item[2] doubleValue],155,160,30); [view addSubview:button];
        }
        NSButton *chart = [NSButton buttonWithTitle:@"Show test chart" target:self action:@selector(showChart:)]; chart.frame = NSMakeRect(500,155,160,30); [view addSubview:chart];
        NSTextField *note = [NSTextField wrappingLabelWithString:@"Inspired by snes19xx/surface-dots. No capture or frame timer.\nSurface Dots uses a native source-curve lookup at full grayscale. Soft restores the earlier gentle contrast. Partial grayscale keeps affine color exploration. Highlight mask = linear ramp. Static multiply grain repeats every 256 native pixels. Vignette shape differs; spatial paper-color variation is omitted.\nAmounts apply on release; unchecked stages retain their values. Main Paper strength scales grain, fibers and Bayer texture only. Performance is unmeasured."];
        note.frame = NSMakeRect(20,20,640,120); note.font = [NSFont systemFontOfSize:12]; note.textColor = NSColor.secondaryLabelColor; [view addSubview:note];
        [view scrollPoint:NSMakePoint(0,680-height)]; [self.readingPanel center];
    }
    [self apply]; [self.readingPanel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [self.readingPanel orderFrontRegardless];
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
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"originalStrength"];
}
- (void)syncAdvanced {
    self.advancedEnable.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.advancedStatus.stringValue = (self.mode != 0 && self.mode != 3) ? @"Original Paper settings inactive. Editing selects Original Paper." :
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
    BOOL switched=self.mode!=0 && self.mode!=3;
    if (switched) [self activateLook:0];
    NSString *key = sender.identifier;
    BOOL topology = switched || [@[@"overlay",@"multiply",@"mix",@"inspectMultiply"] containsObject:key];
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
    self.mode=0;
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"graphMode"];
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
    if (self.mode!=0 && self.mode!=3) [self activateLook:0];
    BOOL preset = sender.tag == 1;
    for (NSDictionary *row in AdvancedRows()) {
        if (row[@"unavailable"] || row[@"automatic"]) continue;
        self.stageOn[row[@"key"]] = @(preset);
        if (preset && row[@"amount"] && ![row[@"key"] isEqual:@"texture"]) self.stageAmounts[row[@"key"]] = row[@"amount"];
    }
    if (preset) self.strength = 1;
    self.inspectMultiply = NO; self.mode = 0;
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"graphMode"];
    [NSUserDefaults.standardUserDefaults setFloat:self.strength forKey:@"graphStrength"]; [self saveAdvanced]; [self rebuildGraphs];
}
- (void)showAdvanced:(id)sender {
    if (self.mode!=0 && self.mode!=3) [self activateLook:0];
    [self.readingPanel orderOut:nil];
    if (!self.advancedPanel) {
        CGFloat height = fmin(740,fmax(360,NSScreen.mainScreen.visibleFrame.size.height-48));
        self.advancedPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,680,height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.advancedPanel.title = @"Original Paper — Stage Breakdown"; self.advancedPanel.releasedWhenClosed = NO;
        self.advancedPanel.hidesOnDeactivate = NO; self.advancedPanel.level = NSStatusWindowLevel+2;
        self.advancedPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.advancedPanel.contentView.bounds];
        scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES;
        scroll.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable; scroll.drawsBackground = NO;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,680,740)];
        scroll.documentView = view; [self.advancedPanel.contentView addSubview:scroll];
        self.advancedEnable = [NSButton checkboxWithTitle:@"Enable desktop effect (⌃⌥⌘P)" target:self action:@selector(toggle:)];
        self.advancedEnable.frame = NSMakeRect(20,702,305,26); [view addSubview:self.advancedEnable];
        self.advancedModeControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(330,702,330,28) pullsDown:NO];
        [self.advancedModeControl addItemsWithTitles:self.looks];
        self.advancedModeControl.target = self; self.advancedModeControl.action = @selector(selectLook:);
        self.advancedModeControl.accessibilityLabel = @"Look"; [view addSubview:self.advancedModeControl];
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
        [self.modeControl addItemsWithTitles:self.looks]; self.modeControl.target = self; self.modeControl.action = @selector(selectLook:);
        self.modeControl.accessibilityLabel = @"Look"; [view addSubview:self.modeControl];
        NSButton *advanced = [NSButton buttonWithTitle:@"Breakdown…" target:self action:@selector(showBreakdown:)];
        advanced.frame = NSMakeRect(290,164,110,28); [view addSubview:advanced];
        self.strengthLabel = [NSTextField labelWithString:@""];
        self.strengthLabel.frame = NSMakeRect(20,130,380,20); [view addSubview:self.strengthLabel];
        self.strengthControl = [NSSlider sliderWithValue:self.strength minValue:0 maxValue:1 target:self action:@selector(changeStrength:)];
        self.strengthControl.frame = NSMakeRect(20,96,380,26); self.strengthControl.continuous = YES;
        self.strengthControl.accessibilityLabel = @"Paper texture strength"; [view addSubview:self.strengthControl];
        NSTextField *note = [NSTextField wrappingLabelWithString:@"Choose a Look; Breakdown… opens its own saved tuning.\nPrivate compositor APIs; not byte-exact shader execution.\nNo recording stream. Power savings are not measured."];
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
    [self showBreakdown:nil]; return NO;
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
        NSSet *allowed = [NSSet setWithArray:@[@"--self-check", @"--enable", @"--controls", @"--chart", @"--color-only", @"--paper-only", @"--advanced", @"--reading"]];
        for (NSString *arg in [args subarrayWithRange:NSMakeRange(1,args.count-1)]) {
            if (![allowed containsObject:arg]) { fprintf(stderr,"Unknown option: %s\n",arg.UTF8String); return 2; }
        }
        if ((int)[args containsObject:@"--color-only"] + (int)[args containsObject:@"--paper-only"] + (int)[args containsObject:@"--advanced"] + (int)[args containsObject:@"--reading"] > 1) {
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
