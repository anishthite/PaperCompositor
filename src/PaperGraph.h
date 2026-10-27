// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Shader lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
#pragma once
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <math.h>

// One implementation for the app and rendered-reference probe.
static id PGFilter(NSString *name, NSDictionary *values) {
    Class cls = NSClassFromString(@"CAFilter");
    SEL selector = NSSelectorFromString(@"filterWithType:");
    if (!cls || ![cls respondsToSelector:selector])
        @throw [NSException exceptionWithName:@"Unsupported compositor" reason:@"CAFilter is unavailable." userInfo:nil];
    id filter = ((id (*)(id, SEL, id))objc_msgSend)(cls, selector, name);
    if (!filter)
        @throw [NSException exceptionWithName:@"Unsupported filter" reason:name userInfo:nil];
    for (NSString *key in values) [filter setValue:values[key] forKey:key];
    return filter;
}

static id PGMatrixFilter(const float matrix[20]) {
    NSValue *value = [NSValue valueWithBytes:matrix objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    return PGFilter(@"colorMatrix", @{@"inputColorMatrix": value});
}

static NSArray *PGColorFilters(BOOL preserveColor) {
    if (preserveColor) return @[PGFilter(@"colorSaturate", @{@"inputAmount": @1})];
    // ponytail: fixed preset defaults; add other color controls only after reference validation.
    // Keep correction separate: merging it into grayscale discards an intermediate clamp.
    // The compositor's own intermediate clamp/precision still differs slightly from the shader.
    const float correction[20] = {
        .845,.17,-.015,0,0, .09,.68,.23,0,0, .16,.085,.755,0,0, 0,0,0,1,0
    };
    const float tone[20] = {
        .2126*.95,.7152*.95,.0722*.95,0,.05,
        .2126*.95,.7152*.95,.0722*.95,0,.05,
        .2126*.95,.7152*.95,.0722*.95,0,.05,
        0,0,0,1,0
    };
    return @[PGMatrixFilter(correction), PGMatrixFilter(tone)];
}

typedef struct {
    BOOL correction, texture, overlay, multiply, mix, inspectMultiply;
    double grey, contrast, brightness, black, tint;
} PGStages;

static inline PGStages PGDefaultStages(void) {
    return (PGStages){.correction=YES,.texture=YES,.overlay=YES,.multiply=YES,.mix=YES,
                      .grey=1,.contrast=1,.brightness=0,.black=.05,.tint=0};
}

static inline NSArray *PGStageFilters(PGStages s) {
    if (!isfinite(s.grey) || s.grey<0 || s.grey>1 || !isfinite(s.contrast) || s.contrast<.5 || s.contrast>2 ||
        !isfinite(s.brightness) || s.brightness<-.5 || s.brightness>.5 || !isfinite(s.black) || s.black<0 || s.black>.3 ||
        !isfinite(s.tint) || s.tint<0 || s.tint>1)
        @throw [NSException exceptionWithName:@"Invalid color stage" reason:@"Advanced color amounts are outside the shader ranges." userInfo:nil];
    NSMutableArray *filters = NSMutableArray.array;
    if (s.correction) [filters addObject:PGColorFilters(NO).firstObject];
    if (s.grey!=0 || s.contrast!=1 || s.brightness!=0 || s.black!=0 || s.tint!=0) {
        // Preserve shader order without extra clamps between affine stages.
        float matrix[20] = {0};
        const double luma[3] = {.2126,.7152,.0722}, tint[3] = {.95,.93,.88};
        for (int row=0; row<3; row++) {
            double warmth = 1+(tint[row]-1)*s.tint;
            double gain = warmth*(1-s.black)*s.contrast;
            for (int col=0; col<3; col++) matrix[row*5+col] = gain*((row==col ? 1-s.grey : 0)+s.grey*luma[col]);
            matrix[row*5+4] = warmth*(s.black+(1-s.black)*(.5*(1-s.contrast)+s.brightness));
        }
        matrix[18] = 1;
        [filters addObject:PGMatrixFilter(matrix)];
    }
    return filters.count ? filters : PGColorFilters(YES);
}

static inline void PGUpdateColorFilters(CALayer *layer, NSArray *filters, BOOL mask) {
    if ([layer isKindOfClass:NSClassFromString(@"CABackdropLayer")])
        layer.filters = mask ? [filters arrayByAddingObject:PGFilter(@"luminanceToAlpha", @{})] : filters;
    for (CALayer *child in layer.sublayers) PGUpdateColorFilters(child,filters,mask);
    if (layer.mask) PGUpdateColorFilters(layer.mask,filters,YES);
}

static CALayer *PGBackdrop(CGRect bounds, CGFloat scale, NSString *group, NSArray *filters) {
    Class cls = NSClassFromString(@"CABackdropLayer");
    if (!cls || ![cls isSubclassOfClass:CALayer.class])
        @throw [NSException exceptionWithName:@"Unsupported compositor" reason:@"CABackdropLayer is unavailable." userInfo:nil];
    CALayer *layer = [cls new];
    layer.frame = bounds;
    layer.contentsScale = scale;
    layer.masksToBounds = YES;
    [layer setValue:@YES forKey:@"windowServerAware"];
    [layer setValue:@1 forKey:@"scale"]; // No text downsampling.
    [layer setValue:group forKey:@"groupName"];
    [layer setValue:@YES forKey:@"usesGlobalGroupNamespace"];
    layer.filters = filters;
    return layer;
}

static CALayer *PGPaper(CGImageRef image, CGRect bounds, CGFloat scale, CGSize texturePixels) {
    CALayer *container = CALayer.layer;
    container.frame = bounds;
    container.masksToBounds = YES;
    // The original preset defaults to ClampToBorder, not repeating paper.
    container.backgroundColor = NSColor.blackColor.CGColor;
    CALayer *pixels = CALayer.layer;
    pixels.contents = (__bridge id)image;
    pixels.contentsScale = scale;
    pixels.minificationFilter = kCAFilterNearest;
    pixels.magnificationFilter = kCAFilterNearest;
    pixels.frame = CGRectMake(0, bounds.size.height - texturePixels.height / scale,
                             texturePixels.width / scale, texturePixels.height / scale);
    [container addSublayer:pixels];
    return container;
}

static CALayer *PGGroup(CGRect bounds) {
    CALayer *layer = CALayer.layer;
    layer.frame = bounds;
    layer.masksToBounds = YES;
    return layer;
}

static void PGSetStrength(CALayer *layer, float strength);

static CALayer *PGCreateStageGraph(CGRect bounds, CGFloat scale, CGImageRef image,
                              CGSize texturePixels, NSArray *filters, BOOL colorOnly, PGStages stages, float strength) {
    if (!image || !isfinite(scale) || scale <= 0 || texturePixels.width <= 0 || texturePixels.height <= 0)
        @throw [NSException exceptionWithName:@"Invalid graph input" reason:@"A paper image and valid pixel scale are required." userInfo:nil];
    NSString *group = NSUUID.UUID.UUIDString;
    CALayer *root = PGGroup(bounds);
    root.name = @"original-blend-graph";
    CALayer *source = PGBackdrop(bounds, scale, group, filters);
    [root addSublayer:source];
    if (colorOnly) return root;

    CALayer *overlay = PGGroup(bounds);
    overlay.name = @"overlay-branch";
    overlay.hidden = !stages.overlay || (!stages.mix && stages.inspectMultiply);
    [overlay addSublayer:PGBackdrop(bounds, scale, group, filters)];
    CALayer *textureEffect = PGGroup(bounds);
    textureEffect.backgroundColor = [NSColor colorWithSRGBRed:.5 green:.5 blue:.5 alpha:1].CGColor;
    CALayer *paper = PGPaper(image, bounds, scale, texturePixels);
    paper.name = @"texture-strength";
    [textureEffect addSublayer:paper];
    textureEffect.compositingFilter = PGFilter(@"overlayBlendMode", @{});
    [overlay addSublayer:textureEffect];
    [root addSublayer:overlay];

    CALayer *luma = PGGroup(bounds);
    luma.name = @"luma-branch"; luma.hidden = !stages.mix && !stages.inspectMultiply;
    [luma addSublayer:PGBackdrop(bounds, scale, group, filters)];
    CALayer *multiply = PGGroup(bounds);
    multiply.name = @"multiply-effect"; multiply.hidden = !stages.multiply;
    [multiply addSublayer:PGBackdrop(bounds, scale, group, filters)];
    CALayer *multiplyPaper = PGPaper(image, bounds, scale, texturePixels);
    multiplyPaper.compositingFilter = PGFilter(@"multiplyBlendMode", @{});
    [multiply addSublayer:multiplyPaper];
    NSArray *maskFilters = [filters arrayByAddingObject:PGFilter(@"luminanceToAlpha", @{})];
    CALayer *strengthMask = PGBackdrop(bounds, scale, group, maskFilters);
    strengthMask.name = @"luma-strength";
    multiply.mask = strengthMask;
    [luma addSublayer:multiply];
    if (stages.mix) luma.mask = PGBackdrop(bounds, scale, group, maskFilters);
    [root addSublayer:luma];
    PGSetStrength(root,stages.texture ? strength : 0);
    return root;
}

static inline CALayer *PGCreateGraph(CGRect bounds, CGFloat scale, CGImageRef image,
                              CGSize texturePixels, NSArray *filters, BOOL colorOnly) {
    return PGCreateStageGraph(bounds,scale,image,texturePixels,filters,colorOnly,PGDefaultStages(),1);
}

// Only these two opacity values change during a slider drag; keep the backdrop group stable.
static void PGSetStrength(CALayer *layer, float strength) {
    strength = isfinite(strength) ? fminf(1, fmaxf(0, strength)) : 1;
    if ([layer.name isEqualToString:@"texture-strength"] || [layer.name isEqualToString:@"luma-strength"])
        layer.opacity = strength;
    for (CALayer *child in layer.sublayers) PGSetStrength(child, strength);
    if (layer.mask) PGSetStrength(layer.mask, strength);
}
