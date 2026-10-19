import SwiftUI

// MARK: - The hint with the keys ("?")
//
// Drawn over the content of the page that is shown, inside the island: no window of its own and
// no change of the island's size. It lists the keys that work where the person is, read from the
// same table the monitor uses (`IslandKeyTable`), so it can never promise a key that does nothing.
// Static: no animation, no timer. "?" or ⎋ puts it away, and so does any key of the island.

struct IslandKeyHelpView: View {
    let area: IslandKeyArea

    /// The keys of the page first, the ones that work everywhere after them.
    private var rows: [IslandKeyRow] {
        let all = IslandKeyTable.rows(area: area)
        return all.filter { $0.group != .everywhere } + all.filter { $0.group == .everywhere }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 14, alignment: .topLeading)],
                      alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: row.keys)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .frame(width: 92, alignment: .leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(LocalizedStringKey(row.descriptionKey))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(hex: "#B0B5BE"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#141518")))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
