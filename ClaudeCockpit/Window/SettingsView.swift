import SwiftUI
import AppKit
import CockpitShared

/// The preferences surface, shown both in the `Settings` scene (⌘,) and embedded in the
/// main window's detail area — hence flexible sizing rather than a fixed frame.
struct SettingsView: View {
    enum Tab: String, Hashable {
        case general, access, pricing, rtk, projects, about
    }

    /// Persisted so the snapshot mode can capture a given tab.
    @AppStorage(SettingsKey.settingsTab) private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AccessSettingsTab()
                .tabItem { Label("Access", systemImage: "lock.open") }
                .tag(Tab.access)
            PricingEditorView()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
                .tag(Tab.pricing)
            RTKSettingsTab()
                .tabItem { Label("RTK", systemImage: "leaf.fill") }
                .tag(Tab.rtk)
            ProjectsSettingsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(Tab.projects)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(
            minWidth: 560, idealWidth: 560, maxWidth: .infinity,
            minHeight: 520, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(CockpitStore.self) private var store

    @AppStorage(SettingsKey.menuBarOnly) private var menuBarOnly = false
    @AppStorage(SettingsKey.usageRefreshSeconds) private var refreshSeconds = 30
    @AppStorage(SettingsKey.currency) private var currency = "USD"
    @AppStorage(SettingsKey.eurRate) private var eurRate = 0.92
    @AppStorage(SettingsKey.sessionsIndexEnabled) private var sessionsIndexEnabled = true
    @AppStorage(SettingsKey.sessionsShowSystemLines) private var sessionsShowSystemLines = false

    /// Mirrors `SMAppService`'s real state: the store exposes it read-only, so the toggle
    /// keeps its own copy and reverts it when registration throws.
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var confirmRebuild = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                    .disabled(store.isDemo)
                Toggle("Menu Bar Only (Hide Dock Icon)", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, newValue in store.setMenuBarOnly(newValue) }
                Text("The menu bar icon stays visible in every case.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Data") {
                Picker("Local usage refresh", selection: $refreshSeconds) {
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                }
                Text("The new interval applies after the current cycle.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Display") {
                Picker("Currency", selection: $currency) {
                    Text("US Dollar (USD)").tag("USD")
                    Text("Euro (EUR)").tag("EUR")
                }
                if currency == "EUR" {
                    TextField(
                        "USD → EUR rate",
                        value: $eurRate,
                        format: .number.precision(.fractionLength(0...4)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("Amounts are computed in dollars, then converted with this rate.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }

            sessionsSection
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = store.launchAtLogin }
        .alert(
            "Launch at Login",
            isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
        ) {
            Button("OK", role: .cancel) { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
        .alert("Rebuild the Sessions Index?", isPresented: $confirmRebuild) {
            Button("Cancel", role: .cancel) { confirmRebuild = false }
            Button("Rebuild", role: .destructive) {
                Task { await store.rebuildSessionIndex() }
            }
        } message: {
            Text("Every transcript in ~/.claude/projects will be read again from the start, which can take several minutes. The transcripts themselves are never changed.")
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        Section("Sessions") {
            Toggle("Index Transcripts", isOn: $sessionsIndexEnabled)
                // Restarts indexing and arms the FSEvents watcher, or stops both when the
                // toggle goes off. The store reads the flag itself.
                .onChange(of: sessionsIndexEnabled) { _, _ in store.sessionsIndexingDidChange() }
            Text("The Sessions section only works with this index. It can be rebuilt at any time and never changes the transcripts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show System Lines in Transcripts", isOn: $sessionsShowSystemLines)
            Text("Hooks, meta lines and attachments, hidden by default.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Index status") {
                Text(indexStateLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Button("Rebuild Index") { confirmRebuild = true }
                    .disabled(store.sessionIndex.isRunning)
                if store.sessionIndex.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("Size: \(AppFormat.bytes(store.sessionIndex.dbSizeBytes))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
        }
    }

    private var indexStateLabel: String {
        let progress = store.sessionIndex
        if progress.isRunning {
            return String(localized: "\(AppFormat.integer(progress.filesDone)) / \(AppFormat.integer(progress.filesTotal)) transcripts", locale: AppFormat.locale)
        }
        guard let last = progress.lastRun else { return String(localized: "never indexed") }
        // `filesDone` counts the files the last pass actually read, which is a handful
        // on an incremental tick — so it is shown against `filesTotal`, never alone.
        return String(localized: "last pass: \(AppFormat.integer(progress.filesDone)) / \(AppFormat.integer(progress.filesTotal)) · \(AppFormat.relative(last, standalone: true))", locale: AppFormat.locale)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try store.setLaunchAtLogin(enabled)
        } catch let error as NSError {
            // Code 3 = the app must be installed in /Applications; common in debug builds.
            loginError = error.code == 3
                ? String(localized: "The app must be in /Applications to launch at login.")
                : String(localized: "Could not change the setting: \(error.localizedDescription)", locale: AppFormat.locale)
            launchAtLogin = store.launchAtLogin
        }
    }
}

// MARK: - RTK

private struct RTKSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.rtkDBPath) private var rtkPath = ""

    var body: some View {
        Form {
            Section("RTK Database") {
                LabeledContent("Database in use") {
                    Text(store.rtkDatabaseURL?.path ?? String(localized: "not found"))
                        .font(.data(11))
                        .foregroundStyle(store.rtkDatabaseURL == nil ? Color.orange : Theme.slate)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Group {
                    TextField("Custom path", text: $rtkPath, prompt: Text("Automatic"))
                        .font(.data(11))
                        .onSubmit { store.rtkPathDidChange() }
                }
                .disabled(store.isDemo)
                HStack {
                    Button("Choose…") { chooseDatabase() }
                        .disabled(store.isDemo)
                    Button("Automatic") {
                        rtkPath = ""
                        store.rtkPathDidChange()
                    }
                    .disabled(rtkPath.isEmpty || store.isDemo)
                    Spacer()
                    Button("Reload") { Task { await store.refreshRTK() } }
                }
                Text("Leave empty for automatic detection (Application Support, then ~/.local/share/rtk).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isDemo { DemoLockedNote() }
            }
        }
        .formStyle(.grouped)
    }

    /// Picks `history.db` or the folder holding it. Under the sandbox the choice is kept
    /// as a bookmark when no grant covers it, and always on the **folder**: rtk runs SQLite in
    /// WAL mode, so reading needs the `-wal`/`-shm` siblings, and `rtk reset` recreates the
    /// file, which a bookmark on the file alone would not survive. Without the folder nothing
    /// is stored: the file alone would show stale data as if it were current.
    private func chooseDatabase() {
        let start = store.rtkDatabaseURL?.deletingLastPathComponent()
            ?? store.paths.home.appendingPathComponent("Library/Application Support/rtk", isDirectory: true)
        guard let picked = store.access.runPanel(
            directory: start,
            message: String(localized: "Choose history.db, or the folder that contains it (recommended)."),
            prompt: String(localized: "Choose"),
            chooseFiles: true) else { return }
        var isDir: ObjCBool = false
        let pickedFolder = FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir) && isDir.boolValue
        let folder = pickedFolder ? picked : picked.deletingLastPathComponent()
        let database = pickedFolder ? picked.appendingPathComponent("history.db") : picked
        if store.isCovered(folder) {
            rtkPath = database.path
            store.rtkPathDidChange()
            return
        }
        var grantTarget = folder
        if !pickedFolder {
            guard let confirmed = store.access.runPanel(
                directory: folder,
                message: String(localized: "Also allow the database folder: SQLite reads its journal (-wal) there.")),
                AccessCoverage.isPath(folder.path, inside: confirmed.path)
            else {
                store.notice = String(localized: "RTK database not saved: access to the folder \(store.displayPath(folder)) is needed, because SQLite reads its journal (-wal) there. Without it, the figures shown would be stale.", locale: AppFormat.locale)
                return
            }
            grantTarget = confirmed
        }
        // Set before granting: the reload the grant triggers then already reads this database.
        rtkPath = database.path
        if !store.grant(grantTarget) { store.rtkPathDidChange() }
    }
}

// MARK: - Projects

private struct ProjectsSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.projectRoots) private var projectRoots = ""

    var body: some View {
        Form {
            Section("Project Roots") {
                TextEditor(text: $projectRoots)
                    .font(.data(11))
                    .frame(minHeight: 140)
                    .disabled(store.isDemo)
                Text("One root per line; “~” is accepted. Empty = ~/DevApps and ~/Documents/GitHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.inaccessibleProjectRoots.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Roots not accessible (outside the allowed folders, ignored):")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                        ForEach(store.inaccessibleProjectRoots, id: \.path) { root in
                            Text(store.displayPath(root)).font(.data(11)).foregroundStyle(Theme.slate)
                        }
                    }
                }
                HStack {
                    Button("Add Root…") { addRoot() }
                        .disabled(store.isDemo)
                    Button("Rescan") { Task { await store.refreshSkills() } }
                    Spacer()
                    Text("\(store.projectRoots.count - store.inaccessibleProjectRoots.count) roots scanned")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                if store.isDemo { DemoLockedNote() }
            }
        }
        .formStyle(.grouped)
    }

    /// Picks a folder, grants it when needed and appends it to the list.
    private func addRoot() {
        guard let url = store.access.runPanel(
            directory: store.paths.home, message: String(localized: "Choose a folder that contains your projects."), prompt: String(localized: "Add"))
        else { return }
        if !store.isCovered(url) { store.grant(url) }
        var lines = projectRoots.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // An empty list stands for the defaults: keep them when adding the first custom root.
        if lines.isEmpty { lines = store.paths.defaultProjectRoots.map { store.displayPath($0) } }
        let entry = store.displayPath(url)
        if !lines.contains(entry) { lines.append(entry) }
        projectRoots = lines.joined(separator: "\n")
        Task { await store.refreshSkills() }
    }
}

// MARK: - Access

private struct AccessSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.claudeConfigDir) private var configDir = ""
    /// What the field shows. Written to the setting only once valid and the typing has
    /// paused, so no reload ever runs on a half-typed or relative path.
    @State private var configDraft = ""
    @State private var configError: String?

    var body: some View {
        Form {
            Section("Allowed Folders") {
                if !store.access.isSandboxed {
                    Text("This version is not sandboxed: it reads all your folders without permission.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                if store.access.grants.isEmpty {
                    Text("No allowed folders.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.slate)
                }
                ForEach(store.access.grants) { grant in
                    HStack(spacing: 8) {
                        Image(systemName: grant.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(grant.isUsable ? Theme.emerald : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.displayPath(URL(fileURLWithPath: grant.path))).font(.data(11))
                            Text(statusLabel(grant.status)).font(.system(size: 10)).foregroundStyle(Theme.slate)
                        }
                        Spacer()
                        Button("Reauthorize") { store.reauthorize(grant) }
                            .disabled(store.isDemo)
                        Button("Remove", role: .destructive) { store.revoke(grant) }
                            .disabled(store.isDemo)
                    }
                }
                HStack {
                    Button("Add…") {
                        store.grantFolder(startingAt: store.paths.home, message: String(localized: "Choose a folder to allow."))
                    }
                    .disabled(store.isDemo)
                    Spacer()
                }
                if store.isDemo { DemoLockedNote() }
            }

            Section("Coverage") {
                coverageRow("Claude data (\(store.displayPath(store.paths.claudeDir)))", store.claudeAccess)
                coverageRow("Home folder (linked skills, projects)", store.homeAccess)
                coverageRow("RTK database", store.rtkAccess)
                coverageRow(
                    "Project roots",
                    store.inaccessibleProjectRoots.isEmpty,
                    detail: store.inaccessibleProjectRoots.isEmpty ? nil
                        : String(localized: "\(store.inaccessibleProjectRoots.count) roots not accessible", locale: AppFormat.locale))
            }

            Section("Claude Configuration Folder") {
                TextField("Folder", text: $configDraft, prompt: Text(verbatim: "~/.claude"))
                    .font(.data(11))
                    .disabled(store.isDemo)
                    .onSubmit { applyConfigDraft() }
                    .task(id: configDraft) {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        applyConfigDraft()
                    }
                if let configError {
                    Text(configError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Choose…") { chooseConfigDir() }
                        .disabled(store.isDemo)
                    Button("Default") {
                        configDraft = ""
                        applyConfigDraft()
                    }
                    .disabled(configDir.isEmpty || store.isDemo)
                    Spacer()
                    Text("In use: \(store.displayPath(store.paths.claudeDir))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                Text("Equivalent to the CLAUDE_CONFIG_DIR variable, which an app opened from the Finder does not see. Empty = the variable if it is set, otherwise ~/.claude.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { configDraft = configDir }
    }

    /// Stores the field's value when it is usable and differs from the setting, then reloads.
    private func applyConfigDraft() {
        guard !store.isDemo else { return }
        let value = configDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudePaths.isUsableConfigDirSetting(value) else {
            configError = String(localized: "Relative path refused: enter an absolute path (/…) or one starting with ~/.")
            return
        }
        configError = nil
        guard value != configDir else { return }
        configDir = value
        store.accessDidChange()
    }

    private func statusLabel(_ status: AccessStore.Grant.Status) -> String {
        switch status {
        case .active: String(localized: "Active")
        case .renewed: String(localized: "Active (permission renewed)")
        case .broken(let reason): String(localized: "Not found: \(reason)", locale: AppFormat.locale)
        case .denied: String(localized: "Access denied by macOS: reauthorize this folder")
        }
    }

    private func coverageRow(_ label: LocalizedStringKey, _ ok: Bool, detail: String? = nil) -> some View {
        LabeledContent(label) {
            Text(detail ?? (ok ? String(localized: "allowed") : String(localized: "not allowed")))
                .font(.system(size: 11))
                .foregroundStyle(ok ? Theme.emerald : .orange)
        }
    }

    private func chooseConfigDir() {
        let start = store.paths.claudeDir
        guard let picked = store.access.runPanel(
            directory: start, message: String(localized: "Choose the Claude Code configuration folder."), prompt: String(localized: "Choose"))
        else { return }
        configDir = store.displayPath(picked)
        configDraft = configDir
        configError = nil
        // A stored grant fires `accessDidChange`, which also picks up the new directory; without
        // one (already covered, or the grant failed) the reload still has to run.
        if store.isCovered(picked) || !store.grant(picked) { store.accessDidChange() }
    }
}

// MARK: - Demo

/// Why a control is greyed out while the demo runs.
private struct DemoLockedNote: View {
    var body: some View {
        Text("Unavailable in demo mode: these settings concern your own data.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.slate)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Installed version") {
                    Text(currentVersion).monospacedDigit().foregroundStyle(Theme.slate)
                }
                Text("Cockpit for Claude — a local dashboard for Claude Code.")
                    .font(.system(size: 12))
                Text("© 2026 Smart Colibri. All rights reserved.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                Link(destination: URL(string: "https://lauriat.fr")!) { Text(verbatim: "lauriat.fr") }
                Link("Project Website", destination: URL(string: "https://smartcolibri.github.io/ClaudeCockpit/")!)
            }
        }
        .formStyle(.grouped)
    }
}
