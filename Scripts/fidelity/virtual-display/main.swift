// Creates one HiDPI virtual display and keeps it alive until SIGTERM/SIGINT.
//
//   virtual-display [--points 1440x900]
//
// The display is `points` wide in points and twice that in pixels, so a window captured on it
// comes out at exactly 2x. Prints one line once the display is attached:
//
//   virtual-display ready id=<CGDirectDisplayID> origin=<x>,<y> points=<w>x<h>
//
// Dev-only (private CoreGraphics SPI). Never shipped; runs only while a capture runs.
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("virtual-display: \(message)\n".utf8))
    exit(1)
}

func parsePoints(_ arguments: [String]) -> (width: UInt32, height: UInt32) {
    guard let flag = arguments.firstIndex(of: "--points") else { return (1440, 900) }
    let parts = arguments.dropFirst(flag + 1).first?.split(separator: "x").compactMap { UInt32($0) } ?? []
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--points expects WxH, e.g. 1440x900") }
    return (parts[0], parts[1])
}

let points = parsePoints(CommandLine.arguments)

let descriptor = CGVirtualDisplayDescriptor()
descriptor.queue = DispatchQueue.main
descriptor.name = "Ghast Fidelity"
descriptor.maxPixelsWide = points.width * 2
descriptor.maxPixelsHigh = points.height * 2
descriptor.sizeInMillimeters = CGSize(width: 25.4 * Double(points.width) / 110, height: 25.4 * Double(points.height) / 110)
descriptor.productID = 0x6768
descriptor.vendorID = 0x6768
descriptor.serialNum = 0x0001
descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
descriptor.terminationHandler = { _, _ in fail("the display was torn down by the system") }

guard let display = CGVirtualDisplay(descriptor: descriptor) else { fail("the system refused to create a virtual display") }

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 1
settings.modes = [CGVirtualDisplayMode(width: points.width, height: points.height, refreshRate: 60)]
guard display.apply(settings) else { fail("apply(settings) was refused") }

let displayID = display.displayID

// Park it to the right of the main display so it never overlaps a real screen.
var config: CGDisplayConfigRef?
if CGBeginDisplayConfiguration(&config) == .success, let config {
    let main = CGDisplayBounds(CGMainDisplayID())
    CGConfigureDisplayOrigin(config, displayID, Int32(main.maxX), 0)
    CGCompleteDisplayConfiguration(config, .forSession)
}

// The mode list is applied asynchronously; wait until the display reports its size.
let deadline = Date().addingTimeInterval(10)
while CGDisplayBounds(displayID).width != Double(points.width), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
let bounds = CGDisplayBounds(displayID)
guard bounds.width == Double(points.width), bounds.height == Double(points.height) else {
    fail("display came up as \(Int(bounds.width))x\(Int(bounds.height)) pt, wanted \(points.width)x\(points.height)")
}

print("virtual-display ready id=\(displayID) origin=\(Int(bounds.minX)),\(Int(bounds.minY)) points=\(points.width)x\(points.height)")
fflush(stdout)

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { exit(0) }
    source.resume()
    signalSources.append(source)
}

withExtendedLifetime(display) { dispatchMain() }
