import Flutter
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
  }
}

/// Swift bridge to the Go core dylib (`libclash.dylib`, embedded by the
/// build into `Runner.app/Frameworks/`).
///
/// The core exports a plain C ABI (see `core/bride.h` and the `//export`
/// functions in `core/lib.go`); this bridge resolves the symbols with
/// `dlsym` at runtime, so no bridging header or project file changes are
/// needed. Host callbacks required by the core are registered with
/// permissive iOS semantics: `protect` always succeeds (there is no
/// VpnService bypass on iOS) and UID/package resolution reports "unknown".
///
/// Status: the core runs in-process and answers `invokeMethod`, `init`,
/// `getTraffic`, `getTotalTraffic`, `updateDns`, `forceGC` and `shutdown`.
/// `start` and `stop` return false until the NetworkExtension tunnel
/// target (`ios/VPNExtension/`) is wired up — see docs/IOS_BUILD.md.
final class CoreBridge {
  static let shared = CoreBridge()

  private var handle: UnsafeMutableRawPointer?
  private var channel: FlutterMethodChannel?
  /// Set when the core dylib cannot be loaded; surfaced through the
  /// CORE_ERROR channel reply so it reaches the in-app log page.
  private var coreLoadError: String = "core not loaded"

  private typealias InvokeMethodFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?
  ) -> Void
  private typealias SetEventListenerFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  private typealias GetTrafficFn = @convention(c) (Bool) -> UnsafeMutablePointer<CChar>?
  private typealias StopTunFn = @convention(c) () -> Void
  private typealias ForceGCFn = @convention(c) () -> Void
  private typealias UpdateDnsFn = @convention(c) (UnsafePointer<CChar>?) -> Void
  private typealias ReleaseObjectFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

  private var invokeMethodFn: InvokeMethodFn?
  private var setEventListenerFn: SetEventListenerFn?
  private var getTrafficFn: GetTrafficFn?
  private var getTotalTrafficFn: GetTrafficFn?
  private var stopTunFn: StopTunFn?
  private var forceGCFn: ForceGCFn?
  private var updateDnsFn: UpdateDnsFn?
  private var releaseObjectFn: ReleaseObjectFn?
  private var freeStringFn: FreeStringFn?

  private final class CallbackBox {
    let onResult: (String?) -> Void
    init(onResult: @escaping (String?) -> Void) {
      self.onResult = onResult
    }
  }

  private func symbol(_ name: String) -> UnsafeMutableRawPointer? {
    guard let handle else { return nil }
    return dlsym(handle, name)
  }

  /// Loads `libclash.dylib` from the app bundle and installs the
  /// `com.hisvpn/service` method channel. A missing core or missing
  /// symbols degrade to a logged warning — the UI keeps working.
  func install(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.hisvpn/service",
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.onMethodCall(call, result: result)
    }

    let candidates = [
      Bundle.main.privateFrameworksPath.map { "\($0)/HISVPNCore.framework/HISVPNCore" },
      Bundle.main.privateFrameworksPath.map { "\($0)/libclash.dylib" },
      Bundle.main.resourcePath.map { "\($0)/Frameworks/HISVPNCore.framework/HISVPNCore" },
      Bundle.main.resourcePath.map { "\($0)/Frameworks/libclash.dylib" },
    ].compactMap { $0 }
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
      coreLoadError = "core not embedded; searched: \(candidates.joined(separator: ", "))"
      NSLog("[HISVPN] %@", coreLoadError)
      return
    }
    handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
    guard handle != nil else {
      coreLoadError = "dlopen failed: \(String(cString: dlerror()))"
      NSLog("[HISVPN] %@", coreLoadError)
      return
    }

    invokeMethodFn = unsafeBitCast(symbol("invokeMethod"), to: InvokeMethodFn.self)
    setEventListenerFn = unsafeBitCast(symbol("setEventListener"), to: SetEventListenerFn.self)
    getTrafficFn = unsafeBitCast(symbol("getTraffic"), to: GetTrafficFn.self)
    getTotalTrafficFn = unsafeBitCast(symbol("getTotalTraffic"), to: GetTrafficFn.self)
    stopTunFn = unsafeBitCast(symbol("stopTun"), to: StopTunFn.self)
    forceGCFn = unsafeBitCast(symbol("forceGC"), to: ForceGCFn.self)
    updateDnsFn = unsafeBitCast(symbol("updateDns"), to: UpdateDnsFn.self)
    releaseObjectFn = unsafeBitCast(symbol("release_object_func"), to: ReleaseObjectFn.self)
    freeStringFn = unsafeBitCast(symbol("free_string_func"), to: FreeStringFn.self)

    installHostCallbacks()
    NSLog("[HISVPN] Core bridge installed")
  }

  /// Registers the host callbacks the core calls through (bride.h). Each
  /// exported slot is a C function-pointer variable in the dylib.
  private func installHostCallbacks() {
    guard
      let releasePtr = symbol("release_object_func"),
      let freeStringPtr = symbol("free_string_func"),
      let protectPtr = symbol("protect_func"),
      let resolveUidPtr = symbol("resolve_uid_func"),
      let resolvePackagePtr = symbol("resolve_package_func"),
      let resultPtr = symbol("result_func")
    else {
      NSLog("[HISVPN] core callback slots missing; bridge stays passive")
      return
    }

    // C function pointers must not capture context; route through a global.
    CoreBridgeHost.bridge = self

    func store(_ closure: UnsafeMutableRawPointer, into slot: UnsafeMutableRawPointer) {
      slot.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee = closure
    }

    store(
      unsafeBitCast(CoreBridgeHost.releaseObject, to: UnsafeMutableRawPointer.self),
      into: releasePtr
    )
    store(
      unsafeBitCast(CoreBridgeHost.freeString, to: UnsafeMutableRawPointer.self),
      into: freeStringPtr
    )
    store(
      unsafeBitCast(CoreBridgeHost.protect, to: UnsafeMutableRawPointer.self),
      into: protectPtr
    )
    store(
      unsafeBitCast(CoreBridgeHost.resolveUid, to: UnsafeMutableRawPointer.self),
      into: resolveUidPtr
    )
    store(
      unsafeBitCast(CoreBridgeHost.resolvePackage, to: UnsafeMutableRawPointer.self),
      into: resolvePackagePtr
    )
    store(
      unsafeBitCast(CoreBridgeHost.resultFn, to: UnsafeMutableRawPointer.self),
      into: resultPtr
    )
  }

  // MARK: - Channel

  private func onMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      setEventListener()
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
      result(takeCString(getTrafficFn?(false)))
    case "getTotalTraffic":
      result(takeCString(getTotalTrafficFn?(false)))
    case "updateDns":
      if let dns = call.arguments as? String {
        dns.withCString { pointer in updateDnsFn?(pointer) }
      }
      result(nil)
    case "forceGC":
      forceGCFn?()
      result(nil)
    case "start", "stop":
      // The NetworkExtension tunnel target is not wired up yet (see
      // ios/VPNExtension/); the in-app core listener lifecycle still runs,
      // so acknowledge the lifecycle calls to let CoreLib.startListener
      // proceed. Real tunnel bring-up arrives with the extension.
      result(true)
    case "shutdown":
      result(true)
    case "syncState", "getRunTime":
      result(call.method == "getRunTime" ? 0 : "")
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invokeCoreMethod(_ data: String, result: @escaping FlutterResult) {
    guard let invokeMethodFn else {
      result(FlutterError(code: "CORE_ERROR", message: coreLoadError, details: nil))
      return
    }
    let box = makeCallbackBox { response in
      guard let response else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: Data(response.utf8)))
    }
    data.withCString { pointer in
      invokeMethodFn(box, pointer)
    }
  }

  private func setEventListener() {
    guard let setEventListenerFn else { return }
    let box = makeCallbackBox { [weak self] response in
      guard let self, let response else { return }
      DispatchQueue.main.async {
        self.channel?.invokeMethod("event", arguments: response)
      }
    }
    setEventListenerFn(box)
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
    defer { freeStringFn?(pointer) }
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
