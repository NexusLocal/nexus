import AppKit
import SwiftUI

// A plain text editor with line numbers. It marks the line with an error.
struct CodeEditor: NSViewRepresentable {
    @Binding var lines: [String]
    var errorLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(lines: $lines)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.writingToolsBehavior = .none
        textView.inlinePredictionType = .no
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalRulerView = LineNumberRuler(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.lines = $lines

        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        let text = lines.joined(separator: "\n")
        if textView.string != text {
            textView.string = text
            context.coordinator.undoManager.removeAllActions()
        }

        markErrorLine(in: textView)
        scrollView.verticalRulerView?.needsDisplay = true
    }

    private func markErrorLine(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            return
        }

        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)

        guard let errorLine, errorLine >= 1, errorLine <= lines.count else {
            return
        }

        let start = lines.prefix(errorLine - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let range = NSRange(location: start, length: (lines[errorLine - 1] as NSString).length)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor(Color.errorBackground), forCharacterRange: range)
    }

    // The text view gets its own undo manager. When text from the model replaces the text in the
    // view, the undo steps of the old text must not apply to the new text.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var lines: Binding<[String]>
        let undoManager = UndoManager()

        init(lines: Binding<[String]>) {
            self.lines = lines
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            lines.wrappedValue = textView.string.components(separatedBy: "\n")
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = 28
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = textView.string as NSString
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        var characterIndex = 0
        var lineNumber = 1

        let drawNumber = { (lineRect: NSRect) in
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 6, y: offset + lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attributes)
        }

        while characterIndex < text.length {
            let lineRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            drawNumber(layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil))

            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // An empty text, or a text that ends with a line break, has one more empty line.
        if text.length == 0 || text.hasSuffix("\n") {
            drawNumber(layoutManager.extraLineFragmentRect)
        }
    }
}
