// cua — computer-use helper for macOS.
// All coordinates are in global display POINTS (Quartz space: origin = top-left
// of the main display, y grows downward). This matches CGEvent, CGWindowList,
// and screencapture -R.
//
// Subcommands:
//   info  pos  move  click  rclick  dclick  drag  scroll  type  key  hotkey
//   windows  grid  shot  do  overlay
//
// Input commands notify the cua-overlay daemon (purple on-screen ring) via a
// unix datagram socket; the daemon auto-starts on first use.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

let CUA_VERSION = "1.0.0"
let eventTap = CGEventTapLocation.cghidEventTap
let src = CGEventSource(stateID: .hidSystemState)
let OVERLAY_SOCK = "/tmp/cua-overlay.sock"

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("cua: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func point(_ args: [String], _ i: Int) -> CGPoint {
    guard args.count > i + 1, let x = Double(args[i]), let y = Double(args[i + 1]) else {
        fail("expected x y coordinates")
    }
    return CGPoint(x: x, y: y)
}

func post(_ e: CGEvent?) {
    guard let e = e else { fail("could not create CGEvent") }
    e.post(tap: eventTap)
}

// MARK: - overlay notifications

func overlayBin() -> String? {
    let argv0 = CommandLine.arguments[0]
    var candidates: [String] = []
    if argv0.contains("/") {
        candidates.append((argv0 as NSString).deletingLastPathComponent + "/cua-overlay")
    }
    for d in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        candidates.append(String(d) + "/cua-overlay")
    }
    candidates.append(NSHomeDirectory() + "/.local/share/cua/bin/cua-overlay")
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func spawnOverlay() {
    guard let path = overlayBin() else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    try? p.run()   // detached: daemon survives this process exiting
}

func notifyOverlay(_ msg: String, allowSpawn: Bool = true) {
    let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = OVERLAY_SOCK.utf8CString.map { UInt8(bitPattern: $0) }
    withUnsafeMutableBytes(of: &addr.sun_path) { ptr in ptr.copyBytes(from: pathBytes) }
    let sent = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, msg, msg.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    // ENOENT = no socket file; ECONNREFUSED = stale socket, nobody listening.
    if sent < 0, allowSpawn, errno == ENOENT || errno == ECONNREFUSED {
        spawnOverlay()
        usleep(400_000)
        notifyOverlay(msg, allowSpawn: false)
    }
}

func curPos() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func notifyPos(_ p: CGPoint, kind: String = "pos") {
    notifyOverlay("\(kind) \(Int(p.x.rounded())) \(Int(p.y.rounded()))")
}

// MARK: - mouse

func moveTo(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)
    post(e)
    usleep(15_000)
}

func mouse(_ type: CGEventType, _ p: CGPoint, _ btn: CGMouseButton, _ count: Int64 = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: type,
                    mouseCursorPosition: p, mouseButton: btn)
    e?.setIntegerValueField(.mouseEventClickState, value: count)
    post(e)
}

// MARK: - key tables

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
    "backspace": 51, "esc": 53, "escape": 53, "fwddelete": 117,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pgup": 116, "pageup": 116,
    "pgdn": 121, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
    "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
    "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
    "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
    "7": 26, "8": 28, "9": 25,
    "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
    ",": 43, ".": 47, "/": 44, "`": 50,
]

let modFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "shift": .maskShift,
    "opt": .maskAlternate, "alt": .maskAlternate, "option": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl,
    "fn": .maskSecondaryFn,
]

func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    down?.flags = flags
    post(down)
    usleep(12_000)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    up?.flags = []
    post(up)
    usleep(12_000)
}

// MARK: - display/window helpers

func displays() -> [[String: Any]] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.enumerated().map { (i, d) in
        let b = CGDisplayBounds(d)
        let mode = CGDisplayCopyDisplayMode(d)
        let pw = mode?.pixelWidth ?? Int(b.width)
        let ph = mode?.pixelHeight ?? Int(b.height)
        return [
            "index": i, "id": Int(d),
            "x": Double(b.origin.x), "y": Double(b.origin.y),
            "w": Double(b.size.width), "h": Double(b.size.height),
            "pixel_w": pw, "pixel_h": ph,
            "scale": pw / Int(b.width),
            "is_main": CGDisplayIsMain(d) != 0,
        ]
    }
}

