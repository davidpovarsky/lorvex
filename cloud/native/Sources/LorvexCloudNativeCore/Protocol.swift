import Foundation
import LorvexDomain
import LorvexSync

public struct NativeRequest: Codable, Sendable {
  public let envelopes: [SyncEnvelope]
  public let action: String
  public let arguments: Arguments
  public let deviceId: String
  public let now: String?
  public let timezone: String?

  public struct Arguments: Codable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
  }

  enum CodingKeys: String, CodingKey {
    case envelopes, action, arguments, now, timezone
    case deviceId = "device_id"
  }

  public init(envelopes: [SyncEnvelope], action: String, arguments: Arguments,
    deviceId: String = "lorvex-cloud-server", now: String? = nil, timezone: String? = nil) {
    self.envelopes = envelopes
    self.action = action
    self.arguments = arguments
    self.deviceId = deviceId
    self.now = now
    self.timezone = timezone
  }
}

public struct NativeResponse: Codable, Sendable {
  public let envelopes: [SyncEnvelope]
  public let result: Result
  public let changed: Bool

  public struct Result: Codable, Sendable {
    public let task: JSONValue
    init(task: JSONValue) { self.task = task }
    enum CodingKeys: String, CodingKey { case task }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      task = try container.decode(ProcessJSON.self, forKey: .task).value
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(ProcessJSON(task), forKey: .task)
    }
  }
}

public enum NativeError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case incompleteSnapshot(String)
  case missingResource(String)

  public var description: String {
    switch self {
    case .invalidRequest(let message): return "invalid_request: " + message
    case .incompleteSnapshot(let message): return "incomplete_snapshot: " + message
    case .missingResource(let name): return "missing_resource: " + name
    }
  }
}


// Narrow process-wire bridge; the canonical JSONValue remains unchanged.
private struct ProcessJSON: Codable {
  let value: JSONValue
  init(_ value: JSONValue) { self.value = value }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { value = .null }
    else if let decoded = try? container.decode(Bool.self) { value = .bool(decoded) }
    else if let decoded = try? container.decode(Int64.self) { value = .int(decoded) }
    else if let decoded = try? container.decode(UInt64.self) { value = .uint(decoded) }
    else if let decoded = try? container.decode(Double.self) { value = .double(decoded) }
    else if let decoded = try? container.decode(String.self) { value = .string(decoded) }
    else if let decoded = try? container.decode([ProcessJSON].self) {
      value = .array(decoded.map(\.value))
    } else {
      value = .object(try container.decode([String: ProcessJSON].self).mapValues(\.value))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .uint(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values.map(ProcessJSON.init))
    case .object(let values): try container.encode(values.mapValues(ProcessJSON.init))
    }
  }
}
