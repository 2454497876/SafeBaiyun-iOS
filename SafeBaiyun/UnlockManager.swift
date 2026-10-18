import CoreBluetooth
import SwiftUI

/// 蓝牙开锁流程，对应 Android 版 `UnlockRepo.kt`。
///
/// iOS 与 Android 的一个关键差异：iOS 出于隐私保护**不向 App 暴露外设的 MAC 地址**，
/// 无法像 Android 那样按 MAC 直接连接，因此采用「扫描 → 用户在列表中点选门禁设备 → 自动完成开锁」。
/// MAC 地址仍用于：① 输入合法性校验；② 生成开锁报文的头部字段。
final class UnlockManager: NSObject, ObservableObject {

    static let shared = UnlockManager()

    /// 门禁 GATT 服务 UUID（与 Android 版一致）
    static let magicServiceUUID = CBUUID(string: "14839ac4-7d7e-415c-9a42-167340cf2339")

    @Published var isScanning = false
    @Published var devices: [CBPeripheral] = []
    @Published var logs: [String] = []
    @Published var message: String?
    @Published var stateText = "蓝牙状态检测中…"

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var readableCharacteristic: CBCharacteristic?
    private var writeableCharacteristic: CBCharacteristic?
    private var macBytes: [UInt8] = []
    private var keyString = ""
    private var timeoutWork: DispatchWorkItem?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外接口

    /// 开始扫描门禁设备（15 秒后自动停止）
    func scan() {
        guard centralManager.state == .poweredOn else {
            message = "蓝牙未开启，请先在控制中心打开蓝牙"
            return
        }
        devices = []
        log("开始扫描门禁设备…")
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.stopScan()
        }
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        centralManager.stopScan()
        log("扫描结束，共发现 \(devices.count) 个设备")
    }

    /// 连接指定设备并执行开锁流程
    func unlock(device: CBPeripheral, mac: String, key: String) {
        stopScan()
        macBytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        keyString = key
        guard macBytes.count == 6 else {
            message = "MAC 地址格式错误，示例：AA:BB:CC:DD:EE:FF"
            return
        }
        guard LockBiz.hexToBytes(key).count >= 8 else {
            message = "Key 格式错误，应为连续十六进制字符串（至少 8 字节，即 16 个字符）"
            return
        }

        peripheral = device
        device.delegate = self
        log("开始连接 \(device.name ?? device.identifier.uuidString)…")
        centralManager.connect(device, options: nil)

        // 10 秒超时自动断开（对应 Android 版逻辑）
        let work = DispatchWorkItem { [weak self] in
            self?.log("10s 超时，自动断开连接")
            self?.cleanup()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - 内部逻辑

    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(text)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func cleanup() {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        peripheral = nil
        readableCharacteristic = nil
        writeableCharacteristic = nil
    }

    /// 收到挑战值后加密并写回
    private func handleChallenge(_ value: Data) {
        let challenge = [UInt8](value)
        log("收到挑战值（\(challenge.count) 字节）：\(hex(challenge))")
        guard let writeCharacteristic = writeableCharacteristic,
              let packet = LockBiz.encryptData(
                  inputData: challenge,
                  headerData: macBytes,
                  keyString: keyString
              ) else {
            message = "加密失败，请检查 MAC / Key 是否正确"
            cleanup()
            return
        }
        log("写入密钥报文：\(hex(packet))")
        peripheral?.writeValue(Data(packet), for: writeCharacteristic, type: .withResponse)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - CBCentralManagerDelegate

extension UnlockManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateText = "蓝牙已就绪"
        case .poweredOff:
            stateText = "蓝牙未开启，请打开蓝牙"
            isScanning = false
        case .unauthorized:
            stateText = "未授权蓝牙权限，请到 设置 → 隐私与安全性 → 蓝牙 中允许"
        case .unsupported:
            stateText = "此设备不支持蓝牙"
        default:
            stateText = "蓝牙不可用"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) {
            devices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        timeoutWork?.cancel()
        log("连接成功，开始搜索服务…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        message = "连接门禁失败，请靠近门禁后重试"
        cleanup()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("连接已断开")
        cleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension UnlockManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("搜索服务失败：\(error.localizedDescription)")
            message = "未找到门禁服务"
            cleanup()
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.magicServiceUUID }) else {
            let found = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
            log("未找到门禁服务，可用服务：\(found)")
            message = "未找到门禁服务，请确认选中的是门禁设备"
            cleanup()
            return
        }
        log("找到门禁服务 \(service.uuid.uuidString)，开始查找特征…")
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            log("查找特征失败：\(error.localizedDescription)")
            cleanup()
            return
        }
        guard let characteristics = service.characteristics else { return }

        var notifyCharacteristics: [CBCharacteristic] = []
        for characteristic in characteristics {
            let props = characteristic.properties
            log("特征 \(characteristic.uuid.uuidString) properties=\(props.rawValue)")
            if props.contains(.read) {
                readableCharacteristic = characteristic
            }
            if props.contains(.write) {
                writeableCharacteristic = characteristic
            }
            if props.contains(.notify) || props.contains(.indicate) {
                notifyCharacteristics.append(characteristic)
            }
        }

        // 订阅通知（iOS 自动写 CCCD 描述符，等价于 Android 手动写描述符）
        for characteristic in notifyCharacteristics {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        log("已订阅通知，开始读取挑战值…")
        if let readable = readableCharacteristic {
            peripheral.readValue(for: readable)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("订阅通知失败：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("读取失败：\(error.localizedDescription)")
            message = "读取挑战值失败"
            cleanup()
            return
        }
        guard let value = characteristic.value, !value.isEmpty else {
            log("读取到空数据")
            return
        }
        handleChallenge(value)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("密钥写入失败：\(error.localizedDescription)")
            message = "开门失败，请重试"
        } else {
            log("密钥写入成功，门禁已触发开锁")
            message = "开门成功"
        }
        cleanup()
    }
}
