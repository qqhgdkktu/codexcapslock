import Foundation

private struct TranscriptFileState {
    var offset: UInt64
    var remainder: Data
    var sessionID: String?
    var modifiedAt: Date
}

final class TranscriptMonitor {
    private let sessionsDirectory: URL
    private var files: [URL: TranscriptFileState] = [:]
    private var lastDiscoveryAt = Date.distantPast
    private let discoveryInterval: TimeInterval = 2.0
    private let initialLookback: TimeInterval = 60 * 60

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
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
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
            files[url] = TranscriptFileState(
                offset: 0,
                remainder: Data(),
                sessionID: sessionIDFromFilename(url),
                modifiedAt: modifiedAt
            )
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
            state.remainder.removeAll(keepingCapacity: true)
        }
        guard size > state.offset,
              let handle = try? FileHandle(forReadingFrom: url) else {
            files[url] = state
            return []
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            let data = try handle.readToEnd() ?? Data()
            state.offset += UInt64(data.count)
            state.remainder.append(data)
        } catch {
            files[url] = state
            return []
        }

        var events: [TranscriptEvent] = []
        while let newline = state.remainder.firstIndex(of: 0x0A) {
            let line = Data(state.remainder[..<newline])
            state.remainder.removeSubrange(...newline)
            events.append(contentsOf: parseLine(line, state: &state))
        }

        files[url] = state
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
