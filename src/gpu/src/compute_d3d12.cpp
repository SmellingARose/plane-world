// pwgpu compute on Direct3D 12. See pw/compute.h for the binding model: one root signature for every kernel,
// [0] = 32 root constants (b0), [1..8] = root UAVs (u1..u8). Buffers live in the DEFAULT heap (implicit state
// promotion/decay between submissions); upload/download go through persistent (grow-only) UPLOAD/READBACK staging buffers.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "pw/compute.h"

using Microsoft::WRL::ComPtr;

namespace pw::gpu {
namespace {
std::string narrowW(const wchar_t* w) { std::string s; for (; *w; ++w) s += (*w < 128) ? char(*w) : '?'; return s; }
std::string hrs(HRESULT h) { char b[32]; snprintf(b, sizeof b, "0x%08lx", (unsigned long)h); return b; }

D3D12_HEAP_PROPERTIES heap(D3D12_HEAP_TYPE t) { D3D12_HEAP_PROPERTIES p = {}; p.Type = t; return p; }
D3D12_RESOURCE_DESC bufferDesc(UINT64 bytes, D3D12_RESOURCE_FLAGS flags) {
    D3D12_RESOURCE_DESC d = {};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; d.Width = bytes; d.Height = 1; d.DepthOrArraySize = 1; d.MipLevels = 1;
    d.SampleDesc.Count = 1; d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; d.Flags = flags;
    return d;
}

class D3D12Compute final : public ComputeContext {
public:
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12CommandAllocator> alloc;
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12QueryHeap> timestamps;
    ComPtr<ID3D12Resource> tsReadback;
    HANDLE event = nullptr;
    UINT64 fenceValue = 0, pending = 0;
    std::string adapter, err;
    bool software = false, recording = false, tsPending = false;
    double lastMs = -1;
    struct Buf { ComPtr<ID3D12Resource> res; std::size_t size = 0; };
    std::vector<Buf> buffers{Buf{}};
    std::vector<ComPtr<ID3D12PipelineState>> kernels{nullptr};

    ~D3D12Compute() override { if (dev) waitIdle(); if (event) CloseHandle(event); }
    Backend backend() const override { return Backend::D3D12; }
    std::string adapterName() const override { return adapter; }
    bool isSoftware() const override { return software; }
    const std::string& lastError() const override { return err; }
    bool fail(std::string* e, const std::string& m, HRESULT h) { if (e) *e = m + " (" + hrs(h) + ")"; return false; }

