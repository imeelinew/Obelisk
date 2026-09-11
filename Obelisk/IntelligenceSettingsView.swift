import ObeliskCore
import ObeliskSync
import SwiftUI

struct IntelligenceSettingsView: View {
    let onMessage: (String, Bool) -> Void
    @Bindable var settings: IntelligenceSettingsModel
    @AppStorage(TitleOptimizationPreferences.autoOptimizeNewBookmarksKey) private var autoOptimizeNewBookmarks = false
    @AppStorage(TitleOptimizationTranslation.storageKey) private var translateNonChineseTitles = false
    @AppStorage(BookmarksModel.aiFeaturesEnabledKey) private var aiFeaturesEnabled = true
    @AppStorage(TitleOptimizationPreferences.optimizeHiddenBookmarksKey) private var optimizeHiddenBookmarks = false
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

    var body: some View {
        Form {
            Section("Intelligence 功能") {
                Toggle("开启 Intelligence 功能", isOn: $aiFeaturesEnabled)
            }

            if aiFeaturesEnabled {
                Section("Intelligence 书签优化") {
                    Toggle("自动优化新书签标题", isOn: $autoOptimizeNewBookmarks)
                    Toggle("优化隐藏书签", isOn: $optimizeHiddenBookmarks)
                    Toggle("自动翻译非中文标题", isOn: $translateNonChineseTitles)
                }

                Section("模型配置") {
                    LabeledContent {
                        llmModelSourcePicker
                    } label: {
                        Text("模型来源")
                    }

                    SecureField(
                        text: llmAPIKeyBinding,
                        prompt: Text(settings.llmProfiles.activeSource == .remote ? "sk-…" : "lm-studio")
                    ) {
                        Label("API Key", systemImage: "key")
                    }

                    TextField(
                        text: llmModelBinding,
                        prompt: Text(settings.llmProfiles.activeSource == .remote ? "gpt-4.1-mini" : "qwen3.5-4b")
                    ) {
                        Label("Model", systemImage: "cpu")
                    }

                    TextField(
                        text: llmBaseURLBinding,
                        prompt: Text(
                            settings.llmProfiles.activeSource == .remote
                                ? "https://api.openai.com/v1/chat/completions"
                                : "http://localhost:1234/v1/chat/completions"
                        )
                    ) {
                        Label("Base URL", systemImage: "link")
                    }

                    HStack(spacing: 12) {
                        Button {
                            settings.testConnection(onMessage: onMessage)
                        } label: {
                            Text(settings.isTestingLLMConfig ? "测试中…" : "测试连接")
                        }
                        .disabled(settings.isTestingLLMConfig)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("Intelligence")
    }

    private var llmModelSourcePicker: some View {
        CompactBorderedMenuPicker(
            options: Array(LLMModelSource.allCases),
            selection: llmModelSourceBinding,
            title: { $0.localizedTitle }
        )
    }

    private var llmModelSourceBinding: Binding<LLMModelSource> {
        Binding(
            get: { settings.llmProfiles.activeSource },
            set: { newValue in
                var profiles = settings.llmProfiles
                profiles.activeSource = newValue
                settings.persist(profiles)
            }
        )
    }

    private var llmAPIKeyBinding: Binding<String> {
        llmConfigBinding(\.apiKey)
    }

    private var llmModelBinding: Binding<String> {
        llmConfigBinding(\.model)
    }

    private var llmBaseURLBinding: Binding<String> {
        llmConfigBinding(\.baseURL)
    }

    private func llmConfigBinding(_ keyPath: WritableKeyPath<LLMConfig, String>) -> Binding<String> {
        Binding(
            get: {
                switch settings.llmProfiles.activeSource {
                case .remote: settings.llmProfiles.remote[keyPath: keyPath]
                case .local: settings.llmProfiles.local[keyPath: keyPath]
                }
            },
            set: { newValue in
                var profiles = settings.llmProfiles
                switch profiles.activeSource {
                case .remote:
                    profiles.remote[keyPath: keyPath] = newValue
                case .local:
                    profiles.local[keyPath: keyPath] = newValue
                }
                settings.persist(profiles)
            }
        )
    }

}

@MainActor
@Observable
final class IntelligenceSettingsModel {
    var llmProfiles = LLMProfilesSettings()
    var isTestingLLMConfig = false
    private var pendingLLMConfigSaveTask: Task<Void, Never>?

    private var llmConfigStore: LLMConfigStore {
        LLMConfigStore()
    }

    func load() {
        llmProfiles = llmConfigStore.loadProfiles()
    }

    func persist(_ profiles: LLMProfilesSettings) {
        llmProfiles = profiles
        pendingLLMConfigSaveTask?.cancel()
        pendingLLMConfigSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                try? LLMConfigStore().save(profiles)
            }.value
        }
    }

    func testConnection(onMessage: @escaping (String, Bool) -> Void) {
        guard !isTestingLLMConfig else { return }
        isTestingLLMConfig = true
        let config = llmProfiles.activeConfig
        Task {
            do {
                _ = try await TitleOptimizer().benchmark(config: config)
                onMessage("连接成功", false)
            } catch {
                onMessage("连接失败", true)
            }
            isTestingLLMConfig = false
        }
    }

    func flush() {
        pendingLLMConfigSaveTask?.cancel()
        let profiles = llmProfiles
        Task.detached(priority: .utility) {
            try? LLMConfigStore().save(profiles)
        }
    }

}
