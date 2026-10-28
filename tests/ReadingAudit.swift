// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Anish Thite
// Source lineage and retained upstream notices: see THIRD_PARTY_NOTICES.md.
// Calibrated, bounded Reading Mode audit. No screen capture or global effect control here.
// Generate configs, run TextureProbe for each, then measure using the SAME native RGB/profile.
import AppKit
import ImageIO

func invalid(_ message: String) -> NSError {
    NSError(domain: "ReadingAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func image(_ url: URL) throws -> CGImage {
    guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
          let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw invalid("Cannot read \(url.path)") }
    return image
}
func write(_ image: CGImage, _ url: URL) throws {
    guard let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { throw invalid("Cannot write PNG") }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { throw invalid("Cannot encode PNG") }
}
func pixels(_ image: CGImage) throws -> [UInt8] {
    guard let space=image.colorSpace else { throw invalid("Missing input profile") }
    var data=[UInt8](repeating:0,count:image.width*image.height*4)
    try data.withUnsafeMutableBytes { bytes in
        guard let context=CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,
            bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw invalid("Cannot decode profile-preserving pixels") }
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    }
    return data
}
func verifyCapture(_ image: CGImage, _ bytes: [UInt8], _ url: URL) throws {
    guard image.width==1040 && image.height==528 else { throw invalid("Expected native 512² halves and identity gutter") }
    var identity:UInt32=2166136261
    for byte in url.path.utf8 { identity=(identity^UInt32(byte)) &* 16777619 }
    for bit in 0..<32 {
        let i=(3*1040+12+bit)*4
        guard (bytes[i]>127)==(((identity>>bit)&1)==1) else { throw invalid("Stale or obscured capture: \(url.lastPathComponent)") }
    }
    for (x,y) in [(1,1),(1038,1),(1,526),(1038,526)] {
        let i=(y*1040+x)*4
        guard bytes[i]>150 && bytes[i+1]<100 && bytes[i+2]>150 else { throw invalid("Missing capture corner") }
    }
}
func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t=min(1,max(0,(x-a)/(b-a)))
    return t*t*(3-2*t)
}
// Independently transcribe the source expression, not the production implementation or LUT.
func sourceTone(_ gray: Double) -> Double {
    let powered=pow(gray,1.2)
    let shaped=smooth(0.08,0.92,powered)
    let boost=smooth(0.3,0.5,shaped)*(1-smooth(0.5,0.7,shaped))
    return shaped+0.1*boost
}
let keys=["grey","tone","grain","fibers","dither","highlights","palette","vignette"]
let cases=["raw","bypass","grey","palette","tone","tone-half","soft","soft-half","color"]
do {
guard CommandLine.arguments.count==3 else { throw invalid("Usage: swift ReadingAudit.swift generate|measure output-directory") }
let root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
if CommandLine.arguments[1]=="generate" {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    for scene in ["ramps","rgb"] {
        var bytes=[UInt8](repeating:255,count:512*512*4)
        for y in 0..<512 { for x in 0..<512 {
            let i=(y*512+x)*4
            for c in 0..<3 {
                if scene=="ramps" { bytes[i+c]=(y/128==0 || c==y/128-1) ? UInt8(x/2) : 0 }
                else { bytes[i+c]=UInt8((c==0 ? x : c==1 ? y : x*37+y*73)&255) }
            }
        }}
        let provider=CGDataProvider(data:Data(bytes) as CFData)!
        let image=CGImage(width:512,height:512,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:2048,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let input=root.appendingPathComponent("\(scene)-input.png")
        try write(image,input)
        for name in cases {
            var settings=Dictionary(uniqueKeysWithValues:keys.map{($0,0.0)})
            if !["raw","bypass"].contains(name) { settings["grey"]=1 }
            if ["palette","color"].contains(name) { settings["palette"]=1 }
            if ["tone","tone-half","soft","soft-half","color"].contains(name) { settings["tone"]=name.hasSuffix("-half") ? 0.5 : 1 }
            if name.hasPrefix("soft") { settings["softTone"]=1 }
            let config:[String:Any]=["mode":name=="raw" ? "raw":"reading","reading":settings,"input":input.path,"tile":512,"settle":1]
            try JSONSerialization.data(withJSONObject:config,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("\(scene)-\(name).json"))
        }
    }
    print("Generated 18 cases. Disable global effects; capture each JSON with TextureProbe to the matching .png, then measure.")
} else if CommandLine.arguments[1]=="measure" {
    var reports=[[String:Any]]()
    for scene in ["ramps","rgb"] {
        let rawImage=try image(root.appendingPathComponent("\(scene)-raw.png")),raw=try pixels(rawImage)
        try verifyCapture(rawImage,raw,root.appendingPathComponent("\(scene)-raw.png"))
        let neutralImage=try image(root.appendingPathComponent("\(scene)-grey.png")),neutral=try pixels(neutralImage)
        for name in cases+["before"] where name != "raw" {
            if name=="before" && !FileManager.default.fileExists(atPath:root.appendingPathComponent("\(scene)-before.png").path) {continue}
            let actualImage=try image(root.appendingPathComponent("\(scene)-\(name).png"))
            guard actualImage.width==1040 && actualImage.height==528,
                CFEqual(actualImage.colorSpace,rawImage.colorSpace) else { throw invalid("Capture dimensions/profile changed") }
            let actual=try pixels(actualImage)
            try verifyCapture(actualImage,actual,root.appendingPathComponent("\(scene)-\(name).png"))
            for quantized in (name=="tone" ? [false,true] : [false]) {
                var errors=[Double](),maximum = -1.0,worst:[String:Any]=[:],spread=0
                for y in 8..<504 {
                    if scene=="ramps" && (y%128<16 || y%128>=112) {continue}
                    for x in 8..<504 {
                        let i=((y+8)*1040+x+8)*4
                        let rgb=(0..<3).map{Double(raw[i+$0])/255}
                        var gray=quantized ? Double(neutral[i])/255 : 0.299*rgb[0]+0.587*rgb[1]+0.114*rgb[2]
                        if name.hasPrefix("soft") {
                            let amount=name=="soft-half" ? 0.5 : 1
                            gray=min(1,max(0,(1+0.18*amount)*gray-0.09*amount))
                        } else if name=="tone-half" {gray=0.5*gray+0.5*sourceTone(gray)}
                        else if ["tone","color","before"].contains(name) {gray=sourceTone(gray)}
                        for c in 0..<3 {
                            let ink=[0.10,0.10,0.12][c],paper=[0.94,0.92,0.86][c]
                            let expected=name=="bypass" ? rgb[c] : (["palette","color"].contains(name) ? ink+(paper-ink)*gray : gray)
                            let error=abs(Double(actual[i+c])-255*expected)
                            errors.append(error)
                            if error>maximum {maximum=error;worst=["x":x,"y":y,"channel":c,"nativeRGB":rgb.map{$0*255},"expected":255*expected,"actual":actual[i+c]]}
                        }
                        let channels=(0..<3).map{Int(actual[i+$0])};spread=max(spread,channels.max()!-channels.min()!)
                    }
                }
                errors.sort()
                let label=name+(quantized ? "-after-captured-gray":"")
                let report:[String:Any]=["scene":scene,"stage":label,"samples":errors.count,"mean":errors.reduce(0,+)/Double(errors.count),
                    "p99":errors[Int(Double(errors.count)*0.99)],"maximum":maximum,"worst":worst,"channelSpread":spread]
                reports.append(report)
                print(String(format:"%@ %@: mean %.4f, p99 %.4f, max %.4f /255",scene,label,errors.reduce(0,+)/Double(errors.count),errors[Int(Double(errors.count)*0.99)],maximum))
                // Finite regression limits; not a universal equivalence claim.
                let limit:Double=name=="bypass" ? 1 : name=="grey" || name=="palette" || name.hasPrefix("soft") || quantized ? 1 : 3
                guard name=="before" || maximum<=limit else { throw invalid("\(scene) \(label) exceeds \(limit)/255") }
                if name=="grey" {guard spread<=1 else { throw invalid("Original hues leaked through full grayscale") }}
            }
        }
    }
    let report:[String:Any]=["units":"native encoded RGB8 levels; same-profile calibrated input","reference":"Surface Dots scalar stages; Soft uses its original affine contract; grain, mask, vignette and spatial tint excluded","reports":reports]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("reading-results.json"))
} else { throw invalid("Unknown action") }
} catch {
    fputs("Reading audit failed: \(error.localizedDescription)\n",stderr)
    exit(1)
}
