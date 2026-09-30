import ServiceManagement
import SwiftUI

/// The panel that opens from the menu bar (or a right-click on the widget). Unlike a menu it
/// stays open while settings are changed, so several can be adjusted in one go.
/// Which tab the panel shows; shared so the app can open it on a given tab.
@MainActor
final class PanelState: ObservableObject {
    static let shared = PanelState()
    enum Tab: Hashable { case usage, settings }
    @Published var tab: Tab = .usage
}

struct ControlPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings
    var raiseWidget: () -> Void
    @ObservedObject private var state = PanelState.shared
    private typealias Tab = PanelState.Tab

    static let width: CGFloat = 368

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                Text("使用量").tag(Tab.usage)
                Text("設定").tag(Tab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            switch state.tab {
            case .usage: UsageTab(store: store, settings: settings)
            case .settings:
                // The settings list is long; scroll inside a fixed-height area so the panel stays on screen.
                ScrollView(.vertical) {
                    SettingsTab(settings: settings, raiseWidget: raiseWidget)
                }
                .frame(height: 560)
            }

            Divider()
            HStack(spacing: 10) {
                Button {
                    store.refresh(manual: true)
                } label: {
                    Label("今すぐ更新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
    }
}

private struct UsageTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LargeCard(items: store.states(settings), width: ControlPanel.width, padding: 14)
            HStack(spacing: 8) {
                ForEach(settings.providerSelection.providers) { p in
                    Button {
                        NSWorkspace.shared.open(p.usageURL)
                    } label: {
                        Label("\(p.name) の使用量ページ", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }
}

/// View-local state kept in an object: the Command Line Tools for macOS 27 ship without
/// SwiftUI's macro plugin, so `@State` no longer compiles there while `@StateObject` does.
final class LoginItemState: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
}

private struct SettingsTab: View {
    @ObservedObject var settings: Settings
    var raiseWidget: () -> Void
    @StateObject private var login = LoginItemState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection("ウィジェット") {
                Row("デスクトップに表示") { Toggle("", isOn: $settings.showWidget).switchStyle() }
                Row("サイズ") {
                    Picker("", selection: $settings.widgetSize) {
                        Text("小").tag(WidgetSize.small); Text("中").tag(WidgetSize.medium); Text("大").tag(WidgetSize.large)
                    }.segmented()
                }
                Row("拡大率") {
                    HStack(spacing: 6) {
                        Slider(value: $settings.widgetZoom, in: Settings.zoomRange, step: 0.05)
                            .frame(width: 110)
                            .controlSize(.small)
                        Text("\(Int((settings.widgetZoom * 100).rounded()))%")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                        Button("100%") { settings.widgetZoom = 1 }
                            .controlSize(.mini)
                            .disabled(abs(settings.widgetZoom - 1) < 0.001)
                    }
                }
                Text("ウィジェットの右下か左下の角をドラッグしても変えられます")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Row("配置") {
                    Picker("", selection: $settings.placement) {
                        Text("デスクトップ").tag(Placement.desktop); Text("最前面").tag(Placement.floating)
                    }.segmented()
                }
                Row("スタイル") {
                    Picker("", selection: $settings.glassStyle) {
                        Text("ガラス").tag(GlassStyle.regular); Text("クリア").tag(GlassStyle.clear); Text("ダーク").tag(GlassStyle.dark)
                    }.segmented()
                }
                Row("作業風景") { Toggle("", isOn: $settings.showWorkScene).switchStyle() }
                if settings.showWorkScene {
                    Row("作業風景の動き") {
                        Picker("", selection: $settings.workSceneStyle) {
                            ForEach(WorkSceneStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.segmented()
                    }
                    Row("ChatGPT アプリの作業も検知") { Toggle("", isOn: $settings.detectChatGPTApp).switchStyle() }
                    if settings.detectChatGPTApp { ChatGPTAccessRow() }
                }
                Row("内訳・クレジット") { Toggle("", isOn: $settings.showWidgetDetails).switchStyle() }
                if settings.showWidget && settings.placement == .desktop {
                    Button("ウィジェットを手前に出す", action: raiseWidget)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            PanelSection("表示") {
                Row("サービス") {
                    Picker("", selection: $settings.providerSelection) {
                        Text("Claude").tag(ProviderSelection.claude)
                        Text("Codex").tag(ProviderSelection.codex)
                        Text("両方").tag(ProviderSelection.both)
                    }.segmented()
                }
                Row("数値") {
                    Picker("", selection: $settings.displayMode) {
                        Text("使用率").tag(DisplayMode.used); Text("残り").tag(DisplayMode.remaining)
                    }.segmented()
                }
                Row("カラー") {
                    Picker("", selection: $settings.colorMode) {
                        Text("使用率で変化").tag(ColorMode.level); Text("固定").tag(ColorMode.brand)
                    }.segmented()
                }
                if settings.colorMode == .level { ColorLegend() }
            }

            PanelSection("Claude の無料リセット") {
                ClaudeResetEditor(settings: settings)
            }

            PanelSection("メニューバー") {
                Row("スタイル") {
                    Picker("", selection: $settings.menuBarMode) {
                        ForEach(MenuBarMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Row("キャラクターの色") {
                    Picker("", selection: $settings.characterColor) {
                        Text("使用率で変化").tag(CharacterColor.level); Text("オレンジ").tag(CharacterColor.claude)
                    }.segmented()
                }
                if settings.characterColor == .level { CharacterScaleEditor(settings: settings) }
                Row("Claude だけ表示") {
                    Toggle("", isOn: $settings.menuBarClaudeOnly).switchStyle()
                        .disabled(settings.menuBarMode.isCharacter)
                }
            }

            PanelSection("更新") {
                Row("間隔") {
                    Picker("", selection: $settings.intervalMinutes) {
                        ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0)分").tag($0) }
                    }.segmented()
                }
                Row("トークン切れを CLI で更新") { Toggle("", isOn: $settings.autoCLIRefresh).switchStyle() }
                Row("ログイン時に起動") {
                    Toggle("", isOn: Binding(get: { login.enabled }, set: setLaunchAtLogin)).switchStyle()
                }
                if let loginError = login.error {
                    Text(loginError).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            login.error = nil
        } catch {
            login.error = "変更できませんでした。システム設定 › 一般 › ログイン項目 から追加してください。"
        }
        login.enabled = SMAppService.mainApp.status == .enabled
    }
}

/// Edit the Claude character's colour steps: colour, and the upper bound of each step.
private struct CharacterScaleEditor: View {
    @ObservedObject var settings: Settings

    var body: some View {
        let steps = settings.characterSteps.sorted { $0.upTo < $1.upTo }
        VStack(alignment: .leading, spacing: 5) {
            Text("Claude の色の段階（キャラクター・5時間・週間のリング）")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                let lower = i == 0 ? 0 : steps[i - 1].upTo + 1
                let upper = i + 1 < steps.count ? steps[i + 1].upTo - 1 : 100
                HStack(spacing: 8) {
                    ColorPicker("", selection: colorBinding(step.id), supportsOpacity: false)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 30)
                    Text(i == steps.count - 1 ? "使用 \(lower)% 〜" : "使用 \(lower) 〜 \(step.upTo)%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    Text("残り \(100 - (i == steps.count - 1 ? 100 : step.upTo))〜\(100 - lower)%")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    if i < steps.count - 1 {
                        Stepper("", value: upToBinding(step.id), in: lower...max(lower, upper), step: 1)
                            .labelsHidden()
                            .controlSize(.mini)
                    }
                }
            }
            Button("初期値に戻す") { settings.characterSteps = CharacterScale.defaults }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.04)))
    }

    private func colorBinding(_ id: UUID) -> Binding<Color> {
        Binding(get: {
            Color(nsColor: CharacterScale.nsColor(settings.characterSteps.first { $0.id == id }?.hex ?? 0xD97757))
        }, set: { color in
            guard let i = settings.characterSteps.firstIndex(where: { $0.id == id }) else { return }
            settings.characterSteps[i].hex = CharacterScale.hex(of: color)
        })
    }

    private func upToBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { settings.characterSteps.first { $0.id == id }?.upTo ?? 0 },
                set: { value in
                    guard let i = settings.characterSteps.firstIndex(where: { $0.id == id }) else { return }
                    settings.characterSteps[i].upTo = value
                })
    }
}

/// The date being typed for a new Claude reset (not `@State`: see LoginItemState).
final class ResetDraft: ObservableObject {
    @Published var date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
}

/// Claude's free resets, typed in from Claude's own usage settings; the API does not report them.
private struct ClaudeResetEditor: View {
    @ObservedObject var settings: Settings
    @StateObject private var draft = ResetDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.claudeResets.isEmpty {
                Text("登録なし").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(settings.claudeResets, id: \.self) { date in
                HStack(spacing: 6) {
                    Text("🎫")
                    Text("\(Fmt.format(date, "M/d(E)")) まで").font(.system(size: 12)).monospacedDigit()
                    Spacer()
                    Button {
                        settings.claudeResets.removeAll { $0 == date }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("使った・削除")
                }
            }
            HStack(spacing: 8) {
                Text("有効期限").font(.system(size: 12))
                DatePicker("", selection: $draft.date, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                Spacer()
                Button("追加") { add() }.controlSize(.small)
            }
            Text("Claude アプリの「設定 → 使用量 → 上限のリセット」に出ている有効期限を入れます。使ったら × で消してください。期限を過ぎたものは自動で消えます。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Claude shows only the day, so the grant counts as good until the end of it.
    private func add() {
        let cal = Calendar.current
        let end = cal.date(bySettingHour: 23, minute: 59, second: 0, of: draft.date) ?? draft.date
        guard end > Date() else { return }
        settings.claudeResets = (settings.claudeResets + [end]).sorted()
    }
}

/// Permission and live status for watching the ChatGPT app.
private struct ChatGPTAccessRow: View {
    @ObservedObject private var activity = WorkActivityStore.shared

    var body: some View {
        // Re-checks the permission every couple of seconds while the panel is open.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                if ChatGPTWatcher.isTrusted {
                    Label(status, systemImage: activity.chatGPT == .busy ? "circle.dotted" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(activity.chatGPT == .busy ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                } else {
                    Text("アクセシビリティの許可が必要です。「許可する」を押し、システム設定で「ClaudeCodexUsage」をオンにしてください。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("すでにオンになっている場合：アプリを更新すると許可が効かなくなります。一度オフにしてからオンに戻してください（それでも変わらなければ「−」で削除して「＋」で追加し直します）。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("許可する") { ChatGPTWatcher.requestPermission() }
                        Button("システム設定を開く") { ChatGPTWatcher.openAccessibilitySettings() }
                    }
                    .controlSize(.small)
                }
                Text("ChatGPT アプリで開いているチャットの「処理中」の表示だけを見ます。タイトルや内容は読みません。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.04)))
        }
    }

    private var status: String {
        switch activity.chatGPT {
        case .busy: return "許可済み ・ ChatGPT アプリ: 処理中"
        case .idle: return "許可済み ・ ChatGPT アプリ: 待機中"
        case .notRunning: return "許可済み ・ ChatGPT アプリは起動していません"
        case .needsPermission, .off: return "許可済み ・ 確認しています…"
        }
    }
}

// MARK: - Layout helpers

private struct PanelSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) { content }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.05)))
        }
    }
}

private struct Row<Control: View>: View {
    var label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 22)
    }
}

/// Which colour means what, as a compact row of chips.
private struct ColorLegend: View {
    private let steps: [(String, Color)] = [("〜19%", Palette.sky[1]), ("〜39%", Palette.green[1]), ("〜59%", Palette.purple[1]),
                                            ("〜74%", Palette.yellow[1]), ("〜89%", Palette.orange[1]), ("90%〜", Palette.red[1])]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.0) { text, color in
                    HStack(spacing: 3) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(text).font(.system(size: 9.5)).monospacedDigit()
                    }
                }
            }
            Text("使用率の目安（残りが少ないほど早めに色が変わります）")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }
}

private extension View {
    func segmented() -> some View { labelsHidden().pickerStyle(.segmented).fixedSize() }
    func switchStyle() -> some View { labelsHidden().toggleStyle(.switch).controlSize(.mini) }
}
