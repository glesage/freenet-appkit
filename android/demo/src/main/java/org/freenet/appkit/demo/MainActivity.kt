package org.freenet.appkit.demo

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.AdapterView
import kotlin.system.exitProcess
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.freenet.mobile.buildInfo
import org.freenet.mobile.processMetrics
import org.freenet.mobile.processMetricsJson
import org.freenet.mobile.runBackendConformance
import org.freenet.mobile.verifyFixtures
import org.json.JSONObject

class MainActivity : Activity() {
    enum class Tab(val label: String) { RIVER("River"), ATLAS("Atlas"), BRIDGE("Bridge"), NATIVE("Native"), NODE("Node") }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var content: FrameLayout
    private lateinit var banner: TextView
    private val tabButtons = mutableMapOf<Tab, Button>()
    private lateinit var river: WebAppPage
    private lateinit var atlas: WebAppPage
    private lateinit var bridge: BridgePage
    private lateinit var nativeView: View
    private lateinit var nodeView: View
    private lateinit var nodeText: TextView
    private lateinit var nativeText: TextView
    private var harnessStarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Harness.appInitUptimeMs = SystemClock.uptimeMillis()
        NodeHost.init(this)
        applyLaunchExtras()
        river = WebAppPage(this, DemoWebApp.RIVER)
        atlas = WebAppPage(this, DemoWebApp.ATLAS)
        bridge = BridgePage(this)
        nativeView = buildNativeScreen()
        nodeView = buildNodeScreen()
        setContentView(buildShell())
        NodeHost.alertPresenter = { alert -> showAlert(alert) }
        NodeHost.onChange { refreshNodeText() }
        content.post {
            Harness.firstFrameUptimeMs = SystemClock.uptimeMillis()
            select(Tab.RIVER)
            startHarnessIfRequested()
        }
    }

    /** Harness settings arrive as intent extras and persist like the settings screen. */
    private fun applyLaunchExtras() {
        val extras = intent?.extras ?: return
        extras.getString("appkit.profile")?.let { NodeHost.profile = NetworkProfile.of(it) }
        extras.getString("appkit.gateway")?.let { NodeHost.gatewayText = it }
        extras.getString("appkit.alerts")?.let { NodeHost.alertGrant = AlertGrant.of(it) }
        extras.getString("appkit.backend")?.let { NodeHost.backend = it }
    }

    // The node runs only while the app is in the foreground.
    override fun onStart() {
        super.onStart()
        NodeHost.onForeground()
    }

    override fun onStop() {
        super.onStop()
        // Harness runs keep the node up unless the scenario measures the
        // lifecycle itself.
        val scenario = intent?.getStringExtra("appkit.scenario")
        if (!harnessStarted || scenario in Harness.lifecycleScenarios) NodeHost.onBackground()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun startHarnessIfRequested() {
        val scenario = intent?.getStringExtra("appkit.scenario") ?: return
        if (harnessStarted) return
        harnessStarted = true
        val exitWhenDone = intent?.getBooleanExtra("appkit.exitWhenDone", false) ?: false
        scope.launch {
            NodeHost.start()
            val names = if (scenario == "all") Harness.scenarios else scenario.split(',')
            for (name in names) {
                val result = Harness.run(this@MainActivity, name)
                Harness.write(applicationContext, name, result)
            }
            if (exitWhenDone) {
                NodeHost.stop()
                delay(300)
                finishAndRemoveTask()
                exitProcess(0)
            }
        }
    }

    fun bridgeReport(): JSONObject? = bridge.latestReport

    fun select(tab: Tab, autorun: Boolean = false) {
        content.removeAllViews()
        val view = when (tab) {
            Tab.RIVER -> river.view.also { river.show() }
            Tab.ATLAS -> atlas.view.also { atlas.show() }
            Tab.BRIDGE -> bridge.view.also { bridge.show(autorun) }
            Tab.NATIVE -> nativeView
            Tab.NODE -> nodeView.also { refreshNodeText() }
        }
        (view.parent as? ViewGroup)?.removeView(view)
        content.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        tabButtons.forEach { (t, button) -> button.alpha = if (t == tab) 1f else 0.55f }
    }

    // --- Layout ---------------------------------------------------------

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

    private fun column(): Pair<ScrollView, LinearLayout> {
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }
        return ScrollView(this).apply { addView(list) } to list
    }

    private fun monoText() = TextView(this).apply {
        typeface = Typeface.MONOSPACE
        textSize = 12f
        setTextIsSelectable(true)
    }

    private fun buildNativeScreen(): View {
        val (scroll, list) = column()
        list.addView(TextView(this).apply {
            text = "Kotlin calls the node directly through the SDK: put, get, update and subscribe on a local fixture node, compared with the desktop values."
        })
        nativeText = monoText()
        list.addView(Button(this).apply {
            text = "Run the native route"
            isAllCaps = false
            setOnClickListener {
                isEnabled = false
                nativeText.text = "Running…"
                scope.launch {
                    nativeText.text = try {
                        val checks = NativeRoute.run(applicationContext, Harness.expectedFixtureValues(applicationContext))
                        val samples = NativeRoute.largeRecords(applicationContext, listOf(16 shl 10, 1 shl 20, 8 shl 20))
                        checks.joinToString("\n") { "${if (it.passed) "✓" else "✗"} ${it.name}" } + "\n\n" +
                            (0 until samples.length()).joinToString("\n") {
                                val s = samples.getJSONObject(it)
                                "%,d B: bindings %.1f ms, put %.1f ms (node %.1f), get %.1f ms (node %.1f)".format(
                                    s.getInt("bytes"), s.getDouble("echoMs"), s.getDouble("putMs"), s.getDouble("putNodeMs"),
                                    s.getDouble("getMs"), s.getDouble("getNodeMs"))
                            }
                    } catch (e: Exception) {
                        "error: ${e.message}"
                    }
                    isEnabled = true
                }
            }
        })
        list.addView(nativeText)
        return scroll
    }

    private fun buildNodeScreen(): View {
        val (scroll, list) = column()
        nodeText = monoText()
        list.addView(nodeText)
        val profile = Spinner(this)
        val profiles = NetworkProfile.entries
        profile.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, profiles.map { it.label })
        profile.setSelection(profiles.indexOf(NodeHost.profile))
        profile.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>, view: View?, position: Int, id: Long) {
                val chosen = profiles[position]
                if (chosen != NodeHost.profile) scope.launch { NodeHost.apply(chosen) }
            }
            override fun onNothingSelected(parent: AdapterView<*>) {}
        }
        list.addView(TextView(this).apply { text = "Network" })
        list.addView(profile)
        val gateway = EditText(this).apply {
            hint = "Gateway: ip:port,public-key-hex"
            setText(NodeHost.gatewayText)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            typeface = Typeface.MONOSPACE
            textSize = 12f
        }
        list.addView(gateway)
        list.addView(Button(this).apply {
            text = "Save gateway"
            isAllCaps = false
            setOnClickListener { NodeHost.gatewayText = gateway.text.toString() }
        })
        list.addView(TextView(this).apply {
            text = "The node runs only while this app is open. It stops when the app moves to the background and starts a fresh session when the app returns. Message alerts appear only while the app is open."
            setPadding(0, 24, 0, 24)
        })
        val output = monoText()
        fun action(label: String, work: suspend () -> String) = Button(this).apply {
            text = label
            isAllCaps = false
            setOnClickListener {
                output.text = "Running…"
                scope.launch { output.text = try { work() } catch (e: Exception) { "error: ${e.message}" } }
            }
        }
        list.addView(action("Start the node") { NodeHost.start(); "started" })
        list.addView(action("Stop the node") { NodeHost.stop(); "stopped" })
        list.addView(action("Wasm backend conformance") {
            val report = runBackendConformance(AppResources.conformanceModules(applicationContext), false)
            (if (report.passed) "passed" else "failed") + "\n" + report.cases.joinToString("\n") {
                "${if (it.passed) "✓" else "✗"} ${it.backend} ${it.name} %.1f ms".format(it.elapsedMs)
            }
        })
        list.addView(action("Protocol fixtures") {
            val expected = AppResources.protocolFixtures(applicationContext)
            val report = FixtureNode.run(applicationContext) { verifyFixtures(expected, it.wsPort) }
            (if (report.passed) "passed" else "failed") + "\n" + report.checks.joinToString("\n") { "${if (it.passed) "✓" else "✗"} ${it.name}" }
        })
        list.addView(action("Process metrics") { processMetricsJson(processMetrics()) })
        list.addView(action("Ask about alerts again") { NodeHost.alertGrant = AlertGrant.NOT_ASKED; "alerts reset" })
        list.addView(output)
        return scroll
    }

    private fun refreshNodeText() {
        if (!::nodeText.isInitialized) return
        val info = NodeHost.info
        val status = NodeHost.status
        val build = buildInfo()
        nodeText.text = buildString {
            appendLine("State: ${status?.state?.name?.lowercase() ?: "not started"}")
            appendLine("Port: ${info?.wsPort ?: "–"}   Session: ${info?.session ?: "–"}   Peers: ${status?.connectedPeers ?: "–"}")
            appendLine("Wasm backend: ${info?.wasmBackend?.name?.lowercase() ?: build.defaultBackend.name.lowercase()}")
            appendLine("Profile: ${NodeHost.profile.label}   Alerts: ${NodeHost.alertGrant.key}")
            NodeHost.lastError?.let { appendLine("Error: $it") }
            appendLine("Core ${build.coreVersion} ${build.coreRevision.take(12)}, stdlib ${build.stdlibVersion}, wasmtime ${build.wasmtimeVersion}")
            appendLine("Target ${build.target}")
            appendLine()
            NodeHost.lifecycleLog.takeLast(12).reversed().forEach { appendLine(it) }
        }
    }
}
