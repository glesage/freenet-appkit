package org.freenet.appkit.demo

import android.content.Context
import android.content.Intent
import android.net.Uri

/** Open [uri] outside the app. */
fun openExternally(context: Context, uri: Uri) {
    context.startActivity(Intent(Intent.ACTION_VIEW, uri))
}
