import AppKit
import SwiftUI
import CockpitShared
import SkillsKit

// MARK: - Overwrite request

/// A transfer the store refused because the destination already exists. Held
/// as plain values so the confirmation alert can replay it with `overwrite`.
private struct OverwriteRequest: Identifiable {
    let id = UUID()
    let level: ResourceLevel
    let mode: TransferMode
    let existing: URL
}

// MARK: - Resource detail

/// Detail pane for one skill, agent or command: identity, path, description,
/// markdown content and the actions that move it around.
struct ResourceDetailView: View {
    let resource: ClaudeResource
    let levels: [ResourceLevel]
    var onTransferred: (ClaudeResource) -> Void
    var onDeleted: () -> Void

    @Environment(CockpitStore.self) private var store

    @State private var content: AttributedString?
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var overwrite: OverwriteRequest?
    @State private var confirmDelete = false
    @State private var busy = false

    private var otherLevels: [ResourceLevel] { levels.filter { $0.id != resource.level.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
            Divider()
            actionBar
            Divider()
            MarkdownContentView(content: content, loadError: loadError)
        }
        .background(Theme.background)
        // Keyed on the modification date so an edit picked up by the directory
        // watcher reloads the pane; the identity itself never changes here.
        .task(id: resource.modifiedAt) { await load() }
        .alert(
            "Replace the Existing Resource?",
            isPresented: Binding(get: { overwrite != nil }, set: { if !$0 { overwrite = nil } }),
            presenting: overwrite
        ) { request in
            Button("Replace", role: .destructive) {
                overwrite = nil
                transfer(request.mode, to: request.level, overwriteExisting: true)
            }
            Button("Cancel", role: .cancel) { overwrite = nil }
        } message: { request in
            Text("“\(resource.name)” already exists in \(request.level.label):\n\(request.existing.path)\n\nThe replaced item is backed up before it is overwritten.")
        }
        .alert("Delete “\(resource.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A backup is created in \(store.paths.backupsDir.path) before deleting.")
        }
        .alert(
            "Error",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(resource.name)
                    .font(.display(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                LevelTag(label: resource.level.label)
                if resource.isSymlink {
                    Label("Symbolic Link", systemImage: "link")
                        .font(.label(10))
                        .foregroundStyle(Theme.slate)
                        .help("Copy, move and delete are disabled: edit the link's target directly.")
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            if let description = resource.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PathRow(url: resource.url) { copyPath() }
            Text("Modified \(AppFormat.relative(resource.modifiedAt)) · \(AppFormat.bytes(resource.sizeBytes))")
                .font(.label(10))
                .foregroundStyle(Theme.mist)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            Menu("Copy To…") {
                ForEach(otherLevels, id: \.id) { level in
                    Button(level.label) { transfer(.copy, to: level) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(otherLevels.isEmpty || busy || resource.isSymlink || store.isDemo)

            Menu("Move To…") {
                ForEach(otherLevels, id: \.id) { level in
                    Button(level.label) { transfer(.move, to: level) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(otherLevels.isEmpty || busy || resource.isSymlink || store.isDemo)

            Spacer(minLength: 8)

            Button {
                store.reveal(resource)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .controlSize(.small)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(busy || resource.isSymlink || store.isDemo)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    // MARK: Operations

    private func load() async {
        do {
            let raw = try await store.read(resource)
            content = MarkdownContentView.render(raw)
            loadError = nil
        } catch {
            content = nil
            loadError = error.localizedDescription
        }
    }

    private func transfer(_ mode: TransferMode, to level: ResourceLevel, overwriteExisting: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await store.transfer(resource, to: level, mode: mode, overwrite: overwriteExisting)
                onTransferred(result)
            } catch SkillsError.alreadyExists(let url) {
                overwrite = OverwriteRequest(level: level, mode: mode, existing: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performDelete() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.delete(resource)
                onDeleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resource.url.path, forType: .string)
        store.notice = String(localized: "Path copied to the clipboard")
    }
}

// MARK: - Plugin detail

/// Read-only detail pane for a skill shipped by a plugin, plus the import
/// action that copies it into one of the writable levels.
struct PluginDetailView: View {
    let plugin: PluginResource
    let levels: [ResourceLevel]
    var onImported: (ClaudeResource) -> Void

    @Environment(CockpitStore.self) private var store

    @State private var content: AttributedString?
    @State private var loadError: String?
    @State private var errorMessage: String?
    @State private var overwrite: OverwriteRequest?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
            Divider()
            actionBar
            Divider()
            MarkdownContentView(content: content, loadError: loadError)
        }
        .background(Theme.background)
        .task { await load() }
        .alert(
            "Replace the Existing Skill?",
            isPresented: Binding(get: { overwrite != nil }, set: { if !$0 { overwrite = nil } }),
            presenting: overwrite
        ) { request in
            Button("Replace", role: .destructive) {
                overwrite = nil
                performImport(to: request.level, overwriteExisting: true)
            }
            Button("Cancel", role: .cancel) { overwrite = nil }
        } message: { request in
            Text("“\(plugin.name)” already exists in \(request.level.label):\n\(request.existing.path)\n\nThe replaced item is backed up before it is overwritten.")
        }
        .alert(
            "Error",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(plugin.qualifiedName)
                    .font(.display(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                LevelTag(label: String(localized: "Plugin"))
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            if let description = plugin.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PathRow(url: plugin.url) { copyPath() }
            Text("\(plugin.org) · version \(plugin.version) · read-only")
                .font(.label(10))
                .foregroundStyle(Theme.mist)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Menu("Import To…") {
                ForEach(levels, id: \.id) { level in
                    Button(level.label) { performImport(to: level) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(levels.isEmpty || busy || store.isDemo)

            Spacer(minLength: 8)

            Button {
                store.reveal(plugin)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func load() async {
        do {
            let raw = try await store.read(plugin)
            content = MarkdownContentView.render(raw)
            loadError = nil
        } catch {
            content = nil
            loadError = error.localizedDescription
        }
    }

    private func performImport(to level: ResourceLevel, overwriteExisting: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await store.importPlugin(plugin, to: level, overwrite: overwriteExisting)
                onImported(result)
            } catch SkillsError.alreadyExists(let url) {
                overwrite = OverwriteRequest(level: level, mode: .copy, existing: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plugin.url.path, forType: .string)
        store.notice = String(localized: "Path copied to the clipboard")
    }
}

// MARK: - Shared pieces

/// Small violet capsule naming the level a resource lives at.
private struct LevelTag: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.label(10))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.violet)
            .background(Capsule().fill(Theme.violet.opacity(0.14)))
    }
}

/// Selectable path with a copy button.
private struct PathRow: View {
    let url: URL
    var copy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(url.path)
                .font(.data(11))
                .foregroundStyle(Theme.slate)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button(action: copy) {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Copy the path")
            .accessibilityLabel("Copy the path")
        }
    }
}

/// Scrollable markdown body, rendered inline so the source layout survives.
struct MarkdownContentView: View {
    let content: AttributedString?
    let loadError: String?

    /// Inline-only parsing keeps every line break, which matters for a file
    /// read as source rather than reflowed as an article.
    static func render(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    var body: some View {
        ScrollView {
            Group {
                if let loadError {
                    SourceBanner(kind: .error, message: loadError)
                } else if let content {
                    Text(content)
                        .font(.data(12))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the file…").font(.system(size: 12)).foregroundStyle(Theme.slate)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
