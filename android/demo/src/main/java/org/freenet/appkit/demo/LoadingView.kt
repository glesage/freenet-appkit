package org.freenet.appkit.demo

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * A spinner and a line of text over the whole page, or the error and a retry
 * button once loading failed.
 */
class LoadingView(context: Context) {
    private val spinner = ProgressBar(context).apply { isIndeterminate = true }
    private val text = TextView(context).apply {
        gravity = Gravity.CENTER
        setPadding(48, 24, 48, 24)
    }
    private val retry = Button(context).apply {
        text = "Try again"
        isAllCaps = false
    }
    val view = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        isClickable = true
        setBackgroundColor(backgroundColor(context))
        addView(spinner, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(text, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(retry, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    fun loading(message: String) {
        spinner.visibility = View.VISIBLE
        retry.visibility = View.GONE
        text.text = message
        view.visibility = View.VISIBLE
        view.bringToFront()
    }

    fun failed(message: String, onRetry: (() -> Unit)?) {
        spinner.visibility = View.GONE
        text.text = message
        retry.visibility = if (onRetry == null) View.GONE else View.VISIBLE
        retry.setOnClickListener { onRetry?.invoke() }
        view.visibility = View.VISIBLE
        view.bringToFront()
    }

    fun hide() {
        view.visibility = View.GONE
    }

    private fun backgroundColor(context: Context): Int {
        val attrs = context.obtainStyledAttributes(intArrayOf(android.R.attr.colorBackground))
        val color = attrs.getColor(0, android.graphics.Color.WHITE)
        attrs.recycle()
        return color
    }
}
