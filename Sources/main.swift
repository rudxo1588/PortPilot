import AppKit
import Foundation

private final class ProcessRankingPanel: NSBox {
    private let capacityLabel = NSTextField(labelWithString: "—")
    private let capacityBar = NSProgressIndicator()
    private var rows: [(rank: NSTextField, name: NSTextField, pid: NSTextField, value: NSTextField)] = []

    init(title: String, symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        borderWidth = 1
        borderColor = .separatorColor
        cornerRadius = 12
        fillColor = .controlBackgroundColor
        contentViewMargins = .zero

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, heading])
        header.spacing = 7

        capacityLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        capacityBar.style = .bar
        capacityBar.controlSize = .small
        capacityBar.isIndeterminate = false
        capacityBar.minValue = 0
        capacityBar.maxValue = 1
        capacityBar.isHidden = true
        capacityBar.setAccessibilityElement(false)
        let stack = NSStackView(views: [header, capacityLabel, capacityBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(8, after: capacityBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        contentView = body
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            capacityBar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        for index in 0..<3 {
            let rank = NSTextField(labelWithString: "")
            rank.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            rank.textColor = .secondaryLabelColor
            let name = NSTextField(labelWithString: index == 0 ? "측정 중…" : "")
            name.lineBreakMode = .byTruncatingMiddle
            name.font = .systemFont(ofSize: index == 0 ? 16 : 12, weight: index == 0 ? .semibold : .regular)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pid = NSTextField(labelWithString: "")
            pid.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            pid.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: index == 0 ? 19 : 12, weight: index == 0 ? .semibold : .medium)
            value.textColor = index == 0 ? tint : .labelColor
            value.alignment = .right
            let line = NSStackView(views: [rank, name, pid, value])
            line.alignment = .firstBaseline
            line.spacing = 6
            stack.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.widthAnchor.constraint(equalTo: stack.widthAnchor),
                rank.widthAnchor.constraint(equalToConstant: 14),
                value.widthAnchor.constraint(greaterThanOrEqualToConstant: 78)
            ])
            rows.append((rank, name, pid, value))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func showCapacity(_ text: String, fraction: Double?) {
        capacityLabel.stringValue = text
        capacityBar.isHidden = fraction == nil
        capacityBar.doubleValue = fraction ?? 0
    }

    func display(_ processes: [ProcessUsage], emptyMessage: String, format: (ProcessUsage) -> String) {
        for (index, row) in rows.enumerated() {
            let process = processes.indices.contains(index) ? processes[index] : nil
            row.rank.stringValue = process == nil ? "" : "\(index + 1)"
            row.name.stringValue = process.map { $0.location?.displayName(for: $0.name) ?? $0.name } ?? (index == 0 ? emptyMessage : "")
            row.name.toolTip = process?.location?.detail ?? process?.name
            row.pid.stringValue = process.map { "PID \($0.pid)" } ?? ""
            row.value.stringValue = process.map(format) ?? ""
        }
    }
}

private enum PortSortColumn: String {
    case cpu, memory, uptime, port

    static let metrics: [Self] = [.cpu, .memory, .uptime]

    var descriptor: NSSortDescriptor {
        NSSortDescriptor(key: rawValue, ascending: self == .port)
    }

