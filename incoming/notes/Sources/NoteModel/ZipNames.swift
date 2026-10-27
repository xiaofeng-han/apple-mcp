import Foundation

/// Marks the file names in a zip archive as UTF-8 (general-purpose flag bit 11). `ditto` writes
/// UTF-8 names but leaves the flag off, so Windows, Python's zipfile and unzip show non-ASCII
/// names (Chinese titles, say) as garbage. Only the flag bytes change, which no checksum covers.
/// Zip64 archives (over 4 GB, with videos) are handled.
public enum ZipNames {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func markUTF8(_ archive: URL) throws {
        let file = try FileHandle(forUpdating: archive)
        defer { try? file.close() }

        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw Failure(description: "the archive ends early") }
            return [UInt8](data)
        }
        func number(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
            var value: UInt64 = 0
            for k in 0..<width { value |= UInt64(bytes[at + k]) << (8 * UInt64(k)) }
            return value
        }

        // The end-of-central-directory record is the last 22 bytes plus a comment of up to 64 KB.
        let size = try file.seekToEnd()
        guard size >= 22 else { throw Failure(description: "too short for a zip archive") }
        let tailSize = Int(min(size, 22 + 0xFFFF))
        let tail = try read(size - UInt64(tailSize), tailSize)
        guard let end = stride(from: tailSize - 22, through: 0, by: -1).first(where: { number(tail, $0, 4) == 0x0605_4b50 }) else {
            throw Failure(description: "no end-of-central-directory record")
        }
        var count = number(tail, end + 10, 2)
        var directorySize = number(tail, end + 12, 4)
        var directoryOffset = number(tail, end + 16, 4)
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: a locator just before the record points at the zip64 record.
            guard end >= 20, number(tail, end - 20, 4) == 0x0706_4b50 else { throw Failure(description: "no zip64 locator") }
            let record = try read(number(tail, end - 12, 8), 56)
            guard number(record, 0, 4) == 0x0606_4b50 else { throw Failure(description: "no zip64 record") }
            count = number(record, 32, 8)
            directorySize = number(record, 40, 8)
            directoryOffset = number(record, 48, 8)
        }
        guard directorySize <= 256 * 1024 * 1024 else { throw Failure(description: "the central directory is too large") }
        var directory = try read(directoryOffset, Int(directorySize))

        var position = 0
        var localHeaders: [UInt64] = []
        for _ in 0..<count {
            guard position + 46 <= directory.count, number(directory, position, 4) == 0x0201_4b50 else {
                throw Failure(description: "a damaged central directory")
            }
            let nameLength = Int(number(directory, position + 28, 2))
            let extraLength = Int(number(directory, position + 30, 2))
            let commentLength = Int(number(directory, position + 32, 2))
            let next = position + 46 + nameLength + extraLength + commentLength
            guard next <= directory.count else { throw Failure(description: "a damaged central directory") }
            let name = Array(directory[(position + 46)..<(position + 46 + nameLength)])
            if String(validating: name, as: UTF8.self) != nil {
                directory[position + 9] |= 0x08  // bit 11 of the flags at offset 8, little-endian
                var local = number(directory, position + 42, 4)
                if local == 0xFFFF_FFFF {
                    // The zip64 extra field holds, in order, only the values that overflowed:
                    // uncompressed size, compressed size, then the local header's offset.
                    var extra = position + 46 + nameLength
                    let extraEnd = extra + extraLength
                    var found = false
                    while extra + 4 <= extraEnd {
                        let id = number(directory, extra, 2), length = Int(number(directory, extra + 2, 2))
                        if id == 1 {
                            var field = extra + 4
                            if number(directory, position + 24, 4) == 0xFFFF_FFFF { field += 8 }
                            if number(directory, position + 20, 4) == 0xFFFF_FFFF { field += 8 }
                            guard field + 8 <= extra + 4 + length else { throw Failure(description: "a damaged zip64 field") }
                            local = number(directory, field, 8)
                            found = true
                            break
                        }
                        extra += 4 + length
                    }
                    guard found else { throw Failure(description: "an entry without its zip64 offset") }
                }
                localHeaders.append(local)
            }
            position = next
        }
        for offset in localHeaders {
            let header = try read(offset, 8)
            guard number(header, 0, 4) == 0x0403_4b50 else { throw Failure(description: "a damaged local header") }
            try file.seek(toOffset: offset + 7)
            try file.write(contentsOf: Data([header[7] | 0x08]))
        }
        try file.seek(toOffset: directoryOffset)
        try file.write(contentsOf: Data(directory))
    }
}
