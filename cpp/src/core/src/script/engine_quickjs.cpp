// QuickJS (quickjs-ng) engine: every platform, the default on Windows. Same prelude and plumbing as the
// JavaScriptCore engine; differences are documented in cpp/docs/SCRIPTING.md.
//  * one JSRuntime + JSContext per runtime; JS_UpdateStackTop when the OS thread changes (workers may migrate);
//  * Float64Arrays over native memory: JS_NewArrayBuffer with no free function (QuickJS never owns the bytes);
//  * watchdog: JS_SetInterruptHandler with a steady-clock deadline (QuickJS polls it every few thousand
//    bytecodes). An interrupted call raises an uncatchable error; the context stays usable afterwards.
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include <atomic>
#include <cstdlib>
#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(_WIN32)
#include <malloc.h>
#else
#include <malloc.h>
#endif
#include "quickjs.h"
#include "engine.h"

namespace pw::script::detail {
namespace {

using Clock = std::chrono::steady_clock;

// Counting allocator (the zero-allocation tick test reads it); otherwise plain malloc.
std::size_t usable(const void* p) {
#if defined(__APPLE__)
    return malloc_size(p);
#elif defined(_WIN32)
    return _msize(const_cast<void*>(p));
#else
    return malloc_usable_size(const_cast<void*>(p));
#endif
}
void* qCalloc(void* o, size_t n, size_t s) { ++*static_cast<std::atomic<std::size_t>*>(o); return std::calloc(n, s); }
void* qMalloc(void* o, size_t s) { ++*static_cast<std::atomic<std::size_t>*>(o); return std::malloc(s); }
void qFree(void*, void* p) { std::free(p); }
void* qRealloc(void* o, void* p, size_t s) {
    if (s == 0) { std::free(p); return nullptr; }
    ++*static_cast<std::atomic<std::size_t>*>(o);
    return std::realloc(p, s);
}
const JSMallocFunctions kMalloc = {qCalloc, qMalloc, qFree, qRealloc, usable};

class QJSEngine;
QJSEngine* engineOf(JSContext* ctx) { return static_cast<QJSEngine*>(JS_GetContextOpaque(ctx)); }

std::string toStd(JSContext* ctx, JSValueConst v) {
    size_t n = 0;
    const char* s = JS_ToCStringLen(ctx, &n, v);
    if (!s) { JS_FreeValue(ctx, JS_GetException(ctx)); return {}; }
    std::string r(s, n);
    JS_FreeCString(ctx, s);
    return r;
}

bool f64(JSContext* ctx, JSValueConst v, double*& p, std::size_t& n) {
    if (JS_GetTypedArrayType(v) != JS_TYPED_ARRAY_FLOAT64) return false;
    size_t off = 0, len = 0, bpe = 0;
    JSValue ab = JS_GetTypedArrayBuffer(ctx, v, &off, &len, &bpe);
    if (JS_IsException(ab)) { JS_FreeValue(ctx, JS_GetException(ctx)); return false; }
    size_t size = 0;
    uint8_t* base = JS_GetArrayBuffer(ctx, &size, ab);
    JS_FreeValue(ctx, ab);
    static double dummy = 0;
    n = len / sizeof(double);
    p = base ? reinterpret_cast<double*>(base + off) : &dummy;
    return base != nullptr || n == 0;
}

class QJSEngine final : public JSEngine {
public:
    QJSEngine() {
        rt_ = JS_NewRuntime2(&kMalloc, &allocs_);
        // Stay well inside the smallest thread stack we run on (Windows: 1 MB main thread, std::thread default).
        JS_SetMaxStackSize(rt_, 256 * 1024);
        JS_SetInterruptHandler(rt_, &QJSEngine::interrupt, this);
        ctx_ = JS_NewContext(rt_);
        JS_SetContextOpaque(ctx_, this);
        thread_ = std::this_thread::get_id();
    }
    ~QJSEngine() override {
        for (JSValue& f : pinned_) JS_FreeValue(ctx_, f);
        JS_FreeContext(ctx_);
        JS_FreeRuntime(rt_);
    }
    pw::script::Engine kind() const override { return pw::script::Engine::QuickJS; }
    std::size_t heapAllocations() const override { return allocs_.load(); }

