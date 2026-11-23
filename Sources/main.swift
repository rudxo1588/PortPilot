import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let service = PortService()
    private let worker = DispatchQueue(label: "local.portpilot.worker", qos: .userInitiated)
    private var window: NSWindow!
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["전체", "Java", "개발 프로세스"], trackingMode: .selectOne, target: nil, action: nil)
    private let refreshButton = NSButton(title: "새로고침", target: nil, action: nil)
    private let stopButton = NSButton(title: "선택 종료…", target: nil, action: nil)
    private let forceButton = NSButton(title: "강제 종료…", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "선택 없음")
    private let statusLabel = NSTextField(wrappingLabelWithString: "포트 조회 중…")
    private let resultView = NSTextView()
    private var allListeners: [Listener] = []
    private var visible: [Listener] = []
    private var checked = Set<String>()
    private var results: [TerminationResult] = []
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PortPilot · 포트와 프로세스"
        window.minSize = NSSize(width: 1030, height: 650)
        window.center()
        let content = window.contentView!
        let title = NSTextField(labelWithString: "포트와 프로세스")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "TCP LISTEN · 현재 사용자만 종료 가능 · 강제 종료는 별도 확인")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        search.placeholderString = "포트, PID, 프로세스명, 소유자, Java 앱 검색"
        search.delegate = self
        search.setAccessibilityLabel("포트 및 프로세스 검색")
        search.sendsSearchStringImmediately = true
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString: "Java·개발 필터에 IDE와 빌드 도구 포함")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let toolbar = NSStackView(views: [search, filter, refreshButton])
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
        table.setAccessibilityLabel("TCP LISTEN 포트 목록")
        let columns: [(String, String, CGFloat)] = [("check", "선택", 45), ("port", "포트", 65), ("process", "프로세스", 140), ("pid", "PID", 70), ("owner", "소유자", 95), ("java", "Java 앱 / 용도", 235), ("address", "주소", 135), ("safety", "종료 가능 여부", 205)]
        for (id, label, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            column.minWidth = id == "check" ? width : 55
            column.resizingMask = id == "check" ? [] : [.userResizingMask]
            table.addTableColumn(column)
        }
        scroll.documentView = table
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
        let actionBar = NSStackView(views: [selectionLabel, spacer, forceButton, stopButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 12
        let resultTitle = NSTextField(labelWithString: "종료 결과")
        resultTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let resultScroll = NSScrollView()
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
        let stack = NSStackView(views: [title, subtitle, toolbar, hint, scroll, actionBar, resultTitle, resultScroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            actionBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultScroll.heightAnchor.constraint(equalToConstant: 142),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count, let column = tableColumn else { return nil }
        let listener = visible[row]
        if column.identifier.rawValue == "check" {
            let cell = NSView()
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
            button.tag = row
            button.state = checked.contains(listener.id) ? .on : .off
            button.isEnabled = !busy && listener.blockedReason == nil && listener.identity != nil
            button.setAccessibilityLabel("\(listener.processName) PID \(listener.pid) 포트 \(listener.port) 선택")
            button.toolTip = listener.blockedReason ?? "프로세스 종료 시 이 PID의 모든 포트가 닫힙니다."
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
        case "process": label.stringValue = listener.processName
        case "pid": label.stringValue = String(listener.pid); label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "owner": label.stringValue = listener.owner
        case "java": label.stringValue = listener.javaApp ?? (listener.isJava ? "Java · 식별자 확인 불가" : "—")
        case "address": label.stringValue = listener.address
        case "safety": label.stringValue = listener.blockedReason ?? (listener.identity == nil ? "신원 확인 불가" : "일반 종료 가능"); label.textColor = listener.blockedReason == nil ? .secondaryLabelColor : .systemOrange
        default: break
        }
        if listener.blockedReason != nil && column.identifier.rawValue != "safety" { label.textColor = .secondaryLabelColor }
        label.toolTip = label.stringValue
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        guard !busy, sender.tag < visible.count else { return }
        let listener = visible[sender.tag]
        guard listener.blockedReason == nil, listener.identity != nil else { return }
        if sender.state == .on { checked.insert(listener.id) } else { checked.remove(listener.id) }
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter(clearSelection: true) }
    @objc private func filterChanged() { applyFilter(clearSelection: true) }

    private func applyFilter(clearSelection: Bool) {
        if clearSelection { checked.removeAll() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visible = allListeners.filter { row in
            let matchFilter = filter.selectedSegment == 0 || (filter.selectedSegment == 1 ? row.isJava : row.isDevelopment)
            let haystack = "\(row.port) \(row.pid) \(row.processName) \(row.owner) \(row.address) \(row.javaApp ?? "")".lowercased()
            return matchFilter && (query.isEmpty || haystack.contains(query))
        }
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let rows = allListeners.filter { checked.contains($0.id) }
        let processes = Set(rows.map(\.pid)).count
        selectionLabel.stringValue = rows.isEmpty ? "선택 없음 · \(visible.count)개 포트 표시" : "\(rows.count)개 포트 선택 · \(processes)개 프로세스"
        stopButton.isEnabled = !busy && !rows.isEmpty
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

    @objc private func refresh() {
        guard !busy else { return }
        checked.removeAll()
        setBusy(true, status: "포트·프로세스 조회 중…")
        worker.async {
            let outcome = Result { try self.service.snapshot() }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let snapshot):
                    self.allListeners = snapshot.listeners
                    self.applyFilter(clearSelection: true)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    self.statusLabel.stringValue = "\(formatter.string(from: Date())) 새로고침 · \(snapshot.listeners.count)개 TCP LISTEN 항목" + (snapshot.warning.map { " · \($0)" } ?? "")
                case .failure(let error):
                    self.allListeners = []
                    self.applyFilter(clearSelection: true)
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

    @objc private func stopSelected() {
        guard !busy else { return }
        let selectedPIDs = Set(allListeners.filter { checked.contains($0.id) }.map(\.pid))
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
                    self.allListeners = snapshot.listeners
                    self.applyFilter(clearSelection: true)
                    self.statusLabel.stringValue = "처리 완료 · TCP LISTEN 목록 재확인" + (snapshot.warning.map { " · \($0)" } ?? "")
                } else {
                    self.allListeners = []
                    self.applyFilter(clearSelection: true)
                    self.statusLabel.stringValue = "처리 후 목록 조회 실패 · 새로고침 필요"
                }
                self.setBusy(false)
            }
        }
    }

    private func renderResults() {
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
        alert.informativeText = "TCP LISTEN 포트 조회와 프로세스 종료\n전체 명령줄·환경변수 표시 및 저장 없음"
        alert.runModal()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
