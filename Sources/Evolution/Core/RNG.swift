// OWNED BY architect. ------------------------------------------------------------------------------
// Deterministic, Codable RNG used EVERYWHERE in evolution (algorithms, episode randomisation, JS Math.random).
// Never use SystemRandomNumberGenerator / Double.random() in evolution code: runs must be reproducible.
import Foundation

/// xoshiro256** seeded through SplitMix64. Value type: copy = fork of the stream.
public struct EvoRNG: RandomNumberGenerator, Codable, Sendable, Equatable {
    public var s0: UInt64, s1: UInt64, s2: UInt64, s3: UInt64

    public init(seed: UInt64) {
        var x = seed
        func sm() -> UInt64 { x &+= 0x9E3779B97F4A7C15; var z = x; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        s0 = sm(); s1 = sm(); s2 = sm(); s3 = sm()
        if s0 | s1 | s2 | s3 == 0 { s0 = 1 }
    }

    @inline(__always) static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }

    @inline(__always) public mutating func next() -> UInt64 {
        let r = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t; s3 = Self.rotl(s3, 45)
        return r
    }
    /// Uniform [0, 1).
    @inline(__always) public mutating func nextDouble() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    @inline(__always) public mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * nextDouble() }
    /// Uniform integer in 0..<n (n > 0).
    @inline(__always) public mutating func int(below n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    /// Standard normal (Box–Muller, no cached spare so the stream stays a pure function of the state).
    @inline(__always) public mutating func gaussian() -> Double {
        let u1 = max(nextDouble(), 1e-300), u2 = nextDouble()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Stable seed derivation: hash of a root seed and a path of integers (generation, candidate, episode...).
    /// Every per-candidate / per-episode RNG is `EvoRNG(seed: EvoRNG.derive(root, gen, idx, ep))`, so
    /// results never depend on thread scheduling.
    public static func derive(_ root: UInt64, _ path: Int...) -> UInt64 {
        var h = root ^ 0x6A09E667F3BCC909
        for p in path {
            h ^= UInt64(bitPattern: Int64(p)) &+ 0x9E3779B97F4A7C15 &+ (h << 6) &+ (h >> 2)
            h = (h ^ (h >> 33)) &* 0xFF51AFD7ED558CCD
            h = (h ^ (h >> 33)) &* 0xC4CEB9FE1A85EC53
            h ^= h >> 33
        }
        return h
    }
}
