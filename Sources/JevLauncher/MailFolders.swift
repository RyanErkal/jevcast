import LauncherCore
import SwiftUI

/// A folder change the user asked for in the sidebar. It waits for a name, or for a yes to remove.
struct MailFolderRequest: Identifiable, Equatable {
    enum Kind: Equatable { case create, rename, delete }
    let kind: Kind
    let accountID: String
    /// The folder to rename or remove, or the folder a new one goes inside. Nil makes a top-level folder.
    let box: MailMailbox?
    var name = ""
    var id: String { "\(kind):\(accountID):\(box?.rowID ?? 0)" }
}

extension MailModel {
    /// Carries out the folder change on the account's server, then reads the folder list again.
    func performFolderRequest(_ request: MailFolderRequest, name: String) {
        guard let engine = NativeMailCenter.activeEngine else { banner = "Folders can be changed in Jevcast's own accounts."; return }
        folderRequest = nil
        Task { @MainActor [weak self] in
            do {
                switch request.kind {
                case .create:
                    try await engine.createFolder(name, account: request.accountID, parent: request.box?.rowID)
                    self?.banner = "Folder “\(name.trimmingCharacters(in: .whitespaces))” added."
                case .rename:
                    guard let box = request.box else { return }
                    try await engine.renameFolder(box.rowID, to: name)
                    // The renamed folder is a new place in the list. The view returns to the inbox.
                    if self?.place == .mailbox(box.rowID) { self?.place = .inbox }
                    self?.banner = "Folder renamed."
                case .delete:
                    guard let box = request.box else { return }
                    try await engine.deleteEmptyFolder(box.rowID)
                    if self?.place == .mailbox(box.rowID) { self?.place = .inbox }
                    self?.banner = "Folder removed."
                }
            } catch { self?.banner = error.localizedDescription }
        }
    }
}

/// The name prompt and the remove confirmation for folder changes.
struct MailFolderPrompt: ViewModifier {
    @ObservedObject var model: MailModel
    @State private var name = ""

    func body(content: Content) -> some View {
        let request = model.folderRequest
        return content
            .alert(title(request), isPresented: Binding(get: { model.folderRequest != nil && model.folderRequest?.kind != .delete },
                                                        set: { if !$0 { model.folderRequest = nil } })) {
                TextField("Folder name", text: $name)
                Button(request?.kind == .rename ? "Rename" : "Add") { if let request { model.performFolderRequest(request, name: name) } }
                Button("Cancel", role: .cancel) { model.folderRequest = nil }
            } message: { Text(request?.kind == .rename ? "The folder keeps its messages." : "The folder is made on the account's server.") }
            .alert("Delete “" + (request?.box?.name ?? "folder") + "”?", isPresented: Binding(get: { model.folderRequest?.kind == .delete },
                                                                                              set: { if !$0 { model.folderRequest = nil } })) {
                Button("Delete Folder", role: .destructive) { if let request { model.performFolderRequest(request, name: "") } }
                Button("Cancel", role: .cancel) { model.folderRequest = nil }
            } message: { Text("Only an empty folder is removed. A folder that holds messages or other folders stays, and nothing is deleted.") }
            .onChange(of: model.folderRequest) { _, next in name = next?.kind == .rename ? (next?.box?.name ?? "") : "" }
    }

    private func title(_ request: MailFolderRequest?) -> String {
        guard let request else { return "" }
        if request.kind == .rename { return "Rename “" + (request.box?.name ?? "folder") + "”" }
        return request.box.map { "New folder in “" + $0.name + "”" } ?? "New folder"
    }
}