    func value(for listener: Listener, usage: ProcessUsage?, sampledAt: Date?) -> Double? {
        switch self {
        case .cpu: return usage?.cpuPercent
        case .memory: return usage.map { Double($0.residentBytes) }
        case .uptime:
            guard let start = usage?.startedAt, let sampledAt else { return nil }
            return max(0, sampledAt.timeIntervalSince(start))
        case .port: return Double(listener.port)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let service = PortService()
    private let worker = DispatchQueue(label: "local.portpilot.worker", qos: .userInitiated)
    private var window: NSWindow!
    private let resourceWorker = DispatchQueue(label: "local.portpilot.resources", qos: .utility)
    private var capacitySampler = SystemCapacitySampler()
    private var samplingResources = false
    private var resourceTimer: Timer?
    private let resourceTime = NSTextField(labelWithString: "측정 중…")
    private let cpuPanel = ProcessRankingPanel(title: "CPU", symbol: "cpu", tint: .systemIndigo)
    private let memoryPanel = ProcessRankingPanel(title: "메모리", symbol: "memorychip", tint: .systemTeal)
    private let resultTitle = NSTextField(labelWithString: "종료 결과")
    private let resultScroll = NSScrollView()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["전체", "Java", "개발 프로세스"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: "새로고침", target: nil, action: nil)
    private let copyPortsButton = NSButton(title: "선택 포트 복사", target: nil, action: nil)
    private let stopButton = NSButton(title: "선택 종료…", target: nil, action: nil)
    private let forceButton = NSButton(title: "강제 종료…", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "선택 없음")
    private let statusLabel = NSTextField(wrappingLabelWithString: "포트 조회 중…")
    private let resultView = NSTextView()
    private var portSnapshot: Snapshot?
    private var resourceSnapshot: ResourceSnapshot?
    private var allListeners: [Listener] { portSnapshot?.listeners ?? [] }
    private var visible: [Listener] = []
    private var checked = Set<String>()
    private var results: [TerminationResult] = []
    private var busy = false

    private var checkedListeners: [Listener] {
        allListeners.filter { checked.contains($0.id) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        resourceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible, !self.window.isMiniaturized, !NSApp.isHidden else { return }
            self.refreshResources()
        }
        resourceTimer?.tolerance = 0.5
    }

    func applicationWillTerminate(_ notification: Notification) {
        resourceTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "PortPilot 정보", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "PortPilot 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)
        let viewItem = NSMenuItem(title: "보기", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "보기")
        let reload = NSMenuItem(title: "새로고침", action: #selector(refresh), keyEquivalent: "r")
        reload.target = self
        viewMenu.addItem(reload)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PortPilot · 포트와 프로세스"
        window.minSize = NSSize(width: 1030, height: 650)
        window.center()
        let content = window.contentView!
        let appIcon = NSImageView()
        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "시스템 사용량")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        resourceTime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resourceTime.textColor = .secondaryLabelColor
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [appIcon, title, titleSpacer, resourceTime])
        header.spacing = 8
        let rankings = NSStackView(views: [cpuPanel, memoryPanel])
        rankings.distribution = .fillEqually
        rankings.alignment = .height
        rankings.spacing = 12
        search.placeholderString = "포트, PID, 프로세스, 프로젝트명·경로 검색"
        search.delegate = self
        search.setAccessibilityLabel("포트 및 프로세스 검색")
        search.sendsSearchStringImmediately = true
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        let portsTitle = NSTextField(labelWithString: "수신 포트")
        portsTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let toolbar = NSStackView(views: [portsTitle, search, filter, refreshButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(toggleClickedRow(_:))
        table.setAccessibilityLabel("TCP LISTEN 포트 목록")
        let columns: [(String, String, CGFloat)] = [
            ("check", "선택", 43), ("port", "포트", 55), ("process", "프로세스 / 프로젝트", 192), ("pid", "PID", 60),
            ("cpu", "CPU", 66), ("memory", "메모리", 82), ("uptime", "실행 시간", 100),
            ("owner", "소유자", 80), ("java", "Java 앱 / 용도", 150), ("address", "주소", 110),
            ("safety", "종료 가능 여부", 160)
        ]
        for (id, label, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            column.minWidth = id == "check" ? width : 55
            column.resizingMask = id == "check" ? [] : [.userResizingMask]
            column.sortDescriptorPrototype = PortSortColumn(rawValue: id)?.descriptor
            table.addTableColumn(column)
        }
        table.sortDescriptors = PortSortColumn.metrics.map(\.descriptor)
        scroll.documentView = table
        copyPortsButton.target = self
        copyPortsButton.action = #selector(copySelectedPorts)
        copyPortsButton.bezelStyle = .rounded
        copyPortsButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyPortsButton.imagePosition = .imageLeading
        stopButton.target = self
        stopButton.action = #selector(stopSelected)
        stopButton.bezelStyle = .rounded
        stopButton.contentTintColor = .systemRed
        stopButton.setAccessibilityLabel("선택한 프로세스 일반 종료")
        forceButton.target = self
        forceButton.action = #selector(forceRemaining)
        forceButton.bezelStyle = .rounded
        forceButton.contentTintColor = .systemRed
        forceButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionBar = NSStackView(views: [selectionLabel, spacer, copyPortsButton, forceButton, stopButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 12
        resultTitle.isHidden = true
        resultTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        resultScroll.isHidden = true
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .bezelBorder
        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.isRichText = false
        resultView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultView.textContainerInset = NSSize(width: 10, height: 8)
        resultView.autoresizingMask = [.width]
        resultView.isVerticallyResizable = true
        resultView.isHorizontallyResizable = false
        resultView.textContainer?.widthTracksTextView = true
        resultView.string = "종료 기록 없음"
        resultView.setAccessibilityLabel("프로세스별 종료 결과")
        resultScroll.documentView = resultView
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, rankings, toolbar, scroll, actionBar, resultTitle, resultScroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: rankings)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            appIcon.widthAnchor.constraint(equalToConstant: 32),
            appIcon.heightAnchor.constraint(equalTo: appIcon.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rankings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rankings.heightAnchor.constraint(equalToConstant: 155),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            actionBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let resultHeight = resultScroll.heightAnchor.constraint(equalToConstant: 84)
        resultHeight.priority = .defaultHigh
        resultHeight.isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        updatePortTable(clearSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count, let column = tableColumn else { return nil }
        let listener = visible[row]
        if column.identifier.rawValue == "check" {
            let cell = NSView()
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
            button.state = checked.contains(listener.id) ? .on : .off
            button.isEnabled = !busy && listener.blockedReason == nil && listener.identity != nil
            button.setAccessibilityLabel("\(listener.processName) PID \(listener.pid) 포트 \(listener.port) 선택")
            button.toolTip = listener.blockedReason
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: cell.centerXAnchor), button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        switch column.identifier.rawValue {
        case "port": label.stringValue = String(listener.port); label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        case "process":
            let location = processLocation(for: listener)
            label.stringValue = location?.displayName(for: listener.processName) ?? listener.processName
            label.toolTip = location?.detail
        case "pid": label.stringValue = String(listener.pid); label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "uptime", "memory", "cpu":
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.stringValue = "—"
            if let ports = portSnapshot, let resources = resourceSnapshot,
               let process = resources.usage(for: listener, in: ports) {
                switch column.identifier.rawValue {
                case "uptime":
                    if let start = process.startedAt {
                        label.stringValue = elapsedText(resources.sampledAt.timeIntervalSince(start))
                    }
                case "memory": label.stringValue = process.memoryText
                default: label.stringValue = process.cpuText
                }
            }
        case "owner": label.stringValue = listener.owner
        case "java": label.stringValue = listener.javaApp ?? (listener.isJava ? "Java · 식별자 확인 불가" : "—")
        case "address": label.stringValue = listener.address
        case "safety": label.stringValue = listener.blockedReason ?? (listener.identity == nil ? "신원 확인 불가" : "일반 종료 가능"); label.textColor = listener.blockedReason == nil ? .secondaryLabelColor : .systemOrange
        default: break
        }
        if listener.blockedReason != nil && column.identifier.rawValue != "safety" { label.textColor = .secondaryLabelColor }
        if label.toolTip == nil { label.toolTip = label.stringValue }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    private func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)일 \(hours % 24)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes % 60)분" }
        if minutes > 0 { return "\(minutes)분 \(seconds % 60)초" }
        return "\(seconds)초"
    }

    @objc private func toggleClickedRow(_ sender: NSTableView) {
        let checkColumn = sender.column(withIdentifier: NSUserInterfaceItemIdentifier("check"))
        guard sender.clickedColumn != checkColumn else { return }
        toggleCheck(at: sender.clickedRow)
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        toggleCheck(at: table.row(for: sender))
    }

    private func toggleCheck(at row: Int) {
        guard !busy, visible.indices.contains(row) else { return }
        let listener = visible[row]
        guard listener.blockedReason == nil, listener.identity != nil else { return }

        let isChecked = !checked.contains(listener.id)
        if isChecked {
            checked.insert(listener.id)
        } else {
            checked.remove(listener.id)
        }

        let checkColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("check"))
        if checkColumn >= 0,
           let button = table.view(atColumn: checkColumn, row: row, makeIfNecessary: false)?.subviews.first as? NSButton {
            button.state = isChecked ? .on : .off
        }
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) { updatePortTable(clearSelection: true) }
    @objc private func filterChanged() { updatePortTable(clearSelection: true) }

    private func sortPorts(_ ports: [Listener]) -> [Listener] {
        let order = table.sortDescriptors.compactMap { descriptor -> (column: PortSortColumn, ascending: Bool)? in
            guard let key = descriptor.key, let column = PortSortColumn(rawValue: key) else { return nil }
            return (column, descriptor.ascending)
        }
        guard !order.isEmpty else { return ports }

        let keyed = ports.map { port in
            let usage = portSnapshot.flatMap { resourceSnapshot?.usage(for: port, in: $0) }
            let values = order.map { $0.column.value(for: port, usage: usage, sampledAt: resourceSnapshot?.sampledAt) }
            return (port: port, values: values)
        }
        // Stable ties retain the listener snapshot's port/PID/address order.
        return keyed.sorted { lhs, rhs in
            for (index, sort) in order.enumerated() {
                let left = lhs.values[index]
                let right = rhs.values[index]
                if left == right { continue }
                guard let left else { return false }
                guard let right else { return true }
                return sort.ascending ? left < right : left > right
            }
            return false
        }.map(\.port)
    }

    private func processLocation(for listener: Listener) -> ProcessLocation? {
        guard let ports = portSnapshot else { return nil }
        return resourceSnapshot?.usage(for: listener, in: ports)?.location
    }

    private func updatePortTable(clearSelection: Bool, refreshingMetrics: Bool = false) {
        if clearSelection { checked.removeAll() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = allListeners.filter { row in
            let matchFilter = filter.selectedSegment == 0 || (filter.selectedSegment == 1 ? row.isJava : row.isDevelopment)
            guard matchFilter, !query.isEmpty else { return matchFilter }
            let location = processLocation(for: row)
            let haystack = "\(row.port) \(row.pid) \(row.processName) \(row.owner) \(row.address) \(row.javaApp ?? "") \(location?.projectName ?? "") \(location?.directory ?? "")".lowercased()
            return haystack.contains(query)
        }
        let sorted = sortPorts(filtered)
        if refreshingMetrics && visible == sorted {
            let identifiers = PortSortColumn.metrics.map(\.rawValue) + ["process"]
            let columns = IndexSet(identifiers.map {
                table.column(withIdentifier: NSUserInterfaceItemIdentifier($0))
            }.filter { $0 >= 0 })
            table.reloadData(forRowIndexes: IndexSet(visible.indices), columnIndexes: columns)
            return
        }
        visible = sorted
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let rows = checkedListeners
        let hasSelection = !busy && !rows.isEmpty
        let processes = Set(rows.map(\.pid)).count
        selectionLabel.stringValue = rows.isEmpty ? "선택 없음 · \(visible.count)개 포트 표시" : "\(rows.count)개 포트 선택 · \(processes)개 프로세스"
        copyPortsButton.isEnabled = hasSelection
        stopButton.isEnabled = hasSelection
        forceButton.isEnabled = !busy && results.contains(where: \.needsForce)
        refreshButton.isEnabled = !busy
        search.isEnabled = !busy
        filter.isEnabled = !busy
    }

    private func setBusy(_ value: Bool, status: String? = nil) {
        busy = value
        if let status { statusLabel.stringValue = status }
        updateButtons()
        table.reloadData()
    }

    private func refreshResources() {
        guard !samplingResources else { return }
        samplingResources = true
        let listenerPIDs = Set(allListeners.map(\.pid))
        resourceWorker.async {
            let capacity = self.capacitySampler.sample()
            let outcome = Result { try PortService.resourceSnapshot(listenerPIDs: listenerPIDs) }
            DispatchQueue.main.async {
                self.samplingResources = false
                self.showCapacity(capacity)
                self.resourceTime.stringValue = DateFormatter.localizedString(from: capacity.sampledAt, dateStyle: .none, timeStyle: .medium)
                switch outcome {
                case .success(let snapshot):
                    self.resourceSnapshot = snapshot
                    self.showRankings(cpu: snapshot.byCPU, memory: snapshot.byMemory, emptyMessage: "표시할 프로세스 없음")
                case .failure:
                    self.resourceSnapshot = nil
                    self.showRankings(cpu: [], memory: [], emptyMessage: "조회 실패")
                }
                self.updatePortTable(clearSelection: false, refreshingMetrics: true)
            }
        }
    }

    private func showCapacity(_ capacity: SystemCapacity) {
        let cores = capacity.coreCount
        var cpuText = "전체 \(cores)코어 · 사용 — · 여유 —"
        if let fraction = capacity.busyFraction {
            let used = (fraction * Double(cores) * 10).rounded() / 10
            cpuText = String(format: "전체 %d코어 · 사용 %.1f코어 · 여유 %.1f코어", cores, used, Double(cores) - used)
        }
        cpuPanel.showCapacity(cpuText, fraction: capacity.busyFraction)

        let total = capacity.totalMemory
        func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
        }
        if let used = capacity.usedMemory {
            let text = "전체 \(size(total)) · 사용 \(size(used)) · 여유(추정) \(size(total - used))"
            memoryPanel.showCapacity(text, fraction: Double(used) / Double(total))
        } else {
            memoryPanel.showCapacity("전체 \(size(total)) · 사용 — · 여유 —", fraction: nil)
        }
    }

    private func showRankings(cpu: [ProcessUsage], memory: [ProcessUsage], emptyMessage: String) {
        cpuPanel.display(cpu, emptyMessage: emptyMessage, format: \.cpuText)
        memoryPanel.display(memory, emptyMessage: emptyMessage, format: \.memoryText)
    }

    @objc private func refresh() {
        guard !busy else { return }
        refreshResources()
        checked.removeAll()
        setBusy(true, status: "포트·프로세스 조회 중…")
        worker.async {
            let outcome = Result { try self.service.snapshot() }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let snapshot):
                    self.portSnapshot = snapshot
                    self.updatePortTable(clearSelection: true)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    self.statusLabel.stringValue = "\(formatter.string(from: Date())) 새로고침 · \(snapshot.listeners.count)개 TCP LISTEN 항목" + (snapshot.warning.map { " · \($0)" } ?? "")
                case .failure(let error):
                    self.portSnapshot = nil
                    self.updatePortTable(clearSelection: true)
                    self.statusLabel.stringValue = "목록 확인 실패: \(error.localizedDescription)"
                }
                self.setBusy(false)
            }
        }
    }

