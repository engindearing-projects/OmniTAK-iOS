//
//  CustomToolbar.swift
//  OmniTAKMobile
//
//  The user-customizable floating "Liquid Glass" bottom bar. Renders the
//  operator's chosen shortcuts (ToolbarConfigStore) and, on long-press,
//  enters an iOS-Home-screen-style edit mode: icons jiggle, a ⊖ badge
//  removes, drag reorders, and a ＋ tile opens the add-shortcut palette.
//

import SwiftUI
import UIKit

struct CustomToolbar: View {
    @ObservedObject private var store = ToolbarConfigStore.shared
    // Observe the language manager so the bar re-renders — and its labels
    // re-resolve — the instant the operator switches language in Settings.
    // Without this the cells keep the English `item.label` baked in at startup.
    @EnvironmentObject private var loc: LocalizationManager
    @Binding var selectedTab: RootTab
    /// Fire a shortcut (tab switch / command). Owner does the routing.
    let onSelect: (BarItem) -> Void
    /// Open the "add a shortcut" palette.
    let onAddTapped: () -> Void
    /// Per-item status dot, keyed by `BarItem.id` — currently the Mesh tab's
    /// radio link state. Field feedback: "is a radio even connected?" needs an
    /// answer you can read without opening the tab. Absent id = no dot.
    var statusDots: [String: Color] = [:]

    @State private var barWidth: CGFloat = 1
    @State private var draggingID: String?
    @State private var dragStartIndex: Int = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var wigglePhase = false
    /// One-time discovery hint that the bar is customizable.
    @AppStorage("didShowToolbarCoachmark") private var seenCoachmark = false

    // #182 — landscape parity. The wide-but-short landscape canvas (plate-
    // carrier orientation) shouldn't be straddled by a full-width bar that
    // buries the map. In landscape we let the pill hug its content (capped
    // width) and center it, freeing the map flanks. Every shortcut, edit
    // mode, drag-reorder and the add-tile all stay exactly as in portrait.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }
    /// Width budget for a compact landscape cell so the centered pill stays
    /// tight against its icons instead of stretching edge to edge.
    private var compactCellWidth: CGFloat { 64 }

    private var showCoachmark: Bool { !seenCoachmark && !store.isEditing && selectedTab == .map }

    private var totalCells: Int {
        store.items.count + (store.isEditing && !store.isFull ? 1 : 0)
    }
    private var cellWidth: CGFloat {
        // In landscape the pill hugs its content, so reorder math keys off the
        // fixed compact cell width rather than the (now content-sized) bar.
        isLandscape ? compactCellWidth : max(1, barWidth / CGFloat(max(totalCells, 1)))
    }

    var body: some View {
        VStack(spacing: 8) {
            if store.isEditing {
                editHeader
            } else if showCoachmark {
                coachmark
            }
            // Landscape: center the content-hugging pill so it doesn't span
            // the whole width and cover the map. Portrait: unchanged (the
            // HStack of maxWidth-infinity cells fills the bar edge to edge).
            if isLandscape {
                barPill
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                barPill
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - First-run coachmark

    private var coachmark: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
            Text(loc.t("bar.coachmark"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Button {
                withAnimation { seenCoachmark = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(BarTint.tools))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onTapGesture { withAnimation { seenCoachmark = true } }
    }

    // MARK: - Edit-mode header

    private var editHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Text(loc.t("bar.editHint"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    store.isEditing = false
                }
            } label: {
                Text(loc.t("bar.done"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(BarTint.tools))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.6))
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        )
        .clipShape(Capsule(style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Bar pill

    private var itemsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                cell(item: item, displayIndex: index)
            }
            if store.isEditing && !store.isFull {
                addCell
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var pillShape: RoundedRectangle { RoundedRectangle(cornerRadius: 34, style: .continuous) }

    private var pillBackground: some View {
        pillShape
            .fill(Color.black.opacity(0.55))
            .background(pillShape.fill(.ultraThinMaterial))
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: BarWidthKey.self, value: geo.size.width - 12)
        }
    }

    private var barPill: some View {
        itemsRow
            .background(widthReader)
            .onPreferenceChange(BarWidthKey.self) { barWidth = $0 }
            .background(pillBackground)
            .overlay(
                pillShape.stroke(
                    store.isEditing ? BarTint.tools.opacity(0.6) : Color.white.opacity(0.08),
                    lineWidth: store.isEditing ? 1.5 : 1
                )
            )
            .clipShape(pillShape)
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 6)
            // Simultaneous (not plain onLongPressGesture) so the hold is
            // recognized alongside the child buttons' taps — otherwise a
            // button swallows the press and edit mode never starts. When it
            // fires, the cells flip allowsHitTesting(false), cancelling the
            // button's pending tap so we don't also navigate.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard !store.isEditing else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    seenCoachmark = true
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.isEditing = true }
                    wigglePhase = true
                }
            )
            .onChange(of: store.isEditing) { editing in
                wigglePhase = editing
                if !editing { draggingID = nil; dragTranslation = 0 }
            }
    }

