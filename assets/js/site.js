/* Поведение сайта курса. Без внешних библиотек. Всё, что зависит от localStorage, обёрнуто в try/catch. */
(function () {
  'use strict';

  var doc = document, root = doc.documentElement;
  var mem = {};
  function store(k, v) {
    try {
      if (v === undefined) { var r = localStorage.getItem(k); return r === null ? (mem[k] === undefined ? null : mem[k]) : r; }
      localStorage.setItem(k, v);
    } catch (e) {
      if (v === undefined) return mem[k] === undefined ? null : mem[k];
      mem[k] = v;
    }
  }
  function $(s, c) { return (c || doc).querySelector(s); }
  function $$(s, c) { return Array.prototype.slice.call((c || doc).querySelectorAll(s)); }
  function el(tag, cls, text) { var e = doc.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }

  /* ---------- тема ---------- */
  var themeBtn = $('.theme-btn');
  if (themeBtn) themeBtn.addEventListener('click', function () {
    var next = root.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
    root.setAttribute('data-theme', next);
    store('theme', next);
  });

  /* ---------- выезжающее меню ---------- */
  var menuBtn = $('.menu-btn'), backdrop = $('.backdrop');
  function setNav(open) {
    doc.body.classList.toggle('nav-open', open);
    if (menuBtn) menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (backdrop) backdrop.hidden = !open;
  }
  if (menuBtn) menuBtn.addEventListener('click', function () { setNav(!doc.body.classList.contains('nav-open')); });
  if (backdrop) backdrop.addEventListener('click', function () { setNav(false); });

  /* ---------- прогресс курса ---------- */
  var nav = $('.course-nav');
  var TOTAL = 0;
  var allIds = $$('.nav-lesson').map(function (a) { return a.getAttribute('data-id'); });
  TOTAL = allIds.length;
  function getDone() {
    var d = {};
    try { (JSON.parse(store('done') || '[]') || []).forEach(function (i) { d[i] = 1; }); } catch (e) {}
    return d;
  }
  function saveDone(d) { store('done', JSON.stringify(Object.keys(d))); }

  function renderProgress() {
    var d = getDone();
    var n = allIds.filter(function (i) { return d[i]; }).length;
    var pct = TOTAL ? Math.round(100 * n / TOTAL) : 0;
    $$('.nav-lesson, .lesson-card').forEach(function (a) { a.classList.toggle('done', !!d[a.getAttribute('data-id')]); });
    var per = {};
    $$('.nav-lesson').forEach(function (a) {
      var t = a.getAttribute('data-topic'); per[t] = per[t] || 0;
      if (d[a.getAttribute('data-id')]) per[t]++;
    });
    $$('[data-count-for]').forEach(function (s) {
      var t = s.getAttribute('data-count-for'), of = s.getAttribute('data-of') || (s.closest('.topic-card') || {getAttribute: function () { return ''; }}).getAttribute('data-of');
      s.textContent = (per[t] || 0) + '/' + of;
    });
    $$('.topic-card').forEach(function (c) {
      var t = c.getAttribute('data-topic'), of = +c.getAttribute('data-of') || 1;
      var i = $('.bar > i', c); if (i) i.style.width = Math.round(100 * (per[t] || 0) / of) + '%';
    });
    $$('[data-topic-progress]').forEach(function (s) {
      var t = s.getAttribute('data-topic-progress');
      s.textContent = (per[t] || 0) + '/' + s.getAttribute('data-of') + ' пройдено';
    });
    var chip = $('.progress-chip');
    if (chip && TOTAL) { chip.hidden = false; $('[data-progress-text]', chip).textContent = '✓ ' + n + '/' + TOTAL; }
    var ov = $('[data-overall]');
    if (ov && TOTAL) { ov.hidden = false; ov.textContent = 'пройдено ' + n + ' из ' + TOTAL + ' (' + pct + '%)'; }
    var sl = $('[data-sl-text]');
    if (sl) sl.textContent = 'курс ' + n + '/' + TOTAL + ' · ' + pct + '%';
    var slb = $('[data-sl-bar]');
    if (slb) { slb.innerHTML = '<i style="width:' + pct + '%"></i>'; }
    var btn = $('[data-done-btn]'), lesson = $('.lesson');
    if (btn && lesson) {
      var id = lesson.getAttribute('data-lesson'), on = !!d[id];
      btn.setAttribute('aria-pressed', on ? 'true' : 'false');
      btn.textContent = on ? '☒ Урок пройден' : 'Отметить урок пройденным';
    }
  }
  var doneBtn = $('[data-done-btn]');
  if (doneBtn) doneBtn.addEventListener('click', function () {
    var id = $('.lesson').getAttribute('data-lesson'), d = getDone();
    if (d[id]) delete d[id]; else d[id] = 1;
    saveDone(d); renderProgress();
  });
  renderProgress();

  /* ---------- поиск по карте курса ---------- */
  var q = $('#q');
  if (q && nav) {
    var topics = $$('.nav-topic', nav), empty = $('.nav-empty', nav);
    var wasOpen = null;
    var filter = function () {
      var s = q.value.trim().toLowerCase(), any = false;
      if (s && wasOpen === null) wasOpen = topics.map(function (t) { return t.open; });
      topics.forEach(function (t, i) {
        var hit = 0;
        $$('li', t).forEach(function (li) {
          var m = !s || li.textContent.toLowerCase().indexOf(s) !== -1 || (t.textContent.toLowerCase().indexOf(s) !== -1 && s.length > 2 && $('summary', t).textContent.toLowerCase().indexOf(s) !== -1);
          li.hidden = !m; if (m && s) hit++;
        });
        t.hidden = !!s && !hit;
        if (s) { t.open = hit > 0; if (hit) any = true; }
      });
      if (!s && wasOpen) { topics.forEach(function (t, i) { t.open = wasOpen[i]; t.hidden = false; }); wasOpen = null; }
      empty.hidden = !s || any;
    };
    q.addEventListener('input', filter);
    q.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        var first = $$('.nav-lesson', nav).filter(function (a) { return !a.parentNode.hidden && !a.closest('[hidden]'); })[0];
        if (first) location.href = first.href;
      } else if (e.key === 'Escape') { if (!q.value) setNav(false); q.value = ''; filter(); q.blur(); }
    });
  }

  /* ---------- блоки кода ---------- */
  var BASH = /^(bash|sh|shell|zsh|console)$/;
  var OUT = /^(text|plaintext|output|log)$/;
  function langOf(box) {
    var m = /language-([\w+-]+)/.exec(box.className); return m ? m[1] : 'text';
  }
  function copyText(pre, lang) {
    var t = pre.textContent.replace(/\n$/, '');
    if (BASH.test(lang)) {
      var ls = t.split('\n').filter(function (l) { return l.trim() !== ''; });
      if (ls.length && ls.every(function (l) { return /^\$ /.test(l); })) t = t.replace(/^\$ /mg, '');
    }
    return t;
  }
  function copyBtn(get) {
    var b = el('button', 'copy', 'копировать'); b.type = 'button';
    b.setAttribute('aria-label', 'Копировать код');
    b.addEventListener('click', function () {
      var t = get();
      var done = function () { b.textContent = 'скопировано'; b.classList.add('ok'); setTimeout(function () { b.textContent = 'копировать'; b.classList.remove('ok'); }, 1600); };
      var fallback = function () {
        var ta = el('textarea'); ta.value = t; ta.style.cssText = 'position:fixed;opacity:0'; doc.body.appendChild(ta); ta.select();
        try { doc.execCommand('copy'); done(); } catch (e) {} doc.body.removeChild(ta);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(done, fallback); else fallback();
    });
    return b;
  }
  $$('[data-prose] div.highlighter-rouge').forEach(function (box) {
    var lang = langOf(box), pre = $('pre', box), tool = el('div', 'tool');
    if (OUT.test(lang)) {
      tool.className = 'tool out';
      box.parentNode.insertBefore(tool, box); tool.appendChild(box);
      tool.appendChild(copyBtn(function () { return copyText(pre, lang); }));
      var prev = tool.previousElementSibling;
      if (prev && prev.classList.contains('bash')) { tool.classList.add('chained'); prev.classList.add('follows'); }
      return;
    }
    var name = BASH.test(lang) ? 'Bash' : (lang === 'text' ? 'Файл' : lang);
    if (BASH.test(lang)) tool.className = 'tool bash';
    var head = el('div', 'tool-head');
    var nm = el('span', 'tool-name'); nm.innerHTML = '<span class="dot">⏺</span> ';
    nm.appendChild(doc.createTextNode(name));
    head.appendChild(nm); head.appendChild(copyBtn(function () { return copyText(pre, lang); }));
    box.parentNode.insertBefore(tool, box); tool.appendChild(head); tool.appendChild(box);
  });

  /* ---------- todo-списки «Итог урока» ---------- */
  var todoIdx = 0;
  $$('[data-prose] li').forEach(function (li) {
    var m, inp = li.querySelector('input.task-list-item-checkbox');
    if (inp && inp.closest('li') === li) {
      /* GFM-чекбокс от kramdown: забираем состояние и убираем нативный input */
      m = [inp.checked ? '[x]' : '[ ]', inp.checked ? 'x' : ' ']; m[0] = ''; inp.parentNode.removeChild(inp);
    } else {
      var w = doc.createTreeWalker(li, NodeFilter.SHOW_TEXT, null), n = w.nextNode();
      if (!n) return;
      m = /^\s*\[( |x|X)\]\s?/.exec(n.nodeValue);
      if (!m) return;
      if (li.firstChild !== n && li.firstElementChild && li.firstElementChild.tagName !== 'P') return;
      n.nodeValue = n.nodeValue.slice(m[0].length);
    }
    var idx = todoIdx++, key = 'todo:' + location.pathname + ':' + idx;
    var text = el('div', 'todo-text');
    while (li.firstChild) text.appendChild(li.firstChild);
    var box = el('button', 'todo-box'); box.type = 'button'; box.setAttribute('role', 'checkbox');
    box.setAttribute('aria-label', 'Отметить пункт');
    var on = store(key) === '1' || (store(key) === null && /x/i.test(m[1]));
    var set = function (v, save) {
      box.setAttribute('aria-checked', v ? 'true' : 'false'); li.classList.toggle('checked', v);
      if (save) store(key, v ? '1' : '0');
    };
    set(on, false);
    li.classList.add('todo'); li.appendChild(box); li.appendChild(text);
    if (li.parentNode) li.parentNode.classList.add('todo-list');
    li.addEventListener('click', function (e) {
      if (e.target.closest('a, code, button.copy') ) return;
      set(box.getAttribute('aria-checked') !== 'true', true);
    });
  });

  /* ---------- подсказки «Проверь понимание» / «Предскажи» ---------- */
  $$('[data-prose] blockquote').forEach(function (b) {
    var s = b.querySelector('strong, p');
    var t = (s ? s.textContent : '').trim().toLowerCase();
    if (/^(проверь понимание|проверь себя|предскажи|подумай|вопрос)/.test(t)) b.classList.add(/^предскажи/.test(t) ? 'predict' : 'hint');
    else if (/^(осторожно|внимание|важно|опасно)/.test(t)) b.classList.add('warn');
  });

  /* ---------- метки [junior]/[middle] на карточки ---------- */
  $$('[data-prose] h3').forEach(function (h) {
    var m = /^\s*(?:\d+\.\s*)?\[(junior|middle|senior)\]\s*/i.exec(h.textContent);
    if (!m) return;
    var lvl = m[1].toLowerCase(), tag = el('span', 'tag tag-' + lvl, lvl);
    var first = h.firstChild;
    if (first && first.nodeType === 3) first.nodeValue = first.nodeValue.replace(/\[(junior|middle|senior)\]\s*/i, '');
    h.insertBefore(tag, h.firstChild);
    // [часто]: вопрос, который задают почти на каждом собеседовании по теме
    var t2 = tag.nextSibling;
    if (t2 && t2.nodeType === 3 && /^\s*(?:\d+\.\s*)?\[часто\]\s*/i.test(t2.nodeValue)) {
      t2.nodeValue = t2.nodeValue.replace(/\[часто\]\s*/i, '');
      h.insertBefore(el('span', 'tag tag-hot', 'часто спрашивают'), t2);
    }
    var card = el('div', 'qcard'), sib = h.nextElementSibling;
    h.parentNode.insertBefore(card, h); card.appendChild(h);
    while (sib && !/^H[1-3]$/.test(sib.tagName)) { var nx = sib.nextElementSibling; card.appendChild(sib); sib = nx; }
  });

  /* ---------- оглавление страницы ---------- */
  var TR = {а:'a',б:'b',в:'v',г:'g',д:'d',е:'e',ё:'e',ж:'zh',з:'z',и:'i',й:'y',к:'k',л:'l',м:'m',н:'n',о:'o',п:'p',р:'r',с:'s',т:'t',у:'u',ф:'f',х:'h',ц:'c',ч:'ch',ш:'sh',щ:'sch',ъ:'',ы:'y',ь:'',э:'e',ю:'yu',я:'ya'};
  function slug(s) {
    return s.toLowerCase().replace(/[а-яё]/g, function (c) { return TR[c]; }).replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  }
  var lesson = $('.lesson-body');
  if (lesson) {
    var heads = $$('h2, h3', lesson).filter(function (h) { return !h.closest('details, .toc'); });
    var used = {};
    heads.forEach(function (h, i) {
      var id = h.id;
      if (!id || /^section(-\d+)?$/.test(id)) id = slug(h.textContent) || 'h-' + i;
      while (used[id]) id += '-' + i;
      used[id] = 1; h.id = id;
      var a = el('a', 'anchor', '#'); a.href = '#' + id; a.setAttribute('aria-label', 'Ссылка на раздел'); h.appendChild(a);
    });
    var tocs = $$('[data-toc]');
    if (heads.length > 2) {
      var qc = false;
      heads.forEach(function (h) {
        var text = h.textContent.replace(/#$/, '').trim();
        if (h.tagName === 'H3' && h.closest('.qcard')) { if (qc) return; }
        var li = el('li', h.tagName === 'H3' ? 'l3' : 'l2'), a = el('a', null, text); a.href = '#' + h.id;
        li.appendChild(a);
        tocs.forEach(function (ol, i) { ol.appendChild(i ? li.cloneNode(true) : li); });
      });
      tocs.forEach(function (ol) { var p = ol.closest('.toc'); if (p) p.hidden = false; });
      /* h3 внутри карточек вопросов в оглавление не нужны: оставим только h2 */
      $$('.toc li.l3').forEach(function (li) {
        var target = doc.getElementById(li.firstChild.getAttribute('href').slice(1));
        if (target && target.closest('.qcard')) li.remove();
      });
      if ('IntersectionObserver' in window) {
        var links = {};
        $$('.toc-side a').forEach(function (a) { links[a.getAttribute('href').slice(1)] = a; });
        var io = new IntersectionObserver(function (es) {
          es.forEach(function (e) {
            if (e.isIntersecting && links[e.target.id]) {
              $$('.toc-side a.active').forEach(function (x) { x.classList.remove('active'); });
              links[e.target.id].classList.add('active');
            }
          });
        }, { rootMargin: '-70px 0px -70% 0px' });
        heads.forEach(function (h) { if (links[h.id]) io.observe(h); });
      }
    }
  }

  /* ---------- клавиши ---------- */
  doc.addEventListener('keydown', function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var t = e.target, typing = t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable);
    if (typing) return;
    if (e.key === '/') {
      if (q) { e.preventDefault(); if (doc.body.classList.contains('nav-open') === false && (window.innerWidth <= 900 || doc.body.classList.contains('layout-home'))) setNav(true); q.focus(); }
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      var a = $('a[data-nav="' + (e.key === 'ArrowLeft' ? 'prev' : 'next') + '"]');
      if (a) location.href = a.href;
    } else if (e.key === 'Escape') setNav(false);
  });
  /* ссылки внутри меню закрывают его на мобильном */
  if (nav) nav.addEventListener('click', function (e) { if (e.target.closest('a')) setNav(false); });

  /* текущий урок виден в сайдбаре */
  var cur = $('.nav-lesson.current, .nav-overview.current');
  var sb = $('.sidebar');
  if (cur && sb) { var r = cur.getBoundingClientRect(); if (r.bottom > window.innerHeight - 40 || r.top < 60) sb.scrollTop += r.top - window.innerHeight / 3; }
})();
