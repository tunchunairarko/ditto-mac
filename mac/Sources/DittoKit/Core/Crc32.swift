import Foundation

/// Port of `CCrc32Dynamic` (Crc32Dynamic.cpp).
///
/// Ditto stores a CRC of every clip's data in `Main.CRC` and uses it to spot
/// duplicates. This is the same reflected CRC-32 (polynomial 0xEDB88320,
/// initial value 0xFFFFFFFF, final one's-complement) so a database written by
/// this app and one written by Windows Ditto agree on what a duplicate is.
enum Crc32 {

    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Feed one buffer into a running CRC. Start with `0xFFFFFFFF`.
    static func update(_ crc: UInt32, _ bytes: Data) -> UInt32 {
        var value = crc
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
            }
        }
        return value
    }

    /// Finish a running CRC (Ditto's `dwCRC = ~dwCRC`).
    static func finalize(_ crc: UInt32) -> UInt32 {
        return ~crc
    }

    static func compute(_ bytes: Data) -> UInt32 {
        return finalize(update(0xFFFF_FFFF, bytes))
    }
}
