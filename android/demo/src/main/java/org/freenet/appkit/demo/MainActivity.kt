package org.freenet.appkit.demo

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/** The app shell: River and Atlas tabs over the embedded node. */
class MainActivity : Activity() {
    enum class Tab(val label: String) { RIVER("River"), ATLAS("Atlas") }

    private lateinit var content: FrameLayout
    private lateinit var banner: TextView
    private val tabButtons = mutableMapOf<Tab, Button>()
    private lateinit var river: WebAppPage
    private lateinit var atlas: WebAppPage

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NodeHost.init(this)
        river = WebAppPage(this, DemoWebApp.RIVER)
        atlas = WebAppPage(this, DemoWebApp.ATLAS)
        setContentView(buildShell())
        NodeHost.alertPresenter = { alert -> showAlert(alert) }
        content.post { select(Tab.RIVER) }
    }

    // The node runs only while the app is in the foreground.
    override fun onStart() {
        super.onStart()
        NodeHost.onForeground()
    }

    override fun onStop() {
        super.onStop()
        NodeHost.onBackground()
    }

    fun select(tab: Tab) {
        content.removeAllViews()
        val view = when (tab) {
            Tab.RIVER -> river.view.also { river.show() }
            Tab.ATLAS -> atlas.view.also { atlas.show() }
        }
        (view.parent as? ViewGroup)?.removeView(view)
        content.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        tabButtons.forEach { (t, button) -> button.alpha = if (t == tab) 1f else 0.55f }
    }

    private fun buildShell(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
        }
        val stack = FrameLayout(this)
        content = FrameLayout(this)
        stack.addView(content)
        banner = TextView(this).apply {
            visibility = View.GONE
            setPadding(32, 24, 32, 24)
            setTextColor(Color.WHITE)
            textSize = 15f
            background = GradientDrawable().apply { cornerRadius = 28f; setColor(Color.parseColor("#E61B1F24")) }
            elevation = 12f
        }
        stack.addView(banner, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP).apply {
            setMargins(24, 24, 24, 0)
        })
        root.addView(stack, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        val tabs = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for (tab in Tab.entries) {
            val button = Button(this).apply {
                text = tab.label
                isAllCaps = false
                setOnClickListener { select(tab) }
            }
            tabButtons[tab] = button
            tabs.addView(button, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(tabs)
        return root
    }

    private fun showAlert(alert: InAppAlert) {
        banner.text = if (alert.body.isEmpty()) alert.title else "${alert.title}\n${alert.body}"
        banner.contentDescription = "Message alert: ${alert.title}. Double tap to open."
        banner.visibility = View.VISIBLE
        banner.setOnClickListener {
            banner.visibility = View.GONE
            select(if (alert.app == DemoWebApp.RIVER) Tab.RIVER else Tab.ATLAS)
            alert.open()
        }
        banner.postDelayed({ banner.visibility = View.GONE }, 8000)
    }
}
