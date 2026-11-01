import AVFoundation
import Foundation
import ImageIO
import JournalModel
import UniformTypeIdentifiers
import Wire

/// read_attachment hands an attachment to the model as MCP content where a type fits (photos and
/// a frame of a video as images, recordings as audio, other files as embedded files), always with
/// its details as text, so a client that drops a content type still has something to work with.
enum Media {
    /// Longest edge of images sent to the model; clients scale larger ones down anyway.
    static let longestEdge = 1568
    static let maxFile = 20 * 1024 * 1024

    static func answer(_ asset: AssetInfo, in entry: EntryInfo, textOnly: Bool) async -> ToolAnswer {
        var details: [String: JSON] = ["id": .string(asset.id), "kind": .string(AssetDetails.kind(asset.kind)),
                                       "entry": ["id": .string(entry.id), "title": .string(entry.title), "date": .string(Output.stamp(entry.date))]]
        details.merge(asset.details) { own, _ in own }
        var content: [Content] = []
        var notes: [String] = []
        for file in asset.files where file.name != "thumbnail" {
            guard file.exists else {
                notes.append("The \(file.name) file is not on this Mac yet (Journal downloads it from iCloud when it is shown).")
                continue
            }
            let type = UTType(filenameExtension: file.url.pathExtension)
            if type?.conforms(to: .image) == true {
                if !textOnly, let jpeg = scaledJPEG(file.url) { content.append(.image(jpeg, mimeType: "image/jpeg")) }
            } else if type?.conforms(to: .movie) == true {
                if let seconds = await duration(file.url) { details["video_seconds"] = .int(Int(seconds.rounded())) }
                if !textOnly, let frame = await still(file.url) {
                    content.append(.image(frame, mimeType: "image/jpeg"))
                    notes.append("The image is a frame from the video.")
                }
            } else if type?.conforms(to: .audio) == true {
                if !textOnly, let data = read(file.url) { content.append(.audio(data, mimeType: type?.preferredMIMEType ?? "audio/mp4")) }
            } else if !textOnly, let data = read(file.url) {
                content.append(.file(data, uri: "attachment:\(asset.id)", mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
            }
        }
        if !notes.isEmpty { details["note"] = .string(notes.joined(separator: " ")) }
        return ToolAnswer(content: [.text(JSON.object(details).text)] + content)
    }

    static func read(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFile else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The image as JPEG with its longest edge at most `longestEdge` (HEIC converted: every client
    /// takes JPEG).
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
}
