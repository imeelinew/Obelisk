import ObeliskSync
import SwiftUI

struct CloudSyncView: View {
    @Bindable var cloudSync: CloudSyncController

    @State private var email = ""
    @State private var password = ""
    @State private var accountError: String?
    @State private var showsSignOutConfirmation = false

    var body: some View {
        Form {
            Section("同步") {
                Toggle(isOn: syncEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开启云同步功能")
                        Text("在你的设备之间同步书签、分组和使用记录，关闭云同步后，Obelisk 仍会将所有数据保存在本机")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if cloudSync.isEnabled {
                    LabeledContent {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(cloudSync.statusTitle)
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

                    if cloudSync.phase == .failed {
                        Button(cloudSync.isPerformingAction ? "重试中…" : "重试同步") {
                            Task { await cloudSync.retry() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!cloudSync.isAuthenticated || cloudSync.isPerformingAction)
                    }
                }
            }

            if cloudSync.isEnabled {
                accountSection
                serviceSection
            }
        }
        .navigationTitle("云同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            email = cloudSync.accountEmail ?? email
        }
        .confirmationDialog(
            "退出云账户？",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出账户", role: .destructive) {
                Task {
                    do {
                        try await cloudSync.signOut()
                    } catch {
                        accountError = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同步将停止，登录信息会从本机移除，本地书签不会被删除")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("云账户") {
            if cloudSync.isAuthenticated {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cloudSync.accountEmail ?? "已连接云账户")
                    Text("此账户用于验证云端数据的访问权限")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("退出云账户")
                        Text("停止同步并移除本机保存的登录信息，不会删除本地书签")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("退出账户", role: .destructive) {
                        showsSignOutConfirmation = true
                    }
                    .disabled(cloudSync.isPerformingAction)
                }
            } else {
                TextField("邮箱", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("密码", text: $password)
                    .textContentType(.password)

                if let accountError {
                    Text(accountError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button(cloudSync.isPerformingAction ? "请稍候…" : "登录并开启同步") {
                    authenticate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    cloudSync.isPerformingAction
                        || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || password.isEmpty
                )
            }
        }
    }

    private var serviceSection: some View {
        Section("云服务") {
            LabeledContent {
                Text(cloudSync.apiStatusTitle)
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("同步服务器")
                    Text(cloudSync.apiHost)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Text(cloudSync.powerSyncStatusTitle)
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("实时同步服务")
                        Text(cloudSync.powerSyncHost)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(cloudSync.isTestingConnection ? "测试中…" : "测试连接") {
                    Task { await cloudSync.testConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(cloudSync.isTestingConnection)
            }
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

    private var statusColor: Color {
        switch cloudSync.phase {
        case .synced: .green
        case .connecting, .uploading, .downloading, .syncing: .accentColor
        case .failed: .red
        case .off, .authenticationRequired, .offline: .secondary
        }
    }

    private var statusDescription: String {
        if let error = cloudSync.syncError {
            return error
        }
        guard let date = cloudSync.lastSyncedAt else {
            return "尚未完成同步"
        }
        return "上次同步：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func authenticate() {
        accountError = nil
        Task {
            do {
                try await cloudSync.login(email: email, password: password)
                password = ""
            } catch {
                accountError = error.localizedDescription
            }
        }
    }
}
