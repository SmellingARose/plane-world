// CraftSpec from the editable craft document model (pw/craft/document.h): one JSON hop keeps both modules' decoding
// rules identical to the Swift app (defaults merged, tolerant parameter types).
#include "pw/craft/document.h"
#include "pw/sim/craft_spec.h"

namespace pw::sim {

CraftSpec CraftSpec::fromDocument(const craft::CraftDocument& doc) {
    CraftSpec s;
    std::string err;
    if (!fromJson(craft::toJson(doc), s, err)) s = CraftSpec{};
    return s;
}

} // namespace pw::sim
