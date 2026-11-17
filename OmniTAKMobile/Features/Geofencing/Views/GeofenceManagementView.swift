//
//  GeofenceManagementView.swift
//  OmniTAKMobile
//
//  The geofence list, and the form that makes a geofence.
//

import SwiftUI
import CoreLocation

// MARK: - Geofence List View

struct GeofenceListView: View {
    @ObservedObject private var manager = GeofenceManager.shared
    @ObservedObject private var service = GeofenceService.shared
    @State private var showCreateGeofence = false
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "#1E1E1E")
                    .ignoresSafeArea()

                if manager.geofences.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(manager.geofences) { geofence in
                                GeofenceCard(geofence: geofence, onShowOnMap: { showOnMap(geofence) })
                            }
                            recentEvents
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(L("geofence.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("geofence.done")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(Color(hex: "#FFFC00"))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showCreateGeofence = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Color(hex: "#FFFC00"))
                    }
                    .accessibilityLabel(L("geofence.create"))
                }
            }
        }
        .sheet(isPresented: $showCreateGeofence) {
            // Saving closes the form and the list with it, so the new geofence is the first
            // thing seen on the map behind them.
            GeofenceCreatorView(onSaved: { presentationMode.wrappedValue.dismiss() })
        }
    }

    /// Closes the list and centers the map on the geofence the way "Center" in the radial menu
    /// does, and also asks for the whole shape to be in view (`viewWidth`, in metres across the screen).
    private func showOnMap(_ geofence: Geofence) {
        guard let coordinate = geofence.centerCoordinate else { return }
        presentationMode.wrappedValue.dismiss()
        NotificationCenter.default.post(
            name: .radialMenuCenterMap,
            object: nil,
            userInfo: [
                "coordinate": coordinate,
                "viewWidth": GeofenceFraming.viewWidth(forExtent: geofence.extent ?? 0),
            ]
        )
    }

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("geofence.recent").uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
                Spacer()
                if !service.recentEvents.isEmpty {
                    Button(L("geofence.clearEvents")) { service.clearEvents() }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#FFFC00"))
                }
            }

            if service.recentEvents.isEmpty {
                Text(L("geofence.noEvents"))
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .padding(.vertical, 4)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(service.recentEvents) { event in
                        GeofenceEventRow(event: event)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text(L("geofence.empty.title"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            Text(L("geofence.empty.body"))
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: { showCreateGeofence = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(L("geofence.create"))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(hex: "#FFFC00"))
                .padding()
                .background(Color(hex: "#FFFC00").opacity(0.2))
                .cornerRadius(10)
            }
        }
        .padding()
    }
}

// MARK: - One event in the history

private struct GeofenceEventRow: View {
    let event: GeofenceEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.eventType.icon)
                .font(.system(size: 14))
                .foregroundColor(event.eventType.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(GeofenceAlertText.sentence(for: event))
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                Text(GeofenceAlertText.age(of: event.timestamp, now: Date(),
                                           locale: Locale(identifier: LocalizationManager.shared.current.rawValue)))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(hex: "#2A2A2A"))
        .cornerRadius(8)
    }
}

// MARK: - Geofence Card

struct GeofenceCard: View {
    let geofence: Geofence
    let onShowOnMap: () -> Void
    @ObservedObject private var manager = GeofenceManager.shared
    @ObservedObject private var service = GeofenceService.shared
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .metric

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(geofence.color.swiftUIColor)
                    .frame(width: 12, height: 12)

