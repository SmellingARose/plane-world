#pragma once
// What the GPU viewport needs to draw an evolved candidate's replay: the craft and per-part world poses at the
// current replay time. Queried on the GUI thread from GpuViewport::updatePaintNode (GUI thread blocked).
#include <cstdint>
#include <vector>
#include "pw/craft/document.h"
#include "pw/geo.h"

/// Missile-interception replays: the incoming missile, both tracks so far, and the intercept / impact event.
struct ReplayThreatView {
    pw::Vec3d missile, craft;                          // positions at the replay time
    std::vector<pw::Vec3d> missileTrail, craftTrail;   // flown so far (oldest first)
    double killRadius = 2.5, time = 0;
    bool destroyed = false;      // intercepted at or before the replay time (missile is gone)
    bool impacted = false;       // reached the defended point without an intercept
    double eventT = -1;          // time of the intercept / impact (-1 = none so far)
    pw::Vec3d eventPoint;
};

class ReplayProvider {
public:
    virtual ~ReplayProvider() = default;
    /// Craft being replayed (nullptr = no replay); `version` changes whenever the craft changes.
    virtual const pw::craft::CraftDocument* replayCraft(uint64_t& version) const = 0;
    /// Part poses in the craft document's part order, plus the craft origin. False when no frame is available.
    virtual bool replayPoses(std::vector<pw::geo::Transform>& parts, pw::geo::Transform& origin) const = 0;
    /// Craft shown at the world spawn while nothing is replayed (nullptr = none); `version` changes with it.
    /// Incoming missile for experiments with a "threat" (false = none).
    virtual bool replayThreat(ReplayThreatView& out) const { (void)out; return false; }
    virtual const pw::craft::CraftDocument* idleCraft(uint64_t& version) const { (void)version; return nullptr; }
};
