import CryptoKit
import Foundation
import Security

/// Checks that an archive is the one the release was signed for: its SHA-256 and an RSA-4096 / PKCS#1 v1.5 signature made
/// with `openssl dgst -sha256 -sign key -binary < archive`. `verify` takes the hex digest of the bytes that were signed.
public enum UpdateSignature {
    /// Lowercase hex SHA-256 of a file, read in 1 MiB chunks (an archive is never held in memory whole).
    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True only if `signature` is a valid RSA-4096 PKCS#1 v1.5 signature of the SHA-256 digest `digestHex` under
    /// `publicKeyPEM`, a PKCS#1 `RSA PUBLIC KEY`. Any malformed input is false.
    public static func verify(digestHex: String, signature: Data, publicKeyPEM: String) -> Bool {
        guard let digest = digest(fromHex: digestHex), let der = pkcs1DER(fromPEM: publicKeyPEM) else { return false }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 4096,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureDigestPKCS1v15SHA256, digest as CFData, signature as CFData, nil)
    }

    /// 32 bytes from exactly 64 lowercase hex characters.
    private static func digest(fromHex hex: String) -> Data? {
        let characters = Array(hex.utf8)
        guard characters.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let high = nibble(characters[i]), let low = nibble(characters[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// The DER inside a `RSA PUBLIC KEY` PEM block. Any other block type (an X.509 `PUBLIC KEY`, a private key) is nil.
    private static func pkcs1DER(fromPEM pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "-----BEGIN RSA PUBLIC KEY-----", lines.last == "-----END RSA PUBLIC KEY-----" else { return nil }
        return Data(base64Encoded: lines.dropFirst().dropLast().joined())
    }
}
