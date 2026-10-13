import AppKit

/// Bottom bar: index state on the left, result count / search time (or a query error) in
/// the middle, FSEvents activity on the right.
final class StatusBarView: NSView {
    private let stateDot = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "Starting…")
    private let resultLabel = NSTextField(labelWithString: "")
    private let activityDot = NSImageView()
    private let eventsLabel = NSTextField(labelWithString: "")
    private let rescanButton = NSButton()
    var onRescan: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let small = NSFont.systemFont(ofSize: 11)
        for l in [stateLabel, resultLabel, eventsLabel] {
            l.font = small
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        resultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let dotConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        stateDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Index state")?.withSymbolConfiguration(dotConfig)
        stateDot.contentTintColor = .systemOrange
        activityDot.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "File system activity")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
        activityDot.contentTintColor = .systemGreen
        activityDot.alphaValue = 0.2
        activityDot.toolTip = "Flashes when file-system changes are applied to the index"

        rescanButton.bezelStyle = .accessoryBarAction
        rescanButton.isBordered = false
        rescanButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rescan")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        rescanButton.contentTintColor = .secondaryLabelColor
        rescanButton.toolTip = "Rescan the index"
        rescanButton.target = self
        rescanButton.action = #selector(rescan)

        let left = NSStackView(views: [stateDot, stateLabel, rescanButton])
        left.spacing = 5
        let right = NSStackView(views: [eventsLabel, activityDot])
        right.spacing = 5
        let spacer1 = NSView(), spacer2 = NSView()
        let stack = NSStackView(views: [left, spacer1, resultLabel, spacer2, right])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        spacer1.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(stack)

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            spacer1.widthAnchor.constraint(equalTo: spacer2.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func rescan() { onRescan?() }

    enum Tone { case busy, ready, failed }

    func setIndexState(_ text: String, tone: Tone) {
        stateLabel.stringValue = text
        stateDot.contentTintColor = switch tone {
        case .busy: .systemOrange
        case .ready: .systemGreen
        case .failed: .systemRed
        }
        rescanButton.isEnabled = tone != .busy
    }

    func setResults(_ text: String, isError: Bool = false) {
        resultLabel.stringValue = text
        resultLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        resultLabel.toolTip = isError ? text : nil
    }

    func setEventCount(_ n: Int) {
        eventsLabel.stringValue = n > 0 ? "\(Formatting.number(n)) recent changes" : ""
    }

    func pulseActivity() {
        activityDot.alphaValue = 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.9
            activityDot.animator().alphaValue = 0.2
        }
    }
}

/// Non-blocking Full Disk Access notice shown above the results.
final class PermissionBannerView: NSView {
    var onOpenSettings: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let title = NSTextField(labelWithString: "Full Disk Access is off")
        title.font = .boldSystemFont(ofSize: 12)
        let body = NSTextField(wrappingLabelWithString:
            "Protected folders (Mail, Messages, Safari, other apps' containers…) can't be indexed and will be missing from results. Grant EFM Full Disk Access in System Settings; EFM rescans automatically when access is granted.")
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 600
        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let open = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openSettings))
        open.bezelStyle = .push
        open.controlSize = .small
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss") ?? NSImage(),
                             target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, text, open, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func dismiss() { onDismiss?() }
}
