// cua-guide — guided drag-and-drop animation for macOS permission panes.
//
// Opens a Privacy & Security pane in System Settings and plays a looping,
// click-through animation showing the agent app's icon being dragged into
// the permission list. Exits when the permission is granted, the settings
// window is closed, or the timeout elapses.
//
//   cua-guide screenrec|accessibility [--app /path/App.app] [--timeout sec] [--demo]
//
// --demo skips the permission check (for testing / screen recordings).
import AppKit
import CoreGraphics
import Foundation

enum Perm: String {
    case screenrec, accessibility

    var paneURL: String {
        switch self {
        case .screenrec:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }
    var label: String {
        switch self {
        case .screenrec:      return "Screen Recording"
        case .accessibility:  return "Accessibility"
        }
    }
    var granted: Bool {
        switch self {
        case .screenrec:      return CGPreflightScreenCaptureAccess()
        case .accessibility:  return AXIsProcessTrusted()
        }
    }
}

// ---------- args ----------
// (types can't capture top-level vars, so parsed config lives in Ctx)
enum Ctx {
    static var perm: Perm = .screenrec
    static var appPath = ""
    static var appName = "your agent app"
    static var appIcon = NSImage()
    static var timeout: TimeInterval = 600
    static var demo = false
}

var args = Array(CommandLine.arguments.dropFirst())
guard let permRaw = args.first, let perm = Perm(rawValue: permRaw) else {
    FileHandle.standardError.write(
        "usage: cua-guide screenrec|accessibility [--app path] [--timeout sec] [--demo]\n"
            .data(using: .utf8)!)
    exit(2)
}
Ctx.perm = perm
args.removeFirst()
Ctx.appPath = ProcessInfo.processInfo.environment["CUA_AGENT_APP"] ?? "/Applications/Devin.app"
var i = 0
while i < args.count {
    switch args[i] {
    case "--app" where i + 1 < args.count: Ctx.appPath = args[i + 1]; i += 1
    case "--timeout" where i + 1 < args.count:
        Ctx.timeout = TimeInterval(args[i + 1]) ?? 600; i += 1
    case "--demo": Ctx.demo = true
    default: break
    }
    i += 1
}
if !FileManager.default.fileExists(atPath: Ctx.appPath) { Ctx.appPath = "" }
Ctx.appName = Ctx.appPath.isEmpty ? "your agent app"
    : ((Ctx.appPath as NSString).lastPathComponent as NSString).deletingPathExtension
Ctx.appIcon = Ctx.appPath.isEmpty
    ? NSWorkspace.shared.icon(forFileType: "app")
    : NSWorkspace.shared.icon(forFile: Ctx.appPath)

// ---------- coordinate helpers ----------
// CGWindowList bounds are Quartz (top-left). Our window is Cocoa (bottom-left
// of primary screen). Convert via the primary screen height.
func quartzToCocoa(_ p: CGPoint) -> CGPoint {
    let h = NSScreen.screens.first?.frame.size.height ?? 0
    return CGPoint(x: p.x, y: h - p.y)
}

func settingsWindowRect() -> CGRect? {
    guard let pid = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.apple.systempreferences" })?
        .processIdentifier else { return nil }
    guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    var best: CGRect?; var bestArea: CGFloat = 0
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              r.width > 400, r.height > 300 else { continue }
        let area = r.width * r.height
        if area > bestArea { bestArea = area; best = r }
    }
    return best   // Quartz coords
}

// ---------- animated guide view ----------
final class GuideView: NSView {
    var t0 = Date()
    var target: CGRect?          // settings window rect, Quartz coords
    var granted = false
    var grantT: Date?
    var winOrigin = CGPoint.zero // window origin in Cocoa coords

