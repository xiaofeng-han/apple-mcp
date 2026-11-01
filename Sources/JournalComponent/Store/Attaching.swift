import AVFoundation
import CoreData
import Foundation
import ImageIO
import JournalModel
import JournalShared
import UniformTypeIdentifiers

/// A photo, video or recording to add to an entry, read and converted before anything is written:
/// what Journal itself would keep for it.
struct NewAttachment: Sendable {
    /// One of the asset's files. All sit at index 0: a video's still and the video itself are
    /// two roles of the same slot, as a Live Photo's are.
    struct File: Sendable {
        /// Journal's name for its role: image, video or audio.
        let role: String
        /// Its name in the asset's folder.
        let name: String
        /// What to write: an image as HEIC, or nil to copy the original file.
        let contents: Data?
    }

    /// Journal's asset type: photo, video or audio.
    let type: String
    let files: [File]
    let source: URL
    /// The asset's metadata, encoded by Journal's own types.
    let metadata: Data
}

/// Reads the files to attach. Journal's own editor saves a photo as HEIC of about 6 megapixels
/// (named "…_resized.heic"), keeps a video as it is with a still of it, and a recording as it is
/// with its waveform; the metadata is the kind Journal writes (PhotoLibraryAssetMetadata,
/// AudioAssetMetadata).
enum Attaching {
    static let maxPixels = 6_000_000.0
    /// The largest file accepted: this app's limit, not Journal's, so one call cannot fill iCloud.
    static let maxFileSize = 250 * 1024 * 1024
    static let maxFiles = 20
    /// The crop Journal's camera writes, which leaves the layout to Journal.
    static let noCrop = "{{0, 0}, {0, 0}}"

    static func prepare(_ paths: [String]) async throws(JournalError) -> [NewAttachment] {
        guard paths.count <= maxFiles else { throw .refused("At most \(maxFiles) files can be attached at a time") }
        var prepared: [NewAttachment] = []
        for path in paths { prepared.append(try await prepare(path)) }
        return prepared
    }

