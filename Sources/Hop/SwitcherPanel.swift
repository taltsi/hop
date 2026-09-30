import AppKit

final class SwitcherPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private let panel: NSPanel
    private let list = ListView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 14)
        panel.contentView = background

        list.autoresizingMask = [.width, .height]
        background.addSubview(list)
        list.onHover = { [weak self] in self?.onHover?($0) }
        list.onClick = { [weak self] in self?.onClick?($0) }
    }

    func show(items: [WindowItem], selected: Int, emptyMessage: String) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let maxRows = max(1, Int((area.height * 0.7 - 2 * ListView.inset) / ListView.rowHeight))
        let rows = max(1, min(items.count, maxRows))
        let width = min(640, area.width - 80)
        let height = CGFloat(rows) * ListView.rowHeight + 2 * ListView.inset
        let frame = NSRect(
            x: area.midX - width / 2,
            y: area.midY - height / 2 + area.height * 0.08,
            width: width,
            height: height
        ).integral

        list.items = items
        list.emptyMessage = emptyMessage
        list.visibleCount = rows
        list.offset = 0
        panel.setFrame(frame, display: false)
        list.frame = panel.contentView!.bounds
        update(selected: selected)
        panel.orderFrontRegardless()
    }

    func update(selected: Int) {
        list.select(selected)
    }

    func hide() {
        panel.orderOut(nil)
        list.items = []
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class ListView: NSView {
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = 8

    var items: [WindowItem] = []
    var emptyMessage = ""
    var visibleCount = 0
    var offset = 0
    private var selected = 0

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func select(_ index: Int) {
        selected = index
        if index < offset { offset = index }
        if index >= offset + visibleCount { offset = index - visibleCount + 1 }
        needsDisplay = true
    }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: Self.inset, y: Self.inset + CGFloat(row) * Self.rowHeight,
               width: bounds.width - 2 * Self.inset, height: Self.rowHeight)
    }

    private func index(at point: NSPoint) -> Int? {
        let row = Int(floor((point.y - Self.inset) / Self.rowHeight))
        guard row >= 0, row < visibleCount, offset + row < items.count else { return nil }
        return offset + row
    }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        if items.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let message = emptyMessage as NSString
            let size = message.size(withAttributes: attrs)
            message.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }

        for row in 0..<visibleCount {
            let i = offset + row
            guard i < items.count else { break }
            let item = items[i]
            let rect = rowRect(row)
            let isSelected = i == selected

            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }

            let iconRect = NSRect(x: rect.minX + 8, y: rect.midY - 13, width: 26, height: 26)
            item.icon?.draw(in: iconRect, from: .zero, operation: .sourceOver,
                            fraction: item.isDimmed ? 0.5 : 1, respectFlipped: true, hints: nil)

            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: isSelected ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let subtitle = item.subtitle as NSString
            let subtitleWidth = min(ceil(subtitle.size(withAttributes: subtitleAttrs).width), rect.width * 0.35)
            let subtitleRect = NSRect(x: rect.maxX - 12 - subtitleWidth, y: rect.midY - 8, width: subtitleWidth, height: 16)
            subtitle.draw(with: subtitleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: subtitleAttrs)

            let titleColor: NSColor = isSelected ? .white : (item.isDimmed ? .secondaryLabelColor : .labelColor)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph,
            ]
            let titleX = iconRect.maxX + 10
            let titleRect = NSRect(x: titleX, y: rect.midY - 9, width: subtitleRect.minX - 16 - titleX, height: 18)
            (item.title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClick?(i) }
    }
}
