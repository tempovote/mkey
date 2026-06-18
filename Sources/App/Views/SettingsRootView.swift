//
//  SettingsRootView.swift
//  mkey
//
//  Settings window: custom sidebar + detail pane. A hand-rolled sidebar is
//  used instead of NavigationSplitView, which mis-renders its selection row
//  into the titlebar area on macOS 26.
//

import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            VStack(spacing: 0) {
                if !state.accessibilityGranted {
                    PermissionBanner()
                }

                PageHeader(page: state.selectedPage)

                Group {
                    switch state.selectedPage {
                    case .typing: TypingPage()
                    case .macro: MacroPage()
                    case .convert: ConvertPage()
                    case .clipboard: ClipboardPage()
                    case .system: SystemPage()
                    case .about: AboutPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        // Accessory (menu-bar) apps don't activate properly when a window opens:
        // the window never becomes key, controls render gray and text fields
        // can't take focus. Promote to .regular while this window is visible.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("settings") == true }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            if !state.showIconOnDock {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("MKey")
                        .font(.headline.weight(.semibold))
                    Text("Bảng điều khiển")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("CÀI ĐẶT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 1)

                ForEach(SettingsPage.allCases) { page in
                    SidebarRow(page: page, isSelected: state.selectedPage == page) {
                        state.selectedPage = page
                    }
                }
            }

            Spacer()

            StatusBadge(isReady: state.accessibilityGranted)
        }
        .padding(14)
        .frame(width: 220)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

private struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title3.weight(.semibold))
                Text(page.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.55)
        }
    }
}

private struct StatusBadge: View {
    let isReady: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(isReady ? "Đã sẵn sàng" : "Cần quyền Trợ năng")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var rowBackground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isHovering { return AnyShapeStyle(.quaternary.opacity(0.38)) }
        return AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)

                Text(page.title)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3, height: 18)
                .padding(.leading, 2)
        }
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// Shown until the Accessibility permission is granted.
struct PermissionBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("MKey cần quyền Trợ năng (Accessibility) để gõ tiếng Việt.")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Mở Cài đặt hệ thống") {
                // re-register MKey into the Accessibility list (macOS won't let an
                // app enable itself, but this adds it back so the user only needs
                // to flip the switch) and start polling so no relaunch is needed
                NotificationCenter.default.post(name: .mkRequestAccessibility, object: nil)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
    }
}
