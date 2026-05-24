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

    init() {
      var current = this.$store.modals.current();
      var props = (current && current.props) || {};
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
          aspectRatio: 1, viewMode: 1, dragMode: "move",
          autoCropArea: 0.9, cropBoxResizable: true,
          cropBoxMovable: true, background: false, guides: true
        });
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
      var canvas = this.cropper.getCroppedCanvas({ width: 256, height: 256 });
      canvas.toBlob(function (blob) {
        if (self.fromParent) {
          try {
            window.dispatchEvent(new CustomEvent("crop-photo-confirmed", { detail: { blob: blob } }));
          } catch (_) {}
          if (self.cropper) { self.cropper.destroy(); self.cropper = null; }
          self.$store.modals.close();
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
