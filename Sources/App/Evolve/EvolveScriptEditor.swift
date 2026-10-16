// OWNED BY evolve-ui builder. ------------------------------------------------------------------------
// JS source editor: NSTextView (monospaced, no smart quotes) with a line-number gutter, lightweight
// JavaScript syntax highlighting, and an inline error marker for ScriptError.line (red gutter + line tint).
import SwiftUI
import AppKit
import PWEvolution

struct EvolveScriptEditor: NSViewRepresentable {
    @Binding var text: String
    var errorLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = JSHighlighter.font
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.delegate = context.coordinator
        tv.string = text
        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.borderType = .bezelBorder
        context.coordinator.ruler = ruler
        JSHighlighter.apply(tv, errorLine: errorLine)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel.filter { NSMaxRange($0.rangeValue) <= (text as NSString).length }
        }
        context.coordinator.ruler?.errorLine = errorLine
        JSHighlighter.apply(tv, errorLine: errorLine)
        if let l = errorLine, l != context.coordinator.lastScrolledError {
            context.coordinator.lastScrolledError = l
            let ns = tv.string as NSString
            var idx = 0, line = 1
            while line < l, idx < ns.length { idx = NSMaxRange(ns.lineRange(for: NSRange(location: idx, length: 0))); line += 1 }
            tv.scrollRangeToVisible(NSRange(location: min(idx, ns.length), length: 0))
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EvolveScriptEditor
        weak var ruler: LineNumberRuler?
        var lastScrolledError: Int?
        init(_ p: EvolveScriptEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            JSHighlighter.apply(tv, errorLine: parent.errorLine)
            ruler?.needsDisplay = true
        }
    }
}

enum JSHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let keywords = ["function", "return", "var", "let", "const", "if", "else", "for", "while", "do", "break", "continue",
                           "new", "true", "false", "null", "undefined", "this", "typeof", "of", "in", "switch", "case", "default", "throw", "try", "catch"]
    private static let kwRE = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b")
    private static let numRE = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?([eE][-+]?\\d+)?\\b")
    private static let strRE = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'|`[^`]*`")
    private static let commentRE = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
    private static let hookRE = try! NSRegularExpression(pattern: "\\b(genome|terms|decode|init|control|reward|terminate|fitness|descriptor|select|crossover|mutate|ask|tell)(?=\\s*\\()")

    static func apply(_ tv: NSTextView, errorLine: Int?) {
        guard let ts = tv.textStorage else { return }
        let ns = ts.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        ts.beginEditing()
        ts.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        func color(_ re: NSRegularExpression, _ c: NSColor) { for m in re.matches(in: ts.string, range: full) { ts.addAttribute(.foregroundColor, value: c, range: m.range) } }
        color(numRE, .systemOrange)
        color(kwRE, .systemPink)
        color(hookRE, .systemTeal)
        color(strRE, .systemGreen)
        color(commentRE, .secondaryLabelColor)
        if let l = errorLine, l >= 1 {
            var idx = 0, line = 1
            while line < l, idx < ns.length { idx = NSMaxRange(ns.lineRange(for: NSRange(location: idx, length: 0))); line += 1 }
            if idx <= ns.length {
                let r = ns.lineRange(for: NSRange(location: min(idx, max(0, ns.length - 1)), length: 0))
                if r.length > 0 { ts.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.25), range: r) }
            }
        }
        ts.endEditing()
    }
}

/// Gutter with line numbers; the error line number is drawn on a red marker.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var errorLine: Int?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // line number of the first visible character
        var line = 1, i = 0
        while i < chars.location { let r = ns.lineRange(for: NSRange(location: i, length: 0)); i = NSMaxRange(r); if i <= chars.location { line += 1 } }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let errAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
        var idx = chars.location
        let inset = tv.textContainerInset.height
        let originY = convert(NSPoint.zero, from: tv).y
        repeat {
            let lr = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.lineRange(for: NSRange(location: min(idx, ns.length - 1 < 0 ? 0 : idx), length: 0))
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: lr.location, length: 0), actualCharacterRange: nil)
            var rect = lm.lineFragmentRect(forGlyphAt: min(gr.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
            if lm.numberOfGlyphs == 0 { rect = NSRect(x: 0, y: 0, width: 0, height: 14) }
            let y = rect.minY + inset + originY
            if line == errorLine {
                NSColor.systemRed.setFill(); NSRect(x: 0, y: y, width: ruleThickness, height: rect.height).fill()
            }
            let s = "\(line)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: ruleThickness - sz.width - 4, y: y + (rect.height - sz.height) / 2), withAttributes: line == errorLine ? errAttrs : attrs)
            line += 1
            idx = NSMaxRange(lr)
            if lr.length == 0 { break }
        } while idx < NSMaxRange(chars) && idx < ns.length
    }
}
