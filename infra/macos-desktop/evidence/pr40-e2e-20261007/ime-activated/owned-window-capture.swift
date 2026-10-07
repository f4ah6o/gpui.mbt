import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@main
struct OwnedWindowCapture {
  @MainActor
  static func main() async {
    guard CommandLine.arguments.count == 4,
          let pid = Int32(CommandLine.arguments[1]) else {
      fputs("usage: owned-window-capture PID TITLE OUTPUT.png\n", stderr)
      exit(2)
    }
    // Establish the process's WindowServer connection before CoreGraphics' capture path.
    _ = NSApplication.shared
    let title = CommandLine.arguments[2]
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      let windows = content.windows.filter { window in
        window.owningApplication?.processID == pid && window.title == title
      }
      guard windows.count == 1, let window = windows.first else {
        fputs("expected exactly one visible app-owned ScreenCaptureKit window\n", stderr)
        exit(4)
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let contentRect = filter.contentRect
      let scale = CGFloat(filter.pointPixelScale)
      guard scale.isFinite, scale > 0, contentRect.width.isFinite, contentRect.height.isFinite,
            contentRect.width > 0, contentRect.height > 0 else {
        fputs("ScreenCaptureKit returned invalid content geometry\n", stderr)
        exit(7)
      }
      let config = SCStreamConfiguration()
      config.width = max(1, Int((contentRect.width * scale).rounded()))
      config.height = max(1, Int((contentRect.height * scale).rounded()))
      config.capturesAudio = false
      config.showsCursor = false
      config.ignoreShadowsSingleWindow = true
      config.includeChildWindows = false
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("cannot create the ScreenCaptureKit PNG destination\n", stderr)
        exit(5)
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        fputs("cannot finalize ScreenCaptureKit PNG\n", stderr)
        exit(6)
      }
      let response: [String: Any] = ["window_id": Int(window.windowID),
                                     "width": image.width, "height": image.height,
                                     "owner_pid": Int(pid), "title": title,
                                     "window_frame": ["width": Double(window.frame.width),
                                                      "height": Double(window.frame.height)],
                                     "capture_engine": "ScreenCaptureKit.SCScreenshotManager",
                                     "content_rect": ["x": Double(contentRect.origin.x),
                                                      "y": Double(contentRect.origin.y),
                                                      "width": Double(contentRect.width),
                                                      "height": Double(contentRect.height)],
                                     "point_pixel_scale": Double(scale),
                                     "shadows_ignored": true, "cursor_excluded": true,
                                     "child_windows_included": false]
      let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
      print(String(decoding: bytes, as: UTF8.self))
    } catch {
      fputs("ScreenCaptureKit capture failed (including Screen Recording permission): \(error.localizedDescription)\n", stderr)
      exit(10)
    }
  }
}
