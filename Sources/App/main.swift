import Cocoa

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// .accessory：常驻菜单栏，不占 Dock。
application.setActivationPolicy(.accessory)
application.run()
