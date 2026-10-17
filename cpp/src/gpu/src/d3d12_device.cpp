// Direct3D 12 backend. Shaders: Slang -> HLSL -> DXIL (Windows SDK dxc) embedded at build time.
// Own device (hardware adapter, or WARP when preferSoftware / no hardware) or a host's device + queue (Qt Quick).
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cstring>
#include <string>
#include "pw/gpu.h"
#include "pw/shaders.h"

using Microsoft::WRL::ComPtr;

namespace pw::gpu {
namespace {
std::string narrow(const wchar_t* w) {
    std::string s;
    for (; *w; ++w) s += (*w < 128) ? char(*w) : '?';
    return s;
}
std::string hr(HRESULT h) { char b[32]; snprintf(b, sizeof b, "0x%08lx", (unsigned long)h); return b; }

class D3D12Device final : public Device {
public:
    static constexpr int kFrames = 2;
    ComPtr<IDXGIFactory4> factory;
    ComPtr<ID3D12Device> dev;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pso;
    ComPtr<ID3D12DescriptorHeap> rtvHeap;
    ComPtr<ID3D12Resource> tex;
    ComPtr<ID3D12CommandAllocator> alloc[kFrames];
    ComPtr<ID3D12GraphicsCommandList> list;
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    UINT64 fenceValue = 0, frameFence[kFrames] = {};
    int frame = 0, w = 0, h = 0;
    std::string adapter;
    bool software = false;
    static constexpr D3D12_RESOURCE_STATES kIdleState = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;

    ~D3D12Device() override { if (dev) waitIdle(); if (event) CloseHandle(event); }
    Backend backend() const override { return Backend::D3D12; }
    std::string adapterName() const override { return adapter; }
    bool isSoftware() const override { return software; }

    bool fail(std::string* err, const std::string& m, HRESULT h) { if (err) *err = m + " (" + hr(h) + ")"; return false; }