    private func description(for targets: [Target]) -> String {
        targets.map { target in
            let ports = Set(target.listeners.map(\.port)).sorted().map(String.init).joined(separator: ", ")
            let java = target.listeners.compactMap(\.javaApp).first.map { " · \($0)" } ?? ""
            let start = Date(timeIntervalSince1970: Double(target.identity.startedSeconds))
            let date = DateFormatter.localizedString(from: start, dateStyle: .short, timeStyle: .medium)
            return "\(target.identity.name) · PID \(target.identity.pid) · \(target.identity.owner)\(java)\n포트 \(ports) · 시작 \(date)"
        }.joined(separator: "\n\n")
    }

    private func showConfirmation(title: String, detail: String, destructive: String, cancelFirst: Bool, handler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        if cancelFirst { alert.addButton(withTitle: "취소"); alert.addButton(withTitle: destructive) }
        else { alert.addButton(withTitle: destructive); alert.addButton(withTitle: "취소") }
        alert.beginSheetModal(for: window) { response in
            if response == (cancelFirst ? .alertSecondButtonReturn : .alertFirstButtonReturn) { handler() }
        }
    }

    @objc private func copySelectedPorts() {
        guard !busy else { return }
        let ports = Set(checkedListeners.map(\.port)).sorted()
        guard !ports.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(ports.map(String.init).joined(separator: "\n"), forType: .string) {
            statusLabel.stringValue = "포트 번호 \(ports.count)개 복사됨"
        } else {
            statusLabel.stringValue = "포트 번호를 복사하지 못했습니다."
        }
    }

