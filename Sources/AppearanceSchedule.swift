import Foundation

/// 工具可以应用的两种系统外观。
enum AppearanceMode: Equatable {
    /// 使用系统浅色外观。
    case light

    /// 使用系统深色外观。
    case dark

    /// 写入系统外观时所需的深色模式开关。
    var isDark: Bool {
        self == .dark
    }
}

/// 按本地时钟每天重复的外观切换计划。
struct AppearanceSchedule: Equatable {
    /// 切换到浅色的时刻，以当天零点起算的分钟数存储。
    let lightMinute: Int

    /// 切换到深色的时刻，以当天零点起算的分钟数存储。
    let darkMinute: Int

    /// 两个时间都必须在同一天的有效时分范围内，且不能相同。
    init?(lightMinute: Int, darkMinute: Int) {
        guard (0..<1440).contains(lightMinute),
              (0..<1440).contains(darkMinute),
              lightMinute != darkMinute else {
            return nil
        }

        self.lightMinute = lightMinute
        self.darkMinute = darkMinute
    }

    /// 返回指定时刻应该使用的外观，以及严格晚于该时刻的下一次切换时间。
    /// 用昨天、今天和明天计算实际发生的切换点，覆盖午夜前后的时间段。
    func occurrence(at date: Date, calendar: Calendar) -> (mode: AppearanceMode, next: Date)? {
        guard let today = calendar.dateInterval(of: .day, for: date) else {
            return nil
        }

        let yesterday = calendar.dateInterval(of: .day, for: today.start.addingTimeInterval(-1))
        let tomorrow = calendar.dateInterval(of: .day, for: today.end)
        let transitions = [yesterday, today, tomorrow].compactMap { $0 }.flatMap { day in
            [
                transition(to: .light, minute: lightMinute, during: day, calendar: calendar),
                transition(to: .dark, minute: darkMinute, during: day, calendar: calendar)
            ].compactMap { $0 }
        }.sorted { first, second in
            // 跳过的本地时刻可能被顺延到同一时间，取原计划中较晚的外观。
            if first.date == second.date {
                return first.minute < second.minute
            }
            return first.date < second.date
        }

        guard let current = transitions.last(where: { $0.date <= date }),
              let next = transitions.first(where: { $0.date > date }) else {
            return nil
        }

        return (current.mode, next.date)
    }

    /// 计算单日内的实际切换时间。夏令时跳过时刻时顺延至下一可用时间，
    /// 时刻重复时只取第一次。从当天开始前搜索，以便覆盖零点和重复的时刻。
    private func transition(
        to mode: AppearanceMode,
        minute: Int,
        during day: DateInterval,
        calendar: Calendar
    ) -> (mode: AppearanceMode, minute: Int, date: Date)? {
        let time = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        guard let date = calendar.nextDate(
            after: day.start.addingTimeInterval(-1),
            matching: time,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first
        ), date >= day.start, date < day.end else {
            return nil
        }

        return (mode, minute, date)
    }
}
