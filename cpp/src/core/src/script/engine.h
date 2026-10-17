#pragma once
// Internal: the small surface a JavaScript engine must provide to the engine-neutral runtime (runtime.cpp).
// Everything structured crosses as JSON text, so an engine only marshals numbers, strings and Float64Arrays.
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "pw/script/runtime.h"

namespace pw::script::detail {

/// Raw exception data extracted by an engine; runtime.cpp turns it into a ScriptError.
struct RawError {
    std::string message;        // toString() of the thrown value
    std::string sourceURL;      // where the engine says the error is (JSC: sourceURL property)
    int line = 0, column = 0;   // engine-reported position (0 = unknown)
    std::string stack;
    bool timedOut = false;      // the watchdog fired during this call
};

struct EngineFailure { RawError error; };   // thrown by Engine methods

/// One argument of a call from runtime.cpp into JS.
struct Arg {
    enum class Kind : uint8_t { Number, String, Float64Array, Null } kind = Kind::Null;
    double number = 0;
    std::string string;
    double* ptr = nullptr;      // Float64Array over caller memory (no copy); must outlive the JS object
    std::size_t length = 0;
    static Arg num(double d) { Arg a; a.kind = Kind::Number; a.number = d; return a; }
    static Arg str(std::string s) { Arg a; a.kind = Kind::String; a.string = std::move(s); return a; }
    static Arg f64(double* p, std::size_t n) { Arg a; a.kind = Kind::Float64Array; a.ptr = p; a.length = n; return a; }
};

/// Result of a call: numbers and strings are all the plumbing ever returns.
struct Result {
    bool isString = false, isNullish = true;
    double number = 0;
    std::string string;
};

/// Natives exposed as `__native.nnCreate / nnForward / log`. The engine decodes arguments and calls these.
class NativeHost {
public:
    virtual ~NativeHost() = default;
    /// Each returns a number result; on error set `err` (thrown into JS as an Error with that message).
    virtual double nnCreate(const std::string& sizesJSON, const std::string& act, const std::string& outAct, std::string& err) = 0;
    virtual void nnForward(int handle, const double* w, std::size_t wn, double offset, const double* x, std::size_t xn,
                           double* y, std::size_t yn, std::string& err) = 0;
    virtual void log(const std::string& s) = 0;
};

class JSEngine {
public:
    virtual ~JSEngine() = default;
    virtual pw::script::Engine kind() const = 0;
    virtual void installNatives(NativeHost* host) = 0;
    /// Evaluates a script with a source URL (line 1). Throws EngineFailure.
    virtual void evaluate(const std::string& source, const std::string& url, double budgetMs) = 0;
    /// Calls a global function by name. Throws EngineFailure (including watchdog timeouts).
    virtual Result call(const char* name, const std::vector<Arg>& args, double budgetMs) = 0;
    /// Pins a global zero-argument function for the hot path; returns a slot id.
    virtual int pin(const char* name) = 0;
    /// Calls a pinned function with no arguments and returns ToNumber(result). Allocation-free on the C++ side.
    virtual double callPinned(int slot, double budgetMs) = 0;
    /// Engine heap allocations so far (QuickJS: counted malloc hooks); SIZE_MAX when the engine cannot tell.
    virtual std::size_t heapAllocations() const { return SIZE_MAX; }
};

std::unique_ptr<JSEngine> makeQuickJS();
#if defined(__APPLE__)
std::unique_ptr<JSEngine> makeJavaScriptCore();
bool jscWatchdogAvailable();
#endif
}
