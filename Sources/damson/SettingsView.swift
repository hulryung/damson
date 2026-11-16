import AppKit
import DamsonCrew
import DamsonSettings
import DamsonTerminal
import SwiftUI

/// Minimal SwiftUI settings window. Persisted via @AppStorage; on change, hot-reloads active sessions via notification.
struct DamsonSettingsView: View {
    @AppStorage("damson.fontSize") private var fontSize: Double = 13
    @AppStorage("damson.fontFamily") private var fontFamily: String = FontDiscovery.defaultFamily()
    @AppStorage("damson.scrollbackLines") private var scrollbackLines: Int = 10_000
    @AppStorage("damson.restoreScrollback") private var restoreScrollback: Bool = false
    @AppStorage("damson.keepSessionsOnRestart") private var keepSessionsOnRestart: Bool = false
    @AppStorage("damson.tabBarStyle") private var tabBarStyleRaw: String = TabBarStyle.compact.rawValue
    @AppStorage("damson.imeStyle") private var imeStyleRaw: String = IMECompositionStyle.none.rawValue
    @AppStorage("damson.theme") private var themeName: String = DamsonTheme.defaultDark.name
    @AppStorage("damson.autoUpdate") private var autoUpdate: Bool = false
    @AppStorage("damson.cursorBlink") private var cursorBlink: Bool = false
    @AppStorage("damson.animations") private var animations: Bool = true
    @AppStorage("damson.cursorShape") private var cursorShapeRaw: String = Grid.CursorShape.block.rawValue
    @AppStorage("damson.cursorMotion") private var cursorMotionRaw: String = CursorMotionStyle.none.rawValue
    @AppStorage("damson.ligatures") private var ligatures: Bool = false
    @AppStorage("damson.ambiguousWide") private var ambiguousWide: Bool = false
    @AppStorage("damson.showScrollbar") private var showScrollbar: Bool = false
    @AppStorage("damson.tabTransition") private var tabTransitionRaw: String = TabTransitionStyle.slide.rawValue
    @AppStorage("damson.activePaneIndicator") private var activePaneRaw: String = ActivePaneIndicator.accentBorder.rawValue
    // Pane chrome. Keys and defaults mirror PaneIndicatorSettings (DamsonTerminal), which is
    // what the panes actually read; @AppStorage needs literals, so they are repeated here.
    @AppStorage("damson.paneDimStrength") private var paneDimStrength: Double = 0.4
    @AppStorage("damson.paneDimTint") private var paneDimTintRaw: String = PaneDimTint.auto.rawValue
    @AppStorage("damson.paneAccentColor") private var paneAccentHex: String = ""
    @AppStorage("damson.paneBorderWidth") private var paneBorderWidth: Double = 1
    @AppStorage("damson.dimInactiveWindows") private var dimInactiveWindows: Bool = false
    @AppStorage("damson.paneDividerColor") private var paneDividerHex: String = ""
    @AppStorage("damson.paneDividerWidth") private var paneDividerWidth: Double = 1
    @State private var previewWindowInactive = false
    @StateObject private var model = SettingsModel()
    @State private var confirmResetAll = false
    @AppStorage("damson.focusFollowsMouse") private var focusFollowsMouse: Bool = true
    @AppStorage("damson.evenSplits") private var evenSplits: Bool = true
    @AppStorage("damson.newTabDirectory") private var newTabDirRaw: String = NewTabDirectory.home.rawValue
    @AppStorage("damson.backgroundOpacity") private var backgroundOpacity: Double = 1.0
    @AppStorage("damson.paddingH") private var paddingH: Double = 4
    @AppStorage("damson.paddingV") private var paddingV: Double = 4
    @AppStorage("damson.backgroundBlur") private var backgroundBlur: Bool = false
    @AppStorage("damson.quickTerminal") private var quickTerminalEnabled: Bool = false
    @AppStorage("damson.screenEffect") private var screenEffectRaw: String = ScreenEffect.none.rawValue
    @AppStorage("damson.screenEffectIntensity") private var screenEffectIntensity: Double = 1.0
    @AppStorage("damson.glyphAppear") private var glyphAppearRaw: String = GlyphAnimStyle.none.rawValue
    @AppStorage("damson.glyphDisappear") private var glyphDisappearRaw: String = GlyphAnimStyle.none.rawValue
    @AppStorage("damson.pressAndHold") private var pressAndHold: Bool = false
    @AppStorage("damson.copyOnSelect") private var copyOnSelect: Bool = true
    @AppStorage("damson.scrollSpeed") private var scrollSpeed: Double = 1.0
    @AppStorage("damson.wordSeparators") private var wordSeparators: String = ""
    @AppStorage("damson.tabBarTransparent") private var tabBarTransparent: Bool = false
    // CommandNotificationPolicy.enabledKey / .thresholdKey (literals required by @AppStorage).
    @AppStorage("damson.commandNotifications") private var commandNotifications: Bool = false
    @AppStorage("damson.commandNotificationSeconds") private var commandNotificationSeconds: Int = 10

    // Orchestration — read by `damson-crew`, which runs as a separate process and reads this
    // app's defaults domain. The key strings live in `OrchestrationSettings.Keys`; they are
    // repeated here because @AppStorage needs literals, and a mismatch would fail silently.
    @AppStorage(OrchestrationSettings.Keys.agentCommand)
    private var agentCommand: String = "claude"
    @AppStorage(OrchestrationSettings.Keys.skipPermissions)
    private var skipPermissions: Bool = true
    @AppStorage(OrchestrationSettings.Keys.notifyOnWaiting)
    private var notifyOnWaiting: Bool = true
    @AppStorage(OrchestrationSettings.Keys.focusOnWaiting)
    private var focusOnWaiting: Bool = false
    @AppStorage(OrchestrationSettings.Keys.notifyOnFinished)
    private var notifyOnFinished: Bool = true
    @AppStorage(OrchestrationSettings.Keys.stallMinutes)
    private var stallMinutes: Int = 5
    @AppStorage(OrchestrationSettings.Keys.worktreeRoot)
    private var worktreeRoot: String = ""
    @AppStorage(OrchestrationSettings.Keys.trustNewWorktrees)
    private var trustNewWorktrees: Bool = true
    @AppStorage(OrchestrationSettings.Keys.openRunsInNewWindow)
    private var openRunsInNewWindow: Bool = false

