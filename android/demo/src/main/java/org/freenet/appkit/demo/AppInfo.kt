package org.freenet.appkit.demo

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast

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
