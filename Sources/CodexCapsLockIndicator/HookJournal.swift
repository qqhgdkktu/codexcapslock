import Darwin
import Foundation

enum HookJournalError: Error {
    case encodeFailed
    case openFailed(Int32)
    case writeFailed(Int32)
}

struct HookJournalWriter {
    let paths: RuntimePaths

    func append(state: IndicatorMode, inputData: Data) throws {
        try paths.prepare()

        let input = (try? JSONDecoder().decode(HookInput.self, from: inputData))
        let signal = HookSignal(
            state: state,
            sessionID: input?.sessionID ?? "unknown",
            turnID: input?.turnID,
            hookEventName: input?.hookEventName,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(signal)
        data.append(0x0A)

        let descriptor = open(paths.eventJournal.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
            throw HookJournalError.openFailed(errno)
        }
        defer { close(descriptor) }

        _ = flock(descriptor, LOCK_EX)
        defer { _ = flock(descriptor, LOCK_UN) }

        let result = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard result == data.count else {
            throw HookJournalError.writeFailed(errno)
        }
    }
}

final class HookJournalReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var remainder = Data()

    init(url: URL) {
        self.url = url
    }

    func readNewSignals() -> [HookSignal] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return []
        }

        let size = fileSize.uint64Value
        if size < offset {
            offset = 0
            remainder.removeAll(keepingCapacity: true)
        }
        guard size > offset,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            remainder.append(data)
        } catch {
            return []
        }

        var signals: [HookSignal] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = remainder[..<newline]
            remainder.removeSubrange(...newline)
            guard !line.isEmpty,
                  let signal = try? decoder.decode(HookSignal.self, from: Data(line)) else {
                continue
            }
            signals.append(signal)
        }

        return signals
    }
}
