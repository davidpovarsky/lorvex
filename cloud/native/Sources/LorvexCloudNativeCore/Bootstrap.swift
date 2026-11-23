import Foundation
import LorvexStore

package enum Bootstrap {
  package static func store() throws -> LorvexStore {
    guard let schema = Bundle.module.url(forResource: "schema", withExtension: "sql"),
      let directory = Bundle.module.url(forResource: "Migrations", withExtension: nil)
    else { throw NativeError.missingResource("canonical schema and migrations") }
    let entries = try JSONDecoder().decode([String: MigrationEntry].self,
      from: Data(contentsOf: directory.appendingPathComponent("checksums.lock")))
    let migrations = try entries.compactMap { key, value -> LorvexStore.SchemaMigration? in
      guard let version = Int(key), version >= 2 else { return nil }
      guard value.name.hasSuffix(".sql"), let underscore = value.name.firstIndex(of: "_"),
        !value.name.contains("/"), !value.name.contains("..") else {
        throw NativeError.missingResource("invalid migration filename")
      }
      let name = String(value.name[value.name.index(after: underscore)...].dropLast(4))
      let sql = try String(contentsOf: directory.appendingPathComponent(value.name), encoding: .utf8)
      return LorvexStore.SchemaMigration(version: version, name: name, sql: sql)
    }.sorted { $0.version < $1.version }
    return try LorvexStore.openInMemory(
      schemaSQL: String(contentsOf: schema, encoding: .utf8), migrations: migrations)
  }

  private struct MigrationEntry: Decodable { let name: String }
}
