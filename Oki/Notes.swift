// Notes → Oki (TZ §5 «Заметки на iPhone»). Apple Notes has no way in from outside, so a Shortcuts automation
// («Заметки» closed → Найти заметки → Отправить заметки в Oki) hands the notes to this action.
// Only new or changed notes go on: sealed with Даша's OKI key, the same way as the web app (sync.js),
// into inbox/ of her private repo. The collector reads them there and deletes them.
import AppIntents
import CryptoKit
import Foundation
import Security

// The repo and keys come from the web app (Sync) through the bridge in App.swift and live in the Keychain,
// readable after the first unlock: the automation may run while the screen is off.
enum Repo {
  struct Creds: Codable { let token: String; let owner: String; let repo: String; let key: String } // key = base64 of the 25 key bytes
  private static let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "oki.gh"]

  static func save(_ c: Creds?) {
    SecItemDelete(q as CFDictionary)
    guard let c, let data = try? JSONEncoder().encode(c) else { return }
    var add = q
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }

  static func load() -> Creds? {
    var get = q
    get[kSecReturnData as String] = true
    var out: AnyObject?
    guard SecItemCopyMatching(get as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return try? JSONDecoder().decode(Creds.self, from: data)
  }
}

struct OkiError: Error, CustomLocalizedStringResourceConvertible {
  let text: String
  var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}

struct SendNotes: AppIntent {
  static var title: LocalizedStringResource = "Отправить заметки в Oki"
  static var description = IntentDescription("Oki найдёт в заметках задачи. Отправляются только новые и изменённые заметки, зашифрованными.")
  static var openAppWhenRun = false

  @Parameter(title: "Заметки", inputConnectionBehavior: .connectToPreviousIntentResult) var notes: [String]

  static var parameterSummary: some ParameterSummary { Summary("Отправить \(\.$notes) в Oki") }

  private static let sentKey = "oki.notes.sent"

  func perform() async throws -> some IntentResult {
    guard let c = Repo.load(), let key = Data(base64Encoded: c.key) else {
      throw OkiError(text: "Откройте Oki: хранилище ещё не подключено на этом iPhone.")
    }
    let d = UserDefaults.standard
    var sent = d.stringArray(forKey: Self.sentKey) ?? []
    let first = d.object(forKey: Self.sentKey) == nil // the very first time: these notes were written before Oki
    var fresh: [String] = [], hashes: [String] = []
    for n in notes {
      let text = String(n.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000))
      if text.isEmpty { continue } // a locked note gives no text
      let h = SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
      if sent.contains(h) || hashes.contains(h) { continue }
      fresh.append(text); hashes.append(h)
    }
    if !fresh.isEmpty {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Europe/Moscow"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
      let body: [String: Any] = ["v": 1, "at": f.string(from: Date()), "first": first, "notes": fresh]
      try await put(c, name: "inbox/\(uid()).oki", sealed: try seal(JSONSerialization.data(withJSONObject: body), key))
    }
    sent = Array((sent + hashes).suffix(500))
    d.set(sent, forKey: Self.sentKey)
    await Bell.shared.refresh() // a good moment to look for new tasks too (Notify.swift)
    return .result()
  }

  // "OKI1" + iv + AES-GCM(json), key = SHA-256(key bytes) — exactly sync.js and vault.py
  private func seal(_ data: Data, _ key: Data) throws -> Data {
    let k = SymmetricKey(data: SHA256.hash(data: key))
    guard let box = try AES.GCM.seal(data, using: k).combined else { throw OkiError(text: "Не получилось зашифровать заметки.") }
    return Data("OKI1".utf8) + box
  }

  private func put(_ c: Repo.Creds, name: String, sealed: Data) async throws {
    var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(c.owner)/\(c.repo)/contents/\(name)")!)
    r.httpMethod = "PUT"
    r.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    r.httpBody = try JSONSerialization.data(withJSONObject: ["message": "oki", "content": sealed.base64EncodedString()])
    let code: Int
    do { code = ((try await URLSession.shared.data(for: r)).1 as? HTTPURLResponse)?.statusCode ?? 0 }
    catch { throw OkiError(text: "Нет интернета. Заметки уйдут в следующий раз.") }
    switch code {
    case 200, 201: return
    case 401: throw OkiError(text: "Ключ GitHub больше не действует. Откройте Oki → Настройки → Хранение.")
    default: throw OkiError(text: "GitHub не принял заметки (\(code)). Попробую в следующий раз.")
    }
  }

  // like store.js: base36 time + random tail
  private func uid() -> String {
    let abc = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    return String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36) + String((0..<5).map { _ in abc.randomElement()! })
  }
}
