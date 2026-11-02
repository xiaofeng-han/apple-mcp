import Foundation
import NoteModel
import Wire

/// One note of a list overview gives, worked out once: its line of text and its JSON (for
/// `--format json`) are both made from it.
@MainActor
struct ListedNote {
    let note: NoteInfo
    /// The version read_note gives; "?" for a note that cannot be read.
    let version: String
    /// The note's plain text, for its size and for the description taken from its first line.
    let text: String
    let attachments: [String: Int]
    /// The description saved with describe_note, whether or not the note changed since.
    let description: Descriptions.Entry?
    /// In a list of notes that need a description: about 300 characters after the title.
    var opening: String?
    /// In Recently Deleted: when it went there, and how many days Notes keeps it still.
    var deleted: (date: Date, daysLeft: Int)?

    var descriptionCurrent: Bool { Descriptions.isCurrent(description, modified: note.modified) }

    /// "2.3k chars, 3 images, 1 table", or locked.
    var size: String { note.locked ? "locked" : Output.size(characters: text.count, attachments: attachments) }

    /// The description column: the saved description, marked (older) when the note changed after
    /// it was written; without one, ~ and the note's own first line.
    var summary: String {
        if note.locked { return "(locked)" }
        if let description { return (descriptionCurrent ? "" : "(older) ") + description.text }
        return "~ " + Descriptions.extract(text, title: note.title)
    }

    /// The note in a list's JSON. Ids are whole and dates have seconds and the offset.
    var json: JSON {
        var fields: [String: JSON] = [
            "id": .string(note.id), "version": .string(version), "title": .string(note.title), "folder": .string(note.folderPath),
            "modified": .string(Output.timestamp(note.modified)), "created": .string(Output.timestamp(note.created)),
            "pinned": .bool(note.pinned), "locked": .bool(note.locked), "chars": .int(text.count),
            "description": Output.json(description?.text), "description_current": .bool(descriptionCurrent),
        ]
        if let opening { fields["opening"] = .string(opening) }
        if let deleted {
            fields["deleted"] = .string(Output.timestamp(deleted.date))
            fields["days_left"] = .int(deleted.daysLeft)
        }
        return .object(fields)
    }

    /// A list's JSON: what it lists (its heading), how many notes match, and the ones shown.
    static func list(_ heading: String, total: Int, _ rows: [ListedNote]) -> JSON {
        ["folder": .string(heading), "total": .int(total), "showing": .int(rows.count), "notes": .array(rows.map(\.json))]
    }
}
