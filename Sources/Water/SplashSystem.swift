// OWNED BY water builder.
// CPU spray/splash particles (ballistic with quadratic air drag), rendered as lit soft billboards.
// Emission is thread-safe (called from hull force evaluation on JobSystem workers / sim thread);
// integration happens once per rendered frame.
import Foundation
import simd
import PWCore

public final class SplashSystem: @unchecked Sendable {
    struct Particle { var pos: Vec3d; var vel: Vec3d; var age: Float; var life: Float; var size: Float }
    public var maxParticles = 16384
    public var airDrag = 0.6                   // 1/m quadratic drag coefficient for droplets/spray clumps
    private var particles: [Particle] = []
    private var pending: [Particle] = []
    private var rng = PCG32(seed: 99)
    private let lock = NSLock()

    public init() {}
    public var count: Int { lock.lock(); defer { lock.unlock() }; return particles.count }

    /// Emit `count` droplets around `position` with mean velocity `velocity` and relative spread.
    public func emit(at position: Vec3d, velocity: Vec3d, count: Int, spread: Double = 0.5, radius: Double = 0.3) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let room = maxParticles - particles.count - pending.count
        let n = min(count, max(0, room))
        let sp = max(simd_length(velocity), 1) * spread
        for _ in 0..<n {
            let j = Vec3d(rng.unit() * 2 - 1, rng.unit() * 2 - 1, rng.unit() * 2 - 1)
            let o = Vec3d(rng.unit() * 2 - 1, 0, rng.unit() * 2 - 1) * radius
            pending.append(Particle(pos: position + o, vel: velocity + j * sp + Vec3d(0, rng.unit() * sp, 0), age: 0,
                                    life: Float(0.6 + rng.unit() * 1.4), size: Float(0.05 + rng.unit() * 0.18)))
        }
    }

    /// Advance all particles; droplets die when they re-enter the water or expire.
    func update(dt: Double, gravity: Double = kGravity, surface: (Double, Double) -> Double) {
        lock.lock()
        particles.append(contentsOf: pending); pending.removeAll(keepingCapacity: true)
        lock.unlock()
        guard dt > 0, !particles.isEmpty else { return }
        var alive = 0
        for i in 0..<particles.count {
            var p = particles[i]
            let sp = simd_length(p.vel)
            p.vel += (Vec3d(0, -gravity, 0) - p.vel * (airDrag * sp)) * dt
            p.pos += p.vel * dt
            p.age += Float(dt)
            p.size *= Float(1 + 0.6 * dt)          // spray clumps spread out as they fly
            let below = p.vel.y < 0 && p.pos.y < surface(p.pos.x, p.pos.z)
            if p.age < p.life && !below { particles[alive] = p; alive += 1 }
        }
        particles.removeLast(particles.count - alive)
    }

    /// Two float4 per particle: (camera-relative pos, size), (alpha, 0, 0, 0).
    func instances(origin: Vec3d) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []; out.reserveCapacity(particles.count * 2)
        for p in particles {
            let r = (p.pos - origin).float
            let fade = 1 - p.age / p.life
            out.append(SIMD4(r, p.size)); out.append(SIMD4(0.55 * fade, 0, 0, 0))
        }
        return out
    }
}
