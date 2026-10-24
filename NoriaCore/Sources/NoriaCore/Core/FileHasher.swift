import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 of file contents, streamed in chunks so memory stays flat.
/// Uses CryptoKit on Apple platforms and a portable implementation elsewhere.
public enum FileHasher {
    static let chunkSize = 1 << 20
    /// Bytes read from each end of a file for the quick pre-check.
    public static let partialSpan = 64 * 1024

    /// Full SHA-256 as lowercase hex. Checks cancellation between chunks.
    public static func sha256(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw NoriaError.accessDenied(path: path) }
        defer { try? handle.close() }
        var hasher = Hasher256()
        while true {
            if Task.isCancelled { throw NoriaError.cancelled }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    /// Hash of the first and last `partialSpan` bytes plus the size. Different
    /// partial digests prove files differ; equal ones still require a full hash.
    public static func partialDigest(path: String, size: Int64) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw NoriaError.accessDenied(path: path) }
        defer { try? handle.close() }
        var hasher = Hasher256()
        hasher.update(Data(String(size).utf8))
        if let head = try handle.read(upToCount: partialSpan) { hasher.update(head) }
        if size > Int64(partialSpan * 2) {
            try handle.seek(toOffset: UInt64(size) - UInt64(partialSpan))
            if let tail = try handle.read(upToCount: partialSpan) { hasher.update(tail) }
        }
        return hasher.finalizeHex()
    }

    public static func sha256(data: Data) -> String {
        var hasher = Hasher256()
        hasher.update(data)
        return hasher.finalizeHex()
    }
}

/// Thin wrapper choosing the SHA-256 implementation.
struct Hasher256 {
    #if canImport(CryptoKit)
    private var hasher = SHA256()

    mutating func update(_ data: Data) { hasher.update(data: data) }

    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #else
    private var hasher = PortableSHA256()

    mutating func update(_ data: Data) { hasher.update(data) }

    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

/// FIPS 180-4 SHA-256. Used where CryptoKit is unavailable (Linux test runners).
struct PortableSHA256 {
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

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            processBlock(pending, at: offset)
            offset += 64
        }
        pending.removeFirst(offset)
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var offset = 0
        while offset < tail.count {
            processBlock(tail, at: offset)
            offset += 64
        }
        pending = []
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }

    private mutating func processBlock(_ bytes: [UInt8], at offset: Int) {
        @inline(__always) func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = offset + i * 4
            w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
