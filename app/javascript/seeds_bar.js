// Seeds bar — navbar (compact) + card (full) animation factory.
//
// Two variants render from components/_seeds_bar.html.erb depending on
// the `compact` local; both share the same x-data factory. Listens for
// two window events declared on the root element:
//
//   @navbar-replay-level.window  → replay() — manual dev replay
//   @navbar-seeds-update.window  → handleSeedsUpdate($event.detail)
//
// And reads two localStorage keys (cross-page handoff so the level-up
// celebration can fire on the NEXT page after the action that earned it):
//
//   seedsLevelUp  → consumed once in init() to run the full level-up
//                   sequence (oldLevel, oldToward, newLevel)
//   seedsNavbar   → ambient state ({ level, toward_next, progress })
//                   read for the "fill from 0" animation
//
// Initial values come from the root element's data attrs (NOT factory
// args). This is the canonical Alpine.data() pattern — `x-data="seedsBar"`
// resolves through Alpine's registered-data scope, which is reliable
// across importmap-load timing. The previous `x-data="seedsBar({...})"`
// shape relied on `window.seedsBar` existing at x-data parse time, which
// fails because importmap modules load AFTER Alpine processes x-data.
//
// data attrs read on init:
//   data-initial-toward — toward_next (0–100), default 0
//   data-initial-level  — level (1+), default 1

function seedsBar() {
  return {
    displaySeeds: 0,
    displayLevel: 1,
    levelingUp: false,
    finalToward: 0,
    _timers: [],

    init() {
      var initialToward = parseInt(this.$root.dataset.initialToward, 10) || 0;
      var initialLevel = parseInt(this.$root.dataset.initialLevel, 10) || 1;
      this.displaySeeds = initialToward;
      this.displayLevel = initialLevel;
      this.finalToward = initialToward;

      var self = this;
      var raw = localStorage.getItem("seedsLevelUp");
      if (raw) {
        localStorage.removeItem("seedsLevelUp");
        try { self.runLevelUpSequence(JSON.parse(raw)); return; } catch (_) {}
      }
      self.normalStart();
    },

    destroy() {
      this._timers.forEach(clearTimeout);
      this._timers = [];
    },

    _schedule(fn, ms) {
      this._timers.push(setTimeout(fn, ms));
    },

    normalStart() {
      var data = this.readNavData();
      if (data) {
        this.displayLevel = data.level;
        this.finalToward = data.toward_next;
      }
      // Animate from 0 to the final value so the bar "fills in" on page load.
      this.displaySeeds = 0;
      var self = this;
      this._schedule(function () { self.displaySeeds = self.finalToward; }, 150);
    },

    readNavData() {
      try {
        var raw = localStorage.getItem("seedsNavbar");
        if (!raw) return null;
        return JSON.parse(raw);
      } catch (_) { return null; }
    },

    // Shared 4-phase animation driving displaySeeds + displayLevel.
    //   Phase 1 @ 300ms:  fill to 100 (kicks the CSS --bar-progress transition)
    //   Phase 2 @ 1500ms: bump level number + spawn confetti (card variant only)
    //   Phase 3 @ 2800ms: drain to 0
    //   Phase 4 @ 3000ms: refill to leftover progress in the new level
    // Callers manage their own levelingUp flag timing — replay() toggles it
    // mid-sequence so the bounce CSS animation fires when the level number
    // actually changes.
    playLevelUpFill(o) {
      var self = this;
      self.displaySeeds = o.oldPct || 0;
      self._schedule(function () { self.displaySeeds = 100; }, 300);
      self._schedule(function () {
        if (o.newLevel !== undefined && o.newLevel !== null) self.displayLevel = o.newLevel;
        if (o.fireConfetti) self.spawnFirework();
      }, 1500);
      self._schedule(function () { self.displaySeeds = 0; }, 2800);
      self._schedule(function () { self.displaySeeds = o.finalProgress; }, 3000);
    },

    runLevelUpSequence(lu) {
      var self = this;
      self.levelingUp = true;
      self.displayLevel = lu.oldLevel;
      var data = self.readNavData();
      self.playLevelUpFill({
        oldPct: lu.oldToward,
        newLevel: lu.newLevel,
        finalProgress: data ? data.toward_next : 0,
        fireConfetti: true
      });
      self._schedule(function () { self.levelingUp = false; }, 3000);
    },

    spawnFirework() {
      // No-op when there's no confettiZone ref (e.g. compact navbar variant).
      var container = this.$refs.confettiZone;
      if (!container) return;
      var colors = window.CONFETTI_COLORS || ["#4BAF50", "#8E82FE", "#06D6A0", "#FF7C47", "#EF4444"];
      var particles = 72;
      for (var i = 0; i < particles; i++) {
        var el = document.createElement("div");
        el.style.cssText = "position:absolute;width:5px;height:5px;border-radius:50%;pointer-events:none;";
        el.style.left = "50%";
        el.style.top = "50%";
        el.style.background = colors[Math.floor(Math.random() * colors.length)];
        container.appendChild(el);
        var angle = (Math.PI * 2 * i / particles) + (Math.random() - 0.5) * 0.4;
        var distance = 80 + Math.random() * 100;
        var dx = Math.cos(angle) * distance;
        var dy = Math.sin(angle) * distance;
        var dur = 700 + Math.random() * 600;
        el.animate([
          { transform: "translate(-50%, -50%) scale(1.8)", opacity: 1 },
          { transform: "translate(calc(-50% + " + dx + "px), calc(-50% + " + dy + "px)) scale(0.2)", opacity: 0 }
        ], { duration: dur, easing: "cubic-bezier(0.16, 1, 0.3, 1)", fill: "forwards", delay: Math.random() * 100 });
        setTimeout(function (e) { e.remove(); }.bind(null, el), 1500);
      }
    },

    replay() {
      var self = this;
      self.displayLevel = Math.max(1, self.displayLevel - 1);
      self.playLevelUpFill({
        oldPct: 60,
        newLevel: self.displayLevel + 1,
        finalProgress: self.finalToward,
        fireConfetti: false
      });
      // Bounce class is gated to the moment the level number actually changes.
      self._schedule(function () { self.levelingUp = true; }, 1500);
      self._schedule(function () { self.levelingUp = false; }, 2800);
    },

    handleSeedsUpdate(d) {
      var self = this;
      if (d.levelUp) {
        // Defensive: only overwrite displayLevel if oldLevel is actually provided
        if (d.oldLevel !== undefined && d.oldLevel !== null) self.displayLevel = d.oldLevel;
        self.levelingUp = true;
        self.playLevelUpFill({
          oldPct: d.oldPct,
          newLevel: d.newLevel,
          finalProgress: d.progress,
          fireConfetti: true
        });
        self._schedule(function () { self.levelingUp = false; }, 3000);
      } else {
        if (d.level !== undefined && d.level !== null) self.displayLevel = d.level;
        self.displaySeeds = d.progress;
      }
    }
  };
}

// Note: the live factory lives INLINE in app/views/components/_seeds_bar.html.erb
// because importmap modules load AFTER Alpine processes x-data in this app's
// setup (verified 2026-05-24). This module is kept as a unit-testable
// duplicate and harmlessly re-assigns window.seedsBar after Alpine has
// already used the inline copy.
window.seedsBar = seedsBar;
