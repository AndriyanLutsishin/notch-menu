import Foundation
@testable import NotchCore

/// Годинник, який тест може «перемотувати» вперед.
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

struct ClipboardHistoryTests {
    func новіші_вгорі_і_без_дублів() {
        let clock = FakeClock()
        let h = ClipboardHistory(now: { clock.now })
        h.add("перший")
        clock.advance(minutes: 1)
        h.add("другий")
        clock.advance(minutes: 1)
        h.add("перший")  // повтор піднімається нагору, а не дублюється
        expect(h.items.map(\.text) == ["перший", "другий"])
    }

    func записи_зникають_через_годину() {
        let clock = FakeClock()
        let h = ClipboardHistory(now: { clock.now })
        h.add("старий")
        clock.advance(minutes: 30)
        h.add("новий")
        clock.advance(minutes: 29)
        expect(h.items.map(\.text) == ["новий", "старий"])   // 59 хв — ще живий
        clock.advance(minutes: 1.01)
        expect(h.items.map(\.text) == ["новий"])             // 60 хв — «старий» зник
        clock.advance(minutes: 30)
        expect(h.items.isEmpty)                               // через годину після «нового» — порожньо
    }

    func пошук_без_регістру_і_старі_не_знаходяться() {
        let clock = FakeClock()
        let h = ClipboardHistory(now: { clock.now })
        h.add("Привіт, Світ")
        h.add("інше")
        expect(h.search("світ").map(\.text) == ["Привіт, Світ"])
        expect(h.search("").count == 2)
        clock.advance(minutes: 61)
        expect(h.search("світ").isEmpty)
    }

    func порожнє_не_зберігається_а_очистити_все_працює() {
        let h = ClipboardHistory()
        expect(h.add("   \n") == false)
        h.add("щось")
        h.clear()
        expect(h.items.isEmpty)
    }

    func обмеження_кількості() {
        let h = ClipboardHistory(maxItems: 3)
        for i in 1...5 { h.add("\(i)") }
        expect(h.items.map(\.text) == ["5", "4", "3"])
    }
}

struct PasteboardPolicyTests {
    func приховані_типи_пропускаються() {
        expect(PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceBundleID: nil))
        expect(PasteboardPolicy.shouldSkip(types: ["org.nspasteboard.TransientType"], sourceBundleID: nil))
        expect(!PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari"))
    }

