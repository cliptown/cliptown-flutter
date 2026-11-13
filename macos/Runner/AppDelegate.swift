import Cocoa
import FlutterMacOS
import ServiceManagement

enum ClipTownTray {
  /// Distance (points) from the right edge of the menu bar.
  static let preferredPosition: Double = 470
}

@main
class AppDelegate: FlutterAppDelegate {
  /// True when launchd started ClipTown as a login item; the Dart side then
  /// keeps the window hidden in the menu bar.
  static var launchedAsLoginItem = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    // New menu-bar items are placed at the far left of the status area, which
    // on a crowded notched display is hidden behind the notch. Prefer a slot
    // near the system icons instead. This is only a registered default: once
    // the user Cmd-drags the icon, macOS persists their choice and it wins.
    UserDefaults.standard.register(defaults: [
      "NSStatusItem Preferred Position Item-0": ClipTownTray.preferredPosition
    ])
    if let event = NSAppleEventManager.shared().currentAppleEvent {
      AppDelegate.launchedAsLoginItem =
        event.eventID == AEEventID(kAEOpenApplication)
        && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
          == OSType(keyAELaunchedAsLogInItem)
    }
    super.applicationWillFinishLaunching(notification)
    if CommandLine.arguments.contains("--enable-open-at-login") {
      // applicationDidFinishLaunching is not delivered to this delegate in the
      // Flutter runner, so register on the next main-queue turn instead.
      DispatchQueue.main.async { AppDelegate.registerAsLoginItem() }
    }
  }

  /// `--enable-open-at-login` (passed by `install-macos.sh --open-at-login`)
  /// registers ClipTown as a login item, exactly like the in-app toggle.
  /// SMAppService only registers the calling app, so the installer cannot do
  /// this from outside.
  static func registerAsLoginItem() {
    if #available(macOS 13.0, *) {
      do {
        try SMAppService.mainApp.register()
        if SMAppService.mainApp.status == .requiresApproval {
          SMAppService.openSystemSettingsLoginItems()
        }
      } catch {
        NSLog("ClipTown could not register as a login item: %@", error.localizedDescription)
      }
    }
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