func windowList() -> [[String: Any]] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return [
            "id": w[kCGWindowNumber as String] as? Int ?? 0,
            "app": w[kCGWindowOwnerName as String] as? String ?? "",
            "title": w[kCGWindowName as String] as? String ?? "",
            "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
            "x": b["X"] ?? 0, "y": b["Y"] ?? 0,
            "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
        ]
    }
}

// MARK: - grid drawing (into current NSGraphicsContext; unflipped, y=0 bottom)

func drawGrid(w: Int, h: Int, ox: Double, oy: Double,
              lw: Double, lh: Double, spacing: Int = 100) {
    let sx = Double(w) / lw, sy = Double(h) / lh
    NSColor.systemYellow.withAlphaComponent(0.55).setStroke()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
        .foregroundColor: NSColor.systemYellow,
        .strokeColor: NSColor.black, .strokeWidth: -4,
    ]
    var gx = (ox / Double(spacing)).rounded(.up) * Double(spacing)
    while gx < ox + lw {
        let fx = (gx - ox) * sx
        let p = NSBezierPath()
        p.move(to: CGPoint(x: fx, y: 0)); p.line(to: CGPoint(x: fx, y: Double(h)))
        p.lineWidth = 1; p.stroke()
        String(Int(gx)).draw(at: CGPoint(x: fx + 3, y: Double(h) - 16),
                             withAttributes: attrs)
        gx += Double(spacing)
    }
    var gy = (oy / Double(spacing)).rounded(.up) * Double(spacing)
    while gy < oy + lh {
        let fy = (gy - oy) * sy
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 0, y: Double(h) - fy))
        p.line(to: CGPoint(x: Double(w), y: Double(h) - fy))
        p.lineWidth = 1; p.stroke()
        String(Int(gy)).draw(at: CGPoint(x: 3, y: Double(h) - fy - 15),
                             withAttributes: attrs)
        gy += Double(spacing)
    }
}

func newBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    guard let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("bitmap alloc failed") }
    return bmp
}

func writePNG(_ bmp: NSBitmapImageRep, _ path: String) {
    guard let png = bmp.representation(using: .png, properties: [:]) else {
        fail("png encode failed")
    }
    do { try png.write(to: URL(fileURLWithPath: path)) }
    catch { fail("write failed: \(error)") }
}

// MARK: - subcommands (a[0] = subcommand name)

func cmdInfo() {
    let data = try! JSONSerialization.data(withJSONObject: displays())
    print(String(data: data, encoding: .utf8)!)
}

func cmdPos() {
    let p = curPos()
    print("\(Int(p.x.rounded())),\(Int(p.y.rounded()))")
}

func cmdMove(_ a: [String]) {
    let p = point(a, 1)
    moveTo(p)
    notifyPos(p)
}

func cmdClick(_ a: [String], type: String) {
    let p = point(a, 1)
    moveTo(p)
    switch type {
    case "click":
        mouse(.leftMouseDown, p, .left); usleep(40_000); mouse(.leftMouseUp, p, .left)
    case "rclick":
        mouse(.rightMouseDown, p, .right); usleep(40_000); mouse(.rightMouseUp, p, .right)
    case "dclick":
        mouse(.leftMouseDown, p, .left, 1); mouse(.leftMouseUp, p, .left, 1)
        usleep(80_000)
        mouse(.leftMouseDown, p, .left, 2); mouse(.leftMouseUp, p, .left, 2)
    default: fail("unknown click type")
    }
    notifyPos(p, kind: "click")
}

func cmdDrag(_ a: [String]) {
    guard a.count >= 5 else { fail("usage: cua drag <x1> <y1> <x2> <y2>") }
    let from = point(a, 1), to = point(a, 3)
    moveTo(from)
    mouse(.leftMouseDown, from, .left)
    usleep(60_000)
    let steps = 24
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        mouse(.leftMouseDragged,
              CGPoint(x: from.x + (to.x - from.x) * t,
                      y: from.y + (to.y - from.y) * t), .left)
        usleep(8_000)
    }
    usleep(40_000)
    mouse(.leftMouseUp, to, .left)
    notifyPos(to, kind: "click")
}

func cmdScroll(_ a: [String]) {
    // positive dy scrolls down (content moves up); positive dx scrolls right.
    guard a.count >= 4, let dy = Int(a[3]) else {
        fail("usage: cua scroll <x> <y> <dy> [dx]")
    }
    let dx = a.count >= 5 ? Int(a[4])! : 0
    let p = point(a, 1)
    moveTo(p)
    let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                    wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(dx), wheel3: 0)
    e?.location = p
    post(e)
    notifyPos(p)
}

