//
//  RadialMenuView.swift
//  OmniTAKMobile
//
//  Radial menu matching the Android RadialMenu.kt design: no backing disc —
//  ring-outlined icon buttons floating directly on the map, a light scrim
//  for tap-away dismissal, and a center ✕ on the anchor. iOS keeps its
//  drag-to-select mechanic and haptics on top of that look.
//

import SwiftUI

// MARK: - Radial Menu View

/// Displays menu items in a ring around `centerPoint`, floating over the map.
struct RadialMenuView: View {
    @Binding var isPresented: Bool
    let centerPoint: CGPoint
    let configuration: RadialMenuConfiguration
    let onSelect: (RadialMenuAction) -> Void
    let onEvent: ((RadialMenuEvent) -> Void)?

    /// Optional context label shown in a small caption under the ring
    /// (e.g. tapped location name) — mirrors Android's RadialCaption.
    var centerLabel: String?

    @State private var selectedIndex: Int? = nil
    @State private var scale: CGFloat = 0
    @State private var itemsAppeared: Bool = false
    @State private var backgroundOpacity: Double = 0
    @State private var dragLocation: CGPoint? = nil

    // Haptic feedback generators
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionGenerator = UISelectionFeedbackGenerator()

    /// Neon accent used by the center ✕ — Android's TacticalAccent (logo green).
    private let accentColor = Color(hex: "#4ADE80")

    init(
        isPresented: Binding<Bool>,
        centerPoint: CGPoint,
        configuration: RadialMenuConfiguration,
        onSelect: @escaping (RadialMenuAction) -> Void,
        onEvent: ((RadialMenuEvent) -> Void)? = nil,
        centerLabel: String? = nil
    ) {
        self._isPresented = isPresented
        self.centerPoint = centerPoint
        self.configuration = configuration
        self.onSelect = onSelect
        self.onEvent = onEvent
        self.centerLabel = centerLabel
    }

    var body: some View {
        ZStack {
            // Light scrim — enough to lift the ring off the basemap without
            // hiding it (Android uses 0.35). Tap-away dismisses.
            Color.black
                .opacity(backgroundOpacity * 0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissMenu()
                }

            // Ring of floating item buttons — no backing disc.
            ZStack {
                ForEach(Array(configuration.items.enumerated()), id: \.element.id) { index, item in
                    RadialMenuItemButton(
                        item: item,
                        index: index,
                        isSelected: selectedIndex == index,
                        itemSize: effectiveItemSize,
                        offset: iconOffset(at: index),
                        appeared: itemsAppeared
                    )
                }

                // Center ✕ on the anchor (Android parity). Tapping it lands in
                // the drag overlay's dead zone → no selection → dismiss; the
                // glyph is the affordance.
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                    Circle()
                        .stroke(accentColor, lineWidth: 2)
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .frame(width: 44, height: 44)
                .opacity(itemsAppeared ? 1 : 0)

                // Context caption below the ring (Android RadialCaption).
                if let label = centerLabel {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .offset(y: effectiveRadius + effectiveItemSize / 2 + 16)
                        .opacity(itemsAppeared ? 1 : 0)
                        .lineLimit(1)
                }
            }
            .frame(width: totalMenuDiameter, height: totalMenuDiameter)
            .position(centerPoint)
            .scaleEffect(scale)

            // Drag gesture overlay
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDragChanged(value.location)
                        }
                        .onEnded { _ in
                            handleDragEnded()
                        }
                )
        }
        .onAppear {
            prepareHaptics()
            showMenu()
        }
        .onDisappear {
            hideMenu()
        }
    }

    // MARK: - Layout Calculations

    /// Larger item size for better touch targets (54pt minimum)
    private var effectiveItemSize: CGFloat {
        max(configuration.itemSize, 54)
    }

    /// Ring radius — icons sit at the full configured radius, like Android.
    private var effectiveRadius: CGFloat {
        configuration.radius
    }

    private var totalMenuDiameter: CGFloat {
        (effectiveRadius + effectiveItemSize / 2) * 2
    }

    /// Icon center position on the ring, starting at 12 o'clock.
    private func iconOffset(at index: Int) -> CGSize {
        let itemCount = configuration.items.count
        let angleStep = (2 * Double.pi) / Double(itemCount)
        let angle = Double(index) * angleStep - (Double.pi / 2)

        let x = effectiveRadius * CGFloat(cos(angle))
        let y = effectiveRadius * CGFloat(sin(angle))

        return CGSize(width: x, height: y)
    }

    // MARK: - Gesture Handling

    private func handleDragChanged(_ location: CGPoint) {
        dragLocation = location

        let newIndex = configuration.closestItemIndex(to: location, center: centerPoint)

        if newIndex != selectedIndex {
            selectedIndex = newIndex

            if let index = newIndex {
                if configuration.hapticFeedback {
                    selectionGenerator.selectionChanged()
                }
                onEvent?(.itemHighlighted(index))
            }
        }
    }

    private func handleDragEnded() {
        if let index = selectedIndex, index < configuration.items.count {
            let selectedItem = configuration.items[index]

            if configuration.hapticFeedback {
                impactGenerator.impactOccurred()
            }

            onSelect(selectedItem.action)
            onEvent?(.itemSelected(selectedItem.action))
        } else {
            onEvent?(.dismissed)
        }

        dismissMenu()
    }

    // MARK: - Menu State

    private func prepareHaptics() {
        if configuration.hapticFeedback {
            impactGenerator.prepare()
            selectionGenerator.prepare()
        }
    }

    private func showMenu() {
        onEvent?(.opened(centerPoint))

        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            scale = 1.0
            backgroundOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                itemsAppeared = true
            }
        }

        if configuration.hapticFeedback {
            impactGenerator.impactOccurred(intensity: 0.6)
        }
    }

    private func hideMenu() {
        withAnimation(.easeOut(duration: 0.15)) {
            itemsAppeared = false
        }
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 0
            backgroundOpacity = 0
        }
    }

    private func dismissMenu() {
        onEvent?(.dismissed)

        withAnimation(.easeOut(duration: 0.15)) {
            itemsAppeared = false
        }

        withAnimation(.easeOut(duration: 0.2).delay(0.05)) {
            scale = 0
            backgroundOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isPresented = false
        }
    }
}

