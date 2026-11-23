import Foundation
import LorvexDomain
import LorvexStore

/// One invocation owns one clock and one ephemeral transaction. No cross-account state.
package final class NativeClock: HlcDominatingStateHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let state: HlcState
  private let physicalMs: UInt64

  package init(deviceId: String, date: Date) throws {
    physicalMs = UInt64(max(0, date.timeIntervalSince1970 * 1000))
    state = try HlcState(deviceSuffix: DeviceIdentity.deviceIdToHlcSuffix(deviceId, surface: .mcp))
  }

  func observe(_ value: Hlc) {
    lock.lock()
    defer { lock.unlock() }
    state.updateOnReceive(remote: value, physicalMs: physicalMs,
      maxForwardDriftMs: HlcState.maxInboundForwardDriftMs)
  }

  package func generate() -> Hlc {
    lock.lock()
    defer { lock.unlock() }
    return state.generate(withPhysicalMs: physicalMs)
  }

  package func generate(dominating floor: Hlc?) -> Hlc {
    lock.lock()
    defer { lock.unlock() }
    if let floor { state.updateOnReceive(remote: floor, physicalMs: physicalMs) }
    return state.generate(withPhysicalMs: physicalMs)
  }
}
