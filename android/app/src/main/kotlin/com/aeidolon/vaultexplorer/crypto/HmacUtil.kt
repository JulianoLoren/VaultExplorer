package com.aeidolon.vaultexplorer.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * One-shot HMAC over an in-memory buffer, via the platform's JCA [Mac].
 *
 * Backs the `hmac` platform-channel method (see `DerivedKeyHandlers.handleHmac`),
 * which replaced the third-party Dart `crypto` package for the built-in
 * authenticator's TOTP/HOTP code generation and for the Bitwarden import's
 * HKDF / MAC check. Same primitive family the sibling handlers already use
 * (`MessageDigest` for the hash verifier, `Cipher` for AES-CBC).
 *
 * Kept as a plain object with no Android dependencies so it can be unit
 * tested on the JVM against the published RFC vectors ([HmacUtilTest]).
 */
object HmacUtil {

    /**
     * Maps the wire name Dart sends (`HmacHash.name`) to its JCA algorithm
     * name, or null for anything unsupported -- callers reject null rather
     * than guessing a default hash.
     */
    fun jcaAlgorithm(hash: String?): String? = when (hash) {
        "sha1" -> "HmacSHA1"
        "sha256" -> "HmacSHA256"
        "sha512" -> "HmacSHA512"
        else -> null
    }

    /**
     * HMAC of [data] under [key]. [jcaAlgorithm] is a value returned by
     * [jcaAlgorithm]. [key] must be non-empty: `SecretKeySpec` rejects an
     * empty key, and neither caller has a legitimate use for one.
     */
    fun compute(jcaAlgorithm: String, key: ByteArray, data: ByteArray): ByteArray {
        require(key.isNotEmpty()) { "HMAC key must not be empty" }
        val mac = Mac.getInstance(jcaAlgorithm)
        mac.init(SecretKeySpec(key, jcaAlgorithm))
        return mac.doFinal(data)
    }
}
