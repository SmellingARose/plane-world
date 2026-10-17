#pragma once
// Plane mesh-cut tool (port of Swift Craft/MeshCut.swift): splits a closed mesh by a plane into two closed
// parts, capping the holes by chaining the cut edges into loops and ear-clipping each loop in the plane.
// Limitation (same as Swift): nested loops (a tube cross-section) are capped per loop, so an inner loop is
// filled instead of becoming a hole; the result is still watertight.
#include <optional>
#include <utility>
#include "pw/craft/mesh.h"

namespace pw::craft::MeshCut {
struct Result { TriMesh below, above; int loops = 0; };
/// `below` keeps the side opposite to `normal`. Input is welded first so shared edges stay shared.
Result split(const TriMesh& input, const Vec3f& planePoint, const Vec3f& planeNormal);
/// Splits a craft part (cad or primitive) into two `cad` parts ("<id>a"/"<id>b"); mass divided by volume.
std::optional<std::pair<CraftPart, CraftPart>> splitPart(const CraftPart& part, const Vec3d& planePoint, const Vec3d& planeNormal);
} // namespace pw::craft::MeshCut
