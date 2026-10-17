#pragma once
// Small, strict JSON DOM (RFC 8259) for craft documents, experiments and parity data. Numbers are parsed with
// std::from_chars (locale independent, correctly rounded), so shortest round-trip decimals recover exact bits.
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace pw::json {

class Value {
public:
    enum class Type : uint8_t { Null, Bool, Number, String, Array, Object };
    Value() = default;
    static Value number(double d) { Value v; v.t_ = Type::Number; v.n_ = d; return v; }
    static Value fromBool(bool b) { Value v; v.t_ = Type::Bool; v.b_ = b; return v; }
    static Value string(std::string s) { Value v; v.t_ = Type::String; v.s_ = std::move(s); return v; }
    static Value array() { Value v; v.t_ = Type::Array; return v; }
    static Value object() { Value v; v.t_ = Type::Object; return v; }

    Type type() const { return t_; }
    bool isNull() const { return t_ == Type::Null; }
    bool isNumber() const { return t_ == Type::Number; }
    bool isString() const { return t_ == Type::String; }
    bool isArray() const { return t_ == Type::Array; }
    bool isObject() const { return t_ == Type::Object; }

    double num(double fallback = 0) const { return t_ == Type::Number ? n_ : fallback; }
    bool boolean(bool fallback = false) const { return t_ == Type::Bool ? b_ : fallback; }
    const std::string& str() const { return s_; }
    const std::vector<Value>& items() const { return a_; }
    std::vector<Value>& items() { return a_; }
    const std::vector<std::pair<std::string, Value>>& members() const { return o_; }
    std::size_t size() const { return t_ == Type::Array ? a_.size() : o_.size(); }
    const Value& operator[](std::size_t i) const { return i < a_.size() ? a_[i] : null(); }
    /// Member lookup (first match); a shared null Value when absent or not an object.
    const Value& operator[](std::string_view key) const;
    bool has(std::string_view key) const;
    void push(Value v) { a_.push_back(std::move(v)); }
    void set(std::string k, Value v) { o_.emplace_back(std::move(k), std::move(v)); }
    static const Value& null();

private:
    Type t_ = Type::Null;
    bool b_ = false;
    double n_ = 0;
    std::string s_;
    std::vector<Value> a_;
    std::vector<std::pair<std::string, Value>> o_;   // insertion order kept (round-trips documents)
};

struct ParseResult { Value value; bool ok = false; std::string error; std::size_t offset = 0; };
ParseResult parse(std::string_view text);
ParseResult parseFile(const std::string& path);
/// Shortest round-trip serialisation (std::to_chars), non-finite numbers as null.
std::string dump(const Value& v, int indent = -1);
std::string formatNumber(double d);
bool readFile(const std::string& path, std::string& out);
}
