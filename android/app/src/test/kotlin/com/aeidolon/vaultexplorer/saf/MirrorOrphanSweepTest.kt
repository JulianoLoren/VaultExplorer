package com.aeidolon.vaultexplorer.saf

import android.content.Context
import androidx.documentfile.provider.DocumentFile
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * [MirrorSyncCoordinator.sweepOrphanedMirrors]: a mirror folder is only
 * deleted by `teardown()`, so one left behind by a killed/crashed process
 * must be removed on a later startup -- without ever touching the mirror of
 * a session that is alive in the current process.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class MirrorOrphanSweepTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val mirrorsDir: File get() = File(context.filesDir, "vault_mirrors")

    private fun makeOrphan(tag: String): File =
        File(mirrorsDir, tag).apply {
            File(this, "root/sub").mkdirs()
            File(this, "root/sub/file.bin").writeBytes(ByteArray(1024) { 1 })
        }

    @Test
    fun `sweep returns 0 when the mirrors folder does not exist`() {
        mirrorsDir.deleteRecursively()
        assertEquals(0, MirrorSyncCoordinator.sweepOrphanedMirrors(context))
    }

    @Test
    fun `sweep removes orphaned mirror folders`() {
        val a = makeOrphan("orphan-a-${System.nanoTime()}")
        val b = makeOrphan("orphan-b-${System.nanoTime()}")

        val removed = MirrorSyncCoordinator.sweepOrphanedMirrors(context)

        assertTrue("expected at least the two orphans removed, got $removed", removed >= 2)
        assertFalse(a.exists())
        assertFalse(b.exists())
    }

    @Test
    fun `sweep leaves a live session's mirror alone and removes it after teardown`() {
        val realRoot = File(context.filesDir, "sweep_real_root_${System.nanoTime()}").apply { mkdirs() }
        val sync = MirrorSyncCoordinator(
            context,
            sessionTag = "live-session-${System.nanoTime()}",
            realOps = SafDocumentOps(context),
        )
        sync.reset(DocumentFile.fromFile(realRoot))
        val orphan = makeOrphan("orphan-c-${System.nanoTime()}")

        try {
            MirrorSyncCoordinator.sweepOrphanedMirrors(context)

            assertFalse("orphan should be gone", orphan.exists())
            assertTrue("live session's mirror must survive the sweep", sync.mirrorRoot.exists())
            assertTrue(File(sync.mirrorRoot, "root").exists())
        } finally {
            sync.teardown()
            realRoot.deleteRecursively()
        }

        assertFalse("teardown deletes the mirror", sync.mirrorRoot.exists())
    }

    @Test
    fun `a folder whose teardown delete failed becomes sweepable afterwards`() {
        val realRoot = File(context.filesDir, "sweep_real_root_${System.nanoTime()}").apply { mkdirs() }
        val sync = MirrorSyncCoordinator(
            context,
            sessionTag = "torn-down-${System.nanoTime()}",
            realOps = SafDocumentOps(context),
        )
        sync.reset(DocumentFile.fromFile(realRoot))
        sync.teardown()
        // Simulate a leftover (e.g. a failed delete) under the now-inactive tag.
        sync.mirrorRoot.mkdirs()

        MirrorSyncCoordinator.sweepOrphanedMirrors(context)

        assertFalse(sync.mirrorRoot.exists())
        realRoot.deleteRecursively()
    }
}