    bool init(const CreateInfo& ci, std::string* e) {
        HRESULT h;
        ComPtr<IDXGIFactory4> factory;
        if (ci.externalDevice) {
            dev = static_cast<ID3D12Device*>(ci.externalDevice);
            if (ci.externalQueue) queue = static_cast<ID3D12CommandQueue*>(ci.externalQueue);
            adapter = "shared device";
        } else {
            if (FAILED(h = CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return fail(e, "CreateDXGIFactory1", h);
            const char* warpEnv = std::getenv("PW_GPU_WARP");
            bool preferSoftware = ci.preferSoftware || (warpEnv && *warpEnv && *warpEnv != '0');
            ComPtr<IDXGIAdapter1> chosen;
            if (!preferSoftware) {
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
                if (FAILED(h = factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)))) return fail(e, "EnumWarpAdapter", h);
                warp.As(&chosen);
            }
            DXGI_ADAPTER_DESC1 d; chosen->GetDesc1(&d);
            adapter = narrowW(d.Description);
            // EnumWarpAdapter's adapter does not always carry the SOFTWARE flag: also match Microsoft Basic Render (WARP)
            software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 || (d.VendorId == 0x1414 && d.DeviceId == 0x8c);
            if (FAILED(h = D3D12CreateDevice(chosen.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)))) return fail(e, "D3D12CreateDevice", h);
        }
        if (!queue) {
            D3D12_COMMAND_QUEUE_DESC qd = {};
            qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
            if (FAILED(h = dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) return fail(e, "CreateCommandQueue", h);
        }
        D3D12_ROOT_PARAMETER params[1 + kMaxBuffers] = {};
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[0].Constants.ShaderRegister = 0; params[0].Constants.Num32BitValues = UINT(kMaxConstantBytes / 4);
        params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        for (int i = 1; i <= kMaxBuffers; ++i) {
            params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
            params[i].Descriptor.ShaderRegister = UINT(i);
            params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        }
        D3D12_ROOT_SIGNATURE_DESC rd = {};
        rd.NumParameters = UINT(1 + kMaxBuffers); rd.pParameters = params;
        ComPtr<ID3DBlob> sig, serr;
        if (FAILED(h = D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &serr))) return fail(e, "SerializeRootSignature", h);
        if (FAILED(h = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&root)))) return fail(e, "CreateRootSignature", h);
        if (FAILED(h = dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&alloc)))) return fail(e, "CreateCommandAllocator", h);
        if (FAILED(h = dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc.Get(), nullptr, IID_PPV_ARGS(&list)))) return fail(e, "CreateCommandList", h);
        list->Close();
        if (FAILED(h = dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) return fail(e, "CreateFence", h);
        event = CreateEvent(nullptr, FALSE, FALSE, nullptr);
        D3D12_QUERY_HEAP_DESC qh = {}; qh.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP; qh.Count = 2;
        if (SUCCEEDED(dev->CreateQueryHeap(&qh, IID_PPV_ARGS(&timestamps)))) {
            auto hp = heap(D3D12_HEAP_TYPE_READBACK); auto bd = bufferDesc(16, D3D12_RESOURCE_FLAG_NONE);
            dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&tsReadback));
        }
        return true;
    }

    void signalAndWait() {
        ++fenceValue;
        queue->Signal(fence.Get(), fenceValue);
        if (fence->GetCompletedValue() < fenceValue) { fence->SetEventOnCompletion(fenceValue, event); WaitForSingleObject(event, INFINITE); }
        pending = 0;
    }
    void waitIdle() override {
        if (!pending) return;
        signalAndWait();
        if (tsPending) { tsPending = false; lastMs = readTimestamps(); }
    }
    double lastGpuMs() const override { return lastMs; }
    double readTimestamps() {
        double ms = -1;
        if (timestamps && tsReadback) {
            UINT64 freq = 0, *t = nullptr; queue->GetTimestampFrequency(&freq);
            D3D12_RANGE rr = {0, 16};
            if (freq && SUCCEEDED(tsReadback->Map(0, &rr, reinterpret_cast<void**>(&t)))) {
                ms = double(t[1] - t[0]) * 1000.0 / double(freq);
                D3D12_RANGE none = {0, 0}; tsReadback->Unmap(0, &none);
            }
        }
        return ms;
    }

    ID3D12Resource* res(int h) const { return h > 0 && std::size_t(h) < buffers.size() ? buffers[std::size_t(h)].res.Get() : nullptr; }

    template <typename Rec>
    bool oneShot(const Rec& rec) {
        waitIdle();
        alloc->Reset();
        list->Reset(alloc.Get(), nullptr);
        rec(list.Get());
        if (FAILED(list->Close())) { err = "command list close failed"; return false; }
        ID3D12CommandList* l[] = {list.Get()};
        queue->ExecuteCommandLists(1, l);
        signalAndWait();
        return true;
    }

    // Persistent staging buffers (grow-only), so per-update uploads / readbacks create no resources.
    static constexpr std::size_t kStageChunk = 8u << 20;
    ComPtr<ID3D12Resource> upStage, downStage;
    std::size_t upSize = 0, downSize = 0;
    void* upPtr = nullptr;
    bool stage(bool upload, std::size_t bytes) {
        ComPtr<ID3D12Resource>& r = upload ? upStage : downStage;
        std::size_t& have = upload ? upSize : downSize;
        if (r && have >= bytes) return true;
        std::size_t want = std::max<std::size_t>(bytes, std::max<std::size_t>(have * 2, 64 * 1024));
        if (upload && upStage) { upStage->Unmap(0, nullptr); upPtr = nullptr; }
        r.Reset(); have = 0;
        auto hp = heap(upload ? D3D12_HEAP_TYPE_UPLOAD : D3D12_HEAP_TYPE_READBACK);
        auto bd = bufferDesc(want, D3D12_RESOURCE_FLAG_NONE);
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, upload ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COPY_DEST,
                                                nullptr, IID_PPV_ARGS(&r)))) { err = upload ? "staging alloc" : "readback alloc"; return false; }
        if (upload) { D3D12_RANGE none = {0, 0}; if (FAILED(r->Map(0, &none, &upPtr))) { err = "staging map"; r.Reset(); return false; } }
        have = want;
        return true;
    }

    int createBuffer(std::size_t requested, const void* init) override {
        std::size_t bytes = std::max<std::size_t>((requested + 15) & ~std::size_t(15), 16);
        Buf b; b.size = bytes;
        auto hp = heap(D3D12_HEAP_TYPE_DEFAULT); auto bd = bufferDesc(bytes, D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
        HRESULT h = dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&b.res));
        if (FAILED(h)) { err = "CreateCommittedResource " + hrs(h); return 0; }
        int handle = 0;
        for (std::size_t i = 1; i < buffers.size(); ++i) if (!buffers[i].res) { buffers[i] = b; handle = int(i); break; }
        if (!handle) { buffers.push_back(b); handle = int(buffers.size() - 1); }
        if (!fill(handle, 0)) return 0;
        if (init && requested && !upload(handle, init, requested, 0)) return 0;
        return handle;
    }
    void destroyBuffer(int h) override { if (h > 0 && std::size_t(h) < buffers.size()) { waitIdle(); buffers[std::size_t(h)] = Buf{}; } }

    bool upload(int h, const void* data, std::size_t bytes, std::size_t offset) override {
        ID3D12Resource* r = res(h);
        if (!r || offset + bytes > buffers[std::size_t(h)].size) { err = "upload out of range"; return false; }
        if (bytes == 0) return true;
        waitIdle();   // the staging buffer may still be read by an earlier copy
        const std::size_t chunk = std::min<std::size_t>(bytes, kStageChunk);   // bounded staging memory
        if (!stage(true, chunk)) return false;
        ID3D12Resource* src = upStage.Get();
        for (std::size_t done = 0; done < bytes; done += chunk) {
            const std::size_t n = std::min(chunk, bytes - done);
            std::memcpy(upPtr, static_cast<const uint8_t*>(data) + done, n);
            if (!oneShot([&](ID3D12GraphicsCommandList* l) { l->CopyBufferRegion(r, offset + done, src, 0, n); })) return false;
        }
        return true;
    }
    bool download(int h, void* out, std::size_t bytes, std::size_t offset) override {
        ID3D12Resource* r = res(h);
        if (!r || offset + bytes > buffers[std::size_t(h)].size) { err = "download out of range"; return false; }
        if (bytes == 0) return true;
        waitIdle();
        if (!stage(false, bytes)) return false;
        ID3D12Resource* dst = downStage.Get();
        if (!oneShot([&](ID3D12GraphicsCommandList* l) { l->CopyBufferRegion(dst, 0, r, offset, bytes); })) return false;
        void* p = nullptr; D3D12_RANGE rr = {0, bytes};
        if (FAILED(dst->Map(0, &rr, &p))) { err = "readback map"; return false; }
        std::memcpy(out, p, bytes); D3D12_RANGE none = {0, 0}; dst->Unmap(0, &none);
        return true;
    }
    bool fill(int h, uint32_t v) override {
        ID3D12Resource* r = res(h);
        if (!r) return false;
        const std::size_t size = buffers[std::size_t(h)].size;
        std::vector<uint32_t> data(std::min(size, kStageChunk) / 4, v);
        for (std::size_t off = 0; off < size; off += data.size() * 4)
            if (!upload(h, data.data(), std::min(data.size() * 4, size - off), off)) return false;
        return true;
    }

    int loadKernel(const char* entry, const void* code, std::size_t size, int, int, int) override {
        D3D12_COMPUTE_PIPELINE_STATE_DESC d = {};
        d.pRootSignature = root.Get();
        d.CS = {code, size};
        ComPtr<ID3D12PipelineState> pso;
        HRESULT h = dev->CreateComputePipelineState(&d, IID_PPV_ARGS(&pso));
        if (FAILED(h)) { err = std::string("CreateComputePipelineState ") + entry + " " + hrs(h); return 0; }
        kernels.push_back(pso);
        return int(kernels.size() - 1);
    }

    bool begin() override {
        if (recording) { err = "begin() while recording"; return false; }
        waitIdle();
        alloc->Reset();
        list->Reset(alloc.Get(), nullptr);
        list->SetComputeRootSignature(root.Get());
        if (timestamps) list->EndQuery(timestamps.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 0);
        recording = true;
        return true;
    }
    bool dispatch(int k, const void* c, std::size_t cbytes, const int* bs, int n, int gx, int gy, int gz) override {
        if (!recording || k <= 0 || std::size_t(k) >= kernels.size() || n > kMaxBuffers || cbytes > kMaxConstantBytes) { err = "bad dispatch"; return false; }
        if (gx <= 0 || gy <= 0 || gz <= 0) return true;
        list->SetPipelineState(kernels[std::size_t(k)].Get());
        if (c && cbytes) {
            uint32_t tmp[kMaxConstantBytes / 4] = {};
            std::memcpy(tmp, c, cbytes);
            list->SetComputeRoot32BitConstants(0, UINT((cbytes + 3) / 4), tmp, 0);
        }
        for (int i = 0; i < kMaxBuffers; ++i) {
            ID3D12Resource* r = i < n ? res(bs[i]) : nullptr;
            list->SetComputeRootUnorderedAccessView(UINT(i + 1), r ? r->GetGPUVirtualAddress() : 0);
        }
        list->Dispatch(UINT(gx), UINT(gy), UINT(gz));
        D3D12_RESOURCE_BARRIER b = {};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV; b.UAV.pResource = nullptr;
        list->ResourceBarrier(1, &b);
        return true;
    }
    double end(bool wait) override {
        if (!recording) return -1;
        recording = false;
        if (timestamps && tsReadback) {
            list->EndQuery(timestamps.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 1);
            list->ResolveQueryData(timestamps.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 0, 2, tsReadback.Get(), 0);
        }
        if (FAILED(list->Close())) { err = "command list close failed"; return -1; }
        ID3D12CommandList* l[] = {list.Get()};
        queue->ExecuteCommandLists(1, l);
        pending = 1; tsPending = true;
        if (!wait) return -1;
        signalAndWait();
        tsPending = false;
        if (dev->GetDeviceRemovedReason() != S_OK) { err = "device removed " + hrs(dev->GetDeviceRemovedReason()); lastMs = -1; return -1; }
        double ms = readTimestamps();
        lastMs = ms;
        return ms;
    }
};
}

std::unique_ptr<ComputeContext> createD3D12Compute(const CreateInfo& ci, std::string* e) {
    auto c = std::make_unique<D3D12Compute>();
    if (!c->init(ci, e)) return nullptr;
    return c;
}
}
