#include "pw/json.h"
#include <charconv>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#if defined(__APPLE__)
#include <xlocale.h>
#endif

namespace pw::json {

const Value& Value::null() { static const Value n; return n; }
const Value& Value::operator[](std::string_view key) const {
    if (t_ == Type::Object) for (auto& [k, v] : o_) if (k == key) return v;
    return null();
}
bool Value::has(std::string_view key) const {
    if (t_ == Type::Object) for (auto& kv : o_) if (kv.first == key) return true;
    return false;
}

namespace {
struct Parser {
    std::string_view s; std::size_t i = 0; std::string err; int depth = 0;
    bool fail(const char* m) { if (err.empty()) err = m; return false; }
    void ws() { while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) ++i; }
    bool lit(std::string_view w) { if (s.substr(i, w.size()) == w) { i += w.size(); return true; } return false; }
    static void utf8(std::string& o, uint32_t c) {
        if (c < 0x80) o += char(c);
        else if (c < 0x800) { o += char(0xC0 | (c >> 6)); o += char(0x80 | (c & 63)); }
        else if (c < 0x10000) { o += char(0xE0 | (c >> 12)); o += char(0x80 | ((c >> 6) & 63)); o += char(0x80 | (c & 63)); }
        else { o += char(0xF0 | (c >> 18)); o += char(0x80 | ((c >> 12) & 63)); o += char(0x80 | ((c >> 6) & 63)); o += char(0x80 | (c & 63)); }
    }
    bool hex4(uint32_t& c) {
        if (i + 4 > s.size()) return fail("truncated \\u escape");
        c = 0;
        for (int k = 0; k < 4; ++k) {
            char h = s[i++]; c <<= 4;
            if (h >= '0' && h <= '9') c |= uint32_t(h - '0');
            else if (h >= 'a' && h <= 'f') c |= uint32_t(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') c |= uint32_t(h - 'A' + 10);
            else return fail("bad \\u escape");
        }
        return true;
    }
    bool str(std::string& o) {
        if (i >= s.size() || s[i] != '"') return fail("expected string");
        ++i;
        while (i < s.size()) {
            char c = s[i++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return fail("control character in string");
            if (c != '\\') { o += c; continue; }
            if (i >= s.size()) break;
            char e = s[i++];
            switch (e) {
            case '"': o += '"'; break; case '\\': o += '\\'; break; case '/': o += '/'; break;
            case 'b': o += '\b'; break; case 'f': o += '\f'; break; case 'n': o += '\n'; break;
            case 'r': o += '\r'; break; case 't': o += '\t'; break;
            case 'u': {
                uint32_t c1; if (!hex4(c1)) return false;
                if (c1 >= 0xD800 && c1 < 0xDC00 && lit("\\u")) {
                    uint32_t c2; if (!hex4(c2)) return false;
                    if (c2 < 0xDC00 || c2 > 0xDFFF) return fail("bad surrogate pair");
                    c1 = 0x10000 + ((c1 - 0xD800) << 10) + (c2 - 0xDC00);
                }
                utf8(o, c1); break;
            }
            default: return fail("bad escape");
            }
        }
        return fail("unterminated string");
    }
    bool number(Value& v) {
        std::size_t b = i;
        if (i < s.size() && s[i] == '-') ++i;
        if (i >= s.size() || !(s[i] >= '0' && s[i] <= '9')) return fail("bad number");
        while (i < s.size() && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.' || s[i] == 'e' || s[i] == 'E' || s[i] == '+' || s[i] == '-')) ++i;
        double d = 0;
#if defined(__APPLE__)
        // libc++ std::from_chars(double) needs macOS 26; strtod_l with the C locale is correctly rounded too.
        std::string tmp(s.substr(b, i - b));
        char* end = nullptr;
        d = strtod_l(tmp.c_str(), &end, LC_C_LOCALE);
        if (end != tmp.c_str() + tmp.size()) return fail("bad number");
#else
        auto r = std::from_chars(s.data() + b, s.data() + i, d);
        if (r.ec != std::errc() || r.ptr != s.data() + i) return fail("bad number");
#endif
        v = Value::number(d);
        // integer literal: keep the exact 64-bit value (doubles lose bits above 2^53)
        bool integral = true; std::size_t q = b; bool neg = false;
        if (q < i && s[q] == '-') { neg = true; ++q; }
        for (std::size_t k = q; k < i; ++k) if (s[k] < '0' || s[k] > '9') { integral = false; break; }
        if (integral && i - q <= 20) {
            uint64_t u = 0; bool ovf = false;
            for (std::size_t k = q; k < i; ++k) { uint64_t dgt = uint64_t(s[k] - '0'); if (u > (~0ull - dgt) / 10) { ovf = true; break; } u = u * 10 + dgt; }
            if (!ovf) {
                if (!neg) v = Value::u64(u);
                else if (u != 0 && u <= 9223372036854775808ull) v = Value::i64(u == 9223372036854775808ull ? INT64_MIN : -int64_t(u));
            }
        }
        return true;
    }
    bool value(Value& v) {
        if (++depth > 512) return fail("nesting too deep");
        ws();
        if (i >= s.size()) return fail("unexpected end");
        char c = s[i];
        bool ok = true;
        if (c == '{') {
            ++i; v = Value::object(); ws();
            if (i < s.size() && s[i] == '}') { ++i; }
            else for (;;) {
                ws(); std::string k; if (!str(k)) { ok = false; break; }
                ws(); if (i >= s.size() || s[i] != ':') { ok = fail("expected ':'"); break; }
                ++i; Value m; if (!value(m)) { ok = false; break; }
                v.set(std::move(k), std::move(m)); ws();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == '}') { ++i; break; }
                ok = fail("expected ',' or '}'"); break;
            }
        } else if (c == '[') {
            ++i; v = Value::array(); ws();
            if (i < s.size() && s[i] == ']') { ++i; }
            else for (;;) {
                Value m; if (!value(m)) { ok = false; break; }
                v.push(std::move(m)); ws();
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == ']') { ++i; break; }
                ok = fail("expected ',' or ']'"); break;
            }
        } else if (c == '"') { std::string t; ok = str(t); v = Value::string(std::move(t)); }
        else if (lit("true")) v = Value::fromBool(true);
        else if (lit("false")) v = Value::fromBool(false);
        else if (lit("null")) v = Value();
        else ok = number(v);
        --depth;
        return ok;
    }
};
void esc(std::string& o, const std::string& s) {
    o += '"';
    for (unsigned char c : s) {
        switch (c) {
        case '"': o += "\\\""; break; case '\\': o += "\\\\"; break; case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break; case '\t': o += "\\t"; break;
        default:
            if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; } else o += char(c);
        }
    }
    o += '"';
}
void dumpTo(std::string& o, const Value& v, int indent, int level) {
    auto nl = [&](int l) { if (indent >= 0) { o += '\n'; o.append(std::size_t(l * indent), ' '); } };
    switch (v.type()) {
    case Value::Type::Null: o += "null"; break;
    case Value::Type::Bool: o += v.boolean() ? "true" : "false"; break;
    case Value::Type::Number:
        if (v.isInteger()) o += v.num() < 0 ? std::to_string(v.asI64()) : std::to_string(v.asU64());
        else o += formatNumber(v.num());
        break;
    case Value::Type::String: esc(o, v.str()); break;
    case Value::Type::Array:
        o += '[';
        for (std::size_t k = 0; k < v.items().size(); ++k) { if (k) o += ','; nl(level + 1); dumpTo(o, v.items()[k], indent, level + 1); }
        if (!v.items().empty()) nl(level);
        o += ']'; break;
    case Value::Type::Object:
        o += '{';
        for (std::size_t k = 0; k < v.members().size(); ++k) {
            if (k) o += ',';
            nl(level + 1); esc(o, v.members()[k].first); o += indent >= 0 ? ": " : ":";
            dumpTo(o, v.members()[k].second, indent, level + 1);
        }
        if (!v.members().empty()) nl(level);
        o += '}'; break;
    }
}
}

ParseResult parse(std::string_view text) {
    ParseResult r; Parser p{text, 0, {}, 0};
    if (p.value(r.value)) { p.ws(); if (p.i == text.size()) r.ok = true; else p.fail("trailing characters"); }
    r.error = p.err; r.offset = p.i;
    return r;
}
bool readFile(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss; ss << f.rdbuf(); out = ss.str(); return true;
}
ParseResult parseFile(const std::string& path) {
    std::string t;
    if (!readFile(path, t)) { ParseResult r; r.error = "cannot read " + path; return r; }
    return parse(t);
}
std::string formatNumber(double d) {
    if (!std::isfinite(d)) return "null";
    char b[40]; auto r = std::to_chars(b, b + sizeof b, d);
    return std::string(b, r.ptr);
}
std::string dump(const Value& v, int indent) { std::string o; dumpTo(o, v, indent, 0); return o; }
}
