import NoriaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var languageChanged = false
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("General") {
                Picker("Language", selection: $model.settings.language) {
                    Text("System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "Español").tag(AppLanguage.spanish)
                }
                .onChange(of: model.settings.language) { languageChanged = true }
                if languageChanged {
                    Text("Relaunch Noria to apply the new language.")
                        .font(NoriaFont.caption)
                        .foregroundStyle(NoriaColor.review)
                }
            }

            Section {
                Picker("When cleaning", selection: $model.settings.removalMethod) {
                    ForEach(RemovalMethod.allCases, id: \.self) { method in
                        Text(method.title).tag(method)
                    }
                }
                Stepper(value: $model.settings.logsMinimumAgeDays, in: 1...365) {
                    Text("Logs older than \(model.settings.logsMinimumAgeDays) days")
                }
                Stepper(value: $model.settings.temporaryMinimumAgeDays, in: 1...365) {
                    Text("Temporary items older than \(model.settings.temporaryMinimumAgeDays) days")
                }
                Stepper(value: $model.settings.downloadsMinimumAgeDays, in: 1...3650) {
                    Text("Installers and archives in Downloads older than \(model.settings.downloadsMinimumAgeDays) days")
                }
            } header: {
                Text("Cleaning")
            } footer: {
                Text("Moving to the Trash lets you restore items with Finder’s Put Back. Space is freed when the Trash is emptied.")
            }

            if AppEdition.isSandboxed {
                Section {
                    LabeledContent("Home folder") {
                        if let granted = model.folderAccess.grantedPath {
                            Label((granted as NSString).abbreviatingWithTildeInPath, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(NoriaColor.safe)
                        } else {
                            Text("Not granted").foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(model.folderAccess.grantedPath == nil ? LocalizedStringKey("Allow Access…") : LocalizedStringKey("Grant Again…")) {
                            model.folderAccess.requestHomeAccess()
                        }
                        if model.folderAccess.grantedPath != nil {
                            Button("Revoke Access", role: .destructive) { model.folderAccess.revoke() }
                        }
                    }
                    if let error = model.folderAccess.errorMessage {
                        Text(error).font(NoriaFont.caption).foregroundStyle(NoriaColor.review)
                    }
                } header: {
                    Text("Folder Access")
                } footer: {
                    Text("The App Store edition runs in the macOS App Sandbox and can only read folders you allow. Temporary Files are not available in this edition.")
                }
            }

            Section("Smart Scan categories") {
                ForEach(CleanCategory.smartScanCategories.filter { !AppEdition.unavailableCategories.contains($0) }) { category in
                    Toggle(isOn: Binding(
                        get: { model.settings.enabledCategories.contains(category) },
                        set: { enabled in
                            if enabled { model.settings.enabledCategories.insert(category) } else { model.settings.enabledCategories.remove(category) }
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(category.title)
                                Text(category.summary).font(NoriaFont.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            CategoryIcon(category: category, size: 22)
                        }
                    }
                }
            }

            Section {
                Toggle("Skip app containers (~/Library/Containers)", isOn: $model.settings.largeFilesSkipsAppContainers)
            } header: {
                Text("Large Files")
            } footer: {
                Text("App containers hold data managed by other apps; reading them makes macOS ask for permission.")
            }

            Section {
                if model.settings.exclusions.isEmpty {
                    Text("No exclusions").foregroundStyle(.secondary)
                }
                ForEach(model.settings.exclusions, id: \.self) { path in
                    HStack {
                        Image(systemName: "nosign").foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            model.settings.exclusions.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove exclusion"))
                    }
                }
                Button("Add Exclusion…") {
                    for path in SystemActions.chooseItems(prompt: String(localized: "Exclude")) {
                        model.addExclusion(path)
                    }
                }
            } header: {
                Text("Exclusions")
            } footer: {
                Text("Excluded files and folders are never scanned or removed.")
            }

            Section {
                LabeledContent("Full Disk Access") {
                    Button("Open Privacy Settings…") { SystemActions.openFullDiskAccessSettings() }
                }
                Text("Optional. Without it, macOS hides some locations (for example the Trash and some app logs) and Noria reports them as not readable. Noria never tries to bypass macOS privacy protections.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
            }

            Section {
                LabeledContent("Operation log") {
                    Button("Show in Finder") {
                        SystemActions.revealInFinder([model.operationLog.fileURL.deletingLastPathComponent().path])
                    }
                }
                Button("Clear History…", role: .destructive) { confirmingClear = true }
                Text("Noria works entirely on this Mac. It sends no file names, paths, content or usage data anywhere.")
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy & Data")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Make space. Run better.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Settings"))
        .confirmationDialog("Clear the history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This deletes Noria's local log. Files are not affected.")
        }
    }
}
