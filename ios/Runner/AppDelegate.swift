import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)
    guard let registrar = registry.registrar(forPlugin: "HISVPNCoreBridge") else {
      NSLog("[HISVPN] no registrar; core bridge not installed")
      return
    }
    CoreBridge.shared.install(messenger: registrar.messenger())
    // The app-level channel answers the shared container path the Dart side
    // resolves its home directory from.
    let appChannel = FlutterMethodChannel(
      name: "com.hisvpn/app",
      binaryMessenger: registrar.messenger()
    )
    appChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "appGroupPath":
        result(
          FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.hisvpn"
          )?.path
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// VPN lifecycle through NETunnelProviderManager: creating and saving the
/// tunnel configuration is what triggers the system's permission prompt.
@available(iOS 13.0, *)
enum VPNManager {
  static let bundleId = "com.hisvpn.HISVPNVPN"
  static let group = "group.com.hisvpn"

  static func start(
    setupParams: String,
    stack: String,
    ipv6: Bool,
    dnsHijacking: Bool,
    completion: @escaping (String?) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        completion("load preferences failed: \(error.localizedDescription)")
        return
      }
      let manager = managers?.first ?? NETunnelProviderManager()
      let tunnel = NETunnelProviderProtocol()
      tunnel.providerBundleIdentifier = bundleId
      tunnel.serverAddress = "HISVPN"
      tunnel.providerConfiguration = [
        "setupParams": setupParams as NSString,
        "stack": stack as NSString,
        "ipv6": (ipv6 ? true : false) as NSObject,
        "dnsHijacking": (dnsHijacking ? true : false) as NSObject,
      ]
      manager.protocolConfiguration = tunnel
      manager.localizedDescription = "HISVPN"
      manager.isEnabled = true
      // This save is what pops the system's "allow adding VPN
      // configurations" password / biometric prompt.
      manager.saveToPreferences { error in
        if let error {
          completion("save preferences failed: \(error.localizedDescription)")
          return
        }
        manager.loadFromPreferences { _, loadError in
          if let loadError {
            completion("reload failed: \(loadError.localizedDescription)")
            return
          }
          do {
            try manager.connection.startVPNTunnel()
            completion(nil)
          } catch {
            completion("start tunnel failed: \(error.localizedDescription)")
          }
        }
      }
    }
  }

  static func stop() {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
      managers?.forEach { $0.connection.stopVPNTunnel() }
    }
  }
}

/// Swift bridge to the Go core, statically linked into the Runner binary.
///
/// The core's C ABI (ios/Runner/hisvpn-core.h + core/bride.h) is imported
/// through the bridging header and referenced DIRECTLY — no dlsym, no
/// runtime symbol lookup: the linker binds every call at build time.
/// Host callbacks registered with permissive iOS semantics: `protect`
/// always succeeds (no VpnService bypass on iOS) and UID/package
/// resolution reports "unknown".
///
/// Status: the core runs in-process and answers `invokeMethod`, `init`,
/// `getTraffic`, `getTotalTraffic`, `updateDns`, `forceGC` and `shutdown`.
/// `start`/`stop` acknowledge the lifecycle so CoreLib.startListener
/// proceeds; the real tunnel arrives with the NetworkExtension target
/// (see ios/VPNExtension/ and docs/IOS_BUILD.md).
final class CoreBridge {
  static let shared = CoreBridge()

  private var channel: FlutterMethodChannel?
  /// The last SharedState payload Dart pushed: keeps setupParams (selected
  /// proxies) and the tun options for when the VPN tunnel is started.
  private var lastSetupParams = "{\"selected-map\":{},\"test-url\":\"\"}"
  private var lastStack = "mixed"
  private var lastIpv6 = true
  private var lastDnsHijacking = true

  private final class CallbackBox {
    let onResult: (String?) -> Void
    init(onResult: @escaping (String?) -> Void) {
      self.onResult = onResult
    }
  }

