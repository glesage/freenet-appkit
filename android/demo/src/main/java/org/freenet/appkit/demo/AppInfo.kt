package org.freenet.appkit.demo

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast

/** The app's names and the links the welcome screen shows. */
object AppInfo {
    val termsUrl: Uri = Uri.parse("https://freenet.org/terms")
    val supportUrl: Uri = Uri.parse("https://freenet.org/support")

    /** The launcher label, `AppKit`, used in prompts. */
    fun shortName(context: Context) = context.applicationInfo.loadLabel(context.packageManager).toString()

    /** `Freenet AppKit`, the welcome screen title and store listing name. */
    fun fullName(context: Context) = context.getString(R.string.app_full_name)
}

/** The schemes [openExternally] hands to other apps. */
private val externalSchemes = setOf("http", "https", "mailto")

/**
 * Open [uri] in another app, such as the browser. Only web and mail links
 * leave the app; other schemes are ignored.
 */
fun openExternally(context: Context, uri: Uri) {
    if (uri.scheme?.lowercase() !in externalSchemes) return
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
    } catch (e: ActivityNotFoundException) {
        Toast.makeText(context, "No app can open this link", Toast.LENGTH_SHORT).show()
    }
}
