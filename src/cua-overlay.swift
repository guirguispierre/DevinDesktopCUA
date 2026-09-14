// cua-overlay — Devin's on-screen cursor. A borderless, click-through,
// always-on-top window drawing a purple ring at the agent's action points.
//
// Listens for datagrams on /tmp/cua-overlay.sock:
//   "pos <x> <y>"    move ring to global point (x,y) and show it
//   "click <x> <y>"  move ring + click ripple
//   "hide" / "show"  fade ring out / in
//   "quit"           exit
//
// The ring fades out automatically when the real cursor diverges from the
// ring (i.e. the human moved the mouse — the human is driving again).
import AppKit
import Foundation

let SOCK = "/tmp/cua-overlay.sock"
let RING: CGFloat = 60   // window size; ring drawn inside

final class RingView: NSView {
    var ripple: CGFloat = 0          // 0 = none, animates 0→1
    var ringColor = NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.94, alpha: 0.95)

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // white halo under-stroke for contrast on any background
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(5.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
        // main ring
        ctx.setStrokeColor(ringColor.cgColor)
        ctx.setLineWidth(3.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
        // center dot
        ctx.setFillColor(ringColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
        // click ripple
        if ripple > 0 {
            let r = 13 + ripple * 36
            let a = (1 - ripple) * 0.7
            ctx.setStrokeColor(ringColor.withAlphaComponent(a).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }
}

final class Overlay: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    var ring: RingView!
    var ringPos = CGPoint.zero
    var ringShown = false
    var lastDiverge = Date.distantPast
    var rippleT: CGFloat = 0
    var fd: Int32 = -1

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        ring = RingView(frame: NSRect(x: 0, y: 0, width: RING, height: RING))
        win = NSWindow(contentRect: ring.frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = ring
        win.alphaValue = 0
        win.orderFrontRegardless()

        listen()
        // 30 Hz housekeeping: ripple animation + fade when the human drives.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in self.tick() }
    }

    // MARK: socket

    func listen() {
        unlink(SOCK)
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { exit(1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = SOCK.utf8CString.map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in ptr.copyBytes(from: pathBytes) }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { exit(1) }   // already running — leave it alone
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
    }

    func drain() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var sa = sockaddr(); var len = socklen_t(MemoryLayout<sockaddr>.size)
            let n = recvfrom(fd, &buf, buf.count, MSG_DONTWAIT, &sa, &len)
            if n <= 0 { break }
            handle(String(decoding: buf[..<n], as: UTF8.self))
        }
    }

    func handle(_ msg: String) {
        let parts = msg.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        switch cmd {
        case "pos", "click":
            guard parts.count >= 3,
                  let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            moveRing(to: CGPoint(x: x, y: y))
            if cmd == "click" { rippleT = .leastNonzeroMagnitude }
        case "hide": win.animator().alphaValue = 0
        case "show": win.alphaValue = 1
        case "quit":
            unlink(SOCK)
            NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: cursor logic

    func mainHeight() -> CGFloat {
        NSScreen.screens.first?.frame.size.height ?? 0
    }

    func moveRing(to p: CGPoint) {
        ringPos = p
        // CGEvent coords: top-left origin. NSWindow: bottom-left of main screen.
        win.setFrameOrigin(NSPoint(x: p.x - RING / 2, y: mainHeight() - p.y - RING / 2))
        if !ringShown {
            ringShown = true
            win.animator().alphaValue = 1
        }
        lastDiverge = .distantPast
    }

    func tick() {
        if rippleT > 0 {
            rippleT += 0.055
            if rippleT >= 1 { rippleT = 0 }
            ring.ripple = rippleT
            ring.needsDisplay = true
        }
        guard ringShown, let e = CGEvent(source: nil) else { return }
        let real = e.location
        let d = hypot(real.x - ringPos.x, real.y - ringPos.y)
        if d > 15 {
            if lastDiverge == .distantPast { lastDiverge = Date() }
            if Date().timeIntervalSince(lastDiverge) > 0.4 {
                ringShown = false
                win.animator().alphaValue = 0
            }
        } else {
            lastDiverge = .distantPast
        }
    }
}

let app = NSApplication.shared
let delegate = Overlay()
app.delegate = delegate
app.run()
