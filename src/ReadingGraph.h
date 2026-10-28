// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Source lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
#pragma once
#import "PaperGraph.h"
#import <stdint.h>

// Inspired by snes19xx/surface-dots reading_mode.glsl; independent native-layer approximation.
static inline NSArray<NSDictionary *> *ReadingRows(void) {
    return @[
        @{ @"key":@"grey", @"title":@"1. Grayscale (BT.601 weights)", @"amount":@1, @"help":@"At 100%, remove original hues before paper tint. These weights operate in the native backdrop color space, which can differ from the shader's sampled RGB." },
        @{ @"key":@"tone", @"title":@"2. Tone curve", @"amount":@1, @"help":@"Soft Reading uses the original gentle contrast; Surface Dots uses the source curve at full grayscale. Tone bypass and amount apply only to this look. Partial grayscale uses affine color exploration." },
        @{ @"key":@"grain", @"title":@"3. Fine paper grain", @"amount":@1, @"help":@"Deterministic static noise; a 256-pixel tile repeats at native resolution. Multiply darkening replaces shader-additive noise." },
        @{ @"key":@"fibers", @"title":@"4. Directional fibers", @"amount":@1, @"help":@"Anisotropic static grain, not their coordinate-shifted hash." },
        @{ @"key":@"dither", @"title":@"5. Bayer texture (4×4)", @"amount":@1, @"help":@"Ordered texture, not grayscale quantization." },
        @{ @"key":@"highlights", @"title":@"6. Highlight-only texture", @"help":@"Clamped luminance ramp approximates their smoothstep mask; uncheck for texture across all tones." },
        @{ @"key":@"palette", @"title":@"7. Cream paper / charcoal ink", @"amount":@1, @"help":@"Map black to (0.10, 0.10, 0.12), white to (0.94, 0.92, 0.86); spatial color variation is omitted." },
        @{ @"key":@"vignette", @"title":@"8. Soft edge vignette", @"amount":@1, @"help":@"Native radial gradient; approximate shape and placement, not their exact vignette formula." }
    ];
}

static double RGAmount(NSDictionary *settings, NSString *key) {
    id value = settings[key];
    double amount = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 1;
    return isfinite(amount) ? fmin(1,fmax(0,amount)) : 1;
}

static double RGSmooth(double low, double high, double value) {
    double t=fmin(1,fmax(0,(value-low)/(high-low)));
    return t*t*(3-2*t);
}

static double RGTone(double value) {
    double gray=RGSmooth(.08,.92,pow(value,1.2));
    return gray+.1*RGSmooth(.3,.5,gray)*(1-RGSmooth(.5,.7,gray));
}

