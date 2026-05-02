import Foundation
import UserNotifications
import AppKit
import os

/// File-based debug log under ~/.ego-mac/debug.log — easy to `tail -f` while iterating.
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ego-mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}

/// Allows banners/sounds to appear even while the popover is the active window.
final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifierDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Native macOS notifications with an osascript fallback for unsigned/non-bundled runs.
enum Notifier {
    /// Best-known UN authorization status. Refreshed on every refreshAuthStatus()
    /// call. We use this to decide whether to attempt UN at all — if it's
    /// denied, UN add() silently swallows the notification, so we go osascript.
    @MainActor static var authStatus: UNAuthorizationStatus = .notDetermined

    @MainActor static var isAuthorized: Bool {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Open System Settings → Notifications. Best-effort URL; falls through to
    /// the legacy bundle-id pref pane if the modern URL isn't recognized.
    @MainActor
    static func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                DebugLog.log("opened notif settings: \(raw)")
                return
            }
        }
        DebugLog.log("failed to open notif settings")
    }

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotifierDelegate.shared

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DebugLog.log("notif auth: granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
            if !granted, let bundleID = Bundle.main.bundleIdentifier {
                DebugLog.log("  → bundleID=\(bundleID)  (Sistem Ayarları → Bildirimler → EGO Mac)")
            }
            refreshAuthStatus()
        }
        refreshAuthStatus()
    }

    static func refreshAuthStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                authStatus = settings.authorizationStatus
                DebugLog.log("notif status now: \(describe(settings.authorizationStatus))")
            }
        }
    }

    /// Public test hook used by the Settings "Test bildirim" button.
    /// Always provides visible feedback regardless of permission state — plays
    /// a system sound + falls back to a modal NSAlert when banner-style is
    /// silently swallowed by macOS.
    @MainActor
    static func sendTest() {
        DebugLog.log("sendTest invoked (status=\(describe(authStatus)))")
        // 1. Audible cue — always works, no permission required.
        NSSound(named: "Glass")?.play()

        // 2. Try UN if authorized.
        if isAuthorized {
            notify(title: "EGO Mac · Test",
                   body: "Bildirim sistemi çalışıyor. Bu yazıyı görüyorsan her şey yolunda.")
        } else {
            // 3. Try osascript path (uses Script Editor's permissions).
            postViaOsascript(
                title: "EGO Mac · Test",
                body: "Bildirim sistemi çalışıyor. Bu yazıyı görüyorsan her şey yolunda.",
                sound: "Glass"
            )
            // 4. Modal alert — guaranteed to appear, so user knows the test ran.
            //    Auto-dismisses after 2 seconds via dispatch.
            let alert = NSAlert()
            alert.messageText = "Test bildirim gönderildi"
            alert.informativeText = "Banner sağ üst köşede göründüyse macOS bildirim izni verilmiş demektir.\n\nEğer banner GELMEDİYSE: Sistem Ayarları → Bildirimler → “EGO Mac” & “Script Editor” uygulamaları için “Bildirimleri İzin Ver” açık olmalı."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Sistem Ayarlarını Aç")
            alert.addButton(withTitle: "Tamam")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openNotificationSettings()
            }
        }
    }

    @MainActor
    static func notify(title: String, body: String, sound: String = "Glass") {
        DebugLog.log("NOTIFY title=\(title) body=\(body)")

        // If we already know UN is unavailable for this app, go straight to
        // osascript so the user actually sees a banner. UN's add() succeeds
        // even when permission is denied — the alert just never shows.
        switch authStatus {
        case .denied:
            DebugLog.log("UN denied for this bundle id → osascript")
            postViaOsascript(title: title, body: body, sound: sound)
            return
        case .notDetermined:
            DebugLog.log("UN status unknown → osascript (UN may also fire if user later allows)")
            postViaOsascript(title: title, body: body, sound: sound)
            return
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLog.log("UN add failed: \(error.localizedDescription) — osascript fallback")
                postViaOsascript(title: title, body: body, sound: sound)
            } else {
                DebugLog.log("UN add ok")
            }
        }
    }

    private static func postViaOsascript(title: String, body: String, sound: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = """
        display notification "\(escape(body))" with title "\(escape(title))" sound name "\(escape(sound))"
        """
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        do {
            try proc.run()
        } catch {
            DebugLog.log("osascript also failed: \(error.localizedDescription)")
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }
}
