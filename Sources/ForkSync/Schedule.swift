import SwiftUI

/// Zeitplan fuer den Auto-Sync. Der Nutzer waehlt in Ortszeit, GitHub-Actions erwartet Cron in UTC.
struct Schedule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case hourly, every6h, daily, weekly, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hourly: tr("Stündlich", "Hourly")
            case .every6h: tr("Alle 6 Stunden", "Every 6 hours")
            case .daily: tr("Täglich", "Daily")
            case .weekly: tr("Wöchentlich", "Weekly")
            case .custom: tr("Eigener Cron-Ausdruck", "Custom cron expression")
            }
        }
    }

    var frequency: Frequency = .daily
    var hour = 7
    var minute = 17
    var weekday = 1           // Cron: 0 = Sonntag ... 6 = Samstag; Standard Montag
    var customCron = "17 5 * * *"

    static var weekdays: [String] {
        tr("Sonntag,Montag,Dienstag,Mittwoch,Donnerstag,Freitag,Samstag",
           "Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday").components(separatedBy: ",")
    }

    /// Cron-Ausdruck in UTC.
    var cron: String {
        switch frequency {
        case .hourly: return "\(minute) * * * *"
        case .every6h: return "\(minute) */6 * * *"
        case .custom: return customCron.trimmingCharacters(in: .whitespaces)
        case .daily, .weekly:
            let offsetMin = TimeZone.current.secondsFromGMT() / 60
            let total = hour * 60 + minute - offsetMin
            let dayShift = Int((Double(total) / 1440).rounded(.down))
            let utc = ((total % 1440) + 1440) % 1440
            let dow = frequency == .weekly ? "\(((weekday + dayShift) % 7 + 7) % 7)" : "*"
            return "\(utc % 60) \(utc / 60) * * \(dow)"
        }
    }

    var isValid: Bool {
        guard frequency == .custom else { return true }
        let fields = customCron.split(separator: " ")
        let bounds = [0...59, 0...23, 1...31, 1...12, 0...6]
        return fields.count == 5 && zip(fields, bounds).allSatisfy { Schedule.fieldValid(String($0), $1) }
    }

    /// Ein Cron-Feld: Liste aus `*`, Zahl oder Bereich `a-b`, jeweils optional mit Schrittweite `/n`.
    private static func fieldValid(_ field: String, _ bounds: ClosedRange<Int>) -> Bool {
        let parts = field.split(separator: ",", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            let s = part.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(s.count) else { return false }
            if s.count == 2 { guard let step = Int(s[1]), step > 0 else { return false } }
            if s[0] == "*" { return true }
            let r = s[0].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...2).contains(r.count), r.allSatisfy({ $0.map(bounds.contains) == true }) else { return false }
            return r.count == 1 || r[0]! <= r[1]!
        }
    }

    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .hourly: return tr("Stündlich, zur Minute \(minute)", "Hourly, at minute \(minute)")
        case .every6h: return tr("Alle 6 Stunden, zur Minute \(minute)", "Every 6 hours, at minute \(minute)")
        case .daily: return tr("Täglich um \(time)", "Daily at \(time)")
        case .weekly: return tr("\(Schedule.weekdays[weekday]) um \(time)", "\(Schedule.weekdays[weekday]) at \(time)")
        case .custom: return "Cron: \(customCron)"
        }
    }

    private static let key = "forksync.schedule"
    static func load() -> Schedule {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Schedule.self, from: data) else { return Schedule() }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Schedule.key) }
    }
}

struct ScheduleButton: View {
    @EnvironmentObject var store: Store
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label(store.schedule.summary, systemImage: "clock")
        }
        .help(tr("Zeitplan für den Auto-Sync", "Schedule for auto-sync"))
        .popover(isPresented: $open, arrowEdge: .top) { SchedulePopover().environmentObject(store) }
    }
}

private struct SchedulePopover: View {
    @EnvironmentObject var store: Store

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: store.schedule.hour, minute: store.schedule.minute, second: 0, of: Date()) ?? Date()
        } set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            store.schedule.hour = c.hour ?? 0
            store.schedule.minute = c.minute ?? 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Zeitplan", "Schedule")).font(.headline)
            Picker(tr("Häufigkeit", "Frequency"), selection: $store.schedule.frequency) {
                ForEach(Schedule.Frequency.allCases) { Text($0.title).tag($0) }
            }
            switch store.schedule.frequency {
            case .hourly, .every6h:
                Stepper(tr("Zur Minute: \(store.schedule.minute)", "At minute: \(store.schedule.minute)"), value: $store.schedule.minute, in: 0...59)
            case .daily:
                DatePicker(tr("Uhrzeit", "Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
            case .weekly:
                Picker(tr("Wochentag", "Weekday"), selection: $store.schedule.weekday) {
                    ForEach(0..<7, id: \.self) { Text(Schedule.weekdays[$0]).tag($0) }
                }
                DatePicker(tr("Uhrzeit", "Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
            case .custom:
                TextField("Cron (UTC)", text: $store.schedule.customCron)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if !store.schedule.isValid {
                    Label(tr("Erwartet 5 Felder, z. B. 17 5 * * *", "Expects 5 fields, e.g. 17 5 * * *"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Cron (UTC): \(store.schedule.cron)")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(tr("Gilt für neu eingerichtete Forks. GitHub startet geplante Läufe oft einige Minuten später; Sommer-/Winterzeit verschiebt die Ortszeit um eine Stunde.",
                        "Applies to newly set-up forks. GitHub often starts scheduled runs a few minutes late; daylight saving time shifts local time by one hour."))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
