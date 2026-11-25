// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation
import SwiftUI

struct CharacterEditError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CharacterProfiles {
    static func name(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }) else {
            throw CharacterEditError(message: "Enter a character name without slashes or control characters.")
        }
        return name
    }

    static func collision(_ name: String, world: String, excluding old: String? = nil, in directory: URL) -> Bool {
        let key = ProgressStore.fileName(character: name, world: world).lowercased()
        let target = directory.appendingPathComponent(ProgressStore.fileName(character: name, world: world))
        let oldKey = old.map { ProgressStore.fileName(character: $0, world: world).lowercased() }
        if FileManager.default.fileExists(atPath: target.path), oldKey != key { return true }
        return ProgressStore.saved(in: directory).contains {
            $0.world == world && $0.character != old && ProgressStore.fileName(character: $0.character, world: world).lowercased() == key
        }
    }

    static func add(_ text: String, world: String, in directory: URL = ProgressStore.directory) throws -> CharacterProgress {
        let name = try self.name(text)
        guard !world.isEmpty else { throw CharacterEditError(message: "Choose a server first.") }
        guard !collision(name, world: world, in: directory) else { throw CharacterEditError(message: "That character is already listed for this server.") }
        // Adding a previously removed name restores its archived progress.
        var record = ProgressStore.load(character: name, world: world, in: directory.appendingPathComponent("removed", isDirectory: true))
        record.character = name; record.world = world; record.updated = Date()
        guard ProgressStore.save(record, in: directory) else { throw CharacterEditError(message: "The character could not be saved.") }
        return record
    }

    static func rename(_ old: String, world: String, to text: String, in directory: URL = ProgressStore.directory) throws -> CharacterProgress {
        let name = try self.name(text)
        let fm = FileManager.default
        let source = directory.appendingPathComponent(ProgressStore.fileName(character: old, world: world))
        let target = directory.appendingPathComponent(ProgressStore.fileName(character: name, world: world))
        guard fm.fileExists(atPath: source.path) else { throw CharacterEditError(message: "That character is no longer listed.") }
        guard !collision(name, world: world, excluding: old, in: directory) else { throw CharacterEditError(message: "Another character already uses that name on this server.") }
        guard var record = ProgressStore.saved(in: directory).first(where: { $0.character == old && $0.world == world }) else {
            throw CharacterEditError(message: "Saved progress could not be read. The original character is unchanged.")
        }
        record.character = name; record.updated = Date()
        guard ProgressStore.save(record, in: directory) else { throw CharacterEditError(message: "The name could not be saved. Your original character is unchanged.") }
        // On case-insensitive disks a case-only rename refers to the same file. Remove an
        // old path only when two distinct directory entries actually exist after saving.
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        if source.lastPathComponent != target.lastPathComponent && names.contains(source.lastPathComponent) && names.contains(target.lastPathComponent) {
            do { try fm.removeItem(at: source) }
            catch {
                try? fm.removeItem(at: target)
                throw CharacterEditError(message: "The name could not be changed. Your original character is unchanged.")
            }
        }
        return record
    }

    static func remove(_ name: String, world: String, in directory: URL = ProgressStore.directory) throws {
        let fm = FileManager.default
        let file = ProgressStore.fileName(character: name, world: world)
        let source = directory.appendingPathComponent(file)
        let archive = directory.appendingPathComponent("removed", isDirectory: true)
        do {
            let data = try Data(contentsOf: source)
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            try data.write(to: archive.appendingPathComponent(file), options: .atomic)
            try fm.removeItem(at: source)
        } catch { throw CharacterEditError(message: "The character could not be removed. Its saved progress was kept.") }
    }
}

extension CompanionState {
    func addCharacterInSettings(_ name: String) throws -> String {
        let record = try CharacterProfiles.add(name, world: world)
        selectCharacter(record.character)
        refreshOptions()
        return record.character
    }

