import AppKit

/// 显示两个每日切换时间，只有按下保存才将表单内容交给定时逻辑。
@MainActor
final class ScheduleSettingsWindow: NSWindowController {
    /// 时间控件只编辑时分。用固定时区展示这些值，避免编辑时遇到夏令时空档。
    private static let pickerTimeZone = TimeZone(secondsFromGMT: 0)!
    /// 控件使用的基准日期，其 UTC 零点对应当天的第 0 分钟。
    private static let referenceDate = Date(timeIntervalSince1970: 0)
    /// 输入每天切到浅色的时分。
    private let lightPicker = makeTimePicker(label: "每天切到浅色")
    /// 输入每天切到深色的时分。
    private let darkPicker = makeTimePicker(label: "每天切到深色")
    /// 保存已通过校验的时间组合。
    private let onSave: (AppearanceSchedule) -> Void

    /// 创建只包含两个时分控件和保存操作的原生设置窗口。
    init(onSave: @escaping (AppearanceSchedule) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "外观切换时间"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        installContent(in: window)
        window.center()
    }

    /// 设置窗口由代码创建，不从归档或界面文件加载。
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("设置窗口必须由代码创建")
    }

    /// 窗口关闭时用现有计划填充控件。第一次打开时显示建议的 07:00 和 19:00。
    func show(schedule: AppearanceSchedule?) {
        guard let window else { return }
        if !window.isVisible {
            lightPicker.dateValue = Self.referenceDate.addingTimeInterval(Double(schedule?.lightMinute ?? 420) * 60)
            darkPicker.dateValue = Self.referenceDate.addingTimeInterval(Double(schedule?.darkMinute ?? 1140) * 60)
        }
        bringApplicationForward()
        window.makeKeyAndOrderFront(nil)
    }

    /// 放置带说明的两个原生时分控件，并让保存和取消响应回车与 Esc。
    private func installContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let inputs = NSGridView(views: [
            [NSTextField(labelWithString: "每天切到浅色"), lightPicker],
            [NSTextField(labelWithString: "每天切到深色"), darkPicker]
        ])
        inputs.rowAlignment = .firstBaseline
        inputs.rowSpacing = 12
        inputs.columnSpacing = 20
        inputs.column(at: 0).xPlacement = .leading
        inputs.column(at: 1).xPlacement = .leading
        inputs.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelChanges))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveChanges))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(inputs)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            inputs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            inputs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            inputs.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.initialFirstResponder = lightPicker
    }

    /// 创建可键入时分或使用系统步进按钮调整的控件。
    private static func makeTimePicker(label: String) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.timeZone = pickerTimeZone
        picker.setAccessibilityLabel(label)
        return picker
    }

    /// 放弃未保存的时间，关闭设置窗口。
    @objc private func cancelChanges() {
        close()
    }

    /// 提交当前正在编辑的时分，校验后关闭窗口并启用新计划。
    @objc private func saveChanges() {
        guard let window, window.makeFirstResponder(nil) else { return }
        let lightMinute = Self.minute(of: lightPicker)
        let darkMinute = Self.minute(of: darkPicker)
        guard let schedule = AppearanceSchedule(lightMinute: lightMinute, darkMinute: darkMinute) else {
            let alert = NSAlert()
            alert.messageText = "两个切换时间需要不同"
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        close()
        onSave(schedule)
    }

    /// 从固定时区的控件值取时分，保存为当天从零点起算的分钟数。
    private static func minute(of picker: NSDatePicker) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pickerTimeZone
        return calendar.component(.hour, from: picker.dateValue) * 60
            + calendar.component(.minute, from: picker.dateValue)
    }
}