// MARK: - Radial Menu Item Button

/// One floating ring item: transparent circle, 2pt tinted ring, tinted icon —
/// the Android RadialMenu item look. Selection (drag-over) fills the circle
/// with the item color and pops it slightly.
struct RadialMenuItemButton: View {
    let item: RadialMenuItem
    let index: Int
    let isSelected: Bool
    let itemSize: CGFloat
    let offset: CGSize
    let appeared: Bool

    private var isDestructive: Bool {
        item.action == .deleteMarker || item.action == .deleteDrawing
    }

    private var itemColor: Color {
        isDestructive ? .red : item.color
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? itemColor.opacity(0.35) : Color.black.opacity(0.35))
            Circle()
                .stroke(itemColor, lineWidth: 2)

            Image(systemName: item.icon)
                .font(.system(size: itemSize * 0.42, weight: .semibold))
                .foregroundColor(isSelected ? .white : itemColor)
        }
        .frame(width: itemSize, height: itemSize)
        .scaleEffect(appeared ? (isSelected ? 1.12 : 1.0) : 0.3)
        .opacity(appeared ? 1.0 : 0)
        .offset(offset)
        .accessibilityLabel(item.label)
        .animation(.spring(response: 0.35, dampingFraction: 0.65).delay(Double(index) * 0.03), value: appeared)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Radial Menu Modifier

/// View modifier to add radial menu capability to any view
struct RadialMenuModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var menuLocation: CGPoint
    let configuration: RadialMenuConfiguration
    let onSelect: (RadialMenuAction) -> Void
    let onEvent: ((RadialMenuEvent) -> Void)?
    let centerLabel: String?

    func body(content: Content) -> some View {
        ZStack {
            content

            if isPresented {
                RadialMenuView(
                    isPresented: $isPresented,
                    centerPoint: menuLocation,
                    configuration: configuration,
                    onSelect: onSelect,
                    onEvent: onEvent,
                    centerLabel: centerLabel
                )
                .transition(.scale.combined(with: .opacity))
                .zIndex(999)
            }
        }
    }
}

// MARK: - View Extension

extension View {
    /// Add a radial menu overlay to this view
    func radialMenu(
        isPresented: Binding<Bool>,
        location: Binding<CGPoint>,
        configuration: RadialMenuConfiguration,
        onSelect: @escaping (RadialMenuAction) -> Void,
        onEvent: ((RadialMenuEvent) -> Void)? = nil,
        centerLabel: String? = nil
    ) -> some View {
        self.modifier(
            RadialMenuModifier(
                isPresented: isPresented,
                menuLocation: location,
                configuration: configuration,
                onSelect: onSelect,
                onEvent: onEvent,
                centerLabel: centerLabel
            )
        )
    }
}

// MARK: - Preview

struct RadialMenuView_Previews: PreviewProvider {
    static var previews: some View {
        RadialMenuPreviewWrapper()
            .preferredColorScheme(.dark)
    }
}

struct RadialMenuPreviewWrapper: View {
    @State private var isPresented = true
    @State private var selectedAction: String = "None"

    var body: some View {
        ZStack {
            // Simulated map background
            Color(hex: "#2A3A2A")
                .ignoresSafeArea()

            VStack {
                Text("Selected: \(selectedAction)")
                    .foregroundColor(.white)
                    .padding()

                Button("Show Menu") {
                    isPresented = true
                }
                .foregroundColor(Color(hex: "#FFFC00"))
            }

            if isPresented {
                RadialMenuView(
                    isPresented: $isPresented,
                    centerPoint: CGPoint(x: 200, y: 400),
                    configuration: RadialMenuConfiguration(
                        items: [
                            RadialMenuItem(
                                icon: "mappin.circle.fill",
                                label: "Drop Point",
                                action: .addWaypoint
                            ),
                            RadialMenuItem(
                                icon: "play.rectangle.fill",
                                label: "Video",
                                action: .custom("video")
                            ),
                            RadialMenuItem(
                                icon: "antenna.radiowaves.left.and.right",
                                label: "Broadcast",
                                action: .custom("broadcast")
                            ),
                            RadialMenuItem(
                                icon: "doc.text.fill",
                                label: "Details",
                                action: .getInfo
                            ),
                            RadialMenuItem(
                                icon: "trash.fill",
                                label: "Delete",
                                action: .deleteMarker
                            ),
                            RadialMenuItem(
                                icon: "magnifyingglass",
                                label: "Search",
                                action: .custom("search")
                            )
                        ],
                        radius: 120,
                        itemSize: 48
                    ),
                    onSelect: { action in
                        switch action {
                        case .addWaypoint:
                            selectedAction = "Drop Point"
                        case .deleteMarker:
                            selectedAction = "Delete"
                        case .getInfo:
                            selectedAction = "Details"
                        case .custom(let id):
                            selectedAction = id.capitalized
                        default:
                            selectedAction = "Other"
                        }
                    },
                    centerLabel: "Eden Valley"
                )
            }
        }
    }
}
