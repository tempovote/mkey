//
//  MkeyApp.swift
//  mkey
//
//  Menu-bar Vietnamese input method for macOS 26, built on the OpenKey
//  engine with a SwiftUI interface.
//

import AppKit
import SwiftUI

@main
struct MkeyApp: App {
    @NSApplicationDelegateAdaptor(MkeyAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }

        Window("MKey — Bộ gõ Tiếng Việt", id: "settings") {
            SettingsRootView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 520)
    }
}

/// Lives permanently in the menu bar, so it is the one SwiftUI view that can
/// reliably receive the "open settings" request from the AppKit delegate.
struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: StatusIcon.image(vietnamese: state.isVietnamese, gray: state.grayIcon))
            .onReceive(NotificationCenter.default.publisher(for: .mkOpenSettingsWindow)) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var clipboard = ClipboardManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Tiếng Việt", isOn: $state.isVietnamese)
            .dynamicShortcut(state.switchKeyStatus)

        Divider()

        Picker("Kiểu gõ", selection: $state.inputType) {
            ForEach(AppState.inputTypeNames.indices, id: \.self) { i in
                Text(AppState.inputTypeNames[i]).tag(i)
            }
        }

        Picker("Bảng mã", selection: $state.codeTable) {
            ForEach(AppState.codeTableNames.indices, id: \.self) { i in
                Text(AppState.codeTableNames[i]).tag(i)
            }
        }

        Divider()

        Button("Chuyển mã nhanh") {
            MKBridge.engineRequestsQuickConvert()
        }
        .dynamicShortcut(state.convertHotKey)

        Button("Công cụ chuyển mã…") { open(.convert) }
        Button("Gõ tắt…") { open(.macro) }

        if clipboard.enabled {
            Button("Lịch sử Clipboard") {
                ClipboardManager.shared.togglePicker()
            }
            .dynamicShortcut(clipboard.hotKey)
        }

        Divider()

        Button("Bảng điều khiển…") { open(.typing) }
        Button("Giới thiệu MKey") { open(.about) }

        Divider()

        Button("Thoát MKey") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func open(_ page: SettingsPage) {
        state.selectedPage = page
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var permissionTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppState.registerDefaultSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        NSApp.setActivationPolicy(state.showIconOnDock ? .regular : .accessory)

        registerWorkspaceNotifications()
        observeQuickConvert()

        // clipboard history runs independently from the engine
        ClipboardManager.shared.startIfEnabled()

        // banner "Mở Cài đặt hệ thống" button asks us to (re-)register for AX
        NotificationCenter.default.addObserver(forName: .mkRequestAccessibility,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.askForAccessibility()
            }
        }

        if AXIsProcessTrusted() {
            startEngine()
        } else {
            state.accessibilityGranted = false
            askForAccessibility()
        }

        if state.showUIOnStartup || !state.accessibilityGranted {
            // delay until the MenuBarExtra label is installed and can route the request
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettingsWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettingsWindow() }
        return true
    }

    // MARK: Engine

    private func startEngine() {
        AppState.shared.accessibilityGranted = true
        if !MKBridge.startEventTap() {
            // tap creation failed although AX is granted (e.g. permission revoked mid-flight)
            AppState.shared.accessibilityGranted = false
            askForAccessibility()
        }
    }

    private func askForAccessibility() {
        // show the system prompt, then poll until granted
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                Task { @MainActor in self?.startEngine() }
            }
        }
    }

    // MARK: Notifications

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(receiveWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(receiveSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(activeAppChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func observeQuickConvert() {
        NotificationCenter.default.addObserver(forName: .MKQuickConvertDidRun,
                                               object: nil, queue: .main) { note in
            let success = (note.object as? NSNumber)?.boolValue ?? false
            Task { @MainActor in
                guard MKBridge.convertAlertWhenCompleted || !success else { return }
                let alert = NSAlert()
                alert.messageText = success ? "Chuyển mã thành công!" : "Không có dữ liệu trong clipboard!"
                alert.informativeText = success ? "Kết quả đã được lưu trong clipboard." : "Hãy sao chép một đoạn văn bản để chuyển đổi."
                alert.addButton(withTitle: "OK")
                alert.window.level = .statusBar
                alert.runModal()
            }
        }
    }

    @objc private func receiveWake(_ note: Notification) {
        _ = MKBridge.startEventTap()
    }

    @objc private func receiveSleep(_ note: Notification) {
        _ = MKBridge.stopEventTap()
    }

    @objc private func spaceChanged(_ note: Notification) {
        MKBridge.requestNewSession()
    }

    @objc private func activeAppChanged(_ note: Notification) {
        if vUseSmartSwitchKey != 0 && MKBridge.isEventTapRunning() {
            MKBridge.activeAppChanged()
        }
    }

    // MARK: Window

    private func openSettingsWindow() {
        // The Window scene registers this identifier; reuse it from AppKit side.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // routed to MenuBarLabel, which holds an openWindow environment action
            NotificationCenter.default.post(name: .mkOpenSettingsWindow, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let mkOpenSettingsWindow = Notification.Name("MKOpenSettingsWindow")
    static let mkRequestAccessibility = Notification.Name("MKRequestAccessibility")
}

extension View {
    @ViewBuilder
    func dynamicShortcut(_ status: Int32) -> some View {
        if let shortcut = ShortcutParser.parse(status) {
            self.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}

private struct ShortcutParser {
    static func parse(_ status: Int32) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
        let value = UInt32(bitPattern: status)
        let char = UInt8((value >> 24) & 0xFF)
        guard char != 0xFE && char != 0 else { return nil }
        
        let key: KeyEquivalent
        if char == 49 || char == 32 {
            key = .space
        } else {
            let letter = String(UnicodeScalar(char)).lowercased()
            if let c = letter.first {
                key = KeyEquivalent(c)
            } else {
                key = KeyEquivalent(" ")
            }
        }
        
        var modifiers: EventModifiers = []
        if value & 0x100 != 0 { _ = modifiers.insert(.control) }
        if value & 0x200 != 0 { _ = modifiers.insert(.option) }
        if value & 0x400 != 0 { _ = modifiers.insert(.command) }
        if value & 0x800 != 0 { _ = modifiers.insert(.shift) }
        
        return (key, modifiers)
    }
}
