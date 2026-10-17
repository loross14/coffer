import Foundation

/// Durable onboarding order. Source discovery precedes any managed knowledge creation.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public enum Step: String, Codable, CaseIterable, Sendable {
        case account, agent, existingVaults, vaultSetup, localModel, worldKnowledge, complete

        public var title: String {
            switch self {
            case .account: "Your account"
            case .agent: "Connect an agent"
            case .existingVaults: "Bring your vaults"
            case .vaultSetup: "Your knowledge home"
            case .localModel: "Local intelligence"
            case .worldKnowledge: "Build World Knowledge"
            case .complete: "Ready"
            }
        }
    }

    public private(set) var step: Step = .account
    public private(set) var connectedAgent: String?
    public private(set) var sourceVaultIDs: [UUID] = []
    public private(set) var worldKnowledgeVaultID: UUID?
    public init() {}

    /// Revisiting source selection invalidates all later creation state but keeps the verified agent.
    public mutating func revisitSources() {
        guard [.vaultSetup, .localModel, .worldKnowledge].contains(step) else { return }
        step = .existingVaults
        sourceVaultIDs = []
        worldKnowledgeVaultID = nil
    }

    /// Only verified results advance a required step. A cancelled or failed operation stays retryable.
    @discardableResult
    public mutating func accountVerified(_ verified: Bool) -> Bool {
        guard step == .account, verified else { return false }
        step = .agent
        return true
    }

    @discardableResult
    public mutating func agentVerified(_ agent: String, successfulRun: Bool) -> Bool {
        guard step == .agent, successfulRun, !agent.isEmpty else { return false }
        connectedAgent = agent
        step = .existingVaults
        return true
    }

    public mutating func sourcesSelected(_ registeredIDs: [UUID]) {
        guard step == .existingVaults else { return }
        sourceVaultIDs = Array(Set(registeredIDs)).sorted { $0.uuidString < $1.uuidString }
        step = .vaultSetup
    }

    public mutating func confirmVaultSetup() {
        guard step == .vaultSetup else { return }
        step = .localModel
    }

    public mutating func finishLocalModelChoice() {
        guard step == .localModel else { return }
        step = .worldKnowledge
    }

    @discardableResult
    public mutating func knowledgeCreated(_ id: UUID, consented: Bool, verified: Bool) -> Bool {
        guard step == .worldKnowledge, consented, verified else { return false }
        worldKnowledgeVaultID = id
        step = .complete
        return true
    }
}
