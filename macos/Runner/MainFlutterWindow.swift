import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    LaunchAtLoginChannel.register(
      messenger: flutterViewController.engine.binaryMessenger)
    WindowActivationChannel.register(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// `cliptown/window` `activate`: bring ClipTown to the front with keyboard focus
/// when summoned by the global shortcut, even while another app is active.
enum WindowActivationChannel {
  static func register(messenger: FlutterBinaryMessenger, window: NSWindow) {
    let channel = FlutterMethodChannel(name: "cliptown/window", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak window] call, result in
      guard call.method == "activate" else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSApp.unhide(nil)
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
      window?.orderFrontRegardless()
      result(nil)
    }
  }
}

/// `cliptown/launch_at_login`: login-item registration via
/// `SMAppService.mainApp` (macOS 13+, App Sandbox compatible) and whether this
/// process was started by the login item.
enum LaunchAtLoginChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "cliptown/launch_at_login", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "launchedAtLogin":
        result(AppDelegate.launchedAsLoginItem)
      case "isEnabled":
        if #available(macOS 13.0, *) {
          // requiresApproval: registered, waiting for the user in System
          // Settings. Report it as on so the toggle matches the request.
          let status = SMAppService.mainApp.status
          result(status == .enabled || status == .requiresApproval)
        } else {
          result(false)
        }
      case "setEnabled":
        guard #available(macOS 13.0, *) else {
          result(
            FlutterError(
              code: "unsupported", message: "Open at login requires macOS 13 or later",
              details: nil))
          return
        }
        let arguments = call.arguments as? [String: Any]
        let enabled = arguments?["enabled"] as? Bool ?? false
        do {
          if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
              SMAppService.openSystemSettingsLoginItems()
              result(
                FlutterError(
                  code: "requires_approval",
                  message: "Approve ClipTown in System Settings > Login Items", details: nil))
              return
            }
          } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
          }
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "login_item_failed", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
