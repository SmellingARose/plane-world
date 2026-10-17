#pragma once
// What the GPU viewport needs to draw an evolved candidate's replay: the craft and per-part world poses at the
// current replay time. Queried on the GUI thread from GpuViewport::updatePaintNode (GUI thread blocked).
#include <cstdint>
#include <vector>
#include "pw/craft/document.h"
#include "pw/geo.h"

class ReplayProvider {
public:
    virtual ~ReplayProvider() = default;
    /// Craft being replayed (nullptr = no replay); `version` changes whenever the craft changes.
    virtual const pw::craft::CraftDocument* replayCraft(uint64_t& version) const = 0;
    /// Part poses in the craft document's part order, plus the craft origin. False when no frame is available.
    virtual bool replayPoses(std::vector<pw::geo::Transform>& parts, pw::geo::Transform& origin) const = 0;
};
