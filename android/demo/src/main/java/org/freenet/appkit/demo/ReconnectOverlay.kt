package org.freenet.appkit.demo

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * Goes over the last page while the node starts a new session: a small
 * "Reconnecting" pill at the top, and a transparent layer that takes all
 * taps, so the stale page can't be used.
 */
class ReconnectOverlay(context: Context) {
    private val density = context.resources.displayMetrics.density

    private val pill = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val padH = (16 * density).toInt()
        val padV = (8 * density).toInt()
        setPadding(padH, padV, padH, padV)
        background = GradientDrawable().apply { cornerRadius = 100 * density; setColor(Color.parseColor("#E61B1F24")) }
        elevation = 6 * density
        addView(ProgressBar(context).apply { isIndeterminate = true },
            LinearLayout.LayoutParams((16 * density).toInt(), (16 * density).toInt()))
        addView(TextView(context).apply {
            text = "Reconnecting"
            setTextColor(Color.WHITE)
            textSize = 14f
            setPadding((8 * density).toInt(), 0, 0, 0)
        })
    }

    val view = FrameLayout(context).apply {
        isClickable = true
        isFocusable = true
        visibility = View.GONE
        contentDescription = "Reconnecting"
        addView(pill, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = (12 * density).toInt() })
    }

    fun show() {
        view.visibility = View.VISIBLE
        view.bringToFront()
    }

    fun hide() {
        view.visibility = View.GONE
    }
}
