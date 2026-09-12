import SwiftUI
import AppKit
import ThermalBarCore

struct PopoverView: View {
    let store: ThermalStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HeaderView(store: store)
                StatusCard(store: store)
                ModePicker(store: store)
                ControlFeedback(store: store)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .opacity(0.45)

            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    Color.clear.frame(height: 0).id("controls-top")
                    ControlSection(store: store)

                    FanOutputCard(store: store)
                    HistoryChartCard(store: store)
                    SensorSummary(store: store)

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("Quit Fantastic Thermal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
              }
              .onChange(of: store.mode) { _, _ in proxy.scrollTo("controls-top", anchor: .top) }
            }
        }
        .frame(width: 382, height: 610)
        .background(.regularMaterial)
        .task {
            store.startMonitoring()
        }
    }
}

/// Drop the view tree while hidden: history still collects, but no charts,
/// labels, or menus are laid out on every background sensor sample.
struct PopoverRootView: View {
    let store: ThermalStore

    var body: some View {
        Group {
            if store.isPanelVisible { PopoverView(store: store) }
            else { Color.clear }
        }
        .frame(width: 382, height: 610)
    }
}

private struct ControlSection: View {
    let store: ThermalStore

    var body: some View {
        switch store.mode {
        case .automatic:
            AutomaticCard()
        case .fixed:
            if store.shouldShowHelperCard {
                HelperCard(store: store)
            }
            FixedControlCard(store: store)
        case .autoPlus:
            if store.shouldShowHelperCard {
                HelperCard(store: store)
            }
            AutoPlusCard(store: store)
            TriggerList(store: store)
        }

    }
}

private struct ControlFeedback: View {
    let store: ThermalStore
    var body: some View {
        if let error = store.lastError { ErrorCard(message: error) }
        else if !store.snapshot.isAvailable && store.lastRefreshDate == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Discovering sensors…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HeaderView: View {
    let store: ThermalStore

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fantastic Thermal")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(store.modeDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
                title: store.mode.title,
                color: store.mode == .automatic ? .secondary : .accentColor
            )
        }
    }
}

private struct StatusCard: View {
    let store: ThermalStore

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current temperature")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(temperatureColor)

                    Text(store.primaryTemperature.map { "\(Int($0.celsius.rounded()))°C" } ?? "—")
                        .font(.system(size: 39, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(temperatureColor)
                }

                Text(store.primaryTemperature?.name ?? "No temperature sensor")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "thermometer.high")
                    Text(hottestLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(height: 13)
                .opacity(hottestLabel.isEmpty ? 0 : 1)
                .accessibilityHidden(hottestLabel.isEmpty)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.isControlling ? Color.accentColor : Color.secondary)
                if let fan = store.primaryFan {
                    Text("\(fan.currentRPM.formatted()) RPM")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(fan.mode == .manual ? "manual target" : fan.mode == .unknown ? "mode unavailable" : "system control")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fanless / monitor only")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var hottestLabel: String {
        guard let hottest = store.hottestTemperature, let primary = store.primaryTemperature,
              hottest.id != primary.id, hottest.celsius > primary.celsius + 3 else { return "" }
        return "Hottest · \(hottest.name) · \(Int(hottest.celsius.rounded()))°C"
    }

    private var temperatureColor: Color {
        guard let temperature = store.primaryTemperature?.celsius else { return .secondary }
        if temperature >= 85 { return .red }
        if temperature >= 70 { return .orange }
        return .primary
    }
}

private struct ModePicker: View {
    let store: ThermalStore

