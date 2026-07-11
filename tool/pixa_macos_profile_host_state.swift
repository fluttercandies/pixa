import AppKit
import CoreGraphics
import Foundation

let targetPrefix = "--target-bundle-id="
let targetBundleIdentifier = CommandLine.arguments
  .dropFirst()
  .first(where: { $0.hasPrefix(targetPrefix) })?
  .dropFirst(targetPrefix.count)
let activateTarget = CommandLine.arguments.contains("--activate-target")

if activateTarget && targetBundleIdentifier == nil {
  fputs("--activate-target requires --target-bundle-id.\n", stderr)
  exit(64)
}

func isScreenLocked() -> Bool {
  guard
    let session = CGSessionCopyCurrentDictionary() as? [String: Any],
    let locked = session["CGSSessionScreenIsLocked"] as? NSNumber
  else {
    return false
  }
  return locked.boolValue
}

func onScreenWindowCount(for processIdentifier: pid_t) -> Int {
  guard
    let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]]
  else {
    return 0
  }
  return windows.count { window in
    let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
    let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
    return owner == processIdentifier && layer == 0 && (alpha ?? 0) > 0
  }
}

func targetApplication() -> NSRunningApplication? {
  guard let targetBundleIdentifier else {
    return nil
  }
  return NSRunningApplication.runningApplications(
    withBundleIdentifier: String(targetBundleIdentifier)
  ).first
}

if activateTarget && !isScreenLocked() {
  let deadline = Date().addingTimeInterval(5)
  repeat {
    if let target = targetApplication() {
      _ = target.activate(options: [.activateAllWindows])
      if target.isActive
        && NSWorkspace.shared.frontmostApplication?.bundleIdentifier
          == target.bundleIdentifier
        && onScreenWindowCount(for: target.processIdentifier) > 0
      {
        break
      }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  } while Date() < deadline
}

let target = targetApplication()
let targetState: [String: Any]? = targetBundleIdentifier.map { bundleIdentifier in
  [
    "bundleIdentifier": String(bundleIdentifier),
    "running": target != nil,
    "active": target?.isActive ?? false,
    "hidden": target?.isHidden ?? true,
    "onScreenWindowCount": target.map {
      onScreenWindowCount(for: $0.processIdentifier)
    } ?? 0,
  ]
}
var state: [String: Any] = [
  "screenLocked": isScreenLocked(),
  "frontmostBundleIdentifier":
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
]
if let targetState {
  state["target"] = targetState
}

let output = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
