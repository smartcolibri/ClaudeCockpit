import SwiftUI
import UsageKit

/// Editable per-family pricing: one row per `ModelFamily`, one column per rate, in USD
/// per million tokens.
///
/// Edits land in a local draft rather than straight into `store.pricing`: the store's
/// `didSet` persists the JSON *and* kicks off a full usage recompute, which would run
/// once per committed field. The draft is pushed to the store when a field commits
/// (blur or return) — `TextField(value:format:)` writes its binding then, not on every
/// keystroke.
struct PricingEditorView: View {
    @Environment(CockpitStore.self) private var store
    @State private var draft: PricingSettings = .default

    private var isDirty: Bool { draft != store.pricing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ratesTable
                explanation
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { draft = store.pricing }
        .onChange(of: draft) { _, _ in apply() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pricing by Model Family")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Restore Default Pricing") { draft = .default }
                    .disabled(draft == .default)
            }
            Text("Dollars per million tokens. Any change applies at once to the estimated cost, everywhere in the app.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Grid

    private var ratesTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("")
                columnHeader("Input")
                columnHeader("Output")
                columnHeader("Cache Write")
                columnHeader("Cache Read")
            }
            Divider().gridCellColumns(5).gridCellUnsizedAxes(.horizontal)
            ForEach(ModelFamily.allCases) { family in
                GridRow {
                    Text(family.rawValue.uppercased())
                        .font(.label())
                        .tracking(1.1)
                        .foregroundStyle(Theme.slate)
                        .gridColumnAlignment(.leading)
                    let rates = binding(for: family)
                    rateCell(rates.inputPerMTok)
                    rateCell(rates.outputPerMTok)
                    rateCell(rates.cacheWritePerMTok)
                    rateCell(rates.cacheReadPerMTok)
                }
            }
        }
        .panelStyle()
    }

    private func columnHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.label(10))
            .foregroundStyle(Theme.slate)
    }

    private func rateCell(_ value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            Text(verbatim: "$").foregroundStyle(Theme.slate)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
        }
        .font(.system(size: 12))
    }

    // MARK: Explanation

    private var explanation: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Token counts come from the Claude Code transcripts (~/.claude/projects): they are the real figures returned by the API, not an estimate.")
                Text("The cost, however, is estimated: only the “Input” rate is published per model. Output ≈ 5 × Input, Cache Write (5 min TTL) ≈ 1.25 × Input, Cache Read ≈ 0.1 × Input.")
                Text("“Restore Default Pricing” brings back the values coded in PricingSettings.default, which are not necessarily today's rates.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.slate)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("How the Cost Is Calculated")
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    // MARK: Plumbing

    private func binding(for family: ModelFamily) -> Binding<ModelPricing> {
        Binding(
            get: { draft.pricing(for: family) },
            set: { draft.setPricing($0, for: family) }
        )
    }

    private func apply() {
        guard isDirty else { return }
        store.pricing = draft
    }
}