func cmdType(_ a: [String]) {
    guard a.count >= 2 else { fail("usage: cua type <text>") }
    let text = a[1...].joined(separator: " ")
    var chunk = ""
    for scalar in text.unicodeScalars {
        if chunk.utf16.count + String(scalar).utf16.count > 20 {
            typeChunk(chunk); chunk = ""
        }
        chunk.unicodeScalars.append(scalar)
    }
    if !chunk.isEmpty { typeChunk(chunk) }
    notifyPos(curPos())
}

func typeChunk(_ s: String) {
    var units = Array(s.utf16)
    units.withUnsafeMutableBufferPointer { buf in
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        post(down)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        post(up)
    }
    usleep(15_000)
}

func parseChord(_ s: String) -> (CGKeyCode, CGEventFlags) {
    let parts = s.lowercased().split(separator: "+").map { String($0) }
    var flags = CGEventFlags()
    var key: CGKeyCode? = nil
    for p in parts {
        if let f = modFlags[p] { flags.insert(f) }
        else if let k = keyCodes[p] { key = k }
        else { fail("unknown key/modifier: \(p)") }
    }
    guard let k = key else { fail("no key in chord: \(s)") }
    return (k, flags)
}

func cmdKey(_ a: [String]) {
    guard a.count >= 2 else { fail("usage: cua key <name>") }
    let (code, _) = parseChord(a[1])
    press(code)
    notifyPos(curPos())
}

func cmdHotkey(_ a: [String]) {
    guard a.count >= 2 else { fail("usage: cua hotkey <mods+key> e.g. cmd+c") }
    let (code, flags) = parseChord(a[1])
    press(code, flags)
    notifyPos(curPos())
}

func cmdWindows() {
    let data = try! JSONSerialization.data(withJSONObject: windowList())
    print(String(data: data, encoding: .utf8)!)
}

// Overlay a global-coordinate grid on an existing PNG:
//   cua grid <file.png> <ox> <oy> <lw> <lh> [spacing] [-o out]
func cmdGrid(_ a: [String]) {
    guard a.count >= 6 else {
        fail("usage: cua grid <file.png> <ox> <oy> <lw> <lh> [spacing] [-o out]")
    }
    let path = a[1]
    let ox = Double(a[2])!, oy = Double(a[3])!
    let lw = Double(a[4])!, lh = Double(a[5])!
    var spacing = 100
    var outPath = (path as NSString).deletingPathExtension + "-grid.png"
    var i = 6
    while i < a.count {
        if a[i] == "-o", i + 1 < a.count { outPath = a[i + 1]; i += 2 }
        else if let s = Int(a[i]) { spacing = s; i += 1 }
        else { i += 1 }
    }
    guard let img = NSImage(contentsOfFile: path),
          let rep = img.representations.first else { fail("cannot load \(path)") }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let bmp = newBitmap(w, h)
    bmp.size = img.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
    img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    drawGrid(w: w, h: h, ox: ox, oy: oy, lw: lw, lh: lh, spacing: spacing)
    NSGraphicsContext.restoreGraphicsState()
    writePNG(bmp, outPath)
    print(outPath)
}

// MARK: shot — capture + downscale + grid + JSON, all in-process.

let MAX_SHOT_W = 1568   // match the image render width of the `read` tool

func shotsDir() -> String {
    // CUA_HOME override, else a stable location independent of clone path.
    let home = ProcessInfo.processInfo.environment["CUA_HOME"]
        ?? NSHomeDirectory() + "/.local/share/cua"
    let dir = home + "/shots"
    try? FileManager.default.createDirectory(atPath: dir,
            withIntermediateDirectories: true)
    return dir
}

func pruneShots() {
    let dir = shotsDir()
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
    let files = names.filter { $0.hasSuffix(".png") }
        .map { dir + "/" + $0 }
        .sorted {
            (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date)
                ?? .distantPast >
            (try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date)
                ?? .distantPast
        }
    for f in files.dropFirst(20) { try? fm.removeItem(atPath: f) }
}