    let accent = NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.94, alpha: 1)

    // lifecycle of one loop (seconds)
    let T_HOLD1: CGFloat = 0.7, T_MOVE: CGFloat = 1.3, T_DROP: CGFloat = 0.6, T_FADE: CGFloat = 0.4
    var cycle: CGFloat { T_HOLD1 + T_MOVE + T_DROP + T_FADE }

    func chipCenter() -> CGPoint {   // where the "drag from" chip sits (view coords)
        guard let tg = target else {
            return CGPoint(x: bounds.midX - 260, y: bounds.midY)
        }
        let mid = quartzToCocoa(CGPoint(x: tg.midX, y: tg.midY))
        let viewMid = CGPoint(x: mid.x - winOrigin.x, y: mid.y - winOrigin.y)
        // left of the window unless that would leave the screen
        let left = CGPoint(x: viewMid.x - tg.width / 2 - 140, y: viewMid.y + 40)
        if left.x > 90 { return left }
        return CGPoint(x: viewMid.x + tg.width / 2 + 140, y: viewMid.y + 40)
    }

    func dropPoint() -> CGPoint {    // inside the settings list area (view coords)
        guard let tg = target else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let p = quartzToCocoa(CGPoint(x: tg.minX + tg.width * 0.62,
                                      y: tg.minY + tg.height * 0.45))
        return CGPoint(x: p.x - winOrigin.x, y: p.y - winOrigin.y)
    }

    func ease(_ x: CGFloat) -> CGFloat {   // easeInOutCubic
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = CGFloat(Date().timeIntervalSince(t0)).truncatingRemainder(dividingBy: cycle)

        if granted {
            drawCheck(ctx)
            return
        }

        let src = chipCenter(), dst = dropPoint()

        // --- instruction banner ---
        let msg = "To grant \(Ctx.perm.label): drag \(Ctx.appName) into the list — " +
                  "or click + and choose it. Close the settings window when done."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: msg, attributes: attrs)
        let ts = str.size()
        let bx = bounds.midX - ts.width / 2, by = bounds.height - 64
        let bg = NSBezierPath(roundedRect: NSRect(x: bx - 14, y: by - 10,
                                                  width: ts.width + 28, height: ts.height + 20),
                              xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.75).setFill(); bg.fill()
        accent.withAlphaComponent(0.9).setStroke(); bg.lineWidth = 1.5; bg.stroke()
        str.draw(at: CGPoint(x: bx, y: by))

        // --- dashed path hint ---
        let path = NSBezierPath()
        path.move(to: src)
        let ctrl = CGPoint(x: (src.x + dst.x) / 2, y: max(src.y, dst.y) + 60)
        path.curve(to: dst, controlPoint1: ctrl, controlPoint2: ctrl)
        path.setLineDash([6, 6], count: 2, phase: 0)
        accent.withAlphaComponent(0.35).setStroke(); path.lineWidth = 2; path.stroke()

        // --- source chip ---
        let chipR = NSRect(x: src.x - 60, y: src.y - 70, width: 120, height: 120)
        let chip = NSBezierPath(roundedRect: chipR, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.65).setFill(); chip.fill()
        accent.withAlphaComponent(0.8).setStroke(); chip.lineWidth = 1.5; chip.stroke()
        Ctx.appIcon.draw(in: NSRect(x: src.x - 28, y: src.y - 20, width: 56, height: 56))
        let nm = NSAttributedString(string: Ctx.appName, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white])
        nm.draw(at: CGPoint(x: src.x - nm.size().width / 2, y: src.y - 52))

        // --- drop target ring ---
        let dropPhase = t >= T_HOLD1 + T_MOVE && t < T_HOLD1 + T_MOVE + T_DROP
        let ringR: CGFloat = dropPhase ? 30 + (t - T_HOLD1 - T_MOVE) * 30 : 26
        let ringA: CGFloat = dropPhase ? 0.9 : 0.55
        ctx.setStrokeColor(accent.withAlphaComponent(ringA).cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: dst.x - ringR, y: dst.y - ringR,
                                     width: ringR * 2, height: ringR * 2))

        // --- ghost icon + cursor ---
        var gpos = src; var gscale: CGFloat = 0.9; var ga: CGFloat = 1
        if t < T_HOLD1 {
            gpos = src; ga = min(1, t / 0.25)
        } else if t < T_HOLD1 + T_MOVE {
            let e = ease((t - T_HOLD1) / T_MOVE)
            gpos = bezier(src, ctrl, dst, e); gscale = 1.0
        } else if t < T_HOLD1 + T_MOVE + T_DROP {
            gpos = dst; gscale = 1 - 0.35 * (t - T_HOLD1 - T_MOVE) / T_DROP
        } else {
            gpos = dst; gscale = 0.65
            ga = 1 - (t - T_HOLD1 - T_MOVE - T_DROP) / T_FADE
        }
        let gs = 56 * gscale
        Ctx.appIcon.draw(in: NSRect(x: gpos.x - gs / 2, y: gpos.y - gs / 2, width: gs, height: gs),
                         from: .zero, operation: .sourceOver, fraction: ga * 0.9)
        drawCursor(ctx, at: CGPoint(x: gpos.x + 16, y: gpos.y - 18), alpha: ga)
    }

    func bezier(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x,
                       y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y)
    }

    // classic arrow pointer, drawn as a filled path
    func drawCursor(_ ctx: CGContext, at p: CGPoint, alpha: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.setAlpha(alpha)
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: -22))
        path.addLine(to: CGPoint(x: 5.5, y: -17))
        path.addLine(to: CGPoint(x: 9, y: -24))
        path.addLine(to: CGPoint(x: 12, y: -22.5))
        path.addLine(to: CGPoint(x: 8.5, y: -15.5))
        path.addLine(to: CGPoint(x: 15, y: -15.5))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1); ctx.strokePath()
        ctx.restoreGState()
    }

    func drawCheck(_ ctx: CGContext) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let el = CGFloat(grantT.map { Date().timeIntervalSince($0) } ?? 0)
        let r: CGFloat = 44 + min(el * 30, 14)
        ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let check = NSBezierPath()
        check.move(to: CGPoint(x: c.x - 20, y: c.y))
        check.line(to: CGPoint(x: c.x - 6, y: c.y - 14))
        check.line(to: CGPoint(x: c.x + 22, y: c.y + 16))
        NSColor.white.setStroke(); check.lineWidth = 8
        check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
        let msg = NSAttributedString(string: "\(Ctx.perm.label) granted!", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.white])
        msg.draw(at: CGPoint(x: c.x - msg.size().width / 2, y: c.y - r - 40))
    }
}