                Text(geofence.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { geofence.isActive },
                    set: { _ in manager.toggleGeofence(geofence) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#FFFC00")))
            }

            // Who is inside, as far as the app knows
            Text(GeofenceAlertText.stateLine(isActive: geofence.isActive,
                                             occupancy: service.occupancy[geofence.id] ?? GeofenceOccupancy()))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(geofence.isActive ? Color(hex: "#FFFC00") : .gray)

            Text(details)
                .font(.system(size: 12))
                .foregroundColor(.gray)

            HStack {
                Button(action: onShowOnMap) {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                        Text(L("geofence.showOnMap"))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#FFFC00"))
                }

                Spacer()

                Button(action: { manager.deleteGeofence(geofence) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text(L("geofence.delete"))
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color(hex: "#2A2A2A"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(geofence.isActive ? geofence.color.swiftUIColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    /// The shape, who it watches, and what it alerts on, on one quiet line.
    private var details: String {
        let shape: String
        switch geofence.type {
        case .circle:
            shape = L("geofence.shape.circle") + " " + GeofenceForm.radiusLabel(meters: geofence.radius ?? 0, unitSystem: unitSystem)
        case .polygon:
            shape = String(format: L("geofence.shape.polygon"), geofence.polygonCoordinates?.count ?? 0)
        }
        var watching: [String] = []
        if geofence.watchSelf { watching.append(L("geofence.watch.me")) }
        if geofence.watchContacts { watching.append(L("geofence.watch.teammates")) }
        var alerts: [String] = []
        if geofence.alertOnEntry { alerts.append(L("geofence.alerts.entry")) }
        if geofence.alertOnExit { alerts.append(L("geofence.alerts.exit")) }
        if geofence.dwellTimeThreshold > 0 {
            alerts.append(String(format: L("geofence.alerts.dwell"), Int(geofence.dwellTimeThreshold / 60)))
        }
        return ([shape] + [watching.joined(separator: ", ")] + [alerts.joined(separator: ", ")])
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - Geofence Creator View

struct GeofenceCreatorView: View {
    private enum Source { case onMap, drawing }

    @State private var name: String
    @State private var source: Source = .onMap
    @State private var radius: Double = GeofenceForm.defaultRadius
    @State private var selectedDrawing: UUID?
    @State private var watchSelf = true
    @State private var watchContacts = true
    @State private var alertOnEntry = true
    @State private var alertOnExit = true
    @State private var enableDwellAlert = false
    @State private var dwellTimeMinutes = 5
    @State private var selectedColor: GeofenceColor = .yellow
    @AppStorage("unitSystem") private var unitSystem: UnitSystem = .metric
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatRaw = CoordinateDisplayFormat.mgrs.rawValue
    @Environment(\.presentationMode) var presentationMode

    /// The middle of the map and the operator's drawings as they were when the form opened.
    @StateObject private var start = GeofenceFormStart()
    private var mapCenter: CLLocationCoordinate2D? { start.mapCenter }
    private var drawings: [GeofenceDrawingSource] { start.drawings }
    /// Called once the geofence is saved, after the form has closed.
    private let onSaved: () -> Void

    init(onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
        _name = State(initialValue: GeofenceForm.defaultName(
            existing: GeofenceManager.shared.geofences.map { $0.name },
            template: L("geofence.form.defaultName")))
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "#1E1E1E")
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        nameSection
                        positionSection
                        watchSection
                        alertsSection
                        colorSection
                        saveButton
                    }
                    .padding()
                }
            }
            .navigationTitle(L("geofence.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("geofence.cancel")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: Sections

    private func sectionTitle(_ key: String) -> some View {
        Text(L(key).uppercased())
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.gray)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("geofence.form.name")

            TextField(L("geofence.form.namePlaceholder"), text: $name)
                .textFieldStyle(PlainTextFieldStyle())
                .padding()
                .background(Color(hex: "#333333"))
                .cornerRadius(8)
                .foregroundColor(.white)
        }
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("geofence.form.position")

            HStack(spacing: 12) {
                SourceButton(icon: "scope", title: L("geofence.form.source.map"),
                             selected: source == .onMap, enabled: true) {
                    source = .onMap
                }
                SourceButton(icon: "pencil.and.outline", title: L("geofence.form.source.drawing"),
                             selected: source == .drawing, enabled: !drawings.isEmpty) {
                    source = .drawing
                }
            }

            if drawings.isEmpty {
                Text(L("geofence.form.noDrawings"))
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            switch source {
            case .onMap:
                mapCenterFields
            case .drawing:
                drawingPicker
            }
        }
    }

    private var mapCenterFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mapCenter {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("geofence.form.center"))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Text(coordinateFormat.format(mapCenter))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            } else {
                Text(L("geofence.form.noCenter"))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("geofence.form.radius"))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Spacer()
                    Text(GeofenceForm.radiusLabel(meters: radius, unitSystem: unitSystem))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                Slider(value: radiusIndex, in: 0...Double(GeofenceForm.radiusChoices.count - 1), step: 1)
                    .accentColor(Color(hex: "#FFFC00"))
            }
        }
    }

    /// The slider walks the list of radii, so its steps are small for small zones and wide for large ones.
    private var radiusIndex: Binding<Double> {
        Binding(
            get: { Double(GeofenceForm.radiusChoices.firstIndex(of: GeofenceForm.nearestRadius(to: radius)) ?? 0) },
            set: { radius = GeofenceForm.radiusChoices[min(max(Int($0.rounded()), 0), GeofenceForm.radiusChoices.count - 1)] }
        )
    }

    private var drawingPicker: some View {
        VStack(spacing: 8) {
            ForEach(drawings) { drawing in
                Button(action: { selectedDrawing = drawing.id }) {
                    HStack(spacing: 10) {
                        Image(systemName: drawing.type.icon)
                            .foregroundColor(selectedDrawing == drawing.id ? Color(hex: "#FFFC00") : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drawing.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text(drawingDetail(drawing))
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        if selectedDrawing == drawing.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(hex: "#FFFC00"))
                        }
                    }
                    .padding(10)
                    .background(selectedDrawing == drawing.id ? Color(hex: "#FFFC00").opacity(0.15) : Color(hex: "#333333"))
                    .cornerRadius(8)
                }
            }
        }
    }

