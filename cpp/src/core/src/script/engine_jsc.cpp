// JavaScriptCore engine (macOS system framework, C API). Port of the engine-specific half of Swift
// JSScriptRuntime.swift:
//  * one JSContextGroup + global context per runtime (never used by two threads at once);
//  * Float64Arrays over native memory with JSObjectMakeTypedArrayWithBytesNoCopy (no copies);
//  * watchdog: JSContextGroupSetExecutionTimeLimit (JavaScriptCore SPI, resolved with dlsym, exactly as the
//    Swift app does). When the SPI is missing, scripts run without a time limit (jscWatchdogAvailable() == false).
#if defined(__APPLE__)
#include <JavaScriptCore/JavaScriptCore.h>
#include <dlfcn.h>

#include <cmath>
#include <string>
#include <vector>

#include "engine.h"

namespace pw::script::detail {
namespace {

using ShouldTerminate = bool (*)(JSContextRef, void*);
using SetTimeLimit = void (*)(JSContextGroupRef, double, ShouldTerminate, void*);
SetTimeLimit setTimeLimitFn() {
    static SetTimeLimit f = reinterpret_cast<SetTimeLimit>(dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit"));
    return f;
}

struct WatchdogFlag { bool fired = false; };
bool watchdogCallback(JSContextRef, void* info) {
    static_cast<WatchdogFlag*>(info)->fired = true;
    return true;
}

std::string toStd(JSStringRef s) {
    std::size_t n = JSStringGetMaximumUTF8CStringSize(s);
    std::string out(n, '\0');
    std::size_t w = JSStringGetUTF8CString(s, out.data(), n);
    out.resize(w ? w - 1 : 0);
    return out;
}
std::string valueToString(JSContextRef ctx, JSValueRef v) {
    if (!v) return {};
    JSStringRef s = JSValueToStringCopy(ctx, v, nullptr);
    if (!s) return {};
    std::string r = toStd(s);
    JSStringRelease(s);
    return r;
}
JSValueRef getProp(JSContextRef ctx, JSObjectRef o, const char* name) {
    JSStringRef n = JSStringCreateWithUTF8CString(name);
    JSValueRef v = JSObjectGetProperty(ctx, o, n, nullptr);
    JSStringRelease(n);
    return v;
}

class JSCEngine;
struct NativeBox { JSCEngine* engine; int kind; };   // 0 nnCreate, 1 nnForward, 2 log

class JSCEngine final : public JSEngine {
public:
    JSCEngine() {
        group_ = JSContextGroupCreate();
        ctx_ = JSGlobalContextCreateInGroup(group_, nullptr);
    }
    ~JSCEngine() override {
        for (JSObjectRef f : pinned_) JSValueUnprotect(ctx_, f);
        JSGlobalContextRelease(ctx_);
        JSContextGroupRelease(group_);
    }
    pw::script::Engine kind() const override { return pw::script::Engine::JavaScriptCore; }

    NativeHost* host = nullptr;

    void installNatives(NativeHost* h) override {
        host = h;
        static JSClassRef cls = [] {
            JSClassDefinition def = kJSClassDefinitionEmpty;
            def.className = "PWNativeFunction";
            def.callAsFunction = &JSCEngine::nativeCall;
            return JSClassCreate(&def);
        }();
        JSObjectRef obj = JSObjectMake(ctx_, nullptr, nullptr);
        const char* names[] = {"nnCreate", "nnForward", "log"};
        for (int k = 0; k < 3; ++k) {
            boxes_.push_back(NativeBox{this, k});
        }
        for (int k = 0; k < 3; ++k) {
            JSObjectRef f = JSObjectMake(ctx_, cls, &boxes_[k]);
            JSStringRef n = JSStringCreateWithUTF8CString(names[k]);
            JSObjectSetProperty(ctx_, obj, n, f, kJSPropertyAttributeReadOnly, nullptr);
            JSStringRelease(n);
        }
        JSStringRef n = JSStringCreateWithUTF8CString("__native");
        JSObjectSetProperty(ctx_, JSContextGetGlobalObject(ctx_), n, obj, kJSPropertyAttributeDontEnum, nullptr);
        JSStringRelease(n);
    }

    static bool f64(JSContextRef ctx, JSValueRef v, double*& p, std::size_t& n) {
        if (!v || !JSValueIsObject(ctx, v)) return false;
        if (JSValueGetTypedArrayType(ctx, v, nullptr) != kJSTypedArrayTypeFloat64Array) return false;
        JSObjectRef o = JSValueToObject(ctx, v, nullptr);
        n = JSObjectGetTypedArrayLength(ctx, o, nullptr);
        // Buffer base + view byte offset (as the Swift runtime does; GetTypedArrayBytesPtr ignores subarray offsets).
        JSObjectRef buf = JSObjectGetTypedArrayBuffer(ctx, o, nullptr);
        void* base = buf ? JSObjectGetArrayBufferBytesPtr(ctx, buf, nullptr) : nullptr;
        std::size_t off = JSObjectGetTypedArrayByteOffset(ctx, o, nullptr);
        static double dummy = 0;
        p = base ? reinterpret_cast<double*>(static_cast<char*>(base) + off) : &dummy;
        return base != nullptr || n == 0;
    }

    static JSValueRef nativeCall(JSContextRef ctx, JSObjectRef fn, JSObjectRef, size_t argc, const JSValueRef argv[], JSValueRef* exc) {
        auto* box = static_cast<NativeBox*>(JSObjectGetPrivate(fn));
        if (!box || !box->engine->host) return JSValueMakeUndefined(ctx);
        auto arg = [&](size_t i) -> JSValueRef { return i < argc ? argv[i] : JSValueMakeUndefined(ctx); };
        std::string err;
        JSValueRef result = JSValueMakeUndefined(ctx);
        NativeHost* h = box->engine->host;
        switch (box->kind) {
        case 0: {
            double r = h->nnCreate(valueToString(ctx, arg(0)), valueToString(ctx, arg(1)), valueToString(ctx, arg(2)), err);
            result = JSValueMakeNumber(ctx, r);
            break;
        }
        case 1: {
            double *w, *x, *y;
            std::size_t wn, xn, yn;
            int handle = int(JSValueToNumber(ctx, arg(0), nullptr));
            double off = JSValueToNumber(ctx, arg(2), nullptr);
            if (!f64(ctx, arg(1), w, wn)) err = "nn.forward: weights must be a Float64Array or array";
            else if (!f64(ctx, arg(3), x, xn) || !f64(ctx, arg(4), y, yn)) err = "nn.forward: bad input/output arrays";
            else h->nnForward(handle, w, wn, off, x, xn, y, yn, err);
            break;
        }
        default: h->log(valueToString(ctx, arg(0))); break;
        }
        if (!err.empty()) {
            JSStringRef s = JSStringCreateWithUTF8CString(err.c_str());
            JSValueRef m = JSValueMakeString(ctx, s);
            JSStringRelease(s);
            *exc = JSObjectMakeError(ctx, 1, &m, nullptr);
        }
        return result;
    }

    void setLimit(double ms) {
        SetTimeLimit f = setTimeLimitFn();
        if (!f || ms == currentLimit_) return;
        currentLimit_ = ms;
        f(group_, ms / 1000.0, &watchdogCallback, &watchdog_);
    }

    [[noreturn]] void throwExc(JSValueRef exc) {
        RawError e;
        e.timedOut = watchdog_.fired;
        watchdog_.fired = false;
        e.message = valueToString(ctx_, exc);
        if (JSValueIsObject(ctx_, exc)) {
            JSObjectRef o = JSValueToObject(ctx_, exc, nullptr);
            JSValueRef u = getProp(ctx_, o, "sourceURL");
            if (u && JSValueIsString(ctx_, u)) e.sourceURL = valueToString(ctx_, u);
            JSValueRef l = getProp(ctx_, o, "line"), c = getProp(ctx_, o, "column");
            if (l && JSValueIsNumber(ctx_, l)) e.line = int(JSValueToNumber(ctx_, l, nullptr));
            if (c && JSValueIsNumber(ctx_, c)) e.column = int(JSValueToNumber(ctx_, c, nullptr));
            JSValueRef s = getProp(ctx_, o, "stack");
            if (s && JSValueIsString(ctx_, s)) e.stack = valueToString(ctx_, s);
        }
        throw EngineFailure{e};
    }

    void evaluate(const std::string& source, const std::string& url, double budgetMs) override {
        setLimit(budgetMs);
        watchdog_.fired = false;
        JSStringRef s = JSStringCreateWithUTF8CString(source.c_str()), u = JSStringCreateWithUTF8CString(url.c_str());
        JSValueRef exc = nullptr;
        JSEvaluateScript(ctx_, s, nullptr, u, 1, &exc);
        JSStringRelease(s);
        JSStringRelease(u);
        if (exc) throwExc(exc);
    }

    JSObjectRef global(const char* name) {
        JSValueRef v = getProp(ctx_, JSContextGetGlobalObject(ctx_), name);
        if (!v || !JSValueIsObject(ctx_, v)) return nullptr;
        JSObjectRef o = JSValueToObject(ctx_, v, nullptr);
        return o && JSObjectIsFunction(ctx_, o) ? o : nullptr;
    }

    JSValueRef makeArg(const Arg& a) {
        switch (a.kind) {
        case Arg::Kind::Number: return JSValueMakeNumber(ctx_, a.number);
        case Arg::Kind::String: {
            JSStringRef s = JSStringCreateWithUTF8CString(a.string.c_str());
            JSValueRef v = JSValueMakeString(ctx_, s);
            JSStringRelease(s);
            return v;
        }
        case Arg::Kind::Float64Array:
            return JSObjectMakeTypedArrayWithBytesNoCopy(ctx_, kJSTypedArrayTypeFloat64Array, a.ptr, a.length * sizeof(double), nullptr,
                                                         nullptr, nullptr);
        default: return JSValueMakeNull(ctx_);
        }
    }

    Result call(const char* name, const std::vector<Arg>& args, double budgetMs) override {
        JSObjectRef fn = global(name);
        if (!fn) { RawError e; e.message = std::string("internal: ") + name + " missing"; throw EngineFailure{e}; }
        std::vector<JSValueRef> argv;
        argv.reserve(args.size());
        for (auto& a : args) {
            argv.push_back(makeArg(a));
            JSValueProtect(ctx_, argv.back());
        }
        setLimit(budgetMs);
        watchdog_.fired = false;
        JSValueRef exc = nullptr;
        JSValueRef r = JSObjectCallAsFunction(ctx_, fn, nullptr, argv.size(), argv.data(), &exc);
        for (auto v : argv) JSValueUnprotect(ctx_, v);
        if (exc) throwExc(exc);
        Result out;
        if (r && JSValueIsString(ctx_, r)) { out.isString = true; out.isNullish = false; out.string = valueToString(ctx_, r); }
        else if (r && !JSValueIsNull(ctx_, r) && !JSValueIsUndefined(ctx_, r)) { out.isNullish = false; out.number = JSValueToNumber(ctx_, r, nullptr); }
        return out;
    }

    int pin(const char* name) override {
        JSObjectRef fn = global(name);
        if (!fn) return -1;
        JSValueProtect(ctx_, fn);
        pinned_.push_back(fn);
        return int(pinned_.size() - 1);
    }

    double callPinned(int slot, double budgetMs) override {
        setLimit(budgetMs);
        JSValueRef exc = nullptr;
        JSValueRef r = JSObjectCallAsFunction(ctx_, pinned_[slot], nullptr, 0, nullptr, &exc);
        if (exc) throwExc(exc);
        return JSValueToNumber(ctx_, r, nullptr);
    }

private:
    JSContextGroupRef group_ = nullptr;
    JSGlobalContextRef ctx_ = nullptr;
    std::vector<NativeBox> boxes_;
    std::vector<JSObjectRef> pinned_;
    WatchdogFlag watchdog_;
    double currentLimit_ = -1;
};
} // namespace

std::unique_ptr<JSEngine> makeJavaScriptCore() {
    auto e = std::make_unique<JSCEngine>();
    return e;
}
bool jscWatchdogAvailable() { return setTimeLimitFn() != nullptr; }
}
#endif
