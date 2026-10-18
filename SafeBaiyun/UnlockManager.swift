import CoreBluetooth
import SwiftUI

/// 蓝牙开锁流程，对应 Android 版 `UnlockRepo.kt`，并实现"快速自动开门"。
///
/// 提速方案（参考 BaiyunKeys 微信小程序的快速开锁机制）：
/// 1. **缓存设备直连**：记住上次开门成功的设备 UUID，下次跳过扫描直接连接（秒开）
/// 2. **按门禁服务过滤扫描**：只扫描广播门禁服务的设备，发现即连（不再被 9 台无关设备拖慢）
/// 3. **双门禁服务支持**：`14839ac4-...` 与 `0734594a-...` 任一匹配即视为门禁
/// 4. 过滤扫描无果时回退全量扫描，按"MAC 广播匹配优先 + 信号强弱"逐个尝试兜底
///
/// iOS 与 Android 的关键差异：iOS 不向 App 暴露外设真实 MAC 地址，无法像 Android
/// 那样直接按 MAC 连接，因此靠缓存 + 服务过滤实现免选择、快速开门。
final class UnlockManager: NSObject, ObservableObject {

    static let shared = UnlockManager()

    /// 门禁 GATT 服务 UUID（两个候选，与 BaiyunKeys 小程序一致；Android 版为后者）
    static let serviceUUIDs: [CBUUID] = [
        CBUUID(string: "14839ac4-7d7e-415c-9a42-167340cf2339"),
        CBUUID(string: "0734594a-a8e7-4b1a-a6b1-cd5243059a57")
    ]

    /// 缓存上次成功开门设备的系统 UUID
    static let lastDeviceUUIDKey = "lastDeviceUUID"

    @Published var isScanning = false
    @Published var isAutoUnlocking = false
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

    // 自动模式状态
    private var autoQueue: [CBPeripheral] = []
    private var rssiMap: [UUID: Int] = [:]
    private var macCandidatesMap: [UUID: [String]] = [:]

    /// 自动开门当前所处阶段
    private enum AutoStage {
        case cachedConnect // 直连缓存设备
        case filteredScan  // 按门禁服务过滤扫描（发现即连）
        case fullScan      // 全量扫描（MAC/信号兜底）
        case tryingQueue   // 逐个尝试队列
    }
    private var autoStage: AutoStage = .cachedConnect

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外接口

    /// 手动扫描（设备列表备用）
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

    /// 快速自动开门：缓存直连 → 服务过滤扫描 → 全量扫描兜底
    func autoUnlock(mac: String, key: String) {
        guard centralManager.state == .poweredOn else {
            message = "蓝牙未开启，请先在控制中心打开蓝牙"
            return
        }
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

        devices = []
        autoQueue = []
        rssiMap = [:]
        macCandidatesMap = [:]
        log("开始自动开门…")
        isAutoUnlocking = true
        autoStage = .cachedConnect
        tryCachedDevice()
    }

