import AppKit

/// The window toolbar a document gets while it is being read.
///
/// Photographs keep their floating chrome even in a window, because it gets
/// out of the way of the picture. A document is the opposite case: controls
/// fading in over the paragraph you are reading are a nuisance, and a search
/// field needs somewhere to live. So a PDF in a window gets a real toolbar,
/// and the floating chrome stands down.
@MainActor
final class ReaderToolbar: NSObject, NSToolbarDelegate {

    let toolbar = NSToolbar(identifier: "casa.reader")
    private weak var target: ViewerController?
    private var searchItem: NSSearchToolbarItem?

    private enum Item: String, CaseIterable {
        case sidebar, zoomOut, zoomIn, markup, rotate, inspector, share, search

        var identifier: NSToolbarItem.Identifier { .init("casa.reader.\(rawValue)") }
    }

    init(target: ViewerController) {
        self.target = target
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.sidebar.identifier, .flexibleSpace,
         Item.zoomOut.identifier, Item.zoomIn.identifier, .space,
         Item.markup.identifier, Item.rotate.identifier, .space,
         Item.inspector.identifier, Item.share.identifier,
         Item.search.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let item = Item.allCases.first(where: { $0.identifier == identifier }) else { return nil }

        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let entry = NSToolbarItem(itemIdentifier: identifier)
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            entry.label = label
            entry.toolTip = label
            entry.isBordered = true
            entry.target = target
            entry.action = action
            return entry
        }

        switch item {
        case .sidebar:
            return button("sidebar.left", "Sidebar", #selector(ViewerController.toggleSidebar(_:)))
        case .zoomOut:
            return button("minus.magnifyingglass", "Zoom Out", #selector(ViewerController.zoomOut(_:)))
        case .zoomIn:
            return button("plus.magnifyingglass", "Zoom In", #selector(ViewerController.zoomIn(_:)))
        case .markup:
            return button("pencil.tip.crop.circle", "Markup", #selector(ViewerController.toggleMarkup(_:)))
        case .rotate:
            return button("rotate.right", "Rotate Page", #selector(ViewerController.rotateRight(_:)))
        case .inspector:
            return button("info.circle", "Info", #selector(ViewerController.toggleInspector(_:)))
        case .share:
            return button("square.and.arrow.up", "Share", #selector(ViewerController.share(_:)))
        case .search:
            let entry = NSSearchToolbarItem(itemIdentifier: identifier)
            entry.searchField.placeholderString = "Search"
            entry.searchField.target = target
            entry.searchField.action = #selector(ViewerController.searchFieldChanged(_:))
            entry.searchField.sendsWholeSearchString = false
            entry.searchField.sendsSearchStringImmediately = false
            searchItem = entry
            return entry
        }
    }

    /// Puts the insertion point in the search field.
    func beginSearch() {
        searchItem?.beginSearchInteraction()
    }

    var query: String { searchItem?.searchField.stringValue ?? "" }
}
