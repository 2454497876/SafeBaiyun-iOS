import SwiftUI

struct SettingsView: View {
    @Binding var mac: String
    @Binding var key: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("门禁参数"),
                    footer: Text("MAC 地址格式如 AA:BB:CC:DD:EE:FF；Key 为连续十六进制加密密钥。数据仅保存在本机，不会上传。")
                ) {
                    TextField("MAC 地址", text: $mac)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    TextField("加密 Key", text: $key)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                }
                Section {
                    Button("保存") { dismiss() }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
