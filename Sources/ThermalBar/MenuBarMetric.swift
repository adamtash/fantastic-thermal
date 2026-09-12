enum MenuBarMetricKind: Sendable {
    case temperature
    case fanPercentage
}

struct MenuBarMetric: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let menuBarLabel: String
    let accessibilityLabel: String
    let symbolName: String
    let kind: MenuBarMetricKind
}
