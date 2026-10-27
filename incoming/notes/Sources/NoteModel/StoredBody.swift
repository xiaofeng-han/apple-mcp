import Foundation

/// The plain text of a note body as NoteStore.sqlite stores it (ZICNOTEDATA.ZDATA), for search.
/// The data is a compressed protobuf: document (field 2) → note (field 3) → text (field 2).
/// Older notes are gzip, notes written by newer versions of Notes are zlib. Formatting is skipped:
/// this text is only searched and summarized, never written back.
public enum StoredBody {
    public static func plainText(_ data: Data) -> String? {
        guard let raw = inflate(data), let document = Protobuf.firstBytes(2, in: raw), let note = Protobuf.firstBytes(3, in: document),
            let text = Protobuf.firstBytes(2, in: note)
        else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    /// gzip or zlib → the inflated bytes; data that is neither is returned as it is.
    public static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        if bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 {
            // gzip: a 10-byte header, optional fields named by the flags, DEFLATE data, then CRC
            // and size (8 bytes).
            let flags = bytes[3]
            var i = 10
            if flags & 0x04 != 0 {
                guard i + 2 <= bytes.count else { return nil }
                i += 2 + (Int(bytes[i]) | Int(bytes[i + 1]) << 8)
            }
            if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
            if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
            if flags & 0x02 != 0 { i += 2 }
            guard i < bytes.count - 8 else { return nil }
            return rawInflate(Data(bytes[i..<(bytes.count - 8)]))
        }
        if bytes.count >= 6, bytes[0] & 0x0f == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 {
            // zlib: 2 header bytes (4 more for a preset dictionary, which Notes does not use),
            // DEFLATE data, then an Adler-32 checksum.
            guard bytes[1] & 0x20 == 0 else { return nil }
            return rawInflate(Data(bytes[2..<(bytes.count - 4)]))
        }
        return data
    }

    /// Foundation's "zlib" algorithm is raw DEFLATE, without zlib's header and checksum.
    static func rawInflate(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}

/// Reads protobuf wire format by field number; Notes ships no schema.
public enum Protobuf {
    /// The first length-delimited field with this number, or nil.
    public static func firstBytes(_ number: Int, in message: Data) -> Data? {
        var found: Data?
        walk(message) { field, wire, value in
            guard field == number, wire == 2, let value else { return true }
            found = value
            return false
        }
        return found
    }

    /// Every field: its number, wire type, and the bytes of a length-delimited field. The visitor
    /// returns false to stop. Returns false when the message is malformed.
    @discardableResult
    public static func walk(_ message: Data, _ visit: (Int, Int, Data?) -> Bool) -> Bool {
        let bytes = [UInt8](message)
        var i = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let byte = bytes[i]
                i += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return false }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                guard varint() != nil else { return false }
                if !visit(field, wire, nil) { return true }
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard i + size <= bytes.count else { return false }
                i += size
                if !visit(field, wire, nil) { return true }
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - i) else { return false }
                let value = Data(bytes[i..<(i + Int(length))])
                i += Int(length)
                if !visit(field, wire, value) { return true }
            default:
                return false
            }
        }
        return true
    }
}
