// Crop Photo modal factory.
//
// Two modes, distinguished by whether the caller passes an imageUrl prop:
//   * fromParent — caller (e.g. components/avatar_cropper) has already
//     picked a file and passes the data URL via props.imageUrl. The
//     modal jumps to the cropper and emits 'crop-photo-confirmed' with
//     the cropped Blob; the parent owns the upload.
//   * standalone — caller opens the modal with no props (e.g.
//     account-page avatar). The modal handles file pick + crop + POST
//     to saveUrl, then reloads.
//
// opts:
//   saveUrl: required for standalone mode (e.g. save_profile_account_path)

function cropPhotoModal(opts) {
  opts = opts || {};
  return {
    cropper: null,
    imageUrl: null,
    fromParent: false,
    dragging: false,
    uploading: false,
    error: null,
    _saveUrl: opts.saveUrl,
    // Configurable crop output. Defaults = avatar (square 256px, transparent).
    // Callers override per-use via the modal props, e.g.
    //   Alpine.store('modals').open('crop-photo',
    //     { imageUrl, aspectRatio: 3, maxWidth: 900, maxHeight: 300, transparent: true })
    aspectRatio: 1,
    maxWidth: 256,
    maxHeight: 256,
    transparent: true,
    autoCropArea: 0.9,
    // dispatch: emit the cropped Blob via 'crop-photo-confirmed' instead of
    // POSTing it (uploadDirect). For callers whose own host owns the upload even
    // though the MODAL picked the file (e.g. the contest banner editor).
    dispatch: false,

    init() {
      var current = this.$store.modals.current();
      var props = (current && current.props) || {};
      if (props.aspectRatio) this.aspectRatio = props.aspectRatio;
      if (props.maxWidth) this.maxWidth = props.maxWidth;
      if (props.maxHeight) this.maxHeight = props.maxHeight;
      if (typeof props.transparent === "boolean") this.transparent = props.transparent;
      if (props.dispatch) this.dispatch = true;
      if (props.autoCropArea) this.autoCropArea = props.autoCropArea;
      if (props.imageUrl) {
        this.fromParent = true;
        this.imageUrl = props.imageUrl;
        this.mountCropper();
      }
    },

    destroy() {
      if (this.cropper) { this.cropper.destroy(); this.cropper = null; }
    },

    mountCropper() {
      var self = this;
      this.$nextTick(function () {
        if (typeof Cropper === "undefined") return;
        if (self.cropper) { self.cropper.destroy(); self.cropper = null; }
        self.cropper = new Cropper(self.$refs.cropImage, {
          aspectRatio: self.aspectRatio, viewMode: 1, dragMode: "move",
          autoCropArea: self.autoCropArea, cropBoxResizable: true,
          cropBoxMovable: true, background: false, guides: true
        });
        // Cropping in progress — lock the modal (no click-outside / escape) so an
        // accidental click doesn't discard the crop. Cancel still works.
        var cur = self.$store.modals.current();
        if (cur && cur.props) cur.props.dismissible = false;
      });
    },

    readFile(file) {
      if (!file) return;
      if (!file.type || file.type.indexOf("image/") !== 0) {
        this.error = "Please choose an image file.";
        return;
      }
      var self = this;
      var reader = new FileReader();
      reader.onload = function (e) {
        self.error = null;
        self.imageUrl = e.target.result;
        self.mountCropper();
      };
      reader.readAsDataURL(file);
    },

    onFilePicked(event) {
      var file = event.target.files[0];
      event.target.value = "";
      this.readFile(file);
    },

    onDrop(event) {
      this.dragging = false;
      var file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0];
      this.readFile(file);
    },

    cancel() {
      if (this.cropper) { this.cropper.destroy(); this.cropper = null; }
      this.$store.modals.close();
    },

    confirm() {
      if (!this.cropper || this.uploading) return;
      var self = this;
      // Cap WIDTH only. For a fixed-aspect crop the aspect already bounds the
      // height (= width / aspectRatio); also passing maxHeight makes cropper.js
      // downscale the whole SOURCE to fit maxHeight when the source is taller
      // (a 1983x793 upload -> 500/793 ~= 0.63x), tanking fidelity. maxWidth alone
      // keeps the crop at source resolution up to the cap.
      var canvasOpts = { maxWidth: this.maxWidth, imageSmoothingQuality: "high" };
      if (!this.transparent) canvasOpts.fillColor = "#ffffff";
      var canvas = this.cropper.getCroppedCanvas(canvasOpts);
      canvas.toBlob(function (blob) {
        if (self.fromParent || self.dispatch) {
          try {
            window.dispatchEvent(new CustomEvent("crop-photo-confirmed", { detail: { blob: blob } }));
          } catch (_) {}
          if (self.cropper) { self.cropper.destroy(); self.cropper = null; }
          // dispatch mode: the caller's host owns the post-confirm flow
          // (processing modal -> success toast), so don't pop the stack here.
          if (!self.dispatch) self.$store.modals.close();
        } else {
          self.uploadDirect(blob);
        }
      }, "image/png");
    },

    async uploadDirect(blob) {
      this.uploading = true;
      this.error = null;
      var csrf = document.querySelector("meta[name='csrf-token']")?.content || "";
      var form = new FormData();
      form.append("user[avatar]", new File([blob], "avatar.png", { type: "image/png" }));
      try {
        // authedFetch surfaces 401 with the login modal; standard fallback
        // if it isn't loaded yet (very early page load, vanishingly rare).
        var fetcher = window.authedFetch || fetch;
        var resp = await fetcher(this._saveUrl, {
          method: "POST",
          headers: { "X-CSRF-Token": csrf, "Accept": "application/json" },
          body: form
        });
        if (!resp) { this.uploading = false; return; } // 401 short-circuit
        var data = await resp.json();
        if (resp.ok && data.success) {
          if (this.cropper) { this.cropper.destroy(); this.cropper = null; }
          this.$store.modals.close();
          window.location.reload();
        } else {
          this.error = (data && data.error) || "Failed to save photo";
          this.uploading = false;
        }
      } catch (e) {
        this.error = e.message || "Network error";
        this.uploading = false;
      }
    }
  };
}

window.cropPhotoModal = cropPhotoModal;
function registerCropPhotoModal() {
  if (typeof Alpine === "undefined") return false;
  Alpine.data("cropPhotoModal", cropPhotoModal);
  return true;
}
if (!registerCropPhotoModal()) {
  document.addEventListener("alpine:init", registerCropPhotoModal);
}
