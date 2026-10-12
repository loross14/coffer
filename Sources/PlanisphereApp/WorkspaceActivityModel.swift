import Foundation
import Observation
import PlanisphereConnection

enum ActivitySurface: String, CaseIterable {
    case prompts = "Prompts", hooks = "Hooks", memory = "Memory"
    var symbol: String { switch self { case .prompts: "text.bubble"; case .hooks: "point.3.connected.trianglepath.dotted"; case .memory: "sparkles.rectangle.stack" } }
}

@MainActor @Observable
final class WorkspaceActivityModel {
    var filter = PromptFilter()
    private(set) var prompts: [RemotePrompt] = []
    private(set) var detail: RemotePrompt?
    private(set) var hooks: [HookActivity] = []
    private(set) var nextCursor: String?
    private(set) var message: String?
    private(set) var detailMessage: String?
    private(set) var busy = false
    private(set) var detailBusy = false
    private(set) var local = LocalWork()
    private(set) var localBusy = false
    private(set) var localProjectPath: String?
    private(set) var hooksTruncated = false
    private var credential: ConnectionCredential?
    private var generation = UUID()
    private var listRequest = UUID()
    private var detailRequest = UUID()
    private var localRequest = UUID()
    private let client: WorkspaceClient

    init(client: WorkspaceClient = WorkspaceClient()) { self.client = client }

    func matches(_ value: ConnectionCredential?, verified: Bool) -> Bool {
        verified && value?.token == credential?.token && value?.connection == credential?.connection
    }

    // Old responses must not repopulate a new account, including a quick A→B→A switch.
    func bind(_ value: ConnectionCredential?, verified: Bool) {
        let value = verified ? value : nil
        guard value?.token != credential?.token || value?.connection != credential?.connection else { return }
        credential = value
        generation = UUID(); listRequest = UUID(); detailRequest = UUID()
        prompts = []; hooks = []; detail = nil; nextCursor = nil
        message = nil; detailMessage = nil; busy = false; detailBusy = false
        hooksTruncated = false; filter = PromptFilter()
    }

    func loadPrompts(more: Bool = false) async {
        guard let credential else { return }
        let scope = generation, request = UUID(), filter = filter
        listRequest = request; busy = true; message = nil
        if !more { prompts = []; detail = nil; detailMessage = nil; nextCursor = nil; detailRequest = UUID(); detailBusy = false }
        do {
            let page = try await client.prompts(credential, filter: filter, before: more ? nextCursor : nil)
            guard scope == generation, request == listRequest else { return }
            var seen = Set<String>()
            prompts = (more ? prompts + page.prompts : page.prompts).filter { seen.insert($0.id).inserted }
            nextCursor = page.next_cursor
        } catch {
            guard scope == generation, request == listRequest else { return }
            handle(error)
        }
        if scope == generation, request == listRequest { busy = false }
    }

    func select(_ id: String) async {
        guard let credential else { return }
        let scope = generation, request = UUID()
        detailRequest = request; detail = nil; detailMessage = nil; detailBusy = true
        do {
            let value = try await client.detail(id, credential: credential)
            guard scope == generation, request == detailRequest else { return }
            detail = value
        } catch {
            guard scope == generation, request == detailRequest else { return }
            detailMessage = error.localizedDescription
            if error as? WorkspaceError == .signInAgain || error as? WorkspaceError == .permissionRequired { handle(error) }
        }
        if scope == generation, request == detailRequest { detailBusy = false }
    }

    func loadHooks() async {
        guard let credential else { return }
        let scope = generation, request = UUID()
        listRequest = request; busy = true; message = nil; hooks = []
        do {
            let page = try await client.hooks(credential)
            guard scope == generation, request == listRequest else { return }
            hooks = page.systems; hooksTruncated = page.truncated
        } catch {
            guard scope == generation, request == listRequest else { return }
            handle(error)
        }
        if scope == generation, request == listRequest { busy = false }
    }

    private func handle(_ error: Error) {
        message = error.localizedDescription
        // A denied/revoked read clears all cloud data, not just the failed view.
        if error as? WorkspaceError == .signInAgain || error as? WorkspaceError == .permissionRequired {
            prompts = []; detail = nil; hooks = []; nextCursor = nil
            detailRequest = UUID(); detailBusy = false
        }
    }

    func loadLocal(project: URL?, reader: LocalWorkReader = LocalWorkReader()) async {
        let request = UUID(); localRequest = request; localBusy = true; local = LocalWork()
        localProjectPath = project.map(LocalWorkReader.canonicalPath)
        let value = await Task.detached(priority: .userInitiated) { reader.load(project: project) }.value
        guard request == localRequest else { return }
        local = value; localBusy = false
    }
}