    func менеджери_паролів_пропускаються() {
        expect(PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password"))
        expect(PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.agilebits.onepassword7"))
        expect(PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.keychainaccess"))
        expect(PasteboardPolicy.shouldSkip(types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Passwords"))
    }

    func ключі_й_токени_розпізнаються() {
        expect(PasteboardPolicy.looksLikeSecret("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"))
        expect(PasteboardPolicy.looksLikeSecret("uQ3kz8Lr0bVxW2m9TnYp4Hs7Ec1Gd6Fa5Jo0Ki3Mv8Bw"))  // схоже на токен монобанку
        expect(PasteboardPolicy.looksLikeSecret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"))
    }

    func звичайний_текст_не_вважається_секретом() {
        expect(!PasteboardPolicy.looksLikeSecret("Привіт! Зустрінемось о 15:00?"))
        expect(!PasteboardPolicy.looksLikeSecret("https://www.google.com/search?q=notch"))
        expect(!PasteboardPolicy.looksLikeSecret("a3f9c2e1b7d4058e6f1a2b3c4d5e6f7a8b9c0d1e"))  // git-хеш (лише малі літери)
        expect(!PasteboardPolicy.looksLikeSecret("UA213223130000026007233566001"))
    }
}

struct ClaudeAPITests {
    func запит_має_правильну_модель_і_заголовки() throws {
        let r = try ClaudeAPI.makeRequest(prompt: "Привіт", model: .fable, apiKey: "test-key")
        expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        expect(r.value(forHTTPHeaderField: "x-api-key") == "test-key")
        expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        expect(body["model"] as? String == "claude-fable-5-1")
        expect(body["stream"] as? Bool == true)
        expect(body["thinking"] == nil)  // для Fable 5.1 параметр thinking не можна задавати
        let msgs = body["messages"] as! [[String: Any]]
        expect(msgs.first?["content"] as? String == "Привіт")
    }

    func розбір_потоку() {
        expect(ClaudeAPI.parseStreamLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Пари"}}"#) == .text("Пари"))
        expect(ClaudeAPI.parseStreamLine(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) == .stop(reason: "end_turn"))
        expect(ClaudeAPI.parseStreamLine("event: ping") == nil)
        expect(ClaudeAPI.parseStreamLine(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}"#) == nil)
        if case .error(let msg) = ClaudeAPI.parseStreamLine(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) {
            expect(msg.contains("перевантажений"))
        } else {
            expect(false, "очікувалась помилка")
        }
    }

    func посилання_в_застосунок_claude() {
        let url = ClaudeAPI.desktopURL(prompt: "Що таке чубчик?")!
        expect(url.absoluteString.hasPrefix("claude://claude.ai/new?q="))
        expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Що таке чубчик?")
    }
}

struct MonobankTests {
    func розбір_відповіді_про_клієнта() throws {
        let json = """
        {"clientId":"x","name":"Андріян","accounts":[
          {"id":"usd1","balance":5000,"creditLimit":0,"currencyCode":840,"type":"white","maskedPan":["444111******2222"]},
          {"id":"uah1","balance":1234567,"creditLimit":1000000,"currencyCode":980,"type":"black","maskedPan":["537541******1234"]}
        ],"jars":[{"id":"j1","title":"На відпустку","balance":250000,"currencyCode":980,"goal":1000000}]}
        """
        let info = try JSONDecoder().decode(Monobank.ClientInfo.self, from: Data(json.utf8))
        let main = Monobank.mainAccount(info.accounts)
        expect(main?.id == "uah1")
        expect(main?.ownMoney == 234567)
        expect(main?.title == "Чорна ··1234")
        expect(info.jars?.first?.title == "На відпустку")
    }

    func формат_грошей() {
        expect(Monobank.formatMoney(123456, currency: 980) == "1\u{a0}234,56 ₴")
        expect(Monobank.formatMoney(-9500, currency: 980).hasPrefix("−95,00"))
        expect(Monobank.formatMoney(100, currency: 840, showPlus: true) == "+1,00 $")
    }

    func запит_виписки_не_довший_за_31_день() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = Monobank.statementRequest(token: "t", account: "uah1", days: 60, now: now)
        expect(r.url?.path == "/personal/statement/uah1/\(1_800_000_000 - 31 * 86400)/1800000000")
        expect(r.value(forHTTPHeaderField: "X-Token") == "t")
    }

    func значок_з_dock() {
        expect(BadgeParser.parse(#""StatusLabel"={ "label"="7" }"#) == "7")
        expect(BadgeParser.parse(#""StatusLabel"={ "label"="" }"#) == nil)
        expect(BadgeParser.parse("[ NULL ]  ASN:0x0-0x1556555:\n    bundleID=[ NULL ]") == nil)
    }
}

// MARK: - Запуск усіх тестів

@main struct TestMain {
    static func main() {
        print("▸ Історія буфера за годину")
        run("новіші_вгорі_і_без_дублів") { ClipboardHistoryTests().новіші_вгорі_і_без_дублів() }
        run("записи_зникають_через_годину") { ClipboardHistoryTests().записи_зникають_через_годину() }
        run("пошук_без_регістру_і_старі_не_знаходяться") { ClipboardHistoryTests().пошук_без_регістру_і_старі_не_знаходяться() }
        run("порожнє_не_зберігається_а_очистити_все_працює") { ClipboardHistoryTests().порожнє_не_зберігається_а_очистити_все_працює() }
        run("обмеження_кількості") { ClipboardHistoryTests().обмеження_кількості() }
        print("▸ Фільтр паролів і секретів")
        run("приховані_типи_пропускаються") { PasteboardPolicyTests().приховані_типи_пропускаються() }
        run("менеджери_паролів_пропускаються") { PasteboardPolicyTests().менеджери_паролів_пропускаються() }
        run("ключі_й_токени_розпізнаються") { PasteboardPolicyTests().ключі_й_токени_розпізнаються() }
        run("звичайний_текст_не_вважається_секретом") { PasteboardPolicyTests().звичайний_текст_не_вважається_секретом() }
        print("▸ Claude API")
        run("запит_має_правильну_модель_і_заголовки") { try ClaudeAPITests().запит_має_правильну_модель_і_заголовки() }
        run("розбір_потоку") { ClaudeAPITests().розбір_потоку() }
        run("посилання_в_застосунок_claude") { ClaudeAPITests().посилання_в_застосунок_claude() }
        print("▸ Монобанк і значки")
        run("розбір_відповіді_про_клієнта") { try MonobankTests().розбір_відповіді_про_клієнта() }
        run("формат_грошей") { MonobankTests().формат_грошей() }
        run("запит_виписки_не_довший_за_31_день") { MonobankTests().запит_виписки_не_довший_за_31_день() }
        run("значок_з_dock") { MonobankTests().значок_з_dock() }
        print("▸ Claude через підписку")
        run("розбір_потоку_claude_code") { ClaudeCodeTests().розбір_потоку_claude_code() }
        run("аргументи_без_інструментів_і_без_збереження") { ClaudeCodeTests().аргументи_без_інструментів_і_без_збереження() }
        print("▸ Музика")
        run("заголовок_youtube_music") { MusicTests().заголовок_youtube_music() }
        print("▸ Датчики і монобанк")
        run("зведення_датчиків") { SensorTests().зведення_датчиків() }
        run("значки_операцій") { SensorTests().значки_операцій() }
        print("▸ Курс, таймер, попередження, дії")
        run("курс_валют") { ExtrasTests().курс_валют() }
        run("таймер") { ExtrasTests().таймер() }
        run("попередження") { ExtrasTests().попередження() }
        run("дії_над_скопійованим") { ExtrasTests().дії_над_скопійованим() }
        run("тип_скопійованого") { ExtrasTests().тип_скопійованого() }
        print("▸ Мої нагадування")
        run("нагадування_додати_закрити_зберегти") { ReminderTests().нагадування_додати_закрити_зберегти() }
        print("▸ Нові помічники")
        run("розкладка") { HelperTests().розкладка() }
        run("розумні_дії") { HelperTests().розумні_дії() }
        run("калькулятор") { HelperTests().калькулятор() }
        run("шаблони") { HelperTests().шаблони() }
        run("бюджет_на_день") { HelperTests().бюджет_на_день() }
        print("▸ Регресії з баг-тесту")
        run("секрети_всередині_рядка") { RegressionTests().секрети_всередині_рядка() }
        run("хибні_розумні_кнопки") { RegressionTests().хибні_розумні_кнопки() }
        run("калькулятор_межові") { RegressionTests().калькулятор_межові() }
        run("розкладка_символи") { RegressionTests().розкладка_символи() }
        run("пошкоджений_файл_не_затирається") { RegressionTests().пошкоджений_файл_не_затирається() }
        print("▸ Gemini")
        run("gemini_запит_і_потік") { GeminiTests().gemini_запит_і_потік() }
        run("gemini_вибір_моделі") { GeminiTests().gemini_вибір_моделі() }
        run("ключ_gemini_не_в_буфері") { GeminiTests().ключ_gemini_не_в_буфері() }
        finish()
    }
}

struct ClaudeCodeTests {
    func розбір_потоку_claude_code() {
        expect(ClaudeCode.parseLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Син"}}}"#) == .text("Син"))
        expect(ClaudeCode.parseLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Синій"}"#) == .stop(reason: "end_turn"))
        expect(ClaudeCode.parseLine(#"{"type":"system","subtype":"init"}"#) == nil)
        if case .error(let m) = ClaudeCode.parseLine(#"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#) {
            expect(m.contains("не залогінений"))
        } else { expect(false, "очікувалась помилка") }
    }

    func аргументи_без_інструментів_і_без_збереження() {
        let a = ClaudeCode.arguments(model: .fable)
        expect(a.contains("claude-fable-5-1"))
        expect(a.contains("--no-session-persistence"))
        if let i = a.firstIndex(of: "--tools") { expect(a[i + 1] == "") } else { expect(false) }
    }
}

struct MusicTests {
    func заголовок_youtube_music() {
        let a = YouTubeMusicTitle.parse("Dibi Dibi Rek • Ismaël Lô - YouTube Music")
        expect(a?.title == "Dibi Dibi Rek" && a?.artist == "Ismaël Lô")
        let b = YouTubeMusicTitle.parse("Океан Ельзи - Обійми - YouTube Music")
        expect(b?.title == "Океан Ельзи - Обійми" && b?.artist == nil)
        expect(YouTubeMusicTitle.parse("YouTube Music") == nil)
        let w = YouTubeMusicTitle.parseWindow("Falling (blackbear Remix) (feat. blackbear) | YouTube Music – відтворюється аудіо - Google Chrome – Profile")
        expect(w?.title == "Falling (blackbear Remix) (feat. blackbear)" && w?.playing == true)
        let paused = YouTubeMusicTitle.parseWindow("Song • Artist | YouTube Music - Google Chrome – Andriyan")
        expect(paused?.title == "Song" && paused?.artist == "Artist" && paused?.playing == false)
        expect(YouTubeMusicTitle.parseWindow("Netflix – відтворюється аудіо - Google Chrome") == nil)
        expect(YouTubeMusicTitle.parse("  ") == nil)
    }
}

struct SensorTests {
    func зведення_датчиків() {
        let t = SensorSummary.summarize([("PMU tdie1", 48.5), ("PMU tdie7", 61.2), ("gas gauge battery", 31.0),
                                         ("NAND CH0 temp", 39.0), ("PMU tdev3", -20), ("bogus", 400)])
        expect(t.cpu == 61.2)
        expect(t.battery == 31.0)
        expect(t.ssd == 39.0)
        expect(SensorSummary.summarize([]).cpu == nil)
        expect(SensorSummary.feel(45) == "прохолодно" && SensorSummary.feel(90) == "гаряче")
        expect(SensorSummary.cpuLoad(previous: (100, 1000), current: (350, 2000)) == 0.25)
        expect(SensorSummary.cpuLoad(previous: (100, 1000), current: (100, 1000)) == nil)
    }

    func значки_операцій() {
        expect(Monobank.icon(mcc: 5411, amount: -5000) == "🛒")
        expect(Monobank.icon(mcc: 5814, amount: -100) == "🍔")
        expect(Monobank.icon(mcc: 4829, amount: 20000) == "💰")
        expect(Monobank.icon(mcc: nil, amount: -1) == "💳")
        let jar = try! JSONDecoder().decode(Monobank.Jar.self, from: Data(#"{"id":"j","title":"Ціль","balance":2500,"currencyCode":980,"goal":10000}"#.utf8))
        expect(jar.progress == 0.25)
    }
}

struct ExtrasTests {
    func курс_валют() {
        let json = #"[{"currencyCodeA":840,"currencyCodeB":980,"date":1,"rateBuy":41.1,"rateSell":41.6},{"currencyCodeA":978,"currencyCodeB":840,"date":1,"rateBuy":1.07,"rateSell":1.09},{"currencyCodeA":985,"currencyCodeB":980,"date":1,"rateCross":10.42},{"currencyCodeA":978,"currencyCodeB":980,"date":1,"rateBuy":44.9,"rateSell":45.6}]"#
        let all = try! JSONDecoder().decode([MonoCurrency.Rate].self, from: Data(json.utf8))
        let picked = MonoCurrency.pick(all)
        expect(picked.map(\.currencyCodeA) == [840, 978, 985])
        expect(picked[0].sell == 41.6)
        expect(picked[2].sell == 10.42)  // злотий: лише крос-курс
        expect(MonoCurrency.format(41.6) == "41,60")
    }

    func таймер() {
        expect(FocusTimer.format(remaining: 25 * 60) == "25:00")
        expect(FocusTimer.format(remaining: 61.2) == "1:02")
        expect(FocusTimer.format(remaining: 3723) == "1:02:03")
        expect(FocusTimer.format(remaining: -5) == "0:00")
    }

    func попередження() {
        expect(SystemWarning.evaluate(cpu: 92, thermalSerious: false, battery: 80, charging: false) == .hot(92))
        expect(SystemWarning.evaluate(cpu: 50, thermalSerious: false, battery: 12, charging: false) == .lowBattery(12))
        expect(SystemWarning.evaluate(cpu: 50, thermalSerious: false, battery: 12, charging: true) == nil)
        expect(SystemWarning.evaluate(cpu: 60, thermalSerious: false, battery: 50, charging: false) == nil)
    }

    func тип_скопійованого() {
        expect(ClipKind.detect("https://www.apple.com/macbook-pro/") == .link(host: "apple.com"))
        expect(ClipKind.detect("name@example.com") == .email)
        expect(ClipKind.detect("+380 67 123 45 67") == .phone)
        expect(ClipKind.detect("1 234,56") == .number)
        expect(ClipKind.detect("func a() {\n  print(1)\n}") == .code)
        expect(ClipKind.detect("Привіт, як справи?") == .text)
    }

    func дії_над_скопійованим() {
        let p = ClipAction.translate.prompt(for: "Hello")
        expect(p.hasSuffix("\n\nHello"))
        expect(p.contains("Переклади"))
    }
}

struct ReminderTests {
    func нагадування_додати_закрити_зберегти() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("r.json")
        let clock = FakeClock()
        let store = ReminderStore(fileURL: url, now: { clock.now })
        expect(store.add("   ") == nil)
        let a = store.add("Купити молоко")!
        clock.advance(minutes: 1)
        let b = store.add("Подзвонити бухгалтеру")!
        expect(store.sorted.map(\.text) == ["Подзвонити бухгалтеру", "Купити молоко"])
        store.toggle(b.id)
        expect(store.openCount == 1)
        expect(store.sorted.map(\.text) == ["Купити молоко", "Подзвонити бухгалтеру"])  // виконане — вниз
        // Після перезапуску все на місці.
        let reopened = ReminderStore(fileURL: url, now: { clock.now })
        expect(reopened.notes.count == 2 && reopened.openCount == 1)
        reopened.clearDone()
        expect(reopened.notes.map(\.id) == [a.id])
        reopened.delete(a.id)
        expect(ReminderStore(fileURL: url).notes.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }
}

struct HelperTests {
    func розкладка() {
        expect(LayoutFix.convert("ghbdsn") == "привіт")
        expect(LayoutFix.convert("Ghbdsn? zr cghfdb") == "Привіт, як справи")
        expect(LayoutFix.convert("руддщ") == "hello")
    }

    func розумні_дії() {
        expect(SmartAction.detect("UA21 3223 1300 0002 6007 2335 6600 1") == .compactIBAN("UA213223130000026007233566001"))
        expect(SmartAction.detect("20450123456789") == .track("20450123456789"))
        expect(SmartAction.detect("+380 67 123 45 67") == .call("+380 67 123 45 67"))
        expect(SmartAction.detect("name@example.com") == .mail("name@example.com"))
        expect(SmartAction.detect("https://apple.com")?.title == "Відкрити")
        expect(SmartAction.detect("Просто текст") == nil)
        expect(SmartAction.call("+380 67 123").url?.absoluteString == "tel:+38067123")
    }

    func калькулятор() {
        expect(Calculator.evaluate("120$ + 15%") == .init(value: 138, currency: 840))
        expect(Calculator.evaluate("(250+50)*3")?.value == 900)
        expect(Calculator.evaluate("1 200,50 грн / 4")?.value == 300.125)
        expect(Calculator.evaluate("200 - 10%")?.value == 180)
        expect(Calculator.evaluate("50 * 20%")?.value == 10)
        expect(Calculator.evaluate("100€")?.currency == 978)
        expect(Calculator.evaluate("123") == nil)          // просто число
        expect(Calculator.evaluate("привіт 2+2") == nil)   // текст — не калькулятор
        expect(Calculator.evaluate("5/0") == nil)
        expect(Calculator.format(1234.5) == "1\u{00a0}234,50")
    }

    func шаблони() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = TemplateStore(fileURL: url)
        let t = store.add("Нова пошта, відділення 12\nКиїв")!
        expect(store.add("Нова пошта, відділення 12\nКиїв") == nil)  // без дублів
        expect(TemplateStore(fileURL: url).items.first?.title == "Нова пошта, відділення 12")
        store.delete(t.id)
        expect(TemplateStore(fileURL: url).items.isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    func бюджет_на_день() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!   // 11 днів до кінця місяця включно
        func tx(_ day: Int, _ uah: Int) -> Monobank.Transaction {
            let d = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
            return try! JSONDecoder().decode(Monobank.Transaction.self, from: Data("""
            {"id":"\(UUID().uuidString)","time":\(Int(d.timeIntervalSince1970)),"description":"x","amount":\(uah * 100),"currencyCode":980}
            """.utf8))
        }
        let list = [tx(5, -5000), tx(20, -1600), tx(21, -300), tx(21, 2000)]
        let b = Budget.compute(monthly: 18000, transactions: list, now: now, calendar: cal)!
        expect(b.spentMonth == 690000 && b.spentToday == 30000)
        expect(b.allowanceToday == (1800000 - 660000) / 11)
        expect(b.level == 0)
        expect(Budget.compute(monthly: 0, transactions: list, now: now) == nil)
    }
}

struct RegressionTests {
    func секрети_всередині_рядка() {
        expect(PasteboardPolicy.looksLikeSecret("export ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"))
        expect(PasteboardPolicy.looksLikeSecret("Authorization: Bearer uQ3kz8Lr0bVxW2m9TnYp4Hs7Ec1Gd6Fa5Jo0Ki3Mv8Bw"))
        expect(PasteboardPolicy.looksLikeSecret("1234567890:" + "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"))
        expect(!PasteboardPolicy.looksLikeSecret("/Volumes/Backup2024/Photos/SummerTripKyivLvivOdesa2025"))
        expect(!PasteboardPolicy.looksLikeSecret("Documents/Report2024FinalVersionABCdefGHI"))
        expect(!PasteboardPolicy.looksLikeSecret("https://example.com/a?token=uQ3kz8Lr0bVxW2m9TnYp4Hs7Ec1Gd6Fa5Jo"))
        expect(!PasteboardPolicy.looksLikeSecret("Зустріч о 15:30 у кабінеті 204, не забудь документи"))
    }

    func хибні_розумні_кнопки() {
        expect(SmartAction.detect("2026-10-19") == nil)
        expect(SmartAction.detect("1 000 000") == nil)
        expect(SmartAction.detect("123456789") == nil)
        expect(SmartAction.detect("5375 4111 2222 3333") == nil)
        expect(SmartAction.detect("20261019153000") == nil)          // мітка часу, не ТТН
        expect(SmartAction.detect("20450123456789") == .track("20450123456789"))
        expect(SmartAction.detect("067 123 45 67") == .call("067 123 45 67"))
        expect(ClaudeAPI.desktopURL(prompt: "C++ і C#")!.absoluteString.contains("C%2B%2B"))
    }

    func калькулятор_межові() {
        expect(Calculator.evaluate("1\u{00a0}200,50 грн / 4")?.value == 300.125)
        expect(Calculator.evaluate("50% * 200")?.value == 100)
        expect(Calculator.evaluate("100€ + 5$") == nil)
        expect(Calculator.evaluate("10:30") == nil)
        expect(Calculator.evaluate("2026-10-19") == nil)
        expect(Calculator.format(300.125) == "300,13")
        expect(Calculator.evaluate("50%") == nil)
        expect(Calculator.evaluate("2024-10") == nil)
        expect(Calculator.evaluate("10/19") == nil)
        expect(Calculator.evaluate("200 + 10%")?.value == 220)
    }

    func розкладка_символи() {
        expect(LayoutFix.convert("Zr cghfdb&") == "Як справи?")
        expect(LayoutFix.convert("гіук\"ьфшдюсщь") == "user@mail.com")
    }

    func пошкоджений_файл_не_затирається() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("r.json")
        try? Data("{це не json".utf8).write(to: url)
        let store = ReminderStore(fileURL: url)
        store.add("нове")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(files.contains { $0.contains("bak-") }, "старий файл має лишитися як .bak")
        try? FileManager.default.removeItem(at: dir)
    }
}

struct GeminiTests {
    func gemini_запит_і_потік() {
        let r = try! GeminiAPI.makeRequest(prompt: "Привіт", model: "gemini-3.5-flash", apiKey: "AIzaTEST")
        expect(r.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse")
        expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaTEST")
        expect(r.url?.query?.contains("AIza") == false, "ключ не в адресі")
        let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any]
        let parts = ((body?["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        expect(parts?.first?["text"] as? String == "Привіт")
        expect(body?["systemInstruction"] != nil)

        expect(GeminiAPI.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":"Си"},{"text":"ній"}],"role":"model"}}]}"#) == .text("Синій"))
        expect(GeminiAPI.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":"думаю…","thought":true}]}}]}"#) == nil, "думки не показуємо")
        expect(GeminiAPI.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":""}]},"finishReason":"STOP"}]}"#) == nil)
        expect(GeminiAPI.parseStreamLine(#"data: {"candidates":[{"finishReason":"MAX_TOKENS"}]}"#) == .stop(reason: "max_tokens"))
        expect(GeminiAPI.parseStreamLine("") == nil)
        if case .error(let m) = GeminiAPI.parseStreamLine(#"data: {"error":{"code":429,"message":"Resource exhausted"}}"#) {
            expect(m.contains("ліміт"))
        } else { expect(false, "очікувалась помилка") }
        expect(GeminiAPI.friendlyError(status: 400, message: "API key not valid. Please pass a valid API key.").contains("aistudio"))
    }

    func gemini_вибір_моделі() {
        let json = #"""
        {"models":[
          {"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent","countTokens"]},
          {"name":"models/gemini-3.8-flash-lite","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-flash-preview-tts","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-pro","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-10-flash","supportedGenerationMethods":["embedContent"]},
          {"name":"models/gemini-3.10-flash","supportedGenerationMethods":["generateContent"]}
        ]}
        """#
        expect(GeminiAPI.pickModels(from: Data(json.utf8)) == ["gemini-3.10-flash", "gemini-3.8-flash", "gemini-3.5-flash"])
        expect(GeminiAPI.pickModels(from: Data("не json".utf8)).isEmpty)
        expect(AskProvider.gemini.usesClaudeAPI == false)
        expect(AskProvider.codex.usesClaudeAPI == false && AskProvider.opus.usesClaudeAPI)
    }

    func ключ_gemini_не_в_буфері() {
        expect(PasteboardPolicy.looksLikeSecret("AI" + "zaSyD3kz8Lr0bVxW2m9TnYp4Hs7Ec1Gd6Fa5J"))
    }
}
