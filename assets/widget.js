export default {
  mounted() {
    this.el.addEventListener("click", async (e) => {
      // Chat composer: the paperclip opens the hidden file picker.
      if (e.target.closest("[data-attach-chat]")) {
        const inp = this.el.querySelector("[data-chat-file]")
        if (inp) inp.click()
        return
      }
      if (!e.target.closest("[data-capture-screenshot]")) return
      this.pushEvent("capture_start", {})
      try {
        const { toBlob } = await import("html-to-image")
        const blob = await toBlob(document.body, { cacheBust: true, pixelRatio: 1 })
        if (!blob) return this.pushEvent("screenshot_failed", {})
        // Hold the bytes locally; ask the server for a presigned URL.
        this.pendingBlob = blob
        this.pushEvent("request_screenshot_upload", { content_type: blob.type || "image/png" })
      } catch (err) {
        console.error("Screenshot capture failed:", err)
        this.pushEvent("screenshot_failed", {})
      }
    })

    // A chat file was picked (delegated — the input renders only when open).
    this.el.addEventListener("change", (e) => {
      const inp = e.target.closest("[data-chat-file]")
      if (!inp || !inp.files || !inp.files[0]) return
      const file = inp.files[0]
      this.pendingFile = file
      this.pushEvent("request_chat_upload", {
        content_type: file.type || "application/octet-stream",
        filename: file.name,
      })
      inp.value = ""
    })

    // Server handed back a presigned URL — PUT the bytes straight to S3.
    this.handleEvent("screenshot_upload_url", async ({ url, s3_key, content_type }) => {
      if (!this.pendingBlob) return
      try {
        const res = await fetch(url, {
          method: "PUT",
          body: this.pendingBlob,
          headers: { "content-type": content_type },
        })
        if (!res.ok) throw new Error("upload failed: " + res.status)
        this.pushEvent("screenshot_uploaded", { s3_key: s3_key, content_type: content_type })
      } catch (err) {
        console.error("Screenshot upload failed:", err)
        this.pushEvent("screenshot_failed", {})
      } finally {
        this.pendingBlob = null
      }
    })

    this.handleEvent("chat_upload_url", async ({ url, s3_key, content_type }) => {
      if (!this.pendingFile) return
      const file = this.pendingFile
      try {
        const res = await fetch(url, {
          method: "PUT",
          body: file,
          headers: { "content-type": content_type },
        })
        if (!res.ok) throw new Error("upload failed: " + res.status)
        this.pushEvent("chat_uploaded", {
          s3_key: s3_key,
          filename: file.name,
          content_type: file.type || content_type,
          size: file.size,
        })
      } catch (err) {
        console.error("Chat upload failed:", err)
        this.pushEvent("chat_upload_failed", {})
      } finally {
        this.pendingFile = null
      }
    })
  },
}

export const CmsChatScroll = {
  mounted() {
    this.scroll()
    this.observer = new MutationObserver(() => this.scroll())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  destroyed() { this.observer && this.observer.disconnect() },
  scroll() { this.el.scrollTop = this.el.scrollHeight },
}