    @objc private func stopSelected() {
        guard !busy else { return }
        let selectedPIDs = Set(checkedListeners.map(\.pid))
        let targets = service.targets(from: allListeners.filter { selectedPIDs.contains($0.pid) })
        guard !targets.isEmpty else { return }
        showConfirmation(title: "\(targets.count)개 프로세스를 종료할까요?", detail: description(for: targets) + "\n\n선택한 PID의 모든 포트와 작업이 종료됩니다. SIGTERM 후 최대 4초 대기하며, 강제 종료는 별도 확인이 필요합니다.", destructive: "일반 종료 (SIGTERM)", cancelFirst: false) {
            self.runTermination(targets, force: false)
        }
    }

    @objc private func forceRemaining() {
        guard !busy else { return }
        let targets = results.filter(\.needsForce).map(\.target)
        guard !targets.isEmpty else { return }
        showConfirmation(title: "남은 \(targets.count)개 프로세스를 강제 종료할까요?", detail: description(for: targets) + "\n\n저장·정리 작업 없이 즉시 종료됩니다(SIGKILL). 프로세스 신원과 포트가 기존 대상과 같을 때만 종료합니다.", destructive: "강제 종료 (SIGKILL)", cancelFirst: true) {
            self.runTermination(targets, force: true)
        }
    }

