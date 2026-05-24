// Card list filter — search-input + dropdown-filter card grid component.
// Used by players/index.html.erb and teams/index.html.erb.
//
// Previously the same x-data shape lived inline in both views and ran the
// filter logic inside a `get filtered()` getter that side-effected
// `card.style.display`. Alpine getters are supposed to be pure; the
// side-effect re-fired on every reactivity tick and made the getter
// re-render its template-text consumer (`x-text="filtered + ' players'"`)
// into a feedback loop. This factory replaces the getter with a real
// method (apply()) plus $watch wiring on search + each filter key.
//
// opts:
//   selector:    required CSS selector for the cards to filter
//                (e.g. '[data-player-card]')
//   searchAttr:  data-* attribute holding the searchable text
//                (default 'data-name' → reads card.dataset.name)
//   filters:     map of dataset-key → current value. 'all' bypasses
//                that filter; any other value must match
//                card.dataset[key] exactly. Defaults to {}.

function cardListFilter(opts) {
  opts = opts || {};
  var dsKey = (opts.searchAttr || "data-name")
    .replace(/^data-/, "")
    .replace(/-([a-z])/g, function (_, c) { return c.toUpperCase(); });

  return {
    search: "",
    visibleCount: 0,
    filters: opts.filters || {},
    _selector: opts.selector,
    _dsKey: dsKey,

    init() {
      var self = this;
      this.apply();
      this.$watch("search", function () { self.apply(); });
      Object.keys(this.filters).forEach(function (k) {
        self.$watch("filters." + k, function () { self.apply(); });
      });
    },

    apply() {
      if (!this._selector) return;
      var q = this.search.toLowerCase().trim();
      var filters = this.filters;
      var cards = document.querySelectorAll(this._selector);
      var dsKey = this._dsKey;
      var count = 0;
      cards.forEach(function (card) {
        var searchVal = (card.dataset[dsKey] || "").toLowerCase();
        var matchSearch = !q || searchVal.includes(q);
        var matchFilters = Object.keys(filters).every(function (k) {
          var v = filters[k];
          return v === "all" || card.dataset[k] === v;
        });
        var visible = matchSearch && matchFilters;
        card.style.display = visible ? "" : "none";
        if (visible) count++;
      });
      this.visibleCount = count;
    }
  };
}

window.cardListFilter = cardListFilter;
function registerCardListFilter() {
  if (typeof Alpine === "undefined") return false;
  Alpine.data("cardListFilter", cardListFilter);
  return true;
}
if (!registerCardListFilter()) {
  document.addEventListener("alpine:init", registerCardListFilter);
}
