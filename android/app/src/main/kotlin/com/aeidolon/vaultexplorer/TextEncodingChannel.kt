package com.aeidolon.vaultexplorer

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset

internal object TextEncodingChannel {
    private const val CHANNEL = "com.aeidolon.vaultexplorer/text_encoding"

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "availableCharsets" -> {
                        result.success(
                            Charset.availableCharsets().map { (name, charset) ->
                                mapOf(
                                    "name" to name,
                                    "displayName" to charset.displayName(),
                                )
                            },
                        )
                    }

                    "decode" -> {
                        val charsetName = call.argument<String>("charset")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (charsetName == null || bytes == null) {
                            result.error(
                                "INVALID_ARGUMENTS",
                                "A charset name and byte array are required.",
                                null,
                            )
                        } else {
                            result.success(String(bytes, Charset.forName(charsetName)))
                        }
                    }

                    "encode" -> {
                        val charsetName = call.argument<String>("charset")
                        val text = call.argument<String>("text")
                        if (charsetName == null || text == null) {
                            result.error(
                                "INVALID_ARGUMENTS",
                                "A charset name and text are required.",
                                null,
                            )
                        } else {
                            result.success(text.toByteArray(Charset.forName(charsetName)))
                        }
                    }

                    else -> result.notImplemented()
                }
            } catch (exception: Exception) {
                result.error(
                    "CHARSET_ERROR",
                    exception.message ?: "The requested charset is unavailable.",
                    null,
                )
            }
        }
    }
}