    private func runTermination(_ targets: [Target], force: Bool) {
        checked.removeAll()
        setBusy(true, status: force ? "대상 재확인 · 강제 종료 중…" : "대상 재확인 · 일반 종료 중…")
        worker.async {
            let batch = force ? self.service.force(targets) : self.service.terminate(targets, timeout: 4)
            let snapshot = try? self.service.snapshot()
            DispatchQueue.main.async {
                if force {
                    let ids = Set(batch.map { $0.target.identity })
                    self.results.removeAll { ids.contains($0.target.identity) }
                    self.results.append(contentsOf: batch)
                } else { self.results = batch }
                self.renderResults()
                if let snapshot {
                    self.portSnapshot = snapshot
                    self.updatePortTable(clearSelection: true)
                    self.statusLabel.stringValue = "처리 완료 · TCP LISTEN 목록 재확인" + (snapshot.warning.map { " · \($0)" } ?? "")
                } else {
                    self.portSnapshot = nil
                    self.updatePortTable(clearSelection: true)
                    self.statusLabel.stringValue = "처리 후 목록 조회 실패 · 새로고침 필요"
                }
                self.setBusy(false)
            }
        }
    }

    private func renderResults() {
        resultTitle.isHidden = results.isEmpty
        resultScroll.isHidden = results.isEmpty
        resultView.string = results.map { result in
            let ports = Set(result.target.listeners.map(\.port)).sorted().map(String.init).joined(separator: ", ")
            let release = result.portsReleased.map { $0 ? "포트 해제 확인" : "포트 점유 남음 / 다른 프로세스가 점유" } ?? "포트 해제 확인 불가"
            return "\(result.target.identity.name) · PID \(result.target.identity.pid) · 포트 \(ports)\n\(result.status) · \(release)\n\(result.detail)"
        }.joined(separator: "\n\n")
        resultView.scrollToBeginningOfDocument(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PortPilot 1.0"
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
