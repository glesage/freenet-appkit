package org.freenet.appkit.demo

import android.content.Context
import kotlinx.coroutines.delay
import org.freenet.appkit.NodeDirectories
import org.freenet.mobile.ClientErrorKind
import org.freenet.mobile.ContractListener
import org.freenet.mobile.ContractRef
import org.freenet.mobile.MobileException
import org.freenet.mobile.MobileNode
import org.freenet.mobile.NodeInfo
import org.freenet.mobile.NodeMode
import org.freenet.mobile.UpdateKind
import org.freenet.mobile.clientErrorKindName
import org.freenet.mobile.connectClient
import org.freenet.mobile.echoBytes
import org.freenet.mobile.fixtureContractWasm
import org.json.JSONArray
import org.json.JSONObject

/** A local-mode node with its own store, apart from the app's network store. */
object FixtureNode {
    suspend fun <T> run(context: Context, body: suspend (NodeInfo) -> T): T {
        val dirs = NodeDirectories.standard(context, "freenet-fixtures")
        val node = MobileNode(dirs.settings(NodeMode.LOCAL))
        val info = node.start()
        try {
            return body(info)
        } finally {
            try { node.stop() } catch (_: Exception) {}
            node.destroy()
        }
    }
}

/** Counts subscription callbacks and does nothing else on the callback thread. */
class CountingListener : ContractListener {
    private val updates = java.util.concurrent.atomic.AtomicInteger()
    private val bytes = java.util.concurrent.atomic.AtomicLong()

    override fun onUpdate(contract: ContractRef, kind: UpdateKind, bytes: ByteArray) {
        updates.incrementAndGet()
        this.bytes.addAndGet(bytes.size.toLong())
    }

    override fun onClosed(reason: String) {}

    val count get() = updates.get()
    val totalBytes get() = bytes.get()
}

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

/** Collects subscription callbacks in arrival order. */
class CallbackRecorder : ContractListener {
    private val events = mutableListOf<String>()

    override fun onUpdate(contract: ContractRef, kind: UpdateKind, bytes: ByteArray) {
        val name = when (kind) {
            UpdateKind.STATE -> "State"
            UpdateKind.DELTA -> "Delta"
            UpdateKind.STATE_AND_DELTA -> "StateAndDelta"
            UpdateKind.RELATED -> "Related"
        }
        synchronized(events) { events.add("$name:${bytes.hex()}") }
    }

    override fun onClosed(reason: String) {
        synchronized(events) { events.add("closed:$reason") }
    }

    val snapshot: List<String> get() = synchronized(events) { events.toList() }
}

/**
 * The custom Kotlin route: the same scripted operations as the Rust
 * fixtures, called through the Kotlin bindings, then compared with the
 * desktop values.
 */
object NativeRoute {
    data class Check(val name: String, val expected: String?, val actual: String) {
        val passed get() = expected == actual
        fun json() = JSONObject().put("name", name).put("expected", expected).put("actual", actual).put("passed", passed)
    }

    fun kindName(error: Exception): String = when (error) {
        is MobileException.Client -> clientErrorKindName(error.kind)
        is MobileException.Timeout -> "Timeout"
        else -> "error:${error.message}"
    }

    suspend fun run(context: Context, expected: Map<String, String>): List<Check> = FixtureNode.run(context) { info ->
        val client = connectClient(info.wsPort)
        val writer = connectClient(info.wsPort)
        val actual = sortedMapOf<String, String>()
        val wasm = fixtureContractWasm()

        val put = client.put(wasm, ByteArray(0), byteArrayOf(1, 2, 3), false, null)
        actual["op.put.instance_id"] = put.contract.instanceId
        actual["op.put.code_hash"] = put.contract.codeHash
        actual["op.get.state"] = client.get(put.contract.instanceId, false, false, null).state.hex()
        actual["op.update.summary"] = client.update(put.contract, byteArrayOf(4, 5), null).summary.hex()
        actual["op.get_after_update.state"] = client.get(put.contract.instanceId, false, false, null).state.hex()

        val recorder = CallbackRecorder()
        client.subscribe(put.contract.instanceId, recorder, null)
        for (delta in listOf<Byte>(6, 7, 8)) writer.update(put.contract, byteArrayOf(delta), null)
        val deadline = System.currentTimeMillis() + 10_000
        while (recorder.snapshot.size < 3 && System.currentTimeMillis() < deadline) delay(20)
        actual["op.subscribe.callbacks"] = recorder.snapshot.take(3).joinToString(",")

        actual["op.error.get_unknown"] = try {
            client.get(expected["key.instance_id"] ?: put.contract.instanceId, false, false, 10_000u); "ok"
        } catch (e: MobileException) { kindName(e) }
        actual["op.error.put_invalid_state"] = try {
            client.put(wasm, byteArrayOf(9), ByteArray(0), false, null); "ok"
        } catch (e: MobileException) { kindName(e) }
        actual["op.cancel.timed_out"] = try {
            client.put(wasm, byteArrayOf(7), byteArrayOf(0xF3.toByte()), false, 500u); "ok"
        } catch (e: MobileException) { kindName(e) }
        actual["op.cancel.read_after"] = client.get(put.contract.instanceId, false, false, null).state.hex()
        client.destroy()
        writer.destroy()
        actual.map { (name, value) -> Check(name, expected[name], value) }
    }

    /** Large-record copying through the bindings alone and through the node. */
    suspend fun largeRecords(context: Context, sizes: List<Int>): JSONArray = FixtureNode.run(context) { info ->
        val client = connectClient(info.wsPort)
        val wasm = fixtureContractWasm()
        val samples = JSONArray()
        sizes.forEachIndexed { index, size ->
            val bytes = ByteArray(size)
            for (i in 0 until size step 4096) bytes[i] = (i shr 12).toByte()
            bytes[0] = 1
            val echoStart = System.nanoTime()
            val echoed = echoBytes(bytes)
            val echoMs = (System.nanoTime() - echoStart) / 1e6
            val putStart = System.nanoTime()
            val put = client.put(wasm, byteArrayOf((index + 1).toByte()), bytes, false, 120_000u)
            val putMs = (System.nanoTime() - putStart) / 1e6
            val getStart = System.nanoTime()
            val got = client.get(put.contract.instanceId, false, false, 120_000u)
            val getMs = (System.nanoTime() - getStart) / 1e6
            samples.put(JSONObject()
                .put("bytes", size)
                .put("echoMs", echoMs)
                .put("putMs", putMs).put("putNodeMs", put.timing.nodeMs)
                .put("getMs", getMs).put("getNodeMs", got.timing.nodeMs)
                .put("intact", echoed.contentEquals(bytes) && got.state.contentEquals(bytes)))
        }
        client.destroy()
        samples
    }

    @Suppress("unused")
    private val kinds = ClientErrorKind.entries
}
