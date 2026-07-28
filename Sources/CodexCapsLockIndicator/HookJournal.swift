import Darwin
import Foundation

enum HookJournalError: Error {
    case invalidPayload
    case invalidIdentifier
    case encodeFailed
    case recordTooLarge
    case openFailed(Int32)
    case unsafeFile
    case lockFailed(Int32)
    case spoolFull
    case readFailed(Int32)
    case writeFailed(Int32)
}

struct JournalBatch: Sendable {
    let records: [LifecycleRecord]
    let consumedBytes: Int
    let inode: ino_t
}

struct HookJournalWriter {
    let paths: RuntimePaths

    func append(action: LifecycleAction, source: CodingAgent, inputData: Data) throws {
        guard inputData.count <= Constants.maximumHookPayloadBytes,
              let input = try? JSONDecoder().decode(HookInput.self, from: inputData),
              let rawSessionID = input.sessionID,
              Self.validIdentifier(rawSessionID) else {
            throw HookJournalError.invalidPayload
        }
        if let turnID = input.turnID, !Self.validIdentifier(turnID) {
            throw HookJournalError.invalidIdentifier
        }
        if let callID = input.callID, !Self.validIdentifier(callID) {
            throw HookJournalError.invalidIdentifier
        }

        let kind: LifecycleEventKind
        switch action {
        case .promptSubmitted:
            kind = .promptSubmitted
        case .toolStarted:
            kind = .toolStarted(callID: input.callID)
        case .permissionRequested:
            kind = .permissionRequested(callID: input.callID)
        case .inputRequested:
            kind = .inputRequested(callID: input.callID)
        case .toolFinished:
            kind = .toolFinished(callID: input.callID)
        case .stopped:
            kind = .stopped(outcome: .completed)
        case .stopFailed:
            kind = .stopped(outcome: .failed)
        case .sessionEnded:
            kind = .sessionEnded
        }

        try append(LifecycleRecord(
            source: source,
            sessionID: source.scopedSessionID(rawSessionID),
            turnID: input.turnID,
            emittedAtMillis: Self.currentTimeMillis(),
            kind: kind
        ))
    }

    func appendAcknowledgement(completionID: UUID? = nil) throws {
        try append(LifecycleRecord(
            source: .codex,
            sessionID: "*",
            turnID: nil,
            emittedAtMillis: Self.currentTimeMillis(),
            kind: .acknowledged(completionID: completionID)
        ))
    }

    func appendAcknowledgementAll() throws {
        try append(LifecycleRecord(
            source: .codex,
            sessionID: "*",
            turnID: nil,
            emittedAtMillis: Self.currentTimeMillis(),
            kind: .acknowledgedAll
        ))
    }

    private func append(_ record: LifecycleRecord) throws {
        try paths.prepare()
        if let response = DaemonControlClient(
            socketURL: paths.controlSocket
        ).send(lifecycleRecord: record), response.succeeded {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        guard data.count <= Constants.maximumLifecycleRecordBytes else {
            throw HookJournalError.recordTooLarge
        }
        data.append(0x0A)

        try withTransportLock(paths: paths, operation: {
            let descriptor = open(
                paths.eventSpool.path,
                O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
            guard descriptor >= 0 else {
                throw HookJournalError.openFailed(errno)
            }
            defer { close(descriptor) }
            try validateRegularUserFile(descriptor)
            guard fchmod(descriptor, 0o600) == 0 else {
                throw HookJournalError.unsafeFile
            }

            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw HookJournalError.unsafeFile
            }
            guard information.st_size >= 0,
                  information.st_size <= off_t(Constants.maximumSpoolBytes) else {
                throw HookJournalError.unsafeFile
            }
            let repairedSize = try truncateIncompleteTail(
                descriptor,
                currentSize: information.st_size
            )
            guard repairedSize + off_t(data.count)
                    <= off_t(Constants.maximumSpoolBytes) else {
                throw HookJournalError.spoolFull
            }
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw HookJournalError.writeFailed(errno)
            }
        })
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let count = value.lengthOfBytes(using: .utf8)
        return (1...Constants.maximumIdentifierBytes).contains(count)
            && !value.utf8.contains(0)
    }

    private static func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

struct HookJournalReader {
    let paths: RuntimePaths

    init(paths: RuntimePaths) {
        self.paths = paths
    }

    init(url: URL) {
        let base = url.deletingLastPathComponent()
        paths = RuntimePaths(
            baseDirectory: base,
            eventJournal: url,
            statusFile: base.appendingPathComponent("status.json"),
            codexHome: base.appendingPathComponent("codex"),
            sessionsDirectory: base.appendingPathComponent("sessions"),
            logsDatabase: base.appendingPathComponent("logs.sqlite")
        )
    }

    func readBatch() -> JournalBatch? {
        try? withTransportLock(paths: paths) {
            let descriptor = open(paths.eventSpool.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                return nil
            }
            defer { close(descriptor) }
            try validateRegularUserFile(descriptor)

            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_size > 0,
                  information.st_size <= off_t(Constants.maximumSpoolBytes) else {
                return nil
            }

            let data = try readExactly(
                from: descriptor,
                maximumBytes: Int(information.st_size)
            )
            guard let finalNewline = data.lastIndex(of: 0x0A) else {
                return nil
            }
            let consumedBytes = data.distance(
                from: data.startIndex,
                to: data.index(after: finalNewline)
            )
            let consumed = data.prefix(consumedBytes)
            var records: [LifecycleRecord] = []
            let decoder = JSONDecoder()

            for rawLine in consumed.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard rawLine.count <= Constants.maximumLifecycleRecordBytes,
                      let record = try? decoder.decode(LifecycleRecord.self, from: Data(rawLine)),
                      validate(record) else {
                    continue
                }
                records.append(record)
            }
            return JournalBatch(
                records: records,
                consumedBytes: consumedBytes,
                inode: information.st_ino
            )
        }
    }

