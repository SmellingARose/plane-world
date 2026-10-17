#pragma once
// CAD import (port of Swift Craft/CADImport.swift): STL (binary + ASCII), OBJ (o/g groups become parts),
// glTF 2.0 (.gltf + .glb: node hierarchy, names, TRS/matrix transforms, data-URI / external / GLB-chunk buffers).
// USD / USDA / USDC / USDZ go through the platform importer where one exists (ModelIO on macOS); elsewhere
// load() fails with a clear "not available on this platform" message.
// Output: a flat list of named parts with meshes already in assembly (craft) space.
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>
#include "pw/craft/mesh.h"

namespace pw::craft {

struct ImportedPart {
    std::string name;
    TriMesh mesh;     // assembly space (node transforms + import options applied)
};

struct CADImportOptions {
    enum class Up : uint8_t { Y, Z };
    Up up = Up::Y;              // source up axis; craft space is Y-up, +X forward, +Z right
    double yawDegrees = 0;      // extra rotation about craft up after the up-axis fix
    double scale = 1;           // uniform scale (e.g. 0.001 for millimetre STL)
    Mat4f matrix() const;
};

namespace cad {
/// Lower-case extensions load() understands on this platform (usd* only where a platform importer exists).
std::vector<std::string> fileExtensions();
bool usdSupported();
/// Load any supported file. On failure returns false and a human-readable message in `error`.
bool load(const std::string& path, const CADImportOptions& opt, std::vector<ImportedPart>& out, std::string& error);

bool parseSTL(const std::vector<uint8_t>& data, TriMesh& out, std::string& error);
std::vector<uint8_t> stlBinary(const TriMesh& m);
bool parseOBJ(std::string_view text, const std::string& defaultName, std::vector<ImportedPart>& out, std::string& error);
/// `baseDir` resolves external buffer URIs ("" = none allowed).
bool parseGLTF(const std::vector<uint8_t>& data, const std::string& baseDir, std::vector<ImportedPart>& out, std::string& error);
/// Platform importer (ModelIO on Apple). Returns false with a message where unavailable.
bool loadPlatform(const std::string& path, std::vector<ImportedPart>& out, std::string& error);
bool readBytes(const std::string& path, std::vector<uint8_t>& out);
} // namespace cad

} // namespace pw::craft
