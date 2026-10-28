// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Source lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
// Bounded, validation-only WindowServer screenshots. Never a desktop-wide overlay.
#import "ReadingGraph.h"
#import <ImageIO/ImageIO.h>

static CGImageRef LoadImage(NSString *path) {
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    CGImageRef result = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!result) @throw [NSException exceptionWithName:@"Invalid image" reason:path userInfo:nil];
    return CGImageRetain(result);
}
static CALayer *ImageLayer(CGImageRef image, CGRect frame, CGFloat scale) {
    CALayer *layer = CALayer.layer;
    layer.frame = frame; layer.contents = (__bridge id)image; layer.contentsScale = scale;
    layer.minificationFilter = kCAFilterNearest; layer.magnificationFilter = kCAFilterNearest;
    return layer;
}
static NSUInteger OffsetPaper(CALayer *layer, CGFloat x, CGFloat y) {
    NSUInteger count = 0;
    if (layer.contents) {
        CGRect frame = layer.frame; frame.origin.x -= x; frame.origin.y += y; layer.frame = frame; count++;
    }
    for (CALayer *child in layer.sublayers) count += OffsetPaper(child,x,y);
    if (layer.mask) count += OffsetPaper(layer.mask,x,y);
    return count;
}
@interface ValidationWindow : NSWindow @end
@implementation ValidationWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
@interface TextureAudit : NSObject <NSApplicationDelegate>
@property NSDictionary *config;
@property NSString *output;
@property NSWindow *source;
@property NSWindow *overlay;
@property int result;
@end
@implementation TextureAudit
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    @try {
        for (NSDictionary *window in CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID))) {
            if ([window[(__bridge NSString *)kCGWindowOwnerName] isEqual:@"PaperCompositor"] && [window[(__bridge NSString *)kCGWindowLayer] integerValue] == NSStatusWindowLevel+1)
                @throw [NSException exceptionWithName:@"Global effect enabled" reason:@"Disable PaperCompositor before collecting validation screenshots." userInfo:nil];
        }
        NSDictionary *c = self.config;
        NSString *mode = c[@"mode"] ?: @"graph";
        if (![@[@"graph",@"paper",@"raw",@"reading"] containsObject:mode]) @throw [NSException exceptionWithName:@"Invalid mode" reason:mode userInfo:nil];
        NSUInteger tile = c[@"tile"] ? [c[@"tile"] unsignedIntegerValue] : 512;
        double strength = c[@"strength"] ? [c[@"strength"] doubleValue] : 1;
        double tileX = [c[@"x"] doubleValue], tileY = [c[@"y"] doubleValue];
        double settle = c[@"settle"] ? [c[@"settle"] doubleValue] : 0.5;
        NSInteger presetMode = [c[@"presetMode"] integerValue];
        if (tile < 1 || tile > 1024 || !isfinite(strength) || strength < 0 || strength > 1 ||
            !isfinite(tileX) || !isfinite(tileY) || tileX < 0 || tileY < 0 || tileX > 8192 || tileY > 8192 ||
            !isfinite(settle) || settle < 0.1 || settle > 3 || presetMode < 0 || presetMode > 2)
            @throw [NSException exceptionWithName:@"Invalid dimensions" reason:@"Invalid tile, offset, or strength." userInfo:nil];
        NSScreen *screen = NSScreen.screens.firstObject;
        CGFloat scale = screen.backingScaleFactor, size = tile / scale;
        CGFloat gutter = 8/scale;
        CGRect bounds = CGRectMake(0,0,size,size);
        self.source = [[ValidationWindow alloc] initWithContentRect:NSMakeRect(NSMinX(screen.frame)+80,NSMinY(screen.frame)+100,size*2+gutter*2,size+gutter*2) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        self.source.releasedWhenClosed = NO; self.source.hasShadow = NO; self.source.ignoresMouseEvents = YES;
        self.source.level = NSStatusWindowLevel+3; self.source.colorSpace = NSColorSpace.sRGBColorSpace;
        self.source.animationBehavior = NSWindowAnimationBehaviorNone;
        self.source.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,size*2+gutter*2,size+gutter*2)];
        view.layer = CALayer.layer; view.wantsLayer = YES; view.layerUsesCoreImageFilters = NO;
        view.layer.backgroundColor = [NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1].CGColor; self.source.contentView = view;
        CALayer *left = CALayer.layer; left.frame = CGRectMake(gutter,gutter,size,size);
        left.backgroundColor = NSColor.whiteColor.CGColor; [view.layer addSublayer:left];
        // A unique bit strip plus four magenta corners rejects stale, moved, or occluded captures.
        uint32_t identity = 2166136261U;
        for (const unsigned char *p=(const unsigned char *)self.output.UTF8String; *p; p++) identity = (identity ^ *p) * 16777619U;
        for (int bit=0; bit<32; bit++) {
            CALayer *mark = CALayer.layer; mark.frame = CGRectMake((12+bit)/scale,size+gutter*2-6/scale,1/scale,4/scale);
            mark.backgroundColor = ((identity >> bit) & 1 ? NSColor.whiteColor : NSColor.blackColor).CGColor;
            [view.layer addSublayer:mark];
        }
        CGImageRef input = c[@"input"] ? LoadImage(c[@"input"]) : NULL;
        if (input && [c[@"inputCrop"] boolValue]) {
            CGRect crop = CGRectMake(tileX,tileY,tile,tile);
            if (CGRectGetMaxX(crop) > CGImageGetWidth(input) || CGRectGetMaxY(crop) > CGImageGetHeight(input))
                @throw [NSException exceptionWithName:@"Invalid input crop" reason:@"Input crop exceeds image." userInfo:nil];
            CGImageRef cropped = CGImageCreateWithImageInRect(input,crop); CGImageRelease(input); input = cropped;
        }
        if (input) [left addSublayer:ImageLayer(input,bounds,scale)];
        CGImageRef expected = NULL;
        if (c[@"reference"]) {
            CGImageRef full = LoadImage(c[@"reference"]);
            CGRect crop = CGRectMake(tileX,tileY,tile,tile);
            if (CGRectGetMaxX(crop) > CGImageGetWidth(full) || CGRectGetMaxY(crop) > CGImageGetHeight(full))
                @throw [NSException exceptionWithName:@"Invalid reference" reason:@"Reference crop exceeds image." userInfo:nil];
            expected = CGImageCreateWithImageInRect(full,crop); CGImageRelease(full);
        } else if (input) expected = CGImageRetain(input);
        if (expected) [view.layer addSublayer:ImageLayer(expected,CGRectMake(size+gutter,gutter,size,size),scale)];
        if (![mode isEqual:@"raw"]) {
            CGImageRef texture = [mode isEqual:@"reading"] ? NULL : LoadImage(c[@"texture"]);
            self.overlay = [[ValidationWindow alloc] initWithContentRect:NSMakeRect(NSMinX(screen.frame)+80+gutter,NSMinY(screen.frame)+100+gutter,size,size) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            self.overlay.releasedWhenClosed = NO; self.overlay.opaque = NO; self.overlay.backgroundColor = NSColor.clearColor;
            self.overlay.hasShadow = NO; self.overlay.ignoresMouseEvents = YES; self.overlay.level = NSStatusWindowLevel+4;
            self.overlay.colorSpace = NSColorSpace.sRGBColorSpace;
            self.overlay.animationBehavior = NSWindowAnimationBehaviorNone;
            self.overlay.collectionBehavior = self.source.collectionBehavior;
            NSView *canvas = [[NSView alloc] initWithFrame:bounds]; canvas.layer = CALayer.layer; canvas.wantsLayer = YES;
            canvas.layerUsesCoreImageFilters = NO; canvas.layer.masksToBounds = YES;
            canvas.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever; self.overlay.contentView = canvas;
            CALayer *graph;
            if ([mode isEqual:@"reading"]) {
                NSDictionary *settings = c[@"reading"] ?: @{};
                if (![settings isKindOfClass:NSDictionary.class]) @throw [NSException exceptionWithName:@"Invalid reading settings" reason:@"Expected a dictionary." userInfo:nil];
                graph = RGCreateGraph(bounds,scale,settings,strength);
            } else if ([mode isEqual:@"paper"]) graph = PGPaper(texture,bounds,scale,CGSizeMake(4096,4096));
            else {
                NSDictionary *d = c[@"stages"];
                if (d) {
                    NSSet *keys = [NSSet setWithArray:@[@"correction",@"texture",@"overlay",@"multiply",@"mix",@"inspectMultiply",@"grey",@"contrast",@"brightness",@"black",@"tint"]];
                    if (![d isKindOfClass:NSDictionary.class]) @throw [NSException exceptionWithName:@"Invalid stages" reason:@"Expected a stage dictionary." userInfo:nil];
                    for (NSString *key in d) if (![keys containsObject:key] || ![d[key] isKindOfClass:NSNumber.class])
                        @throw [NSException exceptionWithName:@"Invalid stage" reason:key userInfo:nil];
                    PGStages s = PGDefaultStages();
                    if (d[@"correction"]) s.correction=[d[@"correction"] boolValue];
                    if (d[@"texture"]) s.texture=[d[@"texture"] boolValue];
                    if (d[@"overlay"]) s.overlay=[d[@"overlay"] boolValue];
                    if (d[@"multiply"]) s.multiply=[d[@"multiply"] boolValue];
                    if (d[@"mix"]) s.mix=[d[@"mix"] boolValue];
                    if (d[@"inspectMultiply"]) s.inspectMultiply=[d[@"inspectMultiply"] boolValue];
                    if (d[@"grey"]) s.grey=[d[@"grey"] doubleValue];
                    if (d[@"contrast"]) s.contrast=[d[@"contrast"] doubleValue];
                    if (d[@"brightness"]) s.brightness=[d[@"brightness"] doubleValue];
                    if (d[@"black"]) s.black=[d[@"black"] doubleValue];
                    if (d[@"tint"]) s.tint=[d[@"tint"] doubleValue];
                    graph = PGCreateStageGraph(bounds,scale,texture,CGSizeMake(4096,4096),PGStageFilters(s),NO,s,strength);
                } else {
                    graph = PGCreateGraph(bounds,scale,texture,CGSizeMake(4096,4096),PGColorFilters(presetMode == 2),presetMode == 1);
                    PGSetStrength(graph,strength);
                }
            }
            // Uniform white makes the original formula equal B at strength one.
            // Shift only texture quads to cover every texel without allocating a 4k window.
            if (![mode isEqual:@"reading"]) {
                NSUInteger images = OffsetPaper(graph,tileX/scale,tileY/scale);
                NSCAssert(images == ([mode isEqual:@"paper"] ? 1U : (presetMode == 1 ? 0U : 2U)), @"Unexpected paper image topology");
            }
            [canvas.layer addSublayer:graph]; if (texture) CGImageRelease(texture);
        }
        if (input) CGImageRelease(input);
        if (expected) CGImageRelease(expected);
        [self.source orderFrontRegardless];
        if (self.overlay) [self.overlay orderFrontRegardless];
        [CATransaction flush];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(settle*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            @try {
                if (!self.source.onActiveSpace) @throw [NSException exceptionWithName:@"Space changed" reason:@"The validation window is no longer on the active desktop; retry this case." userInfo:nil];
                NSRect rect = self.source.frame;
                NSString *region = [NSString stringWithFormat:@"-R%.0f,%.0f,%.0f,%.0f",rect.origin.x,NSMaxY(screen.frame)-NSMaxY(rect),rect.size.width,rect.size.height];
                NSTask *task = NSTask.new; task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
                task.arguments = @[@"-x",@"-tpng",region,self.output];
                NSError *error = nil;
                if (![task launchAndReturnError:&error]) @throw [NSException exceptionWithName:@"Screenshot failed" reason:error.localizedDescription userInfo:nil];
                [task waitUntilExit]; self.result = task.terminationStatus;
                NSLog(@"Captured %@ at %.0fx, tile %lu, offset %.0f,%.0f",self.output,scale,(unsigned long)tile,tileX,tileY);
            } @catch (NSException *e) { NSLog(@"Capture failed: %@",e); self.result = 1; }
            [self finish];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{ self.result=1; [self finish]; });
    } @catch (NSException *e) { NSLog(@"Texture validation failed: %@",e); self.result=1; [self finish]; }
}
- (void)finish { [self.overlay orderOut:nil]; [self.source orderOut:nil]; exit(self.result); }
@end
int main(int argc,const char *argv[]) { @autoreleasepool {
    if (argc != 3) { fputs("Usage: TextureProbe case.json screenshot.png\n",stderr); return 2; }
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1]) options:0 error:&error];
    NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![config isKindOfClass:NSDictionary.class]) { fprintf(stderr,"Invalid case JSON: %s\n",error.localizedDescription.UTF8String); return 2; }
    NSApplication *app = NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    TextureAudit *delegate = TextureAudit.new; delegate.config = config; delegate.output = @(argv[2]); app.delegate = delegate;
    [app run]; return delegate.result;
} }
