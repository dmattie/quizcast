/* Quizcast client behaviour.
   The trace is the signature element: a live recording channel across the foot
   of the projector screen. Baseline noise while the room thinks, a deflection
   for every answer that lands. It shows activity without leaking which option
   anyone chose. */

(function () {
  "use strict";

  var reduced = window.matchMedia &&
                window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function whenShiny(fn) {
    if (window.Shiny && window.Shiny.addCustomMessageHandler && window.jQuery) { fn(); }
    else { setTimeout(function () { whenShiny(fn); }, 50); }
  }

  function cssVar(name, fallback) {
    var v = getComputedStyle(document.documentElement).getPropertyValue(name);
    return (v && v.trim()) || fallback;
  }

  /* ---------------- response trace ---------------- */
  var Trace = {
    canvas: null, ctx: null, samples: [], pending: 0, phase: "lobby", w: 0, h: 0,

    init: function (canvas) {
      this.canvas = canvas;
      this.ctx = canvas.getContext("2d");
      this.resize();
      window.addEventListener("resize", this.resize.bind(this));
      for (var i = 0; i < 400; i++) this.samples.push(0);
      if (!reduced) requestAnimationFrame(this.frame.bind(this));
    },

    resize: function () {
      var dpr = window.devicePixelRatio || 1;
      this.w = this.canvas.clientWidth;
      this.h = this.canvas.clientHeight;
      this.canvas.width = this.w * dpr;
      this.canvas.height = this.h * dpr;
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    },

    spike: function (n) { this.pending += n; },

    frame: function () {
      var idle = this.phase !== "question";
      var amp = idle ? 0.6 : 1.6;
      var v = (Math.random() - 0.5) * amp;

      if (this.pending > 0) {
        this.pending -= 1;
        v = (Math.random() < 0.5 ? -1 : 1) * (16 + Math.random() * 10);
      }

      this.samples.push(v);
      while (this.samples.length > 400) this.samples.shift();

      var ctx = this.ctx, w = this.w, h = this.h, mid = h * 0.62;
      ctx.clearRect(0, 0, w, h);

      var grad = ctx.createLinearGradient(0, 0, w, 0);
      grad.addColorStop(0, "rgba(23,190,187,0)");
      grad.addColorStop(0.12, cssVar("--ch2", "#17BEBB"));
      grad.addColorStop(1, cssVar("--ch2", "#17BEBB"));

      ctx.strokeStyle = grad;
      ctx.lineWidth = 1.5;
      ctx.globalAlpha = idle ? 0.35 : 0.75;
      ctx.beginPath();
      var step = w / (this.samples.length - 1);
      for (var i = 0; i < this.samples.length; i++) {
        var x = i * step, y = mid - this.samples[i];
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.globalAlpha = 1;

      requestAnimationFrame(this.frame.bind(this));
    }
  };

  /* ---------------- confetti ---------------- */
  function celebrate() {
    if (reduced) return;
    var cv = document.createElement("canvas");
    cv.style.cssText =
      "position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:9999";
    document.body.appendChild(cv);
    var ctx = cv.getContext("2d");
    var dpr = window.devicePixelRatio || 1;
    cv.width = innerWidth * dpr; cv.height = innerHeight * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    var colors = [cssVar("--ch1", "#D6336C"), cssVar("--ch2", "#17BEBB"),
                  cssVar("--ch3", "#F2C14E"), cssVar("--ch4", "#8B7BC4"),
                  cssVar("--bone", "#E8E4DB")];
    var bits = [];
    for (var i = 0; i < 220; i++) {
      bits.push({
        x: innerWidth * (0.2 + Math.random() * 0.6),
        y: innerHeight + Math.random() * 120,
        vx: (Math.random() - 0.5) * 7,
        vy: -(11 + Math.random() * 9),
        w: 5 + Math.random() * 7,
        h: 3 + Math.random() * 5,
        rot: Math.random() * Math.PI,
        vr: (Math.random() - 0.5) * 0.28,
        c: colors[(Math.random() * colors.length) | 0]
      });
    }

    var start = performance.now();
    (function step(now) {
      var t = now - start;
      ctx.clearRect(0, 0, innerWidth, innerHeight);
      for (var i = 0; i < bits.length; i++) {
        var b = bits[i];
        b.vy += 0.26; b.x += b.vx; b.y += b.vy; b.rot += b.vr;
        ctx.save();
        ctx.translate(b.x, b.y);
        ctx.rotate(b.rot);
        ctx.globalAlpha = Math.max(0, 1 - t / 6500);
        ctx.fillStyle = b.c;
        ctx.fillRect(-b.w / 2, -b.h / 2, b.w, b.h);
        ctx.restore();
      }
      if (t < 6500) requestAnimationFrame(step);
      else cv.remove();
    })(start);
  }

  /* ---------------- background music ---------------- */
  /* Browsers block autoplay, so this always needs one deliberate click.
     Volume is stored so it survives the re-renders between questions. */
  function audioSetup() {
    var btn = document.getElementById("bgm-toggle");
    var vol = document.getElementById("bgm-vol");
    if (!btn || !vol) return;

    var saved = sessionStorage.getItem("bgm-vol");
    if (saved !== null) vol.value = saved;

    function el() { return document.getElementById("bgm"); }

    function apply() {
      var a = el();
      if (a) a.volume = Math.pow(vol.value / 100, 2); // perceptual, not linear
    }

    btn.addEventListener("click", function () {
      var a = el();
      if (!a) { btn.textContent = "No track"; return; }
      apply();
      if (a.paused) {
        a.play().then(function () { btn.textContent = "Pause music"; })
                .catch(function () { btn.textContent = "Blocked"; });
      } else {
        a.pause();
        btn.textContent = "Play music";
      }
    });

    vol.addEventListener("input", function () {
      sessionStorage.setItem("bgm-vol", vol.value);
      apply();
    });

    // The <audio> element is re-rendered when a quiz loads; keep it in sync.
    new MutationObserver(apply).observe(document.body, { childList: true, subtree: true });
  }

  /* ---------------- surviving a locked phone ---------------- */
  /* When the websocket closes, Shiny lays a grey overlay over the page that
     swallows every tap. On a phone that has just been unlocked this reads as a
     frozen app. The socket is gone either way, so the only real recovery is a
     reload, and two rules keep that from becoming a nuisance:

       - never reload a page nobody is looking at. A locked phone must not wake
         the container and hold the Azure replica open, billing, all evening.
       - give up after a few quick failures, so 50 phones cannot hammer a
         server that is genuinely down. Then it is one tap, deliberately.

     Shiny announces connect and disconnect through jQuery's synthetic trigger
     ($(document).trigger("shiny:disconnected")), which a native
     addEventListener never receives. Hence jQuery here, and hence the direct
     socket probe as well: a phone can come back from sleep with its socket
     already closed and no event left to deliver. */
  var Recover = {
    ready: false, dead: false, pending: false, banner: null,

    init: function () {
      var self = this;

      whenShiny(function () {
        var $ = window.jQuery;

        $(document).on("shiny:connected", function () {
          self.ready = true;
          self.dead = false;
          self.hide();
          // Offer the stored alias back so a reload lands in the game rather
          // than at the name gate. play_server is the only listener.
          var a = null;
          try { a = localStorage.getItem("qc-alias"); } catch (e) {}
          if (a) Shiny.setInputValue("resume", a, { priority: "event" });
        });

        $(document).on("shiny:disconnected", function () { self.fail(); });
      });

      // This one is a real DOM event, and it is what fires when the phone is
      // unlocked. Probe rather than trust a flag: the disconnect may have
      // happened while this page was frozen.
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState !== "visible") return;
        self.check();
        setTimeout(function () { self.check(); }, 1500);
      });
    },

    socketDead: function () {
      try {
        var s = window.Shiny && Shiny.shinyapp && Shiny.shinyapp.$socket;
        return !s || s.readyState > 1;         // 2 CLOSING, 3 CLOSED
      } catch (e) { return false; }
    },

    check: function () {
      if (!this.ready) return;                 // never connected yet
      if (this.dead || this.socketDead()) this.fail();
    },

    fail: function () {
      this.dead = true;
      this.show("Reconnecting\u2026");
      if (document.visibilityState === "visible") this.attempt();
    },

    attempt: function () {
      if (this.pending) return;
      if (this.tooMany()) { this.show("Tap to reconnect", true); return; }
      this.pending = true;
      // Jitter, because a server restart disconnects the whole room at once.
      setTimeout(function () { location.reload(); }, 300 + Math.random() * 1200);
    },

    tooMany: function () {
      var now = Date.now(), hist = [];
      try { hist = JSON.parse(sessionStorage.getItem("qc-reloads") || "[]"); }
      catch (e) { hist = []; }
      hist = hist.filter(function (t) { return now - t < 60000; });
      hist.push(now);
      try { sessionStorage.setItem("qc-reloads", JSON.stringify(hist)); } catch (e) {}
      return hist.length > 4;
    },

    show: function (text, tappable) {
      if (!this.banner) {
        this.banner = document.createElement("div");
        this.banner.className = "reconnect";
        document.body.appendChild(this.banner);
      }
      this.banner.textContent = text;
      this.banner.classList.toggle("tappable", !!tappable);
      this.banner.onclick = tappable ? function () { location.reload(); } : null;
    },

    hide: function () { if (this.banner) this.banner.remove(); this.banner = null; }
  };

  /* ---------------- wiring ---------------- */
  document.addEventListener("DOMContentLoaded", function () {
    var canvas = document.getElementById("trace");
    if (canvas) Trace.init(canvas);
    audioSetup();
    Recover.init();
  });

  whenShiny(function () {
    var lastCount = 0;

    Shiny.addCustomMessageHandler("tick", function (msg) {
      if (msg.phase !== Trace.phase) {
        Trace.phase = msg.phase;
        if (msg.phase === "question") lastCount = 0;
      }
      if (msg.answered > lastCount) {
        Trace.spike(msg.answered - lastCount);
        lastCount = msg.answered;
      } else if (msg.answered < lastCount) {
        lastCount = msg.answered;
      }

      var hud = document.getElementById("hud");
      if (hud && msg.phase === "question") {
        var s = msg.answered + (msg.answered === 1 ? " answer" : " answers");
        if (msg.remaining !== null && msg.remaining !== undefined) {
          s = msg.remaining + "s  ·  " + s;
        }
        hud.textContent = s;
      }
    });

    Shiny.addCustomMessageHandler("celebrate", celebrate);

    Shiny.addCustomMessageHandler("remember", function (msg) {
      try { localStorage.setItem("qc-alias", msg.alias); } catch (e) {}
    });

    // The name was taken by someone with an open socket. Stop offering it.
    Shiny.addCustomMessageHandler("forget", function () {
      try { localStorage.removeItem("qc-alias"); } catch (e) {}
    });
  });

  /* Enter submits the join form. */
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Enter") return;
    var alias = document.getElementById("alias");
    var join = document.getElementById("join");
    if (alias && join && document.activeElement === alias) join.click();
  });
})();
