import Foundation

/// 通过 macOS 自带的系统事件应用设置当前用户的全局外观。
enum SystemAppearance {
    /// 在主线程将系统外观设为指定模式，并将自动化授权和脚本执行失败反馈给调用方。
    @MainActor
    static func apply(_ mode: AppearanceMode) throws {
        // 使用明确的目标值，重复执行同一模式不会把外观切换回去。
        _ = try execute("set dark mode of appearance preferences to \(mode.isDark ? "true" : "false")")
    }

    /// 直接读取系统当前的深色状态，在同一次脚本执行中取反并返回实际设定的新模式。
    @MainActor
    static func toggle() throws -> AppearanceMode {
        let result = try execute("""
        set currentDarkMode to (get dark mode of appearance preferences)
        set newDarkMode to not currentDarkMode
        set dark mode of appearance preferences to newDarkMode
        return newDarkMode
        """)
        return result.booleanValue ? .dark : .light
    }

    /// 在主线程执行系统事件命令，统一应用超时设置，并保留授权和执行错误的具体原因。
    @MainActor
    private static func execute(_ commands: String) throws -> NSAppleEventDescriptor {
        let source = """
        tell application id "com.apple.systemevents"
            with timeout of 10 seconds
                \(commands)
            end timeout
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw AppearanceError.scriptUnavailable
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            switch code {
            case -1743:
                // macOS 拒绝了发送 Apple 事件的请求。
                throw AppearanceError.automationDenied
            case -1712:
                // 系统事件未在 AppleScript 指定的时间内应答。
                throw AppearanceError.timedOut
            default:
                let message = errorInfo[NSAppleScript.errorMessage] as? String
                throw AppearanceError.executionFailed(message: message, code: code)
            }
        }
        return result
    }
}

/// 区分授权、超时和执行错误，供菜单和设置窗口显示处理方式。
private enum AppearanceError: LocalizedError {
    /// 系统无法创建用于切换外观的脚本。
    case scriptUnavailable
    /// 系统拦截了应用发往“系统事件”的自动化请求。
    case automationDenied
    /// 系统事件未按时返回执行结果。
    case timedOut
    /// 系统返回其他错误时，保留原始消息及错误码用于定位问题。
    case executionFailed(message: String?, code: Int?)

    /// 返回面向用户的中文错误描述，并附上可用的系统错误信息。
    var errorDescription: String? {
        switch self {
        case .scriptUnavailable:
            return "无法创建切换系统外观的脚本。"
        case .automationDenied:
            return "请在「系统设置 → 隐私与安全性 → 自动化」中，允许本工具控制「系统事件」。"
        case .timedOut:
            return "系统事件响应超时，请重试。"
        case let .executionFailed(message, code):
            let details = [message, code.map { "错误 \($0)" }].compactMap { $0 }.joined(separator: "，")
            return details.isEmpty ? "无法切换系统外观。" : "无法切换系统外观（\(details)）。"
        }
    }
}
