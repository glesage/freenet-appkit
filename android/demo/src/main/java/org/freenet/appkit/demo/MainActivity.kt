package org.freenet.appkit.demo

import android.app.Activity
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/** The app shell: River and Atlas tabs over the embedded node. */
class MainActivity : Activity() {
    enum class Tab(val label: String, val icon: Int) {
        RIVER("River", R.drawable.ic_tab_river),
        ATLAS("Atlas", R.drawable.ic_tab_atlas),
    }

    private lateinit var root: View
    private lateinit var content: FrameLayout
    private lateinit var banner: TextView
    private lateinit var tabBar: TabBar
    private lateinit var river: WebAppPage
    private lateinit var atlas: WebAppPage
    private var current: WebAppPage? = null
    /** Goes back in the page. Registered only while the page can go back. */
    private var backCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NodeHost.init(this)
        river = WebAppPage(this, DemoWebApp.RIVER)
        atlas = WebAppPage(this, DemoWebApp.ATLAS)
        river.onHistoryChanged = { updateBackCallback() }
        atlas.onHistoryChanged = { updateBackCallback() }
        actionBar?.hide()
        root = buildShell()
        setContentView(root)
        SystemBars.apply(this, root)
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

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        SystemBars.updateIconColours(this, root)
    }

    fun select(tab: Tab) {
        content.removeAllViews()
        val page = when (tab) {
            Tab.RIVER -> river
            Tab.ATLAS -> atlas
        }
        current = page
        page.show()
        (page.view.parent as? ViewGroup)?.removeView(page.view)
        content.addView(page.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        tabBar.select(tab)
        updateBackCallback()
    }

    // --- Back -----------------------------------------------------------
    // Back goes back inside the current page while it has history. With
    // nothing to go back to, the system's own back runs.

    private fun updateBackCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val wanted = current?.canGoBack() == true
        val registered = backCallback as OnBackInvokedCallback?
        if (wanted && registered == null) {
            val callback = OnBackInvokedCallback { current?.goBack() }
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
            backCallback = callback
        } else if (!wanted && registered != null) {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(registered)
            backCallback = null
        }
    }

    /** Android 12L and earlier. */
    @Deprecated("Android 13 and later use OnBackInvokedCallback")
    override fun onBackPressed() {
        val page = current
        if (page != null && page.canGoBack()) page.goBack() else super.onBackPressed()
    }

    // --- Layout ---------------------------------------------------------

    private fun buildShell(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(themeBackground())
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
        tabBar = TabBar(this, Tab.entries) { select(it) }
        root.addView(tabBar.view)
        return root
    }

    private fun themeBackground(): Int {
        val attrs = obtainStyledAttributes(intArrayOf(android.R.attr.colorBackground))
        val color = attrs.getColor(0, Color.WHITE)
        attrs.recycle()
        return color
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
