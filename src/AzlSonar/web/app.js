/* AzL Sonar page. Vanilla JS, no dependencies, no network calls except same-origin /api routes.
   Contract: docs/design.md (HTTP API and Page sections). */
(function () {
  'use strict';

  // ------------------------------------------------------------------ constants

  var MAX_RENDERED_LINES = 3000;   // DOM cap for the log pane
  var MAX_STORED_LINES = 20000;    // in-memory cap (server ring buffer is 5000)
  var POLL_MS = 5000;              // fallback polling interval
  var SSE_MAX_BACKOFF_MS = 30000;
  var THEME_KEY = 'azlsonar.theme';
  var LA_PHASES = ['provisioning', 'arc-registration', 'validation', 'deployment', 'post-deployment', 'update', 'add-node', 'repair'];
  var PHASES = ['provisioning', 'arc-registration', 'validation', 'deployment', 'done', 'failed', 'update', 'add-node', 'repair'];
  var PHASE_LABEL = {
    provisioning: 'Provisioning', 'arc-registration': 'Arc registration', validation: 'Validation',
    deployment: 'Deployment', done: 'Done', failed: 'Failed', 'post-deployment': 'Post-deployment',
    update: 'Update', 'add-node': 'Add node', repair: 'Repair'
  };
  var ROUTE_LABEL = { simplified: 'Simplified machine provisioning (preview)', 'oem-image': 'OEM image + Arc registration' };
  var STATUS_LABEL = {
    notstarted: 'Not started', running: 'In progress', success: 'Succeeded',
    error: 'Failed', skipped: 'Skipped', unknown: 'Unknown'
  };
  var DEMO = typeof location !== 'undefined' && /(?:^|[?&])demo=(?:1|true|yes)(?:&|$)/i.test(location.search);
  // ?demo=1&route=simplified|oem shows the machine-readiness phase of that route instead of a running deployment.
  // ?demo=1&replay=1 plays the demo deployment as a built-in recording (the replay transport bar without a file).
  var DEMO_REPLAY = DEMO && /(?:^|[?&])replay=(?:1|true|yes)(?:&|$)/i.test(location.search);
  var REPLAY_SPEEDS = [1, 30, 60, 240];
  var DEMO_ROUTE = (function () {
    if (typeof location === 'undefined') return '';
    var m = /(?:^|[?&])route=(simplified|oem|oem-image)(?:&|$)/i.exec(location.search);
    return m ? (m[1].toLowerCase() === 'simplified' ? 'simplified' : 'oem-image') : '';
  })();

  // ------------------------------------------------------------------ state

  var app = {
    replay: null,               // replay engine while a recording plays (startReplay); null when live
    config: null,
    state: null,
    guidance: null,
    guidancePhase: null,        // phase picked by the user in the guidance card (null = follow current)
    tailer: null,
    reportedFiles: [],          // files the tailer reports now (/api/logs files, tailer activeFiles)
    fileSig: null,              // signature of the file filter options last rendered
    store: null,                // log store (createLogStore), set below
    logGen: 0,                  // bumped on a back-end restart so late /api/logs answers are ignored
    counts: { all: 0, warning: 0, error: 0 },
    filter: { level: 'all', q: '', file: '', stepKey: null, node: '', nodeBy: '', stage: '' },   // nodeBy: 'card' or 'step' (what chose the machine)
    ui: { mode: null, pickedAt: null, lastMode: null },   // mode the user clicked, and the active mode it was clicked in
    summary: null,              // the summary box model last rendered (summaryFor)
    about: null,                // /api/about: version and documentation links
    details: null,              // /api/details: what Sonar collected and is using
    follow: true,
    newWhilePaused: 0,
    rendered: 0,
    treeSig: { provisioning: null, validation: null, extensions: null, deployment: null, update: null },
    expanded: new Map(),        // key -> bool (user choice)
    sectionCollapsed: { provisioning: false, validation: false, extensions: false, deployment: false, update: false },
    provAutoCollapsed: false,   // the provisioning section was collapsed once validation started
    provTree: [],               // one synthetic tree item per machine (provisioningTreeOf)
    extTree: [],                // OEM image route, from Validate on: one item per machine with its extensions
    stepIndex: new Map(),       // key -> { node, section, parentKey }
    focusKey: { provisioning: null, validation: null, extensions: null, deployment: null, update: null },
    selectedKey: null,
    currentKey: null,
    lastAutoKey: null,
    lastAnnounced: { phase: null, status: null, tailer: null },
    errors: new Map(),          // banner messages by source
    bannerDismissed: '',
    conn: 'connecting'
  };

  var $ = function (id) { return document.getElementById(id); };

  // ------------------------------------------------------------------ helpers

  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  function arr(v) { return Array.isArray(v) ? v : []; }
  function str(v) { return v === null || v === undefined ? '' : String(v); }

  function normStatus(s) {
    var k = str(s).toLowerCase().replace(/[\s_-]+/g, '');
    if (!k) return 'notstarted';
    if (k === 'notstarted' || k === 'pending' || k === 'queued' || k === 'waiting') return 'notstarted';
    if (k === 'running' || k === 'inprogress' || k === 'started' || k === 'executing' || k === 'accepted' ||
        k === 'updating' || k === 'creating' || k === 'provisioning') return 'running';
    if (k === 'success' || k === 'succeeded' || k === 'completed' || k === 'complete' || k === 'done') return 'success';
    if (k === 'error' || k === 'failed' || k === 'failure' || k === 'canceled' || k === 'cancelled') return 'error';
    if (k === 'skipped' || k === 'notapplicable') return 'skipped';
    return 'unknown';
  }

  function normPhase(p) {
    var k = str(p).toLowerCase();
    return PHASES.indexOf(k) >= 0 ? k : (k ? k : 'unknown');
  }

  function parseTime(v) {
    if (v === null || v === undefined || v === '') return NaN;
    if (typeof v === 'number') return v < 1e12 ? v * 1000 : v;
    var s = String(v);
    // ASP.NET style /Date(1696000000000)/
    var m = /\/Date\((-?\d+)/.exec(s);
    if (m) return Number(m[1]);
    var t = Date.parse(s);
    if (isNaN(t) && /^\d{4}-\d{2}-\d{2} \d/.test(s)) t = Date.parse(s.replace(' ', 'T'));
    return t;
  }

  function fmtDuration(sec) {
    if (sec === null || sec === undefined || isNaN(sec) || sec < 0) return '';
    sec = Math.floor(sec);
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    if (h > 0) return h + 'h ' + m + 'm ' + s + 's';
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
  }

  function pad(n, w) { n = String(n); while (n.length < (w || 2)) n = '0' + n; return n; }
  function fmtClock(t) {
    if (isNaN(t)) return '';
    var d = new Date(t);
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }
  function fmtDateTime(t) {
    if (isNaN(t)) return '';
    try { return new Date(t).toLocaleString(); } catch (e) { return new Date(t).toISOString(); }
  }
  // "Now" for timers, durations and "last poll": the wall clock when live, the playback position in a replay.
  var clockSource = null;
  function setClock(fn) { clockSource = typeof fn === 'function' ? fn : null; }
  function nowMs() { return clockSource ? clockSource() : Date.now(); }

  function fmtAgo(t) {
    if (isNaN(t)) return '';
    var s = Math.max(0, Math.round((nowMs() - t) / 1000));
    if (s < 5) return 'just now';
    if (s < 60) return s + ' s ago';
    if (s < 3600) return Math.floor(s / 60) + ' min ago';
    return fmtDuration(s) + ' ago';
  }

  function basename(p) {
    var s = str(p);
    var i = Math.max(s.lastIndexOf('\\'), s.lastIndexOf('/'));
    return i >= 0 ? s.slice(i + 1) : s;
  }

  // "left:5%;width:10px" through the CSS object model: the page's Content-Security-Policy has no 'unsafe-inline'.
  function setStyleText(e, text) {
    String(text).split(';').forEach(function (decl) {
      var i = decl.indexOf(':');
      if (i > 0) e.style.setProperty(decl.slice(0, i).trim(), decl.slice(i + 1).trim());
    });
  }

  // A link from the back end or from data is followed only when it is an https URL on a known documentation host.
  var LINK_HOSTS = ['azurelocal.cloud', 'learn.microsoft.com', 'github.com'];
  function safeLink(url) {
    var u;
    try { u = new URL(String(url)); } catch (e) { return ''; }
    if (u.protocol !== 'https:' || u.username || u.password) return '';
    if (LINK_HOSTS.indexOf(u.hostname.toLowerCase()) < 0) return '';
    return u.href;
  }

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) {
      for (var k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
        var v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
        else if (k === 'style') setStyleText(e, v);
        else if (/^on/i.test(k)) continue;   // data never becomes an event handler
        else e.setAttribute(k, v === true ? '' : v);
      }
    }
    if (children) {
      for (var i = 0; i < children.length; i++) {
        var c = children[i];
        if (c === null || c === undefined || c === false) continue;
        e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
      }
    }
    return e;
  }

  function announce(msg) {
    var a = $('announcer');
    a.textContent = '';
    // a short delay makes screen readers pick up repeated messages
    setTimeout(function () { a.textContent = msg; }, 60);
  }

  // ------------------------------------------------------------------ icons (static inline SVG)

  var ICON = {
    success: '<svg class="si si-success" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="7" fill="currentColor"/><path d="m4.8 8.2 2.1 2.1 4.3-4.5" fill="none" stroke="var(--surface)" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    error: '<svg class="si si-error" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="7" fill="currentColor"/><path d="m5.6 5.6 4.8 4.8m0-4.8-4.8 4.8" stroke="var(--surface)" stroke-width="1.7" stroke-linecap="round"/></svg>',
    running: '<svg class="si si-running" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-opacity=".25" stroke-width="2"/><path class="spin" d="M8 1.8a6.2 6.2 0 0 1 6.2 6.2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="8" cy="8" r="2" fill="currentColor"/></svg>',
    skipped: '<svg class="si si-skipped" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="m5.8 5.6 2.6 2.4-2.6 2.4m3-4.8 2.6 2.4-2.6 2.4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    notstarted: '<svg class="si si-notstarted" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-dasharray="2.4 2.2"/></svg>',
    unknown: '<svg class="si si-unknown" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6.3 6.3a1.8 1.8 0 1 1 2.5 1.6c-.5.3-.8.6-.8 1.2v.3M8 11.4v.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
    caret: '<svg class="caret" viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="m6 3.5 4.5 4.5L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    close: '<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="m4 4 8 8m0-8-8 8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>'
  };
  function icon(status) { return ICON[status] || ICON.unknown; }

  // ------------------------------------------------------------------ log store (pure; also run by tests/WebLogic.Tests.ps1 under Node)
  //
  // Lines are kept in seq order and deduplicated by seq for one back-end instance (server id). The catch-up cursor
  // (catchupSeq: every line up to it has been fetched through /api/logs, or fell out of the ring buffer) is kept apart
  // from the highest seq seen (liveSeq), so a live line that arrives before a catch-up answer never makes the page
  // skip the lines in between. A live stream announces where it starts (SSE 'hello' { server, since }); once the
  // catch-up cursor reaches that point the stream continues it without gaps and moves the cursor too.

  function createLogStore(max) {
    var s = { max: max || MAX_STORED_LINES };
    logStoreReset(s, null);
    return s;
  }

  function logStoreReset(store, serverId) {
    store.serverId = serverId || null;
    store.lines = [];
    store.seqs = new Set();
    store.floor = 0;            // lines below this seq were trimmed; never take them again
    store.catchupSeq = 0;
    store.liveSeq = 0;
    store.streamBase = null;    // seq the current live stream continues from (null: unknown)
    store.streamMax = 0;
    store.fileCounts = new Map();
  }

  function advanceCatchup(store) {
    if (store.streamBase !== null && store.streamBase <= store.catchupSeq && store.streamMax > store.catchupSeq) {
      store.catchupSeq = store.streamMax;
    }
  }

  function logStoreStreamOpened(store, since, serverId) {
    if (serverId && store.serverId && serverId !== store.serverId) return { restart: true };
    if (serverId && !store.serverId) store.serverId = serverId;
    var n = Number(since);
    store.streamBase = since === null || since === undefined || isNaN(n) ? null : n;
    store.streamMax = store.streamBase === null ? 0 : n;
    advanceCatchup(store);
    return { restart: false };
  }

  function logStoreStreamClosed(store) {
    store.streamBase = null;
    store.streamMax = 0;
  }

  function seqKey(l) { return isNaN(l.seq) ? Infinity : l.seq; }
  function bySeq(a, b) { return seqKey(a) - seqKey(b); }

  function normLine(l) {
    var text = str(l.text !== undefined ? l.text : l.message);
    var seq = typeof l.seq === 'number' ? l.seq : (l.seq === undefined || l.seq === null || l.seq === '' ? NaN : Number(l.seq));
    var src = str(l.timeSource).toLowerCase();
    if (src !== 'line' && src !== 'file') src = 'received';
    // Back ends before event-time parsing sent only 'time', which was the receive time.
    var received = l.received !== undefined && l.received !== null && l.received !== '' ? str(l.received) : str(l.time);
    return { seq: seq, time: str(l.time), t: parseTime(l.time), received: received, r: parseTime(received), timeSource: src,
      file: str(l.file), level: normLevel(l.level, text), text: text, lc: null };
  }

  // meta: { server: id or undefined, source: 'catchup' | 'live', lastSeq: /api/logs lastSeq }
  // Returns { restart, fresh[], outOfOrder, trimmed, newFile }. restart: the batch is from another back-end instance;
  // the caller resets the store and fetches /api/logs?since=0.
  function logStoreIngest(store, raw, meta) {
    meta = meta || {};
    var out = { restart: false, fresh: [], outOfOrder: false, trimmed: false, newFile: false };
    if (meta.server && store.serverId && meta.server !== store.serverId) { out.restart = true; return out; }
    if (meta.server && !store.serverId) store.serverId = meta.server;
    var batchMax = 0;
    arr(raw).forEach(function (l) {
      if (!isObj(l)) return;
      var line = normLine(l);
      if (!isNaN(line.seq)) {
        if (line.seq > batchMax) batchMax = line.seq;
        if (line.seq < store.floor || store.seqs.has(line.seq)) return;
        store.seqs.add(line.seq);
        if (line.seq < store.liveSeq) out.outOfOrder = true;
        else store.liveSeq = line.seq;
      }
      if (line.file) {
        var c = store.fileCounts.get(line.file) || 0;
        if (!c) out.newFile = true;
        store.fileCounts.set(line.file, c + 1);
      }
      store.lines.push(line);
      out.fresh.push(line);
    });
    if (meta.source === 'catchup') {
      var last = meta.lastSeq === null || meta.lastSeq === undefined || meta.lastSeq === '' ? NaN : Number(meta.lastSeq);
      var cover = isNaN(last) ? batchMax : Math.max(last, batchMax);
      if (cover > store.catchupSeq) store.catchupSeq = cover;
    } else if (meta.source === 'live' && store.streamBase !== null && batchMax > store.streamMax) {
      store.streamMax = batchMax;
    }
    advanceCatchup(store);
    if (out.outOfOrder) {
      store.lines.sort(bySeq);
      out.fresh.sort(bySeq);
    }
    if (store.lines.length > store.max) {
      var removed = store.lines.splice(0, store.lines.length - store.max + Math.min(1000, Math.floor(store.max / 10)));
      removed.forEach(function (l) {
        if (!isNaN(l.seq)) store.seqs.delete(l.seq);
        if (l.file) {
          var n = (store.fileCounts.get(l.file) || 0) - 1;
          if (n > 0) store.fileCounts.set(l.file, n); else store.fileCounts.delete(l.file);
        }
      });
      var first = store.lines[0];
      if (first && !isNaN(first.seq)) store.floor = first.seq;
      out.trimmed = true;
    }
    return out;
  }

  // The time window of a step for the log filter (+/-1 s); running or unfinished steps are open-ended.
  function stepWindowOf(node) {
    if (!isObj(node)) return null;
    var a = parseTime(node.start), b = parseTime(node.end);
    if (isNaN(a)) return null;
    var running = normStatus(node.status) === 'running';
    return { start: a - 1000, end: running || isNaN(b) ? Infinity : b + 1000, name: str(node.name), rawStart: a, rawEnd: running ? NaN : b };
  }

  function windowSignature(w) { return w ? w.start + '|' + w.end : ''; }

  // Step filter. A line with its own timestamp (timeSource 'line') matches by event time. A line timed by its file
  // name ('file') matches by that time or by when it was received. A line with no timestamp ('received') is
  // approximate: it matches only when Sonar received it inside the step window.
  function lineInWindow(l, win) {
    if (!win) return true;
    function inside(t) { return !isNaN(t) && t >= win.start && t <= win.end; }
    if (l.timeSource === 'line') return inside(l.t);
    if (l.timeSource === 'file') return inside(l.t) || inside(l.r);
    return inside(isNaN(l.r) ? l.t : l.r);
  }

  // What a new state means for an active step filter: 'none' (no filter), 'clear' (the step is gone),
  // 'rerender' (its window changed, for example running -> finished) or 'keep'.
  function stepFilterChange(filterKey, stillIndexed, windowBefore, windowAfter) {
    if (!filterKey) return 'none';
    if (!stillIndexed) return 'clear';
    return windowBefore !== windowAfter ? 'rerender' : 'keep';
  }

  // Which machine and which ZTP stage a log line belongs to. Only the ZTP event lines say ("<time> [ztp] <node>
  // <State>: ..."); a line read from a node's log folder belongs to the node Sonar reads (the seed node) and names no
  // machine itself. The stage follows the event's state: Device*, Management* / Network*, Bios*.
  var ZTP_LINE = /^(?:\S+\s+)?\[ztp\]\s+(\S+)\s+([A-Za-z]+)/;
  function ztpStageOfState(state) {
    if (/^Device/.test(state)) return 'device';
    if (/^(Management|Network)/.test(state)) return 'network';
    if (/^Bios/.test(state)) return 'restore';
    return '';
  }
  function lineScope(l) {
    if (l.scope) return l.scope;
    var m = l.file === 'ztp-events' || /^(?:\S+\s+)?\[ztp\]\s/.test(str(l.text)) ? ZTP_LINE.exec(str(l.text)) : null;
    l.scope = m ? { node: m[1], stage: ztpStageOfState(m[2]) } : { node: '', stage: '' };
    return l.scope;
  }

  // Is the line inside the filter scope { node, stage } and the optional step time window? A machine filter keeps the
  // ZTP lines of that machine, and the node-log lines when that machine is the one Sonar reads (seed).
  function lineInScope(l, f, win, seed) {
    var sc = lineScope(l);
    if (f && f.node) {
      var want = str(f.node).toLowerCase();
      if (sc.node) { if (sc.node.toLowerCase() !== want) return false; }
      else if (!seed || str(seed).toLowerCase() !== want) return false;
    }
    if (f && f.stage && sc.stage !== f.stage) return false;
    if (win && !lineInWindow(l, win)) return false;
    return true;
  }

  // File filter options: the files the tailer reports now plus the files of the lines still held, sorted by name.
  function fileOptionList(reported, fileCounts) {
    var set = new Set();
    arr(reported).forEach(function (p) { if (p) set.add(String(p)); });
    if (fileCounts) fileCounts.forEach(function (n, p) { if (n > 0 && p) set.add(p); });
    return Array.from(set).sort(function (a, b) { return basename(a).localeCompare(basename(b)) || a.localeCompare(b); });
  }

  // The file selection survives only while the file is still offered.
  function keptFileSelection(list, selected) {
    return selected && arr(list).indexOf(selected) >= 0 ? selected : '';
  }

  // ------------------------------------------------------------------ provisioning (pure; also run by tests under Node)

  function phaseLabel(p) {
    var k = str(p).toLowerCase();
    return PHASE_LABEL[k] || (k ? k.charAt(0).toUpperCase() + k.slice(1) : '');
  }

  // The header chip: the phase, and for a failed run the phase that failed ("Failed: Arc registration").
  function phaseChipText(state) {
    if (!isObj(state)) return '—';
    var p = normPhase(state.phase);
    if (p === 'unknown') return 'unknown';
    var active = str(state.activePhase).toLowerCase();
    if (p === 'failed' && active && active !== 'failed') return 'Failed: ' + phaseLabel(active);
    // Every machine is done and no cluster deployment has started yet: say so instead of the phase name. On the
    // simplified route ZTP hands over to OS configuration, not to Validate.
    if ((p === 'provisioning' || p === 'arc-registration') && readyForValidate(state)) return 'Ready for Validate';
    if (p === 'provisioning' && ztpComplete(state)) return 'ZTP complete';
    return phaseLabel(p);
  }

  // OEM image route lifecycle keys (back end) as chip text; other routes show the lifecycle as reported.
  var OEM_LIFECYCLE = {
    NotStarted: 'Not started', UpdatingOsImage: 'Updating OS image', Bootstrapping: 'Bootstrapping',
    Registered: 'Registered (Connected)', Failed: 'Failed', Unknown: 'Unknown'
  };
  function lifecycleLabel(route, lifecycle) {
    var lc = str(lifecycle) || 'Unknown';
    return str(route) === 'oem-image' && OEM_LIFECYCLE[lc] ? OEM_LIFECYCLE[lc] : lc;
  }

  // A node-status group (OS image update or Bootstrap, OEM image route) as { status, done, total, current, state }.
  function stepGroupOf(g) {
    if (!isObj(g)) return null;
    return { status: normStatus(g.status), done: Number(g.done) || 0, total: Number(g.total) || 0,
      current: str(g.current), state: str(g.state) };
  }

  // "Rebooting / unreachable since <time>" while the node probe cannot reach the node; '' otherwise.
  function probeNote(probe, fmt) {
    if (!isObj(probe) || str(probe.state) !== 'unreachable') return '';
    var t = parseTime(probe.unreachableSince);
    return 'Rebooting / unreachable since ' + (isNaN(t) ? 'the last poll' : (fmt ? fmt(t) : str(probe.unreachableSince)));
  }

  // One tree item per machine, its children the machine's provisioning tree (lifecycle stages + ProvisionOs job, or
  // on the OEM image route: OS image update, Bootstrap, Azure registration). The item carries the machine summary in
  // .prov for the panel.
  function provisioningTreeOf(state) {
    var prov = isObj(state) && isObj(state.provisioning) ? state.provisioning : null;
    if (!prov) return [];
    return arr(prov.nodes).filter(isObj).map(function (n) {
      var exts = arr(n.extensions).filter(isObj);
      var route = str(n.route || prov.route);
      return {
        id: str(n.name), name: str(n.name), description: str(n.lifecycleMessage),
        status: normStatus(n.status), start: n.start || null, end: n.end || null,
        errors: arr(n.errors).map(str).filter(Boolean), children: arr(n.tree),
        prov: {
          route: route, lifecycle: str(n.lifecycle) || 'Unknown', lifecycleLabel: lifecycleLabel(route, n.lifecycle),
          percent: typeof n.percent === 'number' ? Math.max(0, Math.min(100, n.percent)) : null,
          reportedPercent: typeof n.reportedPercent === 'number' ? n.reportedPercent : null,
          arcMachineName: str(n.arcMachineName), arcSource: str(n.arcSource), arcStatus: str(n.arcStatus),
          edgeMachineName: str(n.edgeMachineName),
          extensionsReady: exts.filter(function (e) { return normStatus(e.status) === 'success'; }).length,
          extensionsTotal: exts.length,
          update: stepGroupOf(n.update), bootstrap: stepGroupOf(n.bootstrap),
          probe: isObj(n.probe) ? n.probe : null, ztp: isObj(n.ztp) ? n.ztp : null
        }
      };
    });
  }

  // OEM image route, once Validate has started: one item per machine with its mandatory extensions as children.
  function extensionsTreeOf(state) {
    var ext = isObj(state) && isObj(state.extensions) ? state.extensions : null;
    if (!ext || !ext.shown) return [];
    return arr(ext.nodes).filter(isObj).map(function (n) {
      var ready = Number(n.ready) || 0, total = Number(n.total) || arr(n.extensions).length;
      return {
        id: 'ext:' + str(n.name), name: str(n.name), description: 'Extensions ' + ready + ' of ' + total + ' succeeded',
        status: normStatus(n.status), errors: arr(n.errors).map(str).filter(Boolean), children: arr(n.tree)
      };
    });
  }

  // OEM image route: every machine registered and no validation yet.
  function readyForValidate(state) {
    return isObj(state) && isObj(state.provisioning) && state.provisioning.readyForValidate === true;
  }

  // Simplified route with the ZTP event file: every machine provisioned, its management address on the management NIC
  // (ZTP Network stage) and its final BIOS values back (Restore, or none to restore). ZTP is done; OS configuration is next.
  function ztpComplete(state) {
    return isObj(state) && isObj(state.provisioning) && state.provisioning.ztpComplete === true;
  }

  // Machines by status for the section head: { total, ready, failed, running, waiting }.
  function provisioningSummary(tree) {
    var s = { total: 0, ready: 0, failed: 0, running: 0, waiting: 0 };
    arr(tree).forEach(function (n) {
      if (!isObj(n)) return;
      s.total++;
      var st = normStatus(n.status);
      if (st === 'success') s.ready++; else if (st === 'error') s.failed++; else if (st === 'running') s.running++; else s.waiting++;
    });
    return s;
  }

  // The provisioning section is collapsed once (when validation or deployment starts); the user can open it again.
  function provisioningCollapse(activePhase, alreadyCollapsed) {
    var a = str(activePhase).toLowerCase();
    if (a === 'validation' || a === 'deployment') return alreadyCollapsed ? 'keep' : 'collapse';
    if (a === 'provisioning' || a === 'arc-registration') return alreadyCollapsed ? 'expand' : 'keep';
    return 'keep';
  }

  // Where an Arc machine name came from, for the tooltip.
  function arcSourceText(src) {
    return {
      config: 'from nodes[].arcMachineName in the config',
      'edgeMachine.job': 'from the edge machine (ProvisionOs target: provisioningRequest.onboardingConfiguration.resourceId)',
      edgeMachine: 'from the edge machine (properties.arcMachineResourceId)',
      nodeName: 'the node name (Invoke-AzStackHciArcInitialization names the Arc machine after the host)'
    }[str(src)] || '';
  }

  // ------------------------------------------------------------------ modes and summary (pure; also run by tests under Node)
  //
  // The page shows one "mode" at a time: Provisioning, Validate, Deployment, Update, Health. A mode maps onto the phase the
  // back end reports (phase / activePhase) and the section of the state that holds its data (provisioning, validation,
  // deployment, update). Azure's raw states are turned into plain words here; the raw value goes into a tooltip.

  var MODE_IDS = ['prov', 'validate', 'deploy', 'update', 'health'];
  var MODE_OF_PHASE = {
    provisioning: 'prov', 'arc-registration': 'prov', validation: 'validate', deployment: 'deploy', update: 'update',
    done: 'health', 'post-deployment': 'health', 'add-node': 'health', repair: 'health'
  };
  var MODE_TITLE = { validate: 'Validate', deploy: 'Deployment', update: 'Update', health: 'Health' };

  // The provisioning route the run follows: the one the state names, else what the phase says (Arc registration is the
  // OEM image route's machine phase).
  function provRouteOf(state) {
    var r = isObj(state) && isObj(state.provisioning) ? str(state.provisioning.route) : '';
    if (!r && isObj(state) && (normPhase(state.phase) === 'arc-registration' || str(state.activePhase).toLowerCase() === 'arc-registration')) return 'oem-image';
    return r;
  }
  function provMachines(state) { return isObj(state) && isObj(state.provisioning) ? arr(state.provisioning.nodes).filter(isObj) : []; }

  // Provisioning is named after its route: ZTP on the simplified route, the OS image on the OEM image route.
  function modeName(id, route) {
    if (id === 'prov') return route === 'oem-image' ? 'Provisioning (OS image)' : 'Provisioning (ZTP)';
    return MODE_TITLE[id] || id;
  }

  // The mode that is happening now. A failed run stays on the mode that failed; a finished one is Health.
  function activeModeId(state) {
    if (!isObj(state)) return 'prov';
    var p = normPhase(state.phase), act = str(state.activePhase).toLowerCase();
    var key = p === 'failed' ? (act || 'provisioning') : (p === 'done' ? 'done' : (act || p));
    return MODE_OF_PHASE[key] || 'prov';
  }

  // Steps done, the step that runs now (1-based) and its name, over the main steps of a tree.
  function stepProgress(tree) {
    var steps = mainSteps(tree), done = 0, cur = -1;
    steps.forEach(function (n, i) {
      var st = normStatus(n.status);
      if (st === 'success' || st === 'skipped') done++;
      if (cur < 0 && st === 'running') cur = i;
    });
    if (cur < 0 && done < steps.length) cur = done;
    return { total: steps.length, done: done, current: cur >= 0 ? cur + 1 : 0, name: cur >= 0 && steps[cur] ? str(steps[cur].name) : '' };
  }

  function treeEndMax(nodes) {
    var max = NaN;
    (function walk(list) {
      arr(list).forEach(function (n) {
        if (!isObj(n)) return;
        var b = parseTime(n.end);
        if (!isNaN(b) && (isNaN(max) || b > max)) max = b;
        walk(n.children);
      });
    })(nodes);
    return max;
  }

  var MODE_WHEN = {
    validate: { simplified: 'Starts after ZTP and OS configuration are done', 'oem-image': 'Starts when every machine is registered', '': 'Starts after the machines are ready' },
    deploy: 'Starts after validation passes',
    update: 'Available after the cluster is deployed; starts when Azure reports an update',
    health: 'Available after the cluster is deployed'
  };
  function modeWhen(id, route) {
    if (id === 'validate') return MODE_WHEN.validate[route] || MODE_WHEN.validate[''];
    return MODE_WHEN[id] || '';
  }

  // The five tiles: { id, name, status ok|run|idle|err, line, tip, hidden }. A waiting tile has no state line; its tip
  // says when it starts.
  function modeStates(state) {
    var s = isObj(state) ? state : {};
    var route = provRouteOf(s), machines = provMachines(s);
    var active = activeModeId(s), order = MODE_IDS.indexOf(active), phase = normPhase(s.phase);
    var out = [];
    function tile(id, status, line, hidden) {
      out.push({ id: id, name: modeName(id, route), status: status, line: line || '', tip: status === 'idle' ? modeWhen(id, route) : '', hidden: !!hidden });
    }

    var psum = provisioningSummary(provisioningTreeOf(s));
    var unit = route === 'oem-image' ? 'registered' : 'ready';
    var counted = psum.ready + ' of ' + psum.total + ' machines ' + unit;
    var pst, pline = '';
    if (psum.failed) { pst = 'err'; pline = psum.ready + ' of ' + psum.total + ' ' + unit + ', ' + psum.failed + ' failed'; }
    else if (psum.total && psum.ready === psum.total) { pst = 'ok'; pline = ztpComplete(s) ? 'ZTP complete' : counted; }
    else if (order > 0 || phase === 'done') { pst = 'ok'; pline = psum.total ? counted : 'Done'; }
    else if (active === 'prov') { pst = 'run'; pline = psum.total ? counted : 'Waiting for the machines'; }
    else pst = 'idle';
    tile('prov', pst, pline, !machines.length && !route && active !== 'prov');

    [['validate', s.validation, 1], ['deploy', s.deployment, 2]].forEach(function (x) {
      var sec = isObj(x[1]) ? x[1] : null, st = sec ? sectionStatus(sec) : 'notstarted', pr = stepProgress(sec && sec.tree);
      if (st === 'success') tile(x[0], 'ok', x[0] === 'validate' ? 'Passed' : 'Done');
      else if (st === 'running') tile(x[0], 'run', pr.total ? 'Step ' + pr.current + ' of ' + pr.total : 'Running');
      else if (st === 'error') tile(x[0], 'err', 'Failed');
      else if (order > x[2] || phase === 'done') tile(x[0], 'ok', x[0] === 'validate' ? 'Passed' : 'Done');
      else tile(x[0], 'idle');
    });

    var upd = isObj(s.update) ? s.update : null, ust = upd ? sectionStatus(upd) : 'notstarted', upr = stepProgress(upd && upd.tree);
    if (ust === 'success') tile('update', 'ok', 'Done');
    else if (ust === 'running') tile('update', 'run', upr.total ? 'Step ' + upr.current + ' of ' + upr.total : 'Running');
    else if (ust === 'error') tile('update', 'err', 'Failed');
    else tile('update', 'idle');

    var nodes = arr(s.nodes).filter(isObj);
    var connected = nodes.filter(function (n) { return str(n.arcStatus).toLowerCase() === 'connected'; }).length;
    if (phase === 'done' || active === 'health') {
      if (nodes.length && connected < nodes.length) tile('health', 'err', connected + ' of ' + nodes.length + ' connected');
      else tile('health', 'ok', nodes.length ? connected + ' of ' + nodes.length + ' connected' : 'Cluster deployed');
    } else tile('health', 'idle');
    return out;
  }

  // Azure's raw Arc status in plain words.
  function arcInfo(raw) {
    var k = str(raw).toLowerCase();
    if (k === 'connected') return { text: 'Arc ● Connected', kind: 'ok', raw: str(raw) };
    if (k === 'expired') return { text: 'Arc ● Expired', kind: 'warn', raw: str(raw) };
    if (k === 'error') return { text: 'Arc ✕ Error', kind: 'err', raw: str(raw) };
    return { text: 'Arc ○ not connected yet', kind: 'idle', raw: str(raw) || 'no Arc status yet' };
  }

  // A machine's lifecycle (simplified route) or registration stage (OEM image route) in plain words:
  // [text, activity (what it is doing, for the headline), kind].
  var LIFECYCLE_PLAIN = {
    notcreated: ['Waiting to start', 'waiting to start', 'idle'],
    creating: ['Being created in Azure', 'being created in Azure', 'run'],
    awaitingconnection: ['Waiting to connect to Azure', 'waiting to connect to Azure', 'run'],
    provisioning: ['Registering with Azure', 'registering with Azure', 'run'],
    readyforos: ['Ready to install the OS', 'getting ready to install the OS', 'run'],
    installingos: ['Installing the OS', 'installing the OS', 'run'],
    provisioned: ['Provisioned', 'finishing ZTP', 'ok'],
    notstarted: ['Waiting to start', 'waiting to start', 'idle'],
    updatingosimage: ['Updating the OS image', 'updating its OS image', 'run'],
    bootstrapping: ['Bootstrapping', 'bootstrapping', 'run'],
    registered: ['Registered', 'registered', 'ok'],
    failed: ['Failed', 'failed', 'err'],
    unknown: ['Status unknown', 'in an unknown state', 'idle']
  };
  function lifecyclePlain(lifecycle, status, isZtpComplete) {
    var k = str(lifecycle).toLowerCase().replace(/[\s_-]+/g, '');
    var p = LIFECYCLE_PLAIN[k] || (/fail/.test(k) ? LIFECYCLE_PLAIN.failed : LIFECYCLE_PLAIN.unknown);
    var r = { text: p[0], activity: p[1], kind: p[2] };
    if (k === 'provisioned' && isZtpComplete) { r.text = 'ZTP complete'; r.activity = 'complete'; }
    else if (k === 'provisioned' && status !== 'success') { r.text = 'Provisioned, finishing ZTP'; r.kind = 'run'; }
    if (status === 'error') { r.text = /fail/.test(k) ? 'Failed' : 'Failed: ' + p[1]; r.kind = 'err'; }
    return r;
  }

  function firstLine(text, max) {
    var s = str(text).split(/\r?\n/)[0].trim();
    max = max || 120;
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  }

  // The one thing a machine waits on, or what comes next.
  function machineWaits(n, route, isZtpDone) {
    var p = n.prov || {}, st = normStatus(n.status), lc = str(p.lifecycle).toLowerCase();
    if (st === 'error') return firstLine(arr(n.errors)[0] || n.description || 'See the steps for the error');
    if (st === 'success') return route === 'oem-image' ? 'Next: Validate' : (isZtpDone || (p.ztp && p.ztp.complete) ? 'Next: OS configuration' : 'Next: finish ZTP');
    if (isObj(p.probe) && str(p.probe.state) === 'unreachable') return 'Rebooting; not reachable right now';
    if (st === 'notstarted') return 'Waiting to start';
    if (route === 'oem-image') {
      if (p.update && p.update.status === 'running') return 'Waiting on the OS image update' + (p.update.current ? ' (' + p.update.current + ')' : '');
      if (p.bootstrap && p.bootstrap.status === 'running') return 'Waiting on bootstrap' + (p.bootstrap.current ? ': ' + p.bootstrap.current : '');
      return 'Waiting on Azure';
    }
    var z = p.ztp;
    if (lc === 'provisioned' && z) {
      if (z.network && normStatus(z.network.status) !== 'success') return 'Waiting on ZTP: management address check';
      if (z.restore && ['success', 'skipped'].indexOf(normStatus(z.restore.status)) < 0) return 'Waiting on ZTP: BIOS restore';
      return 'Waiting on ZTP: handoff';
    }
    if (lc === 'notcreated' && z && z.device && normStatus(z.device.status) === 'running') return 'Waiting on the node: management address';
    return 'Waiting on Azure';
  }

  // The machines Sonar knows: the config's nodes merged with the state's nodes (Arc status, Arc machine name).
  function machineList(state, config) {
    var byName = new Map();
    arr(config && config.nodes).forEach(function (n) {
      if (isObj(n) && n.name) byName.set(String(n.name).toLowerCase(), { name: String(n.name), seed: !!n.seed });
    });
    arr(state && state.nodes).forEach(function (n) {
      if (!isObj(n) || !n.name) return;
      var k = String(n.name).toLowerCase(), cur = byName.get(k) || { name: String(n.name), seed: !!n.seed };
      cur.arcStatus = n.arcStatus; cur.lastStatusChange = n.lastStatusChange; cur.arcMachineName = n.arcMachineName; cur.arcSource = n.arcSource;
      byName.set(k, cur);
    });
    return Array.from(byName.values());
  }

  // The summary box for one mode: { id, title, status, chip { kind, text }, headline, startedAt, endedAt, when, cards[] }.
  // Card: { name, seed, state, kind, tip, arc { text, kind, raw }, waits, progress, status }. The card carries the full
  // machine name, never a shortened one.
  function summaryFor(state, modeId, config) {
    var s = isObj(state) ? state : {};
    var route = provRouteOf(s), modes = modeStates(s);
    var me = modes.filter(function (m) { return m.id === modeId; })[0] || modes[0];
    var chipText = { ok: 'Done', run: 'Running', err: 'Failed', idle: 'Waiting' };
    var out = { id: me.id, title: me.name, status: me.status, chip: { kind: me.status, text: chipText[me.status] }, headline: '',
      startedAt: NaN, endedAt: NaN, when: me.tip, cards: [] };
    var machines = machineList(s, config);

    if (me.id === 'prov') {
      var tree = provisioningTreeOf(s), sum = provisioningSummary(tree), zDone = ztpComplete(s);
      var starts = tree.map(function (n) { return parseTime(n.start); }).filter(function (t) { return !isNaN(t); });
      var ends = tree.map(function (n) { return parseTime(n.end); }).filter(function (t) { return !isNaN(t); });
      if (starts.length) out.startedAt = Math.min.apply(null, starts);
      if (me.status === 'ok' && ends.length === tree.length && ends.length) out.endedAt = Math.max.apply(null, ends);
      out.cards = tree.map(function (n) {
        var p = n.prov, pl = lifecyclePlain(p.lifecycle, n.status, p.ztp && p.ztp.complete === true);
        return {
          name: n.name, seed: false, state: pl.text, kind: pl.kind, status: n.status, activity: pl.activity,
          tip: 'Azure says: ' + (p.lifecycle || 'Unknown') + (n.description ? ' (' + firstLine(n.description, 160) + ')' : ''),
          arc: arcInfo(p.arcStatus), waits: machineWaits(n, route, zDone), progress: n.status === 'running' && p.percent !== null ? p.percent : null
        };
      });
      var unit = route === 'oem-image' ? 'registered' : 'ready';
      var failed = out.cards.filter(function (c) { return c.status === 'error'; });
      var busy = out.cards.filter(function (c) { return c.status === 'running'; });
      var head = sum.ready + ' of ' + sum.total + ' machines ' + unit;
      if (!tree.length) out.headline = route ? 'No machines reported yet' : 'Waiting for the machines to appear in Azure';
      else if (readyForValidate(s)) out.headline = 'All ' + sum.total + ' machines are registered. Next: Validate';
      else if (zDone) out.headline = 'ZTP is complete: all ' + sum.total + ' machines are provisioned. Next: OS configuration';
      else if (failed.length) out.headline = head + ': ' + failed[0].name + ' is blocked (' + failed[0].waits + ')' + (failed.length > 1 ? ' and ' + (failed.length - 1) + ' more failed' : '');
      else if (busy.length) out.headline = head + ': ' + busy[0].name + ' is ' + busy[0].activity + (busy.length > 1 ? ' and ' + (busy.length - 1) + ' more ' + (busy.length === 2 ? 'is' : 'are') + ' working' : '');
      else out.headline = head;
      return out;
    }

    var sec = me.id === 'validate' ? s.validation : me.id === 'deploy' ? s.deployment : me.id === 'update' ? s.update : null;
    var secTree = isObj(sec) ? arr(sec.tree) : [];
    var pr = stepProgress(secTree), word = { validate: 'Validation', deploy: 'Deployment', update: 'Update' }[me.id];
    if (me.id !== 'health') {
      var a = treeStartMin(secTree), b = treeEndMax(secTree);
      if (!isNaN(a)) out.startedAt = a;
      if (me.status === 'ok' && !isNaN(b)) out.endedAt = b;
    }
    var past = { validate: 'Validation passed', deploy: 'Deployment finished', update: 'Update finished' };
    var cur = isObj(s.current) && str(s.current.stepName) && MODE_OF_PHASE[str(s.current.phase)] === me.id ? str(s.current.stepName) : pr.name;
    if (me.id === 'health') {
      var conn = machines.filter(function (m) { return str(m.arcStatus).toLowerCase() === 'connected'; }).length;
      out.headline = me.status === 'idle' ? me.tip : (machines.length ? 'Cluster deployed: ' + conn + ' of ' + machines.length + ' machines are connected to Azure Arc' : 'Cluster deployed');
    } else if (me.status === 'ok') out.headline = past[me.id];
    else if (me.status === 'err') {
      var bad = firstError(secTree);
      out.headline = word + ' failed' + (bad ? ' at ' + str(bad.name) + (arr(bad.errors)[0] ? ': ' + firstLine(arr(bad.errors)[0], 160) : '') : '');
    } else if (me.status === 'run') {
      out.headline = word + ' is running' + (pr.total ? ': step ' + pr.current + ' of ' + pr.total : '') + (cur ? ' (' + cur + ')' : '');
    } else out.headline = me.tip;

    var verb = { validate: ['Validated', 'Being validated', 'Waiting'], deploy: ['Deployed', 'Taking part', 'Waiting'],
      update: ['Updated', 'Being updated', 'Waiting'] }[me.id];
    var pct = pr.total ? Math.round(100 * pr.done / pr.total) : null;
    var waitsFor = { validate: 'the machines to be ready', deploy: 'validation', update: 'an update from Azure' }[me.id];
    out.cards = machines.map(function (m) {
      var arc = arcInfo(m.arcStatus);
      var card = { name: m.name, seed: !!m.seed, arc: arc, progress: null, waits: '', tip: '', status: me.status, kind: me.status };
      if (me.id === 'health') {
        card.state = arc.kind === 'ok' ? 'Connected' : (arc.kind === 'idle' ? 'Not connected' : str(m.arcStatus));
        card.kind = arc.kind === 'ok' ? 'ok' : (arc.kind === 'idle' ? 'err' : arc.kind);
        card.tip = 'Azure Arc says: ' + (str(m.arcStatus) || 'no status');
        card.waits = me.status === 'idle' ? me.tip : '';
        return card;
      }
      card.state = me.status === 'ok' ? verb[0] : me.status === 'run' ? verb[1] : me.status === 'err' ? 'Stopped' : verb[2];
      card.waits = me.status === 'run' && cur ? 'Now: ' + cur : (me.status === 'idle' ? 'Waits for ' + waitsFor : '');
      if (me.status === 'run') card.progress = pct;
      return card;
    });
    return out;
  }

  // ------------------------------------------------------------------ steps of a mode: what a click does (pure; also run by tests under Node)
  //
  // Every step belongs to Azure or to a node. Azure steps (the machine lifecycle and the ProvisionOs job, the Azure
  // registration, validation and the extensions) run in Azure: there is no log line for them, so a click shows their
  // details under the step and never filters the logs. Node steps (the ZTP Device, Network and Restore stages, the OEM
  // OS image update and bootstrap, deployment and update) leave lines: a click filters the logs to that machine and to
  // the step's time window, or, for a ZTP stage, to the ZTP event lines tagged with that stage. A machine row selects
  // the machine, like its card.

  var MODE_SECTIONS = { prov: ['provisioning'], validate: ['validation', 'extensions'], deploy: ['deployment'], update: ['update'], health: [] };

  // chain: the items from the top of the section down to the clicked step ({ id, name, ... }).
  // Returns { side: 'machine' | 'azure' | 'node', node, stage, window }.
  function stepRule(section, chain) {
    var list = arr(chain).filter(isObj), top = list[0];
    if (!top) return { side: 'azure', node: '', stage: '', window: false };
    if (section === 'provisioning') {
      var machine = str(top.name);
      if (list.length === 1) return { side: 'machine', node: machine, stage: '', window: false };
      var group = str(list[1].id), z = /^ztp\.(device|network|restore)(?:\.|$)/.exec(group);
      if (z) return { side: 'node', node: machine, stage: z[1], window: false };
      if (/^(update|bootstrap)(?:\.|$)/.test(group)) return { side: 'node', node: machine, stage: '', window: true };
      return { side: 'azure', node: machine, stage: '', window: false };
    }
    if (section === 'validation' || section === 'extensions') return { side: 'azure', node: '', stage: '', window: false };
    return { side: 'node', node: '', stage: '', window: true };
  }

  // Short description under a step name. The ZTP steps use the plain text below (the back end's own text is a technical
  // one); other steps keep what Azure or the back end says, and the machine stages of Azure get a plain fallback.
  var ZTP_STEP_DESC = {
    'ztp.device': 'Finds the machine by its management MAC and sets the static address on that port, before the claim.',
    'ztp.network': 'Checks the management port after the install. A static address the install reset is left for OS configuration.',
    'ztp.restore': 'Puts the BIOS settings changed for the install (for example the FC card) back, restarts, waits for Arc.'
  };
  var STEP_DESC = {
    provisionmachine: 'Azure accepts the ownership voucher, creates the edge machine and its role assignments, and the machine registers.',
    registermachine: 'The machine connects out to Azure and registers; this can take a while after the claim.',
    arcenablemaintenanceenvironment: 'Arc-enables the maintenance environment so Azure can reach the machine.',
    installos: 'Azure downloads the OS, installs it, restarts the machine and adds the Arc extensions.',
    'provisionos job': 'The Azure job that provisions the operating system: each of its steps is shown below.'
  };
  function stepDescription(n) {
    if (!isObj(n)) return '';
    var id = str(n.id).toLowerCase();
    if (ZTP_STEP_DESC[id]) return ZTP_STEP_DESC[id];
    var own = str(n.description).trim(), name = str(n.name).trim();
    if (own && own !== name && !isObj(n.prov)) return own;
    if (isObj(n.prov)) return '';
    return STEP_DESC[name.toLowerCase()] || '';
  }

  // What the Steps box says when the selected mode has no steps to show.
  function stepsEmptyText(modeId, status, when, hasMachines) {
    if (modeId === 'health') return 'There are no steps here. Sonar does not run health checks; the cards above show each machine’s Azure Arc status.';
    if (modeId === 'prov' && !hasMachines) return 'No machines reported yet.';
    if (status === 'idle') return 'The steps appear here when this mode begins.' + (when ? ' ' + when + '.' : '');
    return 'No steps reported yet.';
  }

  // The log pane when no line is shown, and why: { kind, title, text, actions: ['node' | 'clear' | 'clearAll'] }.
  //   f: the filter { level, q, file, stepKey, node, stage }; scoped: lines inside the machine / step scope;
  //   total: lines held; tailer: the tailer state ('' when unknown).
  function emptyLogView(f, scoped, total, tailer) {
    var stepScope = !!(f && (f.stepKey || f.stage)), nodeScope = !!(f && f.node);
    if (!total) {
      var down = /^(unavailable|error|disconnected)$/.test(str(tailer).toLowerCase());
      return { kind: 'waiting', title: down ? 'No log lines: the log tailer cannot reach the seed node.' : 'Waiting for log lines…', text: '', actions: [] };
    }
    if ((stepScope || nodeScope) && !scoped) {
      if (stepScope) return { kind: 'step', title: 'No log lines for this step yet.', text: 'This step has produced no lines on this node yet. Nothing is wrong with the filter itself.', actions: nodeScope ? ['node', 'clear'] : ['clear'] };
      return { kind: 'node', title: 'No log lines for ' + str(f.node) + ' yet.', text: 'Sonar reads the seed node’s log folders and the ZTP event file; a machine with neither has nothing to show here yet.', actions: ['clear'] };
    }
    return { kind: 'filters', title: 'No lines match the current filters.', text: 'Try a wider level, another file, or clear the search.', actions: ['clearAll'] };
  }

  // ------------------------------------------------------------------ replay (pure; also run by tests under Node)
  //
  // A recording is a list of events { t, k, ... } (JSON Lines written by the back end, see Recording.ps1):
  // session { config, guidance, server }, state { full } or state { ops }, tailer { tailer }, log { lines }, end.
  // Delta ops: ['s', path, value] sets a key or index (index = length appends), ['d', path] deletes a key,
  // ['t', path, length] truncates an array. The state at time t is the last keyframe before the last state event at or
  // before t, plus the deltas after it.

  function cloneJSON(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }

  // The ops that turn a into b (same rules as Compare-AzlSonarJsonNode in the back end).
  function replayDiff(a, b, path, ops) {
    path = path || [];
    ops = ops || [];
    if (JSON.stringify(a) === JSON.stringify(b)) return ops;
    if (isObj(a) && isObj(b)) {
      Object.keys(b).forEach(function (k) {
        if (Object.prototype.hasOwnProperty.call(a, k)) replayDiff(a[k], b[k], path.concat([k]), ops);
        else ops.push(['s', path.concat([k]), cloneJSON(b[k])]);
      });
      Object.keys(a).forEach(function (k) { if (!Object.prototype.hasOwnProperty.call(b, k)) ops.push(['d', path.concat([k])]); });
      return ops;
    }
    if (Array.isArray(a) && Array.isArray(b)) {
      var common = Math.min(a.length, b.length), i;
      for (i = 0; i < common; i++) replayDiff(a[i], b[i], path.concat([i]), ops);
      for (i = common; i < b.length; i++) ops.push(['s', path.concat([i]), cloneJSON(b[i])]);
      if (a.length > b.length) ops.push(['t', path, b.length]);
      return ops;
    }
    ops.push(['s', path, cloneJSON(b === undefined ? null : b)]);
    return ops;
  }

  // Applies ops to root (in place where it can) and returns the result. Values are cloned.
  function replayApplyOps(root, ops) {
    arr(ops).forEach(function (op) {
      if (!Array.isArray(op) || !Array.isArray(op[1])) throw new Error('A delta op is not [op, path, ...].');
      var kind = op[0], path = op[1];
      if (!path.length) { if (kind !== 's') throw new Error('Delta op ' + kind + ' needs a path.'); root = cloneJSON(op[2]); return; }
      var parent = root;
      for (var i = 0; i < path.length - 1; i++) {
        parent = parent === null || parent === undefined ? undefined : parent[path[i]];
        if (parent === null || parent === undefined) throw new Error('Delta op path not found at segment ' + i + '.');
      }
      var last = path[path.length - 1];
      if (kind === 's') {
        if (Array.isArray(parent) && typeof last === 'number') {
          while (parent.length < last) parent.push(null);
          parent[last] = cloneJSON(op[2]);
        } else parent[last] = cloneJSON(op[2]);
      } else if (kind === 'd') {
        if (Array.isArray(parent) && typeof last === 'number') parent.splice(last, 1); else delete parent[last];
      } else if (kind === 't') {
        var target = parent[last];
        if (!Array.isArray(target)) throw new Error('Delta op t (truncate) does not point at an array.');
        target.length = Math.min(target.length, Number(op[2]) || 0);
      } else throw new Error('Unknown delta op ' + kind + '.');
    });
    return root;
  }

  // JSON Lines text as events; lines that are not JSON objects are counted, not thrown.
  // Notes under the header that explain what the step list alone would hide (all read from the state):
  // Azure lagging behind the node, the Environment Checker stage of Deploy mode, and the tracks built from the
  // REST reference only (update, add-node, repair), which are marked as not verified against a live run.
  function liveNotes(s) {
    var out = [];
    if (!isObj(s)) return out;
    var lag = isObj(s.lag) ? s.lag : null;
    if (lag && lag.detected && lag.message) {
      out.push({ kind: 'lag', text: str(lag.message) + ' (read from ' + (str(lag.source) || 'another source') + ', not from the Azure step list)' });
    }
    var ec = isObj(s.environmentChecker) ? s.environmentChecker : null;
    if (ec && ec.stage && ec.stage !== 'none' && ec.stage !== 'validate' && ec.stage !== 'cloud-deployment' && ec.label) {
      out.push({ kind: 'checker', text: str(ec.label) + (ec.source ? ' (' + (ec.source === 'node log' ? 'from the node log' : str(ec.source)) + ')' : '') });
    }
    var up = isObj(s.update) ? s.update : null;
    if (up && ['installing', 'preparing', 'failed', 'attention'].indexOf(str(up.phase)) >= 0) {
      var what = up.active && up.active.version ? ' ' + str(up.active.version) : '';
      out.push({ kind: 'update', text: 'Update' + what + ': ' + str(up.phase) + '. This track is built from the Microsoft Learn REST reference and is unverified against a live run.' });
    }
    if (normPhase(s.phase) === 'provisioning' && ztpComplete(s)) {
      // The guide's URL comes from the back end (provisioning.nextStep.guide): the web files carry no URL.
      var next = isObj(s.provisioning.nextStep) ? s.provisioning.nextStep : {};
      var guide = safeLink(next.guide);
      var note = { kind: 'ztp', text: 'ZTP is complete: every machine is provisioned, with its management address on the management NIC and its final BIOS values. ' +
        'Next: OS configuration (OEM drivers, C:\\SBE, DHCP off, DNS and time, the deployment admin), then Validate.' + (guide ? ' Guide: ' : '') };
      if (guide) { note.href = guide; note.linkText = guide.replace(/^https:\/\//i, '').replace(/\/$/, ''); }
      out.push(note);
    }
    var tr = str(s.track).toLowerCase();
    if (tr === 'add-node' || tr === 'repair') {
      out.push({ kind: 'track', text: phaseLabel(tr) + ' (set in the config): Sonar shows the Arc machines and the node log; the steps are not reported by Azure. Unverified against a live run.' });
    }
    return out;
  }

  function renderLiveNotes() {
    var host = $('live-notes');
    if (!host) return;
    var notes = liveNotes(app.state);
    host.textContent = '';
    host.hidden = !notes.length;
    notes.forEach(function (n) {
      var li = el('li', { class: 'live-note live-note-' + n.kind, text: n.text });
      if (n.href) li.appendChild(el('a', { href: n.href, target: '_blank', rel: 'noopener noreferrer', text: n.linkText || n.href }));
      host.appendChild(li);
    });
  }

  function replayParseLines(text) {
    var events = [], invalid = 0;
    str(text).split(/\r?\n/).forEach(function (line) {
      if (!line.trim()) return;
      try { var e = JSON.parse(line); if (isObj(e)) events.push(e); else invalid++; } catch (err) { invalid++; }
    });
    return { events: events, invalid: invalid };
  }

  function bsearchLast(list, t) {   // index of the last item with item.t <= t, or -1
    var lo = 0, hi = list.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (list[mid].t <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return ans;
  }

  var REPLAY_PHASE_SHORT = { provisioning: 'Provisioning', 'arc-registration': 'Arc registration', validation: 'Validate', deployment: 'Deploy', update: 'Update' };

  function treeStartMin(nodes) {
    var min = NaN;
    (function walk(list) {
      arr(list).forEach(function (n) {
        if (!isObj(n)) return;
        var a = parseTime(n.start);
        if (!isNaN(a) && (isNaN(min) || a < min)) min = a;
        walk(n.children);
      });
    })(nodes);
    return min;
  }

  // The steps the scrubber marks for Deploy: the top-level steps, or the children of a single top-level step.
  function mainSteps(tree) {
    var t = arr(tree).filter(isObj);
    return t.length === 1 && arr(t[0].children).length ? arr(t[0].children).filter(isObj) : t;
  }

  function firstError(nodes) {
    var hit = null;
    (function walk(list) {
      arr(list).forEach(function (n) {
        if (hit || !isObj(n)) return;
        if (normStatus(n.status) === 'error' && !arr(n.children).some(function (c) { return isObj(c) && normStatus(c.status) === 'error'; })) { hit = n; return; }
        walk(n.children);
      });
    })(nodes);
    return hit;
  }

  function phaseOrigin(state, phase, t) {
    var o = NaN;
    if (phase === 'validation' || phase === 'deployment') o = treeStartMin(isObj(state[phase]) ? state[phase].tree : null);
    else if (isObj(state.provisioning)) {
      arr(state.provisioning.nodes).forEach(function (n) { var a = isObj(n) ? parseTime(n.start) : NaN; if (!isNaN(a) && (isNaN(o) || a < o)) o = a; });
    }
    return isNaN(o) || o > t ? t : o;
  }

  // Normalises recorded events: times in ms (never going back), log lines renumbered 1..n across sessions (each
  // Sonar start numbers from 1), keyframe indexes, markers. meta: the /api/replay replay object (optional).
  function replayLoad(events, meta) {
    var rec = { meta: isObj(meta) ? meta : {}, sessions: [], states: [], lines: [], tailers: [], markers: [], invalid: 0,
      start: NaN, end: NaN, cache: null, cluster: '' };
    var lastT = -Infinity, seq = 0, haveFull = false;
    arr(events).forEach(function (e) {
      var t = isObj(e) ? parseTime(e.t) : NaN;
      if (isNaN(t) || typeof e.k !== 'string') { rec.invalid++; return; }
      if (t < lastT) t = lastT;
      lastT = t;
      if (e.k === 'session') {
        haveFull = false;
        rec.sessions.push({ t: t, server: str(e.server), version: str(e.version), cluster: str(e.cluster),
          config: isObj(e.config) ? e.config : null, guidance: isObj(e.guidance) ? e.guidance : null });
      } else if (e.k === 'state') {
        if (isObj(e.full)) { haveFull = true; rec.states.push({ t: t, full: e.full }); }
        else if (Array.isArray(e.ops) && haveFull) rec.states.push({ t: t, ops: e.ops });
        else { rec.invalid++; return; }
      } else if (e.k === 'log') {
        arr(e.lines).forEach(function (l) {
          if (!isObj(l)) return;
          var c = {}; Object.keys(l).forEach(function (k) { c[k] = l[k]; });
          c.seq = ++seq;
          rec.lines.push({ t: t, line: c });
        });
      } else if (e.k === 'tailer') {
        if (isObj(e.tailer)) rec.tailers.push({ t: t, tailer: e.tailer });
      } else if (e.k !== 'end') return;
      if (isNaN(rec.start)) rec.start = t;
      rec.end = t;
    });
    if (!rec.states.length) throw new Error('The recording holds no state snapshots.');
    var last = rec.sessions[rec.sessions.length - 1];
    rec.cluster = str(rec.meta.cluster) || (last && (last.cluster || (last.config && (last.config.cluster || last.config.clusterName)))) || '';
    rec.markers = replayMarkers(rec);
    return rec;
  }

  function replayMarkers(rec) {
    var marks = [], state = null, lastPhase = null, counts = {}, seenSteps = {}, errorRun = null;
    rec.sessions.forEach(function (s, i) {
      if (i > 0) marks.push({ kind: 'session', key: 'session:' + i, label: 'Sonar restarted', t: s.t, origin: s.t });
    });
    rec.states.forEach(function (ev, idx) {
      state = ev.full ? cloneJSON(ev.full) : replayApplyOps(state, ev.ops);
      if (!isObj(state)) return;
      var ph = normPhase(state.phase), act = str(state.activePhase).toLowerCase() || ph;
      var cur = ph === 'done' || ph === 'failed' ? ph : act;
      if (cur !== lastPhase) {
        counts[cur] = (counts[cur] || 0) + 1;
        var n = counts[cur] > 1 ? ' (' + counts[cur] + ')' : '';
        if (REPLAY_PHASE_SHORT[cur]) {
          marks.push({ kind: 'phase', key: cur + ':' + counts[cur], phase: cur, label: REPLAY_PHASE_SHORT[cur] + n, short: REPLAY_PHASE_SHORT[cur],
            t: ev.t, origin: phaseOrigin(state, cur, ev.t) });
        } else if (cur === 'done') {
          marks.push({ kind: 'end', key: 'done:' + counts[cur], label: 'Succeeded', short: 'Succeeded', t: ev.t, origin: ev.t });
        } else if (cur === 'failed') {
          marks.push({ kind: 'error', key: 'failed:' + counts[cur], label: 'Failed: ' + phaseLabel(act), short: 'Failed', t: ev.t, origin: ev.t });
        }
        lastPhase = cur;
        errorRun = null;
      }
      var dep = isObj(state.deployment) ? state.deployment.tree : null;
      mainSteps(dep).forEach(function (n) {
        var key = 'step:' + str(n.id || n.name);
        var st = normStatus(n.status);
        if (seenSteps[key] || st === 'notstarted' || st === 'skipped' || st === 'unknown') return;
        seenSteps[key] = true;
        if (st !== 'running' && idx === 0) return;   // finished before the recording started
        marks.push({ kind: 'step', key: key, label: str(n.name), t: ev.t, origin: ev.t });
      });
      ['validation', 'deployment'].forEach(function (sec) {
        var bad = firstError(isObj(state[sec]) ? state[sec].tree : null);
        var key = sec + ':' + (counts[sec] || 0);
        if (bad && errorRun !== key) {
          errorRun = key;
          marks.push({ kind: 'error', key: 'error:' + key + ':' + str(bad.id || bad.name), label: 'Failed: ' + str(bad.name), t: ev.t, origin: ev.t });
        }
      });
    });
    marks.sort(function (a, b) { return a.t - b.t; });
    return marks;
  }

  function replayStateIndexAt(rec, t) { return bsearchLast(rec.states, t); }

  // The state at time t (a fresh copy the caller may change), or null before the first state.
  function replayStateAt(rec, t) {
    var i = replayStateIndexAt(rec, t);
    if (i < 0) return null;
    var c = rec.cache, state, j;
    if (c && c.index <= i) {
      state = c.state;
      for (j = c.index + 1; j <= i; j++) state = rec.states[j].full ? cloneJSON(rec.states[j].full) : replayApplyOps(state, rec.states[j].ops);
    } else {
      var k = i;
      while (k > 0 && !rec.states[k].full) k--;
      state = cloneJSON(rec.states[k].full);
      for (j = k + 1; j <= i; j++) state = rec.states[j].full ? cloneJSON(rec.states[j].full) : replayApplyOps(state, rec.states[j].ops);
    }
    rec.cache = { index: i, state: state };
    return cloneJSON(state);
  }

  function replayLogCountAt(rec, t) { return bsearchLast(rec.lines, t) + 1; }
  function replayTailerIndexAt(rec, t) { return bsearchLast(rec.tailers, t); }

  // +h:mm:ss (or -h:mm:ss)
  function fmtOffset(ms) {
    if (ms === null || ms === undefined || isNaN(ms)) return '';
    var neg = ms < 0, s = Math.floor(Math.abs(ms) / 1000);
    return (neg ? '-' : '+') + Math.floor(s / 3600) + ':' + pad(Math.floor((s % 3600) / 60)) + ':' + pad(s % 60);
  }

  // The readout: "Deploy +1:42:10" (time since the current phase began), or "Recording +0:05:00" before any phase.
  function replayPosition(rec, t) {
    var m = null;
    rec.markers.forEach(function (x) { if ((x.kind === 'phase' || x.kind === 'end') && x.t <= t) m = x; });
    if (!m) return { label: 'Recording', offset: t - rec.start, text: 'Recording ' + fmtOffset(t - rec.start), marker: null };
    return { label: m.short || m.label, offset: t - m.origin, text: (m.short || m.label) + ' ' + fmtOffset(t - m.origin), marker: m };
  }

  // Playback clock: recorded time advances by speed x wall time while playing; it stops at the end.
  function clockCreate(start, end, speed) {
    return { start: start, end: end, pos: start, anchor: 0, speed: Number(speed) > 0 ? Number(speed) : 60, playing: false };
  }
  function clockNow(c, wall) {
    if (!c.playing) return c.pos;
    var t = c.pos + (wall - c.anchor) * c.speed;
    return t >= c.end ? c.end : t;
  }
  function clockPlay(c, wall) {
    if (c.playing) return c;
    if (c.pos >= c.end) c.pos = c.start;   // play at the end starts over
    c.playing = true; c.anchor = wall;
    return c;
  }
  function clockPause(c, wall) { c.pos = clockNow(c, wall); c.playing = false; return c; }
  function clockSetSpeed(c, speed, wall) {
    if (!(Number(speed) > 0)) return c;
    c.pos = clockNow(c, wall); c.anchor = wall; c.speed = Number(speed);
    return c;
  }
  function clockSeek(c, t, wall) {
    c.pos = Math.max(c.start, Math.min(c.end, Number(t)));
    c.anchor = wall;
    return c;
  }
  function clockEnded(c, wall) { return clockNow(c, wall) >= c.end; }

  // Scrubber position (0..1) for a time, and the time for a position.
  function scrubFraction(rec, t) { var d = rec.end - rec.start; return d > 0 ? Math.max(0, Math.min(1, (t - rec.start) / d)) : 0; }
  function scrubTime(rec, f) { return rec.start + Math.max(0, Math.min(1, Number(f) || 0)) * (rec.end - rec.start); }

  // ------------------------------------------------------------------ demo data (pure; ?demo=1 and its replay)

  function demoFactory(now) {
    function iso(msAgo) { return new Date(now - msAgo).toISOString(); }
    function step(id, name, status, startAgo, endAgo, children, errors, description) {
      var st = startAgo === null ? null : iso(startAgo), en = endAgo === null ? null : iso(endAgo);
      return { id: id, name: name, description: description || '', status: status, start: st, end: en,
        durationSeconds: st && en ? (startAgo - endAgo) / 1000 : (st ? startAgo / 1000 : null),
        errors: errors || [], children: children || [] };
    }
    return { iso: iso, step: step, M: 60000 };
  }

  // The ?demo=1 running deployment: state, config, guidance, tailer, files, log lines and the lines that keep coming.
  function demoDeploymentSample(now) {
    var f = demoFactory(now), iso = f.iso, step = f.step, M = f.M;
    var validation = [
      step('1', 'Validate deployment prerequisites', 'success', 58 * M, 41 * M, [
        step('1.1', 'Validate hardware', 'success', 58 * M, 56 * M + 42000),
        step('1.2', 'Validate network', 'success', 56 * M + 40000, 52 * M + 10000),
        step('1.3', 'Validate external connectivity', 'success', 52 * M + 8000, 50 * M + 30000),
        step('1.4', 'Validate storage', 'success', 50 * M + 28000, 47 * M),
        step('1.5', 'Validate Azure Arc registration', 'success', 46 * M + 58000, 44 * M + 20000),
        step('1.6', 'Validate memory and processor', 'success', 44 * M + 18000, 41 * M)
      ])
    ];
    var deployment = [
      step('2', 'Deploy Azure Local', 'running', 36 * M, null, [
        step('2.1', 'Run pre-deployment checks', 'success', 36 * M, 33 * M + 12000),
        step('2.2', 'Configure security baseline', 'success', 33 * M + 10000, 29 * M + 52000),
        step('2.3', 'Deploy Arc infrastructure components', 'success', 29 * M + 50000, 22 * M + 4000),
        step('2.4', 'Configure network intents', 'skipped', null, null, null, null, 'Already applied by provisioning'),
        step('2.5', 'Create cluster', 'running', 22 * M, null, [
          step('2.5.1', 'Install failover clustering features', 'success', 22 * M, 18 * M + 31000),
          step('2.5.2', 'Configure Storage Spaces Direct', 'running', 18 * M + 29000, null),
          step('2.5.3', 'Validate cluster', 'notstarted', null, null)
        ]),
        step('2.6', 'Deploy Arc resource bridge', 'notstarted', null, null),
        step('2.7', 'Install Azure Local extensions', 'notstarted', null, null)
      ])
    ];
    var state = {
      cluster: 'clus01', mode: 'Deploy', provisioningState: 'Succeeded', phase: 'deployment',
      validation: { status: 'Success', tree: validation, counts: {} },
      deployment: { status: 'InProgress', tree: deployment, counts: {} },
      nodes: [
        { name: 'node01', arcStatus: 'Connected', lastStatusChange: iso(80 * M) },
        { name: 'node02', arcStatus: 'Connected', lastStatusChange: iso(79 * M) }
      ],
      current: { phase: 'deployment', stepPath: ['2', '2.5', '2.5.2'], stepName: 'Configure Storage Spaces Direct' },
      polledAt: iso(4000)
    };
    var config = { cluster: 'clus01', resourceGroup: 'rg-example-azl', identityModel: 'LocalIdentity', pollSeconds: 20,
      nodes: [{ name: 'node01', seed: true }, { name: 'node02' }], logPaths: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'] };
    var guidance = {
      identityModel: 'LocalIdentity',
      phases: {
        provisioning: { account: 'Local administrator on each node', where: ['C:\\MASLogs'], when: 'After the operating system install finishes', source: 'Sample data (demo mode)', verified: false },
        validation: { account: 'Deployment user on the seed node', where: ['C:\\CloudDeployment\\Logs'], when: 'From the start of Validate, on the seed node first', source: 'Sample data (demo mode)', verified: false },
        deployment: { account: 'Deployment user on the seed node', where: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'], when: 'Throughout Deploy; files rotate as steps change', source: 'Sample data (demo mode)', verified: false, notes: 'Demo guidance only. The real card reads data/phase-guidance.json through /api/guidance.' }
      }
    };
    var f1 = 'C:\\CloudDeployment\\Logs\\CloudDeployment.2026-10-10.1.log', f2 = 'C:\\MASLogs\\Lcm.log';
    var seq = 0;
    function line(msAgo, file, level, text) { return { seq: ++seq, time: iso(msAgo), received: iso(msAgo), timeSource: 'line', file: file, level: level, text: text }; }
    var lines = [
      line(46 * M, f2, 'info', 'Validate Azure Arc registration: node01 Connected, node02 Connected.'),
      line(41 * M, f2, 'info', 'Validation completed: 6 of 6 steps succeeded.'),
      line(36 * M, f1, 'info', 'Action plan "Deploy" started on node01.'),
      line(33 * M, f1, 'info', 'Pre-deployment checks passed.'),
      line(30 * M, f1, 'warning', 'WARNING: Time source on node02 differs from the configured NTP server by 2 s; within tolerance.'),
      line(22 * M + 4000, f1, 'info', 'Arc infrastructure components deployed.'),
      line(22 * M, f1, 'info', 'Step "Create cluster" started.'),
      line(18 * M + 31000, f1, 'info', 'Failover clustering features installed on 2 nodes.'),
      line(18 * M + 29000, f1, 'info', 'Step "Configure Storage Spaces Direct" started.'),
      line(15 * M, f1, 'info', 'Enabling Storage Spaces Direct on cluster clus01.'),
      line(12 * M, f1, 'error', 'Attempt 1 failed: Get-PhysicalDisk timed out on node02. Retrying in 30 s (transient).'),
      line(11 * M + 30000, f1, 'info', 'Attempt 2: physical disk inventory complete, 8 eligible disks.'),
      line(6 * M, f1, 'warning', 'Warning: cache device count differs between nodes; using capacity-only tier.'),
      line(2 * M, f1, 'info', 'Creating storage pool "SU1_Pool".')
    ];
    var msgs = [
      ['info', 'Storage pool health: Healthy.'],
      ['info', 'Waiting for virtual disk "Infrastructure_1" to come online.'],
      ['warning', 'Warning: storage job progress unchanged for 60 s; continuing to wait.'],
      ['info', 'Storage job progress 42%.'],
      ['info', 'Storage job progress 57%.'],
      ['error', 'Retryable error: cluster resource "Infrastructure_1" is pending; will retry.'],
      ['info', 'Storage job progress 71%.']
    ];
    return { state: state, config: config, guidance: guidance, tailer: { state: 'connected', reason: '', node: 'node01' },
      files: [{ path: f1, size: 0, offset: 0 }, { path: f2, size: 0, offset: 0 }], lines: lines, msgs: msgs, file: f1 };
  }

  // A step tree as it stood at time T: steps not started yet are 'notstarted', unfinished ones 'running'.
  function demoSliceTree(nodes, T, parentStarted) {
    return arr(nodes).map(function (n) {
      var c = {};
      Object.keys(n).forEach(function (k) { c[k] = n[k]; });
      var a = parseTime(n.start), b = parseTime(n.end), started = !isNaN(a) && a <= T;
      if (isNaN(a)) c.status = normStatus(n.status) === 'skipped' && parentStarted ? n.status : 'notstarted';
      else if (!started) { c.status = 'notstarted'; c.start = null; c.end = null; c.durationSeconds = null; }
      else if (isNaN(b) || b > T) { c.status = 'running'; c.end = null; c.durationSeconds = Math.round((T - a) / 1000); }
      c.children = demoSliceTree(n.children, T, started);
      c.errors = arr(n.errors).slice();
      return c;
    });
  }

  function runningPath(nodes) {
    var best = [];
    (function walk(list, path) {
      arr(list).forEach(function (n) {
        if (!isObj(n) || normStatus(n.status) !== 'running') return;
        var here = path.concat([n]);
        if (here.length > best.length) best = here;
        walk(n.children, here);
      });
    })(nodes, []);
    return best;
  }

  // ?demo=1&replay=1: the demo deployment as a built-in recording (64 minutes, a poll every 20 s): Arc registration,
  // Validate, Deploy, the log lines at their times. Built with replayDiff, so it is a real keyframe + delta recording.
  function demoRecording(now) {
    var d = demoDeploymentSample(now), M = 60000, final = d.state;
    var start = now - 64 * M, valStart = now - 58 * M, depStart = now - 36 * M;
    function at(T) { return new Date(T).toISOString(); }
    function stateAt(T) {
      var vs = T >= valStart, ds = T >= depStart;
      var val = demoSliceTree(final.validation.tree, T, true), dep = demoSliceTree(final.deployment.tree, T, true);
      var valDone = vs && val.every(function (n) { return normStatus(n.status) === 'success'; });
      var phase = ds ? 'deployment' : vs ? 'validation' : 'arc-registration';
      var path = runningPath(ds ? dep : vs ? val : []);
      return {
        cluster: final.cluster, mode: ds ? 'Deploy' : vs ? 'Validate' : null, provisioningState: ds ? 'Succeeded' : vs ? 'Accepted' : null,
        phase: phase, activePhase: phase,
        validation: { status: vs ? (valDone ? 'Success' : 'InProgress') : 'notstarted', tree: vs ? val : [], counts: {} },
        deployment: { status: ds ? 'InProgress' : 'notstarted', tree: ds ? dep : [], counts: {} },
        nodes: cloneJSON(final.nodes),
        current: { phase: phase, stepPath: path.map(function (n) { return n.id; }), stepName: path.length ? path[path.length - 1].name : null },
        polledAt: at(T)
      };
    }
    var events = [{ t: at(start), k: 'session', format: 1, tool: 'AzL Sonar', version: 'demo', server: 'demo', cluster: final.cluster,
      config: d.config, guidance: d.guidance }];
    events.push({ t: at(start + 500), k: 'tailer', tailer: d.tailer });
    var prev = null, deltas = 0;
    for (var T = start + 1000; ; T = Math.min(now, T + 20000)) {
      var s = stateAt(T);
      if (!prev || deltas >= 30) { events.push({ t: at(T), k: 'state', full: s }); deltas = 0; }
      else {
        var ops = replayDiff(prev, s);
        if (ops.length) { events.push({ t: at(T), k: 'state', ops: ops }); deltas++; }
      }
      prev = s;
      if (T >= now) break;
    }
    var lines = d.lines.slice(), mi = 0;
    for (var L = now - 17 * M; L < now; L += 75000) {
      var m = d.msgs[mi++ % d.msgs.length];
      lines.push({ time: at(L), received: at(L), timeSource: 'line', file: d.file, level: m[0], text: m[1] });
    }
    lines.forEach(function (l) { events.push({ t: l.received, k: 'log', lines: [l] }); });
    events.push({ t: at(now), k: 'end' });
    var order = events.map(function (e, i) { return { e: e, i: i, t: Date.parse(e.t) }; });
    order.sort(function (a, b) { return a.t - b.t || a.i - b.i; });
    return order.map(function (x) { return x.e; });
  }

  app.store = createLogStore(MAX_STORED_LINES);

  if (typeof module === 'object' && module && module.exports && typeof document === 'undefined') {
    module.exports = {
      createLogStore: createLogStore, logStoreReset: logStoreReset, logStoreIngest: logStoreIngest,
      logStoreStreamOpened: logStoreStreamOpened, logStoreStreamClosed: logStoreStreamClosed,
      stepWindowOf: stepWindowOf, windowSignature: windowSignature, lineInWindow: lineInWindow, stepFilterChange: stepFilterChange,
      safeLink: safeLink, __dom: function () {
        return { app: app, el: el, renderSummary: renderSummary, renderDetails: renderDetails, renderHelp: renderHelp, buildLine: buildLine,
          renderLiveNotes: renderLiveNotes, renderChips: renderChips, renderLogAccessWindow: renderLogAccessWindow, renderTree: renderTree, buildItem: buildItem };
      },
      lineScope: lineScope, lineInScope: lineInScope, stepRule: stepRule, stepDescription: stepDescription, stepsEmptyText: stepsEmptyText,
      emptyLogView: emptyLogView, MODE_SECTIONS: MODE_SECTIONS,
      fileOptionList: fileOptionList, keptFileSelection: keptFileSelection, normLevel: normLevel, parseTime: parseTime,
      normStatus: normStatus, phaseLabel: phaseLabel, phaseChipText: phaseChipText, provisioningTreeOf: provisioningTreeOf,
      provisioningSummary: provisioningSummary, provisioningCollapse: provisioningCollapse, arcSourceText: arcSourceText,
      lifecycleLabel: lifecycleLabel, stepGroupOf: stepGroupOf, probeNote: probeNote, extensionsTreeOf: extensionsTreeOf,
      readyForValidate: readyForValidate, ztpComplete: ztpComplete, liveNotes: liveNotes, guidanceSummary: guidanceSummary,
      replayDiff: replayDiff, replayApplyOps: replayApplyOps, replayParseLines: replayParseLines, replayLoad: replayLoad,
      replayStateIndexAt: replayStateIndexAt, replayStateAt: replayStateAt, replayLogCountAt: replayLogCountAt,
      replayTailerIndexAt: replayTailerIndexAt, replayPosition: replayPosition, fmtOffset: fmtOffset, mainSteps: mainSteps,
      clockCreate: clockCreate, clockNow: clockNow, clockPlay: clockPlay, clockPause: clockPause, clockSetSpeed: clockSetSpeed,
      clockSeek: clockSeek, clockEnded: clockEnded, scrubFraction: scrubFraction, scrubTime: scrubTime,
      demoDeploymentSample: demoDeploymentSample, demoRecording: demoRecording, setClock: setClock, nowMs: nowMs,
      nodeDuration: nodeDuration,
      modeStates: modeStates, activeModeId: activeModeId, modeName: modeName, summaryFor: summaryFor, stepProgress: stepProgress,
      lifecyclePlain: lifecyclePlain, arcInfo: arcInfo, machineWaits: machineWaits, machineList: machineList
    };
    return;
  }

  // ------------------------------------------------------------------ theme

  var mql = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function storedTheme() {
    try { var v = localStorage.getItem(THEME_KEY); return v === 'light' || v === 'dark' ? v : null; } catch (e) { return null; }
  }
  function effectiveTheme() {
    var s = document.documentElement.getAttribute('data-theme');
    if (s === 'light' || s === 'dark') return s;
    return mql && mql.matches ? 'dark' : 'light';
  }
  function applyTheme(t) {
    var root = document.documentElement;
    if (t) root.setAttribute('data-theme', t); else root.removeAttribute('data-theme');
    var eff = effectiveTheme();
    root.setAttribute('data-effective-theme', eff);
    var btn = $('theme-btn');
    if (btn) {
      var next = eff === 'dark' ? 'light' : 'dark';
      btn.setAttribute('aria-label', 'Switch to ' + next + ' theme');
      btn.title = 'Switch to ' + next + ' theme';
    }
  }
  applyTheme(storedTheme()); // runs before first paint where possible (script is deferred)

  function toggleTheme() {
    var next = effectiveTheme() === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* storage blocked: theme still switches */ }
    applyTheme(next);
  }

  // ------------------------------------------------------------------ banner (non-blocking errors)

  function setError(source, message) {
    if (message) app.errors.set(source, message); else app.errors.delete(source);
    renderBanner();
  }
  function renderBanner() {
    var b = $('banner'), t = $('banner-text');
    var msgs = Array.from(app.errors.values());
    var sig = msgs.join('|');
    if (!msgs.length || sig === app.bannerDismissed) { b.hidden = true; return; }
    t.textContent = '';
    if (msgs.length === 1) {
      t.appendChild(document.createTextNode(msgs[0]));
    } else {
      var ul = el('ul');
      msgs.forEach(function (m) { ul.appendChild(el('li', { text: m })); });
      t.appendChild(ul);
    }
    b.hidden = false;
  }

  // ------------------------------------------------------------------ API

  function getJSON(path) {
    return fetch(path, { cache: 'no-store', headers: { Accept: 'application/json' }, credentials: 'same-origin' })
      .then(function (r) {
        if (!r.ok) throw new Error(path + ' returned HTTP ' + r.status);
        return r.text();
      })
      .then(function (txt) {
        if (!txt) return null;
        try { return JSON.parse(txt); } catch (e) { throw new Error(path + ' returned invalid JSON'); }
      });
  }

  function safeParse(data) {
    try { return JSON.parse(data); } catch (e) { return null; }
  }

  function loadConfig() {
    return getJSON('/api/config').then(function (c) { setError('config', null); applyConfig(c); },
      function (e) { setError('config', 'Could not load the configuration: ' + e.message); });
  }
  function loadGuidance() {
    return getJSON('/api/guidance').then(function (g) { setError('guidance', null); app.guidance = g; renderGuidance(); },
      function (e) { setError('guidance', 'Could not load the phase guidance: ' + e.message); renderGuidance(); });
  }
  function loadState() {
    return getJSON('/api/state').then(function (s) { setError('state', null); applyState(s); },
      function (e) { setError('state', 'Could not read the deployment state: ' + e.message); throw e; });
  }
  function loadLogs() {
    var gen = app.logGen;
    return getJSON('/api/logs?since=' + encodeURIComponent(app.store.catchupSeq)).then(function (r) {
      setError('logs', null);
      if (gen !== app.logGen || !isObj(r)) return;   // answer to a request sent before a back-end restart
      if (r.server && app.store.serverId && r.server !== app.store.serverId) return handleRestart(r.server);
      if (r.tailer) applyTailer(r.tailer);
      if (Array.isArray(r.files)) applyFiles(r.files);
      applyLogBatch(r.lines, { server: r.server, source: 'catchup', lastSeq: r.lastSeq });
      if (r.truncated === true) return loadLogs();   // the back end caps one answer: fetch the rest
    }, function (e) { setError('logs', 'Could not read the logs: ' + e.message); throw e; });
  }

  // The back end restarted (new server id or startedAt): its seq numbers start again, so start over from since=0.
  function handleRestart(serverId) {
    app.logGen++;
    logStoreReset(app.store, serverId || null);
    app.reportedFiles = [];
    recount();
    renderCounts();
    renderFileOptions();
    rerenderLogs();
    announce('The Sonar back end restarted; reloading the logs.');
    return loadLogs();
  }

  function applyLogBatch(raw, meta) {
    var res = logStoreIngest(app.store, raw, meta);
    if (res.restart) { handleRestart(meta && meta.server).catch(function () {}); return; }
    if (!res.fresh.length && !res.trimmed) return;
    if (res.trimmed) recount();
    else {
      res.fresh.forEach(function (l) { app.counts.all++; if (l.level !== 'info') app.counts[l.level]++; });
    }
    if (res.newFile || res.trimmed) renderFileOptions();
    renderCounts();
    if (res.outOfOrder) rerenderLogs(); else appendLogs(res.fresh);
  }

  // ------------------------------------------------------------------ live updates (SSE + polling fallback)

  var es = null, sseFailures = 0, sseTimer = null, pollTimer = null, polling = false;

  function setConn(c) {
    app.conn = c;
    var node = $('conn');
    node.setAttribute('data-conn', c);
    node.title = { live: 'Live updates over Server-Sent Events', polling: 'Live stream unavailable: polling /api/state and /api/logs every 5 s while it reconnects',
      offline: 'The Sonar back end is not answering; retrying', connecting: 'Connecting to the Sonar back end', demo: 'Demo mode: built-in sample data, no API calls',
      replay: 'Replay of a recording: nothing here is live; no Azure or node access' }[c] || '';
    $('conn-label').textContent = { live: 'Live', polling: 'Polling', offline: 'Offline, retrying',
      connecting: 'Connecting', demo: 'Demo', replay: 'Replay (not live)' }[c] || c;
  }

  function connectSSE() {
    if (DEMO) return;
    if (typeof window.EventSource !== 'function') { startPolling(); return; }
    try {
      es = new EventSource('/api/events');
    } catch (e) {
      es = null; onSSEFailure(); return;
    }
    es.addEventListener('open', function () {
      sseFailures = 0;
      setError('sse', null);
      stopPolling();
      setConn('live');
      logStoreStreamClosed(app.store);   // the 'hello' event of this stream says where it continues from
      // a restart shows in /api/config (startedAt, serverId); then close any gap left while disconnected
      loadConfig().then(function () { return loadLogs(); }).catch(function () {});
      loadState().catch(function () {});
    });
    es.addEventListener('hello', function (e) {
      var d = safeParse(e.data);
      if (!isObj(d)) return;
      if (logStoreStreamOpened(app.store, d.since, d.server).restart) {
        handleRestart(d.server).catch(function () {});
        logStoreStreamOpened(app.store, d.since, d.server);
      }
    });
    es.addEventListener('state', function (e) {
      var s = safeParse(e.data);
      if (s) applyState(s);
    });
    es.addEventListener('log', function (e) {
      var d = safeParse(e.data);
      if (Array.isArray(d)) applyLogBatch(d, { source: 'live' });
      else if (isObj(d) && Array.isArray(d.lines)) applyLogBatch(d.lines, { server: d.server, source: 'live' });
    });
    es.addEventListener('tailer', function (e) {
      var t = safeParse(e.data);
      if (t) applyTailer(t);
    });
    es.onerror = function () {
      if (!es) return;
      es.close();
      es = null;
      logStoreStreamClosed(app.store);
      onSSEFailure();
    };
  }

  function onSSEFailure() {
    sseFailures++;
    startPolling();
    var delay = Math.min(SSE_MAX_BACKOFF_MS, 1000 * Math.pow(2, Math.min(sseFailures - 1, 5)));
    delay += Math.floor(Math.random() * 500);
    clearTimeout(sseTimer);
    sseTimer = setTimeout(connectSSE, delay);
  }

  function startPolling() {
    if (polling || DEMO) return;
    polling = true;
    if (app.conn !== 'offline') setConn('polling');
    pollOnce();
  }
  function stopPolling() {
    polling = false;
    clearTimeout(pollTimer);
  }
  function pollOnce() {
    if (!polling) return;
    Promise.allSettled([loadState(), loadConfig().then(function () { return loadLogs(); })]).then(function (res) {
      if (!polling) return;
      var ok = res.some(function (r) { return r.status === 'fulfilled'; });
      setConn(ok ? 'polling' : 'offline');
      pollTimer = setTimeout(pollOnce, POLL_MS);
    });
  }

  // ------------------------------------------------------------------ config + header

  function cfgCluster(c) { return isObj(c) ? (c.cluster || c.clusterName || '') : ''; }

  function applyConfig(c) {
    if (!isObj(c)) return;
    var prev = app.config;
    app.config = c;
    renderHeader();
    renderRecording();
    if (!prev || DEMO || app.replay) return;
    // Sonar came back with different page files (an update): load them. The old script can't show what the new back end sends.
    if (c.webVersion && prev.webVersion && c.webVersion !== prev.webVersion && typeof location !== 'undefined') { location.reload(); return; }
    // A new serverId (or, from older back ends, a new startedAt) means the back end restarted.
    var restarted;
    if (c.serverId) {
      // already switched over by a log batch or a 'hello' from the new instance: nothing to do
      restarted = app.store.serverId !== c.serverId && (!!app.store.serverId || (!!prev.serverId && prev.serverId !== c.serverId));
    } else {
      restarted = !!c.startedAt && !!prev.startedAt && c.startedAt !== prev.startedAt;
    }
    if (restarted) handleRestart(c.serverId || null).catch(function () {});
  }

  function renderHeader() {
    var s = app.state || {}, c = app.config || {};
    var name = s.cluster || cfgCluster(c) || 'Unknown cluster';
    $('cluster-name').textContent = name;
    document.title = (app.replay ? 'Replay \u2013 ' : '') + (name !== 'Unknown cluster' ? name + ' \u2013 ' : '') + 'AzL Sonar';

    var phase = app.state ? normPhase(s.phase) : 'unknown';
    var ov = overallStatus();
    var chip = $('top-chip'), ck = topChipOf(app.state ? ov.key : 'unknown');
    chip.setAttribute('data-kind', ck.kind);
    chip.className = 'chip chip-' + ck.kind;
    chip.textContent = ck.text;
    chip.title = app.state ? ov.label : 'Waiting for data';

    tickHeader();
    var mid = currentModeId();
    if (app.ui.lastMode !== null && app.ui.lastMode !== mid) {
      // the run moved on to another mode: a step filter of the old one means nothing here
      dropStepFilter();
      app.selectedKey = null;
    }
    app.ui.lastMode = mid;
    renderModes();
    renderSummary();
    renderLogAccessButton();

    if (app.state) {
      if (app.lastAnnounced.phase !== null && app.lastAnnounced.phase !== phase) {
        announce('Phase changed to ' + phaseChipText(s) + '. Status: ' + ov.label + '.');
      } else if (app.lastAnnounced.status !== null && app.lastAnnounced.status !== ov.label) {
        announce('Status: ' + ov.label + '.');
      }
      app.lastAnnounced.phase = phase;
      app.lastAnnounced.status = ov.label;
    }
  }

  function sectionStatus(sec) {
    if (!isObj(sec)) return 'notstarted';
    var raw = sec.status;
    if (isObj(raw)) raw = raw.status;
    var st = normStatus(raw);
    var tree = arr(sec.tree);
    if ((st === 'unknown' || st === 'notstarted') && tree.length) {
      var agg = aggregate(tree);
      if (agg.running) return 'running';
      if (agg.error) return 'error';
      if (agg.total && agg.success + agg.skipped === agg.total) return 'success';
      if (agg.success) return 'running';
    }
    return st;
  }

  function overallStatus() {
    var s = app.state;
    if (!s) return { key: 'unknown', label: 'Waiting for data' };
    var phase = normPhase(s.phase);
    if (phase === 'failed') return { key: 'error', label: 'Failed' };
    if (phase === 'done') return { key: 'success', label: 'Succeeded' };
    if (phase === 'deployment' || phase === 'validation' || phase === 'update') {
      var k = sectionStatus(s[phase]);
      var label = STATUS_LABEL[k];
      if (k === 'success' && phase === 'validation') label = 'Validation succeeded';
      if (k === 'unknown') label = str(isObj(s[phase]) ? s[phase].status : '') || 'Unknown';
      return { key: k, label: label };
    }
    if (isObj(s.provisioning) && arr(s.provisioning.nodes).length) {
      var sum = provisioningSummary(app.provTree);
      if (readyForValidate(s)) {
        return { key: 'success', label: 'Ready for Validate: ' + sum.ready + ' of ' + sum.total + ' machine' + (sum.total === 1 ? '' : 's') +
          (str(s.provisioning.route) === 'oem-image' ? ' registered' : ' provisioned') };
      }
      if (ztpComplete(s)) {
        return { key: 'success', label: 'ZTP complete: ' + sum.ready + ' of ' + sum.total + ' machine' + (sum.total === 1 ? '' : 's') +
          ' provisioned. OS configuration next' };
      }
      var pk = normStatus(s.provisioning.status);
      var what = phaseLabel(s.provisioning.phase || phase);
      var plabel = what + ': ' + sum.ready + ' of ' + sum.total + ' machine' + (sum.total === 1 ? '' : 's') +
        (str(s.provisioning.route) === 'oem-image' ? ' registered' : ' ready');
      if (sum.failed) plabel += ', ' + sum.failed + ' failed';
      return { key: pk, label: plabel };
    }
    var ps = normStatus(s.provisioningState);
    return { key: ps === 'notstarted' ? 'unknown' : ps, label: s.provisioningState ? phaseLabel(phase) + ': ' + s.provisioningState : phaseLabel(phase) };
  }

  function elapsedRange() {
    var s = app.state;
    if (!s) return null;
    var min = Infinity, max = -Infinity, running = false;
    function walk(nodes) {
      arr(nodes).forEach(function (n) {
        if (!isObj(n)) return;
        var a = parseTime(n.start), b = parseTime(n.end);
        if (!isNaN(a) && a < min) min = a;
        if (!isNaN(b) && b > max) max = b;
        if (normStatus(n.status) === 'running') running = true;
        walk(n.children);
      });
    }
    walk(isObj(s.validation) ? s.validation.tree : null);
    walk(isObj(s.deployment) ? s.deployment.tree : null);
    if (min === Infinity) walk(app.provTree);   // before validation: time since the machines started getting ready
    if (min === Infinity) return null;
    var phase = normPhase(s.phase);
    var open = running || (phase !== 'done' && phase !== 'failed' && overallStatus().key === 'running');
    return { start: min, end: open ? null : (max > -Infinity ? max : null) };
  }

  function tickHeader() {
    var r = elapsedRange();
    var e = $('elapsed');
    if (!r) { e.textContent = '\u2014'; e.removeAttribute('title'); }
    else {
      var end = r.end === null ? nowMs() : r.end;
      e.textContent = fmtDuration((end - r.start) / 1000) || '0s';
      e.title = 'Since ' + fmtDateTime(r.start);
    }
    updateSummaryMeta();
    tickAges();
    var lp = $('last-poll');
    var t = app.state ? parseTime(app.state.polledAt) : NaN;
    if (isNaN(t)) { lp.textContent = '\u2014'; lp.removeAttribute('data-stale'); lp.removeAttribute('title'); return; }
    lp.textContent = fmtAgo(t);
    lp.title = fmtDateTime(t);
    var pollS = Number(app.config && app.config.pollSeconds) || 20;
    lp.setAttribute('data-stale', String(nowMs() - t > Math.max(60, pollS * 3) * 1000));
  }

  // The chip in the top bar: a short word for the run status.
  function topChipOf(key) {
    if (key === 'running') return { kind: 'run', text: 'Running' };
    if (key === 'success') return { kind: 'ok', text: 'Done' };
    if (key === 'error') return { kind: 'err', text: 'Failed' };
    return { kind: 'idle', text: 'Waiting' };
  }

  // ------------------------------------------------------------------ mode, summary box and node cards

  function chipEl(kind, text, title) {
    return el('span', { class: 'chip chip-' + kind, 'data-kind': kind, title: title || null, text: text });
  }

  // "This mode started at 17:02" / "Ran for 3 min, finished 40 min ago" / when a waiting mode starts.
  function summaryMeta(sm) {
    if (sm.status === 'idle') return sm.when || '';
    if (isNaN(sm.startedAt)) return '';
    var t = 'This mode started at ' + fmtClock(sm.startedAt);
    if (!isNaN(sm.endedAt)) t = 'Ran for ' + (fmtDuration((sm.endedAt - sm.startedAt) / 1000) || '0s') + ' · finished ' + fmtAgo(sm.endedAt);
    return t;
  }

  function renderSummary() {
    var host = $('summary');
    if (!host) return;
    var sm = summaryFor(app.state, currentModeId(), app.config);
    app.summary = sm;
    // an unchanged summary is left alone, so a poll never takes the keyboard focus off a card
    var sig = JSON.stringify([sm, app.filter.node, !!app.state]);
    if (host.getAttribute('data-sig') === sig) return;
    host.setAttribute('data-sig', sig);
    var focusedCard = document.activeElement && host.contains(document.activeElement) ? document.activeElement.getAttribute('data-node') : null;
    host.textContent = '';
    var head = el('div', { class: 'sumh' }, [
      el('span', { class: 'eyebrow', id: 'sum-title', text: sm.title }),
      chipEl(sm.chip.kind, sm.chip.text),
      el('span', { class: 'sp' }),
      el('span', { class: 'meta', id: 'sum-meta', text: summaryMeta(sm) })
    ]);
    host.appendChild(head);
    host.appendChild(el('div', { class: 'head', id: 'sum-headline', text: app.state ? sm.headline : 'Waiting for data from the Sonar back end' }));
    var cards = el('div', { class: 'cards', role: 'group', 'aria-label': 'Machines' });
    sm.cards.forEach(function (c) {
      var sel = app.filter.node && app.filter.node.toLowerCase() === c.name.toLowerCase();
      var b = el('button', { type: 'button', class: 'card' + (sel ? ' sel' : ''), 'aria-pressed': String(!!sel), 'data-node': c.name,
        title: 'Click to show only ' + c.name + ' in the steps and the logs; click again to clear.' }, [
        el('span', { class: 'nm' }, [
          el('span', { class: 'nm-name', text: c.name }),
          c.seed ? el('span', { class: 'seed', text: 'seed' }) : null,
          chipEl(c.kind, c.state, c.tip)
        ]),
        el('span', { class: 'ln', title: c.arc.raw ? 'Azure Arc says: ' + c.arc.raw : null }, [
          el('span', { class: 'arc arc-' + c.arc.kind, text: c.arc.text })
        ]),
        c.progress !== null && c.progress !== undefined ? el('span', { class: 'bar', role: 'progressbar', 'aria-label': c.name + ' progress',
          'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': String(c.progress) }, [el('i', { style: 'width:' + c.progress + '%' })]) : null,
        c.waits ? el('span', { class: 'ln muted' }, [c.waits]) : null
      ]);
      b.addEventListener('click', function () { selectNode(c.name); });
      cards.appendChild(b);
    });
    host.appendChild(cards);
    host.setAttribute('data-empty', String(!sm.cards.length));
    if (focusedCard) { var fc = cards.querySelector('[data-node="' + cssEscape(focusedCard) + '"]'); if (fc) fc.focus(); }
  }

  function updateSummaryMeta() {
    var m = $('sum-meta');
    if (m && app.summary) m.textContent = summaryMeta(app.summary);
  }

  // Clicking a machine card selects it: the logs (and, in the provisioning mode, the steps) show only that machine.
  // Clicking it again clears the selection.
  function selectNode(name) {
    var same = app.filter.node && app.filter.node.toLowerCase() === name.toLowerCase();
    app.filter.node = same ? '' : name;
    app.filter.nodeBy = same ? '' : 'card';
    if (same || app.selectedKey) { dropStepFilter(); app.selectedKey = null; }
    renderSummary();
    renderTree(false);
    renderChips();
    rerenderLogs();
    announce(same ? 'Machine filter removed.' : 'Showing only ' + name + '.');
  }

  // ------------------------------------------------------------------ state + step tree

  function applyState(s) {
    if (!isObj(s)) return;
    var filterKey = app.filter.stepKey;
    var windowBefore = filterKey ? windowSignature(stepWindow()) : null;
    app.state = s;
    app.provTree = provisioningTreeOf(s);
    app.extTree = extensionsTreeOf(s);
    var collapse = provisioningCollapse(s.activePhase || (normPhase(s.phase) === 'failed' ? '' : s.phase), app.provAutoCollapsed);
    if (collapse === 'collapse') { app.sectionCollapsed.provisioning = true; app.provAutoCollapsed = true; }
    else if (collapse === 'expand') { app.sectionCollapsed.provisioning = false; app.provAutoCollapsed = false; }
    app.stepIndex = new Map();
    indexSection('provisioning');
    indexSection('validation');
    indexSection('extensions');
    indexSection('deployment');
    indexSection('update');
    var stillIndexed = !!filterKey && app.stepIndex.has(filterKey);
    var change = stepFilterChange(filterKey, stillIndexed, windowBefore, stillIndexed ? windowSignature(stepWindow()) : null);
    if (change === 'clear') {
      // the filtered step is no longer reported: drop the filter and show every line again
      app.filter.stepKey = null;
      if (app.selectedKey === filterKey) app.selectedKey = null;
      renderChips();
      rerenderLogs();
      announce('The selected step is no longer reported; the step filter was removed.');
    } else if (change === 'rerender') {
      // the step's window changed (for example running -> finished): filter again with the new window
      renderChips();
      rerenderLogs();
    }
    app.currentKey = findCurrentKey();
    // auto-expand to the current step when it changes
    var autoScroll = false;
    if (app.currentKey && app.currentKey !== app.lastAutoKey) {
      app.lastAutoKey = app.currentKey;
      revealKey(app.currentKey);
      autoScroll = true;
    }
    renderHeader();
    renderLiveNotes();
    renderTree(autoScroll);
    renderGuidance();
    if (app.filter.stepKey) renderChips();
  }

  function nodeKey(parentKey, node, i) {
    var id = isObj(node) && node.id !== undefined && node.id !== null && node.id !== '' ? String(node.id) :
      (isObj(node) && node.name ? 'n:' + node.name : 'i:' + i);
    return parentKey + '/' + id;
  }

  function indexSection(section) {
    var sec = app.state && app.state[section];
    var seen = new Set();
    function walk(nodes, parentKey) {
      arr(nodes).forEach(function (n, i) {
        if (!isObj(n)) return;
        var k = nodeKey(parentKey, n, i);
        if (seen.has(k)) k += '#' + i;  // duplicate ids: keep keys unique
        seen.add(k);
        app.stepIndex.set(k, { node: n, section: section, parentKey: parentKey });
        n.__key = k;
        walk(n.children, k);
      });
    }
    walk(section === 'provisioning' ? app.provTree : section === 'extensions' ? app.extTree : (isObj(sec) ? sec.tree : null), section);
  }

  function findCurrentKey() {
    var s = app.state, cur = isObj(s.current) ? s.current : null;
    // 1. follow current.stepPath (ids or names) in the named phase
    if (cur && Array.isArray(cur.stepPath) && cur.stepPath.length) {
      var secs = cur.phase === 'validation' || cur.phase === 'deployment' || cur.phase === 'update' ? [cur.phase] :
        (cur.phase === 'provisioning' || cur.phase === 'arc-registration' ? ['provisioning'] : ['deployment', 'validation']);
      for (var si = 0; si < secs.length; si++) {
        var nodes = secs[si] === 'provisioning' ? app.provTree : (isObj(s[secs[si]]) ? arr(s[secs[si]].tree) : []), found = null;
        for (var d = 0; d < cur.stepPath.length; d++) {
          var want = str(isObj(cur.stepPath[d]) ? (cur.stepPath[d].id || cur.stepPath[d].name) : cur.stepPath[d]);
          var match = null;
          for (var j = 0; j < nodes.length; j++) {
            var n = nodes[j];
            if (isObj(n) && (str(n.id) === want || str(n.name) === want)) { match = n; break; }
          }
          if (!match) break;
          found = match;
          nodes = arr(match.children);
        }
        if (found && found.__key) return found.__key;
      }
    }
    // 2. deepest running step (deployment first)
    var best = null, bestDepth = -1;
    function walk(nodes, depth) {
      arr(nodes).forEach(function (n) {
        if (!isObj(n)) return;
        if (normStatus(n.status) === 'running' && depth > bestDepth) { best = n; bestDepth = depth; }
        walk(n.children, depth + 1);
      });
    }
    ['update', 'deployment', 'validation'].forEach(function (sec) {
      if (!best && isObj(s[sec])) walk(s[sec].tree, 0);
    });
    if (!best && (s.activePhase === 'provisioning' || s.activePhase === 'arc-registration')) walk(app.provTree, 0);
    if (best) return best.__key;
    // 3. by name
    if (cur && cur.stepName) {
      var hit = null;
      app.stepIndex.forEach(function (v, k) { if (!hit && str(v.node.name) === str(cur.stepName)) hit = k; });
      return hit;
    }
    return null;
  }

  function revealKey(key) {
    var info = app.stepIndex.get(key);
    if (!info) return;
    app.sectionCollapsed[info.section] = false;
    var p = info.parentKey;
    while (p && app.stepIndex.has(p)) {
      app.expanded.set(p, true);
      p = app.stepIndex.get(p).parentKey;
    }
  }

  function subtreeHas(n, statuses) {
    var kids = arr(n.children);
    for (var i = 0; i < kids.length; i++) {
      if (!isObj(kids[i])) continue;
      if (statuses.indexOf(normStatus(kids[i].status)) >= 0 || subtreeHas(kids[i], statuses)) return true;
    }
    return false;
  }

  function isExpanded(n) {
    var k = n.__key;
    if (app.expanded.has(k)) return app.expanded.get(k);
    return subtreeHas(n, ['running', 'error']);
  }

  function aggregate(tree) {
    var a = { total: 0, success: 0, error: 0, running: 0, skipped: 0, notstarted: 0, unknown: 0 };
    function walk(nodes) {
      arr(nodes).forEach(function (n) {
        if (!isObj(n)) return;
        if (arr(n.children).length) { walk(n.children); return; } // leaves carry the progress
        a.total++;
        a[normStatus(n.status)]++;
      });
    }
    walk(tree);
    return a;
  }

  function nodeDuration(n) {
    var st = normStatus(n.status), a = parseTime(n.start), b = parseTime(n.end);
    if (st === 'running' && !isNaN(a)) return (nowMs() - a) / 1000;
    if (typeof n.durationSeconds === 'number' && n.durationSeconds >= 0) return n.durationSeconds;
    if (!isNaN(a) && !isNaN(b)) return (b - a) / 1000;
    return null;
  }

  function renderTree(autoScroll) {
    var host = $('tree-host'), s = app.state || {};
    var mode = currentModeId(), wanted = MODE_SECTIONS[mode] || [];
    var route = provRouteOf(s);
    $('steps-title').textContent = 'Steps \u00b7 ' + modeName(mode, route);
    var active = document.activeElement;
    var focusedKey = host.contains(active) && active.getAttribute ? active.getAttribute('data-key') : null;

    // the sections of other modes go away; the section of the mode is built, or rebuilt when something it shows changed
    Array.prototype.forEach.call(host.querySelectorAll('.tree-section'), function (w) {
      if (wanted.indexOf(w.getAttribute('data-section')) < 0) { w.remove(); app.treeSig[w.getAttribute('data-section')] = null; }
    });
    var shown = 0;
    wanted.forEach(function (section) {
      var sec = section === 'provisioning' ? (isObj(s.provisioning) ? s.provisioning : {}) : (isObj(s[section]) ? s[section] : {});
      var tree = section === 'provisioning' ? app.provTree : section === 'extensions' ? app.extTree : arr(sec.tree);
      var only = section === 'provisioning' ? str(app.filter.node).toLowerCase() : '';
      if (only) tree = tree.filter(function (n) { return str(n.name).toLowerCase() === only; });
      var wrap = host.querySelector('.tree-section[data-section="' + section + '"]');
      if (!tree.length) { if (wrap) wrap.remove(); app.treeSig[section] = null; return; }
      shown++;
      var sig = JSON.stringify([tree, sec.status, app.selectedKey, app.currentKey, only, Array.from(app.expanded.entries())],
        function (k, v) { return k === '__key' ? undefined : v; });
      if (wrap && app.treeSig[section] === sig) return;
      app.treeSig[section] = sig;
      var fresh = buildSection(section, tree);
      if (wrap) host.replaceChild(fresh, wrap); else host.appendChild(fresh);
    });

    // validation, then the extensions installed during Validate
    var order = wanted.map(function (k) { return host.querySelector('[data-section="' + k + '"]'); }).filter(Boolean);
    for (var oi = 0; oi < order.length; oi++) {
      if (host.children[oi] !== order[oi]) host.insertBefore(order[oi], host.children[oi] || null);
    }

    var empty = host.querySelector('.tree-empty');
    if (!shown) {
      var sm = app.summary;
      var text = stepsEmptyText(mode, sm ? sm.status : 'idle', sm ? sm.when : '', app.provTree.length > 0);
      if (!empty) { empty = el('p', { class: 'empty tree-empty', id: 'tree-empty' }); host.appendChild(empty); }
      empty.textContent = text;
    } else if (empty) empty.remove();

    if (focusedKey) {
      var f = treeItem(focusedKey);
      if (f) f.focus({ preventScroll: true });
    }
    $('jump-current').disabled = !app.currentKey;
    if (autoScroll) scrollToKey(app.currentKey, false);
    tickTimers();
  }

  // A tree item by key.
  function treeItem(k) {
    return $('tree-host').querySelector('[data-key="' + cssEscape(k) + '"]');
  }

  function cssEscape(s) {
    if (window.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/["\\]/g, '\\$&');
  }

  function buildSection(section, tree) {
    var wrap = el('div', { class: 'tree-section', 'data-section': section });
    var title = section === 'provisioning' ? 'Machines' : section === 'extensions' ? 'Extensions (installed during Validate)' :
      section === 'validation' ? 'Validation' : section === 'update' ? 'Update (unverified against a live run)' : 'Deployment';
    if (section === 'extensions') wrap.appendChild(el('h3', { class: 'sub-h', text: title }));
    var ul = el('ul', { class: 'tree', role: 'tree', id: 'tree-' + section, 'aria-label': title + ' steps' });
    var tabKey = app.focusKey[section] && app.stepIndex.has(app.focusKey[section]) ? app.focusKey[section] :
      (app.currentKey && app.stepIndex.get(app.currentKey) && app.stepIndex.get(app.currentKey).section === section ? app.currentKey : null);
    tree.forEach(function (n) { if (isObj(n)) ul.appendChild(buildItem(n, 1, tabKey, section, [n])); });
    // exactly one tabbable item, and it is visible
    var tabbable = ul.querySelector('[role="treeitem"][tabindex="0"]');
    if (!tabbable || !isVisibleItem(tabbable)) {
      if (tabbable) tabbable.setAttribute('tabindex', '-1');
      var first = ul.querySelector('[role="treeitem"]');
      if (first) first.setAttribute('tabindex', '0');
    }
    ul.addEventListener('keydown', onTreeKey);
    wrap.appendChild(ul);
    return wrap;
  }

  function buildItem(n, level, tabKey, section, chain) {
    var k = n.__key;
    var st = normStatus(n.status);
    var kids = arr(n.children).filter(isObj);
    var hasKids = kids.length > 0;
    var open = hasKids && isExpanded(n);
    var dur = nodeDuration(n);
    var name = str(n.name) || str(n.description) || '(unnamed step)';
    var rule = stepRule(section, chain);
    var selected = app.selectedKey === k;
    var label = name + (rule.side === 'azure' ? ', runs in Azure' : '') + ', ' + (st === 'unknown' ? str(n.status) || 'unknown status' : STATUS_LABEL[st]) +
      (dur !== null ? ', ' + fmtDuration(dur) : '') + (arr(n.errors).length ? ', ' + arr(n.errors).length + ' error message(s)' : '');

    var li = el('li', { role: 'treeitem', 'data-key': k, 'data-side': rule.side, 'aria-level': String(level), 'aria-label': label,
      'aria-selected': String(selected), tabindex: tabKey === k ? '0' : '-1' });
    if (hasKids) li.setAttribute('aria-expanded', String(open));

    var row = el('div', { class: 'row' + (rule.side === 'machine' ? ' row-machine' : ''), 'data-status': st, 'data-current': String(app.currentKey === k) });
    if (hasKids) {
      var cb = el('button', { type: 'button', class: 'caret-btn', tabindex: '-1', 'aria-hidden': 'true' });
      cb.innerHTML = ICON.caret;
      cb.addEventListener('click', function (e) { e.stopPropagation(); toggleKey(k); });
      row.appendChild(cb);
    } else {
      row.appendChild(el('span', { class: 'caret-spacer', 'aria-hidden': 'true' }));
    }
    var ic = el('span', { 'aria-hidden': 'true', title: STATUS_LABEL[st] || st });
    ic.innerHTML = icon(st);
    row.appendChild(ic);

    var nameEl = el('span', { class: 'step-name' });
    if (rule.side !== 'machine' && section !== 'provisioning' && n.id !== undefined && n.id !== null && n.id !== '' && str(n.id) !== name) nameEl.appendChild(el('span', { class: 'idx', text: str(n.id) }));
    nameEl.appendChild(el('span', { class: 'sn', text: name }));
    if (rule.side === 'azure') nameEl.appendChild(el('span', { class: 'az', title: 'This step runs in Azure: Sonar reads its status from Azure, there are no node log lines for it.', text: 'Azure' }));
    var desc = stepDescription(n);
    if (desc) nameEl.appendChild(el('span', { class: 'desc', text: desc }));
    row.appendChild(nameEl);

    var durEl = el('span', { class: 'dur' });
    if (st === 'running' && !isNaN(parseTime(n.start))) durEl.setAttribute('data-start', String(parseTime(n.start)));
    durEl.textContent = dur !== null ? fmtDuration(dur) : '';
    var tt = [];
    if (!isNaN(parseTime(n.start))) tt.push('Start ' + fmtDateTime(parseTime(n.start)));
    if (!isNaN(parseTime(n.end))) tt.push('End ' + fmtDateTime(parseTime(n.end)));
    if (tt.length) durEl.title = tt.join('\n');
    row.appendChild(durEl);

    row.addEventListener('click', function () { selectStep(k); });
    li.appendChild(row);
    if (isObj(n.prov)) li.appendChild(buildProvMeta(n, st));

    if (selected && rule.side === 'azure') li.appendChild(buildAzureDetail(n, st, name));
    var errs = arr(n.errors).map(str).filter(Boolean);
    if (errs.length && !(selected && rule.side === 'azure')) {
      var box = el('div', { class: 'step-errors', role: 'note', 'aria-label': 'Errors for ' + name });
      errs.forEach(function (m) { box.appendChild(el('p', { text: m })); });
      li.appendChild(box);
    }

    if (hasKids) {
      var g = el('ul', { role: 'group' });
      if (!open) g.hidden = true;
      kids.forEach(function (c) { g.appendChild(buildItem(c, level + 1, tabKey, section, chain.concat([c]))); });
      li.appendChild(g);
    }
    return li;
  }

  // Under a clicked Azure step: what Azure says about it (status, start and end, its message, any error).
  function buildAzureDetail(n, st, name) {
    var a = parseTime(n.start), b = parseTime(n.end), d = nodeDuration(n);
    var box = el('div', { class: 'detail', role: 'group', 'aria-label': 'Azure details of ' + name });
    function p(k, v) { return el('p', null, [el('span', { class: 'k', text: k + ' ' }), v]); }
    box.appendChild(el('p', null, [el('b', { text: name }), ' runs in Azure, so there are no node log lines for it; the logs keep their filter.']));
    box.appendChild(p('Status:', STATUS_LABEL[st] === 'In progress' && !isNaN(a) ? 'In progress, since ' + fmtClock(a) : (st === 'unknown' ? str(n.status) || 'Unknown' : STATUS_LABEL[st])));
    if (!isNaN(a)) box.appendChild(p('Started:', fmtClock(a) + (d !== null ? ' \u00b7 ' + fmtDuration(d) + (st === 'running' ? ' so far' : '') : '')));
    if (!isNaN(b)) box.appendChild(p('Ended:', fmtClock(b)));
    box.appendChild(p('Azure says:', str(n.description) && str(n.description) !== name ? str(n.description) : (stepDescription(n) || 'nothing more than the status')));
    var errs = arr(n.errors).map(str).filter(Boolean);
    if (errs.length) {
      var e = el('div', { class: 'detail-errors', role: 'note' });
      errs.forEach(function (m) { e.appendChild(el('p', { text: m })); });
      box.appendChild(el('p', null, [el('span', { class: 'k', text: 'Errors:' })]));
      box.appendChild(e);
    } else box.appendChild(p('Errors:', 'none'));
    return box;
  }

  // Under a machine row: the OEM route's step counters, the probe note and the extension count. The lifecycle, the Arc
  // machine and the progress are on the machine's card above.
  function buildProvMeta(n, st) {
    var p = n.prov;
    var meta = el('div', { class: 'prov-meta' });
    if (p.extensionsTotal) meta.appendChild(el('span', { text: 'Extensions ' + p.extensionsReady + '/' + p.extensionsTotal }));
    [['OS image update', p.update, 'Get-ArcZeroDaySolutionUpdateStatus on the node: finished steps of Scan, Download, Install'],
      ['Bootstrap', p.bootstrap, 'Get-ArcBootstrapStatus on the node: finished steps']].forEach(function (x) {
      var g = x[1];
      // the update runs only when the OEM image is not the latest: no counter until it starts
      if (!g || !g.total || (x[0] === 'OS image update' && (g.status === 'notstarted' || g.status === 'unknown'))) return;
      meta.appendChild(el('span', { class: 'prov-steps', 'data-status': g.status, title: x[2] + (g.current ? '; now ' + g.current : ''),
        text: x[0] + ' ' + g.done + '/' + g.total }));
    });
    var note = probeNote(p.probe, fmtDateTime);
    if (note) meta.appendChild(el('span', { class: 'prov-probe', title: str(p.probe.reason), text: note }));
    if (st === 'error' && n.description) meta.appendChild(el('span', { class: 'prov-msg', text: n.description }));
    return meta.childNodes.length ? meta : document.createDocumentFragment();
  }

  function isVisibleItem(item) {
    var p = item.parentElement;
    while (p && !p.classList.contains('tree')) {
      if (p.hidden) return false;
      p = p.parentElement;
    }
    return true;
  }

  function visibleItems(tree) {
    return Array.prototype.filter.call(tree.querySelectorAll('[role="treeitem"]'), isVisibleItem);
  }

  function focusItem(item) {
    if (!item) return;
    var tree = item.closest('[role="tree"]');
    Array.prototype.forEach.call(tree.querySelectorAll('[role="treeitem"][tabindex="0"]'), function (x) { x.setAttribute('tabindex', '-1'); });
    item.setAttribute('tabindex', '0');
    item.focus();
    var info = app.stepIndex.get(item.getAttribute('data-key'));
    if (info) app.focusKey[info.section] = item.getAttribute('data-key');
  }

  function toggleKey(k, force) {
    var info = app.stepIndex.get(k);
    if (!info) return;
    var now = isExpanded(info.node);
    var next = typeof force === 'boolean' ? force : !now;
    if (next === now) return;
    app.expanded.set(k, next);
    app.focusKey[info.section] = k;
    renderTree(false);
    var item = treeItem(k);
    if (item) focusItem(item);
  }

  function onTreeKey(e) {
    var item = e.target.closest && e.target.closest('[role="treeitem"]');
    if (!item) return;
    var tree = e.currentTarget;
    var items = visibleItems(tree);
    var i = items.indexOf(item);
    var k = item.getAttribute('data-key');
    var hasKids = item.hasAttribute('aria-expanded');
    var open = item.getAttribute('aria-expanded') === 'true';
    switch (e.key) {
      case 'ArrowDown': if (i < items.length - 1) focusItem(items[i + 1]); break;
      case 'ArrowUp': if (i > 0) focusItem(items[i - 1]); break;
      case 'Home': focusItem(items[0]); break;
      case 'End': focusItem(items[items.length - 1]); break;
      case 'ArrowRight':
        if (hasKids && !open) toggleKey(k, true);
        else if (hasKids && open) { var c = item.querySelector('[role="group"] > [role="treeitem"]'); if (c) focusItem(c); }
        break;
      case 'ArrowLeft':
        if (hasKids && open) toggleKey(k, false);
        else { var p = item.parentElement && item.parentElement.closest('[role="treeitem"]'); if (p) focusItem(p); }
        break;
      case 'Enter':
        if (hasKids) toggleKey(k); else selectStep(k);
        break;
      case ' ':
      case 'Spacebar':
        selectStep(k);
        break;
      default: return;
    }
    e.preventDefault();
  }

  function scrollToKey(k, focus) {
    if (!k) return;
    var item = treeItem(k);
    if (!item) return;
    var host = item.closest('.panel-body') || $('tree-host');
    var row = item.querySelector('.row') || item;
    // scroll inside the tree panel only, never the page
    var hr = host.getBoundingClientRect(), rr = row.getBoundingClientRect();
    if (host.scrollHeight > host.clientHeight + 2) {
      if (rr.top < hr.top || rr.bottom > hr.bottom) {
        host.scrollTop += (rr.top - hr.top) - host.clientHeight / 3;
      }
    }
    if (focus) focusItem(item);
  }

  // The chain of items from the top of the step's section down to the step (for stepRule).
  function stepRuleOf(k) {
    var info = app.stepIndex.get(k);
    if (!info) return stepRule('', []);
    var chain = [], cur = info;
    while (cur) {
      chain.unshift(cur.node);
      cur = app.stepIndex.has(cur.parentKey) ? app.stepIndex.get(cur.parentKey) : null;
    }
    return stepRule(info.section, chain);
  }

  // What a click on a step does: an Azure step shows its details under it and leaves the logs alone; a node step filters
  // the logs to its machine and to its time window (or its ZTP stage); a machine row selects the machine like its card.
  // A second click on the same step clears it.
  function selectStep(k) {
    var info = app.stepIndex.get(k);
    if (!info) return;
    var rule = stepRuleOf(k), name = str(info.node.name);
    if (rule.side === 'machine') { selectNode(rule.node); return; }
    if (app.selectedKey === k) { clearStepFilter(); return; }
    app.selectedKey = k;
    app.focusKey[info.section] = k;
    if (rule.side === 'azure') {
      dropStepFilter();
      announce('Azure step ' + name + ': its details are shown under it. The logs keep their filter.');
    } else if (!rule.stage && isNaN(parseTime(info.node.start))) {
      dropStepFilter();
      announce('Step "' + name + '" has no start time yet, so the logs cannot be filtered to it.');
      setError('step', 'Step "' + name + '" has no start time yet; the log filter needs one.');
      setTimeout(function () { setError('step', null); }, 6000);
    } else {
      app.filter.stepKey = rule.stage ? null : k;
      app.filter.stage = rule.stage;
      if (rule.node && str(app.filter.node).toLowerCase() !== rule.node.toLowerCase()) { app.filter.node = rule.node; app.filter.nodeBy = 'step'; }
      announce('Logs filtered to step ' + name + (rule.node ? ' on ' + rule.node : '') + '.');
    }
    renderTree(false);
    renderSummary();
    var item = treeItem(k);
    if (item) focusItem(item);
    renderChips();
    rerenderLogs();
  }

  // Removes the step part of the log filter (the window, the ZTP stage, and the machine when the step chose it).
  function dropStepFilter() {
    app.filter.stepKey = null;
    app.filter.stage = '';
    if (app.filter.nodeBy === 'step') { app.filter.node = ''; app.filter.nodeBy = ''; }
  }

  function clearStepFilter() {
    dropStepFilter();
    app.selectedKey = null;
    renderTree(false);
    renderSummary();
    renderChips();
    rerenderLogs();
    announce('Step filter removed.');
  }

  function stepWindow() {
    var k = app.filter.stepKey;
    if (!k) return null;
    var info = app.stepIndex.get(k);
    if (!info) return null;
    return stepWindowOf(info.node);
  }

  // ------------------------------------------------------------------ mode bar

  var MODE_OF_SECTION = { provisioning: 'prov', validation: 'validate', extensions: 'validate', deployment: 'deploy', update: 'update' };

  // The mode shown: the one the user clicked while the run is still in the same mode, else the active one.
  function currentModeId() {
    var active = activeModeId(app.state);
    if (app.ui.mode && app.ui.pickedAt === active) {
      var t = modeStates(app.state).filter(function (x) { return x.id === app.ui.mode; })[0];
      if (t && !t.hidden) return app.ui.mode;
    }
    var tiles = modeStates(app.state);
    var a = tiles.filter(function (x) { return x.id === active; })[0];
    return a && !a.hidden ? active : (tiles.filter(function (x) { return !x.hidden; })[0] || { id: active }).id;
  }

  var MODE_GLYPH = { ok: '✓', run: '●', idle: '○', err: '✕' };
  var MODE_WORD = { ok: 'done', run: 'running', idle: 'waiting', err: 'failed' };

  function renderModes() {
    var host = $('modes');
    if (!host) return;
    var tiles = modeStates(app.state).filter(function (t) { return !t.hidden; }), cur = currentModeId();
    var sig = JSON.stringify([tiles, cur]);
    if (host.getAttribute('data-sig') === sig) return;
    host.setAttribute('data-sig', sig);
    var focused = document.activeElement && host.contains(document.activeElement) ? document.activeElement.getAttribute('data-m') : null;
    host.style.setProperty('--n', String(tiles.length));
    host.textContent = '';
    tiles.forEach(function (t) {
      var b = el('button', { type: 'button', class: 'mode' + (t.id === cur ? ' sel' : '') + (t.status === 'idle' ? ' off' : ''), 'data-m': t.id,
        'aria-pressed': String(t.id === cur), title: t.tip || null }, [
        el('span', { class: 'mi mi-' + t.status + (t.status === 'run' ? ' pulse' : ''), 'aria-hidden': 'true', text: MODE_GLYPH[t.status] }),
        el('span', { class: 'mt' }, [
          el('span', { class: 'mn', text: t.name }),
          t.line ? el('span', { class: 'ms', text: t.line }) : null
        ]),
        el('span', { class: 'sr-only', text: ', ' + MODE_WORD[t.status] + (t.tip ? '. ' + t.tip : '') })
      ]);
      b.addEventListener('click', function () { setMode(t.id); });
      host.appendChild(b);
    });
    if (focused) { var fb = host.querySelector('[data-m="' + focused + '"]'); if (fb) fb.focus(); }
  }

  // Clicking a tile switches the summary box and the Steps box to that mode and clears the step and machine filters.
  function setMode(id) {
    if (id === currentModeId()) return;
    app.ui.mode = id;
    app.ui.pickedAt = activeModeId(app.state);
    app.ui.lastMode = id;
    clearScope();
    renderModeView();
    announce(modeName(id, provRouteOf(app.state)) + ' selected.');
  }

  function clearScope() {
    app.filter.node = ''; app.filter.nodeBy = ''; app.filter.stepKey = null; app.filter.stage = ''; app.selectedKey = null;
  }

  function renderModeView() {
    renderModes();
    renderSummary();
    renderTree(false);
    renderChips();
    rerenderLogs();
  }

  function tickTimers() {
    var now = nowMs();
    var nodes = document.querySelectorAll('.dur[data-start]');
    for (var i = 0; i < nodes.length; i++) {
      var a = Number(nodes[i].getAttribute('data-start'));
      nodes[i].textContent = fmtDuration((now - a) / 1000);
    }
  }

  // ------------------------------------------------------------------ guidance

  function gkey(v) { return str(v).toLowerCase().replace(/[\s_-]+/g, ''); }

  function guidanceSource() {
    var g = app.guidance;
    return isObj(g) ? (g.phases || g.guidance || g) : g;
  }

  function guidanceModel() {
    return (isObj(app.guidance) && (app.guidance.identityModel || app.guidance.model)) || (app.config && app.config.identityModel) || '';
  }

  function phaseGuidance(phase) {
    var src = guidanceSource(), want = gkey(phase), hit = null;
    if (Array.isArray(src)) {
      for (var j = 0; j < src.length && !hit; j++) {
        if (isObj(src[j]) && gkey(src[j].phase || src[j].name || src[j].id) === want) hit = src[j];
      }
    } else if (isObj(src)) {
      Object.keys(src).forEach(function (k) { if (!hit && gkey(k) === want && isObj(src[k])) hit = src[k]; });
    }
    if (!hit) return null;
    // tolerate entries still keyed by identity model: { LocalIdentity: {...}, ActiveDirectory: {...} }
    var model = gkey(guidanceModel());
    if (model) {
      var sub = null;
      Object.keys(hit).forEach(function (k) { if (!sub && gkey(k) === model && isObj(hit[k])) sub = hit[k]; });
      if (sub) return sub;
    }
    return hit;
  }

  function guidancePhases() {
    var src = guidanceSource(), out = [];
    if (Array.isArray(src)) src.forEach(function (it) { if (isObj(it) && (it.phase || it.name)) out.push(str(it.phase || it.name).toLowerCase()); });
    else if (isObj(src)) Object.keys(src).forEach(function (k) { if (isObj(src[k])) out.push(k.toLowerCase()); });
    return out;
  }

  // The one-line status of the Log access panel (collapsed by default): where the logs are read from, with which
  // account, whether tailing works and when the last line arrived.
  function guidanceSummary(tailer, g, lastLineMs, hasConfig) {
    var parts = [];
    var t = isObj(tailer) ? tailer : null;
    var st = t ? str(t.state).toLowerCase() : '';
    if (st === 'connected') parts.push('Tailing ' + (t.node ? 'node ' + str(t.node) : 'the seed node'));
    else if (st) parts.push('Tailer ' + st + (t && t.node ? ' (node ' + str(t.node) + ')' : ''));
    else parts.push('Tailer not started');
    if (t && t.credential) parts.push('as ' + str(t.credential));
    else if (isObj(g)) {
      var a = pick(g, ['account', 'accounts', 'user', 'who', 'readBy']);
      if (a !== undefined) {
        var first = str(listOf(a)[0]).split(/(?<=[.;])\s/)[0];
        parts.push('account: ' + (first.length > 90 ? first.slice(0, 87) + '\u2026' : first));
      }
    }
    if (typeof lastLineMs === 'number' && !isNaN(lastLineMs)) parts.push('last line ' + fmtAgo(lastLineMs));
    else if (st === 'connected') parts.push('no line yet');
    return 'Log access: ' + parts.join(' \u00b7 ');
  }

  // The Log access window: the one-line status, then per phase the account, the folders, when, how, this deployment,
  // how sure Sonar is, and where it comes from. Opened by the Log access button in the top bar.

  var laReturnFocus = null;

  function laIsOpen() { var m = $('la-modal'); return !!m && !m.hidden; }

  function openLogAccess() {
    app.guidancePhase = null;
    laReturnFocus = document.activeElement;
    closePops(false);
    $('la-modal').hidden = false;
    document.body.classList.add('modal-open');
    renderLogAccessWindow();
    $('la-close').focus();
  }

  function closeLogAccess() {
    $('la-modal').hidden = true;
    document.body.classList.remove('modal-open');
    if (laReturnFocus && laReturnFocus.focus) laReturnFocus.focus();
    laReturnFocus = null;
  }

  // The phase that matches a mode (the tab the window opens on), and the phase that is happening now.
  function phaseOfMode(modeId) {
    var route = provRouteOf(app.state);
    return { prov: route === 'oem-image' ? 'arc-registration' : 'provisioning', validate: 'validation', deploy: 'deployment', update: 'update', health: 'post-deployment' }[modeId] || 'provisioning';
  }
  function currentGuidancePhase() {
    var s = app.state, act = s ? str(s.activePhase).toLowerCase() : '';
    if (act === 'add-node' || act === 'repair') return act;
    return phaseOfMode(activeModeId(s));
  }

  function renderGuidanceSummary() {
    var m = $('la-msg');
    if (!m) return;
    var last = app.store && app.store.lines.length ? parseTime(app.store.lines[app.store.lines.length - 1].received || app.store.lines[app.store.lines.length - 1].time) : NaN;
    var view = app.guidancePhase || phaseOfMode(currentModeId());
    m.textContent = guidanceSummary(app.tailer, app.guidance ? phaseGuidance(view) : null, last, !!app.config);
  }

  function listOf(v) {
    if (v === null || v === undefined || v === '') return [];
    if (Array.isArray(v)) return v.map(function (x) { return isObj(x) ? (x.path || x.name || x.text || JSON.stringify(x)) : str(x); }).filter(Boolean);
    if (isObj(v)) return Object.keys(v).map(function (k) { return k + ': ' + str(v[k]); });
    return [str(v)];
  }

  function pick(o, names) {
    for (var i = 0; i < names.length; i++) {
      if (o[names[i]] !== undefined && o[names[i]] !== null && o[names[i]] !== '') return o[names[i]];
    }
    return undefined;
  }

  // The tabs the window shows: the phases that have guidance, only the machine-readiness phase of the route Sonar follows.
  function laShownPhases() {
    var available = guidancePhases();
    var route = provRouteOf(app.state);
    var hide = route === 'simplified' ? 'arc-registration' : route === 'oem-image' ? 'provisioning' : '';
    var shown = LA_PHASES.filter(function (p) { return available.indexOf(p) >= 0 && p !== hide; });
    available.forEach(function (p) { if (shown.indexOf(p) < 0 && p !== hide) shown.push(p); });
    return shown;
  }

  function renderGuidance() { renderGuidanceSummary(); if (laIsOpen()) renderLogAccessWindow(); }

  function renderLogAccessWindow() {
    var body = $('la-body'), tabs = $('la-tabs');
    if (!body) return;
    renderGuidanceSummary();
    var model = guidanceModel(), id = $('la-id');
    id.textContent = model ? str(model) : '';
    id.hidden = !model;

    var shown = laShownPhases(), now = currentGuidancePhase();
    var wanted = phaseOfMode(currentModeId());
    var fallback = shown.indexOf(wanted) >= 0 ? wanted : (shown.indexOf(now) >= 0 ? now : shown[0]);
    if (app.guidancePhase && shown.indexOf(app.guidancePhase) < 0) app.guidancePhase = null;
    var view = app.guidancePhase || fallback;

    tabs.textContent = '';
    tabs.hidden = !shown.length;
    shown.forEach(function (p) {
      var b = el('button', { type: 'button', class: 'ptab', role: 'tab', id: 'la-tab-' + p, 'data-p': p, 'aria-selected': String(p === view),
        'aria-controls': 'la-body', tabindex: p === view ? '0' : '-1' }, [phaseLabel(p) + (p === now ? ' (current phase)' : '')]);
      b.addEventListener('click', function () { app.guidancePhase = p; renderLogAccessWindow(); var nb = $('la-tab-' + p); if (nb) nb.focus(); });
      tabs.appendChild(b);
    });
    body.setAttribute('aria-labelledby', 'la-tab-' + view);

    body.textContent = '';
    if (!app.guidance) {
      body.appendChild(el('p', { class: 'muted', text: app.errors.has('guidance') ? 'Guidance is unavailable.' : 'Loading guidance…' }));
      return;
    }
    var g = phaseGuidance(view);
    if (!g) {
      body.appendChild(el('p', { class: 'muted', text: 'No guidance recorded for the ' + phaseLabel(view) + ' phase.' }));
      return;
    }
    var dl = el('dl', { class: 'gk' });
    function row(label, valueNode) { dl.appendChild(el('dt', { text: label })); dl.appendChild(el('dd', null, [valueNode])); }

    var account = pick(g, ['account', 'accounts', 'user', 'who', 'readBy']);
    if (account !== undefined) row('Account', textList(listOf(account), false));
    var where = pick(g, ['where', 'logs', 'logPaths', 'paths', 'location', 'locations', 'logLocation']);
    if (where !== undefined) row('Where', textList(listOf(where), true));
    var when = pick(g, ['when', 'available', 'availability', 'whenAvailable']);
    if (when !== undefined) row('When', textList(listOf(when), false));
    var how = pick(g, ['how', 'access', 'method']);
    if (how !== undefined) row('How', textList(listOf(how), false));
    var profile = app.config && isObj(app.config.profile) ? arr(app.config.profile.notes) : [];
    if (profile.length) row('This deployment', textList(profile.map(str), false));
    var timing = pick(g, ['timing', 'duration', 'expected']);
    if (timing !== undefined) row('How long', textList(listOf(timing), false));
    var cmds = pick(g, ['commands', 'checks']);
    if (cmds !== undefined && listOf(cmds).length) row('Commands', textList(listOf(cmds), true));

    var ver = g.verified;
    var confirmedOn = typeof g.confirmedOn === 'string' && g.confirmedOn ? g.confirmedOn : 'a real deployment';
    var vBox = el('div');
    vBox.appendChild(el('span', { class: 'pill ' + (ver === true ? 'pill-ok' : ver === false ? 'pill-warn' : 'pill-muted'),
      text: ver === true ? 'Confirmed on ' + confirmedOn : ver === false ? 'From Microsoft docs — not yet confirmed' : 'Unknown' }));
    if (typeof g.observed === 'string' && g.observed) vBox.appendChild(el('p', { class: 'guide-note', text: g.observed }));
    if (ver !== true) vBox.appendChild(el('p', { class: 'guide-note', text: 'If the logs are not where this says, Sonar still finds them: it watches every known log folder. Please open an issue on GitHub so this entry can be corrected.' }));
    row('Confidence', vBox);

    var src = pick(g, ['source', 'sources', 'reference', 'references']);
    if (src !== undefined) {
      var ul = el('ul');
      listOf(src).forEach(function (s) {
        var li = el('li');
        var sl = safeLink(s);
        if (sl) li.appendChild(el('a', { href: sl, target: '_blank', rel: 'noopener noreferrer', text: s }));
        else li.appendChild(document.createTextNode(s));
        ul.appendChild(li);
      });
      row('Source', ul);
    }
    body.appendChild(dl);
    var notes = pick(g, ['notes', 'note', 'details']);
    if (notes !== undefined) body.appendChild(el('p', { class: 'notes', text: listOf(notes).join(' ') }));
  }

  // Close button, scrim click, Escape, a Tab that stays inside the window, and the arrow keys between the phase tabs.
  function wireLogAccess() {
    $('la-close').addEventListener('click', closeLogAccess);
    $('la-modal').addEventListener('click', function (e) { if (e.target === $('la-modal')) closeLogAccess(); });
    document.addEventListener('keydown', function (e) {
      if (!laIsOpen()) return;
      if (e.key === 'Escape') { e.preventDefault(); closeLogAccess(); return; }
      if (e.key !== 'Tab') return;
      var f = Array.prototype.filter.call($('la-modal').querySelectorAll('button, a[href], [tabindex="0"]'), function (x) { return !x.disabled && x.offsetParent !== null; });
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
    $('la-tabs').addEventListener('keydown', function (e) {
      var keys = { ArrowRight: 1, ArrowLeft: -1, Home: 'first', End: 'last' };
      if (!(e.key in keys)) return;
      var list = Array.prototype.slice.call($('la-tabs').querySelectorAll('[role="tab"]'));
      var i = list.indexOf(document.activeElement);
      if (i < 0) return;
      var next = keys[e.key] === 'first' ? 0 : keys[e.key] === 'last' ? list.length - 1 : (i + keys[e.key] + list.length) % list.length;
      e.preventDefault();
      list[next].click();
    });
    var alertLink = $('tailer-alert-link');
    if (alertLink) alertLink.addEventListener('click', openLogAccess);
  }

  function textList(items, code) {
    if (items.length === 1 && !code) return document.createTextNode(items[0]);
    var ul = el('ul');
    items.forEach(function (t) { ul.appendChild(el('li', null, [code ? el('code', { text: t }) : t])); });
    return ul;
  }

  // ------------------------------------------------------------------ tailer + files

  function applyTailer(t) {
    if (!isObj(t)) return;
    app.tailer = t;
    renderLogAccessButton();
    var state = str(t.state).toLowerCase() || 'unknown';
    var pill = $('tailer-pill');
    pill.setAttribute('data-tailer', state);
    var label = 'Tailer: ' + (state === 'connected' ? 'connected' : state);
    if (state === 'connected' && t.node) label += ' to ' + t.node;
    pill.textContent = label;
    pill.title = t.reason ? str(t.reason) : label;
    var bad = state === 'unavailable' || state === 'error' || state === 'disconnected';
    $('tailer-alert').hidden = !bad;
    $('tailer-reason').textContent = bad ? (t.reason ? str(t.reason) : 'No reason reported.') + (t.node ? ' (node ' + t.node + ')' : '') : '';
    if (app.lastAnnounced.tailer !== null && app.lastAnnounced.tailer !== state) {
      announce(bad ? 'Live logs unavailable: ' + str(t.reason) : 'Log tailer ' + state + '.');
    }
    app.lastAnnounced.tailer = state;
    if (Array.isArray(t.activeFiles)) applyFiles(t.activeFiles);
  }

  // The tailer's current file list replaces the previous one (files that left it stay only while lines from them are held).
  function applyFiles(files) {
    app.reportedFiles = arr(files).map(function (f) { return str(isObj(f) ? f.path : f); }).filter(Boolean);
    renderFileOptions();
  }

  function renderFileOptions() {
    var sel = $('file-filter');
    var list = fileOptionList(app.reportedFiles, app.store.fileCounts);
    var sig = list.join('\n');
    if (sig !== app.fileSig) {
      app.fileSig = sig;
      sel.textContent = '';
      sel.appendChild(el('option', { value: '', text: 'All files (' + list.length + ')' }));
      list.forEach(function (p) { sel.appendChild(el('option', { value: p, title: p, text: basename(p) || p })); });
    }
    var cur = app.filter.file;
    if (cur && keptFileSelection(list, cur) !== cur) {
      // the selected file is neither reported nor in the held lines any more
      app.filter.file = '';
      sel.value = '';
      renderChips();
      rerenderLogs();
    } else {
      sel.value = cur;
    }
  }

  // ------------------------------------------------------------------ top bar: log access dot, Help box, Details pop-down

  // Green: the node logs are read live. Amber: Azure only (the node logs are not available). Red: nothing answers.
  function logAccessKind() {
    if (str(app.tailer && app.tailer.state).toLowerCase() === 'connected') return 'live';
    return app.state && !app.state.pollError ? 'azure' : 'none';
  }

  function renderLogAccessButton() {
    var btn = $('la-btn');
    if (!btn) return;
    var k = logAccessKind();
    $('la-dot').className = 'dot dot-' + { live: 'ok', azure: 'warn', none: 'err' }[k];
    var text = { live: 'the node logs are live', azure: 'Azure only, the node logs are not available', none: 'neither Azure nor the node logs answer' }[k];
    btn.title = 'Log access: ' + text + '. Open it for the account, folders and timing of each phase.';
    $('la-sr').textContent = ' (' + text + ')';
    var modal = $('la-modal');
    if (modal && !modal.hidden) renderLogAccessWindow();
  }

  var POPS = { details: { btn: 'details-btn', pop: 'details-pop' }, help: { btn: 'help-btn', pop: 'help-pop' } };
  var detailsTimer = null;

  function popIsOpen(id) { return !$(POPS[id].pop).hidden; }

  function setPop(id, open) {
    var p = POPS[id];
    $(p.pop).hidden = !open;
    $(p.btn).setAttribute('aria-expanded', String(open));
    if (id === 'details') {
      $('details-btn').querySelector('.btn-caret').textContent = open ? '▴' : '▾';
      clearInterval(detailsTimer);
      if (open) { loadDetails(); detailsTimer = setInterval(loadDetails, 10000); }
    }
    if (open) {
      Object.keys(POPS).forEach(function (k) { if (k !== id && popIsOpen(k)) setPop(k, false); });
      if (id === 'help') loadAbout();
      var first = $(p.pop).querySelector('a, button');
      if (id === 'help' && first) first.focus();
    }
  }

  function closePops(returnFocus) {
    Object.keys(POPS).forEach(function (k) {
      if (!popIsOpen(k)) return;
      setPop(k, false);
      if (returnFocus) $(POPS[k].btn).focus();
    });
  }

  // ----- Help box (/api/about)

  function loadAbout() {
    if (app.about) { renderHelp(); return Promise.resolve(); }
    return getJSON('/api/about').then(function (a) { if (isObj(a)) { app.about = a; renderHelp(); if (app.details) renderDetails(); } }, function () { renderHelp(); });
  }

  function renderHelp() {
    var a = app.about, links = $('help-links');
    $('help-version').textContent = a && a.version ? 'v' + a.version : '';
    $('help-version').hidden = !(a && a.version);
    if (a && a.summary) $('help-summary').textContent = a.summary;
    if (!a || !arr(a.links).length) return;
    links.textContent = '';
    arr(a.links).filter(isObj).forEach(function (l) {
      var href = safeLink(l.url);   // https on a known documentation host, else it is only text
      if (href) links.appendChild(el('a', { class: 'lk', href: href, target: '_blank', rel: 'noopener noreferrer', text: str(l.label) + ' ↗' }));
      else links.appendChild(el('span', { class: 'lk', text: str(l.label) }));
    });
  }

  // ----- Details pop-down (/api/details): what Sonar collected and is using

  function loadDetails() {
    if (DEMO) { app.details = demoDetails(); renderDetails(); return Promise.resolve(); }
    return getJSON('/api/details').then(function (d) { if (isObj(d)) { app.details = d; renderDetails(); } },
      function (e) { $('details-body').textContent = ''; $('details-body').appendChild(el('p', { class: 'muted', text: 'The details are not available: ' + e.message })); });
  }

  // A time as "<prefix> N s ago"; the text is kept current by tickAges.
  function ageEl(prefix, iso) {
    var t = parseTime(iso);
    if (isNaN(t)) return null;
    return el('span', { class: 'age', 'data-t': String(t), 'data-prefix': prefix, title: fmtDateTime(t), text: prefix + fmtAgo(t) });
  }

  function tickAges() {
    var nodes = document.querySelectorAll('.age[data-t]');
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].textContent = nodes[i].getAttribute('data-prefix') + fmtAgo(Number(nodes[i].getAttribute('data-t')));
    }
  }

  function copyText(text, btn) {
    function done() { var old = btn.textContent; btn.textContent = 'copied'; setTimeout(function () { btn.textContent = old; }, 1500); }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
    else {
      var ta = el('textarea', { 'aria-hidden': 'true', style: 'position:fixed;left:-999px' });
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { /* clipboard blocked */ }
      ta.remove();
    }
  }

  // The grey "where it came from, how old" text after a value: parts (strings or elements) joined with a dot.
  function srcGroup(parts) {
    var list = arr(parts).filter(function (p) { return p !== null && p !== undefined && p !== ''; });
    if (!list.length) return null;
    var wrap = el('span', { class: 'src' });
    list.forEach(function (p, i) {
      if (i) wrap.appendChild(document.createTextNode(' · '));
      wrap.appendChild(typeof p === 'string' ? document.createTextNode(p) : p);
    });
    return wrap;
  }

  function renderDetails() {
    var d = app.details, host = $('details-body');
    if (!isObj(d)) return;
    host.textContent = '';
    var replay = d.mode === 'replay' || !!app.replay;
    function group(title, wide) {
      var dl = el('dl', { class: 'kv' });
      host.appendChild(el('div', { class: 'grp' + (wide ? ' grp-wide' : '') }, [el('h3', { text: title }), dl]));
      return dl;
    }
    // One label and value; extra: the source group and any button after the value.
    function row(dl, label, value, extra) {
      dl.appendChild(el('dt', { text: label }));
      var dd = el('dd');
      var empty = value === '' || value === null || value === undefined;
      dd.appendChild(el('span', { class: 'val' + (empty ? ' warnk' : ''), text: empty ? (replay ? 'not in the recording' : 'not set') : String(value) }));
      arr(extra).forEach(function (x) { if (x) dd.appendChild(x); });
      dl.appendChild(dd);
    }
    var cfgRead = d.config && d.config.readAt ? ageEl('read ', d.config.readAt) : null;

    var t = isObj(d.target) ? d.target : {};
    var g1 = group('Target');
    row(g1, 'Cluster', t.cluster && t.cluster.value, [srcGroup([t.cluster && t.cluster.source])]);
    var rgName = str(t.resourceGroup && t.resourceGroup.value);
    var rgCopy = el('button', { type: 'button', class: 'cp', text: 'copy', 'aria-label': 'Copy the resource group name' });
    rgCopy.addEventListener('click', function () { copyText(rgName, rgCopy); });
    row(g1, 'Resource group', rgName, [rgName ? rgCopy : null, srcGroup([t.resourceGroup && t.resourceGroup.source])]);
    row(g1, 'Subscription', t.subscription && t.subscription.value, [srcGroup([t.subscription && t.subscription.note, t.subscription && t.subscription.source])]);
    row(g1, 'Region', t.region && t.region.value, [srcGroup([t.region && t.region.source])]);

    var g2 = group('Mode');
    row(g2, 'Route', d.route && d.route.label, [srcGroup([d.route && d.route.source])]);
    row(g2, 'Identity', d.identity && d.identity.label, [srcGroup([d.identity && d.identity.source])]);
    if (d.identity && d.identity.meaning) { g2.appendChild(el('dt')); g2.appendChild(el('dd', { class: 'src-note', text: d.identity.meaning })); }

    var g3 = group('Nodes');
    var nodes = arr(d.nodes).filter(isObj);
    if (!nodes.length) row(g3, 'Nodes', '');
    nodes.forEach(function (n) {
      g3.appendChild(el('dt', { class: 'mono-name', text: str(n.name), title: str(n.name) }));
      g3.appendChild(el('dd', null, [el('span', { class: 'val mono', text: n.address ? str(n.address) : (replay ? 'not in the recording' : 'no address') }),
        n.seed ? el('span', { class: 'src', text: 'seed node' }) : null]));
    });

    var s = isObj(d.sources) ? d.sources : {};
    var g4 = group('Sources');
    var az = isObj(s.azure) ? s.azure : {};
    row(g4, 'Azure', replay ? 'recorded polls' : (az.pollSeconds ? 'every ' + az.pollSeconds + ' s' : ''),
      [srcGroup([az.lastAnswerAt ? ageEl('last answer ', az.lastAnswerAt) : null, az.lastAnswerAt ? (az.ok ? 'OK' : (az.message || 'not answering')) : null])]);
    var zt = isObj(s.ztpEvents) ? s.ztpEvents : {};
    if (zt.configured) {
      row(g4, 'ZTP events', zt.events + ' event' + (zt.events === 1 ? '' : 's'),
        [srcGroup([zt.lastEventAt ? ageEl('last ', zt.lastEventAt) : (zt.events ? null : 'none yet'), zt.fileFound ? 'file ' + zt.file : 'file ' + zt.file + ' not found yet'])]);
    } else {
      row(g4, 'ZTP events', replay ? '' : 'no event file set', [srcGroup([replay ? '' : 'the machine steps from the nodes are not shown'])]);
    }
    var nl = isObj(s.nodeLogs) ? s.nodeLogs : {};
    // A replay shows the recorded tailer, not the idle one of the replay server.
    if (replay && isObj(app.tailer)) nl = { state: app.tailer.state, node: app.tailer.node, credential: app.tailer.credential, reason: app.tailer.reason };
    var live =str(nl.state).toLowerCase() === 'connected';
    row(g4, 'Node logs', live ? 'live from the seed node' + (nl.node ? ' (' + nl.node + ')' : '') : 'not available: Azure status only',
      [srcGroup(live ? [(nl.transport && nl.transport !== 'auto' ? 'via ' + nl.transport : ''), (nl.credential ? 'as ' + nl.credential : ''), nl.lastLineAt ? ageEl('last line ', nl.lastLineAt) : null] :
        [firstLine(nl.reason || 'the tailer has not connected yet', 90), nl.lastLineAt ? ageEl('last line ', nl.lastLineAt) : null])]);

    var c = isObj(d.config) ? d.config : {};
    var g5 = group('Config', true);
    var readFrom = str(c.readFrom) + (c.file ? ' (' + c.file + ')' : '');
    var cfgParts = [cfgRead];
    if (c.sourceKind === 'infrastructure' && c.checkEverySeconds) {
      cfgParts.push('re-read every ' + c.checkEverySeconds + ' s');
      cfgParts.push(c.lastChangeAt ? ageEl('last change picked up ', c.lastChangeAt) : 'no change since it was read');
      if (c.lastChangeAt && c.lastChangeNote) cfgParts.push(firstLine(c.lastChangeNote, 110));
    } else if (!replay) {
      cfgParts.push('read when Sonar started; restart Sonar to pick up a change');
    }
    row(g5, 'Read from', readFrom, [srcGroup(cfgParts)]);
    var ns = arr(c.notSet).filter(isObj);
    g5.appendChild(el('dt', { text: 'Not set' }));
    var nsDd = el('dd');
    if (!ns.length) nsDd.appendChild(el('span', { class: 'val', text: replay ? 'not recorded' : 'nothing: every setting Sonar uses is set' }));
    ns.forEach(function (n) {
      nsDd.appendChild(el('div', null, [el('span', { class: 'val warnk', text: str(n.label) + ': ' + str(n.effect) }), srcGroup(['set ' + str(n.key) + ' to change'])]));
    });
    g5.appendChild(nsDd);
    var ver = str(c.version || (app.about && app.about.version) || '');
    row(g5, 'Version', ver ? 'Sonar ' + ver : 'Sonar', []);
  }

  // Sample details for ?demo=1 (documentation addresses and an example name only).
  function demoDetails() {
    var now = Date.now(), iso = function (ago) { return new Date(now - ago).toISOString(); };
    var cfg = app.config || {}, state = app.state || {}, route = provRouteOf(state) || 'oem-image';
    var simplified = route === 'simplified';
    var names = arr(cfg.nodes).map(function (n, i) { return { name: n.name, address: '192.0.2.' + (11 + i), seed: !!n.seed }; });
    return {
      generatedAt: iso(0), mode: 'live',
      target: {
        cluster: { value: str(state.cluster || cfg.cluster), source: 'from infrastructure.yml cluster.name' },
        resourceGroup: { value: str(cfg.resourceGroup), source: 'from infrastructure.yml azure.resource_group' },
        subscription: { value: '00000000...', source: 'from infrastructure.yml azure.subscription_id', note: 'first 8 characters only' },
        region: { value: 'eastus', source: 'from infrastructure.yml azure.location' }
      },
      route: { value: route, label: simplified ? 'Simplified machine provisioning (ZTP)' : 'OEM image + Arc registration', source: 'from infrastructure.yml scenario.os_install' },
      identity: { value: 'ActiveDirectory', label: 'Active Directory', source: 'from infrastructure.yml scenario.identity',
        meaning: 'Machines join your domain at deployment; Sonar reads the deployment log with a domain or local account.' },
      nodes: names,
      sources: {
        azure: { pollSeconds: Number(cfg.pollSeconds) || 20, lastAnswerAt: str(state.polledAt) || iso(12000), ok: true, message: '' },
        ztpEvents: { configured: simplified, file: 'ztp-events.jsonl', fileFound: true, events: 212, lastEventAt: iso(4000) },
        nodeLogs: { state: str(app.tailer && app.tailer.state) || 'connected', node: str(app.tailer && app.tailer.node), credential: 'supplied', transport: 'auto',
          reason: str(app.tailer && app.tailer.reason), lastLineAt: iso(3000) }
      },
      config: { readFrom: 'infrastructure.yml', file: 'infrastructure.yml', sourceKind: 'infrastructure', readAt: iso(30 * 60000), checkedAt: iso(20000), checkEverySeconds: 60,
        lastChangeAt: iso(2 * 60000), lastChangeNote: 'node set changed (added: ' + (names.length ? names[names.length - 1].name : 'a node') + ')',
        notSet: [{ setting: 'credential', label: 'Log account', key: 'credential.source', effect: 'using the signed-in Windows identity' }], version: (app.about && app.about.version) || '' }
    };
  }

  // ------------------------------------------------------------------ logs

  // Same rule as the back end (Get-AzlSonarLineLevel); used only for lines that arrive without a level. Zero-count
  // summaries ('error=0', 'Failed: 0', '0 failed', 'warning count=0', 'errors: 0') are not problems.
  function normLevel(l, text) {
    var k = str(l).toLowerCase();
    if (k === 'error' || k === 'err' || k === 'fatal' || k === 'critical') return 'error';
    if (k === 'warning' || k === 'warn') return 'warning';
    if (k) return 'info';
    var rest = str(text)
      .replace(/\b(?:errors?|exceptions?|failed|failures?|fatal|warnings?|warn)(?:\s+count)?\s*[:=]\s*0+(?![\w]|[.,]\d)/gi, ' ')
      .replace(/(^|[^\w.,])0+\s+(?:errors?|exceptions?|failed|failures?|fatal|warnings?)\b/gi, '$1 ');
    if (/\b(error|exception|failed|fatal)\b/i.test(rest)) return 'error';
    if (/\bwarn(ing)?\b/i.test(rest)) return 'warning';
    return 'info';
  }

  function recount() {
    var c = { all: 0, warning: 0, error: 0 };
    app.store.lines.forEach(function (l) { c.all++; if (l.level !== 'info') c[l.level]++; });
    app.counts = c;
  }

  function renderCounts() {
    ['all', 'warning', 'error'].forEach(function (k) {
      $('cnt-' + k).textContent = app.counts[k].toLocaleString();
      var badge = $('cnt-' + k).parentElement;
      badge.setAttribute('data-nonzero', String(app.counts[k] > 0));
    });
    var btns = $('level-filter').querySelectorAll('button');
    Array.prototype.forEach.call(btns, function (b) {
      var lv = b.getAttribute('data-level');
      var n = lv === 'all' ? app.counts.all : lv === 'warning' ? app.counts.warning + app.counts.error : app.counts.error;
      var base = lv === 'all' ? 'All' : lv === 'warning' ? 'Warnings+' : 'Errors';
      b.textContent = base + ' ' + n.toLocaleString();
      b.setAttribute('aria-label', (lv === 'warning' ? 'Warnings and errors' : base) + ', ' + n + ' lines');
    });
  }

  function seedName() {
    var n = arr(app.config && app.config.nodes).filter(function (x) { return isObj(x) && x.seed; })[0];
    return n ? str(n.name) : str(app.tailer && app.tailer.node);
  }

  // Lines in the scope of the machine / step filters only (not level, file or search): used to tell an empty scope
  // from a scope that the other filters emptied.
  function lineInView(l, win) {
    return lineInScope(l, app.filter, win, seedName());
  }

  function lineMatches(l, win) {
    var f = app.filter;
    if (f.level === 'error' && l.level !== 'error') return false;
    if (f.level === 'warning' && l.level === 'info') return false;
    if (f.file && l.file !== f.file) return false;
    if (!lineInView(l, win)) return false;
    if (f.q) {
      if (l.lc === null) l.lc = l.text.toLowerCase();
      if (l.lc.indexOf(f.q) < 0 && l.file.toLowerCase().indexOf(f.q) < 0) return false;
    }
    return true;
  }

  function buildLine(l) {
    var row = document.createElement('div');
    row.className = 'll l-' + l.level;
    var ts = document.createElement('span');
    var approx = l.timeSource === 'received';
    ts.className = approx ? 'ts approx' : 'ts';
    ts.textContent = (approx ? '~' : '') + (isNaN(l.t) ? l.time.slice(0, 12) : fmtClock(l.t));
    if (l.time) {
      ts.title = l.timeSource === 'line' ? 'Logged ' + fmtDateTime(l.t) + ' (' + l.time + ', from the line); received ' + fmtDateTime(l.r) :
        l.timeSource === 'file' ? 'File name time ' + fmtDateTime(l.t) + ' (the line has no timestamp); received ' + fmtDateTime(l.r) :
        'Received ' + fmtDateTime(l.r) + ' (approximate: the line has no timestamp of its own)';
    }
    var lv = document.createElement('span');
    lv.className = 'lv';
    lv.textContent = l.level === 'error' ? 'ERR' : l.level === 'warning' ? 'WRN' : '';
    var fn = document.createElement('span');
    fn.className = 'fn';
    fn.textContent = basename(l.file);
    fn.title = l.file;
    var tx = document.createElement('span');
    tx.className = 'tx';
    highlightInto(tx, l.text, app.filter.q);
    row.appendChild(ts); row.appendChild(lv); row.appendChild(fn); row.appendChild(tx);
    return row;
  }

  function highlightInto(node, text, q) {
    if (!q) { node.textContent = text; return; }
    var lc = text.toLowerCase(), pos = 0, i;
    var guard = 0;
    while ((i = lc.indexOf(q, pos)) >= 0 && guard++ < 200) {
      if (i > pos) node.appendChild(document.createTextNode(text.slice(pos, i)));
      var mk = document.createElement('mark');
      mk.textContent = text.slice(i, i + q.length);
      node.appendChild(mk);
      pos = i + q.length;
    }
    if (pos < text.length) node.appendChild(document.createTextNode(text.slice(pos)));
  }

  function rerenderLogs() {
    var view = $('log-view');
    var win = stepWindow();
    var matched = [];
    for (var i = app.store.lines.length - 1; i >= 0 && matched.length < MAX_RENDERED_LINES; i--) {
      if (lineMatches(app.store.lines[i], win)) matched.push(app.store.lines[i]);
    }
    matched.reverse();
    var frag = document.createDocumentFragment();
    matched.forEach(function (l) { frag.appendChild(buildLine(l)); });
    view.textContent = '';
    view.appendChild(frag);
    app.rendered = matched.length;
    app.newWhilePaused = 0;
    updateEmpty();
    updateLogStatus();
    if (app.follow) view.scrollTop = view.scrollHeight;
    updateNewLines();
  }

  function appendLogs(fresh) {
    var view = $('log-view');
    var win = stepWindow();
    var frag = document.createDocumentFragment(), added = 0;
    fresh.forEach(function (l) { if (lineMatches(l, win)) { frag.appendChild(buildLine(l)); added++; } });
    if (!added) { updateLogStatus(); return; }
    var empty = view.querySelector('.log-empty');
    if (empty) empty.remove();
    view.appendChild(frag);
    app.rendered += added;
    var excess = app.rendered - MAX_RENDERED_LINES;
    if (excess > 0) {
      var before = view.scrollHeight;
      for (var i = 0; i < excess && view.firstChild; i++) view.removeChild(view.firstChild);
      app.rendered -= excess;
      if (!app.follow) view.scrollTop -= (before - view.scrollHeight); // keep the reader's place
    }
    if (app.follow) view.scrollTop = view.scrollHeight;
    else app.newWhilePaused += added;
    updateLogStatus();
    updateNewLines();
  }

  function updateEmpty() {
    var view = $('log-view');
    if (app.rendered) return;
    var win = stepWindow(), scoped = 0;
    for (var i = 0; i < app.store.lines.length && !scoped; i++) { if (lineInView(app.store.lines[i], win)) scoped = 1; }
    var v = emptyLogView(app.filter, scoped, app.store.lines.length, app.tailer && app.tailer.state);
    var box = el('div', { class: 'log-empty', role: 'status', 'data-kind': v.kind }, [el('b', { text: v.title }), v.text ? el('span', { text: v.text }) : null]);
    if (v.actions.length) {
      var btns = el('div', { class: 'log-empty-actions' });
      v.actions.forEach(function (a) {
        var label = { node: 'Show all lines for this node', clear: 'Clear filter', clearAll: 'Clear all filters' }[a];
        var b = el('button', { type: 'button', class: 'btn btn-sm', 'data-action': a, text: label });
        b.addEventListener('click', function () { emptyAction(a); });
        btns.appendChild(b);
      });
      box.appendChild(btns);
    }
    view.appendChild(box);
  }

  // The buttons of the empty log pane.
  function emptyAction(a) {
    if (a === 'node') {
      // keep the machine, drop the step: the machine's own lines
      app.filter.nodeBy = 'card';
      dropStepFilter();
      app.selectedKey = null;
    } else {
      clearScope();
      if (a === 'clearAll') {
        app.filter.level = 'all'; app.filter.q = ''; app.filter.file = '';
        $('log-search').value = ''; $('file-filter').value = '';
        Array.prototype.forEach.call($('level-filter').querySelectorAll('button'), function (x) { x.setAttribute('aria-pressed', String(x.getAttribute('data-level') === 'all')); });
      }
    }
    renderTree(false);
    renderSummary();
    renderChips();
    rerenderLogs();
  }

  function updateLogStatus() {
    var parts = [];
    var filtered = app.filter.level !== 'all' || app.filter.q || app.filter.file || app.filter.stepKey || app.filter.node || app.filter.stage;
    parts.push('Showing ' + app.rendered.toLocaleString() + (filtered ? ' matching' : '') + ' of ' + app.store.lines.length.toLocaleString() + ' lines');
    if (app.rendered >= MAX_RENDERED_LINES) parts.push('newest ' + MAX_RENDERED_LINES.toLocaleString() + ' rendered; export for the full log');
    $('log-status').textContent = parts.join(' \u00b7 ');
  }

  function updateNewLines() {
    var b = $('new-lines');
    if (app.follow || !app.newWhilePaused) { b.hidden = true; return; }
    b.hidden = false;
    b.textContent = app.newWhilePaused.toLocaleString() + ' new line' + (app.newWhilePaused === 1 ? '' : 's') + ' \u2193';
  }

  function setFollow(on) {
    if (app.follow === on) return;
    app.follow = on;
    var b = $('follow-btn');
    b.setAttribute('aria-pressed', String(on));
    $('follow-label').textContent = on ? 'Following' : 'Paused';
    b.title = on ? 'Auto-scroll is on. Scroll up or click to pause.' : 'Auto-scroll is paused. Click to follow the newest lines.';
    if (on) {
      app.newWhilePaused = 0;
      var v = $('log-view');
      v.scrollTop = v.scrollHeight;
    }
    updateNewLines();
  }

  function renderChips() {
    var host = $('filter-chips');
    host.textContent = '';
    function chip(text, title, onRemove) {
      var b = el('button', { type: 'button', 'aria-label': 'Remove filter: ' + text, title: 'Remove filter' });
      b.innerHTML = ICON.close;
      b.addEventListener('click', onRemove);
      host.appendChild(el('span', { class: 'filter-chip', title: title }, [el('span', { class: 'chip-text', text: text }), b]));
    }
    if (app.filter.node) {
      chip('Machine: ' + app.filter.node, 'Only the lines of this machine: its ZTP events, and the node log when it is the machine Sonar reads.', function () {
        app.filter.node = ''; renderSummary(); renderChips(); rerenderLogs(); $('log-view').focus();
      });
    }
    if (app.filter.stage && app.selectedKey && app.stepIndex.has(app.selectedKey)) {
      chip('Step: ' + str(app.stepIndex.get(app.selectedKey).node.name) + ' (ZTP ' + app.filter.stage + ' events)', 'The ZTP event lines of this stage for this machine.', function () {
        clearStepFilter();
        $('log-view').focus();
      });
    }
    var win = stepWindow();
    if (win) {
      var range = fmtClock(win.rawStart) + ' \u2013 ' + (isNaN(win.rawEnd) ? 'now' : fmtClock(win.rawEnd));
      chip('Step: ' + win.name + ' (' + range + ')', 'Lines logged while this step ran (\u00b11 s). Lines with their own timestamp match by that time (UTC); lines without one (marked ~) match by the time Sonar received them, which is approximate.', function () {
        clearStepFilter();
        var lv = $('log-view'); lv.focus();
      });
    }
    if (app.filter.file) {
      chip('File: ' + basename(app.filter.file), app.filter.file, function () {
        app.filter.file = ''; $('file-filter').value = ''; renderChips(); rerenderLogs(); $('file-filter').focus();
      });
    }
    if (app.filter.q) {
      chip('Text: "' + $('log-search').value + '"', 'Text search', function () {
        $('log-search').value = ''; app.filter.q = ''; renderChips(); rerenderLogs(); $('log-search').focus();
      });
    }
  }

  // ------------------------------------------------------------------ export

  function doExport() {
    var btn = $('export-btn');
    btn.disabled = true;
    var cluster = (app.state && app.state.cluster) || cfgCluster(app.config) || 'cluster';
    var stamp = new Date().toISOString().replace(/[:]/g, '').replace(/\..+$/, '') + 'Z';
    var name = 'azl-sonar-' + String(cluster).replace(/[^\w.-]+/g, '_') + '-' + stamp + '.json';
    var p = DEMO ? Promise.resolve(demoExport()) : fetch('/api/export', { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error('/api/export returned HTTP ' + r.status);
      return r.blob();
    });
    p.then(function (data) {
      var blob = data instanceof Blob ? data : new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      var url = URL.createObjectURL(blob);
      var a = el('a', { href: url, download: name });
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
      setError('export', null);
      announce('Export downloaded as ' + name + '.');
    }).catch(function (e) {
      setError('export', 'Export failed: ' + e.message);
    }).then(function () { btn.disabled = false; });
  }

  // ------------------------------------------------------------------ wiring

  function wire() {
    $('theme-btn').addEventListener('click', toggleTheme);
    if (mql) {
      var onChange = function () { if (!storedTheme()) applyTheme(null); };
      if (mql.addEventListener) mql.addEventListener('change', onChange); else if (mql.addListener) mql.addListener(onChange);
    }
    $('export-btn').addEventListener('click', doExport);
    $('details-btn').addEventListener('click', function (e) { e.stopPropagation(); setPop('details', !popIsOpen('details')); });
    $('details-close').addEventListener('click', function () { setPop('details', false); $('details-btn').focus(); });
    $('help-btn').addEventListener('click', function (e) { e.stopPropagation(); setPop('help', !popIsOpen('help')); });
    document.addEventListener('click', function (e) {
      if (e.target.closest && !e.target.closest('#details-pop, #help-pop')) closePops(false);
    });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && (popIsOpen('details') || popIsOpen('help'))) { e.preventDefault(); closePops(true); } });
    $('la-btn').addEventListener('click', openLogAccess);
    wireLogAccess();
    $('banner-close').addEventListener('click', function () {
      app.bannerDismissed = Array.from(app.errors.values()).join('|');
      $('banner').hidden = true;
    });

    $('jump-current').addEventListener('click', function () {
      if (!app.currentKey) return;
      var info = app.stepIndex.get(app.currentKey), want = info ? MODE_OF_SECTION[info.section] : null;
      if (want && want !== currentModeId()) setMode(want);
      revealKey(app.currentKey);
      renderTree(false);
      scrollToKey(app.currentKey, true);
    });
    $('collapse-all').addEventListener('click', function () {
      app.stepIndex.forEach(function (v, k) { if (arr(v.node.children).length) app.expanded.set(k, false); });
      renderTree(false);
    });

    var lf = $('level-filter');
    lf.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-level]');
      if (!b) return;
      app.filter.level = b.getAttribute('data-level');
      Array.prototype.forEach.call(lf.querySelectorAll('button'), function (x) { x.setAttribute('aria-pressed', String(x === b)); });
      rerenderLogs();
    });

    var search = $('log-search'), deb = null;
    search.addEventListener('input', function () {
      clearTimeout(deb);
      deb = setTimeout(function () {
        app.filter.q = search.value.trim().toLowerCase();
        renderChips();
        rerenderLogs();
      }, 160);
    });
    search.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { search.value = ''; app.filter.q = ''; renderChips(); rerenderLogs(); }
    });

    $('file-filter').addEventListener('change', function (e) {
      app.filter.file = e.target.value;
      renderChips();
      rerenderLogs();
    });

    $('follow-btn').addEventListener('click', function () { setFollow(!app.follow); });
    $('new-lines').addEventListener('click', function () { setFollow(true); });

    var view = $('log-view'), lastTop = 0;
    view.addEventListener('scroll', function () {
      var atBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 24;
      if (atBottom && !app.follow && view.scrollTop > lastTop) setFollow(true); // user scrolled back down
      else if (!atBottom && app.follow && view.scrollTop < lastTop) setFollow(false); // user scrolled up
      lastTop = view.scrollTop;
    }, { passive: true });

    document.addEventListener('keydown', function (e) {
      if (e.key === '/' && !e.ctrlKey && !e.metaKey && !e.altKey) {
        var t = e.target;
        if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
        e.preventDefault();
        search.focus();
        search.select();
      }
    });

    wireReplay();
    setInterval(function () { tickTimers(); tickHeader(); }, 1000);
  }

  function openFromHash() {
    var h = typeof location !== 'undefined' ? location.hash.replace(/^#/, '').toLowerCase() : '';
    if (h === 'details') setPop('details', true);
    else if (h === 'help') setPop('help', true);
    else if (h === 'logaccess') openLogAccess();
  }

  function start() {
    wire();
    renderCounts();
    renderTree(false);
    renderSummary();
    rerenderLogs();
    if (DEMO) {
      // Sample data, but when a Sonar back end serves this page the real version, links and phase guidance are read (a file
      // opened straight from disk keeps the samples).
      startDemo();
      loadAbout();
      getJSON('/api/guidance').then(function (g) { if (isObj(g) && g.available !== false) { app.guidance = g; renderGuidance(); } }, function () { /* sample guidance stays */ });
      openFromHash();
      return;
    }
    openFromHash();
    loadAbout();
    setConn('connecting');
    Promise.allSettled([loadConfig(), loadGuidance(), loadState(), loadLogs()]).then(function (res) {
      if (isObj(app.config) && isObj(app.config.replay)) { loadReplay(); return; }   // Start-AzlSonar.ps1 -Replay
      var ok = res.some(function (r) { return r.status === 'fulfilled'; });
      if (!ok) setConn('offline');
      connectSSE();
    });
  }

  // ------------------------------------------------------------------ replay (Start-AzlSonar.ps1 -Replay, or ?demo=1&replay=1)
  //
  // The whole recording is loaded once (/api/replay); the page rebuilds the state, the tailer status and the log lines
  // at the playback position and renders them through the same functions as live data. Nothing is polled or streamed.

  // Live, recording (-Record): a small pill in the header says so.
  function renderRecording() {
    var pill = $('rec-pill');
    if (!pill) return;
    var r = isObj(app.config) && isObj(app.config.recording) && !app.replay ? app.config.recording : null;
    pill.hidden = !r;
    if (r) pill.title = 'Recording this run to ' + str(r.file) + ' (masked). Replay it with Start-AzlSonar.ps1 -Replay.';
  }

  function loadReplay() {
    setConn('replay');
    return getJSON('/api/replay').then(function (b) {
      if (!isObj(b) || !Array.isArray(b.events)) throw new Error('/api/replay returned no events');
      setError('replay', null);
      startReplay(b.events, b.replay, app.config, app.guidance, false);
    }).catch(function (e) { setError('replay', 'Could not load the recording: ' + e.message); });
  }

  function fmtRecorded(t) {
    if (isNaN(t)) return '';
    try { return new Date(t).toLocaleString(undefined, { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return new Date(t).toISOString(); }
  }

  function startReplay(events, meta, config, guidance, demo) {
    var rec;
    try { rec = replayLoad(events, meta); } catch (e) { setError('replay', 'The recording cannot be played: ' + e.message); return; }
    var r = app.replay = { rec: rec, clock: clockCreate(rec.start, rec.end, rec.meta.speed), stateIdx: -2, logCount: -1, tailerIdx: -2,
      dragging: false, needsSync: false, demo: !!demo, timer: null };
    setClock(function () { return clockNow(r.clock, Date.now()); });
    document.body.classList.add('is-replay');
    setConn('replay');
    if (es) { es.close(); es = null; }
    clearTimeout(sseTimer);
    stopPolling();
    var session = rec.sessions[rec.sessions.length - 1] || {};
    app.config = null;   // a replay never detects back-end restarts
    applyConfig(isObj(config) ? config : (session.config || { cluster: rec.cluster }));
    app.guidance = isObj(guidance) && Object.keys(guidance).length ? guidance : session.guidance;
    renderGuidance();
    app.logGen++;
    logStoreReset(app.store, 'replay');
    buildReplayBar();
    var startAt = parseTime(rec.meta.startAt);
    if (rec.meta.startAtPhase) {
      var m = rec.markers.filter(function (x) { return x.phase === rec.meta.startAtPhase; })[0];
      if (m) startAt = m.t;
      else setError('replay', 'The recording has no ' + phaseLabel(rec.meta.startAtPhase) + ' phase; starting at the beginning.');
    }
    if (!isNaN(startAt)) clockSeek(r.clock, startAt, Date.now());
    replaySync();
    if (rec.meta.autoplay) clockPlay(r.clock, Date.now());
    renderReplayBar();
    r.timer = setInterval(replayTick, 200);
    if (rec.invalid) setError('replay-invalid', rec.invalid + ' event(s) of the recording could not be read and were skipped.');
    announce('Replay of ' + (rec.cluster || 'the cluster') + ' loaded. Nothing on this page is live.');
  }

  // Brings the page to the playback position: state, log lines, tailer status, timers.
  function replaySync() {
    var r = app.replay;
    if (!r) return;
    var rec = r.rec, T = clockNow(r.clock, Date.now());
    var si = Math.max(0, replayStateIndexAt(rec, T));
    if (si !== r.stateIdx) {
      r.stateIdx = si;
      applyState(replayStateAt(rec, rec.states[si].t));
    }
    var lc = replayLogCountAt(rec, T);
    if (lc !== r.logCount) {
      var take = function (from, to) { return rec.lines.slice(from, to).map(function (x) { return x.line; }); };
      if (r.logCount >= 0 && lc > r.logCount && lc - r.logCount <= 1500) {
        applyLogBatch(take(r.logCount, lc), { server: 'replay', source: 'live' });   // forward: lines arrive as if live
      } else {
        app.logGen++;   // backward or a long jump: rebuild the log pane at the position
        logStoreReset(app.store, 'replay');
        logStoreIngest(app.store, take(Math.max(0, lc - MAX_STORED_LINES), lc), { server: 'replay', source: 'live' });
        recount();
        renderCounts();
        renderFileOptions();
        rerenderLogs();
      }
      r.logCount = lc;
    }
    var ti = replayTailerIndexAt(rec, T);
    if (ti !== r.tailerIdx) {
      r.tailerIdx = ti;
      applyTailer(ti >= 0 ? rec.tailers[ti].tailer : { state: 'unknown', reason: '' });
    }
    tickTimers();
    tickHeader();
  }

  function replayTick() {
    var r = app.replay;
    if (!r) return;
    if (r.clock.playing || r.needsSync) {
      r.needsSync = false;
      replaySync();
      if (r.clock.playing && clockEnded(r.clock, Date.now())) {
        clockPause(r.clock, Date.now());
        announce('The replay reached the end of the recording.');
      }
    }
    renderReplayBar();
  }

  // immediate: rebuild now (a click); otherwise on the next tick (dragging the scrubber).
  function replaySeek(t, immediate) {
    var r = app.replay;
    if (!r) return;
    clockSeek(r.clock, t, Date.now());
    if (immediate) replaySync(); else r.needsSync = true;
    renderReplayBar();
  }

  function replayToggle() {
    var r = app.replay;
    if (!r) return;
    var now = Date.now();
    if (r.clock.playing) clockPause(r.clock, now);
    else { clockPlay(r.clock, now); replaySync(); }
    renderReplayBar();
    announce(r.clock.playing ? 'Playing at ' + r.clock.speed + ' times speed.' : 'Paused.');
  }

  function buildReplayBar() {
    var r = app.replay, rec = r.rec;
    $('replay-bar').hidden = false;
    $('replay-badge').hidden = false;
    $('demo-badge').hidden = !r.demo;
    $('export-btn').hidden = true;
    $('log-title').textContent = 'Logs (replay)';
    $('replay-title').textContent = 'Replay of ' + (rec.cluster || 'the cluster') + ' · recorded ' + fmtRecorded(rec.start) + (r.demo ? ' (demo data)' : '');
    $('replay-title').title = (rec.meta.file ? 'Recording ' + rec.meta.file + '. ' : '') + 'Recorded ' + fmtDateTime(rec.start) + ' to ' +
      fmtDateTime(rec.end) + '. Nothing on this page is live.';
    var scrub = $('rp-scrub');
    scrub.min = '0';
    scrub.max = String(Math.max(1, Math.round((rec.end - rec.start) / 1000)));
    scrub.step = '1';
    var speeds = REPLAY_SPEEDS.slice();
    if (speeds.indexOf(r.clock.speed) < 0) { speeds.push(r.clock.speed); speeds.sort(function (a, b) { return a - b; }); }
    var host = $('rp-speed');
    host.textContent = '';
    speeds.forEach(function (s) {
      host.appendChild(el('button', { type: 'button', 'data-speed': String(s), 'aria-pressed': 'false', title: s + ' recorded second' + (s === 1 ? '' : 's') + ' per second', text: s + '×' }));
    });
    var mk = $('rp-markers'), jump = $('rp-jump');
    mk.textContent = '';
    jump.textContent = '';
    jump.appendChild(el('option', { value: '', text: 'Jump to…' }));
    rec.markers.forEach(function (m, i) {
      var into = fmtOffset(m.t - rec.start);
      var pct = scrubFraction(rec, m.t) * 100;
      var b = el('button', { type: 'button', class: 'rp-mark', 'data-kind': m.kind, 'data-i': String(i), 'data-edge': pct < 7 ? 'start' : pct > 93 ? 'end' : null,
        style: 'left:' + pct.toFixed(3) + '%',
        title: m.label + ' (' + into + ' into the recording)', 'aria-label': 'Jump to ' + m.label + ', ' + into + ' into the recording' });
      if (m.kind === 'phase' || m.kind === 'end') b.appendChild(el('span', { class: 'rp-mark-label', text: m.short || m.label }));
      mk.appendChild(b);
      jump.appendChild(el('option', { value: String(i), text: into + '  ' + m.label }));
    });
    jump.disabled = !rec.markers.length;
  }

  function renderReplayBar() {
    var r = app.replay;
    if (!r) return;
    var rec = r.rec, wall = Date.now(), T = clockNow(r.clock, wall), playing = r.clock.playing;
    var play = $('rp-play');
    play.setAttribute('data-playing', String(playing));
    play.setAttribute('aria-label', playing ? 'Pause' : 'Play');
    $('rp-play-label').textContent = playing ? 'Pause' : (clockEnded(r.clock, wall) ? 'Play again' : 'Play');
    Array.prototype.forEach.call($('rp-speed').querySelectorAll('button'), function (b) {
      b.setAttribute('aria-pressed', String(Number(b.getAttribute('data-speed')) === r.clock.speed));
    });
    var pos = replayPosition(rec, T);
    var scrub = $('rp-scrub');
    if (!r.dragging) scrub.value = String(Math.round((T - rec.start) / 1000));
    scrub.setAttribute('aria-valuetext', pos.text + ', ' + fmtDateTime(T));
    $('rp-pos').textContent = pos.text;
    $('rp-clock').textContent = fmtDateTime(T) + ' · ' + fmtOffset(T - rec.start).slice(1) + ' of ' + fmtOffset(rec.end - rec.start).slice(1);
  }

  function wireReplay() {
    $('rp-play').addEventListener('click', replayToggle);
    $('rp-speed').addEventListener('click', function (e) {
      var b = e.target.closest('button[data-speed]');
      if (!b || !app.replay) return;
      clockSetSpeed(app.replay.clock, Number(b.getAttribute('data-speed')), Date.now());
      renderReplayBar();
    });
    var scrub = $('rp-scrub');
    scrub.addEventListener('input', function () {
      if (!app.replay) return;
      app.replay.dragging = true;
      replaySeek(app.replay.rec.start + Number(scrub.value) * 1000, false);
    });
    scrub.addEventListener('change', function () {
      if (!app.replay) return;
      app.replay.dragging = false;
      replaySeek(app.replay.rec.start + Number(scrub.value) * 1000, true);
    });
    $('rp-markers').addEventListener('click', function (e) {
      var b = e.target.closest('.rp-mark');
      if (!b || !app.replay) return;
      var m = app.replay.rec.markers[Number(b.getAttribute('data-i'))];
      if (m) { replaySeek(m.t, true); announce('Jumped to ' + m.label + '.'); }
    });
    $('rp-jump').addEventListener('change', function (e) {
      var i = e.target.value;
      e.target.value = '';
      if (i === '' || !app.replay) return;
      var m = app.replay.rec.markers[Number(i)];
      if (m) { replaySeek(m.t, true); announce('Jumped to ' + m.label + '.'); }
    });
    // Space plays or pauses when nothing else has the focus (the step tree and buttons keep their own Space).
    document.addEventListener('keydown', function (e) {
      if (!app.replay || e.key !== ' ' || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.target !== document.body && e.target !== document.documentElement) return;
      e.preventDefault();
      replayToggle();
    });
  }

  // ------------------------------------------------------------------ demo mode (?demo=1): built-in sample data, no API calls

  function startDemo() {
    $('demo-badge').hidden = false;
    var now = Date.now();
    if (DEMO_REPLAY) {
      startReplay(demoRecording(now), { cluster: 'clus01', file: 'built-in demo recording', speed: 60 }, null, null, true);
      return;
    }
    setConn('demo');
    var f = demoFactory(now);
    if (DEMO_ROUTE) { startRouteDemo(DEMO_ROUTE, f.iso, f.step, f.M); return; }
    var d = demoDeploymentSample(now), state = d.state;
    applyConfig(d.config);
    app.guidance = d.guidance;
    applyState(state);
    applyTailer(d.tailer);
    applyFiles(d.files);
    applyLogBatch(d.lines, { source: 'live' });
    var seq = d.lines.length, mi = 0;
    setInterval(function () {
      var m = d.msgs[mi++ % d.msgs.length];
      var nowIso = new Date().toISOString();
      applyLogBatch([{ seq: ++seq, time: nowIso, received: nowIso, timeSource: 'line', file: d.file, level: m[0], text: m[1] }], { source: 'live' });
    }, 2500);
    setInterval(function () {
      state.polledAt = new Date().toISOString();
      applyState(state);
    }, 20000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }

  // ?demo=1&route=simplified: a ZTP run of three machines (example names). Two are complete (Device, Azure's steps,
  // Network and Restore done); the third is installing the OS in Azure. The ZTP events show in the log pane tagged
  // with the machine and the stage, as the ZTP event file does on a real run. Sample data only; no API calls.
  function startZtpDemo(iso, step, M) {
    var NAMES = ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'];
    var JOB = ['CreatedTargetArcMachine', 'CopiedSiteSettings', 'SetupPermissions', 'ArcNotificationSent', 'Initialize',
      'ResolveConfiguration', 'DownloadOSArtifacts', 'SBEDiscoveryDownload', 'SetupHybridComputeRP', 'PrepareTargetOSProvisioning',
      'InitiateTargetOSProvisioning', 'PrepareK3sShutdown', 'BootIntoTargetOS', 'ValidateStagedArtifacts', 'InvokeTPAUpdate',
      'ReportUpdateStatus', 'ProvisionOs', 'InstallExtensions', 'DeleteUnusedRoleAssignments', 'DeleteUnusedArcMachine'];
    var SUBS = [['Initialize', 'Initialize Resource'], ['DownloadOs', 'Download OS'], ['PrepareOs', 'Prepare OS'],
      ['RebootOs', 'Reboot into OS'], ['InstallExtensions', 'Install required Arc extensions'], ['Finalize', 'Finalize system configuration']];
    var EVIDENCE = {
      Mounted: 'virtual media inserted', Booting: 'the machine is starting from the media', MaintenanceEnvironmentRunning: 'maintenance environment is up',
      DeviceConfigurationSubmitted: 'static address sent to the maintenance environment', DeviceConfigurationStatus: 'configuration status InProgress',
      DeviceAddressSet: 'the management port reports the static address', VoucherWritten: 'ownership voucher read back',
      NetworkJobSubmitted: 'ApplyConfiguration job sent', NetworkJobStatus: 'job status Succeeded',
      ManagementAddressSet: 'address set on the management NIC', BiosRestoreStarted: 'restoring the final BIOS values',
      BiosRestored: 'BIOS restored and Arc connected again'
    };
    var LABEL = { DeviceConfigurationSubmitted: 'Configuration sent to the maintenance environment', DeviceConfigurationStatus: 'Configuration status',
      DeviceAddressSet: 'Address set', NetworkJobSubmitted: 'ApplyConfiguration job sent', NetworkJobStatus: 'Job status',
      ManagementAddressSet: 'Address set on the management NIC', BiosRestoreStarted: 'Restoring the final BIOS values', BiosRestored: 'BIOS restored and Arc connected again' };

    // A ZTP stage step with its events as children: events = [[state, agoMs], ...]; running when it has no final state.
    function stage(id, name, desc, events, done) {
      var kids = events.map(function (e, i) {
        var last = i === events.length - 1, nextAgo = last ? e[1] - 20000 : events[i + 1][1];
        return step(id + '.' + i, e[0], last && !done ? 'running' : 'success', e[1], last && !done ? null : nextAgo, null, null, LABEL[e[0]] || e[0]);
      });
      if (!events.length) return step(id, name, 'notstarted', null, null, [], null, desc);
      return step(id, name, done ? 'success' : 'running', events[0][1], done ? events[events.length - 1][1] - 20000 : null, kids, null, desc);
    }
    function machine(name, idx, complete) {
      var t0 = (152 - idx * 2) * M, b = t0 - 4 * M;
      var device = stage('ztp.device', 'Management address (maintenance environment)', 'azurelocal-ztp Device: the static management address and host name on the port with the management MAC, set before the Azure claim',
        [['DeviceConfigurationSubmitted', t0], ['DeviceConfigurationStatus', t0 - M], ['DeviceAddressSet', t0 - 2 * M]], true);
      var cur = complete ? -1 : 3, jobCur = complete ? -1 : 12, curStatus = 'running';
      var provision = step('lifecycle.0', 'ProvisionMachine', 'success', b, b - 9 * M, demoSteps(step, 'lifecycle.0.',
        [['RegisterMachine', 'Register machine with onboarding service'], ['ArcEnableMaintenanceEnvironment', 'Arc enable maintenance environment'], ['InstallExtensions', 'Install required Arc extensions']],
        b, 3 * M, -1), null, 'Provision machine');
      var install = step('lifecycle.1', 'InstallOs', complete ? 'success' : 'running', b - 10 * M, complete ? b - 58 * M : null,
        demoSteps(step, 'lifecycle.1.', SUBS, b - 10 * M, 8 * M, cur, curStatus), null, 'Install OS');
      var job = step('job', 'ProvisionOs job', complete ? 'success' : 'running', b - 10 * M, complete ? b - 58 * M : null,
        demoSteps(step, 'job.', JOB, b - 10 * M, 2 * M + 20000, jobCur, curStatus), null, 'edgeMachines/jobs/ProvisionOs');
      var network = complete ? stage('ztp.network', 'Management address on the management NIC', 'azurelocal-ztp Network: checks the management address after the OS install',
        [['NetworkJobSubmitted', 32 * M], ['NetworkJobStatus', 31 * M], ['ManagementAddressSet', 30 * M]], true) :
        stage('ztp.network', 'Management address on the management NIC', 'azurelocal-ztp Network: checks the management address after the OS install', [], false);
      var restore = complete ? stage('ztp.restore', 'BIOS restored', 'azurelocal-ztp Restore: the final BIOS values put back over Redfish after the temporary install values',
        [['BiosRestoreStarted', 24 * M], ['BiosRestored', 20 * M]], true) :
        stage('ztp.restore', 'BIOS restored', 'azurelocal-ztp Restore: the final BIOS values put back over Redfish after the temporary install values', [], false);
      var done = complete ? JOB.length : jobCur;
      return {
        name: name, route: 'simplified', lifecycle: complete ? 'Provisioned' : 'InstallingOs',
        lifecycleMessage: complete ? 'Machine has been successfully provisioned.' : 'Installing OS in progress. Wait for the operation to complete.',
        status: complete ? 'success' : 'running', percent: complete ? 100 : Math.min(95, Math.round(25 + 70 * done / JOB.length)), reportedPercent: 50,
        arcMachineName: '00000000-0000-0000-0000-00000000000' + (idx + 1) + '-1', arcSource: 'edgeMachine.job', arcStatus: complete ? 'Connected' : 'Disconnected',
        extensions: [], start: iso(t0), end: complete ? iso(20 * M) : null, errors: [],
        ztp: { complete: complete, device: { status: 'success' }, network: { status: complete ? 'success' : 'notstarted' }, restore: { status: complete ? 'success' : 'notstarted' } },
        tree: [device, provision, install, job, network, restore]
      };
    }
    var provNodes = [machine(NAMES[0], 0, true), machine(NAMES[1], 1, true), machine(NAMES[2], 2, false)];
    var state = {
      cluster: 'iic-azl-c01', mode: null, provisioningState: null, phase: 'provisioning', activePhase: 'provisioning',
      provisioning: { route: 'simplified', routeSource: 'config', phase: 'provisioning', status: 'running', readyForValidate: false, ztpComplete: false, nextStep: null, nodes: provNodes },
      extensions: { shown: false, status: 'notstarted', nodes: [] },
      validation: { status: 'notstarted', tree: [], counts: {} },
      deployment: { status: 'notstarted', tree: [], counts: {} },
      nodes: provNodes.map(function (n) { return { name: n.name, arcStatus: n.arcStatus, arcMachineName: n.arcMachineName, arcSource: n.arcSource, lastStatusChange: iso(30 * M) }; }),
      current: { phase: 'provisioning', stepPath: [NAMES[2], 'job', 'job.12'], stepName: 'BootIntoTargetOS' },
      warnings: [], polledAt: iso(4000)
    };
    applyConfig({ cluster: 'iic-azl-c01', resourceGroup: 'rg-iic-azl-c01', identityModel: 'ActiveDirectory', pollSeconds: 20, provisioningRoute: 'simplified',
      nodes: NAMES.map(function (n, i) { return { name: n, seed: i === 0 }; }), logPaths: ['C:\\Windows\\System32\\Bootstrap\\Logs'] });
    app.guidance = demoGuidance();
    applyState(state);
    applyTailer({ state: 'connected', reason: '', node: NAMES[0], credential: 'supplied' });
    var f1 = 'C:\\Windows\\System32\\Bootstrap\\Logs\\setup.log';
    var f2 = 'C:\\Windows\\System32\\Bootstrap\\Logs\\arcInstallLog-20261010.txt';
    applyFiles([{ path: f1 }, { path: f2 }]);
    var seq = 0, out = [];
    function line(ago, file, level, text) { out.push({ ago: ago, file: file, level: level, text: text }); }
    function ztp(ago, node, state, level, extra) {
      var text = iso(ago) + ' [ztp] ' + node + ' ' + state + ': ' + (extra || EVIDENCE[state] || state);
      line(ago, 'ztp-events', level || 'info', text);
    }
    NAMES.forEach(function (n, i) {
      var t0 = (152 - i * 2) * M;
      ztp(t0 + 6 * M, n, 'Mounted'); ztp(t0 + 4 * M, n, 'Booting'); ztp(t0 + 2 * M, n, 'MaintenanceEnvironmentRunning');
      ztp(t0, n, 'DeviceConfigurationSubmitted'); ztp(t0 - M, n, 'DeviceConfigurationStatus'); ztp(t0 - 2 * M, n, 'DeviceAddressSet');
      ztp(t0 - 3 * M, n, 'VoucherWritten');
    });
    ztp(100 * M, NAMES[2], 'Booting', 'warning', 'no change for 20 minutes (warning)');
    NAMES.slice(0, 2).forEach(function (n, i) {
      ztp((32 - i) * M, n, 'NetworkJobSubmitted'); ztp((31 - i) * M, n, 'NetworkJobStatus'); ztp((30 - i) * M, n, 'ManagementAddressSet');
      ztp((24 - i) * M, n, 'BiosRestoreStarted'); ztp((20 - i) * M, n, 'BiosRestored');
    });
    line(45 * M, f1, 'info', 'Bootstrap service started on ' + NAMES[0] + '.');
    line(44 * M, f2, 'info', 'Azure Connected Machine agent installed.');
    line(43 * M, f2, 'info', 'Connecting ' + NAMES[0] + ' to Azure Arc as 00000000-0000-0000-0000-000000000001-1.');
    line(36 * M, f1, 'warning', 'TimeServer NotStarted: using the DHCP-supplied time source until the site setting applies.');
    line(12 * M, f1, 'info', 'Mandatory extensions reported Succeeded.');
    out.sort(function (a, b) { return b.ago - a.ago; });
    applyLogBatch(out.map(function (o) { return { seq: ++seq, time: iso(o.ago), received: iso(o.ago), timeSource: 'line', file: o.file, level: o.level, text: o.text }; }), { source: 'live' });
    var msgs = [['info', 'Bootstrap heartbeat: healthy.'], ['info', 'Waiting for the next provisioning task.']], mi = 0;
    setInterval(function () {
      var m = msgs[mi++ % msgs.length], nowIso = new Date().toISOString();
      applyLogBatch([{ seq: ++seq, time: nowIso, received: nowIso, timeSource: 'line', file: f1, level: m[0], text: m[1] }], { source: 'live' });
    }, 4000);
    setInterval(function () { state.polledAt = new Date().toISOString(); applyState(state); }, 20000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }

  // Steps for a demo machine: names (or [name, description] pairs) one after the other from startAgo; cur is the index of
  // the current step (-1: all finished) and curStatus its status.
  function demoSteps(step, prefix, names, startAgo, per, cur, curStatus, errors) {
    return names.map(function (nm, i) {
      var name = Array.isArray(nm) ? nm[0] : nm, desc = Array.isArray(nm) ? nm[1] : '';
      var a = startAgo - i * per, b = a - per;
      if (cur < 0 || i < cur) return step(prefix + i, name, 'success', a, b, null, null, desc);
      if (i === cur) return step(prefix + i, name, curStatus, a, curStatus === 'running' ? null : b, null, curStatus === 'error' ? errors : null, desc);
      return step(prefix + i, name, 'notstarted', null, null, null, null, desc);
    });
  }

  function demoGuidance() {
    return {
      identityModel: 'ActiveDirectory',
      phases: {
        provisioning: { account: 'Maintenance environment: the Configurator app user. After the OS install: the local administrator, the same on every node.', where: ['C:\\Windows\\System32\\Bootstrap\\Logs', 'C:\\ProgramData\\AzureConnectedMachineAgent\\Log'], when: 'Once the Azure Stack HCI OS is installed and bootstrap starts.', source: 'Sample data (demo mode)', verified: false },
        validation: { account: 'The local administrator on the seed node.', where: ['C:\\CloudDeployment\\Logs'], when: 'From the start of Validate.', source: 'Sample data (demo mode)', verified: false },
        deployment: { account: 'The deployment user on the seed node.', where: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'], when: 'Throughout Deploy; files rotate as steps change.', source: 'Sample data (demo mode)', verified: false, notes: 'Demo guidance only. The real window reads data/phase-guidance.json through /api/guidance.' }
      }
    };
  }

  // ?demo=1&route=oem: two machines on the OEM image route during Arc registration (node01 updating its OS image, in
  // Download; node02 bootstrapping, in ArcConfiguration > ArcRegistration). Step names as the nodes report them (read
  // live 11 Oct 2026). Sample data only; no API calls. ?demo=1&route=simplified is startZtpDemo.
  function startRouteDemo(route, iso, step, M) {
    if (route === 'simplified') { startZtpDemo(iso, step, M); return; }
    function steps(prefix, names, startAgo, per, cur, curStatus, errors) { return demoSteps(step, prefix, names, startAgo, per, cur, curStatus, errors); }
    // OEM image route: the three groups Arc registration shows per machine (OS image update, Bootstrap, Azure registration).
    var UPD = ['Scan', 'Download', 'Install'];
    var BOOT = ['NetworkConfig', 'RemoteConfig', 'WebProxy', 'TimeServer', 'HostName'];
    var ARCCFG = ['ArtifactsUpload', 'ConnectivityValidation', 'ArcRegistration', 'ArcExtensionInstall'];
    var UPD_DESC = 'Get-ArcZeroDaySolutionUpdateStatus (zero-day solution update; runs only when the OEM image is not the latest)';
    function oemMachine(name, updCur, bootCur, arcCfgCur) {
      // updCur / bootCur / arcCfgCur: index of the running step (-2: nothing started)
      var update = step('update', 'OS image update', updCur < -1 ? 'notstarted' : 'running', updCur < -1 ? null : 14 * M, null,
        steps('update.', UPD, 14 * M, 2 * M + 30000, updCur < -1 ? 0 : updCur, updCur < -1 ? 'notstarted' : 'running'), null, UPD_DESC);
      if (updCur < -1) update.children.forEach(function (c) { c.status = 'notstarted'; c.start = null; c.end = null; c.durationSeconds = null; });
      var bootRunning = bootCur > -2;
      var arcCfg = step('bootstrap.5', 'ArcConfiguration', bootRunning && bootCur >= BOOT.length ? 'running' : 'notstarted',
        bootRunning && bootCur >= BOOT.length ? 3 * M : null, null,
        bootRunning && bootCur >= BOOT.length ? steps('bootstrap.5.', ARCCFG, 3 * M, M, arcCfgCur, 'running') :
          ARCCFG.map(function (nm, i) { return step('bootstrap.5.' + i, nm, 'notstarted', null, null); }));
      var tops = bootRunning ? steps('bootstrap.', BOOT, 9 * M, M, Math.min(bootCur, BOOT.length), 'running').slice(0, BOOT.length) :
        BOOT.map(function (nm, i) { return step('bootstrap.' + i, nm, 'notstarted', null, null); });
      var boot = step('bootstrap', 'Bootstrap', bootRunning ? 'running' : 'notstarted', bootRunning ? 9 * M : null, null, tops.concat([arcCfg]), null, 'Get-ArcBootstrapStatus');
      var arc = step('arc', 'Azure registration', 'notstarted', null, null, [
        step('arc.machine', 'Arc machine registered', 'notstarted', null, null, null, null, 'Microsoft.HybridCompute/machines/' + name + ' in the configured resource group'),
        step('arc.connected', 'Arc agent Connected', 'notstarted', null, null, null, null, 'Microsoft.HybridCompute/machines properties.status')
      ], null, 'Microsoft.HybridCompute/machines/' + name);
      function count(g) {
        var done = 0, total = 0, cur = '';
        (function walk(nodes, path) {
          nodes.forEach(function (c) {
            var here = path.concat([c.name]);
            if (c.status === 'running') cur = here.join(' > ');
            if (c.children.length) walk(c.children, here); else { total++; if (c.status === 'success') done++; }
          });
        })(g.children, []);
        return { state: 'read', status: g.status, done: done, total: total, current: cur };
      }
      var u = count(update), b = count(boot);
      var updating = update.status === 'running';
      var pct = Math.round(100 * (b.done + (updating ? u.done : 0)) / (b.total + 2 + (updating ? u.total : 0)));
      return {
        name: name, route: 'oem-image', lifecycle: updating ? 'UpdatingOsImage' : 'Bootstrapping',
        lifecycleMessage: updating ? 'Updating the OS image (zero-day solution update): ' + u.current + '. Learn: typically 40-45 minutes, then a reboot; Invoke-AzStackHciArcInitialization is run again after the reboot.' :
          'Bootstrapping: ' + b.current + '.',
        status: 'running', percent: pct, reportedPercent: null,
        arcMachineName: name, arcSource: 'nodeName', arcStatus: 'NotFound', extensions: [],
        update: u, bootstrap: b, probe: { state: 'ok', transport: 'winrm', lastProbeUtc: iso(5000), lastSuccessUtc: iso(5000), unreachableSince: null },
        start: iso(updating ? 14 * M : 9 * M), end: null, errors: [], tree: [update, boot, arc]
      };
    }

    var names = ['node01', 'node02'];
    var provNodes = [oemMachine('node01', 1, -2, -1), oemMachine('node02', -2, BOOT.length, 2)];
    var phase = 'arc-registration';
    var provStatus = 'running';
    var state = {
      cluster: 'clus01', mode: null, provisioningState: null,
      phase: phase, activePhase: phase,
      provisioning: { route: route, routeSource: 'auto', phase: phase, status: provStatus, readyForValidate: false, ztpComplete: false, nodes: provNodes },
      extensions: { shown: false, status: 'notstarted', nodes: [] },
      validation: { status: 'notstarted', tree: [], counts: {} },
      deployment: { status: 'notstarted', tree: [], counts: {} },
      nodes: provNodes.map(function (n) { return { name: n.name, arcStatus: n.arcStatus, arcMachineName: n.arcMachineName, arcSource: n.arcSource, lastStatusChange: iso(30 * M) }; }),
      current: { phase: phase, stepPath: ['node02', 'bootstrap', 'bootstrap.5', 'bootstrap.5.2'], stepName: 'ArcRegistration' },
      warnings: [],
      polledAt: iso(4000)
    };
    applyConfig({ cluster: 'clus01', resourceGroup: 'rg-example-azl', identityModel: 'LocalIdentity', pollSeconds: 20, provisioningRoute: 'auto',
      nodes: names.map(function (n, i) { return { name: n, seed: i === 0 }; }), logPaths: ['C:\\Windows\\System32\\Bootstrap\\Logs'] });
    app.guidance = {
      identityModel: 'LocalIdentity',
      phases: {
        provisioning: { account: 'The local administrator given when provisioning, on each node', where: ['C:\\Windows\\System32\\Bootstrap\\Logs'], when: 'Once the Azure Stack HCI OS is installed', source: 'Sample data (demo mode)', verified: false },
        'arc-registration': { account: 'The built-in Administrator until the deployment local admin exists, then the deployment local admin', where: ['C:\\Windows\\System32\\Bootstrap\\Logs', 'C:\\ProgramData\\AzureConnectedMachineAgent\\Log'], when: 'From Invoke-AzStackHciArcInitialization onward', commands: ['Get-ArcBootstrapStatus', 'Get-ArcZeroDaySolutionUpdateStatus', 'Collect-ArcBootstrapSupportLogs'], source: 'Sample data (demo mode)', verified: false },
        validation: { account: 'The deployment local admin', where: ['C:\\CloudDeployment\\Logs'], when: 'From the start of Validate', source: 'Sample data (demo mode)', verified: false },
        deployment: { account: 'The deployment local admin', where: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'], when: 'Throughout Deploy', source: 'Sample data (demo mode)', verified: false, notes: 'Demo guidance only. The real card reads data/phase-guidance.json through /api/guidance.' }
      }
    };
    applyState(state);
    applyTailer({ state: 'connected', reason: '', node: 'node01' });
    var f1 = 'C:\\Windows\\System32\\Bootstrap\\Logs\\setup.log';
    var f2 = 'C:\\Windows\\System32\\Bootstrap\\Logs\\arcInstallLog-20261010.txt';
    var f3 = 'C:\\Windows\\System32\\Bootstrap\\Logs\\AzStackHci.ArcConnection.Debug.log\\PowerShell_transcript.node01.20261010170000.txt';
    applyFiles([{ path: f1 }, { path: f2 }, { path: f3 }]);
    var seq = 0;
    function line(msAgo, file, level, text) { return { seq: ++seq, time: iso(msAgo), received: iso(msAgo), timeSource: 'line', file: file, level: level, text: text }; }
    applyLogBatch([
      line(15 * M, f3, 'info', 'Invoke-AzStackHciArcInitialization started for node01.'),
      line(14 * M, f3, 'info', 'The OS image is not the latest for its release baseline: starting the solution update.'),
      line(12 * M, f1, 'info', 'Update: Scan Succeeded; Download InProgress.'),
      line(10 * M, f1, 'warning', 'Warning: the proxy bypass list is empty; using direct connections.')
    ], { source: 'live' });
    var msgs = [['info', 'Bootstrap heartbeat: healthy.'], ['info', 'Update: Download InProgress.']];
    var mi = 0;
    setInterval(function () {
      var m = msgs[mi++ % msgs.length];
      var nowIso = new Date().toISOString();
      applyLogBatch([{ seq: ++seq, time: nowIso, received: nowIso, timeSource: 'line', file: f1, level: m[0], text: m[1] }], { source: 'live' });
    }, 4000);
    setInterval(function () {
      state.polledAt = new Date().toISOString();
      applyState(state);
    }, 20000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }

  function demoExport() { return app.demoExport ? app.demoExport() : {}; }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
