import Foundation

/// MD5, implemented here rather than taken from CryptoKit.
///
/// Two protocols this app speaks mandate MD5 for request signing — Subsonic's
/// salted token and the AudioScrobbler 2.0 `api_sig` — so it isn't a choice.
/// Having it in-tree keeps the source layer free of CryptoKit, which is what
/// lets both signing paths be unit-tested off an Apple platform. Verified
/// against the RFC 1321 test vectors in `MD5Tests`.
///
/// Not for anything security-sensitive; MD5 has been broken for collisions
/// since 2004. It is used here only because these two wire formats require it.
enum MD5 {

    /// Lowercase hex digest, the form both protocols want.
    static func hex(_ string: String) -> String {
        digest(Array(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func hex(_ data: Data) -> String {
        digest(Array(data))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Per-round left-rotation amounts.
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    /// Sine-derived constants: floor(abs(sin(i + 1)) * 2^32).
    private static let constants: [UInt32] = (0..<64).map {
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0))
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        // Append 0x80, pad with zeros to 56 mod 64, then the bit length LE.
        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for index in 0..<8 {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(index))))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            // 16 little-endian words.
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = chunkStart + index * 4
                words[index] = UInt32(padded[base])
                    | UInt32(padded[base + 1]) << 8
                    | UInt32(padded[base + 2]) << 16
                    | UInt32(padded[base + 3]) << 24
            }

            var a = a0, b = b0, c = c0, d = d0

            for i in 0..<64 {
                let f: UInt32
                let wordIndex: Int

                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    wordIndex = i
                case 16..<32:
                    f = (d & b) | (~d & c)
                    wordIndex = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    wordIndex = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    wordIndex = (7 * i) % 16
                }

                let temp = d
                d = c
                c = b
                let sum = a &+ f &+ constants[i] &+ words[wordIndex]
                b = b &+ rotateLeft(sum, by: shifts[i])
                a = temp
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        // Output is little-endian per word.
        var result = [UInt8]()
        result.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                result.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return result
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