    func renameCharacterInSettings(_ name: String, to newName: String) throws -> String {
        let active = name == character
        if active && !saveGuidePosition() { throw CharacterEditError(message: guideSaveError) }
        let record = try CharacterProfiles.rename(name, world: world, to: newName)
        if active {
            character = record.character; progress = record
            UserDefaults.standard.set(character, forKey: "progress.character")
        }
        refreshOptions()
        return record.character
    }

    func removeCharacterInSettings(_ name: String) throws {
        let active = name == character
        if active && !saveGuidePosition() { throw CharacterEditError(message: guideSaveError) }
        try CharacterProfiles.remove(name, world: world)
        if active {
            character = ""
            refreshOptions()
            character = characterOptions.first ?? ""
            loadCharacter()
            openInitialGuide()
        } else { refreshOptions() }
    }
}

struct CharacterSettingsView: View {
    @ObservedObject var state: CompanionState
    @State private var selected: String?
    @State private var newName = ""
    @State private var editedName = ""
    @State private var notice = ""
    @State private var error = false

    func choose(_ name: String?) { selected = name; editedName = name ?? "" }
    func failed(_ failure: Error) { notice = failure.localizedDescription; error = true }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings").font(.headline).foregroundStyle(Theme.gold)
                Text("Characters · \(state.world.isEmpty ? "Choose a server above" : state.world)")
                    .font(.callout).foregroundStyle(Theme.muted)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.characterOptions.isEmpty {
                            Text("No characters added yet.").font(.callout).foregroundStyle(Theme.muted)
                            Spacer()
                        } else {
                            List(state.characterOptions, id: \.self, selection: $selected) { name in
                                HStack {
                                    Text(name)
                                    Spacer(minLength: 0)
                                    if name == state.character { Image(systemName: "checkmark").foregroundStyle(Theme.jade).help("Current character") }
                                }.tag(name)
                            }
                            .scrollContentBackground(.hidden).listStyle(.sidebar)
                        }
                    }.frame(width: 170)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add a character").font(.callout.bold())
                            TextField("New character name", text: $newName).textFieldStyle(.roundedBorder)
                            Button("Add Character") {
                                do {
                                    let name = try state.addCharacterInSettings(newName)
                                    choose(name); newName = ""; notice = "Character added."; error = false
                                } catch { failed(error) }
                            }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.world.isEmpty)
                            Divider()
                            Text("Edit selected character").font(.callout.bold())
                            TextField("Character name", text: $editedName).textFieldStyle(.roundedBorder).disabled(selected == nil)
                            HStack {
                                Button("Save Name") {
                                    guard let selected else { return }
                                    do {
                                        choose(try state.renameCharacterInSettings(selected, to: editedName))
                                        notice = "Name updated. Saved progress kept."; error = false
                                    } catch { failed(error) }
                                }.disabled(selected == nil || editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Use Character") {
                                    guard let selected else { return }
                                    state.selectCharacter(selected); notice = "Current character updated."; error = false
                                }.disabled(selected == nil || selected == state.character)
                            }
                            Button("Remove from List", role: .destructive) {
                                guard let selected else { return }
                                do {
                                    try state.removeCharacterInSettings(selected)
                                    choose(state.characterOptions.first)
                                    notice = "Character removed. Add the same name to restore its progress."; error = false
                                } catch { failed(error) }
                            }.disabled(selected == nil)
                            Text("Removing a character keeps its saved progress. Add the same name to restore it.")
                                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            if !notice.isEmpty {
                                Text(notice).font(.caption).foregroundStyle(error ? Theme.ember : Theme.jade)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { choose(state.characterOptions.contains(state.character) ? state.character : state.characterOptions.first) }
        .onChange(of: selected) { editedName = $0 ?? "" }
        .onChange(of: state.world) { _ in choose(state.characterOptions.first); newName = ""; notice = "" }
    }
}
