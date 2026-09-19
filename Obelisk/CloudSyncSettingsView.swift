import ObeliskSync
import SwiftUI

struct CloudSyncSettingsView: View {
    @Bindable var cloudSync: CloudSyncController
    let onMessage: (String, Bool) -> Void

    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @State private var serverURL = ""
    @State private var accessKey = ""
    @State private var serviceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("同步") {
                    Toggle("开启云同步功能", isOn: syncEnabled)

                    if cloudSync.isEnabled {
                        syncStatus
                        if cloudSync.phase == .failed
                            || (cloudSync.phase == .waiting && cloudSync.pendingUploadCount > 0)
                        {
                            Button("重试同步") {
                                Task { await cloudSync.retry() }
                            }
                        }
                    }
                }

                if cloudSync.isEnabled {
                    serviceSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
            .settingsContentMargins()
        }
        .navigationTitle("云同步")
        .onAppear {
            serverURL = cloudSync.serverURLString
            accessKey = cloudSync.savedAccessKey()
        }
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { enabled in
                Task { await cloudSync.setEnabled(enabled) }
            }
        )
    }

    private var syncStatus: some View {
        LabeledContent {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(cloudSync.statusTitle.obeliskLocalized)
                    .foregroundStyle(statusColor)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("同步状态")
                Text(statusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serviceSection: some View {
        Section("服务") {
            TextField("服务地址", text: $serverURL, prompt: Text(verbatim: "https://obelisk-sync.example.workers.dev"))
                .autocorrectionDisabled()

            SecureField("访问密钥", text: $accessKey)

            if let serviceError {
                Text(serviceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button(cloudSync.isTestingConnection ? "测试中…" : "测试连接") {
                    Task { await cloudSync.testConnection() }
                }
                .disabled(cloudSync.isTestingConnection || cloudSync.serverURLString.isEmpty)

                Button(cloudSync.isPerformingAction ? "请稍候…" : "保存") {
                    saveService()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    cloudSync.isPerformingAction
                        || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (accessKey.isEmpty && !cloudSync.hasAccessKey)
                )
            }
        }
    }

    private var statusColor: Color {
        switch cloudSync.phase {
        case .synced:
            return Color(red: 0.13, green: 0.55, blue: 0.22)
        case .syncing:
            return .accentColor
        case .failed:
            return .red
        case .off, .notConfigured, .waiting:
            return .secondary
        }
    }

    private var statusDescription: String {
        if let error = cloudSync.syncError {
            return error
        }
        if cloudSync.pendingUploadCount > 0 {
            return "\(cloudSync.pendingUploadCount) 项更改待上传"
        }
        guard let date = cloudSync.lastSyncedAt else {
            return "尚未完成同步"
        }
        return "上次同步：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func saveService() {
        serviceError = nil
        Task {
            do {
                try await cloudSync.saveService(serverURL: serverURL, accessKey: accessKey)
                onMessage("已保存", false)
            } catch {
                serviceError = error.localizedDescription
            }
        }
    }
}
