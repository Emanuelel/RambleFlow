import AppKit

final class VocabularyRows: NSScrollView {
    private static let limit = 80
    private static let rowHeight: CGFloat = 34
    private let rows = NSStackView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: min(260, CGFloat(rows.arrangedSubviews.count) * Self.rowHeight + 4))
    }

    var terms: [String] {
        rows.arrangedSubviews.compactMap { view -> String? in
            guard let field = (view as? EntryRow)?.field else { return nil }
            return field.currentEditor()?.string ?? field.stringValue
        }
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        borderType = .bezelBorder
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        documentView = rows
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rows.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func load(_ terms: [String]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = terms.flatMap { $0.components(separatedBy: .newlines) }
        for term in entries { append(term) }
        updateListSize()
    }

    func addEntry() -> Bool {
        guard rows.arrangedSubviews.count < Self.limit else { return false }
        let row = append("")
        updateListSize()
        superview?.layoutSubtreeIfNeeded()
        rows.scrollToVisible(row.frame)
        window?.makeFirstResponder(row.field)
        return true
    }

    @discardableResult private func append(_ term: String) -> EntryRow {
        let row = EntryRow(term)
        row.remove.target = self
        row.remove.action = #selector(removeEntry(_:))
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        return row
    }

    @objc private func removeEntry(_ button: NSButton) {
        guard let row = rows.arrangedSubviews.compactMap({ $0 as? EntryRow }).first(where: { $0.remove === button }) else { return }
        if row.field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        row.removeFromSuperview()
        updateListSize()
    }

    private func updateListSize() {
        isHidden = rows.arrangedSubviews.isEmpty
        invalidateIntrinsicContentSize()
    }

    private final class EntryRow: NSStackView {
        let field: NSTextField
        let remove = NSButton()

        init(_ term: String) {
            field = NSTextField(string: term)
            super.init(frame: .zero)
            orientation = .horizontal
            alignment = .centerY
            spacing = 8
            edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
            field.placeholderString = "Name or term"
            field.setAccessibilityLabel("Vocabulary entry")
            field.usesSingleLineMode = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove entry")
            remove.setAccessibilityLabel("Remove entry")
            remove.toolTip = "Remove this entry from the draft"
            remove.isBordered = false
            remove.widthAnchor.constraint(equalToConstant: 26).isActive = true
            addArrangedSubview(field)
            addArrangedSubview(remove)
        }

        required init?(coder: NSCoder) { nil }
    }
}
