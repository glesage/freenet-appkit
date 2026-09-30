package org.freenet.appkit.demo

import android.content.Context
import android.content.res.ColorStateList
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The bottom tab bar: one icon and label per tab. The selected tab takes the
 * theme's accent colour, the others its secondary text colour.
 */
class TabBar(context: Context, private val tabs: List<MainActivity.Tab>, onSelect: (MainActivity.Tab) -> Unit) {
    private class Item(val root: LinearLayout, val icon: ImageView, val label: TextView)

    private val selectedColor = themeColor(context, android.R.attr.colorAccent)
    private val normalColor = themeColor(context, android.R.attr.textColorSecondary)
    private val items = mutableMapOf<MainActivity.Tab, Item>()

    val view = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(themeColor(context, android.R.attr.colorBackground))
    }

    init {
        view.addView(View(context).apply { setBackgroundColor(normalColor); alpha = 0.25f },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 1))
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        tabs.forEachIndexed { index, tab ->
            val icon = ImageView(context).apply {
                setImageResource(tab.icon)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            val label = TextView(context).apply {
                text = tab.label
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                gravity = Gravity.CENTER
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            val item = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                minimumHeight = dp(context, 56)
                setPadding(0, dp(context, 6), 0, dp(context, 6))
                isClickable = true
                isFocusable = true
                background = ripple(context)
                contentDescription = "${tab.label}, tab ${index + 1} of ${tabs.size}"
                setOnClickListener { onSelect(tab) }
                addView(icon, LinearLayout.LayoutParams(dp(context, 24), dp(context, 24)))
                addView(label)
            }
            items[tab] = Item(item, icon, label)
            row.addView(item, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        view.addView(row)
    }

    /** Show [tab] as the selected one. */
    fun select(tab: MainActivity.Tab) {
        items.forEach { (t, item) ->
            val color = if (t == tab) selectedColor else normalColor
            item.root.isSelected = t == tab
            item.icon.imageTintList = ColorStateList.valueOf(color)
            item.label.setTextColor(color)
        }
    }

    private companion object {
        fun dp(context: Context, value: Int) = (value * context.resources.displayMetrics.density).toInt()

        fun themeColor(context: Context, attr: Int): Int {
            val attrs = context.obtainStyledAttributes(intArrayOf(attr))
            val color = attrs.getColorStateList(0)?.defaultColor ?: android.graphics.Color.GRAY
            attrs.recycle()
            return color
        }

        fun ripple(context: Context) = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground)).let {
            val drawable = it.getDrawable(0)
            it.recycle()
            drawable
        }
    }
}
