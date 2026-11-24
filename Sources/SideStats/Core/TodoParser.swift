import Foundation

/// Result of parsing a quick-add line such as "call bank tomorrow 10am !!".
struct TodoQuickAdd: Equatable {
    var title: String
    var due: Date?
    var allDay = false
    var priority = 0
    /// The text recognised as the date (for previews).
    var dateText: String?
}

enum TodoParser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static let timePattern = #"(?i)(\d{1,2}[:.]\d{2})|(\d\s*(am|pm|a\.m\.|p\.m\.)(?![a-z]))|\b(noon|midnight|morning|afternoon|evening|tonight|night)\b|\bat\s+\d"#
    private static let dayPattern = #"(?i)\b(today|tonight|tomorrow|tmrw|yesterday|mon|tue|wed|thu|fri|sat|sun|week|month|year|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\d{1,2}[/-]\d{1,2}|\bin\s+\d"#
    private static let danglingBefore = #"(?i)\s*\b(at|on|by|due|until|before|from)\s*$"#
    private static let danglingAfter = #"(?i)^\s*\b(at|on|by)\b\s*$"#

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> TodoQuickAdd {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var priority = 0

        // Priority: leading "!!" / "!!! " or trailing " !" / "!!" / "!!!".
        let lead = s.prefix { $0 == "!" }.count
        if lead > 0 {
            priority = min(3, lead)
            s = String(s.dropFirst(lead)).trimmingCharacters(in: .whitespaces)
        }
        let trail = s.reversed().prefix { $0 == "!" }.count
        if trail > 0 {
            let body = s.dropLast(trail)
            let separated = body.last?.isWhitespace ?? true
            if separated || trail >= 2 {
                priority = max(priority, min(3, trail))
                s = String(body).trimmingCharacters(in: .whitespaces)
            }
        }

        var result = TodoQuickAdd(title: s, priority: priority)
        guard let detector, !s.isEmpty else { return result }
        let ns = s as NSString
        let matches = detector.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard var date = m.date else { continue }
            let text = ns.substring(with: m.range)
            // Ignore bare numbers ("read 1984") and implausible dates.
            if text.allSatisfy({ $0.isNumber || $0.isWhitespace }) { continue }
            if date < now.addingTimeInterval(-7 * 86400) || date > now.addingTimeInterval(5 * 365 * 86400) { continue }

            let hasTime = text.range(of: timePattern, options: .regularExpression) != nil
            let hasDay = text.range(of: dayPattern, options: .regularExpression) != nil
            if !hasTime {
                date = calendar.startOfDay(for: date)
            } else if !hasDay && date < now, let next = calendar.date(byAdding: .day, value: 1, to: date) {
                date = next   // "10am" typed after 10am means tomorrow
            }

            var before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            before = before.replacingOccurrences(of: danglingBefore, with: "", options: .regularExpression)
            let tail = after.range(of: danglingAfter, options: .regularExpression) != nil ? "" : after
            var title = (before + " " + tail)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;-–—")))
            if title.isEmpty { title = s }

            result.title = title
            result.due = date
            result.allDay = !hasTime
            result.dateText = text
            break
        }
        return result
    }
}

/// Section buckets and compact due labels.
enum TodoDue {
    enum Bucket: Int, CaseIterable { case overdue, today, upcoming, none }

    static func isOverdue(_ t: TodoItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = t.due, !t.done else { return false }
        return t.allDay ? due < calendar.startOfDay(for: now) : due < now
    }

    static func bucket(_ t: TodoItem, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
        guard let due = t.due else { return .none }
        if isOverdue(t, now: now, calendar: calendar) { return .overdue }
        return calendar.isDate(due, inSameDayAs: now) ? .today : .upcoming
    }

    static func label(_ t: TodoItem, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let due = t.due else { return nil }
        let time = due.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        let day: String
        switch days {
        case 0: day = t.allDay ? "Today" : ""
        case 1: day = "Tomorrow"
        case -1: day = "Yesterday"
        case 2...6, -6 ... -2: day = due.formatted(.dateTime.weekday(.abbreviated))
        default:
            let sameYear = calendar.component(.year, from: due) == calendar.component(.year, from: now)
            return sameYear ? due.formatted(.dateTime.month(.abbreviated).day())
                : due.formatted(.dateTime.month(.abbreviated).day().year())
        }
        if t.allDay { return day }
        return day.isEmpty ? time : "\(day) \(time)"
    }
}
