import Darwin
import Foundation

private struct ReducerSnapshot: Codable {
    let schemaVersion: UInt8
    let savedAtMillis: Int64
    let reducer: LifecycleReducer
}

struct StateStore {
    let paths: RuntimePaths

    func load() -> LifecycleReducer {
        guard let data = readSnapshot(),
              let snapshot = try? JSONDecoder().decode(ReducerSnapshot.self, from: data),
              snapshot.schemaVersion == LifecycleRecord.schemaVersion else {
            return LifecycleReducer()
        }
        return snapshot.reducer
    }

    func save(_ reducer: LifecycleReducer) throws {
        try paths.prepare()
        let snapshot = ReducerSnapshot(
            schemaVersion: LifecycleRecord.schemaVersion,
            savedAtMillis: Int64(Date().timeIntervalSince1970 * 1_000),
            reducer: reducer
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Constants.maximumSpoolBytes else {
            throw HookJournalError.recordTooLarge
        }
        try writeAtomically(data, to: paths.stateSnapshot)
    }

    func archiveLegacyJournalIfNeeded() {
        guard paths.legacyEventJournal != paths.eventSpool,
              FileManager.default.fileExists(atPath: paths.legacyEventJournal.path) else {
            return
        }
        let descriptor = open(
            paths.legacyEventJournal.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_size <= off_t(Constants.maximumSpoolBytes),
              fchmod(descriptor, 0o600) == 0 else {
            return
        }
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let archive = paths.baseDirectory
            .appendingPathComponent("events-v1-\(stamp).archived")
        guard rename(paths.legacyEventJournal.path, archive.path) == 0 else {
            return
        }
    }

    private func readSnapshot() -> Data? {
        let descriptor = open(
            paths.stateSnapshot.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_size >= 0,
              information.st_size <= off_t(Constants.maximumSpoolBytes) else {
            return nil
        }

        let expected = Int(information.st_size)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, max(expected, 1)))
        while data.count < expected {
            let requested = min(buffer.count, expected - data.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw HookJournalError.openFailed(errno)
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                unlink(temporary.path)
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw HookJournalError.writeFailed(errno)
                }
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary.path, destination.path) == 0 else {
            throw HookJournalError.writeFailed(errno)
        }
        shouldRemove = false

        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
    }
}
