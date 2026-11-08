#if !canImport(CryptoKit)
import Foundation

/// SHA-256 and RSA signature verification off the Mac, where CryptoKit and Security are missing. Verification only, with a public
/// key: no secret is involved, so timing does not matter. swift-crypto was the plan, but its RSA verifies a digest only through
/// its own digest types, which can't be made from the hex digest the feed carries (docs/DECISIONS.md).
struct PortableSHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    mutating func update(data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            block(pending[offset..<(offset + 64)])
            offset += 64
        }
        pending.removeFirst(offset)
    }

    private mutating func block(_ chunk: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let start = chunk.startIndex
        for i in 0..<16 {
            w[i] = UInt32(chunk[start + i * 4]) << 24 | UInt32(chunk[start + i * 4 + 1]) << 16
                | UInt32(chunk[start + i * 4 + 2]) << 8 | UInt32(chunk[start + i * 4 + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var v = state
        for i in 0..<64 {
            let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
            let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
            let t1 = v[7] &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
            let t2 = s0 &+ maj
            v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
        }
        for i in 0..<8 { state[i] = state[i] &+ v[i] }
    }

    mutating func finalize() -> [UInt8] {
        let bits = length &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var offset = 0
        while offset < tail.count {
            block(tail[offset..<(offset + 64)])
            offset += 64
        }
        return state.flatMap { [UInt8($0 >> 24), UInt8(($0 >> 16) & 0xff), UInt8(($0 >> 8) & 0xff), UInt8($0 & 0xff)] }
    }
}

/// RSASSA-PKCS1-v1_5 verification with SHA-256 (RFC 8017, 8.2.2): s^e mod n must be exactly the expected encoding.
enum PortableRSA {
    /// Big-endian bytes as little-endian 32-bit limbs.
    private static func limbs(_ bytes: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.reversed().enumerated() { out[i / 4] |= UInt32(b) << UInt32(i % 4 * 8) }
        while out.count > 1, out.last == 0 { out.removeLast() }
        return out
    }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var x = a, y = b
        while x.count > 1, x.last == 0 { x.removeLast() }
        while y.count > 1, y.last == 0 { y.removeLast() }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        for i in stride(from: x.count - 1, through: 0, by: -1) where x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
        return 0
    }

    /// a * b mod m, by shift and subtract: a 4096-bit verify with a small public exponent stays quick.
    private static func multiplyMod(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32]) -> [UInt32] {
        var product = [UInt32](repeating: 0, count: a.count + b.count)
        for i in a.indices {
            var carry: UInt64 = 0
            for j in b.indices {
                let t = UInt64(a[i]) * UInt64(b[j]) + UInt64(product[i + j]) + carry
                product[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            product[i + b.count] = UInt32(carry)
        }
        var remainder = [UInt32](repeating: 0, count: m.count + 1)
        for bit in stride(from: product.count * 32 - 1, through: 0, by: -1) {
            var carry: UInt32 = (product[bit / 32] >> UInt32(bit % 32)) & 1
            for i in remainder.indices {
                let next = remainder[i] >> 31
                remainder[i] = remainder[i] << 1 | carry
                carry = next
            }
            if compare(remainder, m) >= 0 {
                var borrow: Int64 = 0
                for i in remainder.indices {
                    let t = Int64(remainder[i]) - (i < m.count ? Int64(m[i]) : 0) - borrow
                    remainder[i] = UInt32(truncatingIfNeeded: t)
                    borrow = t < 0 ? 1 : 0
                }
            }
        }
        return remainder
    }

    static func verify(digest: [UInt8], signature: [UInt8], modulus: [UInt8], exponent: [UInt8]) -> Bool {
        let n = modulus.drop { $0 == 0 }
        guard n.count == 512, signature.count == n.count, digest.count == 32 else { return false }   // RSA-4096, as on the Mac
        let m = limbs(Array(n)), s = limbs(signature)
        guard compare(s, m) < 0 else { return false }
        var result: [UInt32] = [1]
        let e = exponent.drop { $0 == 0 }
        guard !e.isEmpty, e.count <= 4 else { return false }
        var bits = e.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var base = s
        while bits > 0 {
            if bits & 1 == 1 { result = multiplyMod(result, base, m) }
            base = multiplyMod(base, base, m)
            bits >>= 1
        }
        var em = [UInt8](repeating: 0, count: n.count)
        for i in 0..<em.count {
            let limb = i / 4
            if limb < result.count { em[em.count - 1 - i] = UInt8(truncatingIfNeeded: result[limb] >> UInt32(i % 4 * 8)) }
        }
        let prefix: [UInt8] = [0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20]
        var expected: [UInt8] = [0x00, 0x01]
        expected += [UInt8](repeating: 0xff, count: n.count - 3 - prefix.count - digest.count)
        expected += [0x00] + prefix + digest
        return em == expected
    }

    /// Modulus and public exponent of a DER PKCS#1 `RSAPublicKey`; nil when it is anything else.
    static func parsePublicKey(der: [UInt8]) -> (modulus: [UInt8], exponent: [UInt8])? {
        var i = 0
        func length() -> Int? {
            guard i < der.count else { return nil }
            let first = der[i]; i += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n >= 1, n <= 4, i + n <= der.count else { return nil }
            var v = 0
            for _ in 0..<n { v = v << 8 | Int(der[i]); i += 1 }
            return v
        }
        func integer() -> [UInt8]? {
            guard i < der.count, der[i] == 0x02 else { return nil }
            i += 1
            guard let n = length(), n > 0, i + n <= der.count else { return nil }
            defer { i += n }
            return Array(der[i..<(i + n)])
        }
        guard der.first == 0x30 else { return nil }
        i = 1
        guard let total = length(), i + total == der.count, let modulus = integer(), let exponent = integer(), i == der.count else { return nil }
        return (modulus, exponent)
    }
}
#endif
