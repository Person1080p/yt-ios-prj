import XCTest
@testable import Aura

/// RFC 1321 test vectors. Request signing for both Subsonic and AudioScrobbler
/// depends on this being exactly right, and a wrong digest fails as an opaque
/// auth error at runtime — so it is pinned here.
final class MD5Tests: XCTestCase {

    func testRFC1321Vectors() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a")
        ]

        for (input, expected) in vectors {
            XCTAssertEqual(MD5.hex(input), expected, "digest of \"\(input)\"")
        }
    }

    func testBlockBoundaryLengths() {
        // 55/56/57 and 63/64/65 bytes exercise every padding branch.
        let expected: [Int: String] = [
            55: "ef1772b6dff9a122358552954ad0df65",
            56: "3b0c8ac703f828b04c6c197006d17218",
            57: "652b906d60af96844ebd21b674f35e93",
            63: "b06521f39153d618550606be297466d5",
            64: "014842d480b571495a4a0363793f7367",
            65: "c743a45e0d2e6a95cb859adae0248435"
        ]
        for (length, digest) in expected {
            XCTAssertEqual(MD5.hex(String(repeating: "a", count: length)), digest,
                           "\(length) bytes of 'a'")
        }
    }

    func testMultiByteUTF8() {
        // Scrobbled titles and artist names are full of these, and the digest
        // is over UTF-8 bytes rather than characters.
        XCTAssertEqual(MD5.hex("Björk"), "7dab4f23a40857b30fdd81370c211680")
        XCTAssertEqual(MD5.hex("é"), "66ddcd97cfdeabb2f6fb8a999b4bc76f")
    }

    func testDataAndStringAgree() {
        XCTAssertEqual(MD5.hex("abc"), MD5.hex(Data("abc".utf8)))
    }
}
