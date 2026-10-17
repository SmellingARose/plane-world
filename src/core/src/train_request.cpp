#include "pw/train_request.h"
#include <atomic>
namespace pw::train {
namespace { std::atomic<Handler> g{nullptr}; }
void setHandler(Handler h) { g.store(h); }
Handler handler() { return g.load(); }
}