    /// 手动模式：连接指定设备并执行开锁流程
    func unlock(device: CBPeripheral, mac: String, key: String) {
        stopScan()
        isAutoUnlocking = false
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

        // 10 秒超时自动断开
        let work = DispatchWorkItem { [weak self] in
            self?.log("10s 超时，自动断开连接")
            self?.cleanup()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - 快速自动开门流程

    /// 阶段一：直连上次成功开门的设备（最快，秒级）
    private func tryCachedDevice() {
        guard isAutoUnlocking else { return }
        guard let uuidString = UserDefaults.standard.string(forKey: Self.lastDeviceUUIDKey),
              let uuid = UUID(uuidString: uuidString) else {
            startFilteredScan()
            return
        }
        let cached = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let device = cached.first else {
            log("上次门禁不在附近，转为扫描")
            startFilteredScan()
            return
        }
        log("直连上次成功开门的设备…")
        connectAndAttempt(device, timeout: 6)
    }

    /// 阶段二：按门禁服务过滤扫描，发现即连
    private func startFilteredScan() {
        guard isAutoUnlocking else { return }
        autoStage = .filteredScan
        devices = []
        rssiMap = [:]
        macCandidatesMap = [:]
        log("按门禁服务过滤扫描…")
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: Self.serviceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self,
                  self.isAutoUnlocking,
                  self.autoStage == .filteredScan,
                  self.peripheral == nil else { return }
            self.log("过滤扫描未发现门禁，回退全量扫描…")
            self.startFullScan()
        }
    }

    /// 阶段三：全量扫描，MAC 广播匹配优先 + 信号强弱逐个尝试
    private func startFullScan() {
        guard isAutoUnlocking else { return }
        autoStage = .fullScan
        devices = []
        rssiMap = [:]
        macCandidatesMap = [:]
        log("全量扫描附近蓝牙设备…")
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.isAutoUnlocking, self.autoStage == .fullScan else { return }
            self.stopScan()
            self.autoStage = .tryingQueue
            // MAC 广播匹配的设备排最前，其余按信号强弱
            self.autoQueue = self.devices.sorted { a, b in
                let aHit = self.macHit(for: a) ? 1 : 0
                let bHit = self.macHit(for: b) ? 1 : 0
                if aHit != bHit { return aHit > bHit }
                return (self.rssiMap[a.identifier] ?? -100) > (self.rssiMap[b.identifier] ?? -100)
            }
            if self.autoQueue.isEmpty {
                self.log("未扫描到任何蓝牙设备")
                self.message = "未扫描到设备，请确认蓝牙已开，靠近门禁（1-2 米）后重试"
                self.isAutoUnlocking = false
                return
            }
            let matched = self.autoQueue.filter { self.macHit(for: $0) }.count
            self.log("扫描到 \(self.autoQueue.count) 个设备，MAC 匹配 \(matched) 个，逐个尝试…")
            self.tryNextDevice()
        }
    }

