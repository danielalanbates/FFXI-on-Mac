import SwiftUI
import AppKit

/// First-run setup, as one button and a running log.
///
/// This is the whole reason the project can be handed to someone who does not know what a wine
/// prefix is. Everything it does is in `Bootstrap`; this is just the face of it.
///
/// Since b60 it is step 2 of the main button's Setup (ContentView.runSetup), after the user chose
/// the folder (`LocationPanel`): it says where Wine and its Windows drive will go and builds
/// nothing until "Set it up" is pressed. On success it closes itself and the main button carries
/// on with the game's Wine and the game, into the same folder.
struct SetupSheet: View {
    /// Called once: true when wine is in place (the launcher rescans and Setup carries on),
    /// false when the sheet was cancelled.
    var onFinished: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var done = false
    @State private var current: Bootstrap.Step? = nil
    @State private var lines: [String] = []
    @State private var failure: String? = nil
    @State private var gameFound = Bootstrap.install?.hasGame ?? false
    /// Where Wine and its Windows drive go (`Bootstrap.target`), and whether that is an existing
    /// wrapper whose Wine is only being replaced.
    private let location = Bootstrap.target
    private let repairing = Bootstrap.repairsInPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up FFXI on Mac").font(.title2.bold()).foregroundStyle(Vana.text)
                Text("This installs everything except the game itself: Apple's Rosetta 2, and "
                     + "Wine with a blank Windows drive for FFXI to live in. About 250 MB and "
                     + "five minutes. You can leave it running.")
                    .font(.callout).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(location == nil ? "Press Setup on the main window to choose where it goes."
                     : repairing ? "Wine is replaced in \(location!.path); its Windows drive and game stay as they are."
                     : "Everything goes in \(location!.deletingLastPathComponent().path): Wine and its Windows drive now, the game's Wine and the game next.")
                    .font(.system(size: 12)).foregroundStyle(Vana.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Bootstrap.Step.allCases, id: \.rawValue) { s in
                    HStack(alignment: .top, spacing: 10) {
                        icon(for: s)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout.weight(.medium))
                                .foregroundStyle(current == s ? Vana.gold : Vana.text)
                            Text(s.detail).font(.system(size: 12)).foregroundStyle(Vana.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))

            if !lines.isEmpty {
                ScrollViewReader { sp in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Vana.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }.padding(8)
                    }
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                    .onChange(of: lines.count) { _ in sp.scrollTo("end", anchor: .bottom) }
                }
            }

            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if done {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now the game itself").font(.callout.weight(.semibold))
                        .foregroundStyle(Vana.text)
                    Text(gameFound
                         ? "Found FFXI in the wrapper. You are ready to play."
                         : "Close this, then press the main button to download the game.")
                        .font(.system(size: 12)).foregroundStyle(Vana.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                // b60: the HorizonXI download is the main window's button (the old installer
                // route here needed renderer pieces a fresh wrapper does not have).
                Spacer()
                // Cancel while it runs stops Setup's chain here; the build itself finishes in the
                // background and the launcher picks it up.
                Button(done ? "Done" : "Cancel") { onFinished(done); dismiss() }
                if !done {
                    Button(running ? "Working…" : "Set it up") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || location == nil)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Vana.backdrop)
    }

    @ViewBuilder
    private func icon(for s: Bootstrap.Step) -> some View {
        let passed = done || (current.map { $0.rawValue > s.rawValue } ?? false)
        if passed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Vana.crystal)
        } else if current == s {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
            Image(systemName: "circle").foregroundStyle(Vana.muted.opacity(0.5))
        }
    }

    private func start() {
        // Remembered from the first write on: a build left to finish after Cancel is still found.
        if !repairing, let w = location { InstallLocation.remember(w.deletingLastPathComponent()) }
        running = true
        failure = nil
        lines = []
        Task {
            do {
                try await Bootstrap.run(
                    log: { line in Task { @MainActor in lines.append(line) } },
                    step: { s in Task { @MainActor in current = s } })
                await MainActor.run {
                    running = false
                    done = true
                    current = nil
                    gameFound = Bootstrap.install?.hasGame ?? false
                    // The main button carries on from here (the game, then PLAY).
                    onFinished(true)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    running = false
                    current = nil
                    failure = error.localizedDescription
                }
            }
        }
    }
}
