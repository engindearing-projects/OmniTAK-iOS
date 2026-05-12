//
//  LassoSelectionPill.swift
//  OmniTAKMobile
//
//  Issue #16 — Compact "✕ N selected" pill that surfaces the active
//  lasso selection and provides a one-tap clear affordance.
//
//  Visual contract: no grey backplate (per radial-menu floating-icon
//  preference). The pill is a soft-orange floating chip — readable
//  on satellite imagery without obstructing the map.
//

import SwiftUI

struct LassoSelectionPill: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("\(count) selected")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                // Tinted orange capsule. NOT a grey backplate — the
                // capsule IS the orange-on-map selection signal.
                Capsule()
                    .fill(Color.orange.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
            )
        }
        .accessibilityLabel("Clear lasso selection of \(count) items")
    }
}

#if DEBUG
struct LassoSelectionPill_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            LassoSelectionPill(count: 1, onClear: {})
            LassoSelectionPill(count: 12, onClear: {})
            LassoSelectionPill(count: 247, onClear: {})
        }
        .padding()
        .background(Color.gray)
    }
}
#endif
