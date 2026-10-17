// Direct3D 12 backend. Shaders: Slang -> HLSL -> DXIL (Windows SDK dxc) embedded at build time.
// Own device (hardware adapter, or WARP when preferSoftware / no hardware) or a host's device + queue (Qt Quick).
//
// One root signature for every pipeline (see pw/gpu.h): root CBVs b0..b3, an SRV table t0..t11, a UAV table
// u8..u11, static samplers s0..s3. Views live in a CPU staging heap and are copied into a per-frame shader-visible
// ring when a draw / dispatch needs a new table. Texture states are tracked per subresource on the CPU (record
// order == submission order); buffers rely on implicit promotion / decay (they are read-only on the GPU).
// Cross-queue textures are created with ALLOW_SIMULTANEOUS_ACCESS: they decay to COMMON after every
// ExecuteCommandLists, so the tracker resets them to COMMON at the first use in each command list.
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <tuple>
#include <vector>
#include "pw/gpu.h"
#include "pw/shaders.h"

using Microsoft::WRL::ComPtr;

namespace pw::gpu {
namespace {

constexpr std::size_t kRingSize = 32u << 20;
constexpr UINT kStagingDescriptors = 65536;
constexpr UINT kRingDescriptors = 32768;   // per frame slot
constexpr UINT kRtvDescriptors = 4096, kDsvDescriptors = 1024;
constexpr int kSrvSlots = 12, kUavSlots = 4;
constexpr D3D12_RESOURCE_STATES kSrvGraphics = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
constexpr D3D12_RESOURCE_STATES kSrvCompute = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;

std::string narrow(const wchar_t* w) {
    std::string s;
    for (; *w; ++w) s += (*w < 128) ? char(*w) : '?';
    return s;
}
std::wstring widen(const char* s) { std::wstring w; for (; s && *s; ++s) w += wchar_t(static_cast<unsigned char>(*s)); return w; }
std::string hrs(HRESULT h) { char b[32]; std::snprintf(b, sizeof b, "0x%08lx", static_cast<unsigned long>(h)); return b; }

DXGI_FORMAT dxFormat(Format f) {
    switch (f) {
        case Format::RGBA8: return DXGI_FORMAT_R8G8B8A8_UNORM;
        case Format::RGBA16F: return DXGI_FORMAT_R16G16B16A16_FLOAT;
        case Format::RG16F: return DXGI_FORMAT_R16G16_FLOAT;
        case Format::R32F: return DXGI_FORMAT_R32_FLOAT;
        case Format::D32F: return DXGI_FORMAT_D32_FLOAT;
        default: return DXGI_FORMAT_UNKNOWN;
    }
}
D3D12_COMPARISON_FUNC dxCompare(CompareOp c) {
    switch (c) {
        case CompareOp::Never: return D3D12_COMPARISON_FUNC_NEVER;
        case CompareOp::Less: return D3D12_COMPARISON_FUNC_LESS;
        case CompareOp::LessEqual: return D3D12_COMPARISON_FUNC_LESS_EQUAL;
        case CompareOp::Greater: return D3D12_COMPARISON_FUNC_GREATER;
        case CompareOp::GreaterEqual: return D3D12_COMPARISON_FUNC_GREATER_EQUAL;
        default: return D3D12_COMPARISON_FUNC_ALWAYS;
    }
}
Vendor vendorFromId(UINT id) {
    switch (id) {
        case 0x10DE: return Vendor::NVIDIA; case 0x1002: case 0x1022: return Vendor::AMD; case 0x8086: return Vendor::Intel;
        case 0x1414: return Vendor::Microsoft; case 0x5143: case 0x4D4F4351: return Vendor::Qualcomm; default: return Vendor::Unknown;
    }
}

/// Simple free-list allocator over a CPU descriptor heap.
struct DescriptorPool {
    ComPtr<ID3D12DescriptorHeap> heap;
    UINT inc = 0, next = 0, capacity = 0;
    std::vector<UINT> freeList;
    D3D12_CPU_DESCRIPTOR_HANDLE base{};
    bool init(ID3D12Device* dev, D3D12_DESCRIPTOR_HEAP_TYPE type, UINT n) {
        D3D12_DESCRIPTOR_HEAP_DESC d = {};
        d.Type = type; d.NumDescriptors = n;
        if (FAILED(dev->CreateDescriptorHeap(&d, IID_PPV_ARGS(&heap)))) return false;
        inc = dev->GetDescriptorHandleIncrementSize(type);
        base = heap->GetCPUDescriptorHandleForHeapStart();
        capacity = n;
        return true;
    }
    D3D12_CPU_DESCRIPTOR_HANDLE alloc() {
        UINT i;
        if (!freeList.empty()) { i = freeList.back(); freeList.pop_back(); }
        else i = next < capacity ? next++ : capacity - 1;   // exhaustion: reuse the last slot (never expected)
        return {base.ptr + SIZE_T(i) * inc};
    }
    void release(D3D12_CPU_DESCRIPTOR_HANDLE h) { if (h.ptr) freeList.push_back(UINT((h.ptr - base.ptr) / inc)); }
};

class D3D12Device;

class D3D12Texture final : public Texture {
public:
    D3D12Device* owner = nullptr;
    ComPtr<ID3D12Resource> res;
    std::vector<D3D12_RESOURCE_STATES> states;   // per subresource
    bool simultaneous = false;
    uint64_t listEpoch = 0;                      // command list that last touched a simultaneous-access texture
    std::map<std::tuple<int, int, int, int>, D3D12_CPU_DESCRIPTOR_HANDLE> srvs;
    std::map<int, D3D12_CPU_DESCRIPTOR_HANDLE> uavs;
    std::map<std::pair<int, int>, D3D12_CPU_DESCRIPTOR_HANDLE> rtvs, dsvs;
    D3D12Texture(const TextureDesc& desc) { d = desc; }
    ~D3D12Texture() override;
    void* native() const override { return res.Get(); }
    int mipCount() const { return d.mips; }
    UINT sub(int mip, int layer) const { return UINT(mip + layer * d.mips); }
};

class D3D12Buffer final : public Buffer {
public:
    ComPtr<ID3D12Resource> res;
    void* mapped = nullptr;
    D3D12Buffer(const BufferDesc& desc) { d = desc; }
    void* map() override { return mapped; }
    D3D12_GPU_VIRTUAL_ADDRESS gpu() const { return res->GetGPUVirtualAddress(); }
};

class D3D12Pipeline final : public Pipeline {
public:
    ComPtr<ID3D12PipelineState> pso;
    D3D12_PRIMITIVE_TOPOLOGY topology = D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
    void setCompute(const int g[3]) { compute = true; group[0] = g[0]; group[1] = g[1]; group[2] = g[2]; }
};

class D3D12Fence final : public Fence {
public:
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    ~D3D12Fence() override { if (event) CloseHandle(event); }
    uint64_t completedValue() const override { return fence->GetCompletedValue(); }
    void wait(uint64_t v) override {
        if (fence->GetCompletedValue() >= v) return;
        fence->SetEventOnCompletion(v, event);
        WaitForSingleObject(event, INFINITE);
    }
};

class D3D12CommandList final : public CommandList {
public:
    D3D12Device* dev = nullptr;
    ComPtr<ID3D12CommandAllocator> alloc[kFramesInFlight];
    ComPtr<ID3D12GraphicsCommandList> list;
    uint64_t epoch = 0;
    D3D12Pipeline* pso = nullptr;
    D3D12_GPU_VIRTUAL_ADDRESS cbs[4] = {};
    TextureView srvTex[8];
    struct SB { D3D12Buffer* buf = nullptr; std::size_t off = 0; } sbs[4];
    TextureView uavTex[4];
    bool tablesDirty = true, cbDirty = true, inRender = false, inCompute = false, uavPending = false;
    int rtW = 0, rtH = 0;
    int passTimer = -1;
    std::vector<int> timersUsed;
    std::vector<D3D12_RESOURCE_BARRIER> barriers;
    // render-pass attachments (states restored by the tracker only when used later)
    TextureView colorViews[kMaxColorTargets];
    int colorCount = 0;
    TextureView depthView;

