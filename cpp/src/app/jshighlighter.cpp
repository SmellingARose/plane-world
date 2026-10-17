#include "jshighlighter.h"
#include <QTextDocument>

namespace {
// Block states: 0 normal, 1 inside /* */, 2 inside `template`.
enum { kNormal = 0, kBlockComment = 1, kTemplate = 2 };
const char* const kHookNames = "genome|terms|decode|init|control|reward|terminate|fitness|descriptor|select|crossover|mutate|ask|tell";
}

JsHighlighter::JsHighlighter(QObject* parent) : QSyntaxHighlighter(parent) {
    m_keywords = QRegularExpression(QStringLiteral(
        "\\b(break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|function|if|import|in|"
        "instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|yield|async|await|NaN|Infinity)\\b"));
    m_numbers = QRegularExpression(QStringLiteral("\\b(0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*\\.?\\d*([eE][+-]?\\d+)?|\\.\\d+([eE][+-]?\\d+)?)\\b"));
    m_functions = QRegularExpression(QStringLiteral("\\b([A-Za-z_$][\\w$]*)\\s*(?=\\()"));
    m_hooks = QRegularExpression(QStringLiteral("\\bfunction\\s+(%1)\\b").arg(QLatin1String(kHookNames)));
    connect(this, &JsHighlighter::colorsChanged, this, [this] { rehighlight(); });
}

void JsHighlighter::setDocument(QQuickTextDocument* d) {
    if (d == m_doc) return;
    m_doc = d;
    QSyntaxHighlighter::setDocument(d ? d->textDocument() : nullptr);
    emit documentChanged();
}

void JsHighlighter::setErrorLine(int l) {
    if (l == m_errorLine) return;
    const int old = m_errorLine;
    m_errorLine = l;
    if (QTextDocument* d = QSyntaxHighlighter::document()) {
        if (old > 0) rehighlightBlock(d->findBlockByNumber(old - 1));
        if (l > 0) rehighlightBlock(d->findBlockByNumber(l - 1));
    }
    emit errorLineChanged();
}

void JsHighlighter::highlightBlock(const QString& text) {
    QTextCharFormat kw, str, num, com, fn, hook;
    kw.setForeground(m_kw); kw.setFontWeight(QFont::DemiBold);
    str.setForeground(m_str);
    num.setForeground(m_num);
    com.setForeground(m_com); com.setFontItalic(true);
    fn.setForeground(m_fn);
    hook.setForeground(m_hook); hook.setFontWeight(QFont::Bold);

    for (auto it = m_functions.globalMatch(text); it.hasNext();) { auto m = it.next(); setFormat(int(m.capturedStart(1)), int(m.capturedLength(1)), fn); }
    for (auto it = m_keywords.globalMatch(text); it.hasNext();) { auto m = it.next(); setFormat(int(m.capturedStart()), int(m.capturedLength()), kw); }
    for (auto it = m_numbers.globalMatch(text); it.hasNext();) { auto m = it.next(); setFormat(int(m.capturedStart()), int(m.capturedLength()), num); }
    for (auto it = m_hooks.globalMatch(text); it.hasNext();) { auto m = it.next(); setFormat(int(m.capturedStart(1)), int(m.capturedLength(1)), hook); }

    // Strings and comments override everything above; scanned left to right so quotes inside comments (and
    // comment markers inside strings) are handled.
    int state = previousBlockState() < 0 ? kNormal : previousBlockState();
    int i = 0;
    const int n = int(text.size());
    int start = 0;
    if (state == kBlockComment) {
        int e = int(text.indexOf(QStringLiteral("*/")));
        if (e < 0) { setFormat(0, n, com); setCurrentBlockState(kBlockComment); goto marks; }
        setFormat(0, e + 2, com); i = e + 2; state = kNormal;
    } else if (state == kTemplate) {
        int e = int(text.indexOf(QChar('`')));
        if (e < 0) { setFormat(0, n, str); setCurrentBlockState(kTemplate); goto marks; }
        setFormat(0, e + 1, str); i = e + 1; state = kNormal;
    }
    while (i < n) {
        const QChar c = text[i];
        if (c == '/' && i + 1 < n && text[i + 1] == '/') { setFormat(i, n - i, com); i = n; break; }
        if (c == '/' && i + 1 < n && text[i + 1] == '*') {
            int e = int(text.indexOf(QStringLiteral("*/"), i + 2));
            if (e < 0) { setFormat(i, n - i, com); state = kBlockComment; i = n; break; }
            setFormat(i, e + 2 - i, com); i = e + 2; continue;
        }
        if (c == '"' || c == '\'' || c == '`') {
            start = i++;
            bool closed = false;
            while (i < n) {
                if (text[i] == '\\') { i += 2; continue; }
                if (text[i] == c) { closed = true; ++i; break; }
                ++i;
            }
            setFormat(start, i - start, str);
            if (!closed && c == '`') state = kTemplate;
            continue;
        }
        ++i;
    }
    setCurrentBlockState(state);
marks:
    if (m_errorLine > 0 && currentBlock().blockNumber() == m_errorLine - 1) {
        // Wavy underline across the line (keeps the colours readable).
        for (int k = 0; k < n; ++k) {
            QTextCharFormat f = format(k);
            f.setUnderlineStyle(QTextCharFormat::WaveUnderline);
            f.setUnderlineColor(m_err);
            setFormat(k, 1, f);
        }
    }
}