    bool init(const CreateInfo& ci, std::string* err) {
        HRESULT h;
        if (ci.externalDevice) {
            dev = static_cast<ID3D12Device*>(ci.externalDevice);
            if (ci.externalQueue) queue = static_cast<ID3D12CommandQueue*>(ci.externalQueue);
            LUID luid = dev->GetAdapterLuid();
            if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
                ComPtr<IDXGIAdapter1> a;
                if (SUCCEEDED(factory->EnumAdapterByLuid(luid, IID_PPV_ARGS(&a)))) {
                    DXGI_ADAPTER_DESC1 d; a->GetDesc1(&d); adapter = narrow(d.Description); software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
                }
            }
        } else {
            if (FAILED(h = CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return fail(err, "CreateDXGIFactory1", h);
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
            DXGI_ADAPTER_DESC1 d; chosen->GetDesc1(&d);
            adapter = narrow(d.Description); software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
            if (FAILED(h = D3D12CreateDevice(chosen.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev)))) return fail(err, "D3D12CreateDevice", h);
        }
        if (!queue) {
            D3D12_COMMAND_QUEUE_DESC qd = {};
            qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
            if (FAILED(h = dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue)))) return fail(err, "CreateCommandQueue", h);
        }
        // Root signature: 12 root constants at b0 (ViewParams), visible to all stages.
        D3D12_ROOT_PARAMETER rp = {};
        rp.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        rp.Constants.ShaderRegister = 0; rp.Constants.RegisterSpace = 0; rp.Constants.Num32BitValues = 12;
        rp.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
        D3D12_ROOT_SIGNATURE_DESC rsd = {};
        rsd.NumParameters = 1; rsd.pParameters = &rp;
        ComPtr<ID3DBlob> sig, errBlob;
        if (FAILED(h = D3D12SerializeRootSignature(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &errBlob))) return fail(err, "SerializeRootSignature", h);
        if (FAILED(h = dev->CreateRootSignature(0, sig->GetBufferPointer(), sig->GetBufferSize(), IID_PPV_ARGS(&root)))) return fail(err, "CreateRootSignature", h);
        const shaders::Blob* vs = shaders::find("viewport.vs");
        const shaders::Blob* ps = shaders::find("viewport.ps");
        if (!vs || !ps) { if (err) *err = "viewport DXIL blobs missing"; return false; }
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = root.Get();
        pd.VS = {vs->data, vs->size};
        pd.PS = {ps->data, ps->size};
        pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pd.SampleMask = UINT_MAX;
        pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pd.RasterizerState.DepthClipEnable = TRUE;
        pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pd.NumRenderTargets = 1;
        pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        pd.SampleDesc.Count = 1;
        if (FAILED(h = dev->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&pso)))) return fail(err, "CreateGraphicsPipelineState", h);
        D3D12_DESCRIPTOR_HEAP_DESC hd = {};
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 1;
        if (FAILED(h = dev->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&rtvHeap)))) return fail(err, "CreateDescriptorHeap", h);
        for (auto& a : alloc)
            if (FAILED(h = dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&a)))) return fail(err, "CreateCommandAllocator", h);
        if (FAILED(h = dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc[0].Get(), nullptr, IID_PPV_ARGS(&list)))) return fail(err, "CreateCommandList", h);
        list->Close();
        if (FAILED(h = dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) return fail(err, "CreateFence", h);
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        return event != nullptr;
    }

    void waitFor(UINT64 v) {
        if (fence->GetCompletedValue() < v) { fence->SetEventOnCompletion(v, event); WaitForSingleObject(event, INFINITE); }
    }
    void waitIdle() override { queue->Signal(fence.Get(), ++fenceValue); waitFor(fenceValue); }

    bool resize(int width, int height) override {
        if (width <= 0 || height <= 0) return false;
        if (tex && width == w && height == h) return true;
        waitIdle();
        tex.Reset();
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = UINT64(width); rd.Height = UINT(height); rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1;
        rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        D3D12_CLEAR_VALUE cv = {}; cv.Format = rd.Format;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, kIdleState, &cv, IID_PPV_ARGS(&tex)))) return false;
        tex->SetName(L"pwgpu viewport target");
        dev->CreateRenderTargetView(tex.Get(), nullptr, rtvHeap->GetCPUDescriptorHandleForHeapStart());
        w = width; h = height;
        return true;
    }

    static D3D12_RESOURCE_BARRIER transition(ID3D12Resource* r, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b) {
        D3D12_RESOURCE_BARRIER x = {};
        x.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        x.Transition.pResource = r; x.Transition.StateBefore = a; x.Transition.StateAfter = b;
        x.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        return x;
    }

    bool render(const ViewParams& p) override {
        if (!tex) return false;
        frame = (frame + 1) % kFrames;
        waitFor(frameFence[frame]);
        alloc[frame]->Reset();
        list->Reset(alloc[frame].Get(), pso.Get());
        auto b0 = transition(tex.Get(), kIdleState, D3D12_RESOURCE_STATE_RENDER_TARGET);
        list->ResourceBarrier(1, &b0);
        D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtvHeap->GetCPUDescriptorHandleForHeapStart();
        list->ClearRenderTargetView(rtv, p.clearColor, 0, nullptr);
        list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        D3D12_VIEWPORT vp = {0, 0, float(w), float(h), 0, 1};
        D3D12_RECT sc = {0, 0, LONG(w), LONG(h)};
        list->RSSetViewports(1, &vp); list->RSSetScissorRects(1, &sc);
        list->SetGraphicsRootSignature(root.Get());
        list->SetGraphicsRoot32BitConstants(0, 12, &p, 0);
        list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        list->DrawInstanced(3, 1, 0, 0);
        auto b1 = transition(tex.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET, kIdleState);
        list->ResourceBarrier(1, &b1);
        if (FAILED(list->Close())) return false;
        ID3D12CommandList* lists[] = {list.Get()};
        queue->ExecuteCommandLists(1, lists);
        queue->Signal(fence.Get(), ++fenceValue);
        frameFence[frame] = fenceValue;
        return true;
    }

    NativeTarget target() const override { return {tex.Get(), int(kIdleState), w, h}; }

    bool readback(std::vector<uint8_t>& out) override {
        if (!tex) return false;
        D3D12_RESOURCE_DESC rd = tex->GetDesc();
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total = 0;
        dev->GetCopyableFootprints(&rd, 0, 1, 0, &fp, nullptr, nullptr, &total);
        D3D12_HEAP_PROPERTIES hp = {}; hp.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC bd = {};
        bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; bd.Width = total; bd.Height = 1; bd.DepthOrArraySize = 1;
        bd.MipLevels = 1; bd.SampleDesc.Count = 1; bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> buf;
        if (FAILED(dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&buf)))) return false;
        frame = (frame + 1) % kFrames;
        waitFor(frameFence[frame]);
        alloc[frame]->Reset();
        list->Reset(alloc[frame].Get(), nullptr);
        auto b0 = transition(tex.Get(), kIdleState, D3D12_RESOURCE_STATE_COPY_SOURCE);
        list->ResourceBarrier(1, &b0);
        D3D12_TEXTURE_COPY_LOCATION dst = {}; dst.pResource = buf.Get(); dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = fp;
        D3D12_TEXTURE_COPY_LOCATION src = {}; src.pResource = tex.Get(); src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0;
        list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
        auto b1 = transition(tex.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, kIdleState);
        list->ResourceBarrier(1, &b1);
        if (FAILED(list->Close())) return false;
        ID3D12CommandList* lists[] = {list.Get()};
        queue->ExecuteCommandLists(1, lists);
        queue->Signal(fence.Get(), ++fenceValue);
        frameFence[frame] = fenceValue;
        waitFor(fenceValue);
        if (dev->GetDeviceRemovedReason() != S_OK) return false;
        void* mapped = nullptr;
        D3D12_RANGE range = {0, SIZE_T(total)};
        if (FAILED(buf->Map(0, &range, &mapped))) return false;
        out.resize(std::size_t(w) * h * 4);
        for (int y = 0; y < h; ++y)
            std::memcpy(&out[std::size_t(y) * w * 4], static_cast<uint8_t*>(mapped) + fp.Offset + std::size_t(y) * fp.Footprint.RowPitch, std::size_t(w) * 4);
        D3D12_RANGE none = {0, 0};
        buf->Unmap(0, &none);
        return true;
    }
};
}

std::unique_ptr<Device> createD3D12Device(const CreateInfo& ci, std::string* err) {
    auto d = std::make_unique<D3D12Device>();
    if (!d->init(ci, err)) return nullptr;
    return d;
}
}
