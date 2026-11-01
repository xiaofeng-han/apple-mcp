import Foundation
import Wire

/// What Journal keeps about one of an entry's attachments ("assets"): its kind, the details its
/// metadata holds, and its files. The metadata is JSON whose keys are its Swift properties; dates
/// are seconds since 2001, data is base64. In the store's file it follows a byte 1, Core Data's
/// mark for data kept in the row.
package struct AssetInfo: Sendable {
    package let id: String
    /// Journal's asset type: photo, video, livePhoto, audio, visit, multiPinMap, genericMap,
    /// stateOfMind, workoutIcon, workoutRoute, motionActivity, music, podcast, book,
    /// thirdPartyMedia, contact, link, reflection, drawing, confetti, …
    package let kind: String
    /// Hidden from the entry's grid (Journal keeps them for its layout).
    package let hidden: Bool
    package let details: [String: JSON]
    package let files: [AssetFile]

    package init(id: String, kind: String, hidden: Bool, details: [String: JSON], files: [AssetFile]) {
        self.id = id
        self.kind = kind
        self.hidden = hidden
        self.details = details
        self.files = files
    }

    /// The words to search: places, people, titles, transcripts, handwriting.
    package var searchText: String {
        func strings(_ value: JSON) -> [String] {
            switch value {
            case .string(let s): [s]
            case .array(let items): items.flatMap(strings)
            case .object(let fields): fields.values.flatMap(strings)
            default: []
            }
        }
        return details.values.flatMap(strings).joined(separator: " ")
    }
}