    bool create(ID3D12Device* d, QueueType queue) {
        q = queue;
        D3D12_COMMAND_LIST_TYPE t = queue == QueueType::Compute ? D3D12_COMMAND_LIST_TYPE_COMPUTE : D3D12_COMMAND_LIST_TYPE_DIRECT;
        for (auto& a : alloc) if (FAILED(d->CreateCommandAllocator(t, IID_PPV_ARGS(&a)))) return false;
        if (FAILED(d->CreateCommandList(0, t, alloc[0].Get(), nullptr, IID_PPV_ARGS(&list)))) return false;
        list->Close();
        return true;
    }
    void begin(int slot, uint64_t ep);
    void resetBindings() {
        pso = nullptr;
        for (auto& c : cbs) c = 0;
        for (auto& t : srvTex) t = {};
        for (auto& b : sbs) b = {};
        for (auto& t : uavTex) t = {};
        tablesDirty = cbDirty = true;
    }

    // ---- state tracking
    void transition(D3D12Texture* t, int mip, int mipN, int layer, int layerN, D3D12_RESOURCE_STATES want) {
        if (t->simultaneous && t->listEpoch != epoch) {   // decayed to COMMON at the end of the last ExecuteCommandLists
            std::fill(t->states.begin(), t->states.end(), D3D12_RESOURCE_STATE_COMMON);
            t->listEpoch = epoch;
        }
        const int mips = t->mipCount(), layers = t->desc().type == TextureType::Tex2DArray ? t->desc().depthOrLayers : 1;
        if (mipN < 0) mipN = mips - mip;
        if (layerN < 0) layerN = layers - layer;
        bool whole = mip == 0 && mipN == mips && layer == 0 && layerN == layers;
        if (whole) {
            bool uniform = std::all_of(t->states.begin(), t->states.end(), [&](D3D12_RESOURCE_STATES s) { return s == t->states[0]; });
            if (uniform) {
                if (t->states[0] != want) pushBarrier(t, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, t->states[0], want);
                std::fill(t->states.begin(), t->states.end(), want);
                return;
            }
        }
        for (int l = layer; l < layer + layerN; ++l)
            for (int m = mip; m < mip + mipN; ++m) {
                UINT s = t->sub(m, l);
                if (t->states[s] != want) { pushBarrier(t, s, t->states[s], want); t->states[s] = want; }
            }
    }
    void pushBarrier(D3D12Texture* t, UINT sub, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b) {
        if (t->simultaneous && a == D3D12_RESOURCE_STATE_COMMON) return;   // implicit promotion
        D3D12_RESOURCE_BARRIER x = {};
        x.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        x.Transition.pResource = t->res.Get(); x.Transition.Subresource = sub;
        x.Transition.StateBefore = a; x.Transition.StateAfter = b;
        barriers.push_back(x);
    }
    void flushBarriers() {
        if (!barriers.empty()) { list->ResourceBarrier(UINT(barriers.size()), barriers.data()); barriers.clear(); }
    }

    void beginRenderPass(const RenderPassDesc& rp) override;
    void endRenderPass() override;
    void beginComputePass(const char* label, int timer) override;
    void endComputePass() override;
    void setPipeline(Pipeline* p) override;
    void setConstants(int slot, const void* data, std::size_t size) override;
    void setConstantBuffer(int slot, Buffer* b, std::size_t off) override {
        if (slot < 0 || slot >= 4 || !b) return;
        cbs[slot] = static_cast<D3D12Buffer*>(b)->gpu() + off; cbDirty = true;
    }
    void setTexture(int slot, const TextureView& v) override { if (slot >= 0 && slot < 8) { srvTex[slot] = v; tablesDirty = true; } }
    void setBuffer(int slot, Buffer* b, std::size_t off) override {
        if (slot < 8 || slot >= 12) return;
        sbs[slot - 8] = {static_cast<D3D12Buffer*>(b), off}; tablesDirty = true;
    }
    void setStorageTexture(int slot, const TextureView& v) override { if (slot >= 8 && slot < 12) { uavTex[slot - 8] = v; tablesDirty = true; } }
    void setViewport(int x, int y, int w, int h) override {
        D3D12_VIEWPORT vp = {float(x), float(y), float(w), float(h), 0, 1};
        D3D12_RECT sc = {LONG(x), LONG(y), LONG(x + w), LONG(y + h)};
        list->RSSetViewports(1, &vp); list->RSSetScissorRects(1, &sc);
    }
    void flush(bool graphics);
    void draw(int vc, int ic, int first) override {
        if (!pso || !inRender) return;
        flush(true);
        list->DrawInstanced(UINT(vc), UINT(ic), UINT(first), 0);
    }
    void drawIndexed(Buffer* ib, int n, int ic, int firstIndex, int baseVertex) override {
        if (!pso || !inRender || !ib) return;
        flush(true);
        auto* b = static_cast<D3D12Buffer*>(ib);
        D3D12_INDEX_BUFFER_VIEW v = {b->gpu(), UINT(b->size()), DXGI_FORMAT_R32_UINT};
        list->IASetIndexBuffer(&v);
        list->DrawIndexedInstanced(UINT(n), UINT(ic), UINT(firstIndex), baseVertex, 0);
    }
    void dispatchGroups(int x, int y, int z) override {
        if (!pso || !inCompute) return;
        flush(false);
        list->Dispatch(UINT(x), UINT(y), UINT(z));
        for (auto& u : uavTex) if (u.texture) uavPending = true;
    }
    void dispatchThreads(int x, int y, int z) override {
        if (!pso) return;
        const int* g = pso->groupSize();
        dispatchGroups((x + g[0] - 1) / g[0], (y + g[1] - 1) / g[1], (z + g[2] - 1) / g[2]);
    }
    void copyTextureToBuffer(const TextureView& v, Buffer* dst, std::size_t offset) override;
    void copyBufferToTexture(Buffer* src, std::size_t offset, const TextureView& v) override;
    void copyBuffer(Buffer* src, std::size_t so, Buffer* dst, std::size_t dO, std::size_t size) override {
        list->CopyBufferRegion(static_cast<D3D12Buffer*>(dst)->res.Get(), dO, static_cast<D3D12Buffer*>(src)->res.Get(), so, size);
    }
    void finishForSampling(const TextureView& v) override {
        auto* t = static_cast<D3D12Texture*>(v.texture);
        transition(t, 0, -1, 0, -1, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        flushBarriers();
    }
};

class D3D12Device final : public Device {
public:
    ComPtr<IDXGIFactory4> factory;
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> gfx, comp;
    ComPtr<ID3D12RootSignature> root;
    DescriptorPool staging, rtvPool, dsvPool;
    ComPtr<ID3D12DescriptorHeap> ringHeap;
    UINT ringInc = 0, ringCursor = 0;
    D3D12_CPU_DESCRIPTOR_HANDLE nullSrv{}, nullUav{};
    struct Ring { ComPtr<ID3D12Resource> buf; uint8_t* cpu = nullptr; std::size_t off = 0; std::vector<std::unique_ptr<D3D12Buffer>> overflow; std::unique_ptr<D3D12Buffer> wrapper; } rings[kFramesInFlight];
    ComPtr<ID3D12Fence> gfxFence, compFence;
    HANDLE event = nullptr;
    uint64_t gfxValue = 0, compValue = 0, slotGfx[kFramesInFlight] = {}, slotComp[kFramesInFlight] = {};
    std::vector<std::unique_ptr<D3D12CommandList>> lists[2];
    std::size_t cursor[2] = {0, 0};
    uint64_t epochCounter = 0;
    bool inFrame = false;
    // timestamps
    ComPtr<ID3D12QueryHeap> queryHeap;
    ComPtr<ID3D12Resource> queryReadback;
    uint64_t* queryCpu = nullptr;
    uint64_t freqGfx = 1, freqComp = 1;
    uint32_t timerMask[kFramesInFlight] = {}, timerCompute[kFramesInFlight] = {};
    std::map<std::string, ComPtr<ID3D12PipelineState>> psoCache;