    static func prepare(_ path: String) async throws(JournalError) -> NewAttachment {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw .refused("\(path): give the file's absolute path") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .creationDateKey])
        guard let values, values.isRegularFile == true else { throw .notFound("a file at \(url.path)") }
        guard (values.fileSize ?? 0) <= maxFileSize else {
            throw .refused("\(url.lastPathComponent) is larger than \(maxFileSize / 1024 / 1024) MB; attach a smaller copy")
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return try photo(url, created: values.creationDate) }
        if type?.conforms(to: .movie) == true { return try await video(url, created: values.creationDate) }
        if type?.conforms(to: .audio) == true { return try await audio(url, created: values.creationDate) }
        throw .refused("\(url.lastPathComponent) is not a photo, video or audio recording, the files Journal attaches")
    }

    // MARK: Photos

    static func photo(_ url: URL, created: Date?) throws(JournalError) -> NewAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw .refused("\(url.lastPathComponent) is not an image macOS can read") }
        let longest = Int((Double(max(width, height)) * pixelScale(width: width, height: height)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let still = still(image) else {
            throw .failed("\(url.lastPathComponent) could not be converted to HEIC")
        }
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let metadata = PhotoLibraryAssetMetadata(
            assetIdentifier: nil, date: takenDate(properties) ?? created ?? Date(), placeName: nil,
            latitude: coordinate(gps, kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef, negative: "S"),
            longitude: coordinate(gps, kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef, negative: "W"),
            size: CGSize(width: image.width, height: image.height),
            squareCropRect: noCrop, landscapeCropRect: noCrop, portraitCropRect: noCrop, displayAtFullAspectRatio: false)
        return NewAttachment(type: "photo", files: [still], source: url, metadata: try encoded(metadata.asData))
    }

    /// How much to shrink an image to keep it within Journal's 6 megapixels.
    static func pixelScale(width: Int, height: Int) -> Double {
        min(1, (maxPixels / Double(width * height)).squareRoot())
    }

    /// The image as the HEIC file Journal keeps for a photo or a video's still.
    static func still(_ image: CGImage) -> NewAttachment.File? {
        heic(image).map { NewAttachment.File(role: "image", name: UUID().uuidString + "_resized.heic", contents: $0) }
    }

    static func heic(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// When the photo was taken, from its Exif (local time unless it names its offset).
    static func takenDate(_ properties: [CFString: Any]) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func coordinate(_ gps: [CFString: Any]?, _ key: CFString, _ referenceKey: CFString, negative: String) -> Double? {
        guard let value = gps?[key] as? Double else { return nil }
        return (gps?[referenceKey] as? String) == negative ? -value : value
    }

    // MARK: Videos and recordings

    static func video(_ url: URL, created: Date?) async throws(JournalError) -> NewAttachment {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, (try? await asset.load(.isPlayable)) == true,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { throw .refused("\(url.lastPathComponent) is not a video macOS can play") }
        let shown = CGSize(width: abs(size.applying(transform).width), height: abs(size.applying(transform).height))
        // Journal draws a video from a still of it, an image in the same slot as the video.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let scale = pixelScale(width: Int(shown.width), height: Int(shown.height))
        generator.maximumSize = CGSize(width: (shown.width * scale).rounded(.up), height: (shown.height * scale).rounded(.up))
        guard let (frame, _) = try? await generator.image(at: .zero), let still = still(frame) else {
            throw .failed("Could not take a still from \(url.lastPathComponent)")
        }
        let (latitude, longitude) = await location(asset)
        let metadata = PhotoLibraryAssetMetadata(
            assetIdentifier: nil, date: await recorded(asset) ?? created ?? Date(), placeName: nil, latitude: latitude, longitude: longitude,
            size: shown, squareCropRect: noCrop, landscapeCropRect: noCrop, portraitCropRect: noCrop, displayAtFullAspectRatio: false)
        let video = NewAttachment.File(role: "video", name: UUID().uuidString + "." + url.pathExtension.lowercased(), contents: nil)
        return NewAttachment(type: "video", files: [still, video], source: url, metadata: try encoded(metadata.asData))
    }

    static func audio(_ url: URL, created: Date?) async throws(JournalError) -> NewAttachment {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false, (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration), duration.isNumeric
        else { throw .refused("\(url.lastPathComponent) is not audio macOS can play") }
        // The waveform Journal shows, worked out as Journal does for its own recordings.
        let levels = try? await AudioIntensityProcessor(computesAverageIntensity: false).readAudioIntensityLevels(from: asset).0
        let metadata = AudioAssetMetadata(duration: duration.seconds, intensities: levels, recordingDate: await recorded(asset) ?? created ?? Date(),
                                          transcriptSegments: nil)
        let file = NewAttachment.File(role: "audio", name: UUID().uuidString + "." + url.pathExtension.lowercased(), contents: nil)
        return NewAttachment(type: "audio", files: [file], source: url, metadata: try encoded(metadata.asData))
    }

    static func recorded(_ asset: AVURLAsset) async -> Date? {
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// The place a video was taken, from its ISO 6709 location ("+37.3349-122.0090+010.000/").
    static func location(_ asset: AVURLAsset) async -> (Double?, Double?) {
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierLocation).first,
              let text = try? await item.load(.stringValue),
              let match = text.firstMatch(of: /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)/)
        else { return (nil, nil) }
        return (Double(match.1), Double(match.2))
    }

    static func encoded(_ data: Data?) throws(JournalError) -> Data {
        guard let data else { throw .failed("Journal could not encode the attachment's details") }
        return data
    }
}

/// An attachment added to an entry, and the folder its file went into (removed again if the
/// entry cannot be saved).
struct Attached {
    let asset: JournalEntryAssetMO
    let folder: URL
}