QString JsHighlighter::newlineIndent(const QString& text, int pos) {
    pos = std::clamp(pos, 0, int(text.size()));
    int ls = int(text.lastIndexOf('\n', pos - 1)) + 1;
    QString indent;
    for (int k = ls; k < pos && (text[k] == ' ' || text[k] == '\t'); ++k) indent += text[k];
    int b = pos - 1;
    while (b >= ls && text[b].isSpace()) --b;
    if (b >= ls && (text[b] == '{' || text[b] == '[' || text[b] == '(')) indent += QStringLiteral("    ");
    return QStringLiteral("\n") + indent;
}

QVariantList JsHighlighter::lineRange(const QString& text, int a, int b) {
    if (a > b) std::swap(a, b);
    int first = int(text.left(a).count('\n')), last = int(text.left(b).count('\n'));
    if (b > a && b > 0 && text[b - 1] == '\n') last = std::max(first, last - 1);
    return {first, last};
}

int JsHighlighter::lineStart(const QString& text, int line) {
    int pos = 0;
    for (int l = 1; l < line; ++l) {
        int nl = int(text.indexOf('\n', pos));
        if (nl < 0) return int(text.size());
        pos = nl + 1;
    }
    return pos;
}

QVariantMap JsHighlighter::transformLines(const QString& text, int selStart, int selEnd, const QString& op) {
    auto r = lineRange(text, selStart, selEnd);
    const int first = r[0].toInt(), last = r[1].toInt();
    const int start = lineStart(text, first + 1);
    int end = lineStart(text, last + 2);
    if (end > start && end <= int(text.size()) && end > 0 && text[end - 1] == '\n' && last + 1 < int(text.count('\n')) + 1) end -= 1;
    QStringList lines = text.mid(start, end - start).split('\n');
    bool allCommented = true;
    for (auto& l : lines) if (!l.trimmed().isEmpty() && !l.trimmed().startsWith("//")) allCommented = false;
    for (auto& l : lines) {
        if (op == "indent") l = QStringLiteral("    ") + l;
        else if (op == "unindent") { int k = 0; while (k < 4 && k < l.size() && l[k] == ' ') ++k; if (k == 0 && l.startsWith('\t')) k = 1; l = l.mid(k); }
        else if (op == "comment") {
            if (l.trimmed().isEmpty()) continue;
            int k = 0; while (k < l.size() && l[k].isSpace()) ++k;
            if (allCommented) { l.remove(k, l.mid(k).startsWith("// ") ? 3 : 2); }
            else l.insert(k, QStringLiteral("// "));
        }
    }
    QString block = lines.join('\n');
    QVariantMap m;
    m["text"] = text.left(start) + block + text.mid(end);
    m["start"] = start; m["end"] = start + int(block.size());
    return m;
}

QStringList JsHighlighter::definedHooks(const QString& text) {
    QStringList out;
    QRegularExpression re(QStringLiteral("(?:^|\\n)\\s*(?:async\\s+)?function\\s+(%1)\\s*\\(").arg(QLatin1String(kHookNames)));
    for (auto it = re.globalMatch(text); it.hasNext();) { auto n = it.next().captured(1); if (!out.contains(n)) out << n; }
    return out;
}
