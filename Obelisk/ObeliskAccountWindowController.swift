import AppKit
import ObeliskSync
import SwiftUI

@MainActor
final class ObeliskAccountWindowController: NSObject, NSWindowDelegate {
    private let auth: ObeliskAuthClient
    private let onAuthenticated: (ObeliskAuthSession) async -> Void
    private var window: NSWindow?

    init(
        auth: ObeliskAuthClient,
        onAuthenticated: @escaping (ObeliskAuthSession) async -> Void
    ) {
        self.auth = auth
        self.onAuthenticated = onAuthenticated
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = ObeliskAccountView(auth: auth) { [weak self] session in
            guard let self else { return }
            self.window?.close()
            await self.onAuthenticated(session)
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Obelisk"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 440, height: 390))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ObeliskAccountView: View {
    let auth: ObeliskAuthClient
    let onAuthenticated: (ObeliskAuthSession) async -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "bookmark.square.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("欢迎使用 Obelisk")
                    .font(.title2.weight(.semibold))
                Text("登录后，书签会在你的 Mac 与 iPhone 之间同步。")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("邮箱", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码（至少 12 个字符）", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(isSubmitting ? "请稍候…" : "登录") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isSubmitting || email.isEmpty || password.count < 12)
        }
        .padding(36)
        .frame(width: 440, height: 390)
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let session = try await auth.login(email: email, password: password)
                await onAuthenticated(session)
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
