import AppKit
import CoreGraphics
import Foundation

let targetPrefix = "--target-bundle-id="
let targetBundleIdentifier = CommandLine.arguments
  .dropFirst()
  .first(where: { $0.hasPrefix(targetPrefix) })?
  .dropFirst(targetPrefix.count)
let activateTarget = CommandLine.arguments.contains("--activate-target")
let monitorTargetVisible = CommandLine.arguments.contains(
  "--monitor-target-visible"
)

if (activateTarget || monitorTargetVisible) && targetBundleIdentifier == nil {
  fputs(
    "--activate-target and --monitor-target-visible require "
      + "--target-bundle-id.\n",
    stderr
  )
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

func currentState() -> [String: Any] {
  let target = targetApplication()
  let targetState: [String: Any]? = targetBundleIdentifier.map {
    bundleIdentifier in
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
  return state
}

func writeState(_ state: [String: Any], to handle: FileHandle) throws {
  let output = try JSONSerialization.data(
    withJSONObject: state,
    options: [.sortedKeys]
  )
  handle.write(output)
  handle.write(Data("\n".utf8))
}

func targetIsContinuouslyVisible(_ state: [String: Any]) -> Bool {
  guard
    state["screenLocked"] as? Bool == false,
    let target = state["target"] as? [String: Any],
    target["running"] as? Bool == true,
    target["active"] as? Bool == true,
    target["hidden"] as? Bool == false,
    (target["onScreenWindowCount"] as? Int ?? 0) > 0,
    state["frontmostBundleIdentifier"] as? String
      == targetBundleIdentifier.map(String.init)
  else {
    return false
  }
  return true
}

let initialState = currentState()
try writeState(initialState, to: FileHandle.standardOutput)

if monitorTargetVisible {
  if !targetIsContinuouslyVisible(initialState) {
    try writeState(initialState, to: FileHandle.standardError)
    exit(3)
  }
  while true {
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    let state = currentState()
    if !targetIsContinuouslyVisible(state) {
      try writeState(state, to: FileHandle.standardError)
      exit(3)
    }
  }
}
