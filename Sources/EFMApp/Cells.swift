import AppKit

enum ColumnID {
    static let name = NSUserInterfaceItemIdentifier("name")
    static let path = NSUserInterfaceItemIdentifier("path")
    static let size = NSUserInterfaceItemIdentifier("size")
    static let modified = NSUserInterfaceItemIdentifier("dateModified")
    static let created = NSUserInterfaceItemIdentifier("dateCreated")
    static let time = NSUserInterfaceItemIdentifier("time")
    static let kind = NSUserInterfaceItemIdentifier("kind")
}

enum CellStyle {
    static let font = NSFont.systemFont(ofSize: 12)
    static let boldFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    static let rowHeight: CGFloat = 20
}

/// Plain text cell (path, size, dates).
final class TextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment, truncation: NSLineBreakMode, font: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.font = font
        tf.alignment = alignment
        tf.lineBreakMode = truncation
        tf.maximumNumberOfLines = 1
        tf.usesSingleLineMode = true
        tf.cell?.truncatesLastVisibleLine = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(tf)
        textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var secondary = false {
        didSet { updateColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
            : (secondary ? .secondaryLabelColor : .labelColor)
    }
}

/// Icon + name with highlighted match terms; re-renders when the row is selected so the
/// accent colour never sits on an accent-coloured selection.
final class NameCellView: NSTableCellView {
    private var name = ""
    private var terms: [String] = []
    private var dimmed = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        let tf = NSTextField(labelWithString: "")
        tf.font = CellStyle.font
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.usesSingleLineMode = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(iv)
        addSubview(tf)
        imageView = iv
        textField = tf
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
            tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, terms: [String], icon: NSImage?, dimmed: Bool = false) {
        self.name = name
        self.terms = terms
        self.dimmed = dimmed
        imageView?.image = icon
        imageView?.alphaValue = dimmed ? 0.4 : 1
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if oldValue != backgroundStyle { render() } }
    }

    private func render() {
        let selected = backgroundStyle == .emphasized
        let base: NSColor = selected ? .alternateSelectedControlTextColor : (dimmed ? .tertiaryLabelColor : .labelColor)
        let accent: NSColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
        textField?.attributedStringValue = Formatting.highlighted(name, terms: terms, font: CellStyle.font,
                                                                 boldFont: CellStyle.boldFont, color: base, accent: accent)
    }
}

extension NSTableView {
    func reusableCell<T: NSView>(_ id: NSUserInterfaceItemIdentifier, make: () -> T) -> T {
        if let v = makeView(withIdentifier: id, owner: nil) as? T { return v }
        return make()
    }
}
