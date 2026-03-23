//
//  Bridging Header：让 Swift 能调用 Objective-C 的 CommonCrypto。
//  VaultCryptoService 里 CCKeyDerivationPBKDF（PBKDF2）来自此头文件。
//  工程 Build Settings 中需设置 SWIFT_OBJC_BRIDGING_HEADER 指向本文件。
//
#import <CommonCrypto/CommonCrypto.h>