static CGImageRef RGToneMap(void) {
    static CGImageRef image;
    if (!image) {
        Class cls=NSClassFromString(@"CAFilter"); SEL types=NSSelectorFromString(@"filterTypes");
        if (![cls respondsToSelector:types] || ![((NSArray *(*)(id,SEL))objc_msgSend)(cls,types) containsObject:@"luminanceMap"])
            @throw [NSException exceptionWithName:@"Reading tone unavailable" reason:@"This compositor does not advertise the native luminance lookup filter." userInfo:nil];
        uint8_t bytes[1024*4];
        for (int x=0;x<1024;x++) {
            bytes[x*4]=bytes[x*4+1]=bytes[x*4+2]=(uint8_t)lround(255*RGTone(x/1023.0));
            bytes[x*4+3]=255;
        }
        NSData *data=[NSData dataWithBytes:bytes length:sizeof(bytes)];
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        image=CGImageCreate(1024,1,8,32,4096,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(space);CGDataProviderRelease(provider);
        if (!image) @throw [NSException exceptionWithName:@"Reading tone unavailable" reason:@"Could not create the native tone lookup." userInfo:nil];
    }
    return image;
}

static NSArray *RGColorFilters(NSDictionary *settings, BOOL palette) {
    double grey = RGAmount(settings,@"grey"), tone = RGAmount(settings,@"tone");
    double tint = palette ? RGAmount(settings,@"palette") : 0;
    const double luma[3] = {.299,.587,.114}, ink[3] = {.10,.10,.12}, paper[3] = {.94,.92,.86};
    BOOL soft=[settings[@"softTone"] isKindOfClass:NSNumber.class] && [settings[@"softTone"] boolValue];
    BOOL useLookup=grey==1 && tone>0 && !soft;
    double affineTone=useLookup ? 0 : tone;
    float matrix[20] = {0}, paletteMatrix[20] = {0};
    for (int row=0; row<3; row++) {
        // Reuse the original gentle affine curve for Soft tone and partial-color exploration.
        for (int col=0; col<3; col++)
            matrix[row*5+col] = (1+.18*affineTone)*((row==col ? 1-grey : 0)+grey*luma[col]);
        matrix[row*5+4] = -.09*affineTone;
        paletteMatrix[row*5+row] = 1+tint*(paper[row]-ink[row]-1);
        paletteMatrix[row*5+4] = tint*ink[row];
    }
    matrix[18] = paletteMatrix[18] = 1;
    NSMutableArray *filters=[NSMutableArray arrayWithObject:PGMatrixFilter(matrix)];
    if (useLookup) [filters addObject:PGFilter(@"luminanceMap",@{@"inputColorMap":(__bridge id)RGToneMap(),@"inputAmount":@(tone)})];
    // Keep palette after the scalar tone lookup; do not fold it into the input grayscale matrix.
    if (tint>0) [filters addObject:PGMatrixFilter(paletteMatrix)];
    return filters;
}

static uint32_t RGHash(uint32_t x, uint32_t y) {
    uint32_t n = x*374761393u+y*668265263u+0x9e3779b9u;
    n = (n^(n>>13))*1274126177u;
    return n^(n>>16);
}

static uint8_t RGTileByte(NSInteger kind, uint32_t x, uint32_t y) {
    static const int bayer[16] = {0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
    double noise;
    if (kind==2) noise = bayer[(y%4)*4+x%4]/16.0-.5;
    else if (kind==1) noise = (RGHash(x/8,y/2)&65535)/65535.0-.5;
    else noise = (RGHash(x,y)&65535)/65535.0-.5;
    return (uint8_t)lround(255*(1-(noise+.5)*(kind==0 ? .035 : kind==1 ? .0175 : .025)));
}

static CGImageRef RGTile(NSInteger kind) {
    static CGImageRef images[3];
    NSCAssert(kind>=0 && kind<3, @"Invalid reading texture kind");
    if (!images[kind]) {
        uint8_t bytes[256*256];
        for (uint32_t y=0;y<256;y++) for (uint32_t x=0;x<256;x++) bytes[y*256+x] = RGTileByte(kind,x,y);
        NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
        images[kind] = CGImageCreate(256,256,8,8,256,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(space); CGDataProviderRelease(provider);
        if (!images[kind]) @throw [NSException exceptionWithName:@"Reading texture unavailable" reason:@"Could not create static grain tile." userInfo:nil];
    }
    return images[kind];
}

static CALayer *RGTexture(CGRect bounds, CGFloat scale, NSInteger kind) {
    CGFloat tileSize = 256/scale;
    CAReplicatorLayer *rows = CAReplicatorLayer.layer;
    rows.frame = bounds; rows.masksToBounds = YES;
    rows.instanceCount = (NSInteger)ceil(bounds.size.height/tileSize);
    rows.instanceTransform = CATransform3DMakeTranslation(0,tileSize,0);
    CAReplicatorLayer *columns = CAReplicatorLayer.layer;
    columns.frame = CGRectMake(0,0,bounds.size.width,tileSize);
    columns.instanceCount = (NSInteger)ceil(bounds.size.width/tileSize);
    columns.instanceTransform = CATransform3DMakeTranslation(tileSize,0,0);
    CALayer *tile = CALayer.layer;
    tile.frame = CGRectMake(0,0,tileSize,tileSize); tile.contentsScale = scale;
    tile.contents = (__bridge id)RGTile(kind);
    tile.minificationFilter = kCAFilterNearest; tile.magnificationFilter = kCAFilterNearest;
    [columns addSublayer:tile]; [rows addSublayer:columns];
    return rows;
}

static void RGSetStrength(CALayer *graph, NSDictionary *settings, float strength) {
    for (CALayer *layer in graph.sublayers) {
        if ([@[@"grain",@"fibers",@"dither"] containsObject:layer.name])
            layer.opacity = RGAmount(settings,layer.name)*fminf(1,fmaxf(0,isfinite(strength) ? strength : 1));
    }
}

static CALayer *RGCreateGraph(CGRect bounds, CGFloat scale, NSDictionary *settings, float strength) {
    if (!isfinite(scale) || scale<=0 || !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
        bounds.size.width<=0 || bounds.size.height<=0)
        @throw [NSException exceptionWithName:@"Invalid reading geometry" reason:@"Positive finite bounds and pixel scale are required." userInfo:nil];
    CALayer *root = PGGroup(bounds); root.name = @"reading-mode-approximation";
    NSString *group = NSUUID.UUID.UUIDString;
    [root addSublayer:PGBackdrop(bounds,scale,group,RGColorFilters(settings,YES))];
    NSArray *keys = @[@"grain",@"fibers",@"dither"];
    for (NSInteger kind=0;kind<3;kind++) {
        if (RGAmount(settings,keys[kind])==0) continue;
        CALayer *texture = RGTexture(bounds,scale,kind); texture.name = keys[kind];
        texture.compositingFilter = PGFilter(@"multiplyBlendMode",@{});
        if (RGAmount(settings,@"highlights")>0) {
            // Linear clamped ramp from 0.5 to 0.95, not the shader's smoothstep.
            const float threshold[20] = {
                .299/.45,.587/.45,.114/.45,0,-.5/.45,
                .299/.45,.587/.45,.114/.45,0,-.5/.45,
                .299/.45,.587/.45,.114/.45,0,-.5/.45, 0,0,0,1,0
            };
            NSArray *filters = [RGColorFilters(settings,NO) arrayByAddingObjectsFromArray:@[PGMatrixFilter(threshold),PGFilter(@"luminanceToAlpha",@{})]];
            texture.mask = PGBackdrop(bounds,scale,group,filters);
        }
        [root addSublayer:texture];
    }
    CAGradientLayer *vignette = CAGradientLayer.layer;
    vignette.name = @"vignette"; vignette.frame = bounds; vignette.type = kCAGradientLayerRadial;
    vignette.startPoint = CGPointMake(.5,.5); vignette.endPoint = CGPointMake(1,1);
    vignette.colors = @[(__bridge id)[NSColor colorWithWhite:0 alpha:0].CGColor,(__bridge id)[NSColor colorWithWhite:0 alpha:.04].CGColor];
    vignette.locations = @[@.55,@1]; vignette.opacity = RGAmount(settings,@"vignette");
    [root addSublayer:vignette]; RGSetStrength(root,settings,strength);
    return root;
}
