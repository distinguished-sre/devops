/* Анимации главной страницы. Без библиотек. Подключается только в layout home.
   Если анимации отключены в системе (prefers-reduced-motion), всё показывается сразу в конечном виде. */
(function () {
  'use strict';
  window.__homeReady = true;

  var doc = document, root = doc.documentElement, body = doc.body;
  var home = doc.querySelector('.home');
  if (!home) return;
  var still = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var hasIO = 'IntersectionObserver' in window;
  function $(s, c) { return (c || doc).querySelector(s); }
  function $$(s, c) { return Array.prototype.slice.call((c || doc).querySelectorAll(s)); }

  /* Вызывает cb(true/false), когда элемент входит в экран и уходит с него. */
  function watch(el, cb, margin) {
    if (!el) return;
    if (!hasIO) { cb(true); return; }
    new IntersectionObserver(function (es) { es.forEach(function (e) { cb(e.isIntersecting); }); },
      { rootMargin: margin || '0px' }).observe(el);
  }

  /* ---------- шапка прозрачная, пока страница наверху ---------- */
  function onScroll() { body.classList.toggle('scrolled', window.scrollY > 12); }
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  /* ---------- появление блоков ---------- */
  var reveals = $$('.reveal, .timebar, .anatomy');
  if (still || !hasIO) reveals.forEach(function (e) { e.classList.add('shown'); });
  else {
    var rio = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('shown'); rio.unobserve(e.target); } });
    }, { rootMargin: '0px 0px -12% 0px' });
    reveals.forEach(function (e) { rio.observe(e); });
  }

  /* ---------- счётчики на первом экране ---------- */
  if (!still) {
    $$('[data-count]').forEach(function (el) {
      var to = +el.getAttribute('data-count'), t0 = null, dur = 1500;
      if (to < 2) return;
      el.textContent = '0';
      setTimeout(function () {
        requestAnimationFrame(function step(t) {
          if (t0 === null) t0 = t;
          var k = Math.min(1, (t - t0) / dur);
          el.textContent = Math.round(to * (1 - Math.pow(1 - k, 3)));
          if (k < 1) requestAnimationFrame(step);
        });
      }, 550);
    });
  }

  /* ---------- прогресс: продолжить с первого непройденного урока ---------- */
  var done = {};
  try { (JSON.parse(localStorage.getItem('done') || '[]') || []).forEach(function (i) { done[i] = 1; }); } catch (e) {}
  $$('[data-dot]').forEach(function (d) { d.classList.toggle('on', !!done[d.getAttribute('data-dot')]); });
  var lessons = $$('.nav-lesson');
  var nDone = lessons.filter(function (a) { return done[a.getAttribute('data-id')]; }).length;
  if (nDone) {
    var next = lessons.filter(function (a) { return !done[a.getAttribute('data-id')]; })[0];
    $$('[data-continue]').forEach(function (a) {
      var txt = $('[data-continue-text]', a);
      if (next) { a.href = next.href; txt.textContent = 'Продолжить: урок ' + next.getAttribute('data-id'); }
      else { a.href = '#map'; txt.textContent = 'Курс пройден, открыть карту'; }
    });
    var hp = $('[data-home-progress]');
    if (hp) { hp.hidden = false; hp.textContent = '✓ пройдено ' + nDone + ' из ' + lessons.length + ' уроков'; }
  }

  /* ---------- терминалы: печатают команды курса по очереди ---------- */
  var SCRIPTS = {
    hero: [
      { tag: 'тема 1', cmd: 'systemctl status notes', out: [['● notes.service - Сервис Заметки', 'g'], ['     Active: active (running)', 'g']] },
      { tag: 'тема 2', cmd: 'curl -si http://notes.lab/healthz | head -1', out: [['HTTP/1.1 200 OK', 'g']] },
      { tag: 'тема 3', cmd: 'git push origin main', out: [['   3f2a1c9..8b7e0d4  main -> main', 'c'], ['# GitHub Actions: ✓ test  ✓ build', 'g']] },
      { tag: 'тема 4', cmd: 'docker compose up -d', out: [[' ✔ Container notes-db-1     Healthy', 'g'], [' ✔ Container notes-notes-1  Started', 'g'], [' ✔ Container notes-proxy-1  Started', 'g']] },
      { tag: 'тема 5', cmd: 'kubectl get pods -n notes', out: [['NAME                     READY   STATUS', 'c'], ['notes-6d9c7b8f5d-4kx2p   1/1     Running', 'g'], ['notes-6d9c7b8f5d-9zq7w   1/1     Running', 'g']] },
      { tag: 'тема 7', cmd: 'terraform apply', out: [['Apply complete! Resources: 0 added, 0 changed, 0 destroyed.', 'g']] },
      { tag: 'тема 8', cmd: 'curl -s notes.lab/metrics | grep requests_total', out: [['notes_http_requests_total{path="/notes",status="200"} 10', 'y']] },
      { tag: 'тема 9', cmd: 'flux get kustomizations', out: [['NAME   SUSPENDED  READY  MESSAGE', 'c'], ['notes  False      True   Applied revision: main@sha1:8b7e0d4', 'g']] }
    ],
    brk: [
      { state: ['ok', 'работает'], cmd: 'curl -si http://notes.lab/ | head -1', out: [['HTTP/1.1 200 OK', 'g']] },
      { cmd: '# ломаем: останавливаем приложение', out: [] },
      { cmd: 'sudo systemctl stop notes', out: [] },
      { state: ['bad', 'сломано'], cmd: 'curl -si http://notes.lab/ | head -1', out: [['HTTP/1.1 502 Bad Gateway', 'r']] },
      { cmd: '# nginx жив, но за ним пусто. Почему?', out: [] },
      { cmd: 'sudo tail -1 /var/log/nginx/error.log', out: [['connect() failed (111: Connection refused)', 'r'], ['while connecting to upstream', 'r']] },
      { cmd: 'systemctl is-active notes', out: [['inactive', 'y']] },
      { cmd: 'sudo systemctl start notes', out: [] },
      { state: ['ok', 'починено'], cmd: 'curl -si http://notes.lab/ | head -1', out: [['HTTP/1.1 200 OK', 'g']] }
    ]
  };

  function Terminal(pre, script, onStep) {
    var i = 0, running = false, timer = null, next = null, cursor = doc.createElement('span');
    cursor.className = 'cur';
    function line(html) {
      var s = doc.createElement('span'); s.className = 'ln'; s.innerHTML = html;
      pre.insertBefore(s, cursor.parentNode === pre ? cursor : null);
      while (pre.childNodes.length > 40) pre.removeChild(pre.firstChild);
      return s;
    }
    function esc(t) { return t.replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }
    // next помнит, что делать дальше: после паузы печать продолжается с того же места, а не с начала команды
    function later(fn, ms) { next = fn; timer = setTimeout(function () { timer = null; next = null; if (running) fn(); }, ms); }
    function run() {
      var st = script[i % script.length];
      if (i && i % script.length === 0) line('<span class="c">&nbsp;</span>');
      if (onStep) onStep(st);
      var isComment = st.cmd.charAt(0) === '#';
      var ln = line('<span class="p">$</span> ');
      var typed = doc.createElement('span'); if (isComment) typed.className = 'c';
      ln.appendChild(typed); ln.appendChild(cursor);
      var k = 0;
      (function type() {
        if (k < st.cmd.length) { typed.textContent += st.cmd.charAt(k++); later(type, 22 + Math.random() * 45); return; }
        later(function () {
          pre.appendChild(cursor);
          var j = 0;
          (function out() {
            if (j < st.out.length) { var o = st.out[j++]; line('<span class="' + o[1] + '">' + esc(o[0]) + '</span>'); later(out, 90); return; }
            var p = line('<span class="p">$</span> '); p.appendChild(cursor);
            i++;
            later(function () { pre.removeChild(p); run(); }, st.out.length ? 1500 : 650);
          })();
        }, 320);
      })();
    }
    // Первые n шагов выводятся сразу, чтобы терминал не стоял пустым, пока печатается остальное
    function renderStatic(n) {
      var part = script.slice(0, n || script.length);
      part.forEach(function (st) {
        line('<span class="p">$</span> <span' + (st.cmd.charAt(0) === '#' ? ' class="c"' : '') + '>' + esc(st.cmd) + '</span>');
        st.out.forEach(function (o) { line('<span class="' + o[1] + '">' + esc(o[0]) + '</span>'); });
      });
      if (onStep) onStep(part[part.length - 1]);
      if (n) i = n;
    }
    return {
      start: function () { if (running) return; running = true; if (!timer) { if (next) later(next, 300); else run(); } },
      stop: function () { running = false; if (timer) { clearTimeout(timer); timer = null; } },
      renderStatic: renderStatic
    };
  }

  var terms = [];
  var heroPre = $('[data-term="hero"]'), tag = $('[data-term-topic]');
  if (heroPre) terms.push([heroPre, Terminal(heroPre, SCRIPTS.hero, function (st) { if (tag && st.tag) tag.textContent = st.tag; }), 2]);
  var brkPre = $('[data-term="break"]'), state = $('[data-break-state]');
  if (brkPre) terms.push([brkPre, Terminal(brkPre, SCRIPTS.brk, function (st) {
    if (state && st.state) { state.className = 'term-state ' + st.state[0]; state.textContent = st.state[1]; }
  }), 1]);
  terms.forEach(function (p) {
    if (still) { p[1].renderStatic(); return; }
    p[1].renderStatic(p[2]);
    var visible = false;
    watch(p[0], function (v) { visible = v; if (v && !doc.hidden) p[1].start(); else p[1].stop(); });
    doc.addEventListener('visibilitychange', function () { if (doc.hidden) p[1].stop(); else if (visible) p[1].start(); });
  });

  /* ---------- путь кода: точка бежит по дороге и зажигает этапы ---------- */
  var pipe = $('[data-pipe]');
  if (pipe) {
    var nodes = $$('.pnode', pipe), N = nodes.length;
    var setP = function (p) {
      pipe.style.setProperty('--p', p.toFixed(4));
      nodes.forEach(function (n, i) {
        var pos = i / (N - 1);
        n.classList.toggle('passed', p >= pos - 0.001);
        n.classList.toggle('hit', Math.abs(p - pos) < 0.075 || (p >= 1 && i === N - 1));
      });
    };
    if (still) setP(1);
    else {
      var raf = null, t0 = null, RUN = 6500, HOLD = 1600;
      var frame = function (t) {
        if (t0 === null) t0 = t;
        var e = (t - t0) % (RUN + HOLD), k = Math.min(1, e / RUN);
        setP(k < 1 ? k * k * (3 - 2 * k) * 0.35 + k * 0.65 : 1);
        raf = requestAnimationFrame(frame);
      };
      watch(pipe, function (v) {
        if (v && !raf) raf = requestAnimationFrame(frame);
        else if (!v && raf) { cancelAnimationFrame(raf); raf = null; }
      });
    }
  }

  /* ---------- сквозной проект: слой стека на каждый шаг ---------- */
  var layers = $$('[data-layer]'), steps = $$('[data-step]');
  var cnt = $('[data-stack-count]'), lbl = $('[data-stack-label]'), cur = 0;
  function setStep(n) {
    if (n === cur) return;
    layers.forEach(function (l) {
      var k = +l.getAttribute('data-layer'), was = l.classList.contains('built');
      l.classList.toggle('built', k <= n);
      l.classList.toggle('now', k === n);
      if (!still && k <= n && !was) { l.classList.remove('drop'); void l.offsetWidth; l.classList.add('drop'); }
    });
    steps.forEach(function (s) { s.classList.toggle('now', +s.getAttribute('data-step') === n); });
    var L = layers.filter(function (l) { return +l.getAttribute('data-layer') === n; })[0];
    if (cnt) cnt.textContent = n;
    if (lbl && L) lbl.textContent = $('.lt', L).textContent;
    cur = n;
  }
  if (layers.length) {
    setStep(1);
    if (hasIO) {
      var sio = new IntersectionObserver(function (es) {
        es.forEach(function (e) { if (e.isIntersecting) setStep(+e.target.getAttribute('data-step')); });
      }, { rootMargin: '-45% 0px -50% 0px' });
      steps.forEach(function (s) { sio.observe(s); });
    } else setStep(layers.length);
  }

  /* ---------- карта: полоска времени и карточки подсвечивают друг друга ---------- */
  function pair(n, on) {
    $$('[data-seg="' + n + '"], .tcard[data-topic="' + n + '"]').forEach(function (e) { e.classList.toggle('hl', on); });
  }
  $$('[data-seg]').forEach(function (s) {
    var n = s.getAttribute('data-seg');
    s.addEventListener('mouseenter', function () { pair(n, true); });
    s.addEventListener('mouseleave', function () { pair(n, false); });
  });
  $$('.tcard').forEach(function (c) {
    var n = c.getAttribute('data-topic');
    c.addEventListener('mouseenter', function () { pair(n, true); });
    c.addEventListener('mouseleave', function () { pair(n, false); });
    /* пятно света за курсором */
    c.addEventListener('pointermove', function (e) {
      var r = c.getBoundingClientRect();
      c.style.setProperty('--mx', (e.clientX - r.left) + 'px');
      c.style.setProperty('--my', (e.clientY - r.top) + 'px');
    });
  });

  /* ---------- калькулятор темпа ---------- */
  var calc = $('[data-calc]');
  if (calc) {
    var HOURS = parseFloat(home.getAttribute('data-hours')) || 165;
    var inH = $('[data-in="h"]', calc), inD = $('[data-in="d"]', calc);
    var MONTHS = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'];
    var plural = function (n, a, b, c) { var m10 = n % 10, m100 = n % 100; return m10 === 1 && m100 !== 11 ? a : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? b : c); };
    var upd = function () {
      var h = parseFloat(inH.value), d = parseInt(inD.value, 10);
      $('[data-out="h"]', calc).textContent = String(h).replace('.', ',');
      $('[data-out="d"]', calc).textContent = d;
      var weeks = Math.ceil(HOURS / (h * d));
      $('[data-res-weeks]', calc).textContent = weeks;
      $('[data-res-unit]', calc).textContent = plural(weeks, 'неделя', 'недели', 'недель');
      var end = new Date(); end.setDate(end.getDate() + weeks * 7);
      var months = Math.round(weeks / 4.35);
      $('[data-res-date]', calc).textContent = 'Если начать сегодня, финиш примерно: ' + MONTHS[end.getMonth()] + ' ' + end.getFullYear() +
        (months >= 2 ? ' (около ' + months + ' ' + plural(months, 'месяца', 'месяцев', 'месяцев') + ')' : '');
    };
    inH.addEventListener('input', upd); inD.addEventListener('input', upd); upd();
  }

  /* ---------- мягкий уход со страницы по внутренней ссылке ---------- */
  if (!still) {
    home.addEventListener('click', function (e) {
      var a = e.target.closest('a[href]');
      if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || a.target) return;
      var url = new URL(a.href, location.href);
      if (url.origin !== location.origin || (url.pathname === location.pathname && url.hash)) return;
      e.preventDefault();
      root.classList.add('leaving');
      setTimeout(function () { location.href = a.href; }, 240);
    });
    window.addEventListener('pageshow', function () { root.classList.remove('leaving'); });
  }
})();
