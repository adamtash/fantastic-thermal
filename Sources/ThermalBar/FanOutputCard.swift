import SwiftUI
import ThermalBarCore

struct FanOutputCard: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Fan output", systemImage: "fanblades.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(fanCountLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if store.snapshot.fans.isEmpty {
                Text("No controllable fans detected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.snapshot.fans.prefix(2))) { fan in
                    FanOutputRow(fan: fan)
                }

                if store.snapshot.fans.count > 2 {
                    Text("Showing the first two detected fans")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Actual speed · percentage uses each fan’s firmware range")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var fanCountLabel: String {
        let count = store.snapshot.fans.count
        return count == 1 ? "1 fan" : "\(count) fans"
    }
}