  func install(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.hisvpn/service",
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.onMethodCall(call, result: result)
    }
    installHostCallbacks()
    NSLog("[HISVPN] Core bridge installed")
  }

  /// Assigns the host callbacks the Go core invokes (bride.h function
  /// pointer variables, statically linked — plain Swift-visible globals).
  private func installHostCallbacks() {
    // C function pointers must not capture context; route through a global.
    CoreBridgeHost.bridge = self
    release_object_func = CoreBridgeHost.releaseObject
    free_string_func = CoreBridgeHost.freeString
    protect_func = CoreBridgeHost.protect
    resolve_uid_func = CoreBridgeHost.resolveUid
    resolve_package_func = CoreBridgeHost.resolvePackage
    result_func = CoreBridgeHost.resultFn
  }

  // MARK: - Channel

  private func onMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      installEventListener()
      result("")
    case "invokeMethod":
      guard let data = call.arguments as? String else {
        result(FlutterError(
          code: "INVALID_ARGUMENT",
          message: "Method call payload must be a string",
          details: nil
        ))
        return
      }
      invokeCoreMethod(data, result: result)
    case "getTraffic":
      result(takeCString(getTraffic(false)))
    case "getTotalTraffic":
      result(takeCString(getTotalTraffic(false)))
    case "updateDns":
      if let dns = call.arguments as? String {
        // Same ownership contract: the core frees the pointer, so hand it a
        // malloc'd copy rather than the Swift string's buffer.
        dns.withCString { pointer in
          guard let copy = strdup(pointer) else { return }
          updateDns(copy)
        }
      }
      result(nil)
    case "forceGC":
      forceGC()
      result(nil)
    case "start":
      // Starting on iOS means bringing up the NetworkExtension tunnel: the
      // system prompts for permission, the extension process runs the Go
      // core from the shared container and owns the utun.
      VPNManager.start(
        setupParams: lastSetupParams,
        stack: lastStack,
        ipv6: lastIpv6,
        dnsHijacking: lastDnsHijacking
      ) { message in
        result(message == nil)
      }
    case "stop":
      VPNManager.stop()
      result(true)
    case "shutdown":
      result(true)
    case "syncState":
      if let payload = call.arguments as? String,
         let data = payload.data(using: .utf8),
         let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        if let setup = state["setupParams"] as? [String: Any],
           let setupData = try? JSONSerialization.data(withJSONObject: setup)
        {
          lastSetupParams = String(data: setupData, encoding: .utf8) ?? lastSetupParams
        }
        if let vpn = state["vpnOptions"] as? [String: Any] {
          lastStack = vpn["stack"] as? String ?? lastStack
          lastIpv6 = vpn["ipv6"] as? Bool ?? lastIpv6
          lastDnsHijacking = vpn["dnsHijacking"] as? Bool ?? lastDnsHijacking
        }
      }
      result("")
    case "getRunTime":
      result(0)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invokeCoreMethod(_ data: String, result: @escaping FlutterResult) {
    let box = makeCallbackBox { response in
      // The core answers on a Go thread; a FlutterMethodChannel reply must
      // happen on the platform thread (the Android bridge wraps the same
      // rule with its MainThreadResult).
      DispatchQueue.main.async {
        guard let response else {
          result(nil)
          return
        }
        result(FlutterStandardTypedData(bytes: Data(response.utf8)))
      }
    }
    // The core frees the argument through free_string_func (the same
    // contract as Android), so it must be a malloc'd copy — a Swift string's
    // internal buffer is not.
    data.withCString { pointer in
      guard let copy = strdup(pointer) else { return }
      invokeMethod(box, copy)
    }
  }

  private func installEventListener() {
    let box = makeCallbackBox { [weak self] response in
      guard let self, let response else { return }
      DispatchQueue.main.async {
        self.channel?.invokeMethod("event", arguments: response)
      }
    }
    setEventListener(box)
  }

  // MARK: - Callback plumbing

  /// Opaque handle handed to the Go core; the core passes it back through
  /// the host callbacks and finally releases it via `release_object_func`.
  private func makeCallbackBox(onResult: @escaping (String?) -> Void) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(CallbackBox(onResult: onResult)).toOpaque()
  }

  func releaseObject(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<CallbackBox>.fromOpaque(pointer).release()
  }

  func deliverResult(_ pointer: UnsafeMutableRawPointer?, _ data: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(pointer).takeUnretainedValue()
    box.onResult(data.map { String(cString: $0) })
  }

  private func takeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { free_string(pointer) }
    return String(cString: pointer)
  }
}

/// Non-capturing C callbacks required by `bride.h`. The Go core invokes
/// these from arbitrary threads.
private enum CoreBridgeHost {
  nonisolated(unsafe) static var bridge: CoreBridge?

  static let releaseObject: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
    bridge?.releaseObject(pointer)
  }
  static let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { pointer in
    free(pointer)
  }
  /// No VpnService bypass exists on iOS: every socket may dial directly.
  static let protect: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { _, _ in 1 }
  /// iOS does not name connection owners; -1 means "unknown".
  static let resolveUid: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?
  ) -> Int32 = { _, _, _, _ in -1 }
  static let resolvePackage: @convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafeMutablePointer<CChar>? =
    { _, _ in strdup("") }
  static let resultFn: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { pointer, data in
    bridge?.deliverResult(pointer, data)
  }
}
