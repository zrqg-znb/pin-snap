import Cocoa

enum AnnotationTool: Int, CaseIterable {
    case rectangle
    case arrow
    case number
    case pen
    case text
    case mosaic

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .arrow: return "箭头"
        case .number: return "编号"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    /// 参考图里的细线图标符号；必须是有效的 SF Symbol，否则图标会是空白。
    var symbol: String {
        switch self {
        case .rectangle: return "square"
        case .arrow: return "arrow.up.right"
        case .number: return "1.circle"
        case .pen: return "pencil.tip"
        case .text: return "textformat.size"
        case .mosaic: return "checkerboard.rectangle"
        }
    }
}

enum AnnotationKind {
    case rectangle
    case arrow
    case number(Int)
    case pen
    case text(String)
    case mosaic
}

struct Annotation {
    var kind: AnnotationKind
    var start: NSPoint
    var end: NSPoint
    var points: [NSPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var textFontSize: CGFloat = AnnotationRenderer.defaultTextFontSize

    var bounds: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

final class PixelSampler {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private let data: UnsafeMutablePointer<UInt8>

    init?(image: CGImage) {
        width = image.width
        height = image.height
        bytesPerRow = width * 4
        let count = bytesPerRow * height
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        data.initialize(repeating: 0, count: count)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            data.deallocate()
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit { data.deallocate() }

    func color(at pixelX: Int, pixelY: Int) -> NSColor {
        let x = min(max(pixelX, 0), width - 1)
        let y = min(max(pixelY, 0), height - 1)
        let offset = y * bytesPerRow + x * 4
        let b = CGFloat(data[offset]) / 255
        let g = CGFloat(data[offset + 1]) / 255
        let r = CGFloat(data[offset + 2]) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}

enum AnnotationRenderer {
    static let mosaicBlock: CGFloat = 12
    static let penWidth: CGFloat = 3
    static let lineWidth: CGFloat = 3
    static let defaultTextFontSize: CGFloat = 22

    static func draw(_ annotation: Annotation,
                     offset: NSPoint,
                     sampler: PixelSampler?,
                     samplerOrigin: NSPoint,
                     scale: CGFloat) {
        switch annotation.kind {
        case .rectangle:
            let rect = annotation.bounds.offsetBy(dx: offset.x, dy: offset.y)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = annotation.lineWidth
            annotation.color.setStroke()
            path.stroke()

        case .arrow:
            drawArrow(from: NSPoint(x: annotation.start.x + offset.x, y: annotation.start.y + offset.y),
                      to: NSPoint(x: annotation.end.x + offset.x, y: annotation.end.y + offset.y),
                      color: annotation.color,
                      lineWidth: annotation.lineWidth)

        case .number(let value):
            drawNumber(value,
                      at: NSPoint(x: annotation.start.x + offset.x, y: annotation.start.y + offset.y),
                      color: annotation.color)

        case .pen:
            guard annotation.points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = annotation.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: annotation.points[0].x + offset.x, y: annotation.points[0].y + offset.y))
            for point in annotation.points.dropFirst() {
                path.line(to: NSPoint(x: point.x + offset.x, y: point.y + offset.y))
            }
            annotation.color.setStroke()
            path.stroke()

        case .text(let text):
            guard !text.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.textFontSize, weight: .semibold),
                .foregroundColor: annotation.color
            ]
            text.draw(at: NSPoint(x: annotation.start.x + offset.x, y: annotation.start.y + offset.y),
                      withAttributes: attributes)

        case .mosaic:
            drawMosaic(annotation, offset: offset, sampler: sampler, samplerOrigin: samplerOrigin, scale: scale)
        }
    }

    /// 从起点指向终点的箭头：轴线 + 两侧箭羽，颜色与线宽跟随当前标注样式。
    static func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, lineWidth: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        let angle = atan2(dy, dx)
        let headLength = min(max(lineWidth * 6, 13), length * 0.55)
        let headSpread = CGFloat.pi / 6
        // 轴线收到箭羽根部，避免线宽在尖端糊成一团。
        let shaftEnd = NSPoint(x: end.x - cos(angle) * headLength * 0.72,
                               y: end.y - sin(angle) * headLength * 0.72)

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .miter
        path.move(to: start)
        path.line(to: shaftEnd)

        let left = NSPoint(x: end.x - cos(angle - headSpread) * headLength,
                           y: end.y - sin(angle - headSpread) * headLength)
        let right = NSPoint(x: end.x - cos(angle + headSpread) * headLength,
                            y: end.y - sin(angle + headSpread) * headLength)
        path.move(to: left)
        path.line(to: end)
        path.line(to: right)

        color.setStroke()
        path.stroke()
    }

    static func drawNumber(_ value: Int, at point: NSPoint, color: NSColor) {
        let radius: CGFloat = 14
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let label = "\(value)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                   withAttributes: attributes)
    }

    private static func drawMosaic(_ annotation: Annotation,
                                   offset: NSPoint,
                                   sampler: PixelSampler?,
                                   samplerOrigin: NSPoint,
                                   scale: CGFloat) {
        guard let sampler else { return }
        let rect = annotation.bounds
        guard rect.width > 1, rect.height > 1 else { return }
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let width = min(mosaicBlock, rect.maxX - x)
                let height = min(mosaicBlock, rect.maxY - y)
                let block = NSRect(x: x + offset.x, y: y + offset.y, width: width, height: height)
                let sampleX = Int((x + width / 2 - samplerOrigin.x) * scale)
                let sampleY = Int((y + height / 2 - samplerOrigin.y) * scale)
                sampler.color(at: sampleX, pixelY: sampleY).setFill()
                NSBezierPath(rect: block).fill()
                x += mosaicBlock
            }
            y += mosaicBlock
        }
    }
}

extension CGContext {
    /// 在当前「左上原点、y 向下」的坐标系里把 CGImage 正向铺满 rect。
    ///
    /// 直接走 CGContext 而不经过 NSImage 缓存：调用方可以明确指定插值质量，
    /// 在 1:1 时用 `.none` 就能保证像素级直出，不会被额外重采样糊掉。
    func drawUprightCGImage(_ image: CGImage, in rect: CGRect, quality: CGInterpolationQuality) {
        guard rect.width > 0, rect.height > 0 else { return }
        saveGState()
        interpolationQuality = quality
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