    private func drawingDetail(_ drawing: GeofenceDrawingSource) -> String {
        switch drawing.type {
        case .circle:
            return L("geofence.shape.circle") + " " + GeofenceForm.radiusLabel(meters: drawing.radius ?? 0, unitSystem: unitSystem)
        case .polygon:
            return String(format: L("geofence.shape.polygon"), drawing.coordinates?.count ?? 0)
        }
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("geofence.form.watch")

            Toggle(L("geofence.watch.me"), isOn: $watchSelf)
                .foregroundColor(.white)
                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#FFFC00")))

            Toggle(L("geofence.watch.teammates"), isOn: $watchContacts)
                .foregroundColor(.white)
                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#FFFC00")))
        }
        .padding()
        .background(Color(hex: "#2A2A2A"))
        .cornerRadius(12)
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("geofence.form.alerts")

            Toggle(L("geofence.form.alertEntry"), isOn: $alertOnEntry)
                .foregroundColor(.white)
                .toggleStyle(SwitchToggleStyle(tint: Color.green))

            Toggle(L("geofence.form.alertExit"), isOn: $alertOnExit)
                .foregroundColor(.white)
                .toggleStyle(SwitchToggleStyle(tint: Color.red))

            Toggle(L("geofence.form.alertDwell"), isOn: $enableDwellAlert)
                .foregroundColor(.white)
                .toggleStyle(SwitchToggleStyle(tint: Color.orange))

