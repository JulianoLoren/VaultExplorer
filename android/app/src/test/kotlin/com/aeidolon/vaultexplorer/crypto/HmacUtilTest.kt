package com.aeidolon.vaultexplorer.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer

/**
 * Checks [HmacUtil] against published test vectors: RFC 2202 (HMAC-SHA-1),
 * RFC 4231 (HMAC-SHA-256/512) and RFC 4226 Appendix D (the HMAC values behind
 * the HOTP test codes -- what the Dart side actually sends: an 8-byte
 * big-endian counter under the shared secret). Test case 6 of each RFC uses a
 * key longer than the hash's block size, which HMAC hashes first.
 */
class HmacUtilTest {

    private fun hex(s: String): ByteArray {
        val clean = s.replace(Regex("[^0-9a-fA-F]"), "")
        require(clean.length % 2 == 0)
        return ByteArray(clean.length / 2) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    private fun hmac(hash: String, key: ByteArray, data: ByteArray): ByteArray =
        HmacUtil.compute(HmacUtil.jcaAlgorithm(hash)!!, key, data)

    private val key20 = ByteArray(20) { 0x0b }
    private val hiThere = "Hi There".toByteArray(Charsets.US_ASCII)
    private val jefe = "Jefe".toByteArray(Charsets.US_ASCII)
    private val whatDoYaWant = "what do ya want for nothing?".toByteArray(Charsets.US_ASCII)
    private val bigKeyMessage =
        "Test Using Larger Than Block-Size Key - Hash Key First".toByteArray(Charsets.US_ASCII)

    // ---- RFC 2202: HMAC-SHA-1 ----

    @Test fun sha1_rfc2202_case1() = assertArrayEquals(
        hex("b617318655057264e28bc0b6fb378c8ef146be00"),
        hmac("sha1", key20, hiThere),
    )

    @Test fun sha1_rfc2202_case2() = assertArrayEquals(
        hex("effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"),
        hmac("sha1", jefe, whatDoYaWant),
    )

    @Test fun sha1_rfc2202_case6_keyLongerThanBlock() = assertArrayEquals(
        hex("aa4ae5e15272d00e95705637ce8a3b55ed402112"),
        hmac("sha1", ByteArray(80) { 0xaa.toByte() }, bigKeyMessage),
    )

    // ---- RFC 4231: HMAC-SHA-256 ----

    @Test fun sha256_rfc4231_case1() = assertArrayEquals(
        hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
        hmac("sha256", key20, hiThere),
    )

    @Test fun sha256_rfc4231_case2() = assertArrayEquals(
        hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
        hmac("sha256", jefe, whatDoYaWant),
    )

    @Test fun sha256_rfc4231_case6_keyLongerThanBlock() = assertArrayEquals(
        hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
        hmac("sha256", ByteArray(131) { 0xaa.toByte() }, bigKeyMessage),
    )

    // ---- RFC 4231: HMAC-SHA-512 ----

    @Test fun sha512_rfc4231_case1() = assertArrayEquals(
        hex(
            "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde" +
                "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"
        ),
        hmac("sha512", key20, hiThere),
    )

    @Test fun sha512_rfc4231_case2() = assertArrayEquals(
        hex(
            "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554" +
                "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
        ),
        hmac("sha512", jefe, whatDoYaWant),
    )

    @Test fun sha512_rfc4231_case6_keyLongerThanBlock() = assertArrayEquals(
        hex(
            "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352" +
                "6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"
        ),
        hmac("sha512", ByteArray(131) { 0xaa.toByte() }, bigKeyMessage),
    )

    // ---- RFC 4226 Appendix D: HMAC-SHA-1 over a big-endian counter ----

    private fun counter(n: Long): ByteArray = ByteBuffer.allocate(8).putLong(n).array()

    @Test fun hotp_rfc4226_appendixD_counters() {
        val secret = "12345678901234567890".toByteArray(Charsets.US_ASCII)
        assertArrayEquals(hex("cc93cf18508d94934c64b65d8ba7667fb7cde4b0"), hmac("sha1", secret, counter(0)))
        assertArrayEquals(hex("75a48a19d4cbe100644e8ac1397eea747a2d33ab"), hmac("sha1", secret, counter(1)))
    }

    // ---- wire names and input validation ----

    @Test fun jcaAlgorithm_mapsTheNamesDartSends() {
        assertEquals("HmacSHA1", HmacUtil.jcaAlgorithm("sha1"))
        assertEquals("HmacSHA256", HmacUtil.jcaAlgorithm("sha256"))
        assertEquals("HmacSHA512", HmacUtil.jcaAlgorithm("sha512"))
    }

    @Test fun jcaAlgorithm_rejectsAnythingElse() {
        assertNull(HmacUtil.jcaAlgorithm(null))
        assertNull(HmacUtil.jcaAlgorithm(""))
        assertNull(HmacUtil.jcaAlgorithm("md5"))
        assertNull(HmacUtil.jcaAlgorithm("SHA256"))
        assertNull(HmacUtil.jcaAlgorithm("sha384"))
    }

    @Test fun compute_rejectsAnEmptyKey() {
        try {
            HmacUtil.compute("HmacSHA256", ByteArray(0), hiThere)
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected: neither caller has a legitimate use for an empty key
        }
    }
}
