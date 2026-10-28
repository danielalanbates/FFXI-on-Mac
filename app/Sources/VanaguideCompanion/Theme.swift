// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// The FFXI on Mac palette (launcher App.swift `Vana`), repeated here because the companion is
// its own target. Night-blue ground, crystal accents, gold headings. Change both together.

import SwiftUI

enum Theme {
    static let night      = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let indigo     = Color(red: 0.11, green: 0.10, blue: 0.26)
    static let violet     = Color(red: 0.20, green: 0.14, blue: 0.36)
    static let crystal    = Color(red: 0.55, green: 0.83, blue: 0.95)
    static let gold       = Color(red: 0.93, green: 0.79, blue: 0.44)
    static let ember      = Color(red: 0.90, green: 0.45, blue: 0.35)
    static let jade       = Color(red: 0.50, green: 0.85, blue: 0.62)
    static let panel      = Color(red: 0.08, green: 0.08, blue: 0.17).opacity(0.85)
    static let stroke     = Color.white.opacity(0.14)
    static let text       = Color(red: 0.94, green: 0.95, blue: 0.99)
    static let muted      = Color(red: 0.64, green: 0.68, blue: 0.80)

    static var backdrop: some View {
        ZStack {
            LinearGradient(colors: [violet, indigo, night], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [crystal.opacity(0.18), .clear],
                           center: .init(x: 0.2, y: 0.05), startRadius: 8, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

/// A rounded panel on the backdrop.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
    }
}

/// Small caps section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5)
            .foregroundStyle(Theme.muted)
    }
}
