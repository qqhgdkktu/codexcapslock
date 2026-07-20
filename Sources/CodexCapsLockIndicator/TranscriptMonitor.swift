import Foundation

private struct TranscriptFileState {
    var offset: UInt64
    var remainder: Data
    var discardingPartialLine: Bool
    var sessionID: String?
    var modifiedAt: Date
}

final class TranscriptMonitor {
    private let sessionsDirectory: URL
    private var files: [URL: TranscriptFileState] = [:]
    private var lastDiscoveryAt = Date.distantPast
    private let discoveryInterval: TimeInterval = 2.0
    private let initialLookback: TimeInterval = 60 * 60
    private let initialTailBytes: UInt64 = 256 * 1024
    private let readChunkBytes = 64 * 1024
    private let maximumLifecycleLineBytes = 128 * 1024

    init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    func poll(now: Date = Date()) -> [TranscriptEvent] {
        if now.timeIntervalSince(lastDiscoveryAt) >= discoveryInterval {
            discoverFiles(now: now)
            lastDiscoveryAt = now
        }

        var events: [TranscriptEvent] = []
        for url in files.keys.sorted(by: { $0.path < $1.path }) {
            events.append(contentsOf: readAppendedLines(from: url))
        }
        return events
    }

    private func discoverFiles(now: Date) {
        for directory in recentDayDirectories(now: now) {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                ]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate else {
                    continue
                }

                if var existing = files[url] {
                    existing.modifiedAt = modifiedAt
                    files[url] = existing
                    continue
                }

                guard now.timeIntervalSince(modifiedAt) <= initialLookback else {
                    continue
                }
                let size = UInt64(max(0, values.fileSize ?? 0))
                let offset = size > initialTailBytes ? size - initialTailBytes : 0
                files[url] = TranscriptFileState(
                    offset: offset,
                    remainder: Data(),
                    discardingPartialLine: offset > 0,
                    sessionID: sessionIDFromFilename(url),
                    modifiedAt: modifiedAt
                )
            }
        }
    }

    private func recentDayDirectories(now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return [0, -1].compactMap { dayOffset in
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return sessionsDirectory
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func readAppendedLines(from url: URL) -> [TranscriptEvent] {
        guard var state = files[url],
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return []
        }

        let size = number.uint64Value
        if size < state.offset {
            state.offset = 0
            state.remainder.removeAll(keepingCapacity: false)
            state.discardingPartialLine = false
        }
        guard size > state.offset,
              let handle = try? FileHandle(forReadingFrom: url) else {
            files[url] = state
            return []
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            var events: [TranscriptEvent] = []
            while state.offset < size {
                let remaining = size - state.offset
                let count = min(readChunkBytes, Int(remaining))
                guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                    break
                }
                state.offset += UInt64(data.count)
                state.remainder.append(data)
                events.append(contentsOf: consumeCompleteLines(state: &state))
            }
            files[url] = state
            return events
        } catch {
            files[url] = state
            return []
        }
    }

    private func consumeCompleteLines(state: inout TranscriptFileState) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        while let newline = state.remainder.firstIndex(of: 0x0A) {
            if state.discardingPartialLine {
                state.remainder.removeSubrange(...newline)
                state.discardingPartialLine = false
                continue
            }

            let lineLength = state.remainder.distance(from: state.remainder.startIndex, to: newline)
            if lineLength <= maximumLifecycleLineBytes {
                let line = Data(state.remainder[..<newline])
                events.append(contentsOf: parseLine(line, state: &state))
            }
            state.remainder.removeSubrange(...newline)
        }

        if state.remainder.count > maximumLifecycleLineBytes {
            state.remainder.removeAll(keepingCapacity: false)
            state.discardingPartialLine = true
        }
        return events
    }

    private func parseLine(_ data: Data, state: inout TranscriptFileState) -> [TranscriptEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else {
            return []
        }

        if type == "session_meta" {
            state.sessionID = (payload["id"] as? String)
                ?? (payload["session_id"] as? String)
                ?? state.sessionID
            return []
        }

        guard let sessionID = state.sessionID else {
            return []
        }

        if type == "event_msg", let eventType = payload["type"] as? String {
            let turnID = payload["turn_id"] as? String
            switch eventType {
            case "task_started", "turn_started":
                return [.turnStarted(sessionID: sessionID, turnID: turnID)]
            case "task_complete", "turn_complete", "turn_aborted":
                return [.turnCompleted(sessionID: sessionID, turnID: turnID)]
            case "shutdown_complete":
                return [.sessionEnded(sessionID: sessionID)]
            default:
                return []
            }
        }

        if type == "response_item", let itemType = payload["type"] as? String {
            let callID = payload["call_id"] as? String
            if itemType == "function_call" || itemType == "custom_tool_call" {
                let name = (payload["name"] as? String)?.lowercased()
                if name == "request_user_input" || name == "request_permissions" {
                    return [.waitingForInput(sessionID: sessionID, callID: callID)]
                }
            }

            if itemType == "function_call_output" || itemType == "custom_tool_call_output" {
                return [.activityResumed(sessionID: sessionID, callID: callID)]
            }
        }

        return []
    }

    private func sessionIDFromFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: "rollout-", options: .backwards) else {
            return nil
        }
        let suffix = stem[range.upperBound...]
        let components = suffix.split(separator: "-")
        guard components.count >= 5 else {
            return nil
        }
        return components.suffix(5).joined(separator: "-")
    }
}
