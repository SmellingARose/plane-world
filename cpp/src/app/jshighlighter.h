#pragma once
// JsHighlighter: JavaScript syntax colouring + error-line marking for a QML TextEdit/TextArea
// (`document: editor.textDocument`). Colours come from QML (the Theme), so light/dark mode stays consistent.
// Also offers editor helpers used by the code editor: indentation-aware newline, (un)indent, comment toggling.
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QSyntaxHighlighter>
#include <QtQml/qqmlregistration.h>

class JsHighlighter : public QSyntaxHighlighter {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickTextDocument* document READ document WRITE setDocument NOTIFY documentChanged)
    Q_PROPERTY(int errorLine READ errorLine WRITE setErrorLine NOTIFY errorLineChanged)   // 1-based, 0 = none
    Q_PROPERTY(QColor keywordColor MEMBER m_kw NOTIFY colorsChanged)
    Q_PROPERTY(QColor stringColor MEMBER m_str NOTIFY colorsChanged)
    Q_PROPERTY(QColor numberColor MEMBER m_num NOTIFY colorsChanged)
    Q_PROPERTY(QColor commentColor MEMBER m_com NOTIFY colorsChanged)
    Q_PROPERTY(QColor functionColor MEMBER m_fn NOTIFY colorsChanged)
    Q_PROPERTY(QColor hookColor MEMBER m_hook NOTIFY colorsChanged)
    Q_PROPERTY(QColor errorColor MEMBER m_err NOTIFY colorsChanged)
public:
    explicit JsHighlighter(QObject* parent = nullptr);
    QQuickTextDocument* document() const { return m_doc; }
    void setDocument(QQuickTextDocument* d);
    int errorLine() const { return m_errorLine; }
    void setErrorLine(int l);

    /// Text to insert for Return at `pos` in `text`: newline + the current line's indentation (+1 level after '{').
    Q_INVOKABLE static QString newlineIndent(const QString& text, int pos);
    /// Lines [first, last] of the selection (0-based) for `selStart`/`selEnd`.
    Q_INVOKABLE static QVariantList lineRange(const QString& text, int selStart, int selEnd);
    /// Rewritten text block with lines indented / unindented / (un)commented; returns {text, start, end}.
    Q_INVOKABLE static QVariantMap transformLines(const QString& text, int selStart, int selEnd, const QString& op);
    /// Character offset of the start of 1-based `line`.
    Q_INVOKABLE static int lineStart(const QString& text, int line);
    /// Names of hooks defined in the source (`function control(` …), for the outline chips.
    Q_INVOKABLE static QStringList definedHooks(const QString& text);
signals:
    void documentChanged();
    void errorLineChanged();
    void colorsChanged();
protected:
    void highlightBlock(const QString& text) override;
private:
    QQuickTextDocument* m_doc = nullptr;
    int m_errorLine = 0;
    QColor m_kw{"#c678dd"}, m_str{"#98c379"}, m_num{"#d19a66"}, m_com{"#7f848e"}, m_fn{"#61afef"}, m_hook{"#e5c07b"}, m_err{"#e5534b"};
    QRegularExpression m_keywords, m_numbers, m_functions, m_hooks;
};
