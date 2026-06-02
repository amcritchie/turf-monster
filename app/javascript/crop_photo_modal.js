// Crop Photo modal factory.
//
// The modal hands the cropped Blob back to its opener via the
// 'crop-photo-confirmed' window event — the opener's host owns the upload.
// The image gets IN two ways:
//   * imageUrl prop — the opener already picked a file and passes the data
//     URL (avatar uploader / avatar_cropper); the modal jumps to the cropper.
//   * no imageUrl — the modal itself is the picker (click/drag-drop empty
//     state), then crops (contest banner editor's open()).
//
// opts (all optional): aspectRatio, maxWidth, maxHeight, transparent,
//   autoCropArea, dispatch (when true, stay open after confirm so the
//   opener's host can run its processing -> success flow).

function cropPhotoModal(opts) {
  opts = opts || {};
  return {
    cropper: null,
    imageUrl: null,
    fromParent: false,
    dragging: false,
    error: null,
    // Configurable crop output. Defaults = avatar (square 256px, transparent).
    // Callers override per-use via the modal props, e.g.
    //   Alpine.store('modals').open('crop-photo',
    //     { imageUrl, aspectRatio: 3, maxWidth: 900, maxHeight: 300, transparent: true })
    aspectRatio: 1,
    maxWidth: 256,
    maxHeight: 256,
    transparent: true,
    autoCropArea: 0.9,
    // dispatch: keep the modal open after confirm so the opener's host can run
    // its own processing -> success flow (it replaces the modal). When false
    // (fromParent, e.g. avatar_cropper) the modal closes itself after confirm.
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
      if (!this.cropper) return;
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
        try {
          window.dispatchEvent(new CustomEvent("crop-photo-confirmed", { detail: { blob: blob } }));
        } catch (_) {}
        if (self.cropper) { self.cropper.destroy(); self.cropper = null; }
        // dispatch mode: the opener's host owns the post-confirm flow
        // (processing modal -> success toast), so don't pop the stack here.
        // fromParent (no dispatch): close the modal now.
        if (!self.dispatch) self.$store.modals.close();
      }, "image/png");
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
