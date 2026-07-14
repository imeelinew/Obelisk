import LocalAuthentication
import ObeliskCore
import ObeliskSync
import SwiftUI

struct MoreTabView: View {
    @Bindable var library: ObeliskLibraryModel

    var body: some View {
        NavigationStack {
            List {
                Section("内容") {
                    NavigationLink {
                        HiddenBookmarksView(library: library)
                    } label: {
                        MoreRow(
                            title: "隐藏书签",
                            systemImage: "eye.slash",
                            color: .indigo,
                            value: "\(library.hiddenBookmarks.count)"
                        )
                    }

                    NavigationLink {
                        ArchiveView(library: library)
                    } label: {
                        MoreRow(
                            title: "归档",
                            systemImage: "archivebox.fill",
                            color: .orange,
                            value: "\(library.archivedBookmarks.count)"
                        )
                    }
                }

                Section("功能") {
                    NavigationLink {
                        IntelligenceSettingsView()
                    } label: {
                        MoreRow(
                            title: "Intelligence",
                            systemImage: "sparkles",
                            color: .purple,
                            value: intelligenceEnabled ? "已开启" : "已关闭"
                        )
                    }

                    if let cloudSync = library.cloudSync {
                        NavigationLink {
                            CloudSyncView(cloudSync: cloudSync)
                        } label: {
                            MoreRow(
                                title: "云同步",
                                systemImage: "cloud",
                                color: .blue,
                                value: cloudSync.statusTitle,
                                statusColor: cloudSync.phase == .synced ? .green : nil
                            )
                        }
                    }
                }

                Section("Obelisk") {
                    NavigationLink {
                        ObeliskSettingsView()
                    } label: {
                        MoreRow(
                            title: "设置",
                            systemImage: "gearshape",
                            color: .secondary
                        )
                    }

                    NavigationLink {
                        AboutObeliskView()
                    } label: {
                        MoreRow(
                            title: "关于 Obelisk",
                            systemImage: "info.circle",
                            color: .secondary,
                            value: appVersion
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("更多")
        }
    }

    @AppStorage("aiFeaturesEnabled") private var intelligenceEnabled = true

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.0"
    }
}

private struct MoreRow: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String?
    var statusColor: Color?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(color)

            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if let value {
                HStack(spacing: 6) {
                    if let statusColor {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(value)
                        .foregroundStyle(statusColor ?? .secondary)
                }
                .font(.subheadline)
            }
        }
    }
}

private struct HiddenBookmarksView: View {
    let library: ObeliskLibraryModel

    @AppStorage("protectHiddenBookmarksWithFaceID") private var isProtected = true
    @State private var isUnlocked = false

    var body: some View {
        Group {
            if !isProtected || isUnlocked {
                List {
                    Section("隐藏书签") {
                        ForEach(library.hiddenBookmarks) { bookmark in
                            BookmarkButton(bookmark: bookmark, library: library)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView {
                    Label("隐藏书签已锁定", systemImage: "lock.fill")
                } actions: {
                    Button("使用 Face ID 解锁") {
                        Task { await authenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("隐藏书签")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if isProtected {
                await authenticate()
            }
        }
    }

    private func authenticate() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return
        }
        isUnlocked = (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "查看隐藏书签"
        )) == true
    }
}

private struct ArchiveView: View {
    let library: ObeliskLibraryModel

    @AppStorage(ObeliskLibraryModel.autoArchiveEnabledKey) private var autoArchiveEnabled = false
    @AppStorage(ObeliskLibraryModel.archiveAfterDaysKey) private var archiveAfterDays = ObeliskLibraryModel.defaultArchiveDays

    var body: some View {
        Form {
            Section("自动归档") {
                Toggle(isOn: $autoArchiveEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动归档闲置书签")
                        Text("开启后 Obelisk 会自动归档您一段时间没有使用的书签")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if autoArchiveEnabled {
                    Stepper(
                        value: $archiveAfterDays,
                        in: ObeliskLibraryModel.minimumArchiveDays...ObeliskLibraryModel.maximumArchiveDays
                    ) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("闲置天数")
                                Text("Obelisk 会自动将超过这个天数没有打开的书签归档")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Text("\(archiveAfterDays) 天")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("归档书签") {
                ForEach(library.archivedBookmarks) { bookmark in
                    BookmarkButton(bookmark: bookmark, library: library)
                        .swipeActions {
                            if bookmark.archivedAt != nil {
                                Button("恢复到书签") {
                                    library.setArchived(false, bookmark: bookmark)
                                }
                                .tint(.blue)
                            }
                        }
                }
            }
        }
        .navigationTitle("归档")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: autoArchiveEnabled) { _, _ in
            library.refreshArchiveSettings()
        }
        .onChange(of: archiveAfterDays) { _, newValue in
            archiveAfterDays = min(
                ObeliskLibraryModel.maximumArchiveDays,
                max(ObeliskLibraryModel.minimumArchiveDays, newValue)
            )
            library.refreshArchiveSettings()
        }
    }
}

private struct ObeliskSettingsView: View {
    @AppStorage("showsURLHostOnly") private var showsURLHostOnly = true
    @AppStorage("protectHiddenBookmarksWithFaceID") private var protectsHiddenBookmarks = true

    var body: some View {
        Form {
            Section("域名显示") {
                Toggle(isOn: showsFullURL) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("显示完整网站域名")
                        Text("开启后书签列表会显示完整 URL")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("安全") {
                Toggle("使用 Face ID 保护隐藏书签", isOn: $protectsHiddenBookmarks)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var showsFullURL: Binding<Bool> {
        Binding(
            get: { !showsURLHostOnly },
            set: { showsURLHostOnly = !$0 }
        )
    }
}

private struct AboutObeliskView: View {
    var body: some View {
        Form {
            LabeledContent("Obelisk", value: version)
        }
        .navigationTitle("关于 Obelisk")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
