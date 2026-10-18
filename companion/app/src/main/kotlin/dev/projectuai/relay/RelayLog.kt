package dev.projectuai.relay

import java.time.LocalTime
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A small in-memory log tail for the Diagnostics screen. Never persisted. */
class RelayLog(private val capacity: Int = 200) {
    private val entries = ArrayDeque<String>()
    private val lock = Any()
    private val _lines = MutableStateFlow<List<String>>(emptyList())
    val lines: StateFlow<List<String>> = _lines.asStateFlow()

    fun add(message: String) {
        val stamp = LocalTime.now().withNano(0).toString()
        synchronized(lock) {
            entries.addLast("$stamp  $message")
            while (entries.size > capacity) entries.removeFirst()
            _lines.value = entries.toList()
        }
    }

    fun tail(): List<String> = synchronized(lock) { entries.toList() }
}
