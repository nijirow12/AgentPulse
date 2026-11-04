import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var stringValue: String? {
        switch self {
        case .text(let value): value
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .blob(let data): String(data: data, encoding: .utf8)
        case .null: nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .integer(let value): value
        case .real(let value): Int64(value)
        case .text(let value): Int64(value)
        case .blob, .null: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        case .text(let value): Double(value)
        case .blob, .null: nil
        }
    }
}

public typealias SQLiteRow = [String: SQLiteValue]

/// Thin read-only wrapper around the system SQLite. Never writes.
public final class SQLiteReader: @unchecked Sendable {
    private var db: OpaquePointer?

    public init?(path: String) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        sqlite3_busy_timeout(handle, 1000)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Runs a query and returns the rows as dictionaries keyed by column name.
    /// Returns `nil` when the statement cannot be prepared or stepped.
    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) -> [SQLiteRow]? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
        }

        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for column in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, column)))
        }

        var rows: [SQLiteRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                var row = SQLiteRow(minimumCapacity: names.count)
                for column in 0..<columnCount {
                    let name = names[Int(column)]
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        row[name] = .integer(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT:
                        row[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_TEXT:
                        if let pointer = sqlite3_column_text(statement, column) {
                            row[name] = .text(String(cString: pointer))
                        } else {
                            row[name] = .null
                        }
                    case SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(statement, column))
                        if length > 0, let pointer = sqlite3_column_blob(statement, column) {
                            row[name] = .blob(Data(bytes: pointer, count: length))
                        } else {
                            row[name] = .blob(Data())
                        }
                    default:
                        row[name] = .null
                    }
                }
                rows.append(row)
            } else if step == SQLITE_DONE {
                break
            } else {
                return nil
            }
        }
        return rows
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
