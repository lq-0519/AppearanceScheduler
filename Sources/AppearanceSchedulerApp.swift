import AppKit
import ServiceManagement

/// 启动只在菜单栏显示的应用，并在 AppKit 事件循环期间保留应用代理。
@main
@MainActor
enum AppearanceSchedulerApp {
    /// 创建菜单栏应用，无需在程序坞中显示图标。
    static func main() {
        let application = NSApplication.shared
        let controller = AppearanceController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) {
            application.run()
        }
    }
}

/// 管理菜单、两个每日切换点，以及用户临时指定的系统外观。
@MainActor
private final class AppearanceController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 本地偏好键。每份计划和临时覆盖各用一个值保存，避免只写了一半的时间组合。
    private enum PreferenceKey {
        /// 依次记录浅色和深色的分钟数。
        static let schedule = "appearanceSchedule"
        /// 记录临时外观及其绝对到期时间，用于重新打开应用后继续生效。
        static let manualOverride = "manualAppearanceOverride"
    }

    /// 手动选择的外观在下一个切换点前优先生效。
    private struct ManualOverride: Codable {
        /// 手动选择是否为深色。
        let isDark: Bool
        /// 手动选择失效的时间。
        let expiresAt: Date
    }

    /// 供计划与临时外观持久化的应用本地偏好。
    private let defaults = UserDefaults.standard
    /// 已保存的计划，首次打开应用时等用户保存时间。
    private var schedule: AppearanceSchedule?
    /// 当前有效的手动选择，跨睡眠和重启保留至到期时间。
    private var manualOverride: ManualOverride?
    /// 只保留下一次切换的一次性定时器，空闲时不做轮询。
    private var timer: Timer?
    /// 保留系统状态项，保证菜单栏图标随应用进程存续。
    private var statusItem: NSStatusItem?
    /// 展示登录项实际状态并提供开关。
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLoginItem), keyEquivalent: "")
    /// 在登录项需要系统批准时提供对应的设置入口。
    private let loginApprovalItem = NSMenuItem(title: "打开登录项设置…", action: #selector(openLoginItems), keyEquivalent: "")
    /// 在后台切换失败后，让用户从菜单查看错误原因。
    private let appearanceErrorItem = NSMenuItem(title: "查看上次切换错误…", action: #selector(showAppearanceError), keyEquivalent: "")
    /// 最近一次切换的失败信息，切换成功后清除。
    private var appearanceError: String?
    /// 设置窗口在首次打开时创建，其后复用。
    private var settingsWindow: ScheduleSettingsWindow?

    /// 生成菜单、恢复上次的计划并监听会影响定时的系统事件。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let minutes = defaults.array(forKey: PreferenceKey.schedule) as? [Int], minutes.count == 2 {
            schedule = AppearanceSchedule(lightMinute: minutes[0], darkMinute: minutes[1])
        }
        if let data = defaults.data(forKey: PreferenceKey.manualOverride) {
            manualOverride = try? PropertyListDecoder().decode(ManualOverride.self, from: data)
        }

        installMenu()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentDidChange(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentDidChange(_:)), name: .NSSystemClockDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentDidChange(_:)), name: .NSSystemTimeZoneDidChange, object: nil
        )
        reconcileAppearance()
    }

    /// 只有打开菜单时才读取登录项状态，及时反映用户在系统设置里的修改。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginApprovalItem.isHidden = status != .requiresApproval
        appearanceErrorItem.isHidden = appearanceError == nil
    }

    /// 创建原生菜单栏图标与菜单，设置窗口仍在需要时才加载。
    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "外观定时器")
        item.button?.toolTip = "外观定时器"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "切到浅色", action: #selector(switchToLight), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "切到深色", action: #selector(switchToDark), keyEquivalent: ""))
        menu.addItem(appearanceErrorItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(loginItem)
        menu.addItem(loginApprovalItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            menuItem.target = self
        }

        item.menu = menu
        statusItem = item
    }

    /// 系统唤醒、时钟变化和时区变化后，从主线程重新应用当前时段并重安排定时。
    @objc private nonisolated func environmentDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.reconcileAppearance()
        }
    }

    /// 根据当前本地时间选择应生效的外观，再安排下一次切换。
    private func reconcileAppearance(interactive: Bool = false) {
        timer?.invalidate()
        timer = nil

        let now = Date()
        guard let occurrence = schedule?.occurrence(at: now, calendar: .autoupdatingCurrent) else {
            return
        }

        if let manualOverride, manualOverride.expiresAt > now {
            // 时区改变后，更早到来的计划点也应结束手动覆盖。
            let expiry = min(manualOverride.expiresAt, occurrence.next)
            if expiry != manualOverride.expiresAt {
                saveManualOverride(ManualOverride(isDark: manualOverride.isDark, expiresAt: expiry))
            }
            armTimer(for: expiry)
            apply(manualOverride.isDark ? .dark : .light, interactive: interactive)
        } else {
            if manualOverride != nil {
                saveManualOverride(nil)
            }
            armTimer(for: occurrence.next)
            apply(occurrence.mode, interactive: interactive)
        }
    }

    /// 使用一次性定时器等待指定时间，在操作系统菜单打开时也能触发。
    private func armTimer(for date: Date) {
        timer?.invalidate()
        let nextTimer = Timer(
            fireAt: date, interval: 0, target: self, selector: #selector(scheduledTimeReached(_:)),
            userInfo: nil, repeats: false
        )
        nextTimer.tolerance = 0.5
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    /// 计划点到来后按实际时间校准，自动跳过睡眠期间错过的切换。
    @objc private func scheduledTimeReached(_ firedTimer: Timer) {
        guard timer === firedTimer else { return }
        reconcileAppearance()
    }

    /// 由菜单立即切换到浅色。
    @objc private func switchToLight() {
        applyManualChoice(.light)
    }

    /// 由菜单立即切换到深色。
    @objc private func switchToDark() {
        applyManualChoice(.dark)
    }

    /// 切换成功后，把手动选择保存到下一个计划点。从未设定时间时只执行即时切换。
    private func applyManualChoice(_ mode: AppearanceMode) {
        guard apply(mode, interactive: true),
              let occurrence = schedule?.occurrence(at: Date(), calendar: .autoupdatingCurrent) else {
            return
        }
        saveManualOverride(ManualOverride(isDark: mode.isDark, expiresAt: occurrence.next))
        armTimer(for: occurrence.next)
    }

    /// 更新内存与本地偏好中的手动选择，清理已经到期或被新计划替换的选择。
    private func saveManualOverride(_ value: ManualOverride?) {
        manualOverride = value
        if let value, let data = try? PropertyListEncoder().encode(value) {
            defaults.set(data, forKey: PreferenceKey.manualOverride)
        } else {
            defaults.removeObject(forKey: PreferenceKey.manualOverride)
        }
    }

    /// 调用系统外观接口。直接操作失败时立即提示，后台失败时保留给菜单查看。
    @discardableResult
    private func apply(_ mode: AppearanceMode, interactive: Bool) -> Bool {
        do {
            try SystemAppearance.apply(mode)
            appearanceError = nil
            return true
        } catch {
            appearanceError = error.localizedDescription
            if interactive {
                showAppearanceError()
            }
            return false
        }
    }

    /// 使用原生提示展示外观切换的具体失败原因。
    @objc private func showAppearanceError() {
        guard let appearanceError else { return }
        showAlert(title: "外观切换失败", message: appearanceError)
    }

    /// 从菜单打开两项时间设置，保存后立即按新时段应用外观。
    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = ScheduleSettingsWindow { [weak self] schedule in
                self?.save(schedule)
            }
        }
        settingsWindow?.show(schedule: schedule)
    }

    /// 成对保存每日切换点，并结束由旧计划决定到期时间的手动选择。
    private func save(_ schedule: AppearanceSchedule) {
        self.schedule = schedule
        defaults.set([schedule.lightMinute, schedule.darkMinute], forKey: PreferenceKey.schedule)
        saveManualOverride(nil)
        reconcileAppearance(interactive: true)
    }

    /// 注册或移除系统登录项，需要额外批准时打开系统设置。
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    openLoginItems()
                }
            }
        } catch {
            if service.status == .requiresApproval {
                openLoginItems()
            } else {
                showAlert(title: "无法更改登录时启动", message: error.localizedDescription)
            }
        }
    }

    /// 打开系统设置的登录项面板，供用户批准登录自启。
    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 停止菜单栏进程，已保存的时间和登录项由系统继续记录。
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// 从仅存在于菜单栏的应用中显示可见的原生错误对话框。
    private func showAlert(title: String, message: String) {
        bringApplicationForward()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 将设置或错误窗口所在的菜单栏应用激活，使窗口能接收键盘输入。
@MainActor
func bringApplicationForward() {
    if #available(macOS 14.0, *) {
        NSApplication.shared.activate()
    } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