// ---------- app ----------
final class Guide: NSObject, NSApplicationDelegate {
    var win: NSWindow!
    var view: GuideView!
    var missingSince: Date?
    let start = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // cover the union of all screens
        var union = CGRect.null
        for s in NSScreen.screens { union = union.union(s.frame) }
        view = GuideView(frame: NSRect(origin: .zero, size: union.size))
        view.winOrigin = union.origin
        win = NSWindow(contentRect: union, styleMask: .borderless,
                       backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = view
        win.orderFrontRegardless()

        NSWorkspace.shared.open(URL(string: Ctx.perm.paneURL)!)

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in self.tick() }
    }

    func tick() {
        view.target = settingsWindowRect()
        if view.target == nil {
            if missingSince == nil { missingSince = Date() }
            // settings window closed for a while → user is done
            if Date().timeIntervalSince(missingSince!) > 8,
               Date().timeIntervalSince(start) > 12 {
                print("guide: settings window closed — done")
                NSApp.terminate(nil)
            }
        } else {
            missingSince = nil
        }

        if !Ctx.demo && !view.granted && Date().timeIntervalSince(start) > 1.5 && Ctx.perm.granted {
            view.granted = true
            view.grantT = Date()
            print("guide: \(Ctx.perm.label) granted")
        }
        if view.granted, Date().timeIntervalSince(view.grantT!) > 1.4 {
            NSApp.terminate(nil)
        }
        if Date().timeIntervalSince(start) > Ctx.timeout {
            print("guide: timed out")
            NSApp.terminate(nil)
        }
        view.needsDisplay = true
    }
}

let app = NSApplication.shared
let delegate = Guide()
app.delegate = delegate
app.run()
