// Image dropzone — click-or-drag file picker with live preview thumbnail.
// Used in /contests/new and /contests/edit. Expects an <input type="file">
// inside the same x-data scope with x-ref="fileInput" and @change="pickFile($event)".
//
// opts:
//   - fileName: server-rendered initial filename (edit form)
//   - previewUrl: server-rendered initial preview URL (edit form)

function imageDropzone(opts) {
  opts = opts || {};
  return {
    fileName: opts.fileName || '',
    previewUrl: opts.previewUrl || '',
    dragging: false,
    _ownsPreviewUrl: false, // only revoke URLs we created (don't revoke server URLs)

    pickFile: function(e) {
      var file = e.target.files[0];
      if (file) this.setFile(file);
    },

    dropFile: function(e) {
      this.dragging = false;
      var file = e.dataTransfer.files[0];
      if (!file || !file.type.startsWith('image/')) return;
      var input = this.$refs.fileInput;
      var dt = new DataTransfer();
      dt.items.add(file);
      input.files = dt.files;
      this.setFile(file);
    },

    setFile: function(file) {
      this.fileName = file.name;
      if (this._ownsPreviewUrl && this.previewUrl) URL.revokeObjectURL(this.previewUrl);
      this.previewUrl = URL.createObjectURL(file);
      this._ownsPreviewUrl = true;
    },

    clear: function() {
      if (this._ownsPreviewUrl && this.previewUrl) URL.revokeObjectURL(this.previewUrl);
      this.fileName = '';
      this.previewUrl = '';
      this._ownsPreviewUrl = false;
      this.$refs.fileInput.value = '';
    }
  };
}

window.imageDropzone = imageDropzone;
function registerImageDropzone() {
  if (typeof Alpine === 'undefined') return false;
  Alpine.data('imageDropzone', imageDropzone);
  return true;
}
if (!registerImageDropzone()) {
  document.addEventListener('alpine:init', registerImageDropzone);
}
