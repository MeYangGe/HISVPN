import NetworkExtension
import os

/// Skeleton PacketTunnelProvider for HISVPN.
///
/// NOT WIRED UP YET — this file is reference source. To activate:
/// 1. In Xcode: File > New > Target > Packet Tunnel Extension, name it
///    `HISVPNVPN`, bundle id `com.hisvpn.HISVPNVPN`.
/// 2. Replace the generated PacketTunnelProvider.swift with this file.
/// 3. Add the `com.hisvpn.HISVPNVPN` app group to both Runner and the
///    extension, add the `packet-tunnel-provider` system extension
///    entitlement (HISVPNVPN.entitlements), embed `libclash.dylib` in the
///    extension target as well, and link `libclash/ios/includes/libclash.h`
///    through the bridging header.
/// 4. Fill in the two TODO sections below.
///
/// The Go core exposes everything the tunnel needs: `quickSetup` (init +
/// config), `startTUN(callback, fd, stack, address, dns)` and `stopTun`.
/// Known-good mihomo-on-iOS ports drive `startTUN` with the utun file
/// descriptor that the provider owns.
class PacketTunnelProvider: NEPacketTunnelProvider {
  private let log = OSLog(subsystem: "com.hisvpn", category: "tunnel")

  override func startTunnel(
    _ options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // TODO: fetch profile/config from the shared app group container and
    // call the core's quickSetup with InitParams + SetupParams (see
    // android VpnService for the JSON shapes: core/hub.go InitParams,
    // SetupParams).
    //
    // TODO: obtain the utun descriptor for packetFlow and call
    // startTUN(callback, fd, stack, address, dns); register the same host
    // callbacks as ios/Runner/AppDelegate.swift (protect = 1,
    // resolveUid = -1, resolvePackage = "").
    os_log("startTunnel requested (skeleton; not implemented)", log: log)
    completionHandler(HISVPNError.notImplemented)
  }

  override func stopTunnel(
    _ reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    // TODO: call the core's stopTun() export and tear down state.
    os_log("stopTunnel (skeleton)", log: log)
    completionHandler()
  }
}

private enum HISVPNError: Error {
  case notImplemented
}
