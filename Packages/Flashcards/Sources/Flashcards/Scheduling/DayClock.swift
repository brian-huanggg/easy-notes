import Foundation

/// 以 Anki 的方式計算「天」：當地時間的換日時間（預設凌晨 4 點）之後才算新的一天。
///
/// swift-fsrs 以 UTC 午夜換日，所以交給它的時間先經過 `schedulerDate` 平移：
/// 第 n 天換日的那一刻對應到 UTC 1970-01-01 之後第 n 天的午夜，同一天內的先後順序不變。
public struct DayClock: Sendable, Equatable {
    public var timeZone: TimeZone
    /// 新的一天從幾點開始（0–23）
    public var rolloverHour: Int

    public init(timeZone: TimeZone = .current, rolloverHour: Int = 4) {
        self.timeZone = timeZone
        self.rolloverHour = rolloverHour
    }

    /// 1970-01-01 起算的第幾天（依當地日期與換日時間）
    public func day(of date: Date) -> Int {
        Int((local(date) / 86_400).rounded(.down))
    }

    /// 第 `day` 天開始的那一刻（當地日期的換日時間）
    public func start(ofDay day: Int) -> Date {
        let target = Double(day) * 86_400 + Double(rolloverHour) * 3600
        // 當地時間 → UTC：以猜測時刻的時區偏移修正一次，夏令時間切換當天再修正一次
        var date = Date(timeIntervalSince1970: target - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: target))))
        date = Date(timeIntervalSince1970: target - Double(timeZone.secondsFromGMT(for: date)))
        return date
    }

    /// 交給 swift-fsrs 的時間：UTC 的日期 = 這裡的「第幾天」
    func schedulerDate(_ date: Date) -> Date {
        let shifted = local(date)
        let day = (shifted / 86_400).rounded(.down)
        return Date(timeIntervalSince1970: day * 86_400 + min(shifted - day * 86_400, 86_399))
    }

    /// 以「換日時間 = 午夜」的當地時間，表示成 1970 起算的秒數
    private func local(_ date: Date) -> TimeInterval {
        date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date)) - Double(rolloverHour) * 3600
    }

    // 公曆日期 ⇄ 1970-01-01 起算的天數（Howard Hinnant 的演算法），不受時區影響
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }
}