package struct AssetFile: Sendable {
    /// Journal's name for the file's role: "image", "video", "audio", "thumbnail", …
    package let name: String
    package let url: URL
    package var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    package init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

package enum AssetDetails {
    /// The kinds find_entries filters by, with the asset types each covers.
    package static let kinds: [(name: String, types: Set<String>)] = [
        ("photo", ["photo", "livePhoto"]), ("video", ["video"]), ("audio", ["audio"]),
        ("place", ["visit", "multiPinMap", "genericMap"]), ("state_of_mind", ["stateOfMind"]),
        ("workout", ["workoutIcon", "workoutRoute"]), ("activity", ["motionActivity"]),
        ("music", ["music", "thirdPartyMedia"]), ("podcast", ["podcast"]), ("book", ["book"]), ("contact", ["contact"]),
        ("link", ["link"]), ("reflection", ["reflection"]), ("drawing", ["drawing"]), ("event", ["confetti"]),
    ]

    /// The kind find_entries and read_entry name an asset type by.
    package static func kind(_ type: String) -> String { kinds.first { $0.types.contains(type) }?.name ?? type }

    package static let reference = Date(timeIntervalSinceReferenceDate: 0)

    /// The metadata's JSON object, or nil.
    package static func json(_ data: Data?) -> [String: Any]? {
        guard let data, data.count > 1 else { return nil }
        let body = data.first == 1 ? data.dropFirst() : data[...]
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    /// The details worth showing, by asset type.
    package static func details(type: String, metadata: Data?) -> [String: JSON] {
        guard let m = json(metadata) else { return [:] }
        var out: [String: JSON] = [:]
        func text(_ key: String, as name: String? = nil) {
            if let value = m[key] as? String, !value.isEmpty { out[name ?? key] = .string(value) }
        }
        func number(_ key: String, as name: String? = nil) {
            if let value = m[key] as? Double { out[name ?? key] = .double((value * 100_000).rounded() / 100_000) }
        }
        func date(_ key: String, as name: String) {
            if let value = m[key] as? Double { out[name] = .string(Stamp.minute(Date(timeIntervalSinceReferenceDate: value))) }
        }
        func seconds(_ key: String, as name: String = "duration_seconds") {
            if let value = m[key] as? Double { out[name] = .int(Int(value.rounded())) }
        }
        switch type {
        case "photo", "livePhoto", "video":
            date("date", as: "taken")
            text("placeName", as: "place")
            number("latitude")
            number("longitude")
        case "audio":
            date("recordingDate", as: "recorded")
            seconds("duration")
            let segments = (m["transcriptSegments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if !segments.isEmpty { out["transcript"] = .string(segments.joined(separator: " ")) }
        case "visit":
            out.merge(visit(m)) { a, _ in a }
        case "genericMap":
            if let v = m["visitsData"] as? [String: Any] { out.merge(visit(v)) { a, _ in a } }
        case "multiPinMap":
            let places = (m["visitsData"] as? [[String: Any]] ?? []).map { JSON.object(visit($0)) }
            if !places.isEmpty { out["places"] = .array(places) }
        case "stateOfMind":
            if let kind = m["reflectiveInterval"] as? Int { out["kind"] = .string(kind == 2 ? "daily mood" : "momentary emotion") }
            if let valence = m["valenceClassification"] as? Int, StateOfMind.valence.indices.contains(valence - 1) {
                out["feeling"] = .string(StateOfMind.valence[valence - 1])
            }
            let labels = (m["labels"] as? [Int] ?? []).compactMap { StateOfMind.labels.indices.contains($0 - 1) ? StateOfMind.labels[$0 - 1] : nil }
            if !labels.isEmpty { out["describes_it"] = .array(labels.map { .string($0) }) }
            let domains = (m["domains"] as? [Int] ?? []).compactMap { StateOfMind.associations.indices.contains($0 - 1) ? StateOfMind.associations[$0 - 1] : nil }
            if !domains.isEmpty { out["because_of"] = .array(domains.map { .string($0) }) }
            date("date", as: "logged")
        case "workoutIcon", "workoutRoute":
            text("type", as: "workout")
            date("startTime", as: "start")
            date("endTime", as: "end")
            seconds("duration")
            text("calories")
            text("distance")
            if let count = m["numberOfWorkouts"] as? Int, count > 1 { out["workouts"] = .int(count) }
        case "motionActivity":
            text("localizedActivityName", as: "activity")
            if out["activity"] == nil { text("activityType", as: "activity") }
            text("steps")
            date("startTime", as: "start")
            date("endTime", as: "end")
        case "music", "thirdPartyMedia":
            text("song", as: "title")
            text("artistName", as: "artist")
            text("albumName", as: "album")
            text("appName", as: "app")
            date("startTime", as: "played")
            text("mediaURL", as: "url")
        case "podcast":
            text("title")
            text("author")
            date("timePlayed", as: "played")
            text("mediaURL", as: "url")
        case "book":
            text("title")
            text("author")
        case "contact":
            text("name")
            date("startTime", as: "start")
            date("endTime", as: "end")
            seconds("duration")
            if let count = m["numberOfExchanges"] as? Int { out["exchanges"] = .int(count) }
        case "link":
            text("url")
            date("date", as: "added")
        case "reflection":
            if let base64 = m["prompt"] as? String, let data = Data(base64Encoded: base64) {
                let prompt = EntryText.fromRTF(data)?.string ?? String(data: data, encoding: .utf8)
                if let prompt, !prompt.isEmpty { out["prompt"] = .string(prompt) }
            }
        case "drawing":
            text("indexableContent", as: "handwriting")
        case "confetti":
            text("placeName", as: "place")
            date("startDate", as: "start")
            date("endDate", as: "end")
        default:
            break
        }
        return out
    }

    package static func visit(_ m: [String: Any]) -> [String: JSON] {
        var out: [String: JSON] = [:]
        if let name = m["placeName"] as? String, !name.isEmpty { out["place"] = .string(name) }
        if let city = m["city"] as? String, !city.isEmpty { out["city"] = .string(city) }
        if let type = m["typeOfPlace"] as? String, !type.isEmpty { out["type"] = .string(type) }
        if let start = m["visitStartTime"] as? Double { out["from"] = .string(Stamp.minute(Date(timeIntervalSinceReferenceDate: start))) }
        if let end = m["visitEndTime"] as? Double { out["to"] = .string(Stamp.minute(Date(timeIntervalSinceReferenceDate: end))) }
        if let latitude = m["latitude"] as? Double { out["latitude"] = .double((latitude * 100_000).rounded() / 100_000) }
        if let longitude = m["longitude"] as? Double { out["longitude"] = .double((longitude * 100_000).rounded() / 100_000) }
        return out
    }
}

/// HealthKit's names for a State of Mind, in the order of its raw values (1 first).
package enum StateOfMind {
    package static let valence = ["very unpleasant", "unpleasant", "slightly unpleasant", "neutral", "slightly pleasant", "pleasant", "very pleasant"]
    package static let labels = [
        "amazed", "amused", "angry", "anxious", "ashamed", "brave", "calm", "content", "disappointed", "discouraged",
        "disgusted", "embarrassed", "excited", "frustrated", "grateful", "guilty", "happy", "hopeless", "irritated",
        "jealous", "joyful", "lonely", "passionate", "peaceful", "proud", "relieved", "sad", "scared", "stressed",
        "surprised", "worried", "annoyed", "confident", "drained", "hopeful", "indifferent", "overwhelmed", "satisfied",
    ]
    package static let associations = [
        "community", "current events", "dating", "education", "family", "fitness", "friends", "health", "hobbies",
        "identity", "money", "partner", "self care", "spirituality", "tasks", "travel", "work", "weather",
    ]
}
