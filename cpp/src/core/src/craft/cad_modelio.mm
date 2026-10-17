// USD / USDA / USDC / USDZ (and any other ModelIO format) import on Apple platforms (port of Swift ModelIOReader).
#import <Foundation/Foundation.h>
#import <ModelIO/ModelIO.h>
#include <functional>
#include "pw/craft/cad.h"

namespace pw::craft::cad {

bool usdSupported() { return true; }

static Mat4f fromSimd(matrix_float4x4 m) {
    Mat4f r;
    for (int c = 0; c < 4; ++c) for (int k = 0; k < 4; ++k) r.c[c][k] = m.columns[c][k];
    return r;
}

static bool triMesh(MDLMesh* mesh, TriMesh& out) {
    MDLVertexAttributeData* attr = [mesh vertexAttributeDataForAttributeNamed:MDLVertexAttributePosition asFormat:MDLVertexFormatFloat3];
    if (!attr) return false;
    std::vector<Vec3f> pos;
    pos.reserve(mesh.vertexCount);
    for (NSUInteger i = 0; i < mesh.vertexCount; ++i) {
        const float* p = (const float*)((const char*)attr.dataStart + i * attr.stride);
        pos.push_back({p[0], p[1], p[2]});
    }
    std::vector<uint32_t> idx;
    for (id obj in mesh.submeshes) {
        if (![obj isKindOfClass:[MDLSubmesh class]]) continue;
        MDLSubmesh* sm = (MDLSubmesh*)obj;
        if (sm.geometryType != MDLGeometryTypeTriangles) {
            MDLSubmesh* tri = [[MDLSubmesh alloc] initWithMDLSubmesh:sm indexType:MDLIndexBitDepthUInt32 geometryType:MDLGeometryTypeTriangles];
            if (!tri) { NSLog(@"[CADImport] warning: could not triangulate submesh '%@'; skipped", sm.name); continue; }
            sm = tri;
        }
        MDLMeshBufferMap* map = [sm.indexBuffer map];
        const uint8_t* bytes = (const uint8_t*)map.bytes;
        for (NSUInteger k = 0; k < sm.indexCount; ++k) {
            switch (sm.indexType) {
            case MDLIndexBitDepthUInt8: idx.push_back(bytes[k]); break;
            case MDLIndexBitDepthUInt16: idx.push_back(((const uint16_t*)bytes)[k]); break;
            default: idx.push_back(((const uint32_t*)bytes)[k]); break;
            }
        }
    }
    std::vector<uint32_t> valid;
    for (uint32_t i : idx) if (i < pos.size()) valid.push_back(i);
    valid.resize(valid.size() / 3 * 3);
    if (valid.empty()) return false;
    out = TriMesh(std::move(pos), std::move(valid));
    return true;
}

bool loadPlatform(const std::string& path, std::vector<ImportedPart>& out, std::string& err) {
    @autoreleasepool {
        NSString* p = [NSString stringWithUTF8String:path.c_str()];
        NSURL* url = [NSURL fileURLWithPath:p];
        if (![MDLAsset canImportFileExtension:url.pathExtension]) { err = std::string("unsupported format: ") + url.pathExtension.UTF8String; return false; }
        MDLAsset* asset = [[MDLAsset alloc] initWithURL:url];
        if (!asset) { err = "cannot open " + path; return false; }
        out.clear();
        std::function<void(MDLObject*, const Mat4f&, const std::string&)> visit = [&](MDLObject* o, const Mat4f& parent, const std::string& prefix) {
            Mat4f local = o.transform ? fromSimd(o.transform.matrix) : Mat4f::identity();
            Mat4f world = parent * local;
            std::string name = o.name.length ? std::string(o.name.UTF8String) : prefix + "obj" + std::to_string(out.size());
            if ([o isKindOfClass:[MDLMesh class]]) {
                TriMesh m;
                if (triMesh((MDLMesh*)o, m)) out.push_back({name, m.transformed(world)});
            }
            for (MDLObject* c in o.children.objects) visit(c, world, name + "/");
        };
        for (NSUInteger i = 0; i < asset.count; ++i) visit([asset objectAtIndex:i], Mat4f::identity(), "");
        return true;
    }
}

} // namespace pw::craft::cad
