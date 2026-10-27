import AVFoundation
import Foundation
import ImageIO
import NoteModel
import PDFKit
import UniformTypeIdentifiers
import Wire

/// read_attachment hands an attachment to the model as MCP content where a type fits (images,
/// scan pages, drawings and a frame of a video as images; audio as audio; PDFs and other files
/// as embedded files), always with the text that can be read out of it (Notes' recognized text,
/// a PDF's text, a text file, a table's cells), so a client that drops a content type still has
/// something to work with.
func attachmentTools(_ store: NotesStore) -> [Tool] {
    [
        Tool("read_attachment", title: "Read an attachment",
             summary: """
                 Opens an attachment from a ![…](attachment:id) placeholder in read_note: images, scans, \
                 drawings, PDFs, audio (recordings with Notes' transcript and summary), video, tables, links \
                 and files.
                 """,
             input: Schema.object([
                 "id": Schema.text("Attachment id"),
                 "text_only": Schema.flag("Only the text, no images or files"),
             ], required: ["id"]), effect: .reads) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id")
            let textOnly = try input.flag("text_only") ?? false
            return try await withNotes(store) {
                let details = try store.attachment(try store.resolveAttachment(reference))
                return await Opening.answer(details, textOnly: textOnly)
            }
        },
    ]
}

enum Opening {
    /// Longest edge of images sent to the model; clients scale larger ones down anyway.
    static let longestEdge = 1568
    static let maxPages = 10
    static let maxFile = 20 * 1024 * 1024
    static let maxText = 20_000

    static func answer(_ details: AttachmentDetails, textOnly: Bool) async -> ToolAnswer {
        var lines = ["\(details.kind)\(details.title.isEmpty ? "" : " \"\(details.title)\"") in the note \"\(details.noteTitle)\" (\(ShortID.of(details.noteID)))"
            + (details.size > 0 ? " | " + ByteCountFormatter.string(fromByteCount: Int64(details.size), countStyle: .file) : "")]
        var content: [Content] = []
        func add(_ label: String, _ text: String) {
            let cut = text.count > maxText ? String(text.prefix(maxText)) + "\n… (cut at \(maxText) characters)" : text
            lines.append("\n\(label):\n\(cut)")
        }
        if let url = details.url { lines.append("URL: \(url)") }
        if let rows = details.rows { lines.append("\n" + Markdown.render([.table(Table(id: details.id, rows: rows))])) }
        for (label, text) in details.texts { add(label, text) }

        // A scan holds pages; a recording made in Notes, parts recorded one after another.
        let part = details.kind == "audio" ? "part" : "page"
        let pages = details.pages.isEmpty ? [details] : Array(details.pages.prefix(maxPages))
        if details.pages.count > maxPages { lines.append("(the first \(maxPages) of \(details.pages.count) \(part)s)") }
        for (index, page) in pages.enumerated() {
            if !details.pages.isEmpty {
                for (label, text) in page.texts { add("\(part.capitalized) \(index + 1), \(label.prefix(1).lowercased() + label.dropFirst())", text) }
            }
            guard let file = page.file else { continue }
            let type = UTType(filenameExtension: file.pathExtension) ?? UTType(page.type)
            if type?.conforms(to: .image) == true {
                if !textOnly, let jpeg = scaledJPEG(file) { content.append(.image(jpeg, mimeType: "image/jpeg")) }
            } else if type?.conforms(to: .pdf) == true {
                if let document = PDFDocument(url: file) {
                    lines.append("PDF, \(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    if let text = document.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("Text in the PDF", text) }
                }
                if !textOnly, let data = read(file) { content.append(.file(data, uri: "attachment:\(page.id)", mimeType: "application/pdf")) }
            } else if type?.conforms(to: .audio) == true {
                if let seconds = await duration(file) { lines.append("Audio, \(clock(seconds))") }
                if !textOnly, let data = read(file) { content.append(.audio(data, mimeType: type?.preferredMIMEType ?? "audio/mp4")) }
            } else if type?.conforms(to: .movie) == true {
                if let seconds = await duration(file) { lines.append("Video, \(clock(seconds)); a frame from it follows") }
                if !textOnly, let frame = await still(file) { content.append(.image(frame, mimeType: "image/jpeg")) }
            } else if type?.conforms(to: .text) == true, let data = read(file), let text = String(data: data, encoding: .utf8) {
                add("The file \(page.fileName ?? file.lastPathComponent)", text)
            } else if let data = read(file) {
                lines.append("The file \(page.fileName ?? file.lastPathComponent)")
                if !textOnly {
                    content.append(.file(data, uri: "attachment:\(page.id)", mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
                }
            } else {
                lines.append("The file \(page.fileName ?? file.lastPathComponent) is larger than \(maxFile / 1024 / 1024) MB and is not sent.")
            }
        }
        if content.isEmpty, lines.count == 1 {
            lines.append(details.file == nil && details.pages.isEmpty && details.rows == nil && details.url == nil
                ? "Its file is not on this Mac (Notes may not have downloaded it), and Notes has no text for it."
                : "Nothing more can be read from it.")
        }
        return ToolAnswer(content: [.text(lines.joined(separator: "\n"))] + content)
    }

    static func read(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFile else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The image as JPEG with its longest edge at most `longestEdge` (HEIC and others converted:
    /// every client takes JPEG).
    static func scaledJPEG(_ file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(jpeg)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func duration(_ file: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: file).load(.duration), time.isNumeric else { return nil }
        return time.seconds
    }

    static func still(_ file: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longestEdge, height: longestEdge)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return jpeg(image)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
