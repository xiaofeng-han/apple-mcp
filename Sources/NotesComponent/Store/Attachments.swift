import CoreData
import Foundation
import NoteModel
import NotesShim

/// What an attachment holds, as plain values: its file on this Mac (if any) and the text Notes
/// already got out of it (recognized text, handwriting, what an image shows, link details).
struct AttachmentDetails: Sendable {
    var id: String
    var kind: String
    var type: String
    var title: String
    var noteID: String
    var noteTitle: String
    var size: Int
    /// The original file; for drawings, the image or PDF Notes renders of them.
    var file: URL?
    var fileName: String?
    var url: String?
    var texts: [(label: String, text: String)]
    /// A scan's pages, in order.
    var pages: [AttachmentDetails]
    var rows: [[String]]?
}

extension NotesStore {
    /// An attachment by the id read_note shows in `![…](attachment:<id>)`.
    func attachment(_ id: String) throws(NotesError) -> AttachmentDetails {
        guard let attachment = try object("ICAttachment", id: id) else {
            if try object("ICInlineAttachment", id: id) != nil {
                throw .refused("attachment:\(ShortID.of(id)) is part of the text (a tag, mention, note link or calculation); read_note already shows it")
            }
            throw .notFound("attachment \(ShortID.of(id))")
        }
        if attachment.get("markedForDeletion") as? Bool == true { throw .notFound("attachment \(ShortID.of(id)) (it was deleted)") }
        guard let note = attachment.get("note") as? NSManagedObject else { throw .notFound("the note of attachment \(ShortID.of(id))") }
        if note.get("isPasswordProtected") as? Bool == true { throw .refused("attachments of locked notes are not read") }
        return details(attachment, note: note)
    }

    private func details(_ attachment: NSManagedObject, note: NSManagedObject) -> AttachmentDetails {
        let type = string(attachment, "typeUTI")
        func text(_ key: String) -> String? {
            let value = (attachment.get(key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let media = attachment.get("media") as? NSManagedObject
        var file = media?.get("mediaURL") as? URL
        let fileName = media?.get("filename") as? String
        if file.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            // Drawings and Paper documents have no media file; Notes keeps a rendering of them.
            file = ["fallbackPDFURL", "fallbackImageURL"].lazy.compactMap { attachment.get($0) as? URL }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        var texts: [(String, String)] = []
        // Notes' own recognition, which can be wrong (Latin gibberish for Chinese labels, once).
        if let t = text("ocrSummary") { texts.append(("Text Notes recognized (may be wrong)", t)) }
        if let t = text("handwritingSummary") { texts.append(("Handwriting Notes recognized (may be wrong)", t)) }
        if let t = text("imageClassificationSummary") { texts.append(("What Notes thinks the image shows (may be wrong)", t)) }
        // A table's summary repeats its cells, which the rows give anyway.
        if type != "com.apple.notes.table", let t = text("summary") { texts.append(("Summary", t)) }
        if let recording = recording(attachment) {
            if !recording.headline.isEmpty { texts.append(("Headline Notes wrote (may be wrong)", recording.headline)) }
            if !recording.summary.isEmpty { texts.append(("Summary Notes wrote (may be wrong)", recording.summary)) }
            if !recording.transcript.isEmpty {
                texts.append(("Transcript Notes made\(recording.call ? " of the call" : "") (may be wrong)", recording.transcript))
            }
        }
        let pages = ((attachment.get("subAttachments") as? Set<NSManagedObject>) ?? [])
            .filter { $0.get("markedForDeletion") as? Bool != true }
            .sorted { ($0.get("creationDate") as? Date ?? .distantPast) < ($1.get("creationDate") as? Date ?? .distantPast) }
            .map { details($0, note: note) }
        return AttachmentDetails(
            id: string(attachment, "identifier"), kind: AttachmentKind.of(type: type), type: type,
            title: text("title") ?? text("userTitle") ?? fileName ?? "", noteID: string(note, "identifier"), noteTitle: string(note, "title"),
            size: attachment.get("fileSize") as? Int ?? 0, file: file, fileName: fileName, url: text("urlString"), texts: texts, pages: pages,
            rows: type == "com.apple.notes.table" ? ANNotes.rowsOfTableAttachment(attachment) : nil)
    }

    /// The transcript and summaries of a recording made in Notes, which keeps them in the
    /// attachment's mergeable data (its audio is in the attachments under it). Nil for audio files
    /// added to a note, which have neither.
    func recording(_ attachment: NSManagedObject) -> ANRecording? {
        guard AttachmentKind.of(type: string(attachment, "typeUTI")) == "audio",
            let data = attachment.get("mergeableData") as? Data, !data.isEmpty
        else { return nil }
        return ANRecording(data: StoredBody.inflate(data) ?? data)
    }
}
