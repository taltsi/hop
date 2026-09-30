import AppKit

/// The switcher's state machine. Driven from the main thread by HotkeyTap.
final class Switcher {
    /// A quick ⌘Tab tap switches without ever flashing the panel.
    private static let showDelay: TimeInterval = 0.12

    private(set) var isActive = false
    private var allItems: [WindowItem]?
    private var items: [WindowItem] = []
    private var selected = 0
    private var pendingDelta = 0
    private var flipped = false // ⌃ held: invert the "all desktops" setting
    private var commitRequested = false
    private var wantsPanel = false
    private var generation = 0
    private var showWork: DispatchWorkItem?

    private let store = WindowStore()
    private let panel = SwitcherPanel()

    init() {
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.commit()
        }
    }

    func warmUp() {
        store.warmUp()
    }

    func begin(reverse: Bool, flipped: Bool) {
        isActive = true
        allItems = nil
        items = []
        pendingDelta = reverse ? -1 : 1
        self.flipped = flipped
        commitRequested = false
        wantsPanel = false
        generation += 1

        // Enumerate off the main thread so a slow app can't stall the event tap.
        let gen = generation
        let store = store
        store.queue.async { [weak self] in
            let list = store.snapshot()
            DispatchQueue.main.async { self?.loaded(list, generation: gen) }
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.wantsPanel = true
            self.showPanelIfReady()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func loaded(_ list: [WindowItem], generation gen: Int) {
        guard gen == generation, isActive else { return }
        allItems = list
        applyFilter()
        selected = wrap(pendingDelta)
        if commitRequested { commit() } else { showPanelIfReady() }
    }

    /// Called as ⌃ goes down or up while the switcher is open.
    func setFlipped(_ flipped: Bool) {
        guard isActive, flipped != self.flipped else { return }
        self.flipped = flipped
        guard allItems != nil else { return }

        let previous = items.indices.contains(selected) ? items[selected].id : nil
        applyFilter()
        selected = items.firstIndex { $0.id == previous } ?? min(1, max(items.count - 1, 0))
        showPanelIfReady()
    }

    private func applyFilter() {
        let all = allItems ?? []
        items = Settings.showAllDesktops != flipped ? all : all.filter(\.isOnCurrentSpace)
    }

    private func showPanelIfReady() {
        guard wantsPanel, allItems != nil else { return }
        let showingAll = Settings.showAllDesktops != flipped
        panel.show(items: items, selected: selected,
                   emptyMessage: showingAll ? "No windows" : "No windows on this desktop")
    }

    func step(_ delta: Int) {
        guard isActive else { return }
        guard allItems != nil else { pendingDelta += delta; return }
        select(wrap(selected + delta))
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selected = index
        panel.update(selected: index)
    }

    func commit() {
        guard isActive else { return }
        guard allItems != nil else { commitRequested = true; return }
        let item = items.indices.contains(selected) ? items[selected] : nil
        end()
        if let item { store.queue.async { item.focus() } }
    }

    func cancel() {
        end()
    }

    private func end() {
        isActive = false
        showWork?.cancel()
        showWork = nil
        allItems = nil
        items = []
        panel.hide()
    }

    private func wrap(_ index: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        return ((index % items.count) + items.count) % items.count
    }
}
