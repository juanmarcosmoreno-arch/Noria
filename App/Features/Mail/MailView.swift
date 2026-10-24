import AppKit
import NoriaCore
import SwiftUI

/// Where Mail's space goes, what Noria can safely clean, and what to do in Mail for the rest.
struct MailView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingCleanup = false

    private var mail: MailModel { model.mail }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoriaSpacing.l) {
                header
                if let usage = mail.usage {
                    if !usage.mailFolderReadable {
                        FullDiskAccessCard()
                    } else {
                        AccountsCard(usage: usage)
                        CleanableCard(confirming: $confirming)
                    }
                }
                GuidanceCard()
            }
            .padding(NoriaSpacing.xl)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text("Mail"))
        .sheet(isPresented: $confirming) {
            CleanupConfirmationView(items: mail.selectedItems, method: model.settings.removalMethod) {
                confirming = false
                mail.cleanSelection()
                showingCleanup = true
            } onCancel: {
                confirming = false
            }
        }
        .sheet(isPresented: $showingCleanup) {
            CleanupProgressView(controller: mail.cleanup) { showingCleanup = false }
        }
    }

    private var header: some View {
        Card {
            HStack(spacing: NoriaSpacing.l) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(NoriaColor.accent)
                VStack(alignment: .leading, spacing: NoriaSpacing.xxs) {
                    if let usage = mail.usage, usage.mailFolderReadable {
                        Text("Mail uses \(Format.bytes(usage.totalSize)) on this Mac").font(NoriaFont.title)
                    } else {
                        Text("Why is Mail so big?").font(NoriaFont.title)
                    }
                    Text("Mail keeps a local copy of your messages and their attachments. Noria shows where the space goes and only removes copies that can be downloaded again. Your messages are never deleted.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if mail.phase == .scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        mail.analyze()
                    } label: {
                        Label(mail.usage == nil ? LocalizedStringKey("Analyze Mail") : LocalizedStringKey("Analyze Again"),
                              systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

private struct FullDiskAccessCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.s) {
                CardHeader(title: "Noria needs Full Disk Access to read Mail", systemImage: "lock.shield")
                Text("macOS protects Mail's folder. To let Noria measure it:")
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open Privacy & Security › Full Disk Access.")
                    Text("2. Turn on Noria (use + to add it if it is not listed).")
                    Text("3. Quit and reopen Noria, then analyze Mail again.")
                }
                .foregroundStyle(.secondary)
                Button("Open Privacy Settings…") { SystemActions.openFullDiskAccessSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct AccountsCard: View {
    var usage: MailUsageReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Space by account", systemImage: "person.crop.circle")
                ForEach(usage.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName).font(NoriaFont.body.weight(.medium))
                                Text(account.kind.title).font(NoriaFont.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(Format.bytes(account.totalSize)).font(NoriaFont.body.monospacedDigit())
                                Text("\(Format.bytes(account.attachmentsSize)) in attachments")
                                    .font(NoriaFont.caption).foregroundStyle(.secondary)
                            }
                        }
                        CapacityBar(fraction: usage.totalSize > 0 ? Double(account.totalSize) / Double(usage.totalSize) : 0, height: 6)
                    }
                }
                if usage.mailDownloadsSize > 0 {
                    HStack {
                        Text("Mail Downloads").font(NoriaFont.body.weight(.medium))
                        Spacer()
                        Text(Format.bytes(usage.mailDownloadsSize)).font(NoriaFont.body.monospacedDigit())
                    }
                }
            }
        }
    }
}

private struct CleanableCard: View {
    @Binding var confirming: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let mail = model.mail
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "What Noria can clean safely", systemImage: "checkmark.shield") {
                    if !mail.removableItems.isEmpty {
                        Button(mail.selectedIDs.count == mail.removableItems.count ? LocalizedStringKey("Deselect All") : LocalizedStringKey("Select All")) {
                            mail.selectAllRemovable(mail.selectedIDs.count != mail.removableItems.count)
                        }
                        .buttonStyle(.link)
                    }
                }
                if mail.removableItems.isEmpty {
                    Text("Nothing to clean: there are no Mail Downloads or downloadable attachment copies.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mail.removableItems) { item in
                        MailItemRow(item: item, isSelected: mail.selectedIDs.contains(item.id)) { mail.toggle(item) }
                    }
                }
                if mail.protectedSize > 0 {
                    Label("\(Format.bytes(mail.protectedSize)) of attachments belong to accounts that keep mail only on this Mac (or whose type could not be confirmed). Noria leaves them alone; see the tips below.",
                          systemImage: "lock")
                        .font(NoriaFont.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    if mail.isMailRunning {
                        Label("Mail is open. It must be closed while cleaning.", systemImage: "exclamationmark.triangle.fill")
                            .font(NoriaFont.caption)
                            .foregroundStyle(NoriaColor.review)
                    }
                    Spacer()
                    Button("Clean \(Format.bytes(mail.selectedSize))…") { confirming = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(mail.selectedIDs.isEmpty || mail.cleanup.isRunning)
                }
            }
        }
    }
}

private struct MailItemRow: View {
    var item: ScanItem
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NoriaSpacing.xs) {
                    Text(item.name).font(NoriaFont.body.weight(.medium))
                    if let group = item.group {
                        Text(group).font(NoriaFont.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.reason.explanation)
                    .font(NoriaFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            RiskBadge(risk: item.risk)
            Text(Format.bytes(item.allocatedSize)).font(NoriaFont.body.monospacedDigit()).frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
        }
    }
}

/// What to do inside Mail itself; these are Mail's own, supported options.
private struct GuidanceCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: NoriaSpacing.m) {
                CardHeader(title: "Reduce Mail's size from Mail itself", systemImage: "lightbulb")
                tip("1", "Stop downloading every attachment",
                    "Mail › Settings › Accounts › choose the account › Account Information › Download Attachments: Recent or None. Do this before cleaning, otherwise Mail downloads everything again.")
                tip("2", "Empty Trash and Junk",
                    "Mailbox › Erase Deleted Items and Mailbox › Erase Junk Mail. Messages in the Trash still use space.")
                tip("3", "Find the biggest messages",
                    "Select a mailbox, then View › Sort By › Size. Deleting a message from an IMAP or iCloud account also deletes it from the server.")
                tip("4", "Accounts stored only on this Mac",
                    "For POP accounts and On My Mac mailboxes, export what you want to keep (Mailbox › Export Mailbox…) before deleting large messages.")
            }
        }
    }

    private func tip(_ number: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoriaSpacing.s) {
            Text(verbatim: number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(NoriaColor.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NoriaFont.body.weight(.semibold))
                Text(text).font(NoriaFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
