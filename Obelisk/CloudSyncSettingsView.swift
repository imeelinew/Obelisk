import ObeliskSync
import SwiftUI

struct CloudSyncSettingsView: View {
    @Bindable var cloudSync: CloudSyncController

    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountError: String?
    @State private var isEditingAccount = false
    @State private var showsSignOutConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        syncStatus
                        if cloudSync.phase == .failed {
                            Button(cloudSync.isPerformingAction ? "重试中…" : "重试同步") {
                                Task { await cloudSync.retry() }
                            }
                            .disabled(!cloudSync.isAuthenticated || cloudSync.isPerformingAction)
                        }
                    }
                }

                if cloudSync.isEnabled {
                    accountSection
                    serviceSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
            .settingsContentMargins()
        }
        .navigationTitle("云同步")
        .onAppear {
            accountEmail = cloudSync.accountEmail ?? ""
            isEditingAccount = cloudSync.isEnabled && !cloudSync.isAuthenticated
        }
        .confirmationDialog(
            "退出云账户？",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出账户", role: .destructive) {
                Task { await signOut() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同步将停止，登录信息会从本机移除，本地书签不会被删除")
        }
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled },
            set: { enabled in
                Task {
                    await cloudSync.setEnabled(enabled)
                    accountEmail = cloudSync.accountEmail ?? accountEmail
                    isEditingAccount = enabled && !cloudSync.isAuthenticated
                }
            }
        )
    }

    private var syncStatus: some View {
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
    }

    private var accountSection: some View {
        Section("云账户") {
            if cloudSync.isAuthenticated, !isEditingAccount {
                authenticatedAccount
            } else {
                authenticationForm
            }
        }
    }

    private var authenticatedAccount: some View {
        Group {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cloudSync.accountEmail ?? "已连接云账户")
                    Text("此账户用于验证云端数据的访问权限")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("重新认证") {
                    accountEmail = cloudSync.accountEmail ?? ""
                    accountPassword = ""
                    accountError = nil
                    isEditingAccount = true
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("退出云账户")
                    Text("停止同步并移除本机保存的登录信息，不会删除本地书签")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("退出账户", role: .destructive) {
                    showsSignOutConfirmation = true
                }
                .disabled(cloudSync.isPerformingAction)
            }
        }
    }

    private var authenticationForm: some View {
        Group {
            TextField("邮箱", text: $accountEmail)
                .textContentType(.username)
            SecureField("密码", text: $accountPassword)
                .textContentType(.password)

            if let accountError {
                Text(accountError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                if cloudSync.isAuthenticated {
                    Button("取消") {
                        accountPassword = ""
                        accountError = nil
                        isEditingAccount = false
                    }
                }
                Spacer(minLength: 0)
                Button(cloudSync.isPerformingAction ? "请稍候…" : "登录并开启同步") {
                    authenticate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    cloudSync.isPerformingAction
                        || accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || accountPassword.isEmpty
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

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时同步服务")
                    Text(cloudSync.powerSyncHost)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(cloudSync.powerSyncStatusTitle)
                    .foregroundStyle(.secondary)
                Button(cloudSync.isTestingConnection ? "测试中…" : "测试连接") {
                    Task { await cloudSync.testConnection() }
                }
                .disabled(cloudSync.isTestingConnection)
            }
        }
    }

    private var statusColor: Color {
        switch cloudSync.phase {
        case .synced:
            return Color(red: 0.13, green: 0.55, blue: 0.22)
        case .connecting, .uploading, .downloading, .syncing:
            return .accentColor
        case .failed:
            return .red
        case .off, .authenticationRequired, .offline:
            return .secondary
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
                try await cloudSync.login(email: accountEmail, password: accountPassword)
                accountPassword = ""
                isEditingAccount = false
            } catch {
                accountError = error.localizedDescription
            }
        }
    }

    private func signOut() async {
        do {
            try await cloudSync.signOut()
            accountPassword = ""
            accountError = nil
            isEditingAccount = true
        } catch {
            accountError = error.localizedDescription
        }
    }
}
