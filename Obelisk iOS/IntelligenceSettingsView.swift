import ObeliskSync
import SwiftUI

struct IntelligenceSettingsView: View {
    @AppStorage("aiFeaturesEnabled") private var intelligenceEnabled = true
    @AppStorage(TitleOptimizationPreferences.autoOptimizeNewBookmarksKey)
    private var autoOptimizeNewBookmarks = false
    @AppStorage(BookmarkAutoGroupingPreferences.autoGroupNewBookmarksKey)
    private var autoGroupNewBookmarks = false
    @AppStorage(TitleOptimizationPreferences.optimizeHiddenBookmarksKey)
    private var optimizeHiddenBookmarks = false
    @AppStorage(TitleOptimizationTranslation.storageKey)
    private var translatesTitles = false

    @State private var profiles = LLMProfilesSettings()
    @State private var isTesting = false
    @State private var message: String?

    private let configStore = LLMConfigStore()

    var body: some View {
        Form {
            Section("Intelligence 功能") {
                Toggle("开启 Intelligence 功能", isOn: $intelligenceEnabled)
            }

            if intelligenceEnabled {
                Section("Intelligence 书签优化") {
                    Toggle(isOn: $autoOptimizeNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动优化新书签标题")
                            Text("开启后将自动使用配置的模型优化新添加的书签标题")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $autoGroupNewBookmarks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动分组新书签")
                            Text("开启后将自动使用配置的模型把新添加的可见书签归入合适分组")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("优化隐藏书签", isOn: $optimizeHiddenBookmarks)
                    Toggle("自动翻译非中文标题", isOn: $translatesTitles)
                }

                Section("模型配置") {
                    Picker("模型来源", selection: $profiles.activeSource) {
                        ForEach(LLMModelSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(
                            "API Key",
                            text: activeConfigBinding(\.apiKey),
                            prompt: Text(profiles.activeSource == .remote ? "sk-…" : "lm-studio")
                        )
                        Text(
                            profiles.activeSource == .remote
                                ? "用于访问云端 OpenAI 兼容服务的 API Key"
                                : "本地服务通常不校验 Key，填任意非空字符串即可"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Model",
                            text: activeConfigBinding(\.model),
                            prompt: Text(profiles.activeSource == .remote ? "gpt-4.1-mini" : "qwen3.5-4b")
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Text(
                            profiles.activeSource == .remote
                                ? "远程服务的模型名称，如 gpt-4.1-mini"
                                : "须与 LM Studio Local Server 里已加载模型的 id 一致"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "Base URL",
                            text: activeConfigBinding(\.baseURL),
                            prompt: Text(
                                profiles.activeSource == .remote
                                    ? "https://api.openai.com/v1/chat/completions"
                                    : "http://localhost:1234/v1/chat/completions"
                            )
                        )
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Text(
                            profiles.activeSource == .remote
                                ? "远程 API 的 chat completions 地址"
                                : "须先在本机启动 LM Studio Local Server（默认端口 1234）"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button(isTesting ? "测试中…" : "测试模型连接") {
                        testConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                }
            }
        }
        .navigationTitle("Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            profiles = configStore.loadProfiles()
        }
        .onChange(of: profiles) { _, settings in
            persist(settings)
        }
        .alert(
            "Intelligence",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func activeConfigBinding<Value>(
        _ keyPath: WritableKeyPath<LLMConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { profiles.activeConfig[keyPath: keyPath] },
            set: { value in
                switch profiles.activeSource {
                case .remote: profiles.remote[keyPath: keyPath] = value
                case .local: profiles.local[keyPath: keyPath] = value
                }
            }
        )
    }

    private func persist(_ settings: LLMProfilesSettings) {
        do {
            try configStore.save(settings)
        } catch {
            message = error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        message = nil
        let config = profiles.activeConfig
        Task {
            defer { isTesting = false }
            do {
                try configStore.save(profiles)
                try await IntelligenceConnectionTester.test(config)
                message = "连接成功"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private enum IntelligenceConnectionTester {
    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
    }

    static func test(_ config: LLMConfig) async throws {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty else {
            throw IntelligenceConfigurationError.missing
        }
        guard let url = URL(string: config.baseURL) else {
            throw IntelligenceConfigurationError.invalid
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Request(
                model: model,
                messages: [.init(role: "user", content: "Reply with OK")],
                temperature: 0
            )
        )

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IntelligenceConfigurationError.connection
        }
    }
}

private enum IntelligenceConfigurationError: LocalizedError {
    case missing
    case invalid
    case connection

    var errorDescription: String? {
        switch self {
        case .missing: "还没有配置 Intelligence 模型，请先填写 API Key 和模型"
        case .invalid: "Intelligence 配置无效，请检查 Base URL"
        case .connection: "连接失败"
        }
    }
}
