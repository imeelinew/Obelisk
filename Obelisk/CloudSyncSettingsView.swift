import ObeliskSync
import SwiftUI

struct CloudSyncSettingsView: View {
    @Bindable var cloudSync: CloudSyncController

    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @State private var serverURL = ""
    @State private var accessKey = ""
    @State private var serviceError: String?
    @State private var serviceSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("同步") {
                    Toggle(isOn: syncEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("开启云同步功能")
                            Text("在你的设备之间同步书签、分组和最近浏览，关闭云同步后，Obelisk 仍会将所有数据保存在本机")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if cloudSync.isEnabled {
                        syncStatus
                        if cloudSync.phase == .failed {
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

            SecureField(
                "访问密钥",
                text: $accessKey,
                prompt: Text(cloudSync.hasAccessKey ? "已保存，输入新密钥可更换" : "部署 Worker 时设置的密钥")
            )

            if let serviceError {
                Text(serviceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(cloudSync.isTestingConnection ? "测试中…" : "测试连接") {
                    Task { await cloudSync.testConnection() }
                }
                .disabled(cloudSync.isTestingConnection || cloudSync.serverURLString.isEmpty)

                Spacer(minLength: 0)

                if serviceSaved {
                    Text("已保存")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(cloudSync.isPerformingAction ? "请稍候…" : "保存并同步") {
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
        serviceSaved = false
        Task {
            do {
                try await cloudSync.saveService(serverURL: serverURL, accessKey: accessKey)
                accessKey = ""
                serviceSaved = true
            } catch {
                serviceError = error.localizedDescription
            }
        }
    }
}