    NativeHost* host = nullptr;

    static int interrupt(JSRuntime*, void* opaque) {
        auto* e = static_cast<QJSEngine*>(opaque);
        if (e->armed_ && Clock::now() > e->deadline_) { e->fired_ = true; return 1; }
        return 0;
    }

    static JSValue native(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv, int magic, JSValueConst*) {
        QJSEngine* e = engineOf(ctx);
        NativeHost* h = e ? e->host : nullptr;
        if (!h) return JS_UNDEFINED;
        auto arg = [&](int i) -> JSValueConst { return i < argc ? argv[i] : JS_UNDEFINED; };
        std::string err;
        JSValue result = JS_UNDEFINED;
        switch (magic) {
        case 0: result = JS_NewFloat64(ctx, h->nnCreate(toStd(ctx, arg(0)), toStd(ctx, arg(1)), toStd(ctx, arg(2)), err)); break;
        case 1: {
            double *w, *x, *y;
            std::size_t wn, xn, yn;
            double hd = 0, off = 0;
            JS_ToFloat64(ctx, &hd, arg(0));
            JS_ToFloat64(ctx, &off, arg(2));
            if (!f64(ctx, arg(1), w, wn)) err = "nn.forward: weights must be a Float64Array or array";
            else if (!f64(ctx, arg(3), x, xn) || !f64(ctx, arg(4), y, yn)) err = "nn.forward: bad input/output arrays";
            else h->nnForward(int(hd), w, wn, off, x, xn, y, yn, err);
            break;
        }
        default: h->log(toStd(ctx, arg(0))); break;
        }
        if (!err.empty()) {
            JSValue ev = JS_NewError(ctx);
            JS_DefinePropertyValueStr(ctx, ev, "message", JS_NewStringLen(ctx, err.data(), err.size()),
                                      JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
            return JS_Throw(ctx, ev);
        }
        return result;
    }

    void installNatives(NativeHost* h) override {
        host = h;
        JSValue obj = JS_NewObject(ctx_);
        const char* names[] = {"nnCreate", "nnForward", "log"};
        const int lengths[] = {3, 5, 1};
        for (int k = 0; k < 3; ++k)
            JS_SetPropertyStr(ctx_, obj, names[k], JS_NewCFunctionData2(ctx_, &QJSEngine::native, names[k], lengths[k], k, 0, nullptr));
        JSValue g = JS_GetGlobalObject(ctx_);
        JS_DefinePropertyValueStr(ctx_, g, "__native", obj, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);   // not enumerable
        JS_FreeValue(ctx_, g);
    }

    void arm(double ms) {
        if (std::this_thread::get_id() != thread_) { thread_ = std::this_thread::get_id(); JS_UpdateStackTop(rt_); }
        fired_ = false;
        armed_ = true;
        deadline_ = Clock::now() + std::chrono::microseconds(int64_t(ms * 1000.0));
    }

    [[noreturn]] void throwPending() {
        armed_ = false;
        JSValue exc = JS_GetException(ctx_);
        RawError e;
        e.timedOut = fired_;
        fired_ = false;
        e.message = toStd(ctx_, exc);
        if (JS_IsObject(exc)) {
            JSValue s = JS_GetPropertyStr(ctx_, exc, "stack");
            if (JS_IsString(s)) e.stack = toStd(ctx_, s);
            JS_FreeValue(ctx_, s);
            JSValue f = JS_GetPropertyStr(ctx_, exc, "fileName");
            if (JS_IsString(f)) e.sourceURL = toStd(ctx_, f);
            JS_FreeValue(ctx_, f);
            JSValue l = JS_GetPropertyStr(ctx_, exc, "lineNumber"), c = JS_GetPropertyStr(ctx_, exc, "columnNumber");
            int32_t li = 0, ci = 0;
            if (JS_IsNumber(l)) JS_ToInt32(ctx_, &li, l);
            if (JS_IsNumber(c)) JS_ToInt32(ctx_, &ci, c);
            JS_FreeValue(ctx_, l);
            JS_FreeValue(ctx_, c);
            e.line = li;
            e.column = ci;
        }
        JS_FreeValue(ctx_, exc);
        throw EngineFailure{e};
    }

    void evaluate(const std::string& source, const std::string& url, double budgetMs) override {
        arm(budgetMs);
        JSValue r = JS_Eval(ctx_, source.c_str(), source.size(), url.c_str(), JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(r)) throwPending();
        armed_ = false;
        JS_FreeValue(ctx_, r);
    }

    JSValue global(const char* name) {
        JSValue g = JS_GetGlobalObject(ctx_);
        JSValue f = JS_GetPropertyStr(ctx_, g, name);
        JS_FreeValue(ctx_, g);
        if (!JS_IsFunction(ctx_, f)) { JS_FreeValue(ctx_, f); return JS_UNDEFINED; }
        return f;
    }

    JSValue makeArg(const Arg& a) {
        switch (a.kind) {
        case Arg::Kind::Number: return JS_NewFloat64(ctx_, a.number);
        case Arg::Kind::String: return JS_NewStringLen(ctx_, a.string.data(), a.string.size());
        case Arg::Kind::Float64Array: {
            JSValue ab = JS_NewArrayBuffer(ctx_, reinterpret_cast<uint8_t*>(a.ptr), a.length * sizeof(double), 0, nullptr, nullptr, false);
            JSValue ta = JS_NewTypedArray(ctx_, 1, &ab, JS_TYPED_ARRAY_FLOAT64);
            JS_FreeValue(ctx_, ab);
            return ta;
        }
        default: return JS_NULL;
        }
    }

    Result call(const char* name, const std::vector<Arg>& args, double budgetMs) override {
        JSValue fn = global(name);
        if (JS_IsUndefined(fn)) { RawError e; e.message = std::string("internal: ") + name + " missing"; throw EngineFailure{e}; }
        std::vector<JSValue> argv;
        argv.reserve(args.size());
        for (auto& a : args) argv.push_back(makeArg(a));
        arm(budgetMs);
        JSValue r = JS_Call(ctx_, fn, JS_UNDEFINED, int(argv.size()), argv.data());
        for (auto& v : argv) JS_FreeValue(ctx_, v);
        JS_FreeValue(ctx_, fn);
        if (JS_IsException(r)) throwPending();
        armed_ = false;
        Result out;
        if (JS_IsString(r)) { out.isString = true; out.isNullish = false; out.string = toStd(ctx_, r); }
        else if (!JS_IsNull(r) && !JS_IsUndefined(r)) { out.isNullish = false; JS_ToFloat64(ctx_, &out.number, r); }
        JS_FreeValue(ctx_, r);
        return out;
    }

    int pin(const char* name) override {
        JSValue f = global(name);
        if (JS_IsUndefined(f)) return -1;
        pinned_.push_back(f);
        return int(pinned_.size() - 1);
    }

    double callPinned(int slot, double budgetMs) override {
        arm(budgetMs);
        JSValue r = JS_Call(ctx_, pinned_[slot], JS_UNDEFINED, 0, nullptr);
        if (JS_IsException(r)) throwPending();
        armed_ = false;
        double d = 0;
        if (JS_IsNumber(r)) JS_ToFloat64(ctx_, &d, r);
        else d = JS_ToBool(ctx_, r) ? 1 : 0;
        JS_FreeValue(ctx_, r);
        return d;
    }

private:
    std::atomic<std::size_t> allocs_{0};
    JSRuntime* rt_ = nullptr;
    JSContext* ctx_ = nullptr;
    std::vector<JSValue> pinned_;
    std::thread::id thread_;
    Clock::time_point deadline_{};
    bool armed_ = false, fired_ = false;
};
} // namespace

std::unique_ptr<JSEngine> makeQuickJS() { return std::make_unique<QJSEngine>(); }
}
