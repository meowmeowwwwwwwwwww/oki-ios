// Reminders (TZ §3 «Уведомления», Даша 2026-10-18). An app from SideStore gets no push from a server,
// so Oki puts its reminders on the phone in advance, like alarms, and they come on time even offline.
// The list comes from two places, both made by notify.js:
//  • the web app, after every change (the newest state: what is done, moved or deleted);
//  • data/notify.oki from the collector: tasks it found in mail, Telegram or notes while Oki was closed.
//    The shell fetches it in the background, when «Заметки» closes, and from the «Обновить напоминания Oki» action.
import AppIntents
import BackgroundTasks
import CryptoKit
import Foundation
import UserNotifications

struct Reminder: Codable {
  let id: String
  var at: String?        // local time 'YYYY-MM-DDTHH:MM'; none = show now
  let title: String
  let body: String
  var go: String?        // where the app opens, '#/task/<id>'
  var quiet: Bool?       // quiet hours: no sound, the screen stays dark
  var created: String?   // new tasks only
  var items: [Reminder]? // new tasks only: their own reminders
}

final class Bell: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Bell()
  static let job = "io.github.meowmeowwwwwwwwwww.oki.refresh"

  private struct FromApp: Codable { let made: String; let plan: [Reminder]; let known: [String]; let quiet: [String] }
  private struct FromCollector: Codable { let at: String; let fresh: [Reminder] }

  private let center = UNUserNotificationCenter.current()
  private let d = UserDefaults.standard
  private let appKey = "oki.bell.app", colKey = "oki.bell.collector", shownKey = "oki.bell.shown"

  var report: ((String) -> Void)? // the page learns 'on' | 'off' | 'ask' (Настройки → Уведомления)
  var show: ((String) -> Void)?   // a tap opens this place in the app
  var waiting: String?            // a tap came before the page was ready

  // MARK: background refresh

  static func register() {
    UNUserNotificationCenter.current().delegate = shared
    BGTaskScheduler.shared.register(forTaskWithIdentifier: job, using: nil) { t in
      guard let t = t as? BGAppRefreshTask else { return t.setTaskCompleted(success: false) }
      later()
      let work = Task { await shared.refresh(); t.setTaskCompleted(success: true) }
      t.expirationHandler = { work.cancel() }
    }
  }

  // iOS decides when exactly; the collector writes new tasks every half hour from 7 to 23:30
  static func later() {
    let r = BGAppRefreshTaskRequest(identifier: job)
    r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
    try? BGTaskScheduler.shared.submit(r)
  }

  // MARK: from the web app

  func fromApp(_ body: Any) {
    guard let b = body as? [String: Any] else { return }
    if b["ask"] as? Bool == true { Task { await ask() }; return }
    guard let data = try? JSONSerialization.data(withJSONObject: b), (try? JSONDecoder().decode(FromApp.self, from: data)) != nil else { return }
    d.set(data, forKey: appKey)
    Task { await place() }
  }

  func ask() async {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    await tell()
    await place()
  }

  func tell() async {
    let s = await center.notificationSettings().authorizationStatus
    let word = s == .denied ? "off" : s == .notDetermined ? "ask" : "on"
    await MainActor.run { report?(word) }
  }

  // MARK: from the collector

  func refresh() async {
    guard let c = Repo.load(), let key = Data(base64Encoded: c.key) else { return }
    var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(c.owner)/\(c.repo)/contents/data/notify.oki")!)
    r.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
    r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    r.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (raw, res) = try? await URLSession.shared.data(for: r), (res as? HTTPURLResponse)?.statusCode == 200,
          let json = unseal(raw, key), (try? JSONDecoder().decode(FromCollector.self, from: json)) != nil else { return }
    d.set(json, forKey: colKey)
    await place()
  }

  // "OKI1" + AES-GCM(json), key = SHA-256(key bytes): the same as sync.js, vault.py and Notes.swift
  private func unseal(_ raw: Data, _ key: Data) -> Data? {
    guard raw.count > 4, raw.prefix(4) == Data("OKI1".utf8),
          let box = try? AES.GCM.SealedBox(combined: raw.dropFirst(4)) else { return nil }
    return try? AES.GCM.open(box, using: SymmetricKey(data: SHA256.hash(data: key)))
  }

  // MARK: putting them on the phone

  private func place() async {
    let s = await center.notificationSettings().authorizationStatus
    guard s == .authorized || s == .provisional || s == .ephemeral else { return }
    let app = d.data(forKey: appKey).flatMap { try? JSONDecoder().decode(FromApp.self, from: $0) }
    let col = d.data(forKey: colKey).flatMap { try? JSONDecoder().decode(FromCollector.self, from: $0) }
    let now = Self.stamp(Date())
    var plan = app?.plan ?? []
    var fresh: [Reminder] = []
    // a task the app has not seen yet: found by the collector after the app last looked
    // (one the app saw and Даша deleted is older than the app's list, so it stays deleted)
    let known = Set(app?.known ?? []), since = app.map { Self.stamp(Self.date($0.made).addingTimeInterval(-15 * 60)) } ?? ""
    for f in col?.fresh ?? [] where !known.contains(f.id) && (f.created ?? "") >= since {
      plan += f.items ?? []
      fresh.append(f)
    }
    center.removeAllPendingNotificationRequests()
    for n in plan.filter({ ($0.at ?? "") > now }).sorted(by: { $0.at! < $1.at! }).prefix(60) {
      add(n, at: Self.date(n.at!))
    }
    // «Новая задача», once for each (Даша: каждая отдельно); the very first time only remember them
    let first = d.object(forKey: shownKey) == nil
    var shown = d.stringArray(forKey: shownKey) ?? []
    let quiet = app?.quiet ?? ["23:00", "08:00"]
    for var f in fresh where !shown.contains(f.id) {
      shown.append(f.id)
      if first { continue }
      f.quiet = Self.inside(String(now.suffix(5)), quiet)
      add(Reminder(id: "new:" + f.id, at: nil, title: f.title, body: f.body, go: f.go, quiet: f.quiet), at: nil)
    }
    d.set(Array(shown.suffix(300)), forKey: shownKey)
  }

  private func add(_ n: Reminder, at: Date?) {
    let c = UNMutableNotificationContent()
    c.title = n.title
    c.body = n.body
    c.userInfo = ["go": n.go ?? "#/home"]
    if n.quiet == true { c.interruptionLevel = .passive } else { c.sound = .default }
    let when = at.map { UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0), repeats: false) }
    center.add(UNNotificationRequest(identifier: n.id, content: c, trigger: when))
  }

  private static func inside(_ t: String, _ q: [String]) -> Bool {
    guard q.count == 2 else { return false }
    return q[0] > q[1] ? t >= q[0] || t < q[1] : t >= q[0] && t < q[1]
  }

  private static let fmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return f
  }()
  static func stamp(_ d: Date) -> String { fmt.string(from: d) }
  static func date(_ s: String) -> Date { fmt.date(from: String(s.prefix(16))) ?? Date() }

  // MARK: UNUserNotificationCenterDelegate

  // Oki is open: show it anyway, quietly if it is a quiet one
  func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
    n.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound]
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    let go = r.notification.request.content.userInfo["go"] as? String ?? "#/home"
    await MainActor.run { if let show { show(go) } else { waiting = go } }
  }
}

// For «Команды»: e.g. add it to the automation that refreshes SideStore, or run it by hand
struct RefreshBell: AppIntent {
  static var title: LocalizedStringResource = "Обновить напоминания Oki"
  static var description = IntentDescription("Oki проверит, нет ли новых задач, и обновит напоминания на этом iPhone.")
  static var openAppWhenRun = false

  func perform() async throws -> some IntentResult {
    await Bell.shared.refresh()
    return .result()
  }
}