    var body: some View {
        Picker("Control mode", selection: Binding(
            get: { store.mode },
            set: { store.setMode($0) }
        )) {
            ForEach(ControlMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Control mode")
    }
}

private struct AutomaticCard: View {
    var body: some View {
        InfoCard(
            icon: "checkmark.shield.fill",
            tint: .green,
            title: "macOS Auto",
            message: "Fantastic Thermal is monitoring only. Apple’s thermal controller has full control of the fans."
        )
    }
}

private struct HelperCard: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: store.helperVerificationIsPositive ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(store.helperVerificationIsPositive ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan-control helper")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.helperStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.helperVerificationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let verification = store.helperVerificationText {
                Label(
                    verification,
                    systemImage: store.helperVerificationIsPositive ? "checkmark.circle.fill" : "info.circle.fill"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(store.helperVerificationIsPositive ? .green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if store.canReinstallHelper || !store.helperIsEnabled {
                HStack(spacing: 8) {
                    if store.canReinstallHelper {
                        Button("Reinstall") {
                            Task { await store.reinstallHelper() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.helperVerificationInProgress)
                        .accessibilityIdentifier("reinstallHelperButton")
                    }

                    if !store.helperIsEnabled {
                        Button("Open Settings") {
                            store.requestHelperSetup()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10, weight: .semibold))
                    }
                }
            }
        }
        .padding(13)
        .background(store.helperVerificationIsPositive ? Color.green.opacity(0.08) : Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct FixedControlCard: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Fixed target", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int(store.configuration.fixedPercent.rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            Slider(value: Binding(
                get: { store.configuration.fixedPercent },
                set: { store.setFixedPercent($0) }
            ), in: 0...100, step: 1, onEditingChanged: { editing in
                if !editing { store.applyCurrentSetting() }
            })
            .accessibilityLabel("Fixed fan target")
            .accessibilityValue("\(Int(store.configuration.fixedPercent)) percent of firmware range")

            HStack(spacing: 7) {
                ForEach(QuickPreset.allCases, id: \.self) { preset in
                    QuickPresetButton(preset: preset, isSelected: isSelected(preset)) {
                        store.applyPreset(preset)
                    }
                }
            }
        }
        .padding(15)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func isSelected(_ preset: QuickPreset) -> Bool {
        abs(store.configuration.fixedPercent - preset.percent) < 0.1
    }
}

private struct AutoPlusCard: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto + triggers")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Never below the last macOS Auto target. Each trigger smoothly ramps fan speed from its start temperature to its upper bound.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Label("Auto floor", systemImage: "arrow.down.to.line")
                Spacer()
                if let floor = store.appliedControl?.targets.first?.floorRPM {
                    Text("≥ \(floor.formatted()) RPM")
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Sampling…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(15)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TriggerList: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Temperature triggers")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Independent curves · highest result wins")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.addTrigger()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Add temperature trigger")
                .disabled(store.configuration.triggers.count >= 32)
            }

            ForEach(store.configuration.triggers) { rule in
                TriggerRow(store: store, rule: rule)
            }

            if store.configuration.triggers.isEmpty {
                Text("Add a rule to raise fan speed when a sensor gets warm.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            }
        }
    }
}

private struct TriggerRow: View {
    let store: ThermalStore
    let rule: TriggerRule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Toggle(isOn: enabledBinding) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Enable \(rule.sensorName) trigger")

