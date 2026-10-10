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
                .tabItem { Label("Général", systemImage: "gearshape") }
                .tag(Tab.general)
            AccessSettingsTab()
                .tabItem { Label("Accès", systemImage: "lock.open") }
                .tag(Tab.access)
            PricingEditorView()
                .tabItem { Label("Tarifs", systemImage: "dollarsign.circle") }
                .tag(Tab.pricing)
            RTKSettingsTab()
                .tabItem { Label("RTK", systemImage: "leaf.fill") }
                .tag(Tab.rtk)
            ProjectsSettingsTab()
                .tabItem { Label("Projets", systemImage: "folder") }
                .tag(Tab.projects)
            AboutSettingsTab()
                .tabItem { Label("À propos", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(
            minWidth: 560, idealWidth: 560, maxWidth: .infinity,
            minHeight: 520, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - Général

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

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Form {
            Section("Démarrage") {
                Toggle("Lancer à la connexion", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                Toggle("Barre de menus seulement (masquer l'icône du Dock)", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { _, newValue in store.setMenuBarOnly(newValue) }
                Text("L'icône de la barre de menus reste visible dans tous les cas.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Données") {
                Picker("Rafraîchissement de l'usage local", selection: $refreshSeconds) {
                    Text("10 secondes").tag(10)
                    Text("30 secondes").tag(30)
                    Text("60 secondes").tag(60)
                    Text("120 secondes").tag(120)
                }
                Text("Le nouvel intervalle s'applique après le cycle en cours.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            }

            Section("Affichage") {
                Picker("Devise", selection: $currency) {
                    Text("Dollar (USD)").tag("USD")
                    Text("Euro (EUR)").tag("EUR")
                }
                if currency == "EUR" {
                    TextField(
                        "Taux USD → EUR",
                        value: $eurRate,
                        format: .number.precision(.fractionLength(0...4)))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("Les montants sont calculés en dollars puis convertis avec ce taux.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }

            sessionsSection
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = store.launchAtLogin }
        .alert(
            "Lancement à la connexion",
            isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
        ) {
            Button("OK", role: .cancel) { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
        .alert("Reconstruire l'index des sessions ?", isPresented: $confirmRebuild) {
            Button("Annuler", role: .cancel) { confirmRebuild = false }
            Button("Reconstruire", role: .destructive) {
                Task { await store.rebuildSessionIndex() }
            }
        } message: {
            Text("Tous les transcripts de ~/.claude/projects seront relus depuis le début, ce qui peut prendre plusieurs minutes. Les transcripts eux-mêmes ne sont jamais modifiés.")
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        Section("Sessions") {
            Toggle("Indexer les transcripts", isOn: $sessionsIndexEnabled)
                // Restarts indexing and arms the FSEvents watcher, or stops both when the
                // toggle goes off. The store reads the flag itself.
                .onChange(of: sessionsIndexEnabled) { _, _ in store.sessionsIndexingDidChange() }
            Text("La section Sessions ne fonctionne qu'avec cet index. Il est reconstructible à tout moment et ne modifie jamais les transcripts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Afficher les lignes système dans les transcripts", isOn: $sessionsShowSystemLines)
            Text("Hooks, méta-lignes et pièces jointes, masqués par défaut.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("État de l'index") {
                Text(indexStateLabel)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Button("Reconstruire l'index") { confirmRebuild = true }
                    .disabled(store.sessionIndex.isRunning)
                if store.sessionIndex.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("Taille : \(Self.byteFormatter.string(fromByteCount: store.sessionIndex.dbSizeBytes))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
        }
    }

    private var indexStateLabel: String {
        let progress = store.sessionIndex
        if progress.isRunning {
            return "\(FRFormat.integer(progress.filesDone)) / \(FRFormat.integer(progress.filesTotal)) transcripts"
        }
        guard let last = progress.lastRun else { return "jamais indexé" }
        // `filesDone` counts the files the last pass actually read, which is a handful
        // on an incremental tick — so it is shown against `filesTotal`, never alone.
        return "dernier passage : \(FRFormat.integer(progress.filesDone)) / \(FRFormat.integer(progress.filesTotal)) · \(FRFormat.relative(last))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try store.setLaunchAtLogin(enabled)
        } catch let error as NSError {
            // Code 3 = l'app doit être installée dans /Applications ; fréquent en debug.
            loginError = error.code == 3
                ? "L'application doit se trouver dans /Applications pour être lancée à la connexion."
                : "Impossible de modifier le réglage : \(error.localizedDescription)"
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
            Section("Base de données RTK") {
                LabeledContent("Base utilisée") {
                    Text(store.rtkDatabaseURL?.path ?? "introuvable")
                        .font(.data(11))
                        .foregroundStyle(store.rtkDatabaseURL == nil ? Color.orange : Theme.slate)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Chemin personnalisé", text: $rtkPath, prompt: Text("Automatique"))
                    .font(.data(11))
                    .onSubmit { store.rtkPathDidChange() }
                HStack {
                    Button("Choisir…") { chooseDatabase() }
                    Button("Automatique") {
                        rtkPath = ""
                        store.rtkPathDidChange()
                    }
                    .disabled(rtkPath.isEmpty)
                    Spacer()
                    Button("Recharger") { Task { await store.refreshRTK() } }
                }
                Text("Laisser vide pour la détection automatique (Application Support, puis ~/.local/share/rtk).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Picks `history.db` or the folder holding it. Under the sandbox the choice is kept
    /// as a bookmark when no grant covers it, and on the **folder**: rtk runs SQLite in WAL
    /// mode, so reading needs the `-wal`/`-shm` siblings, and `rtk reset` recreates the file,
    /// which a bookmark on the file alone would not survive.
    private func chooseDatabase() {
        let start = store.rtkDatabaseURL?.deletingLastPathComponent()
            ?? store.paths.home.appendingPathComponent("Library/Application Support/rtk", isDirectory: true)
        guard let picked = store.access.runPanel(
            directory: start,
            message: "Choisissez history.db, ou le dossier qui le contient (recommandé).",
            prompt: "Choisir",
            chooseFiles: true) else { return }
        var isDir: ObjCBool = false
        let pickedFolder = FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir) && isDir.boolValue
        let folder = pickedFolder ? picked : picked.deletingLastPathComponent()
        let database = pickedFolder ? picked.appendingPathComponent("history.db") : picked
        if !store.isCovered(folder) {
            if pickedFolder {
                store.grant(folder)
            } else if store.grantFolder(
                startingAt: folder,
                message: "Autorisez aussi le dossier de la base : SQLite y lit son journal (-wal).") == nil {
                // Without the folder the file alone still reads, minus what sits in the journal.
                store.grant(picked)
            }
        }
        rtkPath = database.path
        store.rtkPathDidChange()
    }
}

// MARK: - Projets

private struct ProjectsSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.projectRoots) private var projectRoots = ""

    var body: some View {
        Form {
            Section("Racines de projets") {
                TextEditor(text: $projectRoots)
                    .font(.data(11))
                    .frame(minHeight: 140)
                Text("Une racine par ligne, le « ~ » est accepté. Vide = ~/DevApps et ~/Documents/GitHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.inaccessibleProjectRoots.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Racines non accessibles (hors des dossiers autorisés, ignorées) :")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                        ForEach(store.inaccessibleProjectRoots, id: \.path) { root in
                            Text(store.displayPath(root)).font(.data(11)).foregroundStyle(Theme.slate)
                        }
                    }
                }
                HStack {
                    Button("Ajouter une racine…") { addRoot() }
                    Button("Rescanner") { Task { await store.refreshSkills() } }
                    Spacer()
                    Text(FRFormat.plural(store.projectRoots.count - store.inaccessibleProjectRoots.count, "racine analysée"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Picks a folder, grants it when needed and appends it to the list.
    private func addRoot() {
        guard let url = store.access.runPanel(
            directory: store.paths.home, message: "Choisissez un dossier contenant vos projets.", prompt: "Ajouter")
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

// MARK: - Accès

private struct AccessSettingsTab: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.claudeConfigDir) private var configDir = ""

    var body: some View {
        Form {
            Section("Dossiers autorisés") {
                if !store.access.isSandboxed {
                    Text("Cette version n'est pas isolée (sandbox) : elle lit tous vos dossiers sans autorisation.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                if store.access.grants.isEmpty {
                    Text("Aucun dossier autorisé.")
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
                        Button("Réautoriser") { reauthorize(grant) }
                        Button("Retirer", role: .destructive) { store.access.remove(grant) }
                    }
                }
                HStack {
                    Button("Ajouter…") {
                        store.grantFolder(startingAt: store.paths.home, message: "Choisissez un dossier à autoriser.")
                    }
                    Spacer()
                }
            }

            Section("Couverture") {
                coverageRow("Données Claude (\(store.displayPath(store.paths.claudeDir)))", store.claudeAccess)
                coverageRow("Dossier personnel (skills liés, projets)", store.homeAccess)
                coverageRow("Base RTK", store.rtkAccess)
                coverageRow(
                    "Racines de projets",
                    store.inaccessibleProjectRoots.isEmpty,
                    detail: store.inaccessibleProjectRoots.isEmpty ? nil
                        : "\(FRFormat.plural(store.inaccessibleProjectRoots.count, "racine")) non accessible(s)")
            }

            Section("Dossier de configuration Claude") {
                TextField("Dossier", text: $configDir, prompt: Text("~/.claude"))
                    .font(.data(11))
                    .onSubmit { store.accessDidChange() }
                HStack {
                    Button("Choisir…") { chooseConfigDir() }
                    Button("Par défaut") {
                        configDir = ""
                        store.accessDidChange()
                    }
                    .disabled(configDir.isEmpty)
                    Spacer()
                    Text("Utilisé : \(store.displayPath(store.paths.claudeDir))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                Text("Équivalent de la variable CLAUDE_CONFIG_DIR, qu'une app ouverte depuis le Finder ne voit pas. Vide = la variable si elle est définie, sinon ~/.claude.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func statusLabel(_ status: AccessStore.Grant.Status) -> String {
        switch status {
        case .active: "Actif"
        case .renewed: "Actif (autorisation renouvelée)"
        case .broken(let reason): "Introuvable : \(reason)"
        case .denied: "Accès refusé par macOS : réautorisez ce dossier"
        }
    }

    private func coverageRow(_ label: String, _ ok: Bool, detail: String? = nil) -> some View {
        LabeledContent(label) {
            Text(detail ?? (ok ? "autorisé" : "non autorisé"))
                .font(.system(size: 11))
                .foregroundStyle(ok ? Theme.emerald : .orange)
        }
    }

    private func reauthorize(_ grant: AccessStore.Grant) {
        let url = URL(fileURLWithPath: grant.path)
        guard let picked = store.access.runPanel(
            directory: url, message: "Confirmez le dossier \(store.displayPath(url)).") else { return }
        if AccessCoverage.normalized(picked.path) != grant.path { store.access.remove(grant) }
        store.grant(picked)
    }

    private func chooseConfigDir() {
        let start = store.paths.claudeDir
        guard let picked = store.access.runPanel(
            directory: start, message: "Choisissez le dossier de configuration de Claude Code.", prompt: "Choisir")
        else { return }
        configDir = store.displayPath(picked)
        // Granting fires `accessDidChange`, which also picks up the new directory.
        if store.isCovered(picked) { store.accessDidChange() } else { store.grant(picked) }
    }
}

// MARK: - À propos

private struct AboutSettingsTab: View {
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("À propos") {
                LabeledContent("Version installée") {
                    Text(currentVersion).monospacedDigit().foregroundStyle(Theme.slate)
                }
                Text("Cockpit for Claude — tableau de bord local pour Claude Code.")
                    .font(.system(size: 12))
                Text("© 2026 Smart Colibri. Tous droits réservés.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                Link("lauriat.fr", destination: URL(string: "https://lauriat.fr")!)
                Link("Site du projet", destination: URL(string: "https://smartcolibri.github.io/ClaudeCockpit/")!)
            }
        }
        .formStyle(.grouped)
    }
}
