import Foundation
import CommonCrypto

/// 与 Android 版 `LockBiz.kt` / `FDes.kt` / `ByteUtil.kt` 逐行等价的加解密逻辑。
/// 已通过 `ref/verify.py` 交叉验证（DES/ECB/NoPadding 标准测试向量 + 报文结构/校验和）。
enum LockBiz {

    /// 生成 20 字节开锁报文。
    /// - Parameters:
    ///   - inputData: 门禁下发的挑战值（读特征值返回的字节）
    ///   - headerData: MAC 地址的 6 个字节（如 AA:BB:CC:DD:EE:FF → [0xAA,0xBB,...]）
    ///   - keyString: 加密 Key（连续十六进制字符串，至少 8 字节）
    /// - Returns: 20 字节报文；参数不合法返回 nil
    static func encryptData(inputData: [UInt8], headerData: [UInt8], keyString: String) -> [UInt8]? {
        let keyBytes = hexToBytes(keyString)
        guard keyBytes.count >= 8, headerData.count >= 6 else { return nil }

        // headerData[2...5]，共 4 字节
        let headerBytesSubset = Array(headerData[2..<6])

        // sum = Σ inputData（无符号值）+ Σ keyBytes（无符号值）
        var sum = 0
        for byte in inputData { sum += Int(byte) }
        for byte in keyBytes { sum += Int(byte) }
        let sumBytes: [UInt8] = [UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF)]

        // 拼接 sumBytes + inputData，补零到 8 的整数倍
        var paddedLength = sumBytes.count + inputData.count
        if paddedLength % 8 != 0 {
            paddedLength = (paddedLength / 8 + 1) * 8
        }
        var paddedData = [UInt8](repeating: 0, count: paddedLength)
        paddedData[0] = sumBytes[0]
        paddedData[1] = sumBytes[1]
        for (i, byte) in inputData.enumerated() {
            paddedData[2 + i] = byte
        }

        // DES/ECB/NoPadding 加密，取前 8 字节
        guard let encrypted = desECBNoPadding(Data(paddedData), key: Data(keyBytes.prefix(8))),
              encrypted.count >= 8 else { return nil }
        let encryptedBlock = [UInt8](encrypted.prefix(8))

        // 组装 20 字节报文
        var finalData = [UInt8](repeating: 0, count: encryptedBlock.count + 12) // 20
        finalData[0] = 0xA5
        finalData[1] = UInt8(encryptedBlock.count + 12) // 20
        finalData[2] = 5
        finalData[3] = headerBytesSubset[0]
        finalData[4] = headerBytesSubset[1]
        finalData[5] = headerBytesSubset[2]
        finalData[6] = headerBytesSubset[3]
        finalData[7] = 0
        finalData[8] = 1
        finalData[9] = 7
        for (i, byte) in encryptedBlock.enumerated() {
            finalData[10 + i] = byte
        }
        finalData[finalData.count - 2] = 0
        finalData[finalData.count - 1] = 90 // 0x5A

        // checksum = Σ finalData（此时倒数第二字节为 0）；随后倒数第二字节 = ~checksum & 0xFF
        var checksum = 0
        for byte in finalData { checksum += Int(byte) }
        finalData[finalData.count - 2] = UInt8((~checksum) & 0xFF)
        return finalData
    }

    /// 十六进制字符串 → 字节数组。
    /// 兼容连续 hex（"1234567890ABCDEF"），也兼容带冒号/空格/短横线的写法。
    static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard clean.count % 2 == 0 else { return [] }
        var bytes = [UInt8]()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let value = UInt8(clean[index..<next], radix: 16) else { return [] }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    /// DES/ECB/NoPadding 加密（等价于 Java `Cipher.getInstance("DES/ECB/NoPadding")`）。
    /// 使用系统 CommonCrypto，无需第三方依赖。
    private static func desECBNoPadding(_ data: Data, key: Data) -> Data? {
        let keyBytes = Array(key.prefix(8))
        let dataBytes = [UInt8](data)
        var out = [UInt8](repeating: 0, count: dataBytes.count + kCCBlockSizeDES)
        var outLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode), // 不传 kCCOptionPKCS7Padding → NoPadding
            keyBytes, keyBytes.count,
            nil,                          // ECB 无 IV
            dataBytes, dataBytes.count,
            &out, out.count,
            &outLength
        )
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(outLength))
    }
}