            if enableDwellAlert {
                HStack {
                    Text(L("geofence.form.dwellAfter"))
                        .foregroundColor(.gray)
                    Picker("", selection: $dwellTimeMinutes) {
                        ForEach([1, 5, 10, 30, 60], id: \.self) { minutes in
                            Text(String(format: L("geofence.duration.minutes"), minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .accentColor(Color(hex: "#FFFC00"))
                }
            }
        }
        .padding()
        .background(Color(hex: "#2A2A2A"))
        .cornerRadius(12)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("geofence.form.color")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(GeofenceColor.allCases, id: \.self) { color in
                    Button(action: { selectedColor = color }) {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle()
                                    .stroke(selectedColor == color ? Color.white : Color.clear, lineWidth: 2)
                            )
                    }
                }
            }
        }
    }

    private var saveButton: some View {
        VStack(spacing: 8) {
            if !watchSelf && !watchContacts {
                Text(L("geofence.form.watchSomeone"))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            Button(action: save) {
                Text(L("geofence.form.save"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSave ? Color(hex: "#FFFC00") : Color.gray)
                    .cornerRadius(10)
            }
            .disabled(!canSave)
        }
    }

    // MARK: Saving

    private var coordinateFormat: CoordinateDisplayFormat {
        CoordinateDisplayFormat(rawValue: coordinateFormatRaw) ?? .mgrs
    }

    private var selectedSource: GeofenceDrawingSource? {
        drawings.first { $0.id == selectedDrawing }
    }

    /// A position to put it at, and someone to watch. The name never blocks Save: an empty one
    /// is replaced by the offered one.
    private var canSave: Bool {
        guard watchSelf || watchContacts else { return false }
        switch source {
        case .onMap: return mapCenter != nil
        case .drawing: return selectedSource != nil
        }
    }

    private func save() {
        guard canSave else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? GeofenceForm.defaultName(existing: GeofenceManager.shared.geofences.map { $0.name },
                                       template: L("geofence.form.defaultName"))
            : trimmed
        let dwell = enableDwellAlert ? Double(dwellTimeMinutes * 60) : 0

        let geofence: Geofence?
        switch source {
        case .onMap:
            geofence = mapCenter.map {
                Geofence(name: finalName, type: .circle, color: selectedColor,
                         alertOnEntry: alertOnEntry, alertOnExit: alertOnExit,
                         dwellTimeThreshold: dwell, watchSelf: watchSelf, watchContacts: watchContacts,
                         center: $0, radius: radius)
            }
        case .drawing:
            geofence = selectedSource?.makeGeofence(
                name: finalName, color: selectedColor,
                alertOnEntry: alertOnEntry, alertOnExit: alertOnExit,
                dwellTimeThreshold: dwell, watchSelf: watchSelf, watchContacts: watchContacts)
        }
        guard let geofence else { return }

        GeofenceManager.shared.addGeofence(geofence)
        GeofenceService.shared.requestNotificationPermissionIfNeeded()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        presentationMode.wrappedValue.dismiss()
        onSaved()
    }
}

// MARK: - What the form reads when it opens

/// The middle of the map (or the operator's position, if the map has not reported one yet) and
/// the operator's own drawings, read once. A `@StateObject` is made once per time the form is
/// shown, however often the form is built again (the list behind it redraws whenever an alert
/// comes in), so the center on screen is the one the geofence is saved at even while the map is
/// following a phone that is moving.
private final class GeofenceFormStart: ObservableObject {
    let mapCenter: CLLocationCoordinate2D?
    let drawings: [GeofenceDrawingSource]

    init() {
        mapCenter = MapCenterStore.shared.center ?? LocationManager.shared.location?.coordinate
        let store = DrawingStore()
        drawings = store.circles.map(GeofenceDrawingSource.fromCircle)
            + store.polygons.map(GeofenceDrawingSource.fromPolygon)
    }
}

// MARK: - Where the geofence goes

private struct SourceButton: View {
    let icon: String
    let title: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(selected ? Color(hex: "#FFFC00") : .gray)
            .frame(maxWidth: .infinity)
            .padding()
            .background(selected ? Color(hex: "#FFFC00").opacity(0.2) : Color(hex: "#333333"))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color(hex: "#FFFC00") : Color.clear, lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
    }
}
