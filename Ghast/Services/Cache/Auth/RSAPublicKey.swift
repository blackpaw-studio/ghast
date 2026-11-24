import Foundation
import Security

/// Builds a Security.framework RSA public key from a JWK's `n` and `e` and checks RS256
/// signatures with it.
enum RSAPublicKey {
    /// Smallest modulus accepted, in bytes (2048 bits).
    static let minimumModulusBytes = 256

    static func make(modulus: Data, exponent: Data) -> SecKey? {
        let modulus = modulus.drop { $0 == 0 }
        guard modulus.count >= minimumModulusBytes, !exponent.isEmpty else { return nil }
        let der = sequence(integer(Data(modulus)) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    static func verifyRS256(_ key: SecKey, signingInput: Data, signature: Data) -> Bool {
        SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signature as CFData, nil)
    }

    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } in DER.

    private static func integer(_ value: Data) -> Data {
        let body = (value.first ?? 0) & 0x80 != 0 ? Data([0]) + value : value
        return Data([0x02]) + length(body.count) + body
    }

    private static func sequence(_ body: Data) -> Data {
        Data([0x30]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        let bytes = withUnsafeBytes(of: count.bigEndian, Array.init).drop { $0 == 0 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