    /// 连接并进入开锁流程（阶段一/二直连共用）
    private func connectAndAttempt(_ device: CBPeripheral, timeout: TimeInterval) {
        peripheral = device
        device.delegate = self
        log("连接 \(device.name ?? "未知设备")…")
        centralManager.connect(device, options: nil)

        // 超时：断开连接，由 didDisconnect 触发进入下一阶段
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isAutoUnlocking else { return }
            self.log("连接超时（\(Int(timeout))s）")
            self.timeoutWork = nil
            self.readableCharacteristic = nil
            self.writeableCharacteristic = nil
            if let p = self.peripheral {
                self.centralManager.cancelPeripheralConnection(p)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// 当前直连失败后按阶段继续推进
    private func continueAutoAfterFailure() {
        peripheral = nil
        readableCharacteristic = nil
        writeableCharacteristic = nil
        switch autoStage {
        case .cachedConnect:
            startFilteredScan()
        case .filteredScan:
            startFullScan()
        case .tryingQueue:
            tryNextDevice()
        case .fullScan:
            break
        }
    }

    /// 尝试队列中的下一个设备
    private func tryNextDevice() {
        guard isAutoUnlocking else { return }
        guard !autoQueue.isEmpty else {
            log("已尝试全部设备，均未找到门禁服务")
            message = "未找到门禁设备，请靠近门禁（1-2 米）后重试"
            isAutoUnlocking = false
            return
        }
        let device = autoQueue.removeFirst()
        peripheral = device
        device.delegate = self
        log("尝试 \(device.name ?? "未知设备")…")
        centralManager.connect(device, options: nil)

        // 每个设备 5 秒超时
        let work = DispatchWorkItem { [weak self] in
            self?.log("\(device.name ?? "设备") 连接超时，跳过")
            self?.cleanupForNext()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// 清理当前设备并继续尝试下一个（连接断开回调后会自动进入下一个）
    private func cleanupForNext() {
        timeoutWork?.cancel()
        timeoutWork = nil
        readableCharacteristic = nil
        writeableCharacteristic = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    /// 完全停止（手动模式 / 开锁完成）
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

    /// 记录本次成功开门的设备，下次秒开
    private func cacheLastDevice(_ device: CBPeripheral) {
        UserDefaults.standard.set(device.identifier.uuidString, forKey: Self.lastDeviceUUIDKey)
        log("已记住门禁设备，下次可直接秒开")
    }

    private func finishAutoIfNeeded() {
        isAutoUnlocking = false
        autoQueue = []
        isScanning = false
    }

    // MARK: - MAC 识别（从广播数据解析候选 MAC）

    /// 从广播数据 + 设备名中提取可能的 MAC 字符串（无冒号大写）
    private func extractMacCandidates(from advertisementData: [String: Any], peripheral: CBPeripheral) -> [String] {
        var candidates: [String] = []
        if let name = peripheral.name, !name.isEmpty {
            candidates.append(name)
        }
        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            candidates.append(contentsOf: macCandidates(fromBytes: [UInt8](mfr)))
        }
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for data in serviceData.values {
                candidates.append(contentsOf: macCandidates(fromBytes: [UInt8](data)))
            }
        }
        return candidates
    }

    /// 从字节序列中提取 12 位十六进制子串（厂商广播常见结构：公司ID(2B)+MAC(6B)+负载）
    private func macCandidates(fromBytes bytes: [UInt8]) -> [String] {
        var out: [String] = []
        if bytes.count >= 8 {
            out.append(bytes[2..<8].map { String(format: "%02X", $0) }.joined())
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        if hex.count >= 12 {
            var idx = hex.startIndex
            while let end = hex.index(idx, offsetBy: 12, limitedBy: hex.endIndex) {
                out.append(String(hex[idx..<end]))
                idx = hex.index(after: idx)
            }
        }
        return out
    }

    /// 设备广播数据是否包含所填 MAC（任一候选包含完整 MAC，或候选为 MAC 的一部分）
    private func macHit(for device: CBPeripheral) -> Bool {
        guard macBytes.count == 6 else { return false }
        let norm = macBytes.map { String(format: "%02X", $0) }.joined()
        let candidates = macCandidatesMap[device.identifier] ?? []
        for candidate in candidates {
            let clean = candidate
                .uppercased()
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
            if clean.contains(norm) { return true }
            if clean.count >= 8 && norm.contains(clean) { return true }
        }
        return false
    }

    // MARK: - 日志

    private func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(text)")
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
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
            finishAutoIfNeeded()
            cleanup()
            return
        }
        log("写入密钥报文：\(hex(packet))")
        peripheral?.writeValue(Data(packet), for: writeCharacteristic, type: .withResponse)
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
            isAutoUnlocking = false
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
        rssiMap[peripheral.identifier] = RSSI.intValue
        macCandidatesMap[peripheral.identifier] = extractMacCandidates(from: advertisementData, peripheral: peripheral)

        // 过滤扫描阶段：发现带门禁服务的设备，立即停止扫描并连接
        if isAutoUnlocking && autoStage == .filteredScan {
            central.stopScan()
            isScanning = false
            log("发现候选门禁设备 \(peripheral.name ?? "未知设备")，立即连接…")
            connectAndAttempt(peripheral, timeout: 6)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        timeoutWork?.cancel()
        isScanning = false
        log("连接成功，开始搜索服务…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        if isAutoUnlocking {
            continueAutoAfterFailure()
        } else {
            message = "连接门禁失败，请靠近门禁后重试"
            cleanup()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("连接已断开")
        if isAutoUnlocking {
            self.peripheral = nil
            readableCharacteristic = nil
            writeableCharacteristic = nil
            if autoStage == .tryingQueue {
                tryNextDevice()
            } else {
                continueAutoAfterFailure()
            }
        } else {
            cleanup()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension UnlockManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("搜索服务失败：\(error.localizedDescription)")
            if isAutoUnlocking {
                cleanup()
                continueAutoAfterFailure()
            } else {
                message = "未找到门禁服务"
                cleanup()
            }
            return
        }
        guard let service = peripheral.services?.first(where: { Self.serviceUUIDs.contains($0.uuid) }) else {
            let found = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", ")
            log("\(peripheral.name ?? "设备") 无门禁服务，可用服务：\(found)")
            if isAutoUnlocking {
                if autoStage == .tryingQueue {
                    log("跳过，尝试下一个设备…")
                    cleanupForNext()
                } else {
                    cleanup()
                    continueAutoAfterFailure()
                }
            } else {
                message = "未找到门禁服务，请确认选中的是门禁设备"
                cleanup()
            }
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
            if isAutoUnlocking {
                cleanup()
                continueAutoAfterFailure()
            } else {
                cleanup()
            }
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

        // 订阅通知（iOS 自动写 CCCD 描述符）
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
            if isAutoUnlocking {
                message = "读取挑战值失败"
                finishAutoIfNeeded()
                cleanup()
            }
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
            message = "开门失败，请检查 MAC / Key 是否正确"
        } else {
            log("密钥写入成功，门禁已触发开锁")
            message = "开门成功"
            cacheLastDevice(peripheral)
        }
        finishAutoIfNeeded()
        cleanup()
    }
}
