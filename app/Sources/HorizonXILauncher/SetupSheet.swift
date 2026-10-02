import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// First-run setup, as one button and a running log.
///
/// This is the whole reason the project can be handed to someone who does not know what a wine
/// prefix is. Everything it does is in `Bootstrap`; this is just the face of it.
struct SetupSheet: View {
    /// Called when wine is in place, so the launcher can rescan and pick the new install up.
    var onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var done = false
    @State private var current: Bootstrap.Step? = nil
    @State private var lines: [String] = []
    @State private var failure: String? = nil
    @State private var gameFound = Bootstrap.install.hasGame

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up FFXI on Mac").font(.title2.bold()).foregroundStyle(Vana.text)
                Text("This installs everything except the game itself: Apple's Rosetta 2, and "
                     + "Wine with a blank Windows drive for FFXI to live in. About 250 MB and "
                     + "five minutes. You can leave it running.")
                    .font(.callout).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Bootstrap.Step.allCases, id: \.rawValue) { s in
                    HStack(alignment: .top, spacing: 10) {
                        icon(for: s)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout.weight(.medium))
                                .foregroundStyle(current == s ? Vana.gold : Vana.text)
                            Text(s.detail).font(.caption).foregroundStyle(Vana.muted)
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
                                Text(l).font(.system(size: 11, design: .monospaced))
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
                Text(failure).font(.caption).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if done {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now the game itself").font(.callout.weight(.semibold))
                        .foregroundStyle(Vana.text)
                    Text(gameFound
                         ? "Found FFXI in the wrapper. You are ready to play."
                         : "FFXI is Square Enix's, so it comes from your server rather than from "
                           + "here. Download HorizonXI's Windows installer, then hand it over "
                           + "below — it runs inside the drive that was just created.")
                        .font(.caption).foregroundStyle(Vana.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if done && !gameFound {
                    Button("Open HorizonXI's download page") {
                        NSWorkspace.shared.open(URL(string: "https://horizonxi.com/play-now")!)
                    }
                    Button("Install the game…") { chooseInstaller() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(done ? "Done" : "Cancel") { onFinished(); dismiss() }
                if !done {
                    Button(running ? "Working…" : "Set it up") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running)
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
                    gameFound = Bootstrap.install.hasGame
                    onFinished()
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

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Choose your server's Windows installer"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let exe = panel.url else { return }
        do {
            try Bootstrap.runInstaller(exe, log: { l in Task { @MainActor in lines.append(l) } })
        } catch {
            failure = error.localizedDescription
        }
    }
}
