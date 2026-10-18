import SwiftUI

struct ContentView: View {
    @StateObject private var manager = UnlockManager.shared
    @AppStorage("mac") private var mac = ""
    @AppStorage("key") private var key = ""
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text(manager.stateText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { manager.autoUnlock(mac: mac, key: key) }) {
                    Label(
                        manager.isAutoUnlocking ? "自动开门中…" : "开门（自动识别门禁）",
                        systemImage: "lock.open.fill"
                    )
                    .font(.title3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isAutoUnlocking || mac.isEmpty || key.isEmpty)

                if manager.isAutoUnlocking {
                    ProgressView("自动开门中：扫描并识别门禁…")
                }

                if !manager.devices.isEmpty {
                    Text("扫描到的设备（自动识别失败时可手动点选）")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    List(manager.devices, id: \.identifier) { device in
                        Button {
                            manager.unlock(device: device, mac: mac, key: key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? "未知设备")
                                    .font(.headline)
                                Text(device.identifier.uuidString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: 220)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("日志").font(.headline)
                        Spacer()
                        Button("清空") { manager.logs.removeAll() }
                            .font(.footnote)
                    }
                    ScrollView {
                        ForEach(Array(manager.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 180)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("平安回家(离线)")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("设置") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(mac: $mac, key: $key)
            }
            .alert("提示", isPresented: Binding(
                get: { manager.message != nil },
                set: { if !$0 { manager.message = nil } }
            )) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(manager.message ?? "")
            }
        }
    }
}