    func commit(_ batch: JournalBatch) throws {
        try withTransportLock(paths: paths) {
            let descriptor = open(paths.eventSpool.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                return
            }
            defer { close(descriptor) }
            try validateRegularUserFile(descriptor)

            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_ino == batch.inode,
                  information.st_size >= off_t(batch.consumedBytes),
                  information.st_size <= off_t(Constants.maximumSpoolBytes) else {
                return
            }
            guard lseek(descriptor, off_t(batch.consumedBytes), SEEK_SET) >= 0 else {
                throw HookJournalError.readFailed(errno)
            }
            let remaining = try readExactly(
                from: descriptor,
                maximumBytes: Int(information.st_size) - batch.consumedBytes
            )
            try atomicReplace(remaining, at: paths.eventSpool)
        }
    }

    private func validate(_ record: LifecycleRecord) -> Bool {
        guard record.schemaVersion == LifecycleRecord.schemaVersion else {
            return false
        }
        let sessionBytes = record.sessionID.lengthOfBytes(using: .utf8)
        guard (1...Constants.maximumIdentifierBytes).contains(sessionBytes),
              !record.sessionID.utf8.contains(0) else {
            return false
        }
        if let turnID = record.turnID {
            let bytes = turnID.lengthOfBytes(using: .utf8)
            guard (1...Constants.maximumIdentifierBytes).contains(bytes),
                  !turnID.utf8.contains(0) else {
                return false
            }
        }
        let callID: String?
        switch record.kind {
        case let .toolStarted(value),
             let .permissionRequested(value),
             let .inputRequested(value),
             let .toolFinished(value):
            callID = value
        default:
            callID = nil
        }
        if let callID {
            let bytes = callID.lengthOfBytes(using: .utf8)
            guard (1...Constants.maximumIdentifierBytes).contains(bytes),
                  !callID.utf8.contains(0) else {
                return false
            }
        }
        return true
    }
}

private func truncateIncompleteTail(
    _ descriptor: Int32,
    currentSize: off_t
) throws -> off_t {
    guard currentSize > 0 else {
        return 0
    }
    var finalByte: UInt8 = 0
    while true {
        let count = pread(descriptor, &finalByte, 1, currentSize - 1)
        if count == 1 {
            break
        }
        if count < 0, errno == EINTR {
            continue
        }
        throw HookJournalError.readFailed(errno)
    }
    guard finalByte != 0x0A else {
        return currentSize
    }
    let size = Int(currentSize)
    var data = Data(count: size)
    let readCount = try data.withUnsafeMutableBytes { bytes -> Int in
        guard let baseAddress = bytes.baseAddress else {
            return 0
        }
        var offset = 0
        while offset < size {
            let count = pread(
                descriptor,
                baseAddress.advanced(by: offset),
                size - offset,
                off_t(offset)
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw HookJournalError.readFailed(errno)
            }
        }
        return offset
    }
    guard readCount == size else {
        throw HookJournalError.readFailed(errno)
    }
    let repairedSize: Int
    if let newline = data.lastIndex(of: 0x0A) {
        repairedSize = data.distance(
            from: data.startIndex,
            to: data.index(after: newline)
        )
    } else {
        repairedSize = 0
    }
    guard ftruncate(descriptor, off_t(repairedSize)) == 0,
          fsync(descriptor) == 0 else {
        throw HookJournalError.writeFailed(errno)
    }
    return off_t(repairedSize)
}

private func withTransportLock<T>(
    paths: RuntimePaths,
    operation: () throws -> T
) throws -> T {
    let lockURL = paths.baseDirectory.appendingPathComponent("transport.lock")
    let descriptor = open(
        lockURL.path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else {
        throw HookJournalError.openFailed(errno)
    }
    defer { close(descriptor) }
    try validateRegularUserFile(descriptor)
    guard fchmod(descriptor, 0o600) == 0 else {
        throw HookJournalError.unsafeFile
    }
    while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else {
            throw HookJournalError.lockFailed(errno)
        }
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
}

private func validateRegularUserFile(_ descriptor: Int32) throws {
    var information = stat()
    guard fstat(descriptor, &information) == 0,
          (information.st_mode & S_IFMT) == S_IFREG,
          information.st_uid == geteuid(),
          information.st_nlink == 1 else {
        throw HookJournalError.unsafeFile
    }
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
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
}

private func readExactly(from descriptor: Int32, maximumBytes: Int) throws -> Data {
    guard maximumBytes > 0 else {
        return Data()
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes))
    while result.count < maximumBytes {
        let requested = min(buffer.count, maximumBytes - result.count)
        let count = Darwin.read(descriptor, &buffer, requested)
        if count > 0 {
            result.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            throw HookJournalError.readFailed(errno)
        }
    }
    return result
}

private func atomicReplace(_ data: Data, at destination: URL) throws {
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
    try writeAll(data, to: descriptor)
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