    ~D3D12Device() override {
        if (dev && gfx) waitIdle();
        if (event) CloseHandle(event);
    }

    bool fail(std::string* err, const std::string& m, HRESULT h) { if (err) *err = m + " (" + hrs(h) + ")"; return false; }

    bool init(const CreateInfo& ci, std::string* err) {
        HRESULT h;
        DXGI_ADAPTER_DESC1 ad = {};
        if (ci.debugLayer) {
            ComPtr<ID3D12Debug> dbg;
            if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&dbg)))) dbg->EnableDebugLayer();
        }
        if (FAILED(h = CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return fail(err, "CreateDXGIFactory1", h);
        if (ci.externalDevice) {
            dev = static_cast<ID3D12Device*>(ci.externalDevice);
            if (ci.externalQueue) gfx = static_cast<ID3D12CommandQueue*>(ci.externalQueue);
            LUID luid = dev->GetAdapterLuid();
            ComPtr<IDXGIAdapter1> a;
            if (SUCCEEDED(factory->EnumAdapterByLuid(luid, IID_PPV_ARGS(&a)))) a->GetDesc1(&ad);
        } else {
            ComPtr<IDXGIAdapter1> chosen;
            if (!ci.preferSoftware) {
                ComPtr<IDXGIFactory6> f6;
                if (SUCCEEDED(factory.As(&f6))) {
                    for (UINT i = 0;; ++i) {
                        ComPtr<IDXGIAdapter1> a;
                        if (f6->EnumAdapterByGpuPreference(i, DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&a)) == DXGI_ERROR_NOT_FOUND) break;
                        DXGI_ADAPTER_DESC1 d; a->GetDesc1(&d);
                        if (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
                        if (SUCCEEDED(D3D12CreateDevice(a.Get(), D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), nullptr))) { chosen = a; break; }
                    }
                }
            }
            if (!chosen) {
                ComPtr<IDXGIAdapter> warp;
                if (FAILED(h = factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)))) return fail(err, "EnumWarpAdapter", h);
                warp.As(&chosen);
            }
            chosen->GetDesc1(&ad);
            if (FAILED(h = D3D12CreateDevice(chosen.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)))) return fail(err, "D3D12CreateDevice", h);
        }
        c.backend = Backend::D3D12;
        c.adapter = ad.Description[0] ? narrow(ad.Description) : "Direct3D 12 adapter";
        c.vendorId = ad.VendorId; c.deviceId = ad.DeviceId;
        c.software = (ad.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 || ad.VendorId == 0x1414;
        c.vendor = vendorFromId(ad.VendorId);
        c.tuning = tuningFor(c.vendor, c.software);
        c.asyncComputeQueue = true;
        c.timestamps = true;
        if (!gfx) {
            D3D12_COMMAND_QUEUE_DESC qd = {}; qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
            if (FAILED(h = dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&gfx)))) return fail(err, "CreateCommandQueue", h);
        }
        {
            D3D12_COMMAND_QUEUE_DESC qd = {}; qd.Type = D3D12_COMMAND_LIST_TYPE_COMPUTE;
            if (FAILED(h = dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&comp)))) return fail(err, "CreateCommandQueue(compute)", h);
            comp->SetName(L"pwgpu async compute");
        }
        // Root signature.
        D3D12_DESCRIPTOR_RANGE ranges[2] = {};
        ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; ranges[0].NumDescriptors = kSrvSlots; ranges[0].BaseShaderRegister = 0;
        ranges[0].OffsetInDescriptorsFromTableStart = 0;
        ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV; ranges[1].NumDescriptors = kUavSlots; ranges[1].BaseShaderRegister = 8;
        ranges[1].OffsetInDescriptorsFromTableStart = 0;
        D3D12_ROOT_PARAMETER rp[6] = {};
        for (int i = 0; i < 4; ++i) {
            rp[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
            rp[i].Descriptor.ShaderRegister = UINT(i);
            rp[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        }
        rp[4].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        rp[4].DescriptorTable.NumDescriptorRanges = 1; rp[4].DescriptorTable.pDescriptorRanges = &ranges[0];
        rp[4].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        rp[5].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        rp[5].DescriptorTable.NumDescriptorRanges = 1; rp[5].DescriptorTable.pDescriptorRanges = &ranges[1];
        rp[5].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_STATIC_SAMPLER_DESC ss[4] = {};
        for (int i = 0; i < 4; ++i) {
            ss[i].Filter = i == 0 ? D3D12_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT : i == 3 ? D3D12_FILTER_MIN_MAG_MIP_POINT : D3D12_FILTER_MIN_MAG_LINEAR_MIP_POINT;
            ss[i].AddressU = i == 2 ? D3D12_TEXTURE_ADDRESS_MODE_WRAP : D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
            ss[i].AddressV = ss[i].AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
            ss[i].ComparisonFunc = i == 0 ? D3D12_COMPARISON_FUNC_LESS_EQUAL : D3D12_COMPARISON_FUNC_NEVER;
            ss[i].MaxLOD = D3D12_FLOAT32_MAX;
            ss[i].ShaderRegister = UINT(i);
            ss[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        }
        D3D12_ROOT_SIGNATURE_DESC rsd = {};
        rsd.NumParameters = 6; rsd.pParameters = rp; rsd.NumStaticSamplers = 4; rsd.pStaticSamplers = ss;
        ComPtr<ID3DBlob> sig, errBlob;
        if (FAILED(h = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &errBlob)))
            return fail(err, std::string("SerializeRootSignature: ") + (errBlob ? static_cast<const char*>(errBlob->GetBufferPointer()) : ""), h);
        if (FAILED(h = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&root)))) return fail(err, "CreateRootSignature", h);
        // Descriptor heaps.
        if (!staging.init(dev.Get(), D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, kStagingDescriptors) ||
            !rtvPool.init(dev.Get(), D3D12_DESCRIPTOR_HEAP_TYPE_RTV, kRtvDescriptors) || !dsvPool.init(dev.Get(), D3D12_DESCRIPTOR_HEAP_TYPE_DSV, kDsvDescriptors)) {
            if (err) *err = "CreateDescriptorHeap";
            return false;
        }
        D3D12_DESCRIPTOR_HEAP_DESC hd = {};
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; hd.NumDescriptors = kRingDescriptors * kFramesInFlight; hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        if (FAILED(h = dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&ringHeap)))) return fail(err, "CreateDescriptorHeap(shader visible)", h);
        ringInc = dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        nullSrv = staging.alloc();
        D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
        sv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sv.Texture2D.MipLevels = 1;
        dev->CreateShaderResourceView(nullptr, &sv, nullSrv);
        nullUav = staging.alloc();
        D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {};
        uv.Format = DXGI_FORMAT_R8G8B8A8_UNORM; uv.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        dev->CreateUnorderedAccessView(nullptr, nullptr, &uv, nullUav);
        // Upload rings.
        for (int s = 0; s < kFramesInFlight; ++s) {
            BufferDesc bd; bd.size = kRingSize; bd.kind = BufferKind::Upload; bd.label = "pwgpu upload ring";
            auto b = createBufferImpl(bd);
            if (!b) { if (err) *err = "upload ring"; return false; }
            rings[s].buf = b->res; rings[s].cpu = static_cast<uint8_t*>(b->mapped);
            rings[s].wrapper = std::move(b);
        }
        // Fences.
        if (FAILED(h = dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gfxFence)))) return fail(err, "CreateFence", h);
        if (FAILED(h = dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&compFence)))) return fail(err, "CreateFence", h);
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        // Timestamps.
        D3D12_QUERY_HEAP_DESC qh = {};
        qh.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP; qh.Count = UINT(kFramesInFlight * kMaxTimers * 2);
        if (FAILED(dev->CreateQueryHeap(&qh, IID_PPV_ARGS(&queryHeap)))) c.timestamps = false;
        if (c.timestamps) {
            BufferDesc bd; bd.size = std::size_t(qh.Count) * 8; bd.kind = BufferKind::Readback; bd.label = "timestamps";
            auto b = createBufferImpl(bd);
            if (!b) c.timestamps = false;
            else { queryReadback = b->res; queryCpu = static_cast<uint64_t*>(b->mapped); }
            if (FAILED(gfx->GetTimestampFrequency(&freqGfx)) || freqGfx == 0) c.timestamps = false;
            if (FAILED(comp->GetTimestampFrequency(&freqComp)) || freqComp == 0) freqComp = freqGfx;
        }
        return event != nullptr;
    }

    std::unique_ptr<D3D12Buffer> createBufferImpl(const BufferDesc& bd) {
        D3D12_HEAP_PROPERTIES hp = {};
        hp.Type = bd.kind == BufferKind::Upload ? D3D12_HEAP_TYPE_UPLOAD : bd.kind == BufferKind::Readback ? D3D12_HEAP_TYPE_READBACK : D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; rd.Width = std::max<UINT64>(bd.size, 256); rd.Height = 1; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.SampleDesc.Count = 1; rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        D3D12_RESOURCE_STATES st = bd.kind == BufferKind::Upload ? D3D12_RESOURCE_STATE_GENERIC_READ : bd.kind == BufferKind::Readback ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COMMON;
        auto b = std::make_unique<D3D12Buffer>(bd);
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, st, nullptr, IID_PPV_ARGS(&b->res)))) return nullptr;
        b->res->SetName(widen(bd.label).c_str());
        if (bd.kind != BufferKind::Device) {
            D3D12_RANGE r = {0, 0};
            if (FAILED(b->res->Map(0, bd.kind == BufferKind::Readback ? nullptr : &r, &b->mapped))) return nullptr;
        }
        return b;
    }

    std::unique_ptr<Texture> createTexture(const TextureDesc& td) override {
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = td.type == TextureType::Tex3D ? D3D12_RESOURCE_DIMENSION_TEXTURE3D : D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = UINT64(td.width); rd.Height = UINT(td.height); rd.DepthOrArraySize = UINT16(td.depthOrLayers); rd.MipLevels = UINT16(td.mips);
        rd.Format = td.format == Format::D32F ? DXGI_FORMAT_R32_TYPELESS : dxFormat(td.format);
        rd.SampleDesc.Count = 1;
        rd.Flags = D3D12_RESOURCE_FLAG_NONE;
        if (td.usage & TexStorage) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        if (td.usage & TexRenderTarget) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (td.usage & TexDepthTarget) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
        bool simultaneous = (td.usage & TexCrossQueue) && td.format != Format::D32F;
        if (simultaneous) rd.Flags |= D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS;
        auto t = std::make_unique<D3D12Texture>(td);
        t->owner = this;
        t->simultaneous = simultaneous;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&t->res)))) return nullptr;
        t->res->SetName(widen(td.label).c_str());
        int layers = td.type == TextureType::Tex2DArray ? td.depthOrLayers : 1;
        t->states.assign(std::size_t(td.mips) * layers, D3D12_RESOURCE_STATE_COMMON);
        return t;
    }
    std::unique_ptr<Buffer> createBuffer(const BufferDesc& bd) override { return createBufferImpl(bd); }
    std::unique_ptr<Buffer> createBufferWithData(const void* data, std::size_t size, bool index, const char* label) override {
        BufferDesc bd; bd.size = size; bd.kind = BufferKind::Device; bd.index = index; bd.label = label;
        auto b = createBufferImpl(bd);
        if (!b) return nullptr;
        BufferDesc ud; ud.size = size; ud.kind = BufferKind::Upload; ud.label = "staging";
        auto up = createBufferImpl(ud);
        if (!up) return nullptr;
        std::memcpy(up->mapped, data, size);
        CommandList* cl = beginCommandList(QueueType::Graphics);
        cl->copyBuffer(up.get(), 0, b.get(), 0, size);
        submit(cl, {});
        waitQueue(gfx.Get(), gfxFence.Get(), gfxValue);
        return b;
    }

    // ---- views
    D3D12_CPU_DESCRIPTOR_HANDLE srv(D3D12Texture* t, const TextureView& v) {
        int mips = v.mipCount < 0 ? t->mipCount() - v.mip : v.mipCount;
        int layers = t->desc().type == TextureType::Tex2DArray ? t->desc().depthOrLayers : 1;
        int lays = v.layerCount < 0 ? layers - v.layer : v.layerCount;
        auto key = std::make_tuple(v.mip, mips, v.layer, lays);
        auto it = t->srvs.find(key);
        if (it != t->srvs.end()) return it->second;
        D3D12_SHADER_RESOURCE_VIEW_DESC d = {};
        d.Format = t->desc().format == Format::D32F ? DXGI_FORMAT_R32_FLOAT : dxFormat(t->desc().format);
        d.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        switch (t->desc().type) {
            case TextureType::Tex2D: d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; d.Texture2D.MostDetailedMip = UINT(v.mip); d.Texture2D.MipLevels = UINT(mips); break;
            case TextureType::Tex2DArray:
                d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MostDetailedMip = UINT(v.mip); d.Texture2DArray.MipLevels = UINT(mips);
                d.Texture2DArray.FirstArraySlice = UINT(v.layer); d.Texture2DArray.ArraySize = UINT(lays); break;
            case TextureType::Tex3D: d.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; d.Texture3D.MostDetailedMip = UINT(v.mip); d.Texture3D.MipLevels = UINT(mips); break;
        }
        D3D12_CPU_DESCRIPTOR_HANDLE h = staging.alloc();
        dev->CreateShaderResourceView(t->res.Get(), &d, h);
        t->srvs[key] = h;
        return h;
    }
    D3D12_CPU_DESCRIPTOR_HANDLE uav(D3D12Texture* t, int mip) {
        auto it = t->uavs.find(mip);
        if (it != t->uavs.end()) return it->second;
        D3D12_UNORDERED_ACCESS_VIEW_DESC d = {};
        d.Format = dxFormat(t->desc().format);
        switch (t->desc().type) {
            case TextureType::Tex2D: d.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice = UINT(mip); break;
            case TextureType::Tex2DArray:
                d.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice = UINT(mip);
                d.Texture2DArray.ArraySize = UINT(t->desc().depthOrLayers); break;
            case TextureType::Tex3D: d.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE3D; d.Texture3D.MipSlice = UINT(mip); d.Texture3D.WSize = UINT(t->depth(mip)); break;
        }
        D3D12_CPU_DESCRIPTOR_HANDLE h = staging.alloc();
        dev->CreateUnorderedAccessView(t->res.Get(), nullptr, &d, h);
        t->uavs[mip] = h;
        return h;
    }
    D3D12_CPU_DESCRIPTOR_HANDLE rtv(D3D12Texture* t, int mip, int layer) {
        auto key = std::make_pair(mip, layer);
        auto it = t->rtvs.find(key);
        if (it != t->rtvs.end()) return it->second;
        D3D12_RENDER_TARGET_VIEW_DESC d = {};
        d.Format = dxFormat(t->desc().format);
        if (t->desc().type == TextureType::Tex2DArray) {
            d.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice = UINT(mip); d.Texture2DArray.FirstArraySlice = UINT(layer); d.Texture2DArray.ArraySize = 1;
        } else {
            d.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice = UINT(mip);
        }
        D3D12_CPU_DESCRIPTOR_HANDLE h = rtvPool.alloc();
        dev->CreateRenderTargetView(t->res.Get(), &d, h);
        t->rtvs[key] = h;
        return h;
    }
    D3D12_CPU_DESCRIPTOR_HANDLE dsv(D3D12Texture* t, int mip, int layer) {
        auto key = std::make_pair(mip, layer);
        auto it = t->dsvs.find(key);
        if (it != t->dsvs.end()) return it->second;
        D3D12_DEPTH_STENCIL_VIEW_DESC d = {};
        d.Format = DXGI_FORMAT_D32_FLOAT;
        if (t->desc().type == TextureType::Tex2DArray) {
            d.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2DARRAY; d.Texture2DArray.MipSlice = UINT(mip); d.Texture2DArray.FirstArraySlice = UINT(layer); d.Texture2DArray.ArraySize = 1;
        } else {
            d.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D; d.Texture2D.MipSlice = UINT(mip);
        }
        D3D12_CPU_DESCRIPTOR_HANDLE h = dsvPool.alloc();
        dev->CreateDepthStencilView(t->res.Get(), &d, h);
        t->dsvs[key] = h;
        return h;
    }
    void releaseViews(D3D12Texture* t) {
        for (auto& [k, h] : t->srvs) staging.release(h);
        for (auto& [k, h] : t->uavs) staging.release(h);
        for (auto& [k, h] : t->rtvs) rtvPool.release(h);
        for (auto& [k, h] : t->dsvs) dsvPool.release(h);
    }
    /// Allocates n contiguous shader-visible descriptors from this frame's ring.
    bool ringAlloc(UINT n, D3D12_CPU_DESCRIPTOR_HANDLE& cpu, D3D12_GPU_DESCRIPTOR_HANDLE& gpuH) {
        if (ringCursor + n > kRingDescriptors) ringCursor = 0;   // wrap within the slot (only if a frame exceeds 32k descriptors)
        UINT index = UINT(slot) * kRingDescriptors + ringCursor;
        ringCursor += n;
        cpu = {ringHeap->GetCPUDescriptorHandleForHeapStart().ptr + SIZE_T(index) * ringInc};
        gpuH = {ringHeap->GetGPUDescriptorHandleForHeapStart().ptr + UINT64(index) * ringInc};
        return true;
    }

    // ---- pipelines
    bool shader(const char* file, const char* entry, D3D12_SHADER_BYTECODE& bc, std::string* err) {
        std::string key = std::string(file) + "." + entry;
        const shaders::Blob* b = shaders::find(key.c_str());
        if (!b) { if (err) *err = "DXIL blob missing: " + key; return false; }
        bc = {b->data, b->size};
        return true;
    }
    std::unique_ptr<Pipeline> createPipeline(const GraphicsPipelineDesc& gd, std::string* err) override {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = root.Get();
        if (!shader(gd.shader, gd.vertex, pd.VS, err)) return nullptr;
        if (gd.fragment && !shader(gd.shader, gd.fragment, pd.PS, err)) return nullptr;
        for (int i = 0; i < gd.colorCount; ++i) {
            auto& rt = pd.BlendState.RenderTarget[i];
            rt.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
            rt.SrcBlend = D3D12_BLEND_ONE; rt.DestBlend = D3D12_BLEND_ZERO; rt.BlendOp = D3D12_BLEND_OP_ADD;
            rt.SrcBlendAlpha = D3D12_BLEND_ONE; rt.DestBlendAlpha = D3D12_BLEND_ZERO; rt.BlendOpAlpha = D3D12_BLEND_OP_ADD;
            rt.LogicOp = D3D12_LOGIC_OP_NOOP;
            if (gd.blend == BlendMode::Alpha) {
                rt.BlendEnable = TRUE;
                rt.SrcBlend = D3D12_BLEND_SRC_ALPHA; rt.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
                rt.SrcBlendAlpha = D3D12_BLEND_ONE; rt.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
            }
            pd.RTVFormats[i] = dxFormat(gd.color[i]);
        }
        pd.NumRenderTargets = UINT(gd.colorCount);
        pd.SampleMask = UINT_MAX;
        pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode = gd.cull == CullMode::Back ? D3D12_CULL_MODE_BACK : gd.cull == CullMode::Front ? D3D12_CULL_MODE_FRONT : D3D12_CULL_MODE_NONE;
        pd.RasterizerState.FrontCounterClockwise = gd.frontCCW ? TRUE : FALSE;
        pd.RasterizerState.DepthBias = INT(gd.depthBias);
        pd.RasterizerState.SlopeScaledDepthBias = gd.depthBiasSlope;
        pd.RasterizerState.DepthBiasClamp = gd.depthBiasClamp;
        pd.RasterizerState.DepthClipEnable = TRUE;
        if (gd.depth != Format::Unknown) {
            pd.DepthStencilState.DepthEnable = TRUE;
            pd.DepthStencilState.DepthWriteMask = gd.depthWrite ? D3D12_DEPTH_WRITE_MASK_ALL : D3D12_DEPTH_WRITE_MASK_ZERO;
            pd.DepthStencilState.DepthFunc = dxCompare(gd.depthCompare);
            pd.DSVFormat = DXGI_FORMAT_D32_FLOAT;
        }
        pd.PrimitiveTopologyType = gd.topology == Topology::Lines ? D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE : D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.SampleDesc.Count = 1;
        auto p = std::make_unique<D3D12Pipeline>();
        HRESULT h = dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&p->pso));
        if (FAILED(h)) { if (err) *err = std::string("CreateGraphicsPipelineState ") + gd.shader + "." + gd.vertex + " (" + hrs(h) + ")"; return nullptr; }
        if (gd.label) p->pso->SetName(widen(gd.label).c_str());
        p->topology = gd.topology == Topology::Lines ? D3D_PRIMITIVE_TOPOLOGY_LINELIST : D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
        return p;
    }
    std::unique_ptr<Pipeline> createPipeline(const ComputePipelineDesc& cd, std::string* err) override {
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = root.Get();
        if (!shader(cd.shader, cd.entry, pd.CS, err)) return nullptr;
        auto p = std::make_unique<D3D12Pipeline>();
        HRESULT h = dev->CreateComputePipelineState(&pd, IID_PPV_ARGS(&p->pso));
        if (FAILED(h)) { if (err) *err = std::string("CreateComputePipelineState ") + cd.shader + "." + cd.entry + " (" + hrs(h) + ")"; return nullptr; }
        if (cd.label) p->pso->SetName(widen(cd.label).c_str());
        p->setCompute(cd.groupSize);
        return p;
    }
    std::unique_ptr<Fence> createFence() override {
        auto f = std::make_unique<D3D12Fence>();
        if (FAILED(dev->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&f->fence)))) return nullptr;
        f->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        return f;
    }

    // ---- frames + submission
    void waitValue(ID3D12Fence* f, uint64_t v) {
        if (f->GetCompletedValue() >= v) return;
        f->SetEventOnCompletion(v, event);
        WaitForSingleObject(event, INFINITE);
    }
    void waitQueue(ID3D12CommandQueue* q, ID3D12Fence* f, uint64_t& counter) {
        q->Signal(f, ++counter);
        waitValue(f, counter);
    }
    void resolveTimers(int s) {
        if (!c.timestamps || !timerMask[s]) { timerMask[s] = 0; timerCompute[s] = 0; return; }
        timers.clear();
        uint64_t lo = UINT64_MAX, hi = 0;
        for (int i = 0; i < kMaxTimers; ++i) {
            if (!(timerMask[s] & (1u << i))) continue;
            const uint64_t* q = queryCpu + (std::size_t(s) * kMaxTimers + i) * 2;
            uint64_t a = q[0], b = q[1];
            if (b < a) continue;
            double freq = double((timerCompute[s] & (1u << i)) ? freqComp : freqGfx);
            timers.push_back({timerNames[i].empty() ? "timer" + std::to_string(i) : timerNames[i], double(b - a) * 1000.0 / freq});
            if (!(timerCompute[s] & (1u << i))) { lo = std::min(lo, a); hi = std::max(hi, b); }
        }
        if (hi > lo) frameGpuMs = double(hi - lo) * 1000.0 / double(freqGfx);
        timerMask[s] = 0; timerCompute[s] = 0;
    }
    int beginFrame() override {
        slot = int(frame % kFramesInFlight);
        waitValue(gfxFence.Get(), slotGfx[slot]);
        waitValue(compFence.Get(), slotComp[slot]);
        resolveTimers(slot);
        rings[slot].off = 0;
        rings[slot].overflow.clear();
        ringCursor = 0;
        cursor[0] = cursor[1] = 0;
        inFrame = true;
        return slot;
    }
    void endFrame() override {
        gfx->Signal(gfxFence.Get(), ++gfxValue); slotGfx[slot] = gfxValue;
        comp->Signal(compFence.Get(), ++compValue); slotComp[slot] = compValue;
        inFrame = false;
        ++frame;
    }
    CommandList* beginCommandList(QueueType q) override {
        int qi = q == QueueType::Compute ? 1 : 0;
        if (cursor[qi] >= lists[qi].size()) {
            auto l = std::make_unique<D3D12CommandList>();
            l->dev = this;
            if (!l->create(dev.Get(), q)) return nullptr;
            lists[qi].push_back(std::move(l));
        }
        D3D12CommandList* l = lists[qi][cursor[qi]++].get();
        l->begin(slot, ++epochCounter);
        return l;
    }
    void submit(CommandList* cl, const SubmitInfo& si) override {
        auto* l = static_cast<D3D12CommandList*>(cl);
        if (l->inRender) l->endRenderPass();
        if (l->inCompute) l->endComputePass();
        l->flushBarriers();
        if (c.timestamps && !l->timersUsed.empty()) {
            for (int t : l->timersUsed) {
                UINT base = UINT((slot * kMaxTimers + t) * 2);
                l->list->ResolveQueryData(queryHeap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, base, 2, queryReadback.Get(), UINT64(base) * 8);
            }
        }
        l->list->Close();
        ID3D12CommandQueue* q = l->queue() == QueueType::Compute ? comp.Get() : gfx.Get();
        if (si.waitFence) q->Wait(static_cast<D3D12Fence*>(si.waitFence)->fence.Get(), si.waitValue);
        ID3D12CommandList* lists1[] = {l->list.Get()};
        q->ExecuteCommandLists(1, lists1);
        if (si.signalFence) q->Signal(static_cast<D3D12Fence*>(si.signalFence)->fence.Get(), si.signalValue);
        if (!inFrame) {
            // Outside a frame the list's allocator may be reused right away: finish the work now.
            if (l->queue() == QueueType::Compute) waitQueue(comp.Get(), compFence.Get(), compValue);
            else waitQueue(gfx.Get(), gfxFence.Get(), gfxValue);
            int qi = l->queue() == QueueType::Compute ? 1 : 0;
            if (cursor[qi] > 0 && lists[qi][cursor[qi] - 1].get() == l) --cursor[qi];
        }
    }
    void waitIdle() override {
        waitQueue(gfx.Get(), gfxFence.Get(), gfxValue);
        waitQueue(comp.Get(), compFence.Get(), compValue);
    }
    std::vector<std::unique_ptr<D3D12Buffer>> ringWrappers[kFramesInFlight];
    void* allocTransient(std::size_t size, Buffer** buffer, std::size_t* offset) override {
        Ring& r = rings[slot];
        std::size_t aligned = (r.off + 255) & ~std::size_t(255);
        if (aligned + size > kRingSize) {
            BufferDesc bd; bd.size = size; bd.kind = BufferKind::Upload; bd.label = "upload overflow";
            auto b = createBufferImpl(bd);
            if (!b) return nullptr;
            void* p = b->mapped;
            if (buffer) *buffer = b.get();
            if (offset) *offset = 0;
            r.overflow.push_back(std::move(b));
            return p;
        }
        r.off = aligned + size;
        if (buffer) *buffer = r.wrapper.get();
        if (offset) *offset = aligned;
        return r.cpu + aligned;
    }
};

