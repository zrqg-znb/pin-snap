import Cocoa
import Vision

/// 纯本地文字识别。截图工具栏的「提取文字」和截图历史的索引都走这里。
///
/// 之前这里用的是 `.fast` + 关闭语言纠正，这是中文识别率归零的直接原因：
/// Vision 的快速通道只跑拉丁文字模型，中文会被硬当成英文猜，
/// 输出就成了 `È&IfiEI¥¥J` 这类乱码。中文必须走 `.accurate` 并开启语言纠正。
enum TextRecognitionService {
    /// 识别前的最长边上限。
    /// 截图多是 2x Retina（2880×1800），压到 1800 会让 12px 的终端小字糊成一团；
    /// 放到 3000 基本保留原始像素，同时仍能限制最坏情况下的耗时。
    private static let maximumDimension: CGFloat = 3000

    static func recognizeText(in image: CGImage) -> String {
        let prepared = downscaleIfNeeded(image)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 顺序代表优先级：界面截图以中文为主，英文单词（命令、变量名）作为第二语言。
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        if #available(macOS 13.0, *) {
            // Revision 3 对中文排版、混排和标点的处理明显好于默认版本。
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            NSLog("PinSnap OCR: failed \(error)")
            return ""
        }
    }

    private static func downscaleIfNeeded(_ image: CGImage) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maximumDimension else { return image }
        let scale = maximumDimension / longest
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        // 缩小时用高质量插值：小字号文字一旦糊了，中文识别会直接崩。
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