                Menu {
                    ForEach(store.snapshot.temperatures) { sensor in
                        Button {
                            store.updateTrigger(rule) {
                                $0.sensorKey = sensor.id
                                $0.sensorName = sensor.name
                            }
                        } label: {
                            Label(
                                "\(sensor.name) · \(Int(sensor.celsius.rounded()))°C",
                                systemImage: sensor.kind.iconName
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.sensor(for: rule)?.kind.iconName ?? "waveform.path.ecg")
                        Text(selectedSensorLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                if isActive, let sensor = store.sensor(for: rule) {
                    Text("\(Int(rule.percent(at: sensor.celsius).rounded()))% now")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button(role: .destructive) {
                    store.removeTrigger(rule)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(rule.sensorName) trigger")
            }

            HStack {
                Text("Temperature ramp")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rule.summary)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 8) {
                Text("Curve")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Curve", selection: curveBinding) {
                    ForEach(TriggerCurve.allCases, id: \.self) { curve in
                        Text(curve.title).tag(curve)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)
            }

            HStack(spacing: 14) {
                CurveControl(
                    title: "Start temp",
                    systemImage: "thermometer.medium",
                    valueText: "\(Int(rule.thresholdC.rounded()))°",
                    value: thresholdBinding,
                    range: 25...105
                )
                CurveControl(
                    title: "Upper temp",
                    systemImage: "thermometer.high",
                    valueText: "\(Int(rule.upperTemperatureC.rounded()))°",
                    value: upperTemperatureBinding,
                    range: 36...110
                )
            }

            HStack(spacing: 14) {
                CurveControl(
                    title: "Fan at start",
                    systemImage: "fanblades",
                    valueText: "\(Int(rule.startPercent.rounded()))%",
                    value: startPercentBinding,
                    range: 2...100
                )
                CurveControl(
                    title: "Fan at upper",
                    systemImage: "fanblades.fill",
                    valueText: "\(Int(rule.targetPercent.rounded()))%",
                    value: targetBinding,
                    range: 2...100
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(rule.isEnabled ? 0.055 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(rule.isEnabled ? 1 : 0.65)
    }

    private var isActive: Bool {
        store.triggerDecision.matchedRuleIDs.contains(rule.id)
    }

    private var selectedSensorLabel: String {
        guard let sensor = store.sensor(for: rule) else {
            return rule.sensorName
        }
        return "\(rule.sensorName) · \(Int(sensor.celsius.rounded()))°C"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { value in
                store.updateTrigger(rule) { $0.isEnabled = value }
            }
        )
    }

    private var curveBinding: Binding<TriggerCurve> {
        Binding(
            get: { rule.curve },
            set: { value in
                store.updateTrigger(rule) { $0.curve = value }
            }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { rule.thresholdC },
            set: { value in
                store.updateTrigger(rule) {
                    let rounded = value.rounded()
                    $0.thresholdC = rounded
                    if $0.upperTemperatureC <= rounded {
                        $0.upperTemperatureC = min(110, rounded + 1)
                    }
                }
            }
        )
    }

    private var upperTemperatureBinding: Binding<Double> {
        Binding(
            get: { rule.upperTemperatureC },
            set: { value in
                store.updateTrigger(rule) {
                    $0.upperTemperatureC = max($0.thresholdC + 1, value.rounded())
                }
            }
        )
    }

    private var startPercentBinding: Binding<Double> {
        Binding(
            get: { rule.startPercent },
            set: { value in
                store.updateTrigger(rule) {
                    let rounded = min(100, max(2, (value / 2).rounded() * 2))
                    $0.startPercent = rounded
                    $0.targetPercent = max($0.targetPercent, rounded)
                }
            }
        )
    }

    private var targetBinding: Binding<Double> {
        Binding(
            get: { rule.targetPercent },
            set: { value in
                store.updateTrigger(rule) {
                    let rounded = min(100, max(2, (value / 2).rounded() * 2))
                    $0.targetPercent = rounded
                    $0.startPercent = min($0.startPercent, rounded)
                }
            }
        )
    }
}

private struct CurveControl: View {
    let title: String
    let systemImage: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(valueText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: title.hasPrefix("Fan") ? 2 : 1)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SensorSummary: View {
    let store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Useful sensors")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(store.snapshot.isAvailable ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(store.snapshot.isAvailable ? "Live" : "Offline")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 42, height: 16, alignment: .trailing)
                .accessibilityLabel(store.snapshot.isAvailable ? "Sensor data live" : "Sensor data unavailable")
            }

            HStack(spacing: 8) {
                SensorChip(sensor: store.batteryTemperature)
                SensorChip(sensor: store.hottestTemperature, fallback: "Hottest")
            }

            if !store.snapshot.temperatures.isEmpty {
                Menu {
                    ForEach(store.snapshot.temperatures) { sensor in
                        Button {
                            store.setSelectedSensor(sensor)
                        } label: {
                            Label("\(sensor.name) · \(Int(sensor.celsius.rounded()))°", systemImage: sensor.kind.iconName)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "scope")
                        Text("Primary sensor: \(store.primaryTemperature?.name ?? "Not selected")")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(13)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SensorChip: View {
    let sensor: TemperatureReading?
    var fallback: String = "Battery"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sensor?.kind.iconName ?? "thermometer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor?.name ?? fallback)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(sensor.map { "\(Int($0.celsius.rounded()))°" } ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct QuickPresetButton: View {
    let preset: QuickPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: preset.iconName)
                    .font(.system(size: 12, weight: .semibold))
                Text(preset.title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

var cardBackground: some ShapeStyle {
    Color.primary.opacity(0.055)
}
