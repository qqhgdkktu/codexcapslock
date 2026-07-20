import Foundation
import SQLite3

final class CodexLogWatcher {
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var lastID: Int64 = 0

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func pollThreadStatusChangeCount() -> Int {
        guard openIfNeeded(), let database else {
            return 0
        }

        var statement: OpaquePointer?
        let sql = """
        SELECT id, target, feedback_log_body
        FROM logs
        WHERE id > ?
        ORDER BY id ASC
        """

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, lastID)
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            lastID = max(lastID, rowID)
            guard let targetText = sqlite3_column_text(statement, 1),
                  String(cString: targetText) == "codex_app_server::outgoing_message",
                  let text = sqlite3_column_text(statement, 2) else {
                continue
            }
            let body = String(cString: text)
            if body.contains("thread/status/changed") {
                count += 1
            }
        }
        return count
    }

    private func openIfNeeded() -> Bool {
        if database != nil {
            return true
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            return false
        }
        database = handle

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT COALESCE(MAX(id), 0) FROM logs", -1, &statement, nil) == SQLITE_OK,
           let statement {
            if sqlite3_step(statement) == SQLITE_ROW {
                lastID = sqlite3_column_int64(statement, 0)
            }
            sqlite3_finalize(statement)
        }
        return true
    }
}
