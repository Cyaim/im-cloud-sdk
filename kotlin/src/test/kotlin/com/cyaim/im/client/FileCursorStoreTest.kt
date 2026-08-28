package com.cyaim.im.client

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The only store an application will actually use, so the things that go wrong with files are
 * worth asserting rather than assuming.
 *
 * (This test may use `java.nio.file`; the SDK itself may not — `Path` and `Files` are API 26 on
 * Android and this artifact supports API 21. That is why [ImCursorStore.file] takes a
 * `java.io.File`.)
 */
class FileCursorStoreTest {

    private fun tempDir(): File = Files.createTempDirectory("im-cursor-test").toFile().also { it.deleteOnExit() }

    @Test
    fun `a snapshot survives a round trip`() {
        val file = File(tempDir(), "cursors.json")
        val store = ImCursorStore.file(file)
        val snapshot = ImCursorSnapshot(
            convSeqs = mapOf("c1" to 9_007_199_254_740_993L, "c2" to 0L),
            conversationCursor = 1_755_000_000_000L,
            scope = "im.example.com|app-1|alice",
        )

        store.save(snapshot)
        assertEquals(snapshot, ImCursorStore.file(file).load())
    }

    @Test
    fun `a missing file is a fresh install, not a failure`() {
        val store = ImCursorStore.file(File(tempDir(), "nested/deeper/cursors.json"))
        assertEquals(ImCursorSnapshot(), store.load())
    }

    @Test
    fun `the parent directory is created on first write`() {
        val file = File(tempDir(), "nested/deeper/cursors.json")
        ImCursorStore.file(file).save(ImCursorSnapshot(mapOf("c1" to 1L)))
        assertTrue(file.exists())
        assertEquals(1L, ImCursorStore.file(file).load().convSeqs["c1"])
    }

    /**
     * A half-written file parses as corrupt, the SDK correctly refuses to treat corrupt as a fresh
     * install, and the session is then stranded with no cursor advancement. Writing through a temp
     * file and renaming is what makes the file either the old snapshot or the new one.
     */
    @Test
    fun `a write leaves no temp file behind and never a partial one`() {
        val dir = tempDir()
        val file = File(dir, "cursors.json")
        val store = ImCursorStore.file(file)

        store.save(ImCursorSnapshot(mapOf("c1" to 1L)))
        store.save(ImCursorSnapshot(mapOf("c1" to 2L)))
        store.save(ImCursorSnapshot(mapOf("c1" to 3L)))

        assertEquals(listOf("cursors.json"), dir.list()!!.sorted())
        assertEquals(3L, store.load().convSeqs["c1"])
    }

    @Test
    fun `an empty file is a fresh install rather than a parse error`() {
        val file = File(tempDir(), "cursors.json")
        file.writeText("")
        assertEquals(ImCursorSnapshot(), ImCursorStore.file(file).load())
    }

    /**
     * Corrupt is **not** empty. It throws, the SDK surfaces it on `cursorStoreState` and freezes
     * every cursor, and the application decides — because the alternative, treating it as a fresh
     * install, silently destroys history that is sitting intact in the application's own database.
     */
    @Test
    fun `corrupt content throws rather than quietly reading as empty`() {
        val file = File(tempDir(), "cursors.json")
        file.writeText("""{"convSeqs":{"c1":""")
        assertFalse(runCatching { ImCursorStore.file(file).load() }.isSuccess)
    }

    @Test
    fun `the in-memory store keeps what it was given for the life of the process`() {
        val store = ImCursorStore.inMemory()
        store.save(ImCursorSnapshot(mapOf("c1" to 5L)))
        assertEquals(5L, store.load().convSeqs["c1"])
    }

    /**
     * Volatility is the SDK's judgement, not the store's claim.
     *
     * The interface used to carry an `isPersistent` flag with a `true` default, so any store could
     * override it to `false` — and the only thing that answer drives is the one warning standing
     * between a misconfigured client and a support ticket about missing history. Now the SDK
     * recognises its own in-memory store by type and nothing else can pretend to be it.
     */
    @Test
    fun `only the SDK's own in-memory store counts as volatile`() {
        assertTrue(ImCursorStore.inMemory() is InMemoryCursorStore)
        assertFalse(ImCursorStore.file(File(tempDir(), "cursors.json")) is InMemoryCursorStore)

        // A store an integrator wrote cannot declare itself volatile, because there is nothing on
        // the interface to declare it with: `load` and `save`, and that is the whole of it
        // (CONTRACT.md §5.3).
        val custom: ImCursorStore = object : ImCursorStore {
            override fun load(): ImCursorSnapshot = ImCursorSnapshot()
            override fun save(snapshot: ImCursorSnapshot) = Unit
        }
        assertFalse(custom is InMemoryCursorStore)
    }
}
