package com.aeidolon.vaultexplorer.saf

import android.content.Context
import androidx.documentfile.provider.DocumentFile

class MirroredSafDocumentOps(
    private val context: Context,
    private val sync: MirrorSyncCoordinator,
) : VaultDocumentOps {
    private val mirrorOps = SafDocumentOps(context)
    val root: DocumentFile
        get() = DocumentFile.fromFile(java.io.File(sync.mirrorRoot, "root"))

    private fun requireRealUri(folder: DocumentFile): android.net.Uri {
        val path = folder.uri.path ?: throw SafIOException("Not a mirror file: ${folder.uri}")
        val file = java.io.File(path)
        return sync.realUriFor(file)
            ?: throw SafIOException("No real SAF mapping for mirrored path ${file.absolutePath}")
    }

    private fun realDocFor(folder: DocumentFile): DocumentFile {
        val uri = requireRealUri(folder)
        return DocumentFile.fromSingleUri(context, uri)
            ?: throw SafIOException("Real SAF document no longer resolvable: $uri")
    }

    override fun invalidate(folder: DocumentFile) {
        mirrorOps.invalidate(folder)
        try {
            val realDoc = realDocFor(folder)
            sync.invalidateListing(realDoc)
        } catch (_: Exception) {}
    }

    override fun invalidateAll() {
        mirrorOps.invalidateAll()
        sync.invalidateAll()
    }

    override fun invalidateContainingParent(doc: DocumentFile) {
        mirrorOps.invalidateContainingParent(doc)
        try {
            val realDoc = realDocFor(doc)
            sync.realOps.invalidateContainingParent(realDoc)
        } catch (_: Exception) {}
    }

    override fun listChildren(folder: DocumentFile): List<DocumentFile> {
        val path = folder.uri.path ?: throw SafIOException("Invalid folder URI path: ${folder.uri}")
        val mirrorFile = java.io.File(path)
        val realUri = sync.realUriFor(mirrorFile)
            ?: throw SafIOException("No real SAF mapping for mirrored path ${mirrorFile.absolutePath}")
        if (!sync.hasListed(realUri)) {
            val realFolder = DocumentFile.fromSingleUri(context, realUri)
                ?: throw SafIOException("Real SAF document no longer resolvable: $realUri")
            sync.pullListingIfMissing(realFolder, mirrorFile)
            mirrorOps.invalidate(folder)
        }
        return mirrorOps.listChildren(folder)
    }

    override fun childOf(folder: DocumentFile, name: String): DocumentFile? {
        val path = folder.uri.path ?: throw SafIOException("Invalid folder URI path: ${folder.uri}")
        val mirrorFile = java.io.File(path)
        val realUri = sync.realUriFor(mirrorFile)
            ?: throw SafIOException("No real SAF mapping for mirrored path ${mirrorFile.absolutePath}")
        if (!sync.hasListed(realUri)) {
            val realFolder = DocumentFile.fromSingleUri(context, realUri)
                ?: throw SafIOException("Real SAF document no longer resolvable: $realUri")
            sync.pullListingIfMissing(realFolder, mirrorFile)
            mirrorOps.invalidate(folder)
        }
        return mirrorOps.childOf(folder, name)
    }

    override fun createDirectorySafe(parent: DocumentFile, name: String): DocumentFile? {
        val realParent = realDocFor(parent)
        val realCreated = sync.pushCreateDirectory(realParent, name)
        val mirrored = mirrorOps.createDirectorySafe(parent, name) ?: run {
            runCatching { sync.pushDelete(realCreated) }
            return null
        }
        val path = mirrored.uri.path ?: throw SafIOException("Invalid mirrored directory path: ${mirrored.uri}")
        sync.registerExisting(realCreated, java.io.File(path))
        sync.markFreshlyCreated(realCreated)
        sync.markListedEmpty(realCreated)
        return mirrored
    }

    override fun createFileSafe(parent: DocumentFile, mimeType: String, name: String): DocumentFile? {
        val mirrored = mirrorOps.createFileSafe(parent, mimeType, name) ?: return null
        val path = mirrored.uri.path ?: throw SafIOException("Invalid mirrored file path: ${mirrored.uri}")
        val mirrorFile = java.io.File(path)
        try {
            val realParent = realDocFor(parent)
            sync.pushFileWrite(mirrorFile, realParent, existingRealDoc = null, displayName = mirrored.name ?: name, mimeType = mimeType)
        } catch (e: MirrorPushException) {
            runCatching { mirrorFile.delete() }
            mirrorOps.invalidate(parent)
            throw e
        }
        return mirrored
    }

    override fun readWhole(file: DocumentFile): ByteArray {
        ensureContentPulled(file)
        return mirrorOps.readWhole(file)
    }

    override fun writeWhole(file: DocumentFile, bytes: ByteArray) {
        mirrorOps.writeWhole(file, bytes)
        pushContentWrite(file)
    }

    override fun ensureContentPulled(file: DocumentFile) {
        val realFile = realDocFor(file)
        if (!sync.hasContent(realFile)) sync.pullFileIfMissing(realFile)
    }

    override fun resolveForRead(
        file: DocumentFile,
        onBackgroundPullPhase: ((MirrorPullEvents.Phase) -> Unit)?,
    ): DocumentFile? {
        val realFile = try { realDocFor(file) } catch (_: SafIOException) { return null }
        val ready = sync.ensureReadyOrStreamDirect(realFile, onBackgroundPullPhase)
        // ready == true  → mirror is populated, caller should use the mirror file (return null → fallback to ensureContentPulled which is a no-op now)
        // ready == false → large cold file, background pull kicked off; return the REAL doc so ChunkedFileEngine streams from it directly
        return if (ready) null else realFile
    }

    override fun pushContentWrite(file: DocumentFile) {
        val path = file.uri.path ?: throw SafIOException("Invalid file URI path: ${file.uri}")
        val mirrorFile = java.io.File(path)
        val realFile = try { realDocFor(file) } catch (e: SafIOException) { null }
        val realParent = if (realFile == null) {
            file.parentFile?.let { try { realDocFor(it) } catch (_: Exception) { null } }
        } else null
        sync.pushFileWrite(
            mirrorFile,
            realParent = realParent,
            existingRealDoc = realFile,
            displayName = file.name ?: mirrorFile.name,
            mimeType = "application/octet-stream",
        )
    }

    override fun deferContentWrite(file: DocumentFile) {
        val path = file.uri.path ?: throw SafIOException("Invalid file URI path: ${file.uri}")
        sync.deferPush(java.io.File(path)) { pushContentWrite(file) }
    }

    override fun markWritePending(file: DocumentFile) {
        val path = file.uri.path ?: return
        sync.markPendingLocalWrite(java.io.File(path))
    }

    override fun renameDocumentAndGet(doc: DocumentFile, newName: String, parent: DocumentFile?): DocumentFile {
        val realDoc = realDocFor(doc)
        val realParent = parent?.let { realDocFor(it) }
        // A scratch file whose content push was deferred (deferContentWrite):
        // its real document is still the empty placeholder, so renaming it
        // now is safe -- nothing is uploading into it. The content is pushed
        // AFTER the rename, into the renamed document. Renaming a real
        // document that already has an upload in flight (Filen) leaves the
        // upload landing under the old name: a 0-byte final file plus a
        // stray ".tmp" holding the real content.
        val oldMirror = doc.uri.path?.let { java.io.File(it) }
        val deferredPush = oldMirror != null && sync.cancelDeferredPush(oldMirror)
        val realRenamed: DocumentFile
        val mirrorRenamed: DocumentFile
        try {
            realRenamed = sync.pushRename(realDoc, newName, realParent)
            mirrorRenamed = mirrorOps.renameDocumentAndGet(doc, newName, parent)
        } catch (e: Exception) {
            // Rename failed: hand the content back to the deferred timer.
            if (deferredPush) runCatching { deferContentWrite(doc) }
            throw e
        }
        val path = mirrorRenamed.uri.path ?: throw SafIOException("Invalid renamed URI path: ${mirrorRenamed.uri}")
        val newMirror = java.io.File(path)
        sync.registerExisting(realRenamed, newMirror)
        if (deferredPush) {
            sync.markPendingLocalWrite(newMirror)
            sync.pushFileWrite(
                newMirror,
                realParent = null,
                existingRealDoc = realRenamed,
                displayName = newName,
                mimeType = "application/octet-stream",
            )
        }
        return mirrorRenamed
    }

    override fun renameDocument(doc: DocumentFile, newName: String, parent: DocumentFile?) {
        renameDocumentAndGet(doc, newName, parent)
    }

    override fun movePhysicalDocument(doc: DocumentFile, oldParent: DocumentFile, newParent: DocumentFile) {
        val realDoc = realDocFor(doc)
        val realOld = realDocFor(oldParent)
        val realNew = realDocFor(newParent)
        sync.pushMove(realDoc, realOld, realNew)
        mirrorOps.movePhysicalDocument(doc, oldParent, newParent)
    }

    override fun copyDocumentRecursive(source: DocumentFile, targetParent: DocumentFile): DocumentFile {
        val name = source.name ?: throw SafIOException("Source document has no name")
        return if (source.isDirectory) {
            val newDir = createDirectorySafe(targetParent, name) ?: throw SafIOException("Could not create $name in target")
            for (child in listChildren(source)) copyDocumentRecursive(child, newDir)
            newDir
        } else {
            val newFile = createFileSafe(targetParent, "application/octet-stream", name)
                ?: throw SafIOException("Could not create $name in target")
            writeWhole(newFile, readWhole(source))
            newFile
        }
    }

    override fun deleteRecursively(folder: DocumentFile) {
        val realFolder = try { realDocFor(folder) } catch (_: Exception) { null }
        folder.uri.path?.let { sync.cancelDeferredPush(java.io.File(it)) }
        // 1. Delete the local mirror file immediately so local listings update instantly
        mirrorOps.deleteRecursively(folder)
        
        // 2. Delete the remote file on real SAF
        if (realFolder != null) {
            sync.pushDelete(realFolder)
        }
    }
}