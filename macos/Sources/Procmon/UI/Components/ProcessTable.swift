// The process list as an AppKit table.
//
// A SwiftUI list re-walks every row on each update, which for 600 processes
// every two seconds was most of Procmon's main-thread time. NSTableView only
// reconfigures the rows on screen and reuses their views; calling it from
// Swift is a plain Objective-C message send, so nothing is lost crossing over.

import AppKit
import SwiftUI

/// What a row's context menu can do; supplied by the page that owns the table.
struct ProcessActions {
    let inspect: (PID) -> Void
    let quit: (ProcessSample) -> Void
    let forceQuit: (ProcessSample) -> Void
    let pause: (ProcessSample) -> Void
    let resume: (ProcessSample) -> Void
}

struct ProcessTable: NSViewRepresentable {
    let rows: [ProcessSample]
    let columns: [ProcessColumn]
    @Binding var sort: ProcessSort
    let totalMemory: Bytes
    let selected: PID?
    let actions: ProcessActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 10, height: 2)
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: NSTableView?
        private var rows: [ProcessSample] = []
        private var columns: [ProcessColumn] = []
        private var totalMemory = Bytes.zero
        private var sort: Binding<ProcessSort>?
        private var actions: ProcessActions?
        /// Set while the table is changed from SwiftUI, so delegate callbacks
        /// do not echo the change back.
        private var applying = false

        func update(from view: ProcessTable) {
            guard let table else { return }
            applying = true
            defer { applying = false }
            sort = view.$sort
            actions = view.actions
            totalMemory = view.totalMemory
            if view.columns != columns {
                columns = view.columns
                rebuildColumns(table)
            }
            let descriptor = NSSortDescriptor(key: view.sort.column.rawValue, ascending: !view.sort.descending)
            if table.sortDescriptors.first != descriptor {
                table.sortDescriptors = [descriptor]
            }
            rows = view.rows
            table.reloadData()
            if let selected = view.selected, let index = rows.firstIndex(where: { $0.pid == selected }) {
                table.selectRowIndexes([index], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        private func rebuildColumns(_ table: NSTableView) {
            for column in table.tableColumns {
                table.removeTableColumn(column)
            }
            for column in columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
                tableColumn.title = column.title
                tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.isText)
                if column == .name {
                    tableColumn.minWidth = 140
                    tableColumn.resizingMask = .autoresizingMask
                } else {
                    tableColumn.width = column.width
                    tableColumn.minWidth = column.width
                    tableColumn.maxWidth = column.width
                    tableColumn.resizingMask = []
                }
                table.addTableColumn(tableColumn)
            }
            table.sizeLastColumnToFit()
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue), row < rows.count else { return nil }
            let process = rows[row]
            switch column {
            case .name:
                let cell = reuse(tableView, "name") { NameCell() }
                cell.configure(process)
                return cell
            case .memoryShare:
                let cell = reuse(tableView, "share") { ShareCell() }
                cell.share = process.memory.map { $0.ratio(of: totalMemory) }
                return cell
            default:
                let cell = reuse(tableView, column.isNumeric ? "number" : "text") { TextCell(numeric: column.isNumeric) }
                let color: NSColor = switch column.level(process) {
                case .critical: .systemRed
                case .warning: .systemOrange
                case .normal: column.key(process) <= 0 || column == .pid ? .tertiaryLabelColor : .labelColor
                }
                cell.set(column.text(process), color: color)
                return cell
            }
        }

        private func reuse<Cell: NSView>(_ table: NSTableView, _ identifier: String, make: () -> Cell) -> Cell {
            let id = NSUserInterfaceItemIdentifier(identifier)
            if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = id
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  let column = ProcessColumn(rawValue: key)
            else { return }
            sort?.wrappedValue = ProcessSort(column: column, descending: !descriptor.ascending)
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            actions?.inspect(rows[row].pid)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count, let actions else { return }
            let process = rows[table.clickedRow]
            menu.addItem(MenuAction("Inspect") { actions.inspect(process.pid) })
            if let executable = process.executable {
                menu.addItem(MenuAction("Show in Finder") { Finder.reveal(executable) })
            }
            menu.addItem(MenuAction("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.pid.description, forType: .string)
            })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Pause") { actions.pause(process) })
            menu.addItem(MenuAction("Resume") { actions.resume(process) })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Quit") { actions.quit(process) })
            menu.addItem(MenuAction("Force Quit…") { actions.forceQuit(process) })
        }
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc private func run() { handler() }
}

// MARK: - Cells
//
// Laid out by hand in `layout()`: constraint solving for hundreds of cells
// would cost more than drawing them.

/// One line of 13 pt text; fixed, so layout never has to measure a label.
private let lineHeight: CGFloat = 17

@MainActor
private func makeLabel(alignment: NSTextAlignment) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    label.alignment = alignment
    label.lineBreakMode = .byTruncatingMiddle
    label.cell?.truncatesLastVisibleLine = true
    return label
}

private final class TextCell: NSView {
    private let label: NSTextField

    init(numeric: Bool) {
        label = makeLabel(alignment: numeric ? .right : .left)
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    /// Only touches the label when something changed: setting a value
    /// invalidates its layout and drawing even when it is the same.
    func set(_ text: String, color: NSColor) {
        if label.stringValue != text { label.stringValue = text }
        if label.textColor != color { label.textColor = color }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - lineHeight) / 2, width: bounds.width, height: lineHeight)
    }
}

private final class NameCell: NSView {
    private let icon = NSImageView()
    private let label = makeLabel(alignment: .left)
    private let lock = NSImageView()
    private var pid: PID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        lock.image = Glyph.lock.image(size: 11, color: .tertiaryLabelColor)
        for view in [icon, label, lock] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    @MainActor
    func configure(_ process: ProcessSample) {
        // Names, icons and ownership do not change while a process runs.
        guard pid != process.pid else { return }
        pid = process.pid
        label.stringValue = process.name
        // Plain executables get no icon: a placeholder would say nothing.
        icon.image = AppIcons.icon(for: process.executable)
        lock.isHidden = !process.isRestricted
        toolTip = process.isRestricted ? "Owned by another user. Run Procmon with sudo to see its details." : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let lockWidth: CGFloat = lock.isHidden ? 0 : 16
        let labelX: CGFloat = 24
        label.frame = NSRect(x: labelX, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - labelX - lockWidth), height: lineHeight)
        lock.frame = NSRect(x: bounds.width - 12, y: (bounds.height - 11) / 2, width: 11, height: 11)
    }
}

extension Glyph {
    /// The glyph as a template image, tinted by whatever shows it. Toolbar
    /// menus draw only images, not SwiftUI shapes.
    @MainActor
    func templateImage(size: CGFloat) -> NSImage {
        let image = image(size: size, color: .black)
        image.isTemplate = true
        return image
    }

    /// The glyph as an AppKit image, for table cells.
    @MainActor
    func image(size: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(Glyph.stroke * size / Glyph.grid)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(self.path(in: rect, filled: false).cgPath)
            context.strokePath()
            context.addPath(self.path(in: rect, filled: true).cgPath)
            context.fillPath()
            return true
        }
        image.accessibilityDescription = nil
        return image
    }
}

/// A thin bar with a percentage, drawn directly.
private final class ShareCell: NSView {
    var share: Ratio? {
        didSet { if share != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = share.map { $0.percent.description } ?? "–"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.maxX - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        let track = NSRect(x: 0, y: (bounds.height - 4) / 2, width: max(0, bounds.width - 46), height: 4)
        NSColor(Palette.track).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard let share, track.width > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        var filled = track
        filled.size.width = max(4, track.width * share.value)
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
