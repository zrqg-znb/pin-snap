// imgalign —— 截图几何回归工具（无第三方依赖，只用 CoreGraphics）
//
//   swift Scripts/tools/imgalign.swift find <crop.png> <base.png>
//       金字塔归一化互相关，定位 crop 在 base 中的左上原点像素坐标
//   swift Scripts/tools/imgalign.swift crop <in> <out> <x> <y> <w> <h>
//       按左上原点裁图
//   swift Scripts/tools/imgalign.swift diff <a> <b> <heat.png>
//       同尺寸逐像素比较，输出统计并导出差异热力图

import Foundation
import CoreGraphics
import ImageIO
import CoreFoundation

typealias Img = (w: Int, h: Int, g: [Float])

func loadGray(_ path: String, down: Int) -> Img? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = max(1, img.width / down), h = max(1, img.height / down)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var g = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        let p = i * 4
        g[i] = 0.299 * Float(buf[p]) + 0.587 * Float(buf[p + 1]) + 0.114 * Float(buf[p + 2])
    }
    return (w, h, g)
}

/// 零均值归一化互相关：对整体亮度/对比度差异不敏感
func ncc(_ t: Img, _ b: Img, _ ox: Int, _ oy: Int) -> Float {
    let cnt = Float(t.w * t.h)
    var sumT: Float = 0, sumB: Float = 0
    var sumTT: Float = 0, sumBB: Float = 0, sumTB: Float = 0
    for y in 0..<t.h {
        let trow = y * t.w
        let brow = (y + oy) * b.w + ox
        for x in 0..<t.w {
            let p = t.g[trow + x], q = b.g[brow + x]
            sumT += p; sumB += q
            sumTT += p * p; sumBB += q * q; sumTB += p * q
        }
    }
    let cov = sumTB - sumT * sumB / cnt
    let varT = sumTT - sumT * sumT / cnt
    let varB = sumBB - sumB * sumB / cnt
    let den = (varT * varB).squareRoot()
    return den > 1e-6 ? cov / den : 0
}

func cmdFind(cropPath: String, basePath: String) {
    guard let t16 = loadGray(cropPath, down: 16), let b16 = loadGray(basePath, down: 16),
          t16.w <= b16.w, t16.h <= b16.h else { print("尺寸不匹配"); exit(1) }
    var best: (Int, Int, Float) = (0, 0, -2)
    for oy in 0...(b16.h - t16.h) {
        for ox in 0...(b16.w - t16.w) {
            let s = ncc(t16, b16, ox, oy)
            if s > best.2 { best = (ox, oy, s) }
        }
    }
    var cur = best, prevDown = 16
    for down in [8, 4, 2, 1] {
        guard let tt = loadGray(cropPath, down: down), let bb = loadGray(basePath, down: down) else { break }
        let c = (cur.0 * prevDown / down, cur.1 * prevDown / down)
        var lbest = (c.0, c.1, -2 as Float)
        for oy in (c.1 - 3)...(c.1 + 3) {
            for ox in (c.0 - 3)...(c.0 + 3) {
                if ox >= 0, oy >= 0, ox + tt.w <= bb.w, oy + tt.h <= bb.h {
                    let s = ncc(tt, bb, ox, oy)
                    if s > lbest.2 { lbest = (ox, oy, s) }
                }
            }
        }
        cur = lbest
        prevDown = down
    }
    print(String(format: "offset=(%d,%d) NCC=%.5f", cur.0, cur.1, cur.2))
}

func cmdCrop(_ a: [String]) {
    guard a.count >= 8,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let x = Int(a[4]), let y = Int(a[5]), let w = Int(a[6]), let h = Int(a[7]) else {
        print("usage: crop in out x y w h"); exit(2)
    }
    let rect = CGRect(x: x, y: y, width: w, height: h)
        .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    guard let out = img.cropping(to: rect),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, out, nil)
    _ = CGImageDestinationFinalize(dest)
    print("cropped \(rect) from \(img.width)x\(img.height)")
}

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

func cmdDiff(_ a: [String]) {
    guard a.count >= 5, let A = loadRGBA(a[2]), let B = loadRGBA(a[3]) else {
        print("usage: diff a b heat"); exit(2)
    }
    let w = min(A.w, B.w), h = min(A.h, B.h)
    var heat = [UInt8](repeating: 255, count: w * h * 4)
    var sum = 0.0, over8 = 0, over32 = 0, mx = 0
    for y in 0..<h {
        for x in 0..<w {
            let ai = (y * A.w + x) * 4, bi = (y * B.w + x) * 4
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(A.px[ai + c]) - Int(B.px[bi + c]))) }
            sum += Double(d)
            if d > 8 { over8 += 1 }
            if d > 32 { over32 += 1 }
            mx = max(mx, d)
            let hi = (y * w + x) * 4
            heat[hi] = UInt8(min(255, d * 3)); heat[hi + 1] = UInt8(min(255, d))
            heat[hi + 2] = UInt8(min(255, d / 2)); heat[hi + 3] = 255
        }
    }
    let n = Double(w * h)
    print(String(format: "%dx%d 平均差=%.2f >8:%.2f%% >32:%.2f%% 最大差=%d",
                 w, h, sum / n, Double(over8) / n * 100, Double(over32) / n * 100, mx))
    if let cs = CGColorSpace(name: CGColorSpace.sRGB),
       let ctx = CGContext(data: &heat, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
       let img = ctx.makeImage(),
       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[4]) as CFURL,
                                                  "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, img, nil)
        _ = CGImageDestinationFinalize(dest)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: imgalign find|crop|diff ..."); exit(2)
}
switch args[1] {
case "find": guard args.count >= 4 else { exit(2) }; cmdFind(cropPath: args[2], basePath: args[3])
case "crop": cmdCrop(args)
case "diff": cmdDiff(args)
default: print("未知子命令 \(args[1])"); exit(2)
}
