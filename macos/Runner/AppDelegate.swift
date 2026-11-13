import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// True when launchd started ClipTown as a login item; the Dart side then
  /// keeps the window hidden in the menu bar.
  static var launchedAsLoginItem = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    if let event = NSAppleEventManager.shared().currentAppleEvent {
      AppDelegate.launchedAsLoginItem =
        event.eventID == AEEventID(kAEOpenApplication)
        && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
          == OSType(keyAELaunchedAsLogInItem)
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // WindowManager intercepts Close and either hides to the tray or performs
    // an explicit application quit when tray setup is unavailable.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag, let window = mainFlutterWindow {
      window.center()
      window.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
