#!/usr/bin/env swift
import Cocoa
import Foundation

// Dump Cocoa present state for Wine NSWindows (run via lldb `expr` or as inject helper).
// Standalone: lists CGWindowList wine windows + captures alpha sample via screencapture -l.

let args = CommandLine.arguments
let shotDir = args.count > 1 ? args[1] : "/tmp/fly-present-probe"
try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)

let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    fputs("no window list\n", stderr)
    exit(1)
}

var targets: [(id: Int, pid: Int, w: Int, h: Int, name: String)] = []
for w in info {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let lo = owner.lowercased()
    guard lo.contains("wine") else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any]
    let ww = Int(b?["Width"] as? Double ?? 0)
    let hh = Int(b?["Height"] as? Double ?? 0)
    let a = w[kCGWindowAlpha as String] as? Double ?? -1
    print("id=\(id) pid=\(pid) \(ww)x\(hh) α=\(String(format: "%.2f", a)) name=\(name)")
    if ww >= 600 && hh >= 400 {
        targets.append((id, pid, ww, hh, name))
    }
}

for t in targets {
    let path = "\(shotDir)/win-\(t.id)-\(t.w)x\(t.h).png"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-x", "-l", String(t.id), path]
    try? proc.run()
    proc.waitUntilExit()
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
    // Sample corner + center alpha via `sips` / quick CGImage read
    var opaque = 0, transparent = 0, nonzero = 0
    if let url = URL(string: "file://\(path)"),
       let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
       let data = img.dataProvider?.data,
       let ptr = CFDataGetBytePtr(data) {
        let w = img.width, h = img.height, bpr = img.bytesPerRow
        let pts = [(0, 0), (w/2, h/2), (w-1, h-1), (10, 10), (w/2, 10)]
        for (x, y) in pts {
            let o = y * bpr + x * 4
            let r = Int(ptr[o]), g = Int(ptr[o+1]), b = Int(ptr[o+2]), a = Int(ptr[o+3])
            print("  sample(\(x),\(y))=RGBA(\(r),\(g),\(b),\(a))")
            if a == 0 { transparent += 1 }
            else if a == 255 { opaque += 1 }
            if r|g|b != 0 { nonzero += 1 }
        }
    }
    print("  file=\(path) bytes=\(size) opaqueSamples=\(opaque) transparentSamples=\(transparent) nonzeroRGB=\(nonzero)")
}

if targets.isEmpty {
    fputs("no large wine windows\n", stderr)
    exit(2)
}
