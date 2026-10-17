// CFD flow visualisation overlay (FLY, AeroModel.full): a semi-transparent slice quad textured with the solver's
// speed / pressure / vorticity slice, plus tracer particles as point sprites. PWRender does not depend on PWFlow,
// so the App copies the solver products in each frame (see docs/CFD.md, "Visualisation"):
//     overlay.sliceTexture = solver.slice?.texture; overlay.sliceOrigin = s.origin; overlay.sliceU = s.uEdge; overlay.sliceV = s.vEdge
//     overlay.particleBuffer = solver.particleBuffer; overlay.particleCount = solver.particleCount
//     overlay.particleOrigin = solver.gridOrigin; overlay.particleScale = solver.dx
// Drawn in the transparent pass (premultiplied alpha, depth-tested, no depth write).
import Foundation
import Metal
import simd
import PWCore

public final class FlowOverlayRenderable: Renderable {
    public var renderOrder: Int { 110 }
    public var enabled = true
    /// Slice: texture (rgba8, alpha = coverage) and its world placement: texel (0,0) corner + edge vectors.
    public var sliceTexture: MTLTexture?
    public var sliceOrigin = Vec3d.zero, sliceU = Vec3d(1, 0, 0), sliceV = Vec3d(0, 1, 0)
    public var sliceOpacity: Float = 0.8
    /// Particles: float4 buffer of grid coordinates; world = particleOrigin + p.xyz · particleScale.
    public var particleBuffer: MTLBuffer?
    public var particleCount = 0
    public var particleOrigin = Vec3d.zero, particleScale = 1.0
    public var particleSize: Float = 5

    public init() {}

    struct DrawGPU {
        var origin = SIMD4<Float>(0, 0, 0, 0)    // camera-relative; w = opacity
        var u = SIMD4<Float>(0, 0, 0, 0)         // w = point size (px)
        var v = SIMD4<Float>(0, 0, 0, 0)         // w = particle scale (m per cell)
    }

    private var pso: (MTLRenderPipelineState, MTLRenderPipelineState)?
    private var psoSamples = -1
    private var depth: MTLDepthStencilState?
    private var failed = false

    private func pipelines(_ frame: FrameContext) -> (MTLRenderPipelineState, MTLRenderPipelineState)? {
        if let pso, psoSamples == frame.sampleCount { return pso }
        if failed { return nil }
        do {
            let lib = try ShaderLibrary.shared.library(named: "flow.overlay", source: Self.source, device: frame.device)
            func make(_ vs: String, _ fs: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = try ShaderLibrary.shared.function(lib, vs)
                d.fragmentFunction = try ShaderLibrary.shared.function(lib, fs)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = frame.pipelines.hdrFormat
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                d.depthAttachmentPixelFormat = frame.pipelines.depthFormat
                d.rasterSampleCount = frame.sampleCount
                return try frame.device.makeRenderPipelineState(descriptor: d)
            }
            pso = (try make("flowSliceVertex", "flowSliceFragment"), try make("flowParticleVertex", "flowParticleFragment"))
            psoSamples = frame.sampleCount
            return pso
        } catch { print("[FlowOverlay] pipeline error: \(error)"); failed = true; return nil }
    }

    public func drawTransparent(_ enc: any MTLRenderCommandEncoder, frame: FrameContext) {
        guard enabled, sliceTexture != nil || (particleBuffer != nil && particleCount > 0), let (slicePSO, partPSO) = pipelines(frame) else { return }
        enc.setDepthStencilState(frame.pipelines.depthReadOnly)
        enc.setCullMode(.none)
        let cam = frame.camera.position
        if let tex = sliceTexture {
            var d = DrawGPU(origin: SIMD4((sliceOrigin - cam).float, sliceOpacity), u: SIMD4(sliceU.float, 0), v: SIMD4(sliceV.float, 0))
            enc.setRenderPipelineState(slicePSO)
            frame.bindFrame(enc)
            enc.setVertexBytes(&d, length: MemoryLayout<DrawGPU>.stride, index: 3)
            enc.setFragmentBytes(&d, length: MemoryLayout<DrawGPU>.stride, index: 3)
            enc.setFragmentTexture(tex, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let pb = particleBuffer, particleCount > 0 {
            var d = DrawGPU(origin: SIMD4((particleOrigin - cam).float, 1), u: SIMD4(0, 0, 0, particleSize), v: SIMD4(0, 0, 0, Float(particleScale)))
            enc.setRenderPipelineState(partPSO)
            frame.bindFrame(enc)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.setVertexBytes(&d, length: MemoryLayout<DrawGPU>.stride, index: 3)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        }
    }

    static let source = #"""
struct FlowDraw { float4 origin; float4 u; float4 v; };
struct FlowVOut { float4 pos [[position]]; float2 uv; float size [[point_size]]; float age; };

vertex FlowVOut flowSliceVertex(uint vid [[vertex_id]], constant FrameUniforms& F [[buffer(2)]], constant FlowDraw& D [[buffer(3)]]) {
    float2 uv = float2(vid & 1, vid >> 1);
    float3 p = D.origin.xyz + uv.x * D.u.xyz + uv.y * D.v.xyz;
    FlowVOut o; o.pos = F.viewProj * float4(p, 1); o.uv = uv; o.size = 1; o.age = 0;
    return o;
}
fragment float4 flowSliceFragment(FlowVOut in [[stage_in]], constant FrameUniforms& F [[buffer(2)]], constant FlowDraw& D [[buffer(3)]],
                                  texture2d<float> tex [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    float a = c.a * D.origin.w;
    float k = 1.0 / max(F.params.y, 1e-6);   // pre-divide exposure so the colour map reads as displayed
    return float4(c.rgb * a * k, a);
}

vertex FlowVOut flowParticleVertex(uint vid [[vertex_id]], const device float4* P [[buffer(0)]], constant FrameUniforms& F [[buffer(2)]],
                                   constant FlowDraw& D [[buffer(3)]]) {
    float4 q = P[vid];
    float3 p = D.origin.xyz + q.xyz * D.v.w;
    FlowVOut o; o.pos = F.viewProj * float4(p, 1); o.uv = 0; o.size = D.u.w; o.age = q.w;
    if (q.x < 0) o.pos = float4(0, 0, -2, 1);   // not yet spawned
    return o;
}
fragment float4 flowParticleFragment(FlowVOut in [[stage_in]], float2 pc [[point_coord]], constant FrameUniforms& F [[buffer(2)]]) {
    float r = length(pc - 0.5) * 2.0;
    if (r > 1.0) discard_fragment();
    float a = (1.0 - r) * 0.9;
    float k = 1.0 / max(F.params.y, 1e-6);
    float3 c = mix(float3(0.95, 0.98, 1.0), float3(0.3, 0.7, 1.0), clamp(in.age / 2000.0, 0.0, 1.0));
    return float4(c * a * k, a);
}
"""#
}
