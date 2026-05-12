//
//  FEMAMarkerPaletteView.swift
//  OmniTAKMobile
//
//  Modal sheet that exposes the FEMA / Incident Command marker palette.
//  Presented from the Point Dropper drawer — DO NOT collapse the full-screen
//  map for this; this is always a sheet so the map stays sacred
//  (see feedback_omnitak_fullscreen_map).
//
//  Closes GitHub #13.
//
import SwiftUI
import CoreLocation

/// Result handed back to the caller when the user picks an icon.
struct FEMAMarkerSelection: Equatable {
    let icon: FEMAIconCatalog.FEMAIcon
    /// Optional override name; nil means caller should default to icon.label.
    let name: String?
    let remarks: String?
}

struct FEMAMarkerPaletteView: View {
    @Binding var isPresented: Bool
    let onSelect: (FEMAMarkerSelection) -> Void

    @State private var pickedKind: FEMAIconCatalog.Kind?
    @State private var nameOverride: String = ""
    @State private var remarks: String = ""

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "#1E1E1E").ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        ForEach(FEMAIconCatalog.allCategories, id: \.self) { category in
                            categorySection(category)
                        }

                        if pickedKind != nil {
                            detailsSection
                            dropButton
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("FEMA / IC Markers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAR / DISASTER RESPONSE")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "#FFFC00"))
            Text("Tap an icon, then Drop. Round-trips over CoT as a friendly ground installation with a FEMA usericon.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
    }

    private func categorySection(_ category: FEMAIconCatalog.Category) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.displayName.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(category.accentColor)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(FEMAIconCatalog.icons(in: category)) { icon in
                    iconTile(icon)
                }
            }
        }
    }

    private func iconTile(_ icon: FEMAIconCatalog.FEMAIcon) -> some View {
        let isPicked = pickedKind == icon.kind
        return Button(action: {
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            pickedKind = icon.kind
        }) {
            VStack(spacing: 6) {
                Image(systemName: icon.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(isPicked ? .black : icon.category.accentColor)
                    .frame(height: 32)

                Text(icon.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isPicked ? .black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.vertical, 8)
            // No grey backplate — keep icons floating per feedback.
            .background(
                isPicked
                    ? AnyView(icon.category.accentColor)
                    : AnyView(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(icon.category.accentColor.opacity(isPicked ? 1.0 : 0.4),
                            lineWidth: isPicked ? 2 : 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DETAILS (OPTIONAL)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "#FFFC00"))

            TextField("Override name", text: $nameOverride)
                .padding(10)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .foregroundColor(.white)

            TextEditor(text: $remarks)
                .frame(minHeight: 60)
                .padding(6)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .foregroundColor(.white)
        }
    }

    private var dropButton: some View {
        Button(action: dropSelected) {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                Text("DROP")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if let kind = pickedKind, let icon = FEMAIconCatalog.icon(for: kind) {
                    Image(systemName: icon.symbolName)
                        .foregroundColor(icon.category.accentColor)
                }
            }
            .padding()
            .foregroundColor(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#FFFC00"), lineWidth: 2)
            )
        }
        .disabled(pickedKind == nil)
    }

    private func dropSelected() {
        guard let kind = pickedKind, let icon = FEMAIconCatalog.icon(for: kind) else { return }
        let selection = FEMAMarkerSelection(
            icon: icon,
            name: nameOverride.isEmpty ? nil : nameOverride,
            remarks: remarks.isEmpty ? nil : remarks
        )
        onSelect(selection)
        isPresented = false
    }
}

// MARK: - Preview

struct FEMAMarkerPaletteView_Previews: PreviewProvider {
    static var previews: some View {
        FEMAMarkerPaletteView(
            isPresented: .constant(true),
            onSelect: { _ in }
        )
    }
}
