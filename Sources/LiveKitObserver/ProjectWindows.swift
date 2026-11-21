import ObserverCore
import SwiftUI

struct SessionLink: Equatable {
    let project: String, session: String
    init?(url: URL) {
        guard url.scheme == "livekit-observer", url.host == "project", url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[1] == "session", Self.valid(parts[0], prefix: "p_"), Self.valid(parts[2], prefix: "RM_") else { return nil }
        project = parts[0]; session = parts[2]
    }
    init?(project: String, session: String) {
        guard Self.valid(project, prefix: "p_"), Self.valid(session, prefix: "RM_") else { return nil }
        self.project = project; self.session = session
    }
    private static func valid(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.count > prefix.count && value.count < 200 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
    var url: URL { URL(string: "livekit-observer://project/\(project)/session/\(session)")! }
}

@MainActor @Observable
final class WindowContext {
    static let shared = WindowContext()
    var active: AppModel?
    var pendingLinks: [String: String] = [:]
}

private struct ObserverModelKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var observerModel: AppModel? {
        get { self[ObserverModelKey.self] }
        set { self[ObserverModelKey.self] = newValue }
    }
}

struct ProjectWindow: View {
    @Binding private var project: String?
    @State private var model: AppModel
    init(project: Binding<String?>) {
        _project = project; _model = State(initialValue: AppModel(project: project.wrappedValue))
    }
    var body: some View {
        ContentView().environment(model).frame(minWidth: 1100, minHeight: 640)
            .task { if !AppModel.isTesting { await model.refresh(); model.handleSpaceBar() } }
            .onChange(of: model.project) { _, value in project = value }
    }
}

struct WindowFocusReader: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> FocusView { FocusView(model: model) }
    func updateNSView(_ view: FocusView, context: Context) {}
    final class FocusView: NSView {
        let model: AppModel
        private var observer: NSObjectProtocol?
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self {
                    WindowContext.shared.active = self.model
                    UserDefaults.standard.set(self.model.project ?? "", forKey: AppSettings.projectKey)
                } }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
