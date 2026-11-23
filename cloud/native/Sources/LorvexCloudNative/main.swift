import Foundation
import LorvexCloudNativeCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

do {
  // Bounded stdin and JSON stdout only. Operational diagnostics go to stderr.
  let limit = 32 * 1024 * 1024
  var input = Data()
  while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
    guard input.count + chunk.count <= limit else {
      throw NativeError.invalidRequest("snapshot exceeds 32 MiB")
    }
    input.append(chunk)
  }
  let request = try JSONDecoder().decode(NativeRequest.self, from: input)
  let response = try NativeExecutor.execute(request)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let output = try encoder.encode(response)
  guard output.count <= limit else { throw NativeError.invalidRequest("result exceeds 32 MiB") }
  FileHandle.standardOutput.write(output)
  FileHandle.standardOutput.write(Data([0x0a]))
} catch {
  // No user payload, identifiers, or secrets are echoed in process diagnostics.
  FileHandle.standardError.write(Data("canonical lifecycle operation rejected: \(type(of: error))\n".utf8))
  exit(1)
}