// One-shot capture via ScreenCaptureKit. `source` is in display-local points;
// `outW/outH` set the output pixel size (downscale happens inside SCK).
func captureImage(displayID: CGDirectDisplayID, source: CGRect,
                  outW: Int, outH: Int) -> CGImage {
    var img: CGImage? = nil
    var capErr: Error? = nil
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let content = try await SCShareableContent.current
            guard let disp = content.displays.first(where: {
                $0.displayID == displayID
            }) else { throw NSError(domain: "cua", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "display gone"]) }
            let filter = SCContentFilter(display: disp, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = source
            cfg.width = outW; cfg.height = outH
            cfg.showsCursor = false
            img = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        } catch { capErr = error }
        sem.signal()
    }
    sem.wait()
    guard let i = img else {
        fail("capture failed: \(capErr?.localizedDescription ?? "unknown") — Screen Recording permission?")
    }
    return i
}

func captureWindowImage(_ winID: CGWindowID, outW: Int, outH: Int) -> CGImage {
    var img: CGImage? = nil
    var capErr: Error? = nil
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let content = try await SCShareableContent.current
            guard let w = content.windows.first(where: {
                $0.windowID == winID
            }) else { throw NSError(domain: "cua", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "window gone"]) }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            cfg.width = outW; cfg.height = outH
            cfg.showsCursor = false
            img = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        } catch { capErr = error }
        sem.signal()
    }
    sem.wait()
    guard let i = img else {
        fail("window capture failed: \(capErr?.localizedDescription ?? "unknown")")
    }
    return i
}

// Produce a shot JSON {path(gridded), clean_path, origin_x, origin_y,
// logical_w, logical_h, img_w, img_h, ...}. `cg` is already at view size.
func emitShot(_ cg: CGImage, ox: Double, oy: Double, lw: Double, lh: Double,
              extra: [String: Any], tag: String) {
    let tw = cg.width, th = cg.height
    let dir = shotsDir()
    let ts = String(format: "%06d", Int(Date().timeIntervalSince1970 * 1000) % 100_000_000)
    let cleanPath = "\(dir)/shot-\(ts)-\(tag).png"
    let gridPath = "\(dir)/shot-\(ts)-\(tag)-grid.png"

    let bmp = newBitmap(tw, th)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
    NSImage(cgImage: cg, size: NSSize(width: tw, height: th))
        .draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    writePNG(bmp, cleanPath)

    drawGridOnto(bmp, ox: ox, oy: oy, lw: lw, lh: lh)
    writePNG(bmp, gridPath)

    var result: [String: Any] = [
        "path": gridPath, "clean_path": cleanPath,
        "origin_x": ox, "origin_y": oy,
        "logical_w": lw, "logical_h": lh, "img_w": tw, "img_h": th,
    ]
    result.merge(extra) { _, new in new }
    let data = try! JSONSerialization.data(withJSONObject: result)
    print(String(data: data, encoding: .utf8)!)
}

func drawGridOnto(_ bmp: NSBitmapImageRep, ox: Double, oy: Double,
                  lw: Double, lh: Double) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
    drawGrid(w: bmp.pixelsWide, h: bmp.pixelsHigh, ox: ox, oy: oy,
             lw: lw, lh: lh)
    NSGraphicsContext.restoreGraphicsState()
}