    // MARK: - Item cell

    private func cell(item: BarItem, displayIndex: Int) -> some View {
        let isActive = isTabActive(item)
        let isDragging = draggingID == item.id
        let offsetX = isDragging ? dragTranslation - CGFloat(displayIndex - dragStartIndex) * cellWidth : 0

        return ZStack(alignment: .topLeading) {
            Button {
                guard !store.isEditing else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelect(item)
            } label: {
                VStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .fill(isActive ? item.tint.opacity(0.22) : Color.clear)
                            .frame(width: isActive ? 40 : 32, height: isActive ? 40 : 32)
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? item.tint : Color.white.opacity(0.85))
                    }
                    .overlay(alignment: .topTrailing) {
                        if let dot = statusDots[item.id] {
                            Circle()
                                .fill(dot)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                                .offset(x: 1, y: -1)
                        }
                    }
                    Text(loc.t("bar." + item.id))
                        .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                        .foregroundColor(isActive ? item.tint : Color.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!store.isEditing)

            if store.isEditing && store.canRemove {
                removeBadge(item)
            }
        }
        .frame(maxWidth: isLandscape ? compactCellWidth : .infinity)
        .rotationEffect(.degrees(store.isEditing && !isDragging ? (wigglePhase ? 1.6 : -1.6) : 0))
        .scaleEffect(isDragging ? 1.12 : 1)
        .offset(x: offsetX)
        .zIndex(isDragging ? 2 : 0)
        .animation(
            store.isEditing && !isDragging
                ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(Double(displayIndex) * 0.04)
                : .default,
            value: wigglePhase
        )
        .gesture(store.isEditing ? reorderGesture(item: item, displayIndex: displayIndex) : nil)
    }

    private func removeBadge(_ item: BarItem) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                store.remove(item.id)
            }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white, BarTint.red)
                .background(Circle().fill(.white).frame(width: 12, height: 12))
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -4)
    }

    private var addCell: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAddTapped()
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                Text(loc.t("bar.add"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: isLandscape ? compactCellWidth : .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Reorder gesture

    private func reorderGesture(item: BarItem, displayIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard store.isEditing else { return }
                if draggingID == nil {
                    draggingID = item.id
                    dragStartIndex = displayIndex
                }
                dragTranslation = value.translation.width
                let cur = store.itemIDs.firstIndex(of: item.id) ?? displayIndex
                let target = max(0, min(store.items.count - 1,
                                        dragStartIndex + Int((value.translation.width / cellWidth).rounded())))
                if target != cur {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.move(from: cur, to: target)
                    }
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    draggingID = nil
                    dragTranslation = 0
                }
            }
    }

    private func isTabActive(_ item: BarItem) -> Bool {
        if case .tab(let t) = item.kind { return selectedTab == t }
        return false
    }
}

private struct BarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
