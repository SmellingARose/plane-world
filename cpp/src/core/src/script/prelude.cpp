// The prelude JS (src/script/prelude.js), embedded at build time.
#include <cstring>
#include <string>
#include "pw/script/runtime.h"

namespace pw::script::embedded_experiments {
struct Blob { const char* key; const char* data; std::size_t size; };
const Blob* blobs();
}

namespace pw::script {
const std::string& preludeSource() {
    static const std::string s = [] {
        for (auto* b = embedded_experiments::blobs(); b->key; ++b)
            if (std::strcmp(b->key, "prelude.js") == 0) return std::string(b->data, b->size);
        return std::string();
    }();
    return s;
}
}