extension JournalStore {
    /// Adds the files to the entry, after the attachments it shows above its text, as Journal's
    /// editor does: an asset with its metadata and file, placed in the entry's grid.
    func attach(_ attachments: [NewAttachment], to entry: JournalEntryMO) throws(JournalError) -> [Attached] {
        guard !attachments.isEmpty else { return [] }
        let context = try context()
        guard let entryID = entry.value(forKey: "id") as? UUID else { throw .failed("Journal gave no id for the entry") }
        var placement = entry.mergeableAssetPlacement ?? MergeableEntryAssetsPlacement(fromLegacyOrderingFieldsOf: entry)
        var grid = assets(entry).filter { asset in
            guard let id = UUID(uuidString: asset.id), case .grid = placement.assetPlacement(forAssetID: id) else { return false }
            return true
        }.count
        guard grid + attachments.count <= AssetPlacement.Constants.maxGridCount else {
            throw .refused("An entry shows at most \(AssetPlacement.Constants.maxGridCount) attachments; this one has \(grid)")
        }
        var attached: [Attached] = []
        for attachment in attachments {
            let assetID = UUID()
            let folder = Permissions.attachments.appendingPathComponent(entryID.uuidString).appendingPathComponent(assetID.uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in attachment.files {
                    let url = folder.appendingPathComponent(file.name)
                    if let contents = file.contents {
                        try contents.write(to: url)
                    } else {
                        try FileManager.default.copyItem(at: attachment.source, to: url)
                    }
                }
            } catch {
                removeFolders(attached.map(\.folder) + [folder])
                throw .failed("Could not write \(attachment.source.lastPathComponent) into Journal's folder: \(error.localizedDescription)")
            }
            let asset = insertAsset(attachment, id: assetID, entry: entry, entryID: entryID, context: context)
            attached.append(Attached(asset: asset, folder: folder))
            placement.addOrMoveAsset(withID: assetID, to: .grid(grid), from: placement.assetPlacement(forAssetID: assetID))
            grid += 1
        }
        // A Journal 3.0 entry keeps the placement in its mergeable attributes (one before 3.0 has
        // none, and ignores this); both keep the older ordering fields too.
        entry.mergeableAssetPlacement = placement
        entry.modifyLegacyAssetOrderingFields(from: placement)
        entry.computeAndSetAggregateMinimumVersion()
        return attached
    }

    private func insertAsset(_ attachment: NewAttachment, id: UUID, entry: JournalEntryMO, entryID: UUID, context: NSManagedObjectContext) -> JournalEntryAssetMO {
        let now = Date()
        let asset = JournalEntryAssetMO(context: context)
        asset.setValue(id, forKey: "id")
        asset.setValue(now, forKey: "createdDate")
        asset.setValue(now, forKey: "updatedDate")
        asset.setValue(attachment.type, forKey: "assetType")
        asset.setValue("external", forKey: "source")
        asset.setValue(false, forKey: "isHidden")
        asset.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forKey: "osVersion")
        asset.setValue(attachment.metadata, forKey: "assetMetaData")
        asset.setValue(entryID, forKey: "parentID")
        asset.setValue(false, forKey: "isUploadedToCloud")
        asset.setValue(entry, forKey: "entry")
        for item in attachment.files {
            // Journal marks a file it adds for post-processing, which has nothing to do for photos,
            // videos or recordings ("unsupported asset type") and holds the upload until it runs.
            let file = JournalEntryAssetFileAttachmentMO(context: context)
            file.setValue(UUID(), forKey: "id")
            file.setValue("\(entryID.uuidString)/\(id.uuidString)/\(item.name)", forKey: "filePath")
            file.setValue(item.role, forKey: "name")
            file.setValue(0, forKey: "index")
            file.setValue(false, forKey: "needsProcessing")
            file.setValue(id, forKey: "parentID")
            file.setValue(false, forKey: "isUploadedToCloud")
            asset.mutableSetValue(forKey: "fileAttachments").add(file)
        }
        return asset
    }

    /// Takes attachments off the entry, as Journal does: out of its layout and marked for Journal
    /// to delete from iCloud, which then deletes it and its files here too.
    func detach(_ ids: [String], from entry: JournalEntryMO) throws(JournalError) {
        guard !ids.isEmpty else { return }
        var placement = entry.mergeableAssetPlacement ?? MergeableEntryAssetsPlacement(fromLegacyOrderingFieldsOf: entry)
        let shown = Set(assets(entry).map(\.id))
        for reference in ids {
            let wanted = reference.trimmingCharacters(in: .whitespaces).uppercased()
            guard shown.contains(wanted), let asset = entry.assetsArray.first(where: { Self.id($0) == wanted }), let id = UUID(uuidString: wanted) else {
                throw .notFound("an attachment \(reference) in this entry; read_entry lists them")
            }
            if case .canvas = placement.assetPlacement(forAssetID: id) {
                throw .refused("The attachment \(reference) sits in the entry's text, where only Journal can take it out")
            }
            placement.removeAsset(withID: id)
            asset.setValue(true, forKey: "isRemovedFromCloud")
            asset.setValue(Date(), forKey: "updatedDate")
        }
        entry.mergeableAssetPlacement = placement
        entry.modifyLegacyAssetOrderingFields(from: placement)
        entry.computeAndSetAggregateMinimumVersion()
    }

    func removeFolders(_ folders: [URL]) {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }
}
