import SwiftUI

struct GeneralSettingsView: View {
    let onMessage: (String, Bool) -> Void
    @State private var launchAtLoginEnabled = LoginItemController.isEnabled
    @State private var showLanguageRestartAlert = false
    @AppStorage(AppLanguagePreference.storageKey) private var appLanguagePreferenceRaw = AppLanguagePreference.auto.rawValue
    @AppStorage("windowTransparencyEnabled") private var windowTransparencyEnabled = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("在登录时启动 Obelisk", isOn: launchAtLoginBinding)
            }

            Section("语言") {
                LabeledContent("语言") {
                    CompactBorderedMenuPicker(
                        options: Array(AppLanguagePreference.allCases),
                        selection: appLanguagePreferenceBinding,
                        title: { $0.pickerLabel }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(windowTransparencyEnabled ? .hidden : .automatic)
        .settingsContentMargins()
        .navigationTitle("设置")
        .onAppear {
            refreshLaunchAtLoginState()
        }
        .alert(
            "重新打开 Obelisk?",
            isPresented: $showLanguageRestartAlert
        ) {
            Button("稍后", role: .cancel) {}
            Button("重新打开") {
                AppRelauncher.relaunch()
            }
        } message: {
            Text("语言将在重新打开后生效")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { setLaunchAtLoginEnabled($0) }
        )
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LoginItemController.isEnabled
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        let previousValue = launchAtLoginEnabled
        launchAtLoginEnabled = isEnabled

        do {
            try LoginItemController.setEnabled(isEnabled)
            refreshLaunchAtLoginState()
            if launchAtLoginEnabled == isEnabled {
                onMessage(isEnabled ? "已开启登录时启动" : "已关闭登录时启动", false)
            } else {
                onMessage("请在系统设置中允许 Obelisk 登录时启动", true)
            }
        } catch {
            launchAtLoginEnabled = previousValue
            onMessage(error.localizedDescription, true)
        }
    }

    private var appLanguagePreferenceBinding: Binding<AppLanguagePreference> {
        Binding(
            get: { AppLanguagePreference(rawValue: appLanguagePreferenceRaw) ?? .auto },
            set: { newValue in
                let current = AppLanguagePreference(rawValue: appLanguagePreferenceRaw) ?? .auto
                guard newValue != current else { return }
                appLanguagePreferenceRaw = newValue.rawValue
                AppLanguagePreference.persistForNextLaunch(newValue)
                showLanguageRestartAlert = true
            }
        )
    }

}
