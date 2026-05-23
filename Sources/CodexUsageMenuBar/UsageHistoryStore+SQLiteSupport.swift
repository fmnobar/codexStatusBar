import Foundation
import SQLite3

extension UsageHistoryStore {
    func tableHasColumn(table: String, column: String, schema: String? = nil) throws -> Bool {
        let pragmaPrefix = schema.map { "\($0)." } ?? ""
        let statement = try prepare("PRAGMA \(pragmaPrefix)table_info(\(table))")
        defer { sqlite3_finalize(statement) }

        while true {
            let result = sqlite3_step(statement)

            switch result {
            case SQLITE_ROW:
                if columnText(statement, index: 1) == column {
                    return true
                }
            case SQLITE_DONE:
                return false
            default:
                throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
            }
        }
    }

    func tableExists(table: String, schema: String? = nil) throws -> Bool {
        let schemaName = schema ?? "main"
        let statement = try prepare(
            "SELECT EXISTS(SELECT 1 FROM \(schemaName).sqlite_master WHERE type = 'table' AND name = ?)"
        )
        defer { sqlite3_finalize(statement) }

        bindText(table, to: 1, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return false
        default:
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func periodStart(for timestamp: Int64, granularity: UsageHistoryGranularity) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let components: Set<Calendar.Component> = if granularity == .hour {
            [.year, .month, .day, .hour]
        } else {
            [.year, .month, .day]
        }

        return calendar.date(from: calendar.dateComponents(components, from: date))?.timeIntervalSince1970Int ?? timestamp
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")

        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)

        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw UsageHistoryStoreError.databaseOperationFailed(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageHistoryStoreError.statementPreparationFailed(lastErrorMessage)
        }

        return statement
    }

    func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageHistoryStoreError.databaseOperationFailed(lastErrorMessage)
        }
    }

    func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bindText(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindOptionalInt(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindOptionalBool(_ value: Bool?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindOptionalDate(_ value: Date?, to index: Int32, in statement: OpaquePointer) {
        bindOptionalInt(value?.timeIntervalSince1970Int, to: index, in: statement)
    }

    func normalizedModelName(_ value: String?) -> String? {
        CodexModelIdentifier.normalized(value)
    }

    static func normalizedModelSQLExpression(column: String) -> String {
        let cleanedModelExpression = """
        TRIM(REPLACE(REPLACE(REPLACE(\(column), char(9), ' '), char(10), ' '), char(13), ' '))
        """
        let firstTokenExpression = """
        CASE
            WHEN INSTR(\(cleanedModelExpression), ' ') > 0
                THEN SUBSTR(\(cleanedModelExpression), 1, INSTR(\(cleanedModelExpression), ' ') - 1)
            ELSE \(cleanedModelExpression)
        END
        """
        return """
        NULLIF(CASE
            WHEN (\(firstTokenExpression)) GLOB '*[^A-Za-z0-9._-]*' THEN NULL
            ELSE (\(firstTokenExpression))
        END, '')
        """
    }

    func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }

        return String(cString: text)
    }

    func optionalColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return columnText(statement, index: index)
    }

    func optionalColumnInt(_ statement: OpaquePointer, index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_int64(statement, index)
    }

    func optionalColumnBool(_ statement: OpaquePointer, index: Int32) -> Bool? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_int(statement, index) != 0
    }

    func optionalColumnDate(_ statement: OpaquePointer, index: Int32) -> Date? {
        optionalColumnInt(statement, index: index).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    func optionalColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return sqlite3_column_double(statement, index)
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    static func observedConsumedPercent(
        currentUsedPercent: Double,
        previousUsedPercent: Double?
    ) -> Double {
        guard let previousUsedPercent else {
            return 0
        }

        let consumedPercent = currentUsedPercent - previousUsedPercent
        return min(max(consumedPercent, 0), 100)
    }

    static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((date.timeIntervalSince1970Int / 60) * 60))
    }

    static func roundedToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(date.timeIntervalSince1970Int))
    }
}

extension Date {
    var timeIntervalSince1970Int: Int64 {
        Int64(timeIntervalSince1970.rounded(.down))
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
