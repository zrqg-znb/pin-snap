import Cocoa

struct CaptureSnapshot {
    let image: CGImage
    let pixelSize: CGSize
    let screenFrame: NSRect
    let scale: CGFloat

    var pointSize: NSSize { NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }
}