    @ObservedObject private var updater = DamsonUpdater.shared

    // Installing the command-line tools and the agent skills. Recomputed when the Agents
    // tab appears, so the state shown is what is on disk rather than what was true when
    // the settings window opened.
    @State private var toolStatus: [ToolInstall.Status] = []
    @State private var binChoice: ToolInstall.BinChoice?
    @State private var toolMessage: String?
    @State private var skillMessage: String?
    @State private var installingSkill = false

    private let nerdFonts = FontDiscovery.nerdFontFamilies()
    private let regularFonts = FontDiscovery.regularMonospaceFamilies()

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(model: model)
        } detail: {
            ScrollViewReader { proxy in
                page(model.page)
                    .navigationTitle(model.page.title)
                    .onChange(of: model.highlightKey) { key in
                        guard let key else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .center) }
                    }
            }
        }
        .environmentObject(model)
        // Minimum only: a fixed frame here would pin the hosting view's min and max size
        // to the same value, and the window's `.resizable` would do nothing. Every page is
        // a grouped Form, which scrolls, so the content copes with any size above this.
        .frame(minWidth: 680, minHeight: 440)
        .onChange(of: fontSize) { _ in postChanged() }
        .onChange(of: fontFamily) { _ in postChanged() }
        .onChange(of: scrollbackLines) { _ in postChanged() }
        .onChange(of: tabBarStyleRaw) { _ in postChanged() }
        .onChange(of: imeStyleRaw) { _ in postChanged() }
        .onChange(of: cursorBlink) { _ in postChanged() }
        .onChange(of: animations) { _ in postChanged() }
        .onChange(of: cursorShapeRaw) { _ in postChanged() }
        .onChange(of: cursorMotionRaw) { _ in postChanged() }
        .onChange(of: ligatures) { _ in postChanged() }
        .onChange(of: ambiguousWide) { _ in postChanged() }
        .onChange(of: showScrollbar) { _ in postChanged() }
        .onChange(of: activePaneRaw) { _ in postChanged() }
        .onChange(of: paneDimStrength) { _ in postChanged() }
        .onChange(of: paneDimTintRaw) { _ in postChanged() }
        .onChange(of: paneAccentHex) { _ in postChanged() }
        .onChange(of: paneBorderWidth) { _ in postChanged() }
        .onChange(of: dimInactiveWindows) { _ in postChanged() }
        .onChange(of: paneDividerHex) { _ in postChanged() }
        .onChange(of: paneDividerWidth) { _ in postChanged() }
        .onChange(of: backgroundOpacity) { _ in postChanged() }
        .onChange(of: paddingH) { _ in postChanged() }
        .onChange(of: paddingV) { _ in postChanged() }
        .onChange(of: backgroundBlur) { _ in postChanged() }
        .onChange(of: tabBarTransparent) { _ in postChanged() }
        .onChange(of: screenEffectRaw) { _ in postChanged() }
        .onChange(of: screenEffectIntensity) { _ in postChanged() }
        .onChange(of: glyphAppearRaw) { _ in postChanged() }
        .onChange(of: glyphDisappearRaw) { _ in postChanged() }
        .onChange(of: copyOnSelect) { _ in postChanged() }
        .onChange(of: scrollSpeed) { _ in postChanged() }
        .onChange(of: wordSeparators) { _ in postChanged() }
        .onChange(of: pressAndHold) { v in
            // Update the system key immediately (full effect after restart). Off = key repeat, on = accent popup.
            UserDefaults.standard.set(v, forKey: "ApplePressAndHoldEnabled")
        }
        .onChange(of: themeName) { _ in postChanged() }
        .onChange(of: autoUpdate) { _ in
            // Apply to the Sparkle updater immediately (separate from the config hot-reload path).
            DamsonUpdater.shared.applyAutomaticChecksSetting()
        }
    }

    // MARK: - Pages

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .appearance: appearancePage
        case .window: windowPage
        case .panes: panesPage
        case .effects: effectsPage
        case .terminal: terminalPage
        case .keys: KeysSettingsTab()
        case .agents: agentsPage
        case .advanced: advancedPage
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
    }

    private var appearancePage: some View {
        Form {
            SettingsSection(.appearance, "Font") {
                HStack {
                    Text("Size")
                    Spacer()
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(minWidth: 50)
                    }
                }
                .setting("damson.fontSize")
                Picker("Family", selection: $fontFamily) {
                    if !nerdFonts.isEmpty {
                        Section("Nerd Fonts (powerline/icon glyphs)") {
                            ForEach(nerdFonts, id: \.self) { f in
                                Text(f).tag(f)
                            }
                        }
                    }
                    Section("Monospaced") {
                        ForEach(regularFonts, id: \.self) { f in
                            Text(f).tag(f)
                        }
                    }
                }
                .setting("damson.fontFamily")
                // Preview — a glyph sample in the selected font (includes powerline separators, icons, etc.).
                HStack {
                    Text("Preview")
                    Spacer()
                    Text("123 abc ❯  ")
                        .font(.custom(fontFamily, size: CGFloat(fontSize)))
                        .frame(width: 220, alignment: .leading)
                }
                Toggle("Ligatures", isOn: $ligatures)
                    .setting("damson.ligatures")
                caption("Programming ligatures like => != -> ===. Shown only when the font supports them (Fira Code, JetBrains Mono, D2CodingLigature, etc.).")
                Toggle("Ambiguous-width symbols as double width", isOn: $ambiguousWide)
                    .setting("damson.ambiguousWide")
                caption("Give circled numbers/letters (\u{2460}\u{2461}\u{24B6}), \u{203B}, \u{2605}, arrows and similar CJK-font full-width symbols two cells so they show at their designed size, even in runs. Apps that assume one cell (most TUIs) may misalign columns; existing lines re-render on new output.")
            }
            SettingsSection(.appearance, "Theme") {
                // Browsing the list with ↑↓ instantly updates the large preview on the right and the live terminal.
                ThemeBrowser(themeName: $themeName)
                    .setting("damson.theme")
                if themeName == DamsonTheme.customName {
                    CustomThemeEditor(onChange: { postChanged() })
                        .setting("damson.customTheme")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var windowPage: some View {
        Form {
            SettingsSection(.window, "Window") {
                Picker("Tab Bar", selection: $tabBarStyleRaw) {
                    ForEach(TabBarStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .setting("damson.tabBarStyle")
                Toggle("Transparent tab bar", isOn: $tabBarTransparent)
                    .setting("damson.tabBarTransparent")
                caption("When off (default), the tab bar is a solid theme background color; when on, it's frosted-glass translucent.")
                Toggle("Always Show Scrollbar", isOn: $showScrollbar)
                    .setting("damson.showScrollbar")
                caption("When off (default), the scrollbar fades in while you scroll and when the pointer nears the right edge; when on, it stays visible whenever there is scrollback.")
                Picker("Tab Transition", selection: $tabTransitionRaw) {
                    ForEach(TabTransitionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .setting("damson.tabTransition")
                Toggle("Focus follows mouse", isOn: $focusFollowsMouse)
                    .setting("damson.focusFollowsMouse")
                caption("When on (default), the pane under the mouse cursor activates without a click. Only meaningful in split windows.")
                Toggle("Even splits", isOn: $evenSplits)
                    .setting("damson.evenSplits")
                caption("When on (default), splitting (⌘D / ⌘⇧D) or closing (⌘W) a pane evens out every pane left in the same row or column — a third split gives ⅓ · ⅓ · ⅓. When off, a split just halves the active pane (½ · ¼ · ¼) and a close hands all of its space to the neighbor.")
                Picker("New Tab Directory", selection: $newTabDirRaw) {
                    ForEach(NewTabDirectory.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                .setting("damson.newTabDirectory")
                caption("Starting location for new tabs. Splits always inherit the current pane's directory. Shell integration (zsh OSC 7) is injected automatically.")
            }
            SettingsSection(.window, "Padding") {
                sliderRow("Horizontal", value: $paddingH, range: 0...32, step: 1,
                          label: "\(Int(paddingH)) pt")
                    .setting("damson.paddingH")
                sliderRow("Vertical", value: $paddingV, range: 0...32, step: 1,
                          label: "\(Int(paddingV)) pt")
                    .setting("damson.paddingV")
                caption("Inner space between the window edges and the terminal content. Applies live; the grid size (cols×rows) adjusts to the remaining area.")
            }
            SettingsSection(.window, "Transparency") {
                sliderRow("Background Opacity", value: $backgroundOpacity, range: 0.2...1.0, step: nil,
                          label: "\(Int((backgroundOpacity * 100).rounded()))%")
                    .setting("damson.backgroundOpacity")
                Toggle("Background Blur (frosted glass)", isOn: $backgroundBlur)
                    .disabled(backgroundOpacity >= 1.0)
                    .setting("damson.backgroundBlur")
                caption("Lowering the background opacity lets what's behind the window show through. Blur frosts that backdrop like frosted glass (no effect at 100% opacity).")
            }
            SettingsSection(.window, "Quick Terminal") {
                Toggle("Global quick-terminal shortcut", isOn: $quickTerminalEnabled)
                    .setting("damson.quickTerminal")
                QuickTerminalShortcutRow()
                    .setting("damson.quickTerminal.shortcut")
                caption("From any app, the shortcut shows or hides one dedicated terminal window; its shell keeps running while hidden. Only that exact chord is taken — it must include ⌘ or ⌃. If another app already owns it, the setting turns itself off and says so. Tools → Show/Hide Quick Terminal works without it.")
            }
        }
        .formStyle(.grouped)
    }

    private var effectsPage: some View {
        Form {
            SettingsSection(.effects, "Screen Effect") {
                Picker("Effect", selection: $screenEffectRaw) {
                    ForEach(ScreenEffect.allCases, id: \.rawValue) { e in
                        Text(e.displayName).tag(e.rawValue)
                    }
                }
                .setting("damson.screenEffect")
                sliderRow("Intensity", value: $screenEffectIntensity, range: 0.2...1.0, step: nil,
                          label: "\(Int((screenEffectIntensity * 100).rounded()))%")
                    .disabled(screenEffectRaw == ScreenEffect.none.rawValue)
                    .setting("damson.screenEffectIntensity")
                caption("An effect applied across the whole screen — CRT, phosphor, bloom, and more (static — no extra cost when idle).")
            }
            SettingsSection(.effects, "Text Animation") {
                Picker("On Type (appear)", selection: $glyphAppearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.appearDisplayName()).tag(s.rawValue)
                    }
                }
                .setting("damson.glyphAppear")
                Picker("On Delete (disappear)", selection: $glyphDisappearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.disappearDisplayName()).tag(s.rawValue)
                    }
                }
                .setting("damson.glyphDisappear")
                caption("A short animation played when glyphs appear or are erased near the cursor. Applies only to typing and deleting (excludes scrolling and bulk output).")
            }
        }
        .formStyle(.grouped)
    }

    private var terminalPage: some View {
        Form {
            SettingsSection(.terminal, "Scrollback") {
                HStack {
                    Text("Lines")
                    Spacer()
                    Stepper(value: $scrollbackLines, in: 1000...200_000, step: 1000) {
                        Text("\(scrollbackLines)").monospacedDigit().frame(minWidth: 70)
                    }
                }
                .setting("damson.scrollbackLines")
                Toggle("Restore scrollback on relaunch", isOn: $restoreScrollback)
                    .setting("damson.restoreScrollback")
                caption("Saves each pane's scrollback text on quit and shows it after relaunch (colors not preserved). Compact-mode windows only.")
            }
            SettingsSection(.terminal, "Sessions") {
                Toggle("Keep sessions running across restarts", isOn: $keepSessionsOnRestart)
                    .setting("damson.keepSessionsOnRestart")
                caption("Update installs and \"Restart Damson\" keep every pane's program running and reattach after the relaunch; the quit dialog gains a \"Keep Sessions & Quit\" option. Compact-mode windows only.")
            }
            SettingsSection(.terminal, "Cursor") {
                Picker("Shape", selection: $cursorShapeRaw) {
                    Text("Block").tag(Grid.CursorShape.block.rawValue)
                    Text("Underline").tag(Grid.CursorShape.underline.rawValue)
                    Text("Bar").tag(Grid.CursorShape.bar.rawValue)
                }
                .setting("damson.cursorShape")
                Toggle("Blink", isOn: $cursorBlink)
                    .setting("damson.cursorBlink")
                Picker("Motion", selection: $cursorMotionRaw) {
                    ForEach(CursorMotionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .setting("damson.cursorMotion")
                caption("The cursor slides to its new cell instead of jumping — about a tenth of "
                        + "a second, drawn on the GPU — and \"with trail\" leaves a fading smear "
                        + "along the way. Output that scrolls the screen still moves it instantly; "
                        + "only moves within the screen slide.")
                Toggle("Animations", isOn: $animations)
                    .setting("damson.animations")
            }
            SettingsSection(.terminal, "IME Composition") {
                Picker("Style", selection: $imeStyleRaw) {
                    ForEach(IMECompositionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .setting("damson.imeStyle")
                caption("How Korean / Japanese / Chinese composition is displayed while you type.")
            }
            SettingsSection(.terminal, "Selection") {
                Toggle("Copy on select", isOn: $copyOnSelect)
                    .setting("damson.copyOnSelect")
                caption("When on (default), selecting text (drag, or double-/triple-click) copies it to the clipboard immediately.")
                HStack {
                    Text("Word separators")
                    TextField("(none)", text: $wordSeparators)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                .setting("damson.wordSeparators")
                caption("Extra characters that break a word on double-click (whitespace always breaks). Leave empty so paths and identifiers like /usr/local/bin select as one word.")
            }
            SettingsSection(.terminal, "Scroll") {
                sliderRow("TUI Scroll Speed", value: $scrollSpeed, range: 0.25...4.0, step: nil,
                          label: String(format: "%.2fx", scrollSpeed), labelWidth: 48)
                    .setting("damson.scrollSpeed")
                caption("Trackpad scroll speed in mouse-tracking TUIs like Claude Code and tmux. Lower is slower. (No effect on normal scrollback scrolling.)")
            }
            SettingsSection(.terminal, "Command Notifications") {
                Toggle("Notify when long commands finish", isOn: $commandNotifications)
                    .setting("damson.commandNotifications")
                HStack {
                    Text("Minimum duration")
                    Spacer()
                    Stepper(value: $commandNotificationSeconds, in: 1...86_400, step: 5) {
                        Text("\(commandNotificationSeconds) s").monospacedDigit().frame(minWidth: 70)
                    }
                }
                .setting("damson.commandNotificationSeconds")
                .disabled(!commandNotifications)
                caption("Posts a macOS notification when a shell command runs at least this long, unless its pane is focused in the frontmost window. Clicking it reveals the pane. Needs zsh shell integration (or a shell that emits OSC 133 C/D) and notification permission.")
            }
            SettingsSection(.terminal, "Keyboard") {
                Toggle("Press and hold for accents", isOn: $pressAndHold)
                    .setting("damson.pressAndHold")
                caption("When off (default), every key repeats on press-and-hold (the terminal standard). When on, macOS default behavior applies — some keys like a/e show an accent popup on hold instead of repeating. Changes take effect after an app restart.")
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPage: some View {
        Form {
            SettingsSection(.advanced, "Updates") {
                Toggle("Automatic Updates", isOn: $autoUpdate)
                    .setting("damson.autoUpdate")
                caption("When on, checks for new versions in the background. You can always check manually via \"Check for Updates…\".")
                HStack {
                    Button("Check for Updates…") {
                        DamsonUpdater.shared.checkForUpdates(nil)
                    }
                    .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text(currentVersionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Section("Settings File") {
                HStack {
                    Button("Export Settings…") { SettingsTransfer.exportSettings() }
                    Button("Import Settings…") { SettingsTransfer.importSettings() }
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmResetAll = true }
                }
                caption("Export saves every setting on this page and the others — theme, custom colors and keyboard shortcuts included — to one file you can import on another Mac. Window layouts and sessions are not part of it.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmResetAll) {
            Button("Reset All Settings", role: .destructive) {
                for page in SettingsPage.allCases { model.reset(page) }
            }
        } message: {
            Text("Every setting, including the theme, custom colors and keyboard shortcuts, goes back to its default. Your open windows and sessions are not affected.")
        }
    }

    /// Settings for running several coding agents as tabs — read by `damson-crew`.
    ///
    /// These live here rather than in a config file because the CLI ships inside this app
    /// bundle: someone who installed the .dmg has the tool but no obvious place to configure
    /// it. Every one of them can still be overridden per run with a flag.
    private var agentsPage: some View {
        Form {
            Section("Setup") {
                HStack {
                    Text("Command-line tools")
                    Spacer()
                    Text(toolSummary).foregroundColor(.secondary)
                    Button(toolButtonTitle) { installTools() }
                }
                caption("Links damson-cli, damson-crew and damson-computer into "
                        + (binChoice.map { shortPath($0.url.path) } ?? "a folder on your PATH")
                        + ". They are symlinks, so they follow this app when it updates.")
                if let choice = binChoice, !choice.onPath {
                    Label("\(shortPath(choice.url.path)) is not on your PATH — add it to your "
                          + "shell profile: export PATH=\"\(shortPath(choice.url.path)):$PATH\"",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }

                HStack {
                    Text("Agent skill")
                    Spacer()
                    if installingSkill { ProgressView().controlSize(.small) }
                    Button("Claude Code") { installClaudeSkill() }.disabled(installingSkill)
                    Button("Codex") { installCodexPrompt() }.disabled(installingSkill)
                }
                caption("Teaches the agent how to drive a run: the plugin for Claude Code, and a "
                        + "/damson-orchestration prompt in ~/.codex/prompts for Codex, which has no "
                        + "plugins. Both are safe to press again to update.")

                if let message = toolMessage ?? skillMessage {
                    Text(message).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                }
            }

            SettingsSection(.agents, "Agent") {
                TextField("Command", text: $agentCommand)
                    .textFieldStyle(.roundedBorder)
                    .setting("damson.orchestration.agentCommand")
                caption("What `damson-crew run` starts when a task does not name its own command. "
                        + "claude, codex, grok and cursor-agent all work.")

                Toggle("Skip permission prompts", isOn: $skipPermissions)
                    .setting("damson.orchestration.skipPermissions")
                caption("Passes --dangerously-skip-permissions to claude, so an agent runs a task "
                        + "through instead of stopping to ask. An agent waiting on an approval is "
                        + "the most common way a run stalls — the tabs look alive while every one "
                        + "of them waits for a keypress.")
                if skipPermissions {
                    Label("Agents will edit files and run commands without asking. "
                          + "Only claude is affected; other agents spell this differently.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            SettingsSection(.agents, "Windows") {
                Toggle("Open each run in a new window", isOn: $openRunsInNewWindow)
                    .setting("damson.orchestration.openRunsInNewWindow")
                caption("A run's agent tabs open together in a window of their own instead of "
                        + "beside the tabs you are working in. Run the same group again and the "
                        + "new tabs join that window. Override it for one run with "
                        + "damson-crew run --new-window or --no-new-window.")
            }

            SettingsSection(.agents, "Notifications") {
                Toggle("When an agent is blocked on me", isOn: $notifyOnWaiting)
                    .setting("damson.orchestration.notifyOnWaiting")
                Toggle("Bring its tab forward", isOn: $focusOnWaiting)
                    .setting("damson.orchestration.focusOnWaiting")
                caption("A blocked agent will not move until you answer it, so this is the one "
                        + "case worth pulling the window in front of you.")

                Toggle("When an agent finishes working", isOn: $notifyOnFinished)
                    .setting("damson.orchestration.notifyOnFinished")
                caption("Told when an agent that was working goes idle. Claude Code publishes no "
                        + "completion signal for a session in a terminal, so this is \"it stopped\" "
                        + "rather than \"the task is done\" — but without it a run of five finishes "
                        + "in silence. It never steals focus.")

                Stepper(value: $stallMinutes, in: 0...120) {
                    HStack {
                        Text("When an agent has gone quiet for")
                        Spacer()
                        Text(stallMinutes == 0 ? "off" : "\(stallMinutes) min")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .setting("damson.orchestration.stallMinutes")
                caption("A long \"busy\" is not proof of progress: an agent retrying an overloaded "
                        + "API shows exactly the same status as one doing real work. This reports "
                        + "how long it has been quiet and leaves the judgement to you. 0 turns it off.")
            }

            SettingsSection(.agents, "Worktrees") {
                TextField("Root folder", text: $worktreeRoot, prompt: Text("Beside each repository"))
                    .textFieldStyle(.roundedBorder)
                    .setting("damson.orchestration.worktreeRoot")
                caption("Where damson-crew makes a git worktree for a task. Leave empty to keep "
                        + "them next to the repository they came from, as <repo>-worktrees.")

                Toggle("Trust new worktrees automatically", isOn: $trustNewWorktrees)
                    .setting("damson.orchestration.trustNewWorktrees")
                caption("Claude Code asks before working in a git repository it has not seen, and "
                        + "a worktree is a new one every time — so a run of five tasks stops five "
                        + "times. This answers that once, for worktrees damson-crew created "
                        + "itself from a repository you named.")
                if trustNewWorktrees {
                    Label("Writes ~/.claude.json, keeping a .damson-backup copy. Only Claude "
                          + "Code — codex and cursor-agent have their own prompts.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshToolStatus() }
    }

    // MARK: - Installing the tools and skills

    /// The tools as this bundle carries them.
    private var toolSource: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    private var toolSummary: String {
        switch ToolInstall.overall(toolStatus) {
        case .installed: return "installed"
        case .notInstalled: return "not installed"
        case .outdated: return "points at another copy"
        case .partial(let n): return "\(n) to update"
        case .blocked: return "name already taken"
        case .unavailable: return "missing from this app"
        }
    }

    private var toolButtonTitle: String {
        switch ToolInstall.overall(toolStatus) {
        case .installed: return "Reinstall"
        case .notInstalled: return "Install"
        case .outdated, .partial: return "Update"
        case .blocked, .unavailable: return "Install"
        }
    }

    /// `~` rather than the full home path: the folder is the point, not the user's name.
    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func refreshToolStatus() {
        // The app's own PATH is the minimal one LaunchServices hands a Dock launch, so ask
        // the login shell — otherwise every folder looks "not on PATH".
        let entries = ToolInstall.pathEntries(LoginEnvironment.loginPATH)
        let choice = ToolInstall.chooseBinDirectory(candidates: ToolInstall.defaultCandidates(),
                                                    pathEntries: entries)
        binChoice = choice
        toolStatus = ToolInstall.status(source: toolSource, binDir: choice.url)
    }

    private func installTools() {
        guard let choice = binChoice else { return }
        do {
            let written = try ToolInstall.install(source: toolSource, binDir: choice.url)
            toolMessage = written.isEmpty
                ? "Already up to date in \(shortPath(choice.url.path))."
                : "Linked \(written.joined(separator: ", ")) into \(shortPath(choice.url.path))."
        } catch {
            toolMessage = error.localizedDescription
        }
        skillMessage = nil
        refreshToolStatus()
    }

    private func installCodexPrompt() {
        let source = toolSource.appendingPathComponent("agents/codex-damson-orchestration.md")
        let destination = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/prompts/damson-orchestration.md")
        do {
            let written = try ToolInstall.installPrompt(from: source, to: destination)
            skillMessage = written
                ? "Wrote \(shortPath(destination.path)) — type /damson-orchestration in Codex."
                : "Codex prompt already up to date."
        } catch {
            skillMessage = "Could not write the Codex prompt: \(error.localizedDescription)"
        }
        toolMessage = nil
    }

    /// Runs Claude Code's own plugin commands rather than copying files into its store: the
    /// layout there is Claude Code's to change, and `claude plugin` is the supported door.
    private func installClaudeSkill() {
        installingSkill = true
        toolMessage = nil
        skillMessage = "Installing…"
        let path = LoginEnvironment.mergedPATH(login: LoginEnvironment.loginPATH,
                                               inherited: ProcessInfo.processInfo.environment["PATH"])
        DispatchQueue.global(qos: .userInitiated).async {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            guard let claude = PTYHost.resolveProgram("claude", env: env) else {
                DispatchQueue.main.async {
                    installingSkill = false
                    skillMessage = "Claude Code's `claude` command is not on your PATH."
                }
                return
            }
            // `add`/`install` fail once the marketplace and plugin are there, and `update`
            // fails before they are: try the first, fall back to the second.
            func run(_ args: [String]) -> (ok: Bool, out: String) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claude)
                p.arguments = args
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { return (false, error.localizedDescription) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                // Progress is rewritten with \r, so splitting on newlines alone leaves the
                // spinner line glued to the result. Keep the last line that says something.
                let last = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty } ?? ""
                return (p.terminationStatus == 0, last)
            }
            // The marketplace first, then the plugin — and `update` runs whether or not
            // `install` succeeded, because `install` reports success for a plugin that is
            // already there at an old version, which is exactly the case this button is for.
            var market = run(["plugin", "marketplace", "add", "hulryung/damson"])
            if !market.ok { market = run(["plugin", "marketplace", "update", "damson"]) }
            let install = run(["plugin", "install", "damson-orchestration@damson"])
            let update = run(["plugin", "update", "damson-orchestration@damson"])
            let ok = install.ok || update.ok
            let summary = update.ok ? update.out : (install.ok ? install.out : update.out)
            DispatchQueue.main.async {
                installingSkill = false
                skillMessage = ok
                    ? "\(summary) — restart Claude Code to pick it up."
                    : "claude plugin failed: \(summary.isEmpty ? market.out : summary)"
            }
        }
    }

    /// "Version 0.3.0 (259)" — shown next to the manual check button.
    private var currentVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    // MARK: - Panes (active-pane indicator, inactive-window dim, dividers)

    private var paneMode: PaneIndicatorMode { PaneIndicatorMode(rawValue: activePaneRaw) ?? .accentBorder }

    private var panesPage: some View {
        Form {
            SettingsSection(.panes, "Active Pane") {
                Picker("Indicator", selection: $activePaneRaw) {
                    ForEach(ActivePaneIndicator.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .setting("damson.activePaneIndicator")
                if paneMode == .dimInactive || paneMode == .dimAndBorder || dimInactiveWindows {
                    sliderRow("Dim Strength", value: $paneDimStrength,
                              range: PaneIndicatorSettings.dimStrengthRange, step: 0.05,
                              label: "\(Int((paneDimStrength * 100).rounded()))%")
                        .setting("damson.paneDimStrength")
                    Picker("Dim Color", selection: $paneDimTintRaw) {
                        ForEach(PaneDimTint.allCases, id: \.rawValue) { t in
                            Text(t.displayName).tag(t.rawValue)
                        }
                    }
                    .setting("damson.paneDimTint")
                }
                if paneMode == .accentBorder || paneMode == .dimAndBorder {
                    optionalColorRow("Custom accent color", hex: $paneAccentHex,
                                     fallback: PaneIndicatorStyle.resolve(
                                        PaneIndicatorSettings(), isActive: true, multiPane: true,
                                        windowIsKey: true, background: .black,
                                        systemAccent: .controlAccentColor).borderColor ?? .controlAccentColor)
                        .setting("damson.paneAccentColor")
                }
                if paneMode.hasBorder {
                    sliderRow("Border Width", value: $paneBorderWidth,
                              range: lineWidthRange, step: 0.5, label: pointLabel(paneBorderWidth))
                        .setting("damson.paneBorderWidth")
                }
            }
            SettingsSection(.panes, "Inactive Windows") {
                Toggle("Dim inactive windows", isOn: $dimInactiveWindows)
                    .setting("damson.dimInactiveWindows")
                caption("Dims every pane of a Damson window while another window or app has focus, so the focused window stands out. Uses the dim strength and color above.")
            }
            SettingsSection(.panes, "Dividers") {
                optionalColorRow("Custom divider color", hex: $paneDividerHex, fallback: .separatorColor)
                    .setting("damson.paneDividerColor")
                sliderRow("Divider Width", value: $paneDividerWidth,
                          range: lineWidthRange, step: 0.5, label: pointLabel(paneDividerWidth))
                    .setting("damson.paneDividerWidth")
                caption("The border and divider are drawn over the pane edge, inside the padding, so widths stop at 4 pt to keep text clear.")
            }
            Section("Preview") {
                PaneIndicatorPreview(settings: currentPaneSettings, theme: previewTheme,
                                     windowIsKey: !previewWindowInactive)
                    .frame(height: 120)
                if dimInactiveWindows {
                    Toggle("Preview as inactive window", isOn: $previewWindowInactive)
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lineWidthRange: ClosedRange<Double> {
        Double(PaneIndicatorSettings.lineWidthRange.lowerBound)...Double(PaneIndicatorSettings.lineWidthRange.upperBound)
    }

    private func pointLabel(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) pt" : String(format: "%.1f pt", v)
    }

    /// Built from the @AppStorage values rather than read back from defaults, so the preview
    /// follows a slider during the drag.
    private var currentPaneSettings: PaneIndicatorSettings {
        var s = PaneIndicatorSettings()
        s.mode = paneMode
        s.dimStrength = paneDimStrength
        s.dimTint = PaneDimTint(rawValue: paneDimTintRaw) ?? .auto
        s.accentColor = NSColor(hexString: paneAccentHex)
        s.borderWidth = CGFloat(paneBorderWidth)
        s.dimInactiveWindows = dimInactiveWindows
        s.dividerColor = NSColor(hexString: paneDividerHex)
        s.dividerWidth = CGFloat(paneDividerWidth)
        return s
    }

    private var previewTheme: DamsonTheme {
        if themeName == DamsonTheme.customName { return CustomTheme.load().toTheme() }
        return DamsonTheme.preset(named: themeName) ?? .defaultDark
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double?, label: String, labelWidth: CGFloat = 44) -> some View {
        HStack {
            Text(title)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(label)
                .monospacedDigit()
                .frame(width: labelWidth, alignment: .trailing)
        }
    }

    /// A toggle that, when on, reveals a color well. Off stores "" (= the system color);
    /// turning it on starts the well at `fallback`, so the color doesn't jump.
    private func optionalColorRow(_ title: String, hex: Binding<String>, fallback: NSColor) -> some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { !hex.wrappedValue.isEmpty },
                set: { on in hex.wrappedValue = on ? fallback.hexString : "" }))
            Spacer()
            if !hex.wrappedValue.isEmpty {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hexString: hex.wrappedValue) ?? fallback) },
                    set: { hex.wrappedValue = NSColor($0).hexString }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .damsonSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let damsonSettingsChanged = Notification.Name("DamsonSettingsChanged")
}

/// Theme browser — a list on the left (browse with ↑↓) plus a large preview on the right.
/// When the selection changes, $themeName (@AppStorage) updates and the parent view's
/// onChange(themeName) pushes a hot-reload to the live sessions (preview = live terminal, updated instantly).
struct ThemeBrowser: View {
    @Binding var themeName: String
    @FocusState private var listFocused: Bool

    private struct Entry: Identifiable {
        let name: String
        let theme: DamsonTheme
        var id: String { name }
    }

    private var entries: [Entry] {
        DamsonTheme.presets.map { Entry(name: $0.name, theme: $0) }
            + [Entry(name: DamsonTheme.customName, theme: CustomTheme.load().toTheme())]
    }

    private var selectedTheme: DamsonTheme {
        if themeName == DamsonTheme.customName { return CustomTheme.load().toTheme() }
        return DamsonTheme.preset(named: themeName) ?? .defaultDark
    }

    /// Move the selection by delta from the current position (clamped to range). For ↑↓ key browsing.
    private func moveSelection(_ delta: Int) {
        let all = entries
        guard !all.isEmpty else { return }
        let idx = all.firstIndex { $0.name == themeName } ?? 0
        let next = min(max(idx + delta, 0), all.count - 1)
        themeName = all[next].name
    }

    private func row(_ e: Entry) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: e.theme.background))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            Text(e.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(e.name == themeName
                      ? Color.accentColor.opacity(listFocused ? 0.35 : 0.22)
                      : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { themeName = e.name; listFocused = true }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { e in row(e).id(e.name) }
                    }
                    .padding(4)
                }
                .frame(width: 190, height: 210)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(listFocused ? Color.accentColor.opacity(0.8)
                                            : Color.secondary.opacity(0.3),
                                lineWidth: listFocused ? 1.5 : 0.5))
                .focusable()
                .focusRingDisabled()
                .focused($listFocused)
                .onMoveCommand { dir in
                    switch dir {
                    case .up: moveSelection(-1)
                    case .down: moveSelection(1)
                    default: break
                    }
                }
                .onChange(of: themeName) { name in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(themeName, anchor: .center) }
            }

            ThemePreview(theme: selectedTheme)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
        }
    }
}

private extension View {
    /// Remove the default blue focus ring (macOS 14+). On 13 it's left as-is (compile-only guarantee).
    @ViewBuilder func focusRingDisabled() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
    }
}

/// Mini terminal preview — colored sample prompt/output over the background, plus 16 ANSI color swatches.
struct ThemePreview: View {
    let theme: DamsonTheme
    private func col(_ i: Int) -> Color { Color(nsColor: theme.ansi[i]) }
    private var fg: Color { Color(nsColor: theme.foreground) }

    private func swatch(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(col(i))
            .frame(maxWidth: .infinity).frame(height: 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                Text("➜ ").foregroundColor(col(2))
                    + Text("~/dev/damson ").foregroundColor(col(4))
                    + Text("git:(").foregroundColor(fg)
                    + Text("main").foregroundColor(col(1))
                    + Text(")").foregroundColor(fg)
                Text("$ ").foregroundColor(col(2))
                    + Text("ls ").foregroundColor(fg)
                    + Text("-la").foregroundColor(col(3))
                Text("# building project…").foregroundColor(col(8))
                Text("hello ").foregroundColor(fg)
                    + Text("world ").foregroundColor(col(5))
                    + Text("✓").foregroundColor(col(6))
            }
            .font(.system(size: 11, design: .monospaced))

            Spacer(minLength: 6)
            Text("ANSI").font(.system(size: 9)).foregroundColor(fg.opacity(0.6))
            HStack(spacing: 3) { ForEach(0..<8, id: \.self) { swatch($0) } }
            HStack(spacing: 3) { ForEach(8..<16, id: \.self) { swatch($0) } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: theme.background))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// ColorPicker editor for the 19 custom-theme colors (background/foreground/cursor + 16 ANSI).
/// Saves to UserDefaults immediately on change and triggers a hot-reload via onChange.
struct CustomThemeEditor: View {
    let onChange: () -> Void
    @State private var data: CustomThemeData = CustomTheme.load()

    private static let ansiNames = [
        "0 Black", "1 Red", "2 Green", "3 Yellow",
        "4 Blue", "5 Magenta", "6 Cyan", "7 White",
        "8 Br Black", "9 Br Red", "10 Br Green", "11 Br Yellow",
        "12 Br Blue", "13 Br Magenta", "14 Br Cyan", "15 Br White",
    ]

    var body: some View {
        // Starting point for copying colors from a preset.
        HStack {
            Text("Start from")
            Spacer()
            Menu("Copy preset…") {
                ForEach(DamsonTheme.presets, id: \.name) { theme in
                    Button(theme.name) { copyFrom(theme) }
                }
            }
            .frame(width: 140)
        }

        ColorPicker("Background", selection: hexBinding(\.background))
        ColorPicker("Foreground", selection: hexBinding(\.foreground))
        ColorPicker("Cursor", selection: hexBinding(\.cursor))

        ForEach(0..<16, id: \.self) { i in
            ColorPicker(Self.ansiNames[i], selection: ansiBinding(i))
        }
    }

    private func copyFrom(_ theme: DamsonTheme) {
        let h = theme.toHexColors()
        data = CustomThemeData(background: h.bg, foreground: h.fg, cursor: h.cursor, ansi: h.ansi)
        CustomTheme.save(data)
        onChange()
    }

    private func hexBinding(_ kp: WritableKeyPath<CustomThemeData, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: data[keyPath: kp]) ?? .black) },
            set: { c in
                data[keyPath: kp] = NSColor(c).hexString
                CustomTheme.save(data)
                onChange()
            }
        )
    }

    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding(
            get: {
                guard i < data.ansi.count else { return .black }
                return Color(nsColor: NSColor(hexString: data.ansi[i]) ?? .black)
            },
            set: { c in
                while data.ansi.count <= i { data.ansi.append("#000000") }
                data.ansi[i] = NSColor(c).hexString
                CustomTheme.save(data)
                onChange()
            }
        )
    }
}

extension DamsonConfig {
    /// Returns a DamsonConfig populated from the settings saved in UserDefaults. Unset keys use defaults.
    static func fromUserDefaults() -> DamsonConfig {
        let d = UserDefaults.standard
        var config = DamsonConfig()
        // A Dock-launched app inherits LaunchServices' PATH, which has nothing the user
        // installed. The interactive shell fixes its own from its rc files; a program exec'd
        // directly into a pane — `spawn -- claude` — does not, and failed on every task with
        // "no executable named 'claude'". Give it what the login shell would have had.
        config.env["PATH"] = LoginEnvironment.mergedPATH(login: LoginEnvironment.loginPATH,
                                                         inherited: config.env["PATH"])
        let fs = d.double(forKey: "damson.fontSize")
        if fs >= 6 { config.fontSize = CGFloat(fs) }
        if let family = d.string(forKey: "damson.fontFamily"), !family.isEmpty {
            config.fontFamily = family
        } else {
            // Unset → the default chosen by FontDiscovery (Nerd Font preferred).
            config.fontFamily = FontDiscovery.defaultFamily()
        }
        let sb = d.integer(forKey: "damson.scrollbackLines")
        if sb > 0 { config.scrollbackLines = sb }
        if let raw = d.string(forKey: "damson.imeStyle"),
           let style = IMECompositionStyle(rawValue: raw) {
            config.imeStyle = style
        }
        config.cursorBlink = d.bool(forKey: "damson.cursorBlink")
        config.ligatures = d.bool(forKey: "damson.ligatures")
        config.ambiguousWide = d.bool(forKey: "damson.ambiguousWide")
        config.showScrollbar = d.bool(forKey: "damson.showScrollbar")
        if let h = d.object(forKey: "damson.paddingH") as? Double {
            config.padding.width = CGFloat(max(0, min(64, h)))
        }
        if let v = d.object(forKey: "damson.paddingV") as? Double {
            config.padding.height = CGFloat(max(0, min(64, v)))
        }
        if let o = d.object(forKey: "damson.backgroundOpacity") as? Double {
            config.backgroundOpacity = CGFloat(max(0.2, min(1.0, o)))
        }
        config.backgroundBlur = d.bool(forKey: "damson.backgroundBlur")
        if let raw = d.string(forKey: "damson.screenEffect"),
           let e = ScreenEffect(rawValue: raw) {
            config.screenEffect = e
        }
        if let i = d.object(forKey: "damson.screenEffectIntensity") as? Double {
            config.screenEffectIntensity = CGFloat(max(0.2, min(1.0, i)))
        }
        if let raw = d.string(forKey: "damson.glyphAppear"),
           let s = GlyphAnimStyle(rawValue: raw) {
            config.glyphAppear = s
        }
        if let raw = d.string(forKey: "damson.glyphDisappear"),
           let s = GlyphAnimStyle(rawValue: raw) {
            config.glyphDisappear = s
        }
        config.copyOnSelect = d.object(forKey: "damson.copyOnSelect") as? Bool ?? true
        if let s = d.object(forKey: "damson.scrollSpeed") as? Double {
            config.scrollSpeed = CGFloat(max(0.25, min(4.0, s)))
        }
        config.wordSeparators = d.string(forKey: "damson.wordSeparators") ?? ""
        config.animations = d.object(forKey: "damson.animations") as? Bool ?? true
        if let raw = d.string(forKey: "damson.cursorShape"),
           let shape = Grid.CursorShape(rawValue: raw) {
            config.cursorShape = shape
        }
        if let raw = d.string(forKey: "damson.cursorMotion"),
           let style = CursorMotionStyle(rawValue: raw) {
            config.cursorMotion = style
        }
        if let themeName = d.string(forKey: "damson.theme") {
            if themeName == DamsonTheme.customName {
                config.theme = CustomTheme.load().toTheme()
            } else if let theme = DamsonTheme.preset(named: themeName) {
                config.theme = theme
            }
        }
        // A new terminal's starting directory is the user's home directory. Otherwise it would
        // inherit the working directory Damson was launched from (e.g. an Xcode build, /tmp, a
        // command run from somewhere), forcing a cd every time. (The caller may override this
        // under an "inherit current directory" policy.)
        config.cwd = NSHomeDirectory()
        // Inject shell integration so the shell reports cwd via OSC 7 (zsh only). The source of split/new-tab cwd inheritance.
        config.env.merge(
            ShellIntegration.envOverrides(forShellPath: config.argv.first)
        ) { _, new in new }
        return config
    }
}

extension IMECompositionStyle {
    var displayName: String {
        switch self {
        case .none: return "None (no display, default)"
        case .underline: return "Underline (thin)"
        case .thickUnderline: return "Thick Underline (thick)"
        case .background: return "Background (highlight)"
        case .both: return "Background + Underline"
        }
    }
}