D3D12Texture::~D3D12Texture() { if (owner) owner->releaseViews(this); }

void D3D12CommandList::begin(int slot, uint64_t ep) {
    epoch = ep;
    alloc[slot]->Reset();
    list->Reset(alloc[slot].Get(), nullptr);
    ID3D12DescriptorHeap* heaps[] = {dev->ringHeap.Get()};
    list->SetDescriptorHeaps(1, heaps);
    if (q == QueueType::Graphics) list->SetGraphicsRootSignature(dev->root.Get());
    list->SetComputeRootSignature(dev->root.Get());
    resetBindings();
    inRender = inCompute = uavPending = false;
    timersUsed.clear();
    barriers.clear();
}

void D3D12CommandList::setPipeline(Pipeline* p) {
    pso = static_cast<D3D12Pipeline*>(p);
    if (!pso) return;
    list->SetPipelineState(pso->pso.Get());
    if (!pso->isCompute()) list->IASetPrimitiveTopology(pso->topology);
    cbDirty = tablesDirty = true;
}

void D3D12CommandList::setConstants(int slot, const void* data, std::size_t size) {
    if (slot < 0 || slot >= 4) return;
    Buffer* b = nullptr; std::size_t off = 0;
    void* p = dev->allocTransient(size, &b, &off);
    if (!p) return;
    std::memcpy(p, data, size);
    cbs[slot] = static_cast<D3D12Buffer*>(b)->gpu() + off;
    cbDirty = true;
}

