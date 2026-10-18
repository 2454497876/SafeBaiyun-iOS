#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
验证从 Kotlin(LockBiz.kt / FDes.kt / ByteUtil.kt) 移植的开锁报文算法：
1. DES/ECB/NoPadding 用标准测试向量校验
2. 用合成输入跑完整 encryptData，检查报文结构与校验和
Swift 版(LockBiz.swift)是本脚本的逐行直译。
"""
from Crypto.Cipher import DES

# ---------- 1. DES/ECB/NoPadding 标准测试向量 ----------
# FIPS 标准向量: key=133457799BBCDFF1, plaintext=0123456789ABCDEF, ciphertext=85E813540F0AB405
def des_ecb_nopadding(data: bytes, key: bytes) -> bytes:
    cipher = DES.new(key[:8], DES.MODE_ECB)
    return cipher.encrypt(data)

key_vec = bytes.fromhex("133457799BBCDFF1")
pt_vec = bytes.fromhex("0123456789ABCDEF")
ct_expected = bytes.fromhex("85E813540F0AB405")
ct_actual = des_ecb_nopadding(pt_vec, key_vec)
assert ct_actual == ct_expected, f"DES test vector FAIL: {ct_actual.hex()} != {ct_expected.hex()}"
print("[OK] DES/ECB/NoPadding 标准测试向量通过: 85E813540F0AB405")

# ---------- 2. 移植 LockBiz.encryptData ----------
def hex_to_bytes(hex_str: str) -> bytes:
    return bytes.fromhex(hex_str)

def encrypt_data(input_data: bytes, header_data: bytes, key_string: str) -> bytes:
    key_bytes = hex_to_bytes(key_string)
    header_bytes_subset = header_data[2:6]          # headerData[2..5] 共 4 字节

    # sum = Σ inputData 无符号值 + Σ keyBytes 无符号值
    total = sum(input_data) + sum(key_bytes)
    sum_bytes = bytes([total & 0xFF, (total >> 8) & 0xFF])

    # 拼接 sumBytes + inputData，补零到 8 的整数倍
    padded_length = len(sum_bytes) + len(input_data)
    if padded_length % 8 != 0:
        padded_length = (padded_length // 8 + 1) * 8
    padded_data = bytearray(padded_length)
    padded_data[0] = sum_bytes[0]
    padded_data[1] = sum_bytes[1]
    padded_data[2:2 + len(input_data)] = input_data

    # DES/ECB/NoPadding，取前 8 字节
    encrypted_block = des_ecb_nopadding(bytes(padded_data), key_bytes)[:8]

    # 组装 20 字节报文
    final_data = bytearray(len(encrypted_block) + 12)  # 20
    final_data[0] = 0xA5
    final_data[1] = len(encrypted_block) + 12          # 20
    final_data[2] = 5
    final_data[3:7] = header_bytes_subset
    final_data[7] = 0
    final_data[8] = 1
    final_data[9] = 7
    final_data[10:18] = encrypted_block
    final_data[18] = 0
    final_data[19] = 90                                # 0x5A

    # checksum = Σ final_data；final_data[18] = ~checksum & 0xFF
    checksum = sum(final_data)
    final_data[18] = (~checksum) & 0xFF
    return bytes(final_data)

# ---------- 3. 合成输入验证 ----------
# 模拟: MAC=AA:BB:CC:DD:EE:FF, key=16 位十六进制, challenge=8 字节
mac = bytes.fromhex("AABBCCDDEEFF")
key = "1234567890ABCDEF"          # 8 字节连续 hex
challenge = bytes.fromhex("0102030405060708")

packet = encrypt_data(challenge, mac, key)

assert len(packet) == 20, f"packet len={len(packet)}"
assert packet[0] == 0xA5, "head 0xA5"
assert packet[1] == 20, "len byte"
assert packet[2] == 5, "type byte"
assert packet[3:7] == mac[2:6], "header subset"
assert packet[19] == 0x5A, "tail 0x5A"
# Java 版：checksum 在 finalData[18]=0 时计算，随后 finalData[18] = ~checksum & 0xFF
pre = bytearray(packet); pre[18] = 0
assert (sum(pre) + packet[18]) & 0xFF == 0xFF, "checksum relation: packet[18] == ~checksum(含[18]=0) & 0xFF"
print("[OK] 报文结构校验通过: len=20, head=0xA5, type=5, tail=0x5A, header=MAC[2:6], checksum 正确")
print("     合成输入  MAC=AA:BB:CC:DD:EE:FF  key=1234567890ABCDEF  challenge=01 02 03 04 05 06 07 08")
print("     报文输出  " + " ".join(f"{b:02X}" for b in packet))

# ---------- 4. 边界: 挑战值非 8 字节倍数时补零路径 ----------
challenge2 = bytes.fromhex("01020304")   # 4 字节
packet2 = encrypt_data(challenge2, mac, key)
assert len(packet2) == 20
print("[OK] 挑战值 4 字节（非 8 倍数，走补零路径）报文长度仍为 20: " + " ".join(f"{b:02X}" for b in packet2))
print("\n全部验证通过：Swift 版 LockBiz.swift 按同一逻辑直译即可。")
