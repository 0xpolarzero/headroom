import SwiftUI

struct MenuBarLabel: View {
    let percent: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if let percent {
                Text("\(Int(percent.rounded()))%").monospacedDigit()
            }
        }
    }
}