void D3D12CommandList::flush(bool graphics) {
    const D3D12_RESOURCE_STATES srvState = graphics && q == QueueType::Graphics ? kSrvGraphics : kSrvCompute;
    // Transitions for everything bound (also when the tables are unchanged: another pass may have moved a texture).
    for (auto& v : srvTex) if (v.texture) transition(static_cast<D3D12Texture*>(v.texture), v.mip, v.mipCount, v.layer, v.layerCount, srvState);
    bool anyUav = false;
    for (auto& v : uavTex) if (v.texture) { transition(static_cast<D3D12Texture*>(v.texture), v.mip, 1, 0, -1, D3D12_RESOURCE_STATE_UNORDERED_ACCESS); anyUav = true; }
    if (anyUav && uavPending) {
        D3D12_RESOURCE_BARRIER u = {};
        u.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV; u.UAV.pResource = nullptr;
        barriers.push_back(u);
        uavPending = false;
    }
    flushBarriers();
    if (cbDirty) {
        for (int i = 0; i < 4; ++i) {
            if (!cbs[i]) continue;
            if (graphics) list->SetGraphicsRootConstantBufferView(UINT(i), cbs[i]);
            else list->SetComputeRootConstantBufferView(UINT(i), cbs[i]);
        }
        cbDirty = false;
    }
    if (tablesDirty) {
        ID3D12Device* d = dev->dev.Get();
        D3D12_CPU_DESCRIPTOR_HANDLE cpu; D3D12_GPU_DESCRIPTOR_HANDLE gpuH;
        dev->ringAlloc(kSrvSlots + kUavSlots, cpu, gpuH);
        const UINT inc = dev->ringInc;
        for (int i = 0; i < 8; ++i) {
            D3D12_CPU_DESCRIPTOR_HANDLE dst = {cpu.ptr + SIZE_T(i) * inc};
            D3D12_CPU_DESCRIPTOR_HANDLE src = srvTex[i].texture ? dev->srv(static_cast<D3D12Texture*>(srvTex[i].texture), srvTex[i]) : dev->nullSrv;
            d->CopyDescriptorsSimple(1, dst, src, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        for (int i = 0; i < 4; ++i) {
            D3D12_CPU_DESCRIPTOR_HANDLE dst = {cpu.ptr + SIZE_T(8 + i) * inc};
            if (sbs[i].buf) {
                D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
                sv.Format = DXGI_FORMAT_UNKNOWN; sv.ViewDimension = D3D12_SRV_DIMENSION_BUFFER; sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                sv.Buffer.FirstElement = UINT64(sbs[i].off / 16);
                sv.Buffer.NumElements = UINT((sbs[i].buf->size() - sbs[i].off) / 16);
                sv.Buffer.StructureByteStride = 16;
                d->CreateShaderResourceView(sbs[i].buf->res.Get(), &sv, dst);
            } else {
                d->CopyDescriptorsSimple(1, dst, dev->nullSrv, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
            }
        }
        for (int i = 0; i < 4; ++i) {
            D3D12_CPU_DESCRIPTOR_HANDLE dst = {cpu.ptr + SIZE_T(kSrvSlots + i) * inc};
            D3D12_CPU_DESCRIPTOR_HANDLE src = uavTex[i].texture ? dev->uav(static_cast<D3D12Texture*>(uavTex[i].texture), uavTex[i].mip) : dev->nullUav;
            d->CopyDescriptorsSimple(1, dst, src, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        D3D12_GPU_DESCRIPTOR_HANDLE uavTable = {gpuH.ptr + UINT64(kSrvSlots) * inc};
        if (graphics) { list->SetGraphicsRootDescriptorTable(4, gpuH); list->SetGraphicsRootDescriptorTable(5, uavTable); }
        else { list->SetComputeRootDescriptorTable(4, gpuH); list->SetComputeRootDescriptorTable(5, uavTable); }
        tablesDirty = false;
    }
}

void D3D12CommandList::beginRenderPass(const RenderPassDesc& rp) {
    if (inRender) endRenderPass();
    if (inCompute) endComputePass();
    resetBindings();
    D3D12_CPU_DESCRIPTOR_HANDLE rtvs[kMaxColorTargets];
    rtW = rtH = 0;
    colorCount = rp.colorCount;
    for (int i = 0; i < rp.colorCount; ++i) {
        auto* t = static_cast<D3D12Texture*>(rp.color[i].view.texture);
        colorViews[i] = rp.color[i].view;
        transition(t, rp.color[i].view.mip, 1, rp.color[i].view.layer, 1, D3D12_RESOURCE_STATE_RENDER_TARGET);
        rtvs[i] = dev->rtv(t, rp.color[i].view.mip, rp.color[i].view.layer);
        rtW = t->width(rp.color[i].view.mip); rtH = t->height(rp.color[i].view.mip);
    }
    D3D12_CPU_DESCRIPTOR_HANDLE dsvH = {};
    depthView = rp.depth.view;
    if (rp.depth.view.texture) {
        auto* t = static_cast<D3D12Texture*>(rp.depth.view.texture);
        transition(t, rp.depth.view.mip, 1, rp.depth.view.layer, 1, D3D12_RESOURCE_STATE_DEPTH_WRITE);
        dsvH = dev->dsv(t, rp.depth.view.mip, rp.depth.view.layer);
        if (!rtW) { rtW = t->width(rp.depth.view.mip); rtH = t->height(rp.depth.view.mip); }
    }
    flushBarriers();
    passTimer = rp.timer >= 0 && rp.timer < kMaxTimers && dev->caps().timestamps ? rp.timer : -1;
    if (passTimer >= 0) {
        list->EndQuery(dev->queryHeap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, UINT((dev->frameSlot() * kMaxTimers + passTimer) * 2));
        timersUsed.push_back(passTimer);
        dev->timerMask[dev->frameSlot()] |= 1u << passTimer;
    }
    list->OMSetRenderTargets(UINT(rp.colorCount), rp.colorCount ? rtvs : nullptr, FALSE, rp.depth.view.texture ? &dsvH : nullptr);
    for (int i = 0; i < rp.colorCount; ++i)
        if (rp.color[i].load == LoadOp::Clear) list->ClearRenderTargetView(rtvs[i], rp.color[i].clear, 0, nullptr);
    if (rp.depth.view.texture && rp.depth.load == LoadOp::Clear) list->ClearDepthStencilView(dsvH, D3D12_CLEAR_FLAG_DEPTH, rp.depth.clear, 0, 0, nullptr);
    setViewport(0, 0, rtW, rtH);
    inRender = true;
}

void D3D12CommandList::endRenderPass() {
    if (!inRender) return;
    if (passTimer >= 0) list->EndQuery(dev->queryHeap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, UINT((dev->frameSlot() * kMaxTimers + passTimer) * 2 + 1));
    passTimer = -1;
    inRender = false;
    resetBindings();
}

void D3D12CommandList::beginComputePass(const char*, int timer) {
    if (inRender) endRenderPass();
    if (inCompute) endComputePass();
    resetBindings();
    passTimer = timer >= 0 && timer < kMaxTimers && dev->caps().timestamps ? timer : -1;
    if (passTimer >= 0) {
        list->EndQuery(dev->queryHeap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, UINT((dev->frameSlot() * kMaxTimers + passTimer) * 2));
        timersUsed.push_back(passTimer);
        dev->timerMask[dev->frameSlot()] |= 1u << passTimer;
        if (q == QueueType::Compute) dev->timerCompute[dev->frameSlot()] |= 1u << passTimer;
    }
    inCompute = true;
}

void D3D12CommandList::endComputePass() {
    if (!inCompute) return;
    if (passTimer >= 0) list->EndQuery(dev->queryHeap.Get(), D3D12_QUERY_TYPE_TIMESTAMP, UINT((dev->frameSlot() * kMaxTimers + passTimer) * 2 + 1));
    passTimer = -1;
    inCompute = false;
    resetBindings();
}

void D3D12CommandList::copyTextureToBuffer(const TextureView& v, Buffer* dst, std::size_t offset) {
    auto* t = static_cast<D3D12Texture*>(v.texture);
    transition(t, v.mip, 1, v.layer, 1, D3D12_RESOURCE_STATE_COPY_SOURCE);
    flushBarriers();
    D3D12_TEXTURE_COPY_LOCATION d = {};
    d.pResource = static_cast<D3D12Buffer*>(dst)->res.Get(); d.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    d.PlacedFootprint.Offset = offset;
    d.PlacedFootprint.Footprint.Format = t->desc().format == Format::D32F ? DXGI_FORMAT_R32_FLOAT : dxFormat(t->desc().format);
    d.PlacedFootprint.Footprint.Width = UINT(t->width(v.mip)); d.PlacedFootprint.Footprint.Height = UINT(t->height(v.mip));
    d.PlacedFootprint.Footprint.Depth = UINT(t->depth(v.mip));
    d.PlacedFootprint.Footprint.RowPitch = UINT(copyRowPitch(t->width(v.mip), t->desc().format));
    D3D12_TEXTURE_COPY_LOCATION s = {};
    s.pResource = t->res.Get(); s.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; s.SubresourceIndex = t->sub(v.mip, v.layer);
    list->CopyTextureRegion(&d, 0, 0, 0, &s, nullptr);
}

void D3D12CommandList::copyBufferToTexture(Buffer* src, std::size_t offset, const TextureView& v) {
    auto* t = static_cast<D3D12Texture*>(v.texture);
    transition(t, v.mip, 1, v.layer, 1, D3D12_RESOURCE_STATE_COPY_DEST);
    flushBarriers();
    D3D12_TEXTURE_COPY_LOCATION s = {};
    s.pResource = static_cast<D3D12Buffer*>(src)->res.Get(); s.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    s.PlacedFootprint.Offset = offset;
    s.PlacedFootprint.Footprint.Format = dxFormat(t->desc().format);
    s.PlacedFootprint.Footprint.Width = UINT(t->width(v.mip)); s.PlacedFootprint.Footprint.Height = UINT(t->height(v.mip));
    s.PlacedFootprint.Footprint.Depth = UINT(t->depth(v.mip));
    s.PlacedFootprint.Footprint.RowPitch = UINT(copyRowPitch(t->width(v.mip), t->desc().format));
    D3D12_TEXTURE_COPY_LOCATION d = {};
    d.pResource = t->res.Get(); d.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; d.SubresourceIndex = t->sub(v.mip, v.layer);
    list->CopyTextureRegion(&d, 0, 0, 0, &s, nullptr);
}

} // namespace

std::unique_ptr<Device> createD3D12Device(const CreateInfo& ci, std::string* err) {
    auto d = std::make_unique<D3D12Device>();
    if (!d->init(ci, err)) return nullptr;
    return d;
}
} // namespace pw::gpu
