import CryptoKit
import Foundation
import Security

/// 对应 `vault-crypto.js`：RSA-OAEP(SHA-256) 封装随机 AES-256-GCM 密钥；记录与私钥均用 AES-GCM。
/// 扩展里密码派生用 Argon2id；iOS 无内置 Argon2，此处用 **PBKDF2-HMAC-SHA256** 高迭代逼近「慢哈希」目的（与 Chrome 插件数据不互通）。
enum VaultCryptoService {
    /// 与扩展「不宜过快」同量级目标；可按设备调整。
    static let pbkdf2Iterations: UInt32 = 250_000
    static let saltLength = 16
    static let aesIVLength = 12
    static let rsaBits = 2048

    enum VaultCryptoError: Error {
        case invalidInput
        case keyDerivationFailed
        case keyGenerationFailed
        case encryptFailed
        case decryptFailed
        case rsaFailed
        case randomGenerationFailed
    }

    // MARK: - Password key（扩展为 Argon2id；此处 PBKDF2-SHA256）

    static func derivePasswordSymmetricKey(password: String, salt: Data) throws -> SymmetricKey {
        guard let pwdData = password.data(using: .utf8), !pwdData.isEmpty else { throw VaultCryptoError.invalidInput }
        var derived = Data(count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { dbuf in
            guard let dptr = dbuf.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return salt.withUnsafeBytes { sbuf in
                guard let sptr = sbuf.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
                return pwdData.withUnsafeBytes { pbuf in
                    guard let pptr = pbuf.bindMemory(to: Int8.self).baseAddress else { return Int32(kCCParamError) }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pptr,
                        pwdData.count,
                        sptr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        dptr,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { buf -> Int32 in
            guard let p = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, p)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.randomGenerationFailed }
        return d
    }

    // MARK: - RSA 2048

    static func generateRSAKeyPair() throws -> (publicKey: SecKey, privateKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: rsaBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.keyGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw VaultCryptoError.keyGenerationFailed }
        return (publicKey, privateKey)
    }

    static func exportPublicKeySPKI(_ publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return data
    }

    static func importPublicKeySPKI(_ data: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: rsaBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return key
    }

    static func exportPrivateKeyDER(_ privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return data
    }

    static func importPrivateKeyDER(_ data: Data) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: rsaBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? VaultCryptoError.invalidInput
        }
        return key
    }

    // MARK: - AES-GCM（与扩展一致：12 字节 IV，tag 128 bit，密文区为 ciphertext||tag）

    static func aesGcmEncrypt(plain: Data, key: SymmetricKey) throws -> (iv: Data, ciphertextWithTag: Data) {
        let iv = try randomBytes(aesIVLength)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
        var out = Data()
        out.append(contentsOf: sealed.ciphertext)
        out.append(contentsOf: sealed.tag)
        return (iv, out)
    }

    static func aesGcmDecrypt(iv: Data, ciphertextWithTag: Data, key: SymmetricKey) throws -> Data {
        guard ciphertextWithTag.count >= 16 else { throw VaultCryptoError.decryptFailed }
        let tag = ciphertextWithTag.suffix(16)
        let ct = ciphertextWithTag.dropLast(16)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    static func encryptPrivateKeyWithPassword(privateKey: SecKey, passwordKey: SymmetricKey) throws -> VaultEncryptedBlob {
        let pk = try exportPrivateKeyDER(privateKey)
        let (iv, ct) = try aesGcmEncrypt(plain: pk, key: passwordKey)
        return VaultEncryptedBlob(iv: iv.base64EncodedString(), ciphertext: ct.base64EncodedString())
    }

    static func decryptPrivateKeyWithPassword(blob: VaultEncryptedBlob, passwordKey: SymmetricKey) throws -> SecKey {
        guard let iv = Data(base64Encoded: blob.iv), let ct = Data(base64Encoded: blob.ciphertext) else {
            throw VaultCryptoError.invalidInput
        }
        let der = try aesGcmDecrypt(iv: iv, ciphertextWithTag: ct, key: passwordKey)
        return try importPrivateKeyDER(der)
    }

    // MARK: - 单条记录（对应 encryptRecordWithPublicKey / decryptRecordWithPrivateKey）

    /// 供后台任务使用：只传 SPKI DER，避免在并发域之间传递 `SecKey`。
    static func encryptRecord(spkiDER: Data, payload: VaultPayload) throws -> VaultRecordEncoded {
        let pub = try importPublicKeySPKI(spkiDER)
        return try encryptRecord(payload: payload, publicKey: pub)
    }

    static func encryptRecord(payload: VaultPayload, publicKey: SecKey) throws -> VaultRecordEncoded {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let plain = try encoder.encode(payload)
        let aesKeyData = try randomBytes(32)
        let sym = SymmetricKey(data: aesKeyData)
        let (iv, ciphertextWithTag) = try aesGcmEncrypt(plain: plain, key: sym)
        var err: Unmanaged<CFError>?
        guard let encKey = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, aesKeyData as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() ?? VaultCryptoError.rsaFailed
        }
        return VaultRecordEncoded(iv: iv, ciphertext: ciphertextWithTag, encryptedAesKey: encKey)
    }

    static func decryptRecord(encoded: VaultRecordEncoded, privateKey: SecKey) throws -> VaultPayload {
        var err: Unmanaged<CFError>?
        guard let aesRaw = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, encoded.encryptedAesKey as CFData, &err) as Data? else {
            throw err?.takeRetainedValue() ?? VaultCryptoError.rsaFailed
        }
        let sym = SymmetricKey(data: aesRaw)
        let json = try aesGcmDecrypt(iv: encoded.iv, ciphertextWithTag: encoded.ciphertext, key: sym)
        return try JSONDecoder().decode(VaultPayload.self, from: json)
    }

    /// 首次设置保险库：盐 + RSA + 加密私钥
    static func createVaultMeta(password: String) throws -> VaultMetaFile {
        guard password.count >= 8, password.count <= 16 else { throw VaultCryptoError.invalidInput }
        let salt = try randomBytes(saltLength)
        let passwordKey = try derivePasswordSymmetricKey(password: password, salt: salt)
        let (pub, priv) = try generateRSAKeyPair()
        let spki = try exportPublicKeySPKI(pub)
        let encPriv = try encryptPrivateKeyWithPassword(privateKey: priv, passwordKey: passwordKey)
        return VaultMetaFile(
            salt: salt.base64EncodedString(),
            publicKeySPKI: spki.base64EncodedString(),
            encryptedPrivateKey: encPriv
        )
    }

    static func loadPublicKey(from meta: VaultMetaFile) throws -> SecKey {
        guard let d = Data(base64Encoded: meta.publicKeySPKI) else { throw VaultCryptoError.invalidInput }
        return try importPublicKeySPKI(d)
    }

    static func unlockPrivateKey(meta: VaultMetaFile, password: String) throws -> SecKey {
        guard let salt = Data(base64Encoded: meta.salt) else { throw VaultCryptoError.invalidInput }
        let passwordKey = try derivePasswordSymmetricKey(password: password, salt: salt)
        return try decryptPrivateKeyWithPassword(blob: meta.encryptedPrivateKey, passwordKey: passwordKey)
    }
}
