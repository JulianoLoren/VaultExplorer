package com.aeidolon.vaultexplorer.util

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/** Applies the language selected in Flutter settings to native notification text. */
object NotificationLocale {
    private const val PREFS_NAME = "notification_locale"
    private const val LANGUAGE_KEY = "language_code"

    fun save(context: Context, languageCode: String?) {
        val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        preferences.edit().apply {
            if (languageCode.isNullOrBlank() || languageCode == "system") {
                remove(LANGUAGE_KEY)
            } else {
                putString(LANGUAGE_KEY, languageCode)
            }
        }.apply()
    }

    fun wrap(context: Context): Context {
        val languageCode = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(LANGUAGE_KEY, null)
            ?.takeIf { it.isNotBlank() && it != "system" }
            ?: return context

        val configuration = Configuration(context.resources.configuration)
        configuration.setLocale(Locale.forLanguageTag(languageCode))
        return context.createConfigurationContext(configuration)
    }
}
