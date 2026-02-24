// ============================================================
// EventRecorder.swift
// ARO Runtime - Event Recording and Replay for Debugging
// ============================================================

import Foundation

/// A recorded event with timestamp for replay
public struct RecordedEvent: Codable, Sendable {
    /// When the event occurred
    public let timestamp: Date

    /// Type name of the event
    public let eventType: String

    /// Event payload as JSON string
    public let payload: String

    public init(timestamp: Date, eventType: String, payload: String) {
        self.timestamp = timestamp
        self.eventType = eventType
        self.payload = payload
    }
}

/// Event recording session metadata
public struct EventRecording: Codable, Sendable {
    public let version: String
    public let application: String
    public let recorded: Date
    public let events: [RecordedEvent]

    public init(application: String, events: [RecordedEvent]) {
        self.version = "1.0"
        self.application = application
        self.recorded = Date()
        self.events = events
    }
}

/// Records events for debugging and replay
/// GitLab #124: Event replay and persistence
public actor EventRecorder {
    private var events: [(timestamp: Date, eventType: String, payload: String)] = []
    private var isRecording = false
    private var subscriptionId: UUID?
    private let eventBus: EventBus

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
    }

    /// Start recording all events
    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        events.removeAll()

        // Subscribe to all events
        subscriptionId = eventBus.subscribe(to: "*") { [weak self] event in
            guard let self else { return }
            Task {
                await self.recordEvent(event)
            }
        }
    }

    /// Stop recording and return captured events
    public func stopRecording() -> [RecordedEvent] {
        isRecording = false

        if let id = subscriptionId {
            eventBus.unsubscribe(id)
            subscriptionId = nil
        }

        return events.map { RecordedEvent(timestamp: $0.timestamp, eventType: $0.eventType, payload: $0.payload) }
    }

    /// Save recorded events to file
    public func saveToFile(_ path: String, applicationName: String = "ARO Application") async throws {
        let recordedEvents = events.map { RecordedEvent(timestamp: $0.timestamp, eventType: $0.eventType, payload: $0.payload) }
        let recording = EventRecording(application: applicationName, events: recordedEvents)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(recording)
        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
    }

    /// Record an event
    private func recordEvent(_ event: any RuntimeEvent) {
        guard isRecording else { return }

        let eventType = type(of: event).eventType
        let payload = serializeEvent(event)

        events.append((timestamp: Date(), eventType: eventType, payload: payload))
    }

    /// Serialize event to JSON string
    private func serializeEvent(_ event: any RuntimeEvent) -> String {
        // Use reflection to extract event properties
        let mirror = Mirror(reflecting: event)
        var dict: [String: Any] = [:]

        for child in mirror.children {
            if let label = child.label {
                dict[label] = String(describing: child.value)
            }
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }

    /// Check if currently recording
    public var recording: Bool {
        isRecording
    }

    /// Get count of recorded events
    public var eventCount: Int {
        events.count
    }
}

/// Replays recorded events for debugging
/// GitLab #124: Event replay and persistence
public actor EventReplayer {
    private let eventBus: EventBus

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
    }

    /// Load recording from file
    public func loadFromFile(_ path: String) throws -> EventRecording {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(EventRecording.self, from: data)
    }

    /// Replay events with timing preserved
    /// - Parameters:
    ///   - recording: The event recording to replay
    ///   - speed: Playback speed (1.0 = normal, 2.0 = 2x speed, etc.)
    public func replay(_ recording: EventRecording, speed: Double = 1.0) async throws {
        var lastTimestamp: Date?

        for recorded in recording.events {
            // Preserve relative timing between events
            if let last = lastTimestamp {
                let delay = recorded.timestamp.timeIntervalSince(last) / speed
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            // Reconstruct and publish event
            // Note: We publish a generic DomainEvent with the recorded payload
            let replayedEvent = ReplayedEvent(
                originalType: recorded.eventType,
                timestamp: recorded.timestamp,
                payload: recorded.payload
            )
            eventBus.publish(replayedEvent)

            lastTimestamp = recorded.timestamp
        }
    }

    /// Replay events without timing delays
    public func replayFast(_ recording: EventRecording) {
        for recorded in recording.events {
            let replayedEvent = ReplayedEvent(
                originalType: recorded.eventType,
                timestamp: recorded.timestamp,
                payload: recorded.payload
            )
            eventBus.publish(replayedEvent)
        }
    }
}

/// Event emitted during replay
public struct ReplayedEvent: RuntimeEvent {
    public static let eventType = "Replayed"

    public let originalType: String
    public let timestamp: Date
    public let payload: String

    public init(originalType: String, timestamp: Date, payload: String) {
        self.originalType = originalType
        self.timestamp = timestamp
        self.payload = payload
    }
}
