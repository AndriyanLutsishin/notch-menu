import AppKit
import CoreAudio
import IOKit.pwr_mgt
import NotchCore
import UniformTypeIdentifiers
import Vision

// MARK: - Розкладка у виділеному тексті (⌃⌥L)

/// Копіює виділене (⌘C), виправляє розкладку, вставляє назад (⌘V) і повертає попередній буфер.
/// Потрібен «Універсальний доступ» (щоб натиснути ⌘C/⌘V за тебе) — він уже є для лічильників.
@MainActor
enum SelectionLayoutFixer {
    private static var running = false

    static func run(clipboard: ClipboardWatcher) {
        guard !running else { return }
        guard AXIsProcessTrusted() else { DockBadges.requestPermission(); return }
        running = true
        // Повна копія буфера (картинки, файли, оформлений текст, позначки паролів) — щоб повернути як було.
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        clipboard.suppress(seconds: 3)  // проміжні копії не потрапляють в історію
        waitForModifiersReleased(tries: 25) {
            let before = pb.changeCount
            press(key: 8)  // ⌘C
            waitForCopy(pb, since: before, tries: 20) { copied in
                guard copied, let text = pb.string(forType: .string), !text.isEmpty else {
                    restore(saved, to: pb)
                    NSSound.beep()
                    running = false
                    return
                }
                pb.clearContents()
                pb.setString(LayoutFix.convert(text), forType: .string)
                press(key: 9)  // ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    restore(saved, to: pb)
                    running = false
                }
            }
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Поки тримаєш ⌃⌥ від гарячої клавіші, програми можуть сприйняти ⌘C як ⌃⌥⌘C — чекаємо до 0,5 с.
    private static func waitForModifiersReleased(tries: Int, then: @escaping () -> Void) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if tries <= 0 || flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { waitForModifiersReleased(tries: tries - 1, then: then) }
        }
    }

    /// Чекаємо, поки програма справді скопіює (до 1 с — повільні програми копіюють не одразу).
    private static func waitForCopy(_ pb: NSPasteboard, since: Int, tries: Int, then: @escaping (Bool) -> Void) {
        if pb.changeCount != since { then(true); return }
        guard tries > 0 else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForCopy(pb, since: since, tries: tries - 1, then: then) }
    }

    private static func press(key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Текст із картинки (локально, вбудоване розпізнавання macOS)

enum ImageText {
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func recognize(_ url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            // Зменшена копія (до 4096 px) з правильним поворотом — фото з iPhone часто «лежать на боці».
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 4096]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let wanted = ["uk-UA", "en-US", "ru-RU"]
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            request.recognitionLanguages = wanted.filter(supported.contains)
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.value
    }
}

// MARK: - «Не засинай»

@MainActor
final class StayAwake: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var until: Date?   // nil при active — «поки не вимкну»
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func start(minutes: Int?) {
        stop()
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Notch Menu: не засинати" as CFString, &assertion)
        guard ok == kIOReturnSuccess else { return }
        active = true
        if let minutes {
            until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if active { IOPMAssertionRelease(assertion) }
        active = false
        until = nil
    }
}

// MARK: - Пауза музики під час дзвінка

/// Раз на 2 с дивиться, чи зайнятий мікрофон (без доступу до самого звуку — лише «так/ні»).
/// Якщо мікрофон зайнятий ≥3 с і відкритий месенджер — ставить музику на паузу, а після дзвінка повертає.
@MainActor
final class CallWatcher {
    private let player: NowPlaying
    private var timer: Timer?
    private var micSince: Date?
    private var quietSince: Date?
    private var pausedByUs = false
    private var askedThisCall = false
    private var pausedSource: MusicSource?
    private let callApps = ["ru.keepcoder.Telegram", "com.viber.osx", "net.whatsapp.WhatsApp", "com.apple.FaceTime",
                            "us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap"]

    var enabled: Bool { UserDefaults.standard.object(forKey: "pauseOnCall") as? Bool ?? true }

    init(player: NowPlaying) { self.player = player }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    private func tick() {
        guard enabled else { return }
        let now = Date()
        if Self.microphoneInUse() && callAppRunning {
            quietSince = nil
            if micSince == nil { micSince = now }
            if !askedThisCall, let since = micSince, now.timeIntervalSince(since) >= 3 {
                askedThisCall = true  // питаємо плеєр один раз за дзвінок
                // Повертати музику будемо лише якщо вона справді грала й ми її зупинили.
                let source = player.source
                player.pauseIfPlaying { [weak self] paused in
                    if paused { self?.pausedByUs = true; self?.pausedSource = source; Debug.log("дзвінок: музику на паузу") }
                }
            }
        } else {
            micSince = nil
            askedThisCall = false
            guard pausedByUs else { return }
            if quietSince == nil { quietSince = now }
            if let q = quietSince, now.timeIntervalSince(q) >= 2 {
                pausedByUs = false
                quietSince = nil
                if player.source == pausedSource { player.resumePlaying() }  // лише те джерело, яке ми зупинили
                Debug.log("дзвінок завершився: музика знову грає")
            }
        }
    }

    private var callAppRunning: Bool {
        callApps.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Чи використовує хтось мікрофон за замовчуванням (CoreAudio, без дозволу на мікрофон).
    static func microphoneInUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
