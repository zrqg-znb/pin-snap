import Cocoa
import Vision

/// 纯本地文字识别。截图工具栏的「提取文字」和截图历史的索引都走这里。
enum TextRecognitionService {
    private static let maximumDimension: CGFloat = 1800

    /// 识别一张 CGImage。超大图先等比缩小，避免阻塞编辑器交互；
    /// 缩小只用于识别，不影响原图保存、复制和导出。
    static func recognizeText(in image: CGImage) -> String {
        let prepared = downscaleIfNeeded(image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

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
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