func cmdShot(_ a: [String]) {
    let disps = displays()
    guard !disps.isEmpty else { fail("no displays") }
    var i = 1
    var mode = "cursor"   // cursor | display | region | window
    var dIdx = -1
    var rect = CGRect.zero
    var winID: CGWindowID = 0
    while i < a.count {
        switch a[i] {
        case "-d":
            guard i + 1 < a.count, let n = Int(a[i + 1]) else { fail("-d needs index") }
            mode = "display"; dIdx = n; i += 2
        case "-r":
            guard i + 1 < a.count else { fail("-r needs x,y,w,h") }
            let v = a[i + 1].split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { fail("-r x,y,w,h") }
            mode = "region"
            rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]); i += 2
        case "-w":
            guard i + 1 < a.count, let n = Int(a[i + 1]) else { fail("-w needs id") }
            mode = "window"; winID = CGWindowID(n); i += 2
        default:
            fail("unknown arg \(a[i])")
        }
    }

    func dispBounds(_ d: [String: Any]) -> CGRect {
        CGRect(x: d["x"] as! Double, y: d["y"] as! Double,
               width: d["w"] as! Double, height: d["h"] as! Double)
    }
    func containing(_ p: CGPoint) -> [String: Any] {
        disps.first { dispBounds($0).contains(p) }
            ?? disps.first { ($0["is_main"] as? Bool) == true } ?? disps[0]
    }
    // output px size for a logical w×h, capped at MAX_SHOT_W
    func outSize(_ lw: Double, _ lh: Double) -> (Int, Int) {
        let t = min(1.0, Double(MAX_SHOT_W) / lw)
        return (Int((lw * t).rounded()), Int((lh * t).rounded()))
    }
    // capture `rect` (global pts) from the display that contains it
    func shotRect(_ rect: CGRect, extra: [String: Any], tag: String) {
        let d = containing(CGPoint(x: rect.midX, y: rect.midY))
        let db = dispBounds(d)
        let src = rect.offsetBy(dx: -db.origin.x, dy: -db.origin.y)
        let (ow, oh) = outSize(Double(rect.width), Double(rect.height))
        let cg = captureImage(displayID: CGDirectDisplayID(d["id"] as! Int),
                              source: src, outW: ow, outH: oh)
        emitShot(cg, ox: Double(rect.origin.x), oy: Double(rect.origin.y),
                 lw: Double(rect.width), lh: Double(rect.height),
                 extra: extra.merging(
                    ["display": d["index"] as! Int]) { a, _ in a }, tag: tag)
    }

    switch mode {
    case "window":
        guard let w = windowList().first(where: {
            ($0["id"] as? Int) == Int(winID)
        }) else { fail("window \(winID) not on screen") }
        let lw = w["w"] as! Double, lh = w["h"] as! Double
        let (ow, oh) = outSize(lw, lh)
        let cg = captureWindowImage(winID, outW: ow, outH: oh)
        emitShot(cg, ox: w["x"] as! Double, oy: w["y"] as! Double,
                 lw: lw, lh: lh, extra: ["window": w], tag: "w\(winID)")
    case "region":
        shotRect(rect, extra: [:], tag: "r")
    case "display":
        guard dIdx >= 0 && dIdx < disps.count else { fail("no display index \(dIdx)") }
        let d = disps[dIdx]
        shotRect(dispBounds(d),
                 extra: ["scale": d["scale"] as! Int], tag: "d\(dIdx)")
    default: // display under cursor
        let d = containing(curPos())
        shotRect(dispBounds(d),
                 extra: ["scale": d["scale"] as! Int],
                 tag: "d\(d["index"] as! Int)")
    }
    pruneShots()
}

// MARK: do — batch subcommands in one process: cua do 'click 1 2' 'type hi' ...

func cmdDo(_ a: [String]) {
    guard a.count >= 2 else { fail("usage: cua do '<cmd>' ['<cmd>' ...]") }
    for s in a[1...] {
        let parts = s.split(separator: " ").map(String.init)
        runSub(parts)
    }
}

// MARK: overlay — control the cursor-ring daemon

