// OWNED BY terrain builder.
// GPU hydraulic erosion (virtual-pipe shallow water model, Mei et al. 2007) + thermal weathering,
// as Metal compute kernels compiled at runtime. Operates on `HeightField.base`, writes back the eroded
// terrain and a moisture map (time-averaged water depth / flow).
import Foundation
import Metal
import simd
import PWCore
import PWRender

public struct ErosionParams: Sendable {
    public var iterations = 240
    public var thermalIterations = 40
    public var dt: Float = 0.05
    public var rain: Float = 1.0            // m/s of rain (×dt per step)
    public var evaporation: Float = 0.05
    public var capacity: Float = 2.0        // sediment capacity constant Kc
    public var dissolve: Float = 0.5        // Ks
    public var deposit: Float = 0.3         // Kd
    public var maxErosionDepth: Float = 12  // m of water beyond which capacity stops growing
    public var talusAngle: Float = 0.62     // tan(slope) above which material slides (~32°)
    public var thermalRate: Float = 0.25
    public var strength: Float = 1
    public init() {}
}

public struct ErosionResult: Sendable { public var gpuMs: Double; public var volumeBefore: Double; public var volumeAfter: Double }

public enum TerrainErosion {
    static let source = #"""
struct ErosionU {
    uint w; uint h; float cell; float dt;
    float rain; float evap; float Kc; float Ks;
    float Kd; float maxDepth; float talus; float thermal;
    uint iter; float strength; float pad0; float pad1;
};
inline uint eidx(constant ErosionU &u, int x, int y) { return uint(clamp(y, 0, int(u.h) - 1)) * u.w + uint(clamp(x, 0, int(u.w) - 1)); }
inline float ehash(uint a, uint b) { uint h = a * 747796405u + b * 2891336453u; h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u; h = (h >> 22u) ^ h; return float(h) / 4294967295.0; }

kernel void erodeRainFlux(constant ErosionU &u [[buffer(0)]], device const float *b [[buffer(1)]], device const float *d [[buffer(2)]],
                          device float4 *flux [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(u, x, y);
    float water = d[i];
    float H = b[i] + water;
    const float A = u.cell * u.cell * 0.25, g9 = 9.81;
    float4 f = flux[i];
    float hL = x > 0 ? b[eidx(u,x-1,y)] + d[eidx(u,x-1,y)] : 1e9;
    float hR = x < int(u.w) - 1 ? b[eidx(u,x+1,y)] + d[eidx(u,x+1,y)] : 1e9;
    float hT = y > 0 ? b[eidx(u,x,y-1)] + d[eidx(u,x,y-1)] : 1e9;
    float hB = y < int(u.h) - 1 ? b[eidx(u,x,y+1)] + d[eidx(u,x,y+1)] : 1e9;
    float k = u.dt * A * g9 / u.cell;
    f = max(float4(0.0), f * 0.995 + k * (float4(H) - float4(hL, hR, hT, hB)));
    float out = f.x + f.y + f.z + f.w;
    float vol = water * u.cell * u.cell;
    if (out * u.dt > vol) f *= vol / max(out * u.dt, 1e-9);
    flux[i] = f;
}

kernel void erodeWater(constant ErosionU &u [[buffer(0)]], device float *d [[buffer(2)]], device const float4 *flux [[buffer(3)]],
                       device float2 *vel [[buffer(4)]], device float *moist [[buffer(7)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(u, x, y);
    float4 f = flux[i];
    float inL = x > 0 ? flux[eidx(u,x-1,y)].y : 0.0;      // left neighbour's right-flux flows into me
    float inR = x < int(u.w) - 1 ? flux[eidx(u,x+1,y)].x : 0.0;
    float inT = y > 0 ? flux[eidx(u,x,y-1)].w : 0.0;
    float inB = y < int(u.h) - 1 ? flux[eidx(u,x,y+1)].z : 0.0;
    float dV = u.dt * ((inL + inR + inT + inB) - (f.x + f.y + f.z + f.w));
    float d0 = d[i];
    float d1 = max(0.0, d0 + dV / (u.cell * u.cell));
    float dAvg = max(0.5 * (d0 + d1), 1e-3);
    float wx = 0.5 * (inL - f.x + f.y - inR), wy = 0.5 * (inT - f.z + f.w - inB);
    float2 v = float2(wx, wy) / (u.cell * dAvg);
    float vmax = 0.5 * u.cell / u.dt;
    float vl = length(v); if (vl > vmax) v *= vmax / vl;
    vel[i] = v;
    // rain: patchy, changes every 16 iterations
    float r = ehash(g.x / 16u + (u.iter / 16u) * 7919u, g.y / 16u + u.iter / 16u);
    d[i] = d1 + u.rain * u.dt * (0.4 + 1.2 * r);
    moist[i] += min(d1, 2.0) + 0.02 * min(vl, 10.0);
}

kernel void erodeSediment(constant ErosionU &u [[buffer(0)]], device const float *b [[buffer(1)]], device float *d [[buffer(2)]],
                          device const float2 *vel [[buffer(4)]], device const float *sIn [[buffer(5)]], device float *sOut [[buffer(6)]],
                          device float *bOut [[buffer(8)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(u, x, y);
    float bx = (b[eidx(u,x+1,y)] - b[eidx(u,x-1,y)]) / (2.0 * u.cell);
    float by = (b[eidx(u,x,y+1)] - b[eidx(u,x,y-1)]) / (2.0 * u.cell);
    float slope2 = bx * bx + by * by;
    float sinA = sqrt(slope2 / (1.0 + slope2));
    float2 v = vel[i];
    float water = d[i];
    float depthTerm = saturate(1.0 - max(0.0, u.maxDepth - water) / u.maxDepth);    // ramps 0→1 with depth
    depthTerm = sqrt(depthTerm);
    float C = u.Kc * u.strength * max(sinA, 0.03) * length(v) * depthTerm;
    float s = sIn[i];
    float bb = b[i];
    if (C > s) {
        float e = min(u.Ks * u.dt * (C - s), 0.05 * u.cell);
        bb -= e; s += e;
    } else {
        float dep = u.Kd * u.dt * (s - C);
        bb += dep; s -= dep;
    }
    bOut[i] = bb;
    sOut[i] = s;
}

kernel void erodeAdvect(constant ErosionU &u [[buffer(0)]], device float *d [[buffer(2)]], device const float2 *vel [[buffer(4)]],
                        device const float *sIn [[buffer(6)]], device float *sOut [[buffer(5)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y); uint i = eidx(u, x, y);
    float2 p = float2(g) - vel[i] * u.dt / u.cell;
    p = clamp(p, float2(0.0), float2(u.w - 1, u.h - 1));
    int2 p0 = int2(floor(p)); float2 fr = p - float2(p0);
    float s00 = sIn[eidx(u,p0.x,p0.y)], s10 = sIn[eidx(u,p0.x+1,p0.y)], s01 = sIn[eidx(u,p0.x,p0.y+1)], s11 = sIn[eidx(u,p0.x+1,p0.y+1)];
    sOut[i] = mix(mix(s00, s10, fr.x), mix(s01, s11, fr.x), fr.y);
    d[i] *= (1.0 - u.evap * u.dt);
}

// Thermal weathering: move material from cells steeper than the talus angle (8-neighbourhood, gather form).
inline float thermalOut(constant ErosionU &u, device const float *b, int x, int y, thread float &total) {
    float h = b[eidx(u,x,y)], maxD = 0.0; total = 0.0;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        float dist = (dx != 0 && dy != 0) ? 1.41421 : 1.0;
        float diff = h - b[eidx(u,x+dx,y+dy)];
        if (diff / (dist * u.cell) > u.talus) { total += diff; maxD = max(maxD, diff); }
    }
    return maxD;
}
kernel void erodeThermal(constant ErosionU &u [[buffer(0)]], device const float *b [[buffer(1)]], device float *bOut [[buffer(8)]],
                         uint2 g [[thread_position_in_grid]]) {
    if (g.x >= u.w || g.y >= u.h) return;
    int x = int(g.x), y = int(g.y);
    float h = b[eidx(u,x,y)];
    float myTotal; float myMax = thermalOut(u, b, x, y, myTotal);
    float moved = myTotal > 0.0 ? u.thermal * 0.5 * (myMax - u.talus * u.cell) : 0.0;
    moved = max(moved, 0.0);
    float delta = -moved;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        int nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= int(u.w) || ny >= int(u.h)) continue;
        float nTotal; float nMax = thermalOut(u, b, nx, ny, nTotal);
        if (nTotal <= 0.0) continue;
        float diff = b[eidx(u,nx,ny)] - h;
        float dist = (dx != 0 && dy != 0) ? 1.41421 : 1.0;
        if (diff / (dist * u.cell) > u.talus) {
            float nMoved = max(0.0, u.thermal * 0.5 * (nMax - u.talus * u.cell));
            delta += nMoved * diff / nTotal;
        }
    }
    bOut[uint(y) * u.w + uint(x)] = h + delta;
}
"""#

    struct Uniforms {
        var w: UInt32, h: UInt32, cell: Float, dt: Float
        var rain: Float, evap: Float, Kc: Float, Ks: Float
        var Kd: Float, maxDepth: Float, talus: Float, thermal: Float
        var iter: UInt32, strength: Float, pad0: Float = 0, pad1: Float = 0
    }

    /// Erode `field.base` in place (whole field). Synchronous: waits for the GPU.
    @discardableResult
    public static func run(field: HeightField, params: ErosionParams, device: (any MTLDevice)? = GPU.shared?.device,
                           queue: (any MTLCommandQueue)? = GPU.shared?.queue) throws -> ErosionResult {
        guard let device, let queue else { throw RenderError.noDevice }
        let lib = try ShaderLibrary.shared.library(named: "terrain.erosion", source: source, device: device)
        func pso(_ n: String) throws -> any MTLComputePipelineState { try device.makeComputePipelineState(function: ShaderLibrary.shared.function(lib, n)) }
        let pRainFlux = try pso("erodeRainFlux"), pWater = try pso("erodeWater"), pSed = try pso("erodeSediment")
        let pAdvect = try pso("erodeAdvect"), pThermal = try pso("erodeThermal")

        let W = field.width, H = field.height, n = W * H
        let fbytes = n * 4
        func buf(_ len: Int) -> any MTLBuffer { device.makeBuffer(length: len, options: .storageModeShared)! }
        let bA = device.makeBuffer(bytes: field.base.ptr, length: fbytes, options: .storageModeShared)!
        let bB = buf(fbytes), water = buf(fbytes), flux = buf(n * 16), vel = buf(n * 8), sA = buf(fbytes), sB = buf(fbytes), moist = buf(fbytes)
        for b in [water, flux, vel, sA, sB, moist] { memset(b.contents(), 0, b.length) }

        let volBefore = field.base.buffer.reduce(0.0) { $0 + Double($1) }
        var params = params
        if let e = ProcessInfo.processInfo.environment["PW_EROSION_TUNE"]?.split(separator: ",").compactMap({ Float($0) }), e.count == 6 {
            params.rain = e[0]; params.evaporation = e[1]; params.capacity = e[2]; params.dissolve = e[3]; params.deposit = e[4]; params.dt = e[5]
        }
        var u = Uniforms(w: UInt32(W), h: UInt32(H), cell: Float(field.spacing), dt: params.dt, rain: params.rain * Float(field.spacing) / 8,
                         evap: params.evaporation, Kc: params.capacity, Ks: params.dissolve, Kd: params.deposit,
                         maxDepth: params.maxErosionDepth, talus: params.talusAngle, thermal: params.thermalRate, iter: 0, strength: params.strength)
        let grid = MTLSize(width: W, height: H, depth: 1), tg = MTLSize(width: 16, height: 16, depth: 1)
        var bCur = bA, bOther = bB
        var gpuMs = 0.0
        let total = params.iterations + params.thermalIterations
        var it = 0
        while it < total {
            guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw RenderError.pipeline("erosion command buffer") }
            cb.label = "terrain.erosion"
            let batchEnd = min(total, it + 40)
            while it < batchEnd {
                u.iter = UInt32(it)
                e.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                if it < params.iterations {
                    e.setComputePipelineState(pRainFlux)
                    e.setBuffer(bCur, offset: 0, index: 1); e.setBuffer(water, offset: 0, index: 2); e.setBuffer(flux, offset: 0, index: 3)
                    e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    e.setComputePipelineState(pWater)
                    e.setBuffer(vel, offset: 0, index: 4); e.setBuffer(moist, offset: 0, index: 7)
                    e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    e.setComputePipelineState(pSed)
                    e.setBuffer(sA, offset: 0, index: 5); e.setBuffer(sB, offset: 0, index: 6); e.setBuffer(bOther, offset: 0, index: 8)
                    e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    swap(&bCur, &bOther)
                    e.setComputePipelineState(pAdvect)
                    e.setBuffer(sB, offset: 0, index: 6); e.setBuffer(sA, offset: 0, index: 5)
                    e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    // a light thermal pass every 4 hydraulic steps keeps channels from over-steepening
                    if it % 4 == 3 {
                        e.setComputePipelineState(pThermal)
                        e.setBuffer(bCur, offset: 0, index: 1); e.setBuffer(bOther, offset: 0, index: 8)
                        e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                        swap(&bCur, &bOther)
                    }
                } else {
                    e.setComputePipelineState(pThermal)
                    e.setBuffer(bCur, offset: 0, index: 1); e.setBuffer(bOther, offset: 0, index: 8)
                    e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                    swap(&bCur, &bOther)
                }
                it += 1
            }
            e.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            if let err = cb.error { throw RenderError.pipeline("erosion: \(err)") }
            gpuMs += (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        // Deposit the suspended sediment back so mass is conserved, then copy out.
        let bp = bCur.contents().bindMemory(to: Float.self, capacity: n)
        let sp = sA.contents().bindMemory(to: Float.self, capacity: n)
        let mp = moist.contents().bindMemory(to: Float.self, capacity: n)
        let out = field.base.ptr, mo = field.moisture.ptr
        // moisture: log-scaled time-averaged water depth, normalised by the 98th percentile
        let iters = Float(max(params.iterations, 1))
        var sample: [Float] = stride(from: 0, to: n, by: max(1, n / 4096)).map { log(1 + mp[$0] / iters * 20) }
        sample.sort()
        let p98 = max(sample[min(sample.count - 1, sample.count * 98 / 100)], 1e-4)
        JobSystem.shared.parallelFor(n, grain: 65536) { r in
            for i in r {
                out[i] = bp[i] + sp[i]
                mo[i] = min(1, max(0, log(1 + mp[i] / iters * 20) / p98))
            }
        }
        let volAfter = field.base.buffer.reduce(0.0) { $0 + Double($1) }
        return ErosionResult(gpuMs: gpuMs, volumeBefore: volBefore, volumeAfter: volAfter)
    }
}
