import NetworkExtension
import os

/// The HISVPN packet tunnel: the Go core runs in this extension process,
/// configured from the same App Group container the app writes (database,
/// profiles, config.yaml), and takes over the utun the system hands us.
///
/// The flow mirrors the Android VpnService:
///   quickSetup (init + selectedMap)  ->  setTUNSettings  ->  startTUN(fd)
/// with the same hardcoded tunnel layout (172.19.0.1/30 etc.).
class PacketTunnelProvider: NEPacketTunnelProvider {
  private static let ipv4Address = "172.19.0.1/30"
  private static let ipv6Address = "fdfe:dcba:9876::1/126"
  private static let dnsIPv4 = "172.19.0.2"
  private static let dnsIPv6 = "fdfe:dcba:9876::2"
  private static let netAny = "0.0.0.0"
  private static let netAny6 = "::"
  private static let mtu: NSNumber = 9000

  private final class CallbackBox {
    let onResult: (String?) -> Void
    init(onResult: @escaping (String?) -> Void) {
      self.onResult = onResult
    }
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let log = OSLog(subsystem: "com.hisvpn", category: "tunnel")
    guard let config = (protocolConfiguration as? NETunnelProviderProtocol)?
      .providerConfiguration
    else {
      os_log("no providerConfiguration", log: log, type: .error)
      completionHandler(TunnelError.missingConfiguration)
      return
    }
    let setupParams = (config["setupParams"] as? String) ?? "{\"selected-map\":{},\"test-url\":\"\"}"
    let stack = (config["stack"] as? String) ?? "mixed"
    let ipv6 = (config["ipv6"] as? Bool) ?? true
    let dnsHijacking = (config["dnsHijacking"] as? Bool) ?? true

    // The App Group container is the core's homeDir — same files the app
    // process maintains (config.yaml, profiles, database).
    guard
      let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.9e357262a457fc58.4"
      )
    else {
      os_log("App Group container missing", log: log, type: .error)
      completionHandler(TunnelError.missingAppGroup)
      return
    }
    let homeDir = groupURL.path

    installHostCallbacks()

    // quickSetup: init the core (homeDir) and apply the selected proxies,
    // exactly the payload the Android host passes to the same export.
    let initParams = "{\"home-dir\": \"\(homeDir)\", \"version\": 29}"
    let quickSetupBox = makeCallbackBox { message in
      guard let message, message.isEmpty else {
        os_log("quickSetup failed: %{public}@", log: log, type: .error, message ?? "?")
        self.teardown()
        completionHandler(TunnelError.coreSetupFailed(message ?? "?"))
        return
      }
      self.bringUpTunnel(stack: stack, ipv6: ipv6, dnsHijacking: dnsHijacking) { error in
        completionHandler(error)
      }
    }
    initParams.withCString { initPtr in
      setupParams.withCString { setupPtr in
        guard let initCopy = strdup(initPtr), let setupCopy = strdup(setupPtr) else {
          return
        }
        quickSetup(quickSetupBox, initCopy, setupCopy)
      }
    }
  }

  private func bringUpTunnel(
    stack: String,
    ipv6: Bool,
    dnsHijacking: Bool,
    completion: @escaping (Error?) -> Void
  ) {
    let log = OSLog(subsystem: "com.hisvpn", category: "tunnel")
    var addresses = [Self.ipv4Address]
    if ipv6 {
      addresses.append(Self.ipv6Address)
    }
    var dnsServers = [Self.dnsIPv4]
    if ipv6 {
      dnsServers.append(Self.dnsIPv6)
    }
    if dnsHijacking {
      dnsServers = [Self.netAny, Self.netAny6]
    }

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.dnsIPv4)
    settings.mtu = Self.mtu
    let ipv4Settings = NEIPv4Settings(
      addresses: ["172.19.0.1"],
      subnetMasks: ["255.255.255.252"]
    )
    ipv4Settings.includedRoutes = [NEIPv4Route.default()]
    let ipv6Settings = NEIPv6Settings(
      addresses: ipv6 ? ["fdfe:dcba:9876::1"] : [],
      networkPrefixLengths: ipv6 ? [126] : []
    )
    if ipv6 {
      ipv6Settings.includedRoutes = [NEIPv6Route.default()]
    }
    settings.ipv4Settings = ipv4Settings
    settings.ipv6Settings = ipv6Settings
    settings.dnsSettings = NEDNSSettings(servers: dnsServers)

    setTunnelNetworkSettings(settings) { error in
      if let error {
        os_log("setTunnelNetworkSettings failed: %{public}@", log: log, type: .error, "\(error)")
        completion(error)
        return
      }
      // The packetFlow's utun descriptor, the same KVC every iOS port uses.
      guard
        let socket = self.packetFlow.value(forKeyPath: "socket"),
        let fd = (socket as? NSObject)?.value(forKeyPath: "fileDescriptor") as? Int32,
        fd > 0
      else {
        os_log("packetFlow descriptor unavailable", log: log, type: .error)
        completion(TunnelError.noTunDescriptor)
        return
      }
      let tunBox = Unmanaged.passRetained(CallbackBox(onResult: { _ in })).toOpaque()
      let address = addresses.joined(separator: ",")
      let dns = dnsServers.joined(separator: ",")
      let started = stack.withCString { stackPtr in
        address.withCString { addressPtr in
          dns.withCString { dnsPtr in
            startTUN(tunBox, fd, UnsafeMutablePointer(mutating: stackPtr),
                    UnsafeMutablePointer(mutating: addressPtr),
                    UnsafeMutablePointer(mutating: dnsPtr))
          }
        }
      }
      // The Go side frees the strings through free_string_func and the
      // callback object through release_object_func.
      if !started {
        os_log("startTUN rejected the descriptor", log: log, type: .error)
        completion(TunnelError.startTunFailed)
        return
      }
      os_log("tunnel up", log: log)
      completion(nil)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    stopTun()
    completionHandler()
  }

  private func teardown() {
    stopTun()
    cancelTunnelWithError(nil)
  }

  // MARK: - Host callbacks (bride.h)

  private func installHostCallbacks() {
    TunnelHostCallbacks.install()
  }

  private func makeCallbackBox(onResult: @escaping (String?) -> Void) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(CallbackBox(onResult: onResult)).toOpaque()
  }
}

private enum TunnelError: Error {
  case missingConfiguration
  case missingAppGroup
  case coreSetupFailed(String)
  case noTunDescriptor
  case startTunFailed
}

/// The non-capturing C callbacks the Go core invokes (bride.h). Semantics
/// match the in-app bridge: no socket bypass on iOS, UID/package unknown.
private enum TunnelHostCallbacks {
  static func install() {
    release_object_func = { pointer in
      if let pointer {
        Unmanaged<CallbackBoxLocal>.fromOpaque(pointer).release()
      }
    }
    free_string_func = { pointer in
      free(pointer)
    }
    protect_func = { _, _ in 1 }
    resolve_uid_func = { _, _, _, _ in -1 }
    resolve_package_func = { _, _ in strdup("") }
    result_func = { pointer, data in
      guard let pointer else { return }
      let box = Unmanaged<CallbackBoxLocal>.fromOpaque(pointer).takeUnretainedValue()
      box.onResult(data.map { String(cString: $0) })
    }
  }
}

/// Mirrors PacketTunnelProvider.CallbackBox for the host callback plumbing.
private final class CallbackBoxLocal {
  let onResult: (String?) -> Void
  init(onResult: @escaping (String?) -> Void) {
    self.onResult = onResult
  }
}
