package org.freenet.appkit.demo

import android.content.Context
import android.graphics.Typeface
import android.os.Build
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * The first-start screen: what the app does, that it connects to other
 * people's devices, and the terms and support links. "Continue" stores that
 * it was seen; the node starts only after that.
 */
class WelcomeScreen(private val context: Context, onContinue: () -> Unit) {
    private val density = context.resources.displayMetrics.density
    private val textColor = context.obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary)).let {
        val colors = it.getColorStateList(0)
        it.recycle()
        colors
    }

    val view = ScrollView(context).apply { isFillViewport = true }

    init {
        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL or Gravity.CENTER_VERTICAL
            val pad = dp(28)
            setPadding(pad, pad, pad, pad)
        }
        column.addView(ImageView(context).apply {
            setImageResource(R.mipmap.ic_launcher)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(96), dp(96)))
        column.addView(TextView(context).apply {
            text = AppInfo.fullName(context)
            textSize = 28f
            setTextColor(textColor)
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, dp(12))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) setAccessibilityHeading(true)
        })
        for (line in LINES) {
            column.addView(TextView(context).apply {
                text = line
                textSize = 17f
                setTextColor(textColor)
                gravity = Gravity.CENTER
                setPadding(0, dp(8), 0, dp(8))
            })
        }
        column.addView(TextView(context).apply {
            text = linked("By continuing you agree to the Terms.", "Terms") { openExternally(context, AppInfo.termsUrl) }
            movementMethod = LinkMovementMethod.getInstance()
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(24), 0, dp(4))
        })
        column.addView(TextView(context).apply {
            text = linked("Support", "Support") { openExternally(context, AppInfo.supportUrl) }
            movementMethod = LinkMovementMethod.getInstance()
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, dp(24))
        })
        column.addView(Button(context).apply {
            text = "Continue"
            isAllCaps = false
            textSize = 17f
            minWidth = dp(200)
            setOnClickListener {
                markSeen(context)
                onContinue()
            }
        })
        view.addView(column)
    }

    private fun dp(value: Int) = (value * density).toInt()

    private fun linked(text: String, word: String, onClick: () -> Unit) = SpannableString(text).apply {
        val start = text.indexOf(word)
        setSpan(object : ClickableSpan() {
            override fun onClick(widget: View) = onClick()
        }, start, start + word.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    companion object {
        private val LINES = listOf(
            "Chat with River and browse Atlas, served by Freenet running on your phone.",
            "Freenet connects directly to other people's devices. It runs only while this app is open.",
            "What you post is shared with other people on the network.",
        )
        private const val KEY = "welcomeSeen"

        private fun prefs(context: Context) = context.getSharedPreferences("appkit", Context.MODE_PRIVATE)

        fun isSeen(context: Context) = prefs(context).getBoolean(KEY, false)

        fun markSeen(context: Context) = prefs(context).edit().putBoolean(KEY, true).apply()
    }
}
