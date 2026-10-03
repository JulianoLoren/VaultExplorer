package com.aeidolon.vaultexplorer.handlers

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import com.aeidolon.vaultexplorer.MainActivity

class SecureStorageHandlers(
    private val activity: MainActivity,
) {
    private val KEY_ALIAS = "vaultexplorer_app_secure_storage_key"
    private val PREFS_NAME = "vaultexplorer_app_secure_storage"

    /**
     * Every Keystore AES-GCM operation (and the SharedPreferences commit) used
     * to run directly on the platform/UI thread, so each settings read during
     * startup blocked touch handling and frame production for the length of a
     * Keystore round trip. They now run here instead.
     *
     * Deliberately a single thread, not [MainActivity]'s shared ioExecutor:
     * the Dart side issues write-then-read sequences against the same key, and
     * one thread keeps them in the order they were sent. It is a daemon thread
     * that exits after 30s idle, so the three Activity subclasses that each
     * build their own handler don't each leave a permanent thread behind.
     */
    private val storageExecutor = ThreadPoolExecutor(
        1, 1, 30L, TimeUnit.SECONDS, LinkedBlockingQueue(),
    ) { runnable ->
        Thread(runnable, "ve-secure-storage").apply { isDaemon = true }
    }.apply { allowCoreThreadTimeOut(true) }

    private fun runOffMainThread(result: MethodChannel.Result, block: () -> Any?) {
        storageExecutor.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("SECURE_STORAGE_ERROR", e.message, null) }
            }
        }
    }

    private val androidKeyStore: KeyStore by lazy {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    }

    /**
     * The Keystore-backed key *handle* (non-exportable -- the key bytes never
     * leave the secure hardware/TEE). Resolving it with getEntry() on every
     * single read and write was a Keystore lookup per call on top of the
     * cipher operation itself. Only touched from [storageExecutor].
     */
    private var cachedMasterKey: SecretKey? = null

    private fun getOrCreateMasterKey(): SecretKey {
        cachedMasterKey?.let { return it }
        val existing = androidKeyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry
        if (existing != null) {
            cachedMasterKey = existing.secretKey
            return existing.secretKey
        }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build()
        generator.init(spec)
        val created = generator.generateKey()
        cachedMasterKey = created
        return created
    }

    /**
     * Runs [block] with the master key. If it throws, the cached handle is
     * dropped and the call retried once with a freshly resolved key, so a
     * key that was deleted or regenerated underneath us (e.g. by a panic
     * wipe) can't leave this process failing every operation until restart.
     */
    private fun <T> withMasterKey(block: (SecretKey) -> T): T? {
        for (attempt in 0..1) {
            try {
                return block(getOrCreateMasterKey())
            } catch (_: Exception) {
                cachedMasterKey = null
            }
        }
        return null
    }

    private fun encrypt(plainText: String): String? = withMasterKey { key ->
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val encryptedBytes = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + encryptedBytes.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(encryptedBytes, 0, combined, iv.size, encryptedBytes.size)
        Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encryptedBase64: String): String? {
        val combined = try {
            Base64.decode(encryptedBase64, Base64.NO_WRAP)
        } catch (_: Exception) {
            return null
        }
        if (combined.size <= 12) return null
        val iv = combined.copyOfRange(0, 12)
        val payload = combined.copyOfRange(12, combined.size)
        return withMasterKey { key ->
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            String(cipher.doFinal(payload), Charsets.UTF_8)
        }
    }

    private val prefs by lazy {
        activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun handleRead(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key == null) {
            result.error("INVALID_ARGS", "key required", null)
            return
        }
        runOffMainThread(result) {
            val encrypted = prefs.getString(key, null)
            if (encrypted == null) null else decrypt(encrypted)
        }
    }

    fun handleWrite(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        val value = call.argument<String>("value")
        if (key == null) {
            result.error("INVALID_ARGS", "key required", null)
            return
        }
        if (value == null) {
            handleDelete(call, result)
            return
        }
        runOffMainThread(result) {
            val encrypted = encrypt(value)
            if (encrypted == null) false else prefs.edit().putString(key, encrypted).commit()
        }
    }

    fun handleDelete(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key == null) {
            result.error("INVALID_ARGS", "key required", null)
            return
        }
        runOffMainThread(result) { prefs.edit().remove(key).commit() }
    }

    fun handleDeleteAll(call: MethodCall, result: MethodChannel.Result) {
        runOffMainThread(result) { prefs.edit().clear().commit() }
    }

    /**
     * Decrypts and returns stored entries. With no arguments this is every
     * entry, exactly as before. [prefixes] (include) and [excludePrefixes]
     * narrow it *before* decryption, so entries the caller never wanted --
     * notably remembered vault passwords and PIN/pattern hashes -- are not
     * decrypted, and one Keystore operation per skipped entry is saved.
     */
    fun handleReadAll(call: MethodCall, result: MethodChannel.Result) {
        val include = call.argument<List<String>>("prefixes")
        val exclude = call.argument<List<String>>("excludePrefixes")
        runOffMainThread(result) {
            val resultMap = HashMap<String, String>()
            for ((key, value) in prefs.all) {
                if (value !is String) continue
                if (include != null && include.none { key.startsWith(it) }) continue
                if (exclude != null && exclude.any { key.startsWith(it) }) continue
                val decrypted = decrypt(value)
                if (decrypted != null) {
                    resultMap[key] = decrypted
                }
            }
            resultMap
        }
    }

    fun handleContainsKey(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (key == null) {
            result.error("INVALID_ARGS", "key required", null)
            return
        }
        // Queued behind any in-flight write so it observes that write.
        runOffMainThread(result) { prefs.contains(key) }
    }
}
