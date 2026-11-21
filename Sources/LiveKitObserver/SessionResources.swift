import ObserverCore
import Foundation

extension LiveKitCLI: SessionSource {
    func resource(_ id: String, kind: SessionResource) async throws -> SessionResourceDocument {
        SessionResourceDocument(kind: kind, json: try await analytics(kind.arguments(id)))
    }
}