func cmdOverlay(_ a: [String]) {
    let action = a.count > 1 ? a[1] : "status"
    switch action {
    case "on":
        spawnOverlay(); print("overlay on")
    case "off":
        notifyOverlay("quit")
        let pk = Process()
        pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pk.arguments = ["-x", "cua-overlay"]
        try? pk.run(); pk.waitUntilExit()
        print("overlay off")
    case "hide": notifyOverlay("hide")
    case "show": notifyOverlay("show")
    default:
        let pg = Process()
        let pipe = Pipe()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-x", "cua-overlay"]
        pg.standardOutput = pipe
        try? pg.run(); pg.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        print(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? "overlay not running" : "overlay running (pid \(out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
}

// MARK: doctor — self-diagnostics

func cmdDoctor() {
    var ok = true
    func check(_ name: String, _ pass: Bool, _ hint: String = "") {
        let mark = pass ? "✓" : "✗"
        let extra = pass || hint.isEmpty ? "" : " — " + hint
        print("\(mark) \(name)\(extra)")
        if !pass { ok = false }
    }

    // Screen Recording: try a 4x4 capture of the main display.
    var screenOK = false
    if let d = displays().first {
        let cg = tryCapture(displayID: CGDirectDisplayID(d["id"] as! Int))
        screenOK = cg != nil
    }
    check("Screen Recording", screenOK,
          "grant Devin Screen Recording in System Settings → Privacy & Security")

    // Accessibility: whether synthetic input is trusted.
    check("Accessibility", AXIsProcessTrusted(),
          "grant Devin Accessibility in System Settings → Privacy & Security")

    // Displays
    let n = displays().count
    check("Displays enumerated (\(n))", n > 0)

    // shots dir writable
    let dir = shotsDir()
    let probe = dir + "/.doctor-probe"
    let wOK = (try? "x".write(toFile: probe, atomically: true,
                              encoding: .utf8)) != nil
    if wOK { try? FileManager.default.removeItem(atPath: probe) }
    check("Shots dir writable (\(dir))", wOK)

    // overlay binary + daemon
    check("cua-overlay binary found", overlayBin() != nil,
          "run build.sh in the repo")
    check("overlay daemon running", overlayRunning(),
          "it auto-starts on first input command, or `cua overlay on`")

    // PATH
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    check("~/.local/bin on PATH", path.contains(".local/bin"),
          "add ~/.local/bin to PATH")

    print(ok ? "doctor: all good" : "doctor: issues found")
    if !ok { exit(1) }
}

func tryCapture(displayID: CGDirectDisplayID) -> CGImage? {
    var img: CGImage? = nil
    let sem = DispatchSemaphore(value: 0)
    Task {
        if let content = try? await SCShareableContent.current,
           let disp = content.displays.first(where: { $0.displayID == displayID }) {
            let filter = SCContentFilter(display: disp, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: 0, y: 0, width: 8, height: 8)
            cfg.width = 8; cfg.height = 8
            img = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
        }
        sem.signal()
    }
    sem.wait()
    return img
}

func overlayRunning() -> Bool {
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-x", "cua-overlay"]
    pg.standardOutput = Pipe()
    try? pg.run(); pg.waitUntilExit()
    return pg.terminationStatus == 0
}

// MARK: - dispatch

func runSub(_ a: [String]) {
    guard let cmd = a.first else { return }
    switch cmd {
    case "info": cmdInfo()
    case "pos": cmdPos()
    case "move": cmdMove(a)
    case "click", "rclick", "dclick": cmdClick(a, type: cmd)
    case "drag": cmdDrag(a)
    case "scroll": cmdScroll(a)
    case "type": cmdType(a)
    case "key": cmdKey(a)
    case "hotkey": cmdHotkey(a)
    case "windows": cmdWindows()
    case "grid": cmdGrid(a)
    case "shot": cmdShot(a)
    case "do": cmdDo(a)
    case "overlay": cmdOverlay(a)
    case "doctor": cmdDoctor()
    case "version", "--version", "-v": print("cua \(CUA_VERSION)")
    case "sleep":
        if a.count >= 2, let ms = Int(a[1]) { usleep(UInt32(ms) * 1000) }
    default: fail("unknown subcommand \(cmd)")
    }
}

func usage() -> Never {
    print("""
    cua — computer-use input/display helper (all coords in global points)

      cua info                         displays as JSON (x,y,w,h,scale — Quartz space)
      cua pos                          print cursor "x,y"
      cua move <x> <y>                 move cursor
      cua click <x> <y>                left click
      cua rclick <x> <y>               right click
      cua dclick <x> <y>               double click
      cua drag <x1> <y1> <x2> <y2>     left-button drag
      cua scroll <x> <y> <dy> [dx]     scroll at point (dy>0 down, dx>0 right)
      cua type <text>                  type text (full Unicode)
      cua key <name>                   return,tab,space,esc,delete,arrows,f1-f12,home,end,pgup,pgdn
      cua hotkey <mods+key>            e.g. cmd+c, cmd+shift+4, cmd+space
      cua windows                      on-screen windows as JSON (id,app,title,bounds)
      cua shot [-d N|-r x,y,w,h|-w id] capture+grid+JSON in one step (fast path)
      cua grid <f.png> <ox> <oy> <lw> <lh> [px]  overlay grid on existing PNG
      cua do '<cmd>' ['<cmd>' ...]     batch actions in one call, e.g.
                                       cua do 'click 500 300' 'type hi' 'key return' 'shot'
      cua sleep <ms>                   wait (useful inside `do`)
      cua overlay on|off|status        Devin's on-screen cursor ring
      cua doctor                       check permissions + setup
      cua version                      print version
    """)
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
if args[0] == "-h" || args[0] == "--help" || args[0] == "help" { usage() }
runSub(args)
