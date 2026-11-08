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
  // ?demo=1&route=simplified|oem shows the machine-readiness phase of that route instead of a running deployment;
  // route=osconfig shows an OS configuration run (one ZTP and one ISO machine side by side); route=arm the toolkit's ARM
  // Validate and Deploy run (checks, validation, deployment, and the step 0.41 failure).
  // (Provisioning reads Not used); route=discovery the Discovery stage alone.
  // ?demo=1&replay=1 plays the demo deployment as a built-in recording (the replay transport bar without a file).
  var DEMO_REPLAY = DEMO && /(?:^|[?&])replay=(?:1|true|yes)(?:&|$)/i.test(location.search);
  var REPLAY_SPEEDS = [1, 30, 60, 240];
  var DEMO_ROUTE = (function () {
    if (typeof location === 'undefined') return '';
    var m = /(?:^|[?&])route=(simplified|oem|oem-image|osconfig|arm|iso|discovery)(?:&|$)/i.exec(location.search);
    var k = m ? m[1].toLowerCase() : '';
    return k === 'simplified' || k === 'osconfig' || k === 'arm' || k === 'iso' || k === 'discovery' ? k : (m ? 'oem-image' : '');
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
    treeSig: { discovery: null, provisioning: null, osconfiguration: null, armvalidation: null, validation: null, extensions: null, armdeployment: null, deployment: null, update: null },
    expanded: new Map(),        // key -> bool (user choice)
    sectionCollapsed: { discovery: false, provisioning: false, osconfiguration: false, armvalidation: false, validation: false, extensions: false, armdeployment: false, deployment: false, update: false },
    provAutoCollapsed: false,   // the provisioning section was collapsed once validation started
    provTree: [],               // one synthetic tree item per machine (provisioningTreeOf)
    oscTree: [],                // OS configuration: one tree item per machine with its steps (osConfigTreeOf)
    discTree: [],               // Discovery: one tree item per machine with what was read (discoveryTreeOf)
    extTree: [],                // OEM image route, from Validate on: one item per machine with its extensions
    stepIndex: new Map(),       // key -> { node, section, parentKey }
    focusKey: { discovery: null, provisioning: null, osconfiguration: null, armvalidation: null, validation: null, extensions: null, armdeployment: null, deployment: null, update: null },
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
  // The OS configuration event lines: "<time> [osconfig] <node> <State> (<Step>): ..." (file os-config-events). The stage is
  // osc.<step>; the guarded network change events belong to the Network step even when they name none.
  var OSC_LINE = /^(?:\S+\s+)?\[osconfig\]\s+(\S+)\s+([A-Za-z]+)(?:\s+\(([A-Za-z]+)\))?/;
  // The ARM run's event lines: "<time> [arm] <node|*> <State> (<step>): ..." (file arm-events).
  var ARM_LINE = /^(?:\S+\s+)?\[arm\]\s+(\S+)\s+([A-Za-z]+)/;
  function lineScope(l) {
    if (l.scope) return l.scope;
    if (l.file === 'os-config-events' || /^(?:\S+\s+)?\[osconfig\]\s/.test(str(l.text))) {
      var o = OSC_LINE.exec(str(l.text));
      if (o) {
        var ostep = o[3] || (/^NetworkChange/.test(o[2]) ? 'Network' : (/^Domain(Join|Admins)/.test(o[2]) ? 'DomainJoin' : ''));
        l.scope = { node: o[1], stage: ostep ? 'osc.' + ostep.toLowerCase() : '' };
        return l.scope;
      }
    }
    if (l.file === 'arm-events' || /^(?:\S+\s+)?\[arm\]\s/.test(str(l.text))) {
      // The toolkit's ARM run: '*' is the run itself (no machine), a node name is a check of that machine.
      var a = ARM_LINE.exec(str(l.text));
      if (a) { l.scope = { node: a[1] === '*' ? '' : a[1], stage: '' }; return l.scope; }
    }
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

  // ------------------------------------------------------------------ OS configuration (pure; also run by tests under Node)
  //
  // The mode between Provisioning and Validate. The back end builds state.osConfiguration from the toolkit's OS
  // configuration event file (Get-AzlSonarOsConfigurationState): one machine per node with its method (Ztp or Iso), transport,
  // versions and 13 steps. The page only shows it. A machine with no event yet shows the method it is expected to use.

  var OSC_STAGE_LABEL = {
    waiting: 'Waiting', planned: 'Planned', ok: 'OK', info: 'Info', changing: 'Changing', applied: 'Applied', verified: 'Verified',
    failed: 'Failed', blocked: 'Blocked', skipped: 'Not applicable', rolledback: 'Rolled back', refused: 'Refused'
  };
  var OSC_STAGE_KIND = {
    waiting: 'idle', planned: 'warn', ok: 'ok', info: 'ok', changing: 'run', applied: 'ok', verified: 'ok',
    failed: 'err', blocked: 'warn', skipped: 'idle', rolledback: 'err', refused: 'err'
  };
  var OSC_STATE_LABEL = {
    waiting: 'Waiting to start', planning: 'Reading the machine', planned: 'Planned', applying: 'Applying', retrying: 'Retrying',
    reconnecting: 'Reconnecting', awaitingconfirm: 'Awaiting confirmation', verifying: 'Verifying', converged: 'Converged',
    failed: 'Failed', blocked: 'Blocked', rolledback: 'Rolled back', refused: 'Refused'
  };
  var OSC_STATE_KIND = {
    waiting: 'idle', planning: 'run', planned: 'idle', applying: 'run', retrying: 'warn', reconnecting: 'run', awaitingconfirm: 'warn',
    verifying: 'run', converged: 'ok', failed: 'err', blocked: 'err', rolledback: 'err', refused: 'err'
  };
  var OSC_TRANSPORT_LABEL = { ArcRunCommand: 'Arc Run Command', WinRM: 'WinRM' };
  var OSC_GUARDED_LABEL = {
    Staged: 'Staged on the node', Verifying: 'Checking the node (stable period)', AwaitingConfirm: 'Waiting for the confirmation',
    Committed: 'Committed', Repaired: 'Repaired', RolledBack: 'Rolled back', Refused: 'Refused before any change'
  };

  function oscOf(state) { return isObj(state) && isObj(state.osConfiguration) ? state.osConfiguration : null; }
  function oscNodes(state) { var o = oscOf(state); return o ? arr(o.nodes).filter(isObj) : []; }
  // Is there anything from the OS configuration run to show? (a run started, or a machine has an attempt)
  function oscHasData(osc) {
    if (!isObj(osc)) return false;
    return !!(isObj(osc.run) && osc.run.started) || arr(osc.nodes).some(function (n) { return isObj(n) && Number(n.attempt) > 0; });
  }

  // One tree item per machine; its children are the machine's steps. The item carries the machine summary in .osc.machine.
  function osConfigTreeOf(state) {
    return oscNodes(state).map(function (n) {
      return {
        id: str(n.name), name: str(n.name), description: str(n.stateText), status: normStatus(n.status), start: n.start || null, end: n.end || null,
        errors: arr(n.errors).map(str).filter(Boolean), children: arr(n.tree),
        osc: { machine: true, method: str(n.method), methodSource: str(n.methodSource), methodNote: str(n.methodNote), transport: str(n.transport),
          declared: str(n.declared), declaredMethod: str(n.declaredMethod), mismatch: n.mismatch === true, warnings: arr(n.warnings).map(str), versions: isObj(n.versions) ? n.versions : {},
          evidence: isObj(n.evidence) ? n.evidence : {}, state: str(n.state), stateText: str(n.stateText), retries: Number(n.retries) || 0, restarts: Number(n.restarts) || 0,
          guarded: str(n.guarded), guardedDetail: isObj(n.guardedDetail) ? n.guardedDetail : null, runCommands: arr(n.runCommands).filter(isObj),
          changes: Number(n.changes) || 0, blocked: Number(n.blocked) || 0, currentStep: str(n.currentStep),
          domainJoined: n.domainJoined === true, logAccount: isObj(n.logAccount) ? n.logAccount : null,
          address: oscAddressChip(n), timeline: oscTimelineLines(n, 3) }
      };
    });
  }

  // The method chip of a machine: { text, kind, title }. "Ztp" or "Iso"; "expected" when no event has resolved it yet.
  function oscMethodChip(m) {
    var method = str(m.method);
    if (!method) return { text: 'Method unknown', kind: 'idle', title: 'No event has named the method yet, and the master file does not say how this machine was installed.' };
    var label = method === 'Ztp' ? 'ZTP' : 'ISO';
    var title = method === 'Ztp' ? 'Provisioned by ZTP (simplified machine provisioning): the computer name and the Azure Arc registration are checked, everything else is configured.'
      : 'Installed from an ISO: the computer name is set (a restart) and the machine is registered with Azure Arc, besides everything else.';
    if (str(m.methodSource) === 'expected') return { text: label + ' (expected)', kind: 'idle', title: title + ' Expected because ' + (str(m.methodNote) || 'of the master file') + '; the run has not resolved it yet.' };
    if (m.mismatch === true) return { text: label + ' (differs from the file)', kind: 'warn', title: title + ' The master file declares ' + (str(m.declared) || 'another method') + ' but the evidence says ' + method + '; the evidence wins.' };
    return { text: label, kind: method === 'Ztp' ? 'run' : 'ok', title: title };
  }

  // "10.0.26100 build 26100" style text for the versions of a machine; '' when nothing is known.
  function oscVersionLines(m) {
    var v = isObj(m.versions) ? m.versions : {}, out = [];
    var os = str(v.osCaption) || (str(v.osVersion) ? 'OS ' + str(v.osVersion) : '');
    if (os) out.push(os + (v.build && str(v.osVersion).indexOf(str(v.build)) < 0 ? ' (build ' + str(v.build) + ')' : ''));
    if (str(v.hostname)) out.push('computer name ' + str(v.hostname));
    var sbe = [str(v.sbePublisher), str(v.sbeFamily), str(v.sbeVersion)].filter(Boolean).join(' ');
    if (sbe || str(v.sbePackage)) out.push('SBE ' + (sbe || str(v.sbePackage)) + (str(v.sbeDelivery) ? ' (' + str(v.sbeDelivery) + ')' : ''));
    if (str(v.schemaVersion)) out.push('schema ' + str(v.schemaVersion));
    if (str(v.wrapperVersion)) out.push('wrapper ' + str(v.wrapperVersion));
    return out;
  }

  // Seconds left in a guarded change's confirmation window, or NaN.
  function oscCountdown(confirmBy, now) {
    var t = parseTime(confirmBy);
    return isNaN(t) ? NaN : Math.max(0, Math.round((t - (now === undefined ? nowMs() : now)) / 1000));
  }
  function fmtCountdown(sec) {
    if (isNaN(sec)) return '';
    if (sec <= 0) return 'window over';
    return pad(Math.floor(sec / 60)) + ':' + pad(sec % 60) + ' left';
  }

  // The summary-card model of one machine.
  function oscCard(n, now) {
    var chip = oscMethodChip(n), tr = OSC_TRANSPORT_LABEL[str(n.transport)] || str(n.transport);
    var state = str(n.state) || 'waiting', steps = arr(n.tree).filter(isObj);
    var done = steps.filter(function (s) { var st = isObj(s.osc) ? str(s.osc.stage) : ''; return st === 'ok' || st === 'info' || st === 'applied' || st === 'verified' || st === 'skipped'; }).length;
    var cur = str(n.currentStep), curName = '';
    steps.forEach(function (s) { if (isObj(s.osc) && s.osc.step === cur) curName = str(s.name); });
    var g = isObj(n.guardedDetail) ? n.guardedDetail : null;
    var lines = [];
    if (state === 'converged') lines.push('All ' + steps.length + ' steps match the master file');
    else if (state === 'planned') lines.push(str(n.stateText));
    else if (curName) lines.push('Now: ' + curName);
    else if (state === 'waiting') lines.push('Waiting for the run to reach this machine');
    if (n.retries) lines.push('Retried ' + n.retries + (n.retries === 1 ? ' time' : ' times') + ' (Arc Run Command lost)');
    if (n.restarts) lines.push('Restarted ' + n.restarts + (n.restarts === 1 ? ' time' : ' times'));
    if (g && (str(n.guarded) === 'RolledBack' || str(n.guarded) === 'Refused') && str(g.reason)) lines.push((n.guarded === 'RolledBack' ? 'Rolled back: ' : 'Refused: ') + firstLine(g.reason, 140));
    else if (state === 'failed' || state === 'blocked') lines.push(firstLine(arr(n.errors)[0] || str(n.stateText), 140));
    var chips = [{ text: chip.text, kind: chip.kind, title: chip.title }];
    if (tr) chips.push({ text: tr, kind: 'idle', title: 'How this machine is reached.' });
    if (isObj(n.logAccount) && str(n.logAccount.reason)) lines.push('Logs: ' + str(n.logAccount.reason));
    var ac = oscAddressChip(n);
    if (ac) chips.push({ text: ac.text, kind: 'idle', title: ac.title });
    if (isObj(n.waiting)) lines.push('Waiting for ' + str(n.waiting.what) + ' (' + (Number(n.waiting.elapsedSeconds) || 0) + ' s' + (str(n.waiting.phase) ? ', phase ' + str(n.waiting.phase) : '') + ')');
    arr(n.unknownStates).slice(0, 2).forEach(function (u) { lines.push('Event not known to this Sonar: ' + str(u)); });
    return {
      name: str(n.name), seed: false, state: OSC_STATE_LABEL[state] || state, kind: OSC_STATE_KIND[state] || 'idle', status: normStatus(n.status),
      tip: str(n.stateText), arc: null, chips: chips, lines: lines.concat(arr(n.warnings).slice(0, 2).map(function (w) { return 'Warning: ' + firstLine(w, 140); })),
      waits: '', progress: state === 'applying' || state === 'verifying' || state === 'retrying' ? Math.round(100 * done / Math.max(1, steps.length)) : null,
      until: state === 'awaitingconfirm' && g ? str(g.confirmBy) : '', osc: true
    };
  }

  function oscHeadline(osc, mode) {
    var total = Number(osc.nodesTotal) || 0, ok = Number(osc.nodesConverged) || 0, run = isObj(osc.run) ? osc.run : {};
    if (!oscHasData(osc)) return 'No OS configuration run has been seen yet';
    if (osc.ready) return 'OS configuration has converged on all ' + total + ' machine' + (total === 1 ? '' : 's') + '. Next: Validate';
    var bad = arr(osc.nodes).filter(function (n) { return isObj(n) && (n.state === 'failed' || n.state === 'blocked' || n.state === 'rolledback' || n.state === 'refused'); });
    var head = ok + ' of ' + total + ' machine' + (total === 1 ? '' : 's') + ' converged';
    if (bad.length) return head + ': ' + str(bad[0].name) + ' ' + (OSC_STATE_LABEL[bad[0].state] || 'failed').toLowerCase() + (bad.length > 1 ? ' and ' + (bad.length - 1) + ' more' : '');
    if (run.completed && run.mode === 'Plan') return 'Plan finished' + (run.planChanges !== null && run.planChanges !== undefined ? ': ' + run.planChanges + ' change' + (run.planChanges === 1 ? '' : 's') + ' pending' : '') + '. Nothing was changed; run it with -Mode Apply';
    if (run.completed) return head + '; the run ended with exit code ' + run.exitCode;
    var retry = Number(osc.nodesRetrying) || 0;
    return head + (retry ? ', ' + retry + ' retrying' : '') + (osc.state === 'planning' ? ' (reading the machines)' : osc.state === 'applying' ? ' (applying)' : '');
  }

  // The guarded network change panel(s): one per machine that has one. Model: [{ node, title, kind, rows[{k,v}], until, reason }].
  var OSC_GUARDED_PHASE_KIND = { Staged: 'run', Verifying: 'run', AwaitingConfirm: 'warn', Repaired: 'warn', Committed: 'ok', RolledBack: 'err', Refused: 'err' };
  function oscGuardedPanels(osc) {
    return arr(isObj(osc) ? osc.guarded : []).filter(isObj).map(function (g) {
      var phase = str(g.phase) || str(g.state), rows = [];
      rows.push({ k: 'Change id', v: str(g.changeId) || 'not reported' });
      if (str(g.oldAddress) || str(g.newAddress)) rows.push({ k: 'Address', v: (str(g.oldAddress) || '?') + ' \u2192 ' + (str(g.newAddress) || '?') });
      rows.push({ k: 'Phase', v: (OSC_GUARDED_LABEL[phase] || phase) + (g.reconnecting === true ? ' (the host is reconnecting)' : '') + (str(g.rung) ? ', repair rung ' + str(g.rung) : '') });
      if (str(g.confirmBy)) rows.push({ k: 'Deadline', v: fmtDateTime(parseTime(g.confirmBy)) + (Number(g.confirmMinutes) ? ' (' + Number(g.confirmMinutes) + ' min window)' : '') });
      if (str(g.reason)) rows.push({ k: phase === 'Refused' ? 'Refused because' : 'Rollback reason', v: str(g.reason) });
      if (str(g.verdict)) rows.push({ k: 'Node verdict', v: str(g.verdict) });
      return { node: str(g.node), title: 'Guarded network change: ' + str(g.node), kind: OSC_GUARDED_PHASE_KIND[phase] || 'idle', rows: rows, until: g.active === true && phase === 'AwaitingConfirm' ? str(g.confirmBy) : '' };
    });
  }

  // Where a machine's management address came from: { text, title } or null.
  function oscAddressChip(n) {
    var a = isObj(n.address) ? n.address : null;
    if (!a || !str(a.value)) return null;
    return { text: str(a.value) + ' (' + (str(a.source) ? str(a.sourceLabel) : 'source not reported') + ')' + (a.forced === true ? ', transport forced' : ''),
      title: 'The address the run reaches this machine on and how it was found: override, ZTP handoff, Azure Arc machine, infrastructure file or the neighbor table (MAC lookup).' + (a.reconnected === true ? ' The machine answered on this address after a restart or an address change.' : '') };
  }

  // The newest events of a machine (label, status and message), unknown states included; [{ text, kind }].
  function oscTimelineLines(n, count) {
    return arr(n.timeline).filter(isObj).slice(-(count || 3)).map(function (e) {
      return { text: str(e.label) + (e.known === false ? ' (state not known to this Sonar)' : '') + (str(e.message) && str(e.message) !== str(e.label) ? ': ' + firstLine(e.message, 140) : ''), kind: str(e.status) || 'idle' };
    });
  }

  // Facts under the headline: [{ k, v }].
  function oscFacts(osc) {
    var run = isObj(osc.run) ? osc.run : {}, out = [], extra = [];
    extra.push({ k: 'Run id', v: str(run.id) || 'none (older feed: one run)' });
    if (Number(run.staleIgnored) > 0) extra.push({ k: 'Older run, ignored', v: Number(run.staleIgnored) + ' line' + (Number(run.staleIgnored) === 1 ? '' : 's'), warn: true });
    var unk = arr(osc.unknownStates).filter(isObj);
    if (unk.length) extra.push({ k: 'States not known to Sonar', v: unk.map(function (u) { return str(u.state) + (Number(u.count) > 1 ? ' \u00d7' + u.count : ''); }).join(', '), warn: true });
    var rem = isObj(osc.remoting) && isObj(osc.remoting.profile) ? osc.remoting.profile : null;
    if (rem) extra.push({ k: 'Remoting', v: str(rem.class) + (str(rem.posture) ? ', ' + str(rem.posture) : '') + (str(rem.scheme) ? ', ' + str(rem.scheme) : ''), warn: rem.relaxed === true });
    var th = isObj(osc.remoting) && isObj(osc.remoting.trustedHosts) ? osc.remoting.trustedHosts : null;
    if (th && th.changed === true) extra.push({ k: 'TrustedHosts', v: th.restored === true ? 'changed, restored' : 'changed on the runner, not restored yet', warn: th.restored !== true });
    out.push({ k: 'Run', v: ({ waiting: 'not started', planning: 'planning', planned: 'plan finished', applying: 'applying', converged: 'converged', failed: 'failed', incomplete: 'ended, not converged' })[str(osc.state)] || str(osc.state) });
    out.push({ k: 'Machines converged', v: (Number(osc.nodesConverged) || 0) + ' of ' + (Number(osc.nodesTotal) || 0) });
    var w = isObj(osc.wipe) ? osc.wipe : {};
    if (w.published) out.push({ k: 'Wipe list', v: !w.enabled ? 'off' : (Number(w.count) === 0 ? 'nothing to wipe' : (w.pending ? 'pending (' + arr(w.nodes).length + ' machine' + (arr(w.nodes).length === 1 ? '' : 's') + ')' : 'done')), warn: !!(w.enabled && w.pending && Number(w.count) > 0) });
    var wa = isObj(osc.wipe) && isObj(osc.wipe.approval) ? osc.wipe.approval : null;
    if (wa) out.push({ k: 'Wipe list approval', v: str(wa.state).toLowerCase() + (str(wa.message) ? ': ' + firstLine(wa.message, 100) : ''), warn: str(wa.state) === 'Rejected' });
    if (run.mode) out.push({ k: 'Mode', v: run.mode });
    return out.concat(extra);
  }

  // ------------------------------------------------------------------ Discovery (pure; also run by tests under Node)
  //
  // The first stage, before ZTP: the toolkit's Invoke-HardwareDiscovery.ps1 reads each iDRAC and writes one file per machine
  // and a summary. The back end reads them (state.discovery); the page shows the service tag, the ports with their MACs, the
  // suggested management port and the BOSS card of every machine.

  var DISC_STATE_LABEL = { discovered: 'Discovered', attention: 'Check', missing: 'Not discovered yet', unreadable: 'Unreadable' };
  var DISC_STATE_KIND = { discovered: 'ok', attention: 'warn', missing: 'idle', unreadable: 'err' };

  function discOf(state) { return isObj(state) && isObj(state.discovery) ? state.discovery : null; }
  function discNodes(state) { var d = discOf(state); return d ? arr(d.nodes).filter(isObj) : []; }
  // Is there anything from the discovery to show? (a machine was read, or a file could not be)
  function discHasData(d) { return isObj(d) && (Number(d.nodesDiscovered) > 0 || arr(d.problems).length > 0); }

  // One tree item per machine; its children are the identity, the ports, the management port and the BOSS card.
  function discoveryTreeOf(state) {
    return discNodes(state).map(function (n) {
      return {
        id: str(n.name), name: str(n.name), description: str(n.stateText), status: normStatus(n.status), start: null, end: null,
        errors: arr(n.errors).map(str).filter(Boolean), children: arr(n.tree),
        disc: { machine: true, state: str(n.state), serviceTag: str(n.serviceTag), model: str(n.model), notes: arr(n.notes).map(str), management: isObj(n.management) ? n.management : null,
          boss: isObj(n.boss) ? n.boss : null, bmcMac: str(n.bmcMac), ports: arr(n.ports).filter(isObj) }
      };
    });
  }

  // The summary-card model of one machine in the Discovery mode.
  function discCard(n) {
    var state = str(n.state) || 'missing', m = isObj(n.management) ? n.management : null, b = isObj(n.boss) ? n.boss : {};
    var lines = [];
    if (state === 'missing') lines.push(str(n.stateText));
    if (state === 'unreadable') lines.push(firstLine(arr(n.errors)[0] || str(n.stateText), 140));
    if (n.found !== false && state !== 'unreadable') {
      if (str(n.serviceTag)) lines.push('Service tag ' + str(n.serviceTag));
      var ports = arr(n.ports), up = ports.filter(function (p) { return isObj(p) && p.linkUp === true; }).length;
      if (ports.length) lines.push(ports.length + ' network port' + (ports.length === 1 ? '' : 's') + ', ' + up + ' with link up');
      lines.push(m ? 'Management port: ' + str(m.name) + (str(m.mac) ? ' (' + str(m.mac) + ')' : '') + (m.confirmed ? '' : ' - a guess, confirm it') : 'No management port suggested');
      arr(n.notes).slice(0, 2).forEach(function (t) { lines.push('Check: ' + firstLine(t, 140)); });
    }
    var chips = [];
    if (str(n.model)) chips.push({ text: str(n.model), kind: 'idle', title: 'The model the iDRAC reports.' });
    if (b.present === true) chips.push({ text: b.hasVirtualDisk ? 'BOSS: virtual disk' : 'BOSS: no virtual disk', kind: b.hasVirtualDisk ? 'ok' : 'warn', title: 'The BOSS card holds the OS drives. A card without a virtual disk gets one in the toolkit\u2019s Phase 02 Task 01, before the OS install.' });
    else if (n.found !== false && state !== 'unreadable') chips.push({ text: 'No BOSS card', kind: 'idle', title: 'The iDRAC lists no BOSS card.' });
    return {
      name: str(n.name), seed: false, state: DISC_STATE_LABEL[state] || state, kind: DISC_STATE_KIND[state] || 'idle', status: normStatus(n.status),
      tip: str(n.stateText), arc: null, chips: chips, lines: lines, waits: '', progress: null, until: '', discovery: true
    };
  }

  function discHeadline(d, manual) {
    if (!isObj(d) || d.configured !== true) return 'Discovery is not configured: set discoveryPath to the folder of the toolkit\u2019s hardware discovery';
    var total = Number(d.nodesTotal) || 0, ok = Number(d.nodesDiscovered) || 0;
    switch (str(d.state)) {
      case 'waiting': return 'Waiting for the discovery output. Run Invoke-HardwareDiscovery.ps1 from the toolkit; Sonar reads the folder it writes.';
      case 'empty': return 'The discovery folder is there but holds no machine yet';
      case 'partial': return ok + ' of ' + total + ' machine' + (total === 1 ? '' : 's') + ' read; the discovery is still running';
      case 'failed': return arr(d.problems).length ? arr(d.problems).length + ' discovery file' + (arr(d.problems).length === 1 ? '' : 's') + ' could not be read (' + str(d.problems[0].file) + ')' : ok + ' of ' + total + ' machines discovered; ' + (Number(d.nodesFailed) || 0) + ' not';
      case 'discovered': return str(d.stateText) + '. Next: ' + (manual ? 'OS configuration' : 'ZTP');
      default: return str(d.stateText);
    }
  }

  // ------------------------------------------------------------------ ARM Validate and Deploy (pure; also run by tests under Node)
  //
  // The toolkit's Invoke-AzureLocalArmDeployment.ps1 checks the instance, submits Validate, waits, asks for approval,
  // submits Deploy and waits; its event feed becomes state.arm (Get-AzlSonarArmState): the run, and for each phase
  // (validation, deployment) its checks (failures first), its steps, its elapsed time and a hint for a known failure.
  // The page shows that inside the Validate and Deployment modes, next to the steps Azure reports itself. Azure's own
  // trees stay the truth once Azure has steps; the feed covers what Azure cannot: the checks before the submit, a refusal,
  // and the toolkit's words for a failure.

  var ARM_STATE_LABEL = {
    waiting: 'Waiting for a run', checking: 'Checking', planned: 'Plan ready', validating: 'Validating', validated: 'Validated',
    awaitingapproval: 'Waiting for approval', deploying: 'Deploying', deployed: 'Deployed', failed: 'Failed'
  };
  var ARM_RESULT_KIND = { Passed: 'ok', Failed: 'err', Warning: 'warn', Skipped: 'idle' };
  var ARM_MODE_WORD = { Plan: 'Plan', Validate: 'Validate', Deploy: 'Deploy', ValidateAndDeploy: 'Validate and Deploy' };
  var ARM_PHASE_OF_MODE = { validate: 'validation', deploy: 'deployment' };

  // The sample run of ?demo=1&route=arm (example names), declared here because the exports below are reached before the demo code.
  var ARM_DEMO_CHECKS = [['AzureContext', '*'], ['ResourceGroup', '*'], ['ResourceProviders', '*'], ['Permissions', '*'], ['NamesAvailable', '*'], ['KeyVaultSecrets', '*'],
    ['ArcMachinesConnected', 'iic-azl-n01'], ['ArcMachinesConnected', 'iic-azl-n02'], ['ArcMachinesConnected', 'iic-azl-n03'],
    ['ArcMachineNaming', 'iic-azl-n01'], ['ArcMachineNaming', 'iic-azl-n02'], ['ArcMachineNaming', 'iic-azl-n03'],
    ['OsConfigurationConverged', 'iic-azl-n01'], ['OsConfigurationConverged', 'iic-azl-n02'], ['OsConfigurationConverged', 'iic-azl-n03'],
    ['OsBuildConsistent', '*'], ['DnsAndTime', '*'], ['ActiveDirectoryPrepared', '*']];
  var ARM_DEMO_VSTEPS = [['0.1', 'Check Arc connectivity'], ['0.2', 'Check hardware requirements'], ['0.3', 'Check network settings'], ['0.4', 'Check storage'],
    ['0.5', 'Check Active Directory'], ['0.6', 'Check Key Vault access'], ['0.7', 'Check time and DNS'], ['0.8', 'Create the validation resources']];

  function armOf(state) { return isObj(state) && isObj(state.arm) ? state.arm : null; }
  function armHasData(arm) { return isObj(arm) && arm.hasData === true; }
  function armPhaseOf(state, which) { var a = armOf(state); return a && isObj(a[which]) ? a[which] : null; }
  function armPhaseHasData(ph) { return isObj(ph) && !!str(ph.status) && ph.status !== 'notstarted'; }
  // The tree of a phase: the checks group, then the steps group (both built by the back end).
  function armTreeOf(state, which) { var ph = armPhaseOf(state, which); return ph ? arr(ph.tree).filter(isObj) : []; }

  // The mode the ARM run is in, when it is further on than the Azure phase says: validate or deploy, else ''.
  function armActiveMode(state) {
    var a = armOf(state);
    if (!armHasData(a)) return '';
    var ph = armPhaseOf(state, a.activePhase === 'deployment' ? 'deployment' : 'validation');
    if (!armPhaseHasData(ph) || ph.status === 'planned') return '';
    return a.activePhase === 'deployment' ? 'deploy' : 'validate';
  }

  // The tile of Validate or Deployment from the ARM run, or null when Azure already has steps of its own for the mode.
  function armTile(state, modeId, azureStatus) {
    var ph = armPhaseOf(state, ARM_PHASE_OF_MODE[modeId]);
    if (!armPhaseHasData(ph)) return null;
    if (azureStatus !== 'notstarted' && azureStatus !== 'unknown') return null;
    var c = isObj(ph.checkCounts) ? ph.checkCounts : {}, cur = isObj(ph.current) ? ph.current : null, fail = isObj(ph.failing) ? ph.failing : null;
    var tip = str(ph.text) + (str(ph.nextAction) ? '. Next: ' + firstLine(ph.nextAction, 200) : '');
    switch (ph.status) {
      case 'checking': return { status: 'run', line: 'Checking', tip: tip };
      case 'planned': return { status: 'idle', line: 'Plan ready', tip: tip };
      case 'blocked': return { status: 'err', line: (Number(c.failed) || 0) + ' check' + (Number(c.failed) === 1 ? '' : 's') + ' failed', tip: tip };
      case 'running': {
        var sec = Number(ph.elapsedSeconds);
        return { status: 'run', line: (cur ? 'Step ' + str(cur.step) : 'Running') + (sec >= 0 && !isNaN(sec) ? ' · ' + (fmtDuration(sec) || '0s') : ''), tip: tip };
      }
      case 'passed': return { status: 'ok', line: modeId === 'validate' ? 'Passed' : 'Done', tip: tip };
      case 'failed': return { status: 'err', line: fail && str(fail.step) ? 'Failed at ' + str(fail.step) : 'Failed', tip: tip };
      case 'timedout': return { status: 'err', line: 'Timed out', tip: tip };
      case 'refused': return { status: 'err', line: 'Not started', tip: tip };
    }
    return null;
  }

  // One sentence for the summary box, from the phase of the ARM run.
  function armHeadline(ph) {
    if (!isObj(ph)) return '';
    var c = isObj(ph.checkCounts) ? ph.checkCounts : {}, s = isObj(ph.stepCounts) ? ph.stepCounts : {}, cur = isObj(ph.current) ? ph.current : null, fail = isObj(ph.failing) ? ph.failing : null;
    switch (ph.status) {
      case 'checking': return 'The toolkit is checking the instance before ' + str(ph.label) + ': ' + (Number(c.total) || 0) + ' check' + (Number(c.total) === 1 ? '' : 's') + ' so far';
      case 'planned': return str(ph.text) + '. Nothing was submitted';
      case 'blocked': return firstLine(ph.message, 200) || ((Number(c.failed) || 0) + ' check(s) failed; nothing was submitted');
      case 'running': return str(ph.label) + ' is running: ' + (Number(s.total) || 0) + ' step' + (Number(s.total) === 1 ? '' : 's') + ' reported' + (cur ? ' (now ' + str(cur.step) + ' ' + str(cur.name) + ')' : '');
      case 'passed': return str(ph.text);
      case 'failed': return str(ph.text) + (fail && str(fail.message) ? ': ' + firstLine(fail.message, 180) : '');
      case 'timedout': return str(ph.text);
      case 'refused': return firstLine(ph.text, 220);
    }
    return '';
  }

  // Facts under the headline: [{ k, v, warn }].
  function armFacts(arm, which) {
    var ph = isObj(arm) && isObj(arm[which]) ? arm[which] : null, out = [];
    if (!armPhaseHasData(ph)) return out;
    var run = isObj(arm.run) ? arm.run : {}, c = isObj(ph.checkCounts) ? ph.checkCounts : {}, s = isObj(ph.stepCounts) ? ph.stepCounts : {};
    out.push({ k: 'Toolkit run', v: (ARM_MODE_WORD[str(run.mode)] || str(run.mode) || 'run') + ', ' + (ARM_STATE_LABEL[str(arm.state)] || str(arm.state)).toLowerCase() });
    if (Number(c.total) > 0) {
      out.push({ k: 'Checks', v: (Number(c.passed) || 0) + ' passed, ' + (Number(c.failed) || 0) + ' failed' + (c.warning ? ', ' + c.warning + ' with a warning' : '') + (c.skipped ? ', ' + c.skipped + ' skipped' : ''), warn: Number(c.failed) > 0 });
    }
    if (Number(s.total) > 0) {
      out.push({ k: 'Steps', v: s.total + ' reported: ' + (Number(s.success) || 0) + ' done' + (s.running ? ', ' + s.running + ' running' : '') + (s.error ? ', ' + s.error + ' failed' : ''), warn: Number(s.error) > 0 });
    }
    var sec = Number(ph.elapsedSeconds);
    if (ph.elapsedSeconds !== null && ph.elapsedSeconds !== undefined && !isNaN(sec)) out.push({ k: 'Elapsed', v: (fmtDuration(sec) || '0s') + (ph.status === 'running' ? ' so far' : '') });
    if (which === 'validation' && str(run.template)) out.push({ k: 'Template', v: str(run.template) + (str(run.parameterHash) ? ' · parameters ' + str(run.parameterHash) : '') });
    if (ph.skipped) out.push({ k: 'Validation', v: 'already passed with these parameters; not submitted again' });
    if (isObj(ph.resumed)) out.push({ k: 'Resumed', v: 'resubmitted after ' + (str(ph.resumed.previous) || 'an earlier run').toLowerCase() + '; the first steps show where Azure restarted', warn: true });
    if (which === 'validation' && arm.awaitingApproval === true) out.push({ k: 'Approval', v: 'waiting; run Mode Deploy to go on', warn: true });
    if (isObj(ph.hint)) out.push({ k: 'Known failure', v: str(ph.hint.title), warn: true });
    else if (isObj(ph.preventiveHint)) out.push({ k: 'Heads-up', v: str(ph.preventiveHint.title) + (arr(ph.preventiveHint.nodes).length ? ' (' + arr(ph.preventiveHint.nodes).map(str).join(', ') + ')' : '') + '; Deploy would stop at step 0.41', warn: true });
    if (str(ph.nextAction)) out.push({ k: 'Next', v: firstLine(ph.nextAction, 220) });
    return out;
  }

  // The top-bar text when the ARM run is what is happening and Azure has no steps for the phase yet, or null.
  function armOverall(state) {
    var m = armActiveMode(state);
    if (!m) return null;
    var ph = armPhaseOf(state, ARM_PHASE_OF_MODE[m]), az = sectionStatus(isObj(state) ? state[ARM_PHASE_OF_MODE[m]] : null);
    if (az !== 'notstarted' && az !== 'unknown') return null;
    var key = ph.kind === 'running' ? 'running' : ph.kind === 'success' ? 'success' : ph.kind === 'error' ? 'error' : 'unknown';
    return { key: key, label: str(ph.label) + ': ' + str(ph.text) };
  }

  // ------------------------------------------------------------------ modes and summary (pure; also run by tests under Node)
  //
  // The page shows one "mode" at a time: Discovery, Provisioning, OS configuration, Validate, Deployment, Update (and, for a
  // run that Sonar was started for, Add node or Repair). A mode maps onto the phase the back end reports (phase /
  // activePhase) and the section of the state that holds its data (discovery, provisioning, validation, deployment,
  // update). Azure's raw states are turned into plain words here; the raw value goes into a tooltip. A finished
  // deployment is the Deployment mode in its Done state; the machine cards keep each machine's Azure Arc status.

  var MODE_IDS = ['discovery', 'prov', 'osconfig', 'validate', 'deploy', 'update', 'addnode', 'repair'];
  var MODE_OF_PHASE = {
    provisioning: 'prov', 'arc-registration': 'prov', validation: 'validate', deployment: 'deploy', update: 'update',
    done: 'deploy', 'post-deployment': 'deploy', 'add-node': 'addnode', repair: 'repair'
  };
  var MODE_TITLE = { discovery: 'Discovery', osconfig: 'OS configuration', validate: 'Validate', deploy: 'Deployment', update: 'Update', addnode: 'Add node', repair: 'Repair' };
  // Start-AzlSonar.ps1 -Monitor (the monitor key of the config): the one tile a standalone monitor shows.
  var MONITOR_TILE = { discovery: 'discovery', provisioning: 'prov', osconfiguration: 'osconfig', validate: 'validate', deployment: 'deploy', update: 'update', addnode: 'addnode', repair: 'repair' };
  // The tile a standalone monitor was started for, or '' (Auto: every tile of the flow).
  function monitorOf(state) {
    var k = isObj(state) ? str(state.monitor).toLowerCase().replace(/[^a-z]/g, '') : '';
    return MONITOR_TILE[k] || '';
  }
  // Provisioning is not used when the master file says the OS was installed by hand (scenario.os_install is not simplified).
  function manualInstall(state) { return isObj(state) && isObj(state.provisioning) && state.provisioning.manualInstall === true; }

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

  // The mode that is happening now. A failed run stays on the mode that failed; a finished one is Deployment (Done).
  function activeModeId(state) {
    if (!isObj(state)) return 'prov';
    var p = normPhase(state.phase), act = str(state.activePhase).toLowerCase();
    var key = p === 'failed' ? (act || 'provisioning') : (p === 'done' ? 'done' : (act || p));
    var only = monitorOf(state);
    if (only) return only;
    var mode = MODE_OF_PHASE[key] || 'prov';
    // Provisioning is over for the machines that ZTP finished, or an OS configuration run has started: that mode is the one to watch.
    // A manual install has no provisioning to watch: the run starts at OS configuration.
    if (mode === 'prov') {
      var osc = oscOf(state), disc = discOf(state);
      var provStarted = provisioningTreeOf(state).some(function (n) { return normStatus(n.status) !== 'notstarted'; });
      // Discovery comes first: while it is the only stage with anything to show, it is the one to watch.
      if (disc && disc.configured === true && !provStarted && !(osc && oscHasData(osc))) return 'discovery';
      if (manualInstall(state)) return 'osconfig';
      if (osc && (oscHasData(osc) || (osc.configured === true && ztpComplete(state)))) return 'osconfig';
    }
    // The toolkit's ARM run can be ahead of what Azure reports (checks that failed before anything was submitted).
    var armMode = armActiveMode(state);
    if (armMode && MODE_IDS.indexOf(armMode) > MODE_IDS.indexOf(mode) && p !== 'done') return armMode;
    return mode;
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
    discovery: 'Runs first, before ZTP: the toolkit’s Invoke-HardwareDiscovery.ps1 reads each iDRAC; Sonar follows the folder it writes (discoveryPath)',
    prov: { simplified: 'Starts after discovery: ZTP claims the machines', 'oem-image': 'Starts when the machines register with Azure Arc', '': 'Starts after discovery' },
    addnode: 'Available after the cluster is deployed; Sonar follows the Arc machines and the node log',
    repair: 'Available after the cluster is deployed; Sonar follows the Arc machines and the node log',
    osconfig: 'Starts after ZTP is complete; follows the toolkit’s OS configuration event file (osConfigEventsPath)',
    validate: { simplified: 'Starts after OS configuration has converged on every machine', 'oem-image': 'Starts when every machine is registered', '': 'Starts after the machines are ready' },
    deploy: 'Starts after validation passes',
    update: 'Available after the cluster is deployed; starts when Azure reports an update'
  };
  function modeWhen(id, route, manual) {
    if (id === 'validate') return MODE_WHEN.validate[route] || MODE_WHEN.validate[''];
    if (id === 'prov') return manual ? 'Not used: the OS was installed by hand' : (MODE_WHEN.prov[route] || MODE_WHEN.prov['']);
    if (id === 'osconfig' && manual) return 'Starts when the machines answer; follows the toolkit’s OS configuration event file (osConfigEventsPath)';
    return MODE_WHEN[id] || '';
  }

  // The tiles of the flow: { id, name, status ok|run|idle|na|err, line, tip, hidden }. Discovery, Provisioning, OS configuration,
  // Validate, Deployment and Update are the six of a normal run; Add node and Repair are tiles of their own that show only when
  // the run is one of them. A waiting tile has no state line; its tip says when it starts. Status na is a stage that is not
  // used in this run (a manual install has no provisioning). A standalone monitor (state.monitor) shows its tile only.
  function modeStates(state) {
    var s = isObj(state) ? state : {};
    var route = provRouteOf(s), machines = provMachines(s);
    var active = activeModeId(s), order = MODE_IDS.indexOf(active), phase = normPhase(s.phase);
    var provIdx = MODE_IDS.indexOf('prov'), manual = manualInstall(s);
    var out = [];
    function tile(id, status, line, hidden, tip) {
      out.push({ id: id, name: id === 'prov' && manual ? 'Provisioning' : modeName(id, route), status: status, line: line || '', tip: tip || (status === 'idle' ? modeWhen(id, route, manual) : ''), hidden: !!hidden });
    }

    // Discovery: the first stage, before ZTP. Grey with a tip that says how to get its data when there is none.
    var disc = discOf(s), dst = 'idle', dline = '', dtip = '';
    if (disc && disc.configured === true && (discHasData(disc) || str(disc.state) === 'failed')) {
      var dtotal = Number(disc.nodesTotal) || 0, dok = Number(disc.nodesDiscovered) || 0;
      if (str(disc.state) === 'failed') { dst = 'err'; dline = arr(disc.problems).length ? arr(disc.problems).length + ' unreadable' : dok + ' of ' + dtotal + ' discovered, ' + (Number(disc.nodesFailed) || 0) + ' failed'; }
      else if (str(disc.state) === 'partial') { dst = 'run'; dline = dok + ' of ' + dtotal + ' machines read'; }
      else { dst = 'ok'; dline = dok + ' of ' + dtotal + ' machines'; }
    } else if (disc && disc.configured === true) {
      dtip = order > provIdx || phase === 'done' ? 'No discovery data in this run.' : modeWhen('discovery', route, manual);
    } else {
      dtip = 'Set discoveryPath to follow the toolkit’s hardware discovery (Invoke-HardwareDiscovery.ps1), which runs before ZTP.';
    }
    tile('discovery', dst, dline, false, dtip);

    var psum = provisioningSummary(provisioningTreeOf(s));
    var unit = route === 'oem-image' ? 'registered' : 'ready';
    var counted = psum.ready + ' of ' + psum.total + ' machines ' + unit;
    var pst, pline = '', ptip = '';
    if (manual) { pst = 'na'; pline = 'Not used: manual install'; ptip = 'The OS was installed by hand; OS configuration starts when the machines answer.'; }
    else if (psum.failed) { pst = 'err'; pline = psum.ready + ' of ' + psum.total + ' ' + unit + ', ' + psum.failed + ' failed'; }
    else if (psum.total && psum.ready === psum.total) { pst = 'ok'; pline = ztpComplete(s) ? 'ZTP complete' : counted; }
    else if ((order > provIdx || phase === 'done') && !psum.total && !machines.length && !route) { pst = 'idle'; }   // Sonar saw no machines: it cannot say provisioning is done
    else if (order > provIdx || phase === 'done') { pst = 'ok'; pline = psum.total ? counted : 'Done'; }
    else if (active === 'prov') { pst = 'run'; pline = psum.total ? counted : 'Waiting for the machines'; }
    else pst = 'idle';
    // With no machine data (a run Sonar joined after provisioning) the tile is grey and its tip says why.
    tile('prov', pst, pline, false, ptip || (pst === 'idle' && order > provIdx ? 'No machine data in this run: Sonar started after provisioning, or the resource group has no edge machines.' : ''));

    // OS configuration: ready for the cluster when every machine has converged. It never keeps Provisioning running.
    var osc = oscOf(s), ost, oline = '', otip = '';
    if (osc && oscHasData(osc)) {
      var ototal = Number(osc.nodesTotal) || 0, ook = Number(osc.nodesConverged) || 0;
      if (Number(osc.nodesFailed) > 0) { ost = 'err'; oline = ook + ' of ' + ototal + ' converged, ' + osc.nodesFailed + ' failed'; }
      else if (osc.ready) { ost = 'ok'; oline = ook + ' of ' + ototal + ' converged'; }
      else if (osc.status === 'running') { ost = 'run'; oline = ook + ' of ' + ototal + ' converged' + (Number(osc.nodesRetrying) ? ', ' + osc.nodesRetrying + ' retrying' : ''); }
      else { ost = 'idle'; oline = osc.state === 'planned' ? 'Plan ready' : ook + ' of ' + ototal + ' converged'; otip = osc.state === 'planned' ? 'The plan was made and nothing was changed. Run the OS configuration with -Mode Apply.' : ''; }
    } else {
      ost = 'idle';
      otip = osc && osc.configured === true ? (order > MODE_IDS.indexOf('osconfig') || phase === 'done' ? 'No OS configuration data in this run.' : modeWhen('osconfig', route, manual)) : 'Set osConfigEventsPath to follow the toolkit’s OS configuration run.';
    }
    tile('osconfig', ost, oline, false, otip);

    [['validate', s.validation, MODE_IDS.indexOf('validate')], ['deploy', s.deployment, MODE_IDS.indexOf('deploy')]].forEach(function (x) {
      var sec = isObj(x[1]) ? x[1] : null, st = sec ? sectionStatus(sec) : 'notstarted', pr = stepProgress(sec && sec.tree);
      var at = order <= x[2] && phase !== 'done' ? armTile(s, x[0], st) : null;   // Azure has no steps for it yet: the ARM run says
      if (at) tile(x[0], at.status, at.line, false, at.tip);
      else if (st === 'success') tile(x[0], 'ok', x[0] === 'validate' ? 'Passed' : 'Done');
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

    // Add node and Repair: a tile of their own, shown only when the run is one of them (Azure reports no steps for them).
    var track = str(s.track).toLowerCase(), act = str(s.activePhase).toLowerCase(), only = monitorOf(s);
    ['addnode', 'repair'].forEach(function (id) {
      var key = id === 'addnode' ? 'add-node' : 'repair', on = track === key || act === key || only === id;
      if (!on) return;
      if (act === key) tile(id, 'run', 'Following the node log', false);
      else tile(id, 'idle', '', false);
    });
    // A standalone monitor shows its own tile only; the others are hidden, not greyed.
    if (only) out.forEach(function (t) { t.hidden = t.id !== only; });
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
    var chipText = { ok: 'Done', run: 'Running', err: 'Failed', idle: 'Waiting', na: 'Not used' };
    var out = { id: me.id, title: me.name, status: me.status, chip: { kind: me.status, text: chipText[me.status] }, headline: '',
      startedAt: NaN, endedAt: NaN, when: me.tip, cards: [] };
    var machines = machineList(s, config);

    if (me.id === 'discovery') {
      var dd = discOf(s) || {}, dnodes = discNodes(s);
      var dlatest = parseTime(dd.collectedAt);
      if (!isNaN(dlatest) && me.status === 'ok') out.endedAt = dlatest;
      out.cards = dnodes.map(function (n) { return discCard(n); });
      out.headline = discHeadline(dd, manualInstall(s));
      out.facts = discHasData(dd) ? [{ k: 'Discovered', v: (Number(dd.nodesDiscovered) || 0) + ' of ' + (Number(dd.nodesTotal) || 0) }, { k: 'Summary', v: dd.summaryFound ? 'written (the run finished)' : 'not written yet' }].concat(dd.collectedAt ? [{ k: 'Latest read', v: fmtDateTime(dlatest) }] : []) : [];
      return out;
    }

    if (me.id === 'prov' && manualInstall(s)) {
      out.headline = 'Not used: the OS was installed by hand, so Sonar has no provisioning to watch. OS configuration starts when the machines answer.';
      out.cards = [];
      return out;
    }

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

    if (me.id === 'osconfig') {
      var os = oscOf(s) || {}, orun = isObj(os.run) ? os.run : {};
      var ost0 = parseTime(orun.started), oend = parseTime(orun.completed);
      if (!isNaN(ost0)) out.startedAt = ost0;
      if (me.status === 'ok' && !isNaN(oend)) out.endedAt = oend;
      out.cards = oscNodes(s).map(function (n) { return oscCard(n); });
      out.headline = me.status === 'idle' && !oscHasData(os) ? me.tip : oscHeadline(os);
      out.facts = oscHasData(os) ? oscFacts(os) : [];
      out.panels = oscGuardedPanels(os);
      return out;
    }

    var sec = me.id === 'validate' ? s.validation : me.id === 'deploy' ? s.deployment : me.id === 'update' ? s.update : null;
    var secTree = isObj(sec) ? arr(sec.tree) : [];
    var pr = stepProgress(secTree), word = { validate: 'Validation', deploy: 'Deployment', update: 'Update', addnode: 'Add node', repair: 'Repair' }[me.id];
    if (me.id === 'validate' || me.id === 'deploy' || me.id === 'update') {
      var a = treeStartMin(secTree), b = treeEndMax(secTree);
      if (!isNaN(a)) out.startedAt = a;
      if (me.status === 'ok' && !isNaN(b)) out.endedAt = b;
    }
    var past = { validate: 'Validation passed', deploy: 'Deployment finished', update: 'Update finished' };
    var cur = isObj(s.current) && str(s.current.stepName) && MODE_OF_PHASE[str(s.current.phase)] === me.id ? str(s.current.stepName) : pr.name;
    var conn = machines.filter(function (m) { return str(m.arcStatus).toLowerCase() === 'connected'; }).length;
    if (me.id === 'addnode' || me.id === 'repair') {
      out.headline = me.status === 'run' ? word + ': Sonar follows the Arc machines and the node log; Azure reports no steps for it' : me.tip;
    } else if (me.status === 'ok') out.headline = past[me.id] + (me.id === 'deploy' && machines.length ? ': ' + conn + ' of ' + machines.length + ' machines are connected to Azure Arc' : '');
    else if (me.status === 'err') {
      var bad = firstError(secTree);
      out.headline = word + ' failed' + (bad ? ' at ' + str(bad.name) + (arr(bad.errors)[0] ? ': ' + firstLine(arr(bad.errors)[0], 160) : '') : '');
    } else if (me.status === 'run') {
      out.headline = word + ' is running' + (pr.total ? ': step ' + pr.current + ' of ' + pr.total : '') + (cur ? ' (' + cur + ')' : '');
    } else out.headline = me.tip;

    var verb = { validate: ['Validated', 'Being validated', 'Waiting'], deploy: ['Deployed', 'Taking part', 'Waiting'],
      update: ['Updated', 'Being updated', 'Waiting'], addnode: ['Added', 'Following', 'Waiting'], repair: ['Repaired', 'Following', 'Waiting'] }[me.id];
    var pct = pr.total ? Math.round(100 * pr.done / pr.total) : null;
    var waitsFor = { validate: 'the machines to be ready', deploy: 'validation', update: 'an update from Azure', addnode: 'the cluster', repair: 'the cluster' }[me.id];
    out.cards = machines.map(function (m) {
      var arc = arcInfo(m.arcStatus);
      var card = { name: m.name, seed: !!m.seed, arc: arc, progress: null, waits: '', tip: '', status: me.status, kind: me.status };
      if (me.id === 'addnode' || me.id === 'repair') {
        card.state = me.status === 'run' ? 'Following' : 'Waiting';
        card.waits = me.status === 'idle' ? me.tip : '';
        card.tip = 'Azure Arc says: ' + (str(m.arcStatus) || 'no status');
        return card;
      }
      card.state = me.status === 'ok' ? verb[0] : me.status === 'run' ? verb[1] : me.status === 'err' ? 'Stopped' : verb[2];
      card.waits = me.status === 'run' && cur ? 'Now: ' + cur : (me.status === 'idle' ? 'Waits for ' + waitsFor : '');
      if (me.status === 'run') card.progress = pct;
      return card;
    });
    if (me.id === 'validate' || me.id === 'deploy') {
      var which = ARM_PHASE_OF_MODE[me.id], aph = armPhaseOf(s, which);
      if (armPhaseHasData(aph)) {
        // Azure has no steps for the mode yet: the ARM run supplies the headline and the times. Either way its facts show.
        var azSt = sec ? sectionStatus(sec) : 'notstarted';
        if (azSt === 'notstarted' || azSt === 'unknown') {
          out.headline = armHeadline(aph) || out.headline;
          var as = parseTime(aph.started), ae = parseTime(aph.completed);
          if (!isNaN(as)) out.startedAt = as;
          if (!isNaN(ae) && me.status !== 'run') out.endedAt = ae;
        } else if (aph.status === 'failed' && isObj(aph.hint)) {
          out.headline += '. Known failure: ' + str(aph.hint.title);
        }
        out.facts = armFacts(armOf(s), which);
      }
    }
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

  var MODE_SECTIONS = { discovery: ['discovery'], prov: ['provisioning'], osconfig: ['osconfiguration'], validate: ['armvalidation', 'validation', 'extensions'], deploy: ['armdeployment', 'deployment'], update: ['update'], addnode: [], repair: [] };

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
    if (section === 'osconfiguration') {
      // A machine row selects the machine; a step filters the log to that machine's [osconfig] lines for the step.
      if (list.length === 1) return { side: 'machine', node: str(top.name), stage: '', window: false };
      var ostep = isObj(list[1].osc) ? str(list[1].osc.step) : '';
      return { side: 'node', node: str(top.name), stage: ostep ? 'osc.' + ostep.toLowerCase() : '', window: false };
    }
    // The toolkit's own checks and steps: reported by the ARM run, not by a node (no log window) and not read from Azure.
    if (section === 'armvalidation' || section === 'armdeployment') return { side: 'arm', node: '', stage: '', window: false };
    if (section === 'discovery') {
      // A machine row selects the machine; what discovery read about it is a file, not a node log: a click filters nothing.
      return { side: list.length === 1 ? 'machine' : 'file', node: str(top.name), stage: '', window: false };
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
    if (modeId === 'addnode' || modeId === 'repair') return 'Azure reports no steps for this operation. Sonar follows the Arc machines (the cards above) and the seed node’s log.';
    if (modeId === 'discovery') return status === 'idle' ? 'The machines appear here when the toolkit’s hardware discovery has written its output. Run Invoke-HardwareDiscovery.ps1 and point discoveryPath at its output folder.' + (when ? ' ' + when + '.' : '') : 'No machines reported yet.';
    if (modeId === 'prov' && status === 'na') return 'Not used: the OS was installed by hand. There is nothing to provision; OS configuration starts when the machines answer.';
    if (modeId === 'prov' && !hasMachines) return 'No machines reported yet.';
    if (modeId === 'osconfig' && status === 'idle') return 'The steps appear here when the OS configuration run starts. Run Invoke-AzureLocalOsConfiguration.ps1 from the toolkit and point osConfigEventsPath at its os-configuration-events.jsonl.' + (when ? ' ' + when + '.' : '');
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
    var oscn = oscNodes(s);
    oscn.forEach(function (n) {
      arr(n.warnings).slice(0, 2).forEach(function (w) { out.push({ kind: 'osconfig', text: 'OS configuration, ' + str(n.name) + ': ' + firstLine(w, 220) }); });
    });
    var armA = armOf(s);
    if (armHasData(armA)) {
      arr(armA.hints).filter(isObj).forEach(function (h) {
        out.push({ kind: 'arm', text: (h.preventive === true ? 'Before Deploy: ' : 'Known failure: ') + str(h.title) + '. ' + firstLine(h.text, 300) });
      });
      arr(armA.warnings).slice(0, 2).forEach(function (w) { out.push({ kind: 'arm', text: 'ARM run: ' + firstLine(w, 220) }); });
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

  // ------------------------------------------------------------------ OS configuration demo (pure; ?demo=1&route=osconfig and the built-in replay)
  //
  // Two or three machines in different situations, one ZTP and one ISO side by side: iic-azl-n01 (ZTP, over Arc Run Command)
  // plans, applies and converges with one retry of a lost run command; iic-azl-n02 (ISO, over WinRM) changes its management
  // address with the guarded change (commit confirmed), restarts for its computer name, registers with Azure Arc, fails
  // on the OEM drivers, and converges on a second attempt; iic-azl-n03 (ZTP, over WinRM) is still applying. r is the minutes
  // since the run began. Sample names and documentation values only.

  var OSC_DEMO_STEP = ['RemoteManagement', 'Network', 'Dns', 'Time', 'Hostname', 'DomainJoin', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'Drivers', 'ArcRegistration'];
  var OSC_DEMO_NAME = {
    RemoteManagement: 'Remote management', Network: 'Network (management address)', Dns: 'DNS servers', Time: 'Time (NTP)', Hostname: 'Computer name',
    UnusedAdapters: 'Unused network adapters', LocalAdmin: 'Local administrator', Mpio: 'MPIO (SAN)', SanVerify: 'SAN verification', ClearStorage: 'Clear storage',
    Sbe: 'SBE package', Drivers: 'OEM drivers', ArcRegistration: 'Azure Arc registration', DomainJoin: 'Domain join'
  };
  var OSC_DEMO_OK = {
    RemoteManagement: 'WinRM: Running/Automatic, 1 listener(s)', Network: 'management: static 192.0.2.%IP%/24 gw 192.0.2.1', Dns: 'DNS: 192.0.2.53,192.0.2.54',
    Time: 'NTP peers: ntp.example.test', Hostname: 'computer name: %NAME%', UnusedAdapters: '2 unused port(s) disabled', LocalAdmin: 'azl-admin: present, enabled, in Administrators',
    Mpio: 'MultipathIO feature: Enabled', SanVerify: '2 SAN disk(s), 4 paths each', ClearStorage: 'no leftover local storage', Sbe: 'SBE_Dell_16G-45n0c-Intel_5.0.2606.1616.zip: present, SHA-256 matches',
    Drivers: 'OEM network drivers: current', ArcRegistration: 'Arc machine %NAME% is Connected', DomainJoin: 'joined iic.example.test (OU=Servers)'
  };

  function oscDemoSpecs() {
    return [
      { name: 'iic-azl-n01', ip: 11, method: 'Ztp', transport: 'ArcRunCommand', declared: 'simplified', start: 0.2, planAt: 0.9, verifyAt: 3.2, convergedAt: 3.6,
        changes: { Dns: { from: 1.2, to: 1.5, current: '192.0.2.250', desired: '192.0.2.53,192.0.2.54' }, Time: { from: 1.5, to: 1.8, current: 'type NT5DS (domain)', desired: 'ntp.example.test' },
          DomainJoin: { from: 1.8, to: 2.1, current: 'workgroup WORKGROUP', desired: 'iic.example.test (OU=Servers)' },
          UnusedAdapters: { from: 2.1, to: 2.4, current: 'Slot 3 Port 2 (Up)', desired: 'Disabled' }, Mpio: { from: 2.4, to: 2.8, current: 'Disabled', desired: 'Enabled' }, Drivers: { from: 2.8, to: 3.2, current: '24.1.0', desired: '24.4.1.0' } },
        verify: ['Hostname', 'ArcRegistration'], na: { ClearStorage: 'os_configuration.clear_storage is off, so no storage is wiped.' },
        retry: { at: 2.0, to: 2.2 }, versions: { hostname: 'iic-azl-n01', osVersion: '10.0.26100.1', build: 26100, sbePublisher: 'Dell', sbeFamily: '16G-45n0c-Intel', sbeVersion: '5.0.2606.1616', sbeDelivery: 'SAS download by the node (Arc Run Command)' } },
      { name: 'iic-azl-n02', ip: 12, method: 'Iso', transport: 'WinRM', declared: 'simplified', mismatch: true, start: 0.25, planAt: 1.0, verifyAt: 5.2, convergedAt: 6.2,
        changes: { Network: { from: 1.5, to: 2.6, current: 'dhcp 192.0.2.112', desired: 'static 192.0.2.12 gw 192.0.2.1', guarded: true }, Dns: { from: 2.6, to: 2.8, current: '192.0.2.250', desired: '192.0.2.53,192.0.2.54' },
          Hostname: { from: 2.8, to: 3.5, current: 'WIN-7K2Q9', desired: 'iic-azl-n02' }, DomainJoin: { from: 3.5, to: 3.8, current: 'workgroup WORKGROUP', desired: 'iic.example.test (OU=Servers)' },
          ArcRegistration: { from: 3.8, to: 4.1, current: 'not registered', desired: 'Connected in rg-iic-azl-c01' },
          ClearStorage: { from: 4.1, to: 4.4, current: '1 pool(s), 2 virtual disk(s), disks: 3 (1000 GB)', desired: 'clean' }, Sbe: { from: 4.4, to: 4.6, current: 'missing', desired: 'present, SHA-256 matches' },
          Drivers: { from: 4.6, to: 5.7, current: '24.1.0', desired: '24.4.1.0', fail: { at: 4.9, reason: 'Driver package Intel_E810.inf does not match the SBE manifest hash; the node kept its current driver.' } } },
        second: { start: 5.0, planAt: 5.2, changes: { Drivers: { from: 5.3, to: 5.7, current: '24.1.0', desired: '24.4.1.0' } }, verifyAt: 5.9, convergedAt: 6.2 },
        verify: [], na: {}, reconnect: { at: 3.1, to: 3.4 }, wipe: '3 local disks (1000 GB)',
        versions: { hostname: 'iic-azl-n02', osVersion: '10.0.26100.1', build: 26100, osCaption: 'Azure Stack HCI', sbePublisher: 'Dell', sbeFamily: '16G-45n0c-Intel', sbeVersion: '5.0.2606.1616', sbeDelivery: 'copy over WinRM' } },
      { name: 'iic-azl-n03', ip: 13, method: 'Ztp', transport: 'WinRM', declared: 'simplified', start: 0.4, planAt: 1.1, verifyAt: 6.0, convergedAt: 6.3,
        changes: { DomainJoin: { from: 3.9, to: 4.2, current: 'workgroup WORKGROUP', desired: 'iic.example.test (OU=Servers)' }, Time: { from: 4.2, to: 4.6, current: 'type NT5DS (domain)', desired: 'ntp.example.test' }, Mpio: { from: 4.6, to: 5.4, current: 'Disabled', desired: 'Enabled' }, Drivers: { from: 5.4, to: 6.0, current: '24.1.0', desired: '24.4.1.0' } },
        verify: ['Hostname', 'ArcRegistration'], na: { ClearStorage: 'os_configuration.clear_storage is off, so no storage is wiped.' },
        versions: { hostname: 'iic-azl-n03', osVersion: '10.0.26100.1', build: 26100, sbePublisher: 'Dell', sbeFamily: '16G-45n0c-Intel', sbeVersion: '5.0.2606.1616', sbeDelivery: 'copy over WinRM' } }
    ];
  }

  // One machine of state.osConfiguration at r minutes (base = ms of r 0).
  function oscDemoNode(sp, r, base, unit) {
    function at(m) { return new Date(base + m * (unit || 60000)).toISOString(); }
    var att2 = !!sp.second && r >= sp.second.start, cur = att2 ? sp.second : sp;
    var started = r >= cur.start, planned = r >= cur.planAt;
    var changeEnds = Object.keys(cur.changes || {}).map(function (k) { return cur.changes[k].to; });
    var firstChange = Math.min.apply(null, Object.keys(cur.changes || {}).map(function (k) { return cur.changes[k].from; }).concat([Infinity]));
    var anyFailed = false, anyChanging = false, awaiting = null, rolled = null;
    var steps = OSC_DEMO_STEP.map(function (st) {
      var ch = (cur.changes || {})[st], first = (sp.changes || {})[st], prior = att2 && first && !ch;
      var o = { stage: 'waiting', action: '', evidence: '', current: '', desired: '', start: null, end: null, errors: [], guarded: null };
      var verifyOnly = sp.verify.indexOf(st) >= 0, okText = OSC_DEMO_OK[st].replace('%NAME%', sp.name).replace('%IP%', String(sp.ip));
      if (!started) return { st: st, o: o, verifyOnly: verifyOnly };
      if (!planned) return { st: st, o: o, verifyOnly: verifyOnly };
      if (sp.na && sp.na[st]) { o.stage = 'skipped'; o.evidence = 'Not applicable: ' + sp.na[st]; return { st: st, o: o, verifyOnly: false }; }
      if (verifyOnly) { o.stage = 'ok'; o.action = 'Ok'; o.evidence = 'Ok: Verify only: ' + okText; return { st: st, o: o, verifyOnly: true }; }
      if (!ch) { o.stage = 'ok'; o.action = 'Ok'; o.evidence = (prior ? 'Verified: ' : 'Ok: ') + okText; if (prior) o.stage = 'verified'; return { st: st, o: o, verifyOnly: false }; }
      o.current = ch.current; o.desired = ch.desired;
      var txt = st + ': ' + ch.current + ' -> ' + ch.desired;
      if (r < ch.from) { o.stage = 'planned'; o.action = 'Change'; o.evidence = 'Change: ' + txt; }
      else if (ch.fail && r >= ch.fail.at) { o.stage = 'failed'; o.start = at(ch.from); o.end = at(ch.fail.at); o.errors = [ch.fail.reason]; o.evidence = 'Failed: ' + ch.fail.reason; anyFailed = true; }
      else if (r < ch.to) {
        o.stage = 'changing'; o.start = at(ch.from); o.evidence = 'Changing: ' + txt; anyChanging = true;
        if (ch.guarded) {
          var g = r < ch.from + 0.3 ? 'Staged' : r < ch.from + 0.6 ? 'Verifying' : 'AwaitingConfirm';
          o.guarded = { state: g, changeId: 'net-1', rung: '', repairs: 0, confirmBy: g === 'AwaitingConfirm' ? at(ch.from + 0.6 + 10) : null, confirmMinutes: 10, reason: '' };
          if (g === 'AwaitingConfirm') awaiting = o.guarded;
        }
      } else if (r < cur.verifyAt) { o.stage = 'applied'; o.start = at(ch.from); o.end = at(ch.to); o.evidence = 'Applied: ' + txt; }
      else { o.stage = 'verified'; o.start = at(ch.from); o.end = at(ch.to); o.evidence = 'Verified: ' + okText; }
      if (ch.guarded && o.stage !== 'changing' && o.stage !== 'planned' && r >= ch.to) o.guarded = { state: 'Committed', changeId: 'net-1', rung: '', repairs: 0, confirmBy: null, confirmMinutes: 10, reason: '' };
      return { st: st, o: o, verifyOnly: false };
    });
    var retrying = !!sp.retry && r >= sp.retry.at && r < sp.retry.to, reconnecting = !!sp.reconnect && r >= sp.reconnect.at && r < sp.reconnect.to;
    var converged = started && r >= cur.convergedAt;
    var state = !started ? 'waiting' : converged ? 'converged' : anyFailed ? 'failed' : retrying ? 'retrying' : reconnecting ? 'reconnecting' : awaiting ? 'awaitingconfirm'
      : anyChanging ? 'applying' : !planned ? 'planning' : r < firstChange ? 'planned' : r < cur.verifyAt ? 'verifying' : 'verifying';
    var status = { waiting: 'notstarted', planned: 'notstarted', converged: 'success', failed: 'error' }[state] || 'running';
    var tree = steps.map(function (x) {
      var o = x.o, ts = { waiting: 'notstarted', planned: 'notstarted', ok: 'success', info: 'success', changing: 'running', applied: 'success', verified: 'success', failed: 'error', skipped: 'skipped' }[o.stage];
      return {
        id: 'osc.' + x.st, name: OSC_DEMO_NAME[x.st], description: o.evidence, status: ts, rawStatus: o.stage, start: o.start, end: o.end, durationSeconds: o.start && o.end ? Math.round((Date.parse(o.end) - Date.parse(o.start)) / 1000) : null,
        errors: o.errors, children: [],
        osc: { step: x.st, stage: o.stage, action: o.action, verifyOnly: x.verifyOnly, notApplicable: o.stage === 'skipped', current: o.current, desired: o.desired, nextAction: '', level: 'Info',
          transport: sp.transport, arc: sp.transport === 'ArcRunCommand' && ['changing', 'applied', 'verified', 'failed'].indexOf(o.stage) >= 0 && !x.verifyOnly, guarded: o.guarded }
      };
    });
    var current = '';
    tree.forEach(function (t) { if (!current && t.osc.stage === 'changing') current = t.osc.step; });
    var stateText = { waiting: 'Waiting to start', planning: 'Reading the machine (plan)', planned: 'Planned: ' + Object.keys(cur.changes || {}).length + ' changes pending', applying: 'Applying changes', retrying: 'Retrying (run command lost, try 1)',
      reconnecting: 'Reconnecting after a restart or an address change', awaitingconfirm: 'Network change applied; waiting for the orchestrator’s confirmation', verifying: 'Verifying', converged: 'Converged',
      failed: 'Failed' }[state];
    var v = {}; Object.keys(sp.versions).forEach(function (k) { v[k] = sp.versions[k]; });
    v.schemaVersion = '5.3.0'; v.wrapperVersion = '1.0.0';
    var failedStep = tree.filter(function (t) { return t.osc.stage === 'failed'; })[0];
    var joinStep = tree.filter(function (t) { return t.osc.step === 'DomainJoin'; })[0];
    var domainJoined = !!joinStep && (joinStep.osc.stage === 'applied' || joinStep.osc.stage === 'verified');
    // the domain account is added to the local Administrators a moment after the join: only then does Sonar switch accounts
    var adminsConfigured = domainJoined && !!(sp.changes || {}).DomainJoin && r >= sp.changes.DomainJoin.to + 0.1;
    var gstep = tree.filter(function (t) { return t.osc.guarded; })[0];
    return {
      name: sp.name, method: started ? sp.method : sp.method, methodSource: started ? 'resolved' : 'expected', methodNote: started ? '' : 'scenario.os_install is simplified',
      declared: started ? sp.declared : '', declaredMethod: started ? 'Ztp' : '', mismatch: !!sp.mismatch && started, transport: started ? sp.transport : '',
      evidence: started ? { handoff: sp.method === 'Ztp' ? 'ready' : 'none', arc: sp.method === 'Ztp' ? 'Connected' : 'none', winrm: sp.transport === 'WinRM' ? 'answers' : 'not tried' } : { handoff: '', arc: '', winrm: '' },
      warnings: sp.mismatch && started ? ['Declared os_install \'simplified\' but there is no ready ZTP handoff and no Connected Arc machine, and the machine answers on WinRM, so the ISO path is used. Check scenario.os_install.'] : [],
      versions: started && planned ? v : { hostname: '', osVersion: '', build: '', osCaption: '', sbePublisher: v.sbePublisher, sbeFamily: v.sbeFamily, sbeVersion: v.sbeVersion, sbePackage: '', sbeDelivery: started ? v.sbeDelivery : '', schemaVersion: started ? '5.3.0' : '', wrapperVersion: started ? '1.0.0' : '' },
      status: status, state: state, stateText: stateText, currentStep: current, converged: converged,
      retries: sp.retry && r >= sp.retry.at ? 1 : 0, restarts: sp.reconnect && r >= sp.reconnect.at ? 1 : 0,
      changes: tree.filter(function (t) { return t.osc.stage === 'planned'; }).length, blocked: 0, errors: failedStep ? failedStep.errors : [], attempt: started ? (att2 ? 2 : 1) : 0,
      start: started ? at(cur.start) : null, end: converged ? at(cur.convergedAt) : null, lastEventAt: started ? at(Math.min(r, cur.convergedAt)) : null,
      domainJoined: domainJoined, domainAdminsConfigured: adminsConfigured, logAccount: adminsConfigured
        ? { kind: 'domain', userName: 'IIC\\svc-join', reason: 'domain-joined: using IIC\\svc-join', warning: '', waitingForAdmins: false }
        : domainJoined
          ? { kind: 'local', userName: 'azl-admin', reason: 'joined, waiting for domain administrators: using azl-admin', warning: '', waitingForAdmins: true }
          : { kind: 'local', userName: 'azl-admin', reason: 'workgroup: using azl-admin', warning: '', waitingForAdmins: false },
      guarded: gstep ? gstep.osc.guarded.state : '',
      guardedDetail: gstep ? Object.assign({ phase: gstep.osc.guarded.state, active: ['Committed', 'RolledBack', 'Refused'].indexOf(gstep.osc.guarded.state) < 0, reconnecting: false,
        group: 'Management', oldAddress: '192.0.2.31', newAddress: '192.0.2.21', verdict: gstep.osc.guarded.state === 'RolledBack' ? 'GatewayUnreachable' : '', startedAt: null }, gstep.osc.guarded) : null,
      address: started ? { value: sp.transport === 'WinRM' ? '192.0.2.22' : '192.0.2.21', source: sp.transport === 'WinRM' ? 'neighbor' : 'handoff', sourceLabel: sp.transport === 'WinRM' ? 'Neighbor table, by MAC' : 'ZTP handoff', forced: false, reconnected: false, at: at(0.3) } : { value: '', source: '', sourceLabel: 'not reported', forced: false, reconnected: false, at: null },
      timeline: started ? [{ at: at(0.3), state: 'TransportResolved', label: 'Transport and address resolved', group: 'node', known: true, status: 'idle', step: '', level: 'Info', seq: null,
        message: 'Reached over ' + (sp.transport || 'WinRM') + ' for every step.' }] : [],
      unknownStates: [], unknownEvents: [], waiting: null, remoting: { bootstrap: null, firewall: null, listener: null }, lastEvent: null,
      runCommands: sp.transport === 'ArcRunCommand' && started && !converged ? [{ name: 'azl-osconfig-3f9c1a7b2d4e', state: retrying ? 'Unknown' : 'Running', provisioning: 'Succeeded', since: at(Math.max(cur.start, r - 0.2)), ageMinutes: 0, stuck: false }] : [],
      tree: tree
    };
  }

  // The Discovery stage of the demo: n machines read ('discovered'), or part of them ('partial'), or none yet ('waiting').
  function demoDiscovery(names, kind, iso, M) {
    var read = kind === 'waiting' ? 0 : kind === 'partial' ? Math.max(1, names.length - 1) : names.length;
    var nodes = names.map(function (name, i) {
      var found = i < read, attention = i === 1 && found;
      var mac = function (n) { return '00-00-5E-00-53-' + ('0' + (i * 4 + n).toString(16).toUpperCase()).slice(-2); };
      var notes = attention ? ['The BOSS card has no virtual disk yet: the toolkit\u2019s Phase 02 Task 01 creates it before the OS install.'] : [];
      return {
        name: name, found: found, state: !found ? 'missing' : attention ? 'attention' : 'discovered', status: found ? 'success' : 'notstarted',
        stateText: !found ? 'Not discovered yet' : attention ? 'Discovered; 1 thing to check' : 'Discovered', serviceTag: found ? 'EXAMPLE' + (i + 1) : '', serial: found ? 'CHEXAMPLE' + (i + 1) : '',
        model: found ? 'Example R660' : '', biosVersion: found ? '2.1.0' : '', bmcMac: found ? mac(10) : '', collectedAt: iso(20 * M),
        management: found ? { name: 'Embedded Port 1', mac: mac(1), confirmed: !attention, reason: 'its MAC is already the management MAC in infrastructure.yml' } : null,
        ports: found ? [{ name: 'Embedded Port 1', slot: 'Embedded', mac: mac(1), linkUp: true, speedMbps: 10000, adapterModel: 'Example 10G' }, { name: 'Slot 3 Port 1', slot: 'Slot 3', mac: mac(2), linkUp: false, speedMbps: null, adapterModel: 'Example 25G' }] : [],
        boss: { present: found, driveCount: found ? 2 : 0, hasVirtualDisk: found && !attention, needsVirtualDisk: attention }, warnings: 0, warningTexts: [], notes: notes, errors: [],
        tree: found ? [
          { id: 'disc.identity', name: 'Identity', description: 'Service tag EXAMPLE' + (i + 1) + ', Example R660, BIOS 2.1.0', status: 'success', errors: [], children: [] },
          { id: 'disc.ports', name: 'Network ports (2)', description: '1 of 2 with link up', status: 'success', errors: [], children: [
            { id: 'disc.port.1', name: 'Embedded Port 1', description: mac(1) + ', link up, 10000 Mbps', status: 'success', errors: [], children: [] },
            { id: 'disc.port.2', name: 'Slot 3 Port 1', description: mac(2) + ', no link', status: 'success', errors: [], children: [] }] },
          { id: 'disc.management', name: 'Management port', description: 'Embedded Port 1, ' + mac(1), status: attention ? 'notstarted' : 'success', errors: [], children: [] },
          { id: 'disc.boss', name: 'BOSS card', description: attention ? '2 drives, no virtual disk yet' : '2 drives, a virtual disk exists', status: attention ? 'notstarted' : 'success', errors: [], children: [] }] : []
      };
    });
    return {
      configured: true, status: kind === 'discovered' ? 'success' : kind === 'partial' ? 'running' : 'notstarted', state: kind,
      stateText: kind === 'discovered' ? 'All ' + names.length + ' machines discovered; 1 to check before ZTP' : kind === 'partial' ? read + ' of ' + names.length + ' machines read; the discovery is still running' : 'Waiting for the discovery output',
      location: 'discovery', summaryFound: kind === 'discovered', collectedAt: iso(20 * M), ready: kind === 'discovered', nodesTotal: names.length, nodesDiscovered: read, nodesFailed: 0, problems: [], nodes: nodes
    };
  }

  function oscDemoState(r, base, count, unit) {
    var specs = oscDemoSpecs().slice(0, count || 3);
    var nodes = specs.map(function (sp) { return oscDemoNode(sp, r, base, unit); });
    function at(m) { return new Date(base + m * (unit || 60000)).toISOString(); }
    var endAt = Math.max.apply(null, specs.map(function (sp) { return sp.second ? sp.second.convergedAt : sp.convergedAt; }));
    var started = r >= 0.2, planDone = r >= 1.0, completed = r >= endAt + 0.1;
    var total = nodes.length, ok = nodes.filter(function (n) { return n.state === 'converged'; }).length;
    var failed = nodes.filter(function (n) { return n.state === 'failed'; }).length, retrying = nodes.filter(function (n) { return n.state === 'retrying'; }).length;
    var ready = ok === total;
    var wipeNodes = specs.filter(function (sp) { return sp.wipe; }).map(function (sp) {
      var n = nodes.filter(function (x) { return x.name === sp.name; })[0], st = n.tree.filter(function (t) { return t.osc.step === 'ClearStorage'; })[0].osc.stage;
      return { node: sp.name, disks: sp.wipe, done: st === 'applied' || st === 'verified' };
    });
    var warnings = [];
    nodes.forEach(function (n) { n.warnings.forEach(function (w) { warnings.push(n.name + ': ' + w); }); });
    return {
      configured: true, status: !started ? 'notstarted' : failed ? 'error' : ready ? 'success' : 'running',
      state: !started ? 'waiting' : failed ? 'failed' : ready ? 'converged' : !planDone ? 'planning' : 'applying', ready: ready,
      run: { started: started ? at(0.2) : null, completed: completed ? at(endAt + 0.1) : null, mode: 'Apply', exitCode: completed ? 0 : null, planCompleted: planDone, planChanges: 17,
        cluster: 'iic-azl-c01', schemaVersion: '5.3.0', wrapperVersion: '1.0.0', lastEventAt: at(Math.min(r, endAt)), events: 64,
        id: 'run-20261107-1', legacy: false, runsSeen: 1, staleIgnored: 0, seq: 64, timeline: [] },
      remoting: { profile: { class: 'lab', posture: 'standard', relaxed: false, scheme: 'http', trustedHosts: 'Merge', remoteAddress: ['192.0.2.0/24'], level: 'Info', message: '', at: at(0.1) }, trustedHosts: null },
      unknownStates: [],
      guarded: nodes.filter(function (n) { return n.guardedDetail; }).map(function (n) { return Object.assign({ node: n.name }, n.guardedDetail); }),
      nodesTotal: total, nodesConverged: ok, nodesFailed: failed, nodesRetrying: retrying,
      wipe: planDone ? { published: true, enabled: true, count: wipeNodes.length ? 1 : 0, pending: wipeNodes.some(function (w) { return !w.done; }), nodes: wipeNodes } : { published: false, enabled: false, count: 0, pending: false, nodes: [] },
      nodes: nodes, warnings: warnings
    };
  }

  // The event lines of the demo run up to r, as the log pane shows them: "<time> [osconfig] <node> <State> (<Step>): ...".
  function oscDemoLines(r, base, count, unit) {
    var out = [];
    function at(m) { return new Date(base + m * (unit || 60000)).toISOString(); }
    var specs = oscDemoSpecs().slice(0, count || 3);
    function add(m, node, state, step, level, text) { if (m <= r) out.push({ time: at(m), level: level, text: at(m) + ' [osconfig] ' + node + ' ' + state + (step ? ' (' + step + ')' : '') + ': ' + text }); }
    add(0.2, '*', 'RunStarted', '', 'info', 'OS configuration run started: mode Apply, cluster iic-azl-c01, ' + specs.length + ' node(s): ' + specs.map(function (x) { return x.name; }).join(', ') + '.');
    specs.forEach(function (sp) {
      var n = sp.name;
      add(sp.start, n, 'NodeStarted', '', 'info', 'Looking at ' + n + ': its handoff, its Arc machine, and whether it answers on WinRM.');
      add(sp.start + 0.1, n, 'MethodResolved', '', sp.mismatch ? 'warning' : 'info', 'Declared os_install \'simplified\'; so the ' + sp.method + ' path over ' + sp.transport + (sp.mismatch ? '. Warning: no ready ZTP handoff, the machine answers on WinRM, so the ISO path is used.' : '.'));
      add(sp.start + 0.1, n, 'TransportResolved', '', 'info', n + ' is reached over ' + sp.transport + ' for every step.');
      Object.keys(sp.changes).forEach(function (st) {
        var ch = sp.changes[st];
        var dj = st === 'DomainJoin';
        add(sp.planAt, n, dj ? 'DomainJoinPlanned' : 'StepPlanned', st, 'info', 'Change: ' + st + ': ' + ch.current + ' -> ' + ch.desired);
        add(ch.from, n, dj ? 'DomainJoinApplying' : 'StepApplying', st, 'info', 'Changing: ' + st + ': ' + ch.current + ' -> ' + ch.desired);
        if (ch.guarded) {
          add(ch.from, n, 'NetworkChangeStaged', 'Network', 'info', 'The change is staged on the node with a snapshot; the watchdog is armed.');
          add(ch.from + 0.3, n, 'NetworkChangeVerifying', 'Network', 'info', 'The node checks its own address, gateway and DNS for a stable minute.');
          add(ch.from + 0.6, n, 'NetworkChangeAwaitingConfirm', 'Network', 'warning', 'Local checks passed; waiting for the orchestrator to confirm within 10 minutes, or the node reverts. (warning)');
          add(ch.to, n, 'NetworkChangeCommitted', 'Network', 'info', 'Both proofs are in: the change is committed and the watchdog is disarmed.');
        }
        if (ch.fail) add(ch.fail.at, n, 'StepFailed', st, 'error', 'Failed: ' + ch.fail.reason);
        else add(ch.to, n, dj ? 'DomainJoined' : 'StepApplied', st, 'info', dj ? 'Joined iic.example.test and restarted.' : 'Applied: ' + st);
        if (dj) add(ch.to + 0.1, n, 'DomainAdminsConfigured', st, 'info', 'The domain account IIC\\svc-join was added to the local Administrators group.');
      });
      if (sp.retry) add(sp.retry.at, n, 'NodeRetry', '', 'warning', 'The Arc Run Command ended in state Unknown (the node\'s agent may have lost its connection). Try 1 of 3 in the Apply pass; trying again in 15 s.');
      if (sp.reconnect) { add(sp.reconnect.at, n, 'NodeReconnecting', '', 'warning', 'The node restarted (a computer name change needs one); the run waits for it.'); add(sp.reconnect.to, n, 'NodeReconnected', '', 'info', 'The node came back with a new boot time and answered again.'); }
      if (sp.second) {
        add(sp.changes.Drivers.fail.at, n, 'NodeFailed', '', 'error', sp.changes.Drivers.fail.reason);
        add(sp.second.start, n, 'NodeStarted', '', 'info', 'Looking at ' + n + ' again.');
        add(sp.second.planAt, n, 'StepPlanned', 'Drivers', 'info', 'Change: Drivers: 24.1.0 -> 24.4.1.0');
        add(sp.second.changes.Drivers.from, n, 'StepApplying', 'Drivers', 'info', 'Changing: Drivers: 24.1.0 -> 24.4.1.0');
        add(sp.second.changes.Drivers.to, n, 'StepApplied', 'Drivers', 'info', 'Applied: Drivers');
      }
      add(sp.second ? sp.second.convergedAt : sp.convergedAt, n, 'NodeConverged', '', 'info', 'The verification pass found nothing left to change.');
    });
    add(1.0, '*', 'PlanCompleted', '', 'info', 'Plan complete for 3 node(s): 17 change(s) pending, 0 blocked. Nothing was changed.');
    add(1.0, '*', 'WipeListPublished', '', 'warning', '1 node(s) have local disks that WILL BE WIPED NOW: iic-azl-n02: 3 local disks (1000 GB) (warning)');
    out.sort(function (a, b) { return Date.parse(a.time) - Date.parse(b.time); });
    return out;
  }

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
  var OSC_DEMO_SCALE = 1.12;
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
      // OS configuration runs in the minutes before Validate (its scenario is 6.4 minutes long; the recording gives it 5.7).
      var osR = Math.max(0, (T - start) / M) * OSC_DEMO_SCALE;
      return {
        cluster: final.cluster, mode: ds ? 'Deploy' : vs ? 'Validate' : null, provisioningState: ds ? 'Succeeded' : vs ? 'Accepted' : null,
        phase: phase, activePhase: phase,
        osConfiguration: oscDemoState(osR, start, 2, M / OSC_DEMO_SCALE),
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
    oscDemoLines(99, start, 2, M / OSC_DEMO_SCALE).forEach(function (l) {
      lines.push({ time: l.time, received: l.time, timeSource: 'line', file: 'os-config-events', level: l.level, text: l.text });
    });
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
      lifecyclePlain: lifecyclePlain, arcInfo: arcInfo, machineWaits: machineWaits, machineList: machineList,
      discOf: discOf, discNodes: discNodes, discHasData: discHasData, discoveryTreeOf: discoveryTreeOf, discCard: discCard, discHeadline: discHeadline,
      levelSet: levelSet, levelPasses: levelPasses, toggleLevel: toggleLevel, levelCount: levelCount, demoDiscovery: demoDiscovery, laMonitorPhases: laMonitorPhases, monitorOf: monitorOf, manualInstall: manualInstall, MODE_IDS: MODE_IDS, MODE_TITLE: MODE_TITLE,
      oscGuardedPanels: oscGuardedPanels, oscAddressChip: oscAddressChip, oscTimelineLines: oscTimelineLines, oscFacts: oscFacts,
      oscOf: oscOf, oscNodes: oscNodes, oscHasData: oscHasData, osConfigTreeOf: osConfigTreeOf, oscMethodChip: oscMethodChip, oscVersionLines: oscVersionLines,
      oscCard: oscCard, oscHeadline: oscHeadline, oscFacts: oscFacts, oscCountdown: oscCountdown, fmtCountdown: fmtCountdown,
      oscDemoState: oscDemoState, oscDemoLines: oscDemoLines,
      armOf: armOf, armHasData: armHasData, armPhaseOf: armPhaseOf, armPhaseHasData: armPhaseHasData, armTreeOf: armTreeOf, armActiveMode: armActiveMode,
      armTile: armTile, armHeadline: armHeadline, armFacts: armFacts, armOverall: armOverall, armDemoState: armDemoState, armDemoLines: armDemoLines
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
    var only = monitorOf(app.state);
    document.title = (app.replay ? 'Replay \u2013 ' : '') + (name !== 'Unknown cluster' ? name + ' \u2013 ' : '') + (only ? MODE_TITLE[only] + ' \u2013 ' : '') + 'AzL Sonar';

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
    var armO = armOverall(s);   // the toolkit's ARM run is ahead of Azure (checks before the submit, a refusal)
    if (armO) return armO;
    var osc = oscOf(s);
    if (osc && oscHasData(osc) && activeModeId(s) === 'osconfig') {
      var okey = osc.status === 'success' ? 'success' : osc.status === 'error' ? 'error' : osc.status === 'running' ? 'running' : 'unknown';
      return { key: okey, label: 'OS configuration: ' + oscHeadline(osc) };
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
    var oscRun = oscOf(s) && isObj(oscOf(s).run) ? oscOf(s).run : null;
    if (min === Infinity && oscRun && activeModeId(s) === 'osconfig' && !isNaN(parseTime(oscRun.started))) {
      min = parseTime(oscRun.started);   // OS configuration is the mode to watch: time since its run began
      if (!isNaN(parseTime(oscRun.completed))) max = parseTime(oscRun.completed); else running = true;
    }
    var armPh = armPhaseOf(s, armActiveMode(s) === 'deploy' ? 'deployment' : 'validation');
    if (min === Infinity && armPhaseHasData(armPh) && armActiveMode(s) && !isNaN(parseTime(armPh.started))) {
      min = parseTime(armPh.started);   // the toolkit's run is the mode to watch: time since its phase began
      if (!isNaN(parseTime(armPh.completed))) max = parseTime(armPh.completed); else running = armPh.status === 'running';
    }
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
    if (arr(sm.facts).length) {
      var facts = el('dl', { class: 'facts', 'aria-label': 'Run summary' });
      sm.facts.forEach(function (f) {
        facts.appendChild(el('div', null, [el('dt', { text: f.k }), el('dd', { class: f.warn ? 'warnk' : null, text: f.v })]));
      });
      host.appendChild(facts);
    }
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
        c.arc ? el('span', { class: 'ln', title: c.arc.raw ? 'Azure Arc says: ' + c.arc.raw : null }, [
          el('span', { class: 'arc arc-' + c.arc.kind, text: c.arc.text })
        ]) : null,
        c.chips ? el('span', { class: 'ln chips' }, c.chips.map(function (x) { return chipEl(x.kind, x.text, x.title); })) : null,
        c.progress !== null && c.progress !== undefined ? el('span', { class: 'bar', role: 'progressbar', 'aria-label': c.name + ' progress',
          'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': String(c.progress) }, [el('i', { style: 'width:' + c.progress + '%' })]) : null,
        c.waits ? el('span', { class: 'ln muted' }, [c.waits]) : null,
        c.until ? el('span', { class: 'ln' }, [el('span', { class: 'countdown', 'data-until': c.until, text: 'Confirmation window: ' + fmtCountdown(oscCountdown(c.until)) })]) : null
      ].concat(arr(c.lines).map(function (t) { return el('span', { class: 'ln muted' }, [t]); })));
      b.addEventListener('click', function () { selectNode(c.name); });
      cards.appendChild(b);
    });
    host.appendChild(cards);
    arr(sm.panels).forEach(function (p) {
      var box = el('section', { class: 'panel-guard guard-' + p.kind, 'aria-label': p.title });
      box.appendChild(el('h3', { class: 'sub-h', text: p.title }));
      var dl = el('dl', { class: 'facts' });
      p.rows.forEach(function (r) { dl.appendChild(el('div', null, [el('dt', { text: r.k }), el('dd', { text: r.v })])); });
      box.appendChild(dl);
      if (p.until) box.appendChild(el('p', { class: 'ln' }, [el('span', { class: 'countdown', 'data-until': p.until, text: 'Confirmation window: ' + fmtCountdown(oscCountdown(p.until)) })]));
      host.appendChild(box);
    });
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
    app.oscTree = osConfigTreeOf(s);
    app.discTree = discoveryTreeOf(s);
    app.extTree = extensionsTreeOf(s);
    var collapse = provisioningCollapse(s.activePhase || (normPhase(s.phase) === 'failed' ? '' : s.phase), app.provAutoCollapsed);
    if (collapse === 'collapse') { app.sectionCollapsed.provisioning = true; app.provAutoCollapsed = true; }
    else if (collapse === 'expand') { app.sectionCollapsed.provisioning = false; app.provAutoCollapsed = false; }
    app.stepIndex = new Map();
    indexSection('discovery');
    indexSection('provisioning');
    indexSection('osconfiguration');
    indexSection('armvalidation');
    indexSection('validation');
    indexSection('extensions');
    indexSection('armdeployment');
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
    var sec = app.state && app.state[section === 'osconfiguration' ? 'osConfiguration' : section];
    var armTree = section === 'armvalidation' ? armTreeOf(app.state, 'validation') : section === 'armdeployment' ? armTreeOf(app.state, 'deployment') : null;
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
    walk(armTree ? armTree : section === 'provisioning' ? app.provTree : section === 'osconfiguration' ? app.oscTree : section === 'discovery' ? app.discTree : section === 'extensions' ? app.extTree : (isObj(sec) ? sec.tree : null), section);
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
    if (!best && activeModeId(s) === 'osconfig') walk(app.oscTree, 0);
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
      var armWhich = section === 'armvalidation' ? 'validation' : section === 'armdeployment' ? 'deployment' : '';
      var sec = armWhich ? (armPhaseOf(s, armWhich) || {}) : section === 'provisioning' ? (isObj(s.provisioning) ? s.provisioning : {}) : section === 'osconfiguration' ? (isObj(s.osConfiguration) ? s.osConfiguration : {}) : (isObj(s[section]) ? s[section] : {});
      var tree = armWhich ? armTreeOf(s, armWhich) : section === 'provisioning' ? app.provTree : section === 'osconfiguration' ? app.oscTree : section === 'discovery' ? app.discTree : section === 'extensions' ? app.extTree : arr(sec.tree);
      var only = section === 'provisioning' || section === 'osconfiguration' || section === 'discovery' ? str(app.filter.node).toLowerCase() : '';
      if (only) tree = tree.filter(function (n) { return str(n.name).toLowerCase() === only; });
      var wrap = host.querySelector('.tree-section[data-section="' + section + '"]');
      if (!tree.length) { if (wrap) wrap.remove(); app.treeSig[section] = null; return; }
      shown++;
      var sig = JSON.stringify([tree, sec.status, app.selectedKey, app.currentKey, only, Array.from(app.expanded.entries()), section === 'validation' || section === 'deployment' ? armTreeOf(s, section).length : 0],
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
    var title = section === 'provisioning' || section === 'osconfiguration' || section === 'discovery' ? 'Machines' : section === 'extensions' ? 'Extensions (installed during Validate)' :
      section === 'armvalidation' ? 'Toolkit run: checks and validation results' : section === 'armdeployment' ? 'Toolkit run: checks and deployment progress' :
      section === 'validation' ? 'Validation' : section === 'update' ? 'Update (unverified against a live run)' : 'Deployment';
    if (section === 'extensions' || section === 'armvalidation' || section === 'armdeployment') wrap.appendChild(el('h3', { class: 'sub-h', text: title }));
    // When the toolkit's run is shown above, say that the next list is what Azure itself reports.
    if ((section === 'validation' && armTreeOf(app.state, 'validation').length) || (section === 'deployment' && armTreeOf(app.state, 'deployment').length)) {
      wrap.appendChild(el('h3', { class: 'sub-h', text: (section === 'validation' ? 'Validation' : 'Deployment') + ' steps reported by Azure' }));
    }
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
    var label = name + (rule.side === 'azure' ? ', runs in Azure' : (rule.side === 'file' ? ', read from the discovery files' : '')) + ', ' + (st === 'unknown' ? str(n.status) || 'unknown status' : STATUS_LABEL[st]) +
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
    if (isObj(n.arm) && n.arm.kind === 'step') nameEl.appendChild(el('span', { class: 'idx', text: str(n.arm.step) }));
    else if (!isObj(n.arm) && rule.side !== 'machine' && section !== 'provisioning' && section !== 'osconfiguration' && section !== 'discovery' && n.id !== undefined && n.id !== null && n.id !== '' && str(n.id) !== name) nameEl.appendChild(el('span', { class: 'idx', text: str(n.id) }));
    nameEl.appendChild(el('span', { class: 'sn', text: name }));
    if (rule.side === 'azure') nameEl.appendChild(el('span', { class: 'az', title: 'This step runs in Azure: Sonar reads its status from Azure, there are no node log lines for it.', text: 'Azure' }));
    if (isObj(n.osc) && n.osc.arc === true) nameEl.appendChild(el('span', { class: 'az', title: 'This step runs as an Azure Arc Run Command: Azure starts it on the node and Sonar can read the run command from Azure.', text: 'Azure' }));
    var desc = stepDescription(n);
    if (desc) nameEl.appendChild(el('span', { class: 'desc', text: desc }));
    row.appendChild(nameEl);
    if (isObj(n.osc) && n.osc.stage) {
      var oo = n.osc, stageWord = oo.verifyOnly && (oo.stage === 'ok' || oo.stage === 'info') ? 'Verify only: OK' : (oo.verifyOnly && oo.stage === 'blocked' ? 'Verify only: differs' : (OSC_STAGE_LABEL[oo.stage] || oo.stage));
      var oscs = el('span', { class: 'osc-stage' });
      oscs.appendChild(chipEl(OSC_STAGE_KIND[oo.stage] || 'idle', stageWord, oo.notApplicable ? 'Does not apply to this machine: ' + str(n.description) : (oo.verifyOnly ? 'ZTP did this; the run checks it and does not change it.' : '')));
      if (isObj(oo.guarded) && str(oo.guarded.state)) {
        var gd = oo.guarded, gtext = OSC_GUARDED_LABEL[str(gd.state)] || str(gd.state);
        if (str(gd.state) === 'Repaired' && str(gd.rung)) gtext += ' (rung ' + str(gd.rung) + ')';
        oscs.appendChild(chipEl(str(gd.state) === 'RolledBack' || str(gd.state) === 'Refused' ? 'err' : str(gd.state) === 'Committed' ? 'ok' : 'warn', 'Network change: ' + gtext, 'The management network change is guarded: the node reverts on its own unless the orchestrator confirms it in time.'));
        if (str(gd.state) === 'AwaitingConfirm' && str(gd.confirmBy)) {
          oscs.appendChild(el('span', { class: 'countdown', 'data-until': str(gd.confirmBy), text: fmtCountdown(oscCountdown(gd.confirmBy)) }));
        }
      }
      var descEl = nameEl.querySelector('.desc');
      nameEl.insertBefore(oscs, descEl);
    }

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
    if (isObj(n.osc) && n.osc.machine === true) li.appendChild(buildOscMeta(n));
    if (isObj(n.arm)) li.appendChild(buildArmMeta(n));
    if (isObj(n.disc) && n.disc.machine === true) li.appendChild(buildDiscMeta(n));

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

  // Under a check or a step of the toolkit's run: the result chip of a check, its next action, and for the failing step the
  // hint for the known failure. All of it is text from the feed, rendered as text.
  function buildArmMeta(n) {
    var a = n.arm, parts = [];
    if (a.kind === 'check') {
      if (a.result && a.result !== 'Passed') parts.push(chipEl(ARM_RESULT_KIND[a.result] || 'idle', a.result === 'Warning' ? 'Warning' : a.result === 'Skipped' ? 'Skipped' : 'Failed', 'The result of this check before the submit.'));
      if (a.node && a.node !== '*') parts.push(el('span', { class: 'arm-node', title: 'The machine this check ran for', text: a.node }));
      if (str(a.nextAction) && a.result !== 'Passed') parts.push(el('span', { class: 'prov-msg arm-next', text: 'Next: ' + a.nextAction }));
    }
    if (a.kind === 'step' && a.failing === true) parts.push(chipEl('err', 'Failing step', 'The step the toolkit names as the one that stopped the run.'));
    if (a.kind === 'step' && str(a.hint)) parts.push(el('span', { class: 'prov-msg arm-hint', role: 'note', text: 'Known failure: ' + a.hint }));
    if (!parts.length) return document.createDocumentFragment();
    var meta = el('div', { class: 'prov-meta arm-meta' });
    parts.forEach(function (p) { meta.appendChild(p); });
    return meta;
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

  // Under a machine row of the OS configuration mode: the method, the transport, the versions, retries and restarts, the
  // guarded network change, the Arc run commands read from Azure, and any warning.
  function buildOscMeta(n) {
    var m = n.osc, meta = el('div', { class: 'prov-meta osc-meta' });
    var chip = oscMethodChip(m);
    meta.appendChild(chipEl(chip.kind, chip.text, chip.title));
    if (m.transport) meta.appendChild(el('span', { title: 'How this machine is reached', text: OSC_TRANSPORT_LABEL[m.transport] || m.transport }));
    if (m.address) meta.appendChild(el('span', { class: 'osc-addr', title: m.address.title, text: m.address.text }));
    m.timeline.forEach(function (t) { meta.appendChild(el('span', { class: 'osc-event osc-event-' + t.kind, text: t.text })); });
    oscVersionLines({ versions: m.versions }).forEach(function (t) { meta.appendChild(el('span', { class: 'osc-ver', text: t })); });
    if (m.retries) meta.appendChild(el('span', { class: 'prov-steps', 'data-status': 'running', title: 'An Arc Run Command ended in state Unknown and was run again', text: 'Retried ' + m.retries + '×' }));
    if (m.restarts) meta.appendChild(el('span', { class: 'prov-steps', 'data-status': 'running', text: 'Restarted ' + m.restarts + '×' }));
    if (m.guarded) {
      var g = m.guardedDetail || {};
      var gt = 'Network change: ' + (OSC_GUARDED_LABEL[m.guarded] || m.guarded);
      var gspan = el('span', { class: 'prov-steps', 'data-status': m.guarded === 'RolledBack' || m.guarded === 'Refused' ? 'error' : m.guarded === 'Committed' ? 'success' : 'running', text: gt });
      meta.appendChild(gspan);
      if (m.guarded === 'AwaitingConfirm' && str(g.confirmBy)) meta.appendChild(el('span', { class: 'countdown', 'data-until': str(g.confirmBy), text: fmtCountdown(oscCountdown(g.confirmBy)) }));
      if ((m.guarded === 'RolledBack' || m.guarded === 'Refused') && str(g.reason)) meta.appendChild(el('span', { class: 'prov-msg', text: 'The node says: ' + str(g.reason) }));
    }
    m.runCommands.forEach(function (rc) {
      meta.appendChild(el('span', { class: 'prov-steps', 'data-status': rc.stuck ? 'error' : 'running', title: 'Read from Azure: Microsoft.HybridCompute/machines/runCommands (read only)',
        text: 'Run command ' + str(rc.name) + ': ' + str(rc.state) + (rc.ageMinutes !== null && rc.ageMinutes !== undefined ? ', ' + rc.ageMinutes + ' min' : '') + (rc.stuck ? ' (stuck?)' : '') }));
    });
    if (isObj(m.logAccount) && str(m.logAccount.reason)) {
      meta.appendChild(el('span', { class: 'osc-account', title: 'The account that reads this machine\u2019s logs: the local one until the machine reports DomainJoined, then the domain account. The password is never shown.',
        text: 'Log account: ' + str(m.logAccount.reason) }));
    }
    m.warnings.forEach(function (w) { meta.appendChild(el('span', { class: 'prov-msg osc-warn', text: 'Warning: ' + w })); });
    return meta;
  }

  // Under a machine row of the Discovery mode: the model, the iDRAC MAC, the management port and the BOSS card, and what to check.
  function buildDiscMeta(n) {
    var d = n.disc, meta = el('div', { class: 'prov-meta disc-meta' });
    if (d.model) meta.appendChild(el('span', { text: d.model }));
    if (d.serviceTag) meta.appendChild(el('span', { title: 'The service tag is the serial number ZTP maps the ownership voucher by.', text: 'Service tag ' + d.serviceTag }));
    if (d.bmcMac) meta.appendChild(el('span', { title: 'The iDRAC\u2019s own MAC address.', text: 'iDRAC MAC ' + d.bmcMac }));
    if (d.management) meta.appendChild(el('span', { class: 'prov-steps', 'data-status': d.management.confirmed ? 'success' : 'running', title: str(d.management.reason),
      text: 'Management port ' + str(d.management.name) + (d.management.mac ? ' ' + str(d.management.mac) : '') + (d.management.confirmed ? '' : ' (suggested)') }));
    d.notes.forEach(function (t) { meta.appendChild(el('span', { class: 'prov-msg disc-note', text: 'Check: ' + t })); });
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
    if (rule.side === 'file') { announce(name + ' is read from the discovery files; there is no node log for it.'); return; }
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

  var MODE_OF_SECTION = { discovery: 'discovery', provisioning: 'prov', osconfiguration: 'osconfig', armvalidation: 'validate', validation: 'validate', extensions: 'validate', armdeployment: 'deploy', deployment: 'deploy', update: 'update' };

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

  var MODE_GLYPH = { ok: '✓', run: '●', idle: '○', err: '✕', na: '–' };
  var MODE_WORD = { ok: 'done', run: 'running', idle: 'waiting', err: 'failed', na: 'not used' };

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
      var b = el('button', { type: 'button', class: 'mode' + (t.id === cur ? ' sel' : '') + (t.status === 'idle' || t.status === 'na' ? ' off' : ''), 'data-m': t.id,
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
    var cds = document.querySelectorAll('.countdown[data-until]');
    for (var ci = 0; ci < cds.length; ci++) {
      var left = oscCountdown(cds[ci].getAttribute('data-until'), now), pre = cds[ci].textContent.indexOf('Confirmation window: ') === 0 ? 'Confirmation window: ' : '';
      cds[ci].textContent = pre + fmtCountdown(left);
    }
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
    return { discovery: 'provisioning', prov: route === 'oem-image' ? 'arc-registration' : 'provisioning', osconfig: 'provisioning', validate: 'validation', deploy: 'deployment', update: 'update', addnode: 'add-node', repair: 'repair' }[modeId] || 'provisioning';
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

  // A standalone monitor lists only the access its own phases need (config.monitorPhases from the back end).
  function laMonitorPhases(phases, config) {
    if (!isObj(config) || !Array.isArray(config.monitorPhases) || !config.monitor || String(config.monitor).toLowerCase() === 'auto') return phases;
    return phases.filter(function (p) { return config.monitorPhases.indexOf(p) >= 0; });
  }

  // The tabs the window shows: the phases that have guidance, only the machine-readiness phase of the route Sonar follows.
  function laShownPhases() {
    var available = guidancePhases();
    var route = provRouteOf(app.state);
    var hide = route === 'simplified' ? 'arc-registration' : route === 'oem-image' ? 'provisioning' : '';
    var shown = LA_PHASES.filter(function (p) { return available.indexOf(p) >= 0 && p !== hide; });
    available.forEach(function (p) { if (shown.indexOf(p) < 0 && p !== hide) shown.push(p); });
    return laMonitorPhases(shown, app.config);
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
    var accountNodes = oscNodes(app.state).filter(function (n) { return isObj(n.logAccount) && str(n.logAccount.reason); });
    if (accountNodes.length) {
      var acctList = el('ul', { class: 'acct' });
      accountNodes.forEach(function (n) {
        var li = el('li', null, [el('strong', { text: str(n.name) + ': ' }), document.createTextNode(str(n.logAccount.reason))]);
        if (str(n.logAccount.warning)) li.appendChild(el('span', { class: 'warnk', text: ' ' + str(n.logAccount.warning) }));
        acctList.appendChild(li);
      });
      row('Account in use', acctList);
    }
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

    // The domain account that reads a node's logs once the node is joined and has the domain administrators: its circuit breaker.
    var la = isObj(d.logAccount) ? d.logAccount : null;
    if (la && str(la.account)) {
      var gA = group('Domain account');
      row(gA, 'Account', str(la.account), [srcGroup(['read from the master file; its password stays in Key Vault and is never shown'])]);
      var BREAKER_WORD = { closed: 'in use as soon as a node is ready for it', open: 'paused for every node after a rejection', latched: 'paused until its password changes or Sonar restarts', probing: 'one check in progress' };
      var rej = Number(la.failures) || 0, lim = Number(la.maxRejections) || 2;
      row(gA, 'Breaker', BREAKER_WORD[str(la.state)] || str(la.state),
        [srcGroup([rej + ' of ' + lim + ' rejections', str(la.nextProbeAt) && (str(la.state) === 'open' || str(la.state) === 'probing') ? 'next check ' + fmtClock(parseTime(la.nextProbeAt)) : null,
          str(la.lastClass) ? 'last: ' + str(la.lastClass) : null, Number(la.backoffMinutes) ? 'back-off ' + la.backoffMinutes + ' min' : null])]);
      row(gA, 'Password', str(la.credential) === 'unavailable' ? 'not available (Key Vault); asked for again' + (str(la.credentialRetryAt) ? ' at ' + fmtClock(parseTime(la.credentialRetryAt)) : '') : (str(la.credential) === 'ready' ? 'read from Key Vault' : 'not read yet'), []);
    }

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
    var oe = isObj(s.osConfigEvents) ? s.osConfigEvents : {};
    if (oe.configured) {
      row(g4, 'OS configuration events', oe.events + ' event' + (oe.events === 1 ? '' : 's'),
        [srcGroup([oe.lastEventAt ? ageEl('last ', oe.lastEventAt) : (oe.events ? null : 'none yet'), oe.fileFound ? 'file ' + oe.file : 'file ' + oe.file + ' not found yet'])]);
    } else {
      row(g4, 'OS configuration events', replay ? '' : 'no event file set', [srcGroup([replay ? '' : 'the OS configuration mode shows no steps'])]);
    }
    var ae = isObj(s.armEvents) ? s.armEvents : {};
    if (ae.configured) {
      row(g4, 'ARM run events', ae.events + ' event' + (ae.events === 1 ? '' : 's'),
        [srcGroup([ae.lastEventAt ? ageEl('last ', ae.lastEventAt) : (ae.events ? null : 'none yet'), ae.fileFound ? 'file ' + ae.file : 'file ' + ae.file + ' not found yet (no toolkit run has started)'])]);
    } else {
      row(g4, 'ARM run events', replay ? '' : 'no event file set', [srcGroup([replay ? '' : 'Validate and Deployment show only what Azure reports'])]);
    }
    var nl = isObj(s.nodeLogs) ? s.nodeLogs : {};
    // A replay shows the recorded tailer, not the idle one of the replay server.
    if (replay && isObj(app.tailer)) nl = { state: app.tailer.state, node: app.tailer.node, credential: app.tailer.credential, reason: app.tailer.reason };
    var live =str(nl.state).toLowerCase() === 'connected';
    row(g4, 'Node logs', live ? 'live from the seed node' + (nl.node ? ' (' + nl.node + ')' : '') : 'not available: Azure status only',
      [srcGroup(live ? [(nl.transport && nl.transport !== 'auto' ? 'via ' + nl.transport : ''), (nl.credential ? 'as ' + nl.credential : ''), nl.lastLineAt ? ageEl('last line ', nl.lastLineAt) : null] :
        [firstLine(nl.reason || 'the tailer has not connected yet', 90), nl.lastLineAt ? ageEl('last line ', nl.lastLineAt) : null])]);

    // OS configuration: how each machine is being configured and with which versions (from the run's events).
    var oscState = oscOf(app.state), oscMachines = oscNodes(app.state);
    if (oscState && oscHasData(oscState) && oscMachines.length) {
      var gO = group('OS configuration', true);
      var orun = isObj(oscState.run) ? oscState.run : {};
      row(gO, 'Run', (orun.mode ? orun.mode + ', ' : '') + (OSC_STATE_LABEL[oscState.state] || str(oscState.state)) + ', ' + oscState.nodesConverged + ' of ' + oscState.nodesTotal + ' converged',
        [srcGroup([orun.started ? 'started ' + fmtClock(parseTime(orun.started)) : null, orun.exitCode !== null && orun.exitCode !== undefined ? 'exit code ' + orun.exitCode : null])]);
      oscMachines.forEach(function (n) {
        var chip = oscMethodChip({ method: n.method, methodSource: n.methodSource, methodNote: n.methodNote, mismatch: n.mismatch, declared: n.declared });
        var verLines = oscVersionLines(n);
        gO.appendChild(el('dt', { class: 'mono-name', text: str(n.name), title: str(n.name) }));
        gO.appendChild(el('dd', null, [
          el('span', { class: 'val', text: chip.text + (n.transport ? ' via ' + (OSC_TRANSPORT_LABEL[n.transport] || n.transport) : '') }),
          verLines.length ? el('span', { class: 'src', text: verLines.join(' · ') }) : el('span', { class: 'src', text: 'no versions reported yet' }),
          isObj(n.logAccount) && str(n.logAccount.reason) ? el('span', { class: 'src', text: 'log access: ' + str(n.logAccount.reason) }) : null
        ]));
      });
    }

    // The toolkit's ARM Validate and Deploy run: what it is doing, the template, and the known failure it matched.
    var armState = armOf(app.state);
    if (armHasData(armState)) {
      var gA2 = group('ARM Validate and Deploy', true);
      var arun = isObj(armState.run) ? armState.run : {};
      row(gA2, 'Run', (ARM_MODE_WORD[str(arun.mode)] || str(arun.mode) || 'run') + ', ' + (ARM_STATE_LABEL[str(armState.state)] || str(armState.state)).toLowerCase(),
        [srcGroup([arun.started ? 'started ' + fmtClock(parseTime(arun.started)) : null, arun.exitCode !== null && arun.exitCode !== undefined ? 'exit code ' + arun.exitCode : null,
          str(arun.runId) ? 'run ' + str(arun.runId) : null])]);
      if (str(arun.template)) row(gA2, 'Template', str(arun.template), [srcGroup([str(arun.parameterHash) ? 'parameters ' + str(arun.parameterHash) : null, str(arun.schemaVersion) ? 'schema ' + str(arun.schemaVersion) : null])]);
      [['validation', 'Validate'], ['deployment', 'Deploy']].forEach(function (x) {
        var ph = armPhaseOf(app.state, x[0]);
        if (!armPhaseHasData(ph)) return;
        var cc = isObj(ph.checkCounts) ? ph.checkCounts : {}, sc = isObj(ph.stepCounts) ? ph.stepCounts : {}, el0 = Number(ph.elapsedSeconds);
        row(gA2, x[1], str(ph.text), [srcGroup([Number(cc.total) ? cc.total + ' checks, ' + (cc.failed || 0) + ' failed' : null, Number(sc.total) ? sc.total + ' steps' : null,
          ph.elapsedSeconds !== null && ph.elapsedSeconds !== undefined && !isNaN(el0) ? fmtDuration(el0) || '0s' : null, str(ph.deploymentName) ? 'ARM deployment ' + str(ph.deploymentName) : null])]);
      });
      arr(armState.hints).filter(isObj).forEach(function (h) {
        row(gA2, h.preventive === true ? 'Heads-up' : 'Known failure', str(h.title), [srcGroup([str(h.id), h.phase ? str(h.phase) : null])]);
      });
    }

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
      logAccount: oscOf(state) ? { account: 'IIC\\svc-join', state: 'closed', failures: 0, maxRejections: 2, backoffMinutes: 0, nextProbeAt: null, lastClass: '', credential: 'ready', credentialRetryAt: null } : null,
      sources: {
        azure: { pollSeconds: Number(cfg.pollSeconds) || 20, lastAnswerAt: str(state.polledAt) || iso(12000), ok: true, message: '' },
        ztpEvents: { configured: simplified, file: 'ztp-events.jsonl', fileFound: true, events: 212, lastEventAt: iso(4000) },
        osConfigEvents: { configured: !!oscOf(state), file: 'os-configuration-events.jsonl', fileFound: true, events: 118, lastEventAt: iso(3000) },
        armEvents: { configured: !!armOf(state) && armHasData(armOf(state)), file: 'arm-deployment-events.jsonl', fileFound: true, events: armOf(state) && armOf(state).run ? Number(armOf(state).run.events) || 0 : 0, lastEventAt: iso(3000) },
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
      var n = levelCount(app.counts, lv);
      var base = { all: 'All', info: 'Info', warning: 'Warnings', error: 'Errors' }[lv] || lv;
      b.textContent = base + ' ' + n.toLocaleString();
      b.setAttribute('aria-label', base + ', ' + n + ' lines');
    });
    pressLevelButtons();
  }

  // Lines of one level in the counts { all, warning, error }: info is what is neither.
  function levelCount(counts, level) {
    if (level === 'all') return counts.all;
    if (level === 'info') return Math.max(0, counts.all - counts.warning - counts.error);
    return counts[level] || 0;
  }

  // Which level buttons are pressed: All when there is no level filter, else exactly the levels that are on.
  function pressLevelButtons() {
    var lf = $('level-filter'), on = levelSet(app.filter.level);
    Array.prototype.forEach.call(lf.querySelectorAll('button'), function (x) {
      var lv = x.getAttribute('data-level');
      x.setAttribute('aria-pressed', String(lv === 'all' ? !on.length : on.indexOf(lv) >= 0));
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

  // The level filter: 'all' (no filter) or the levels shown, 'info', 'warning', 'error', or several joined with commas in that
  // order ('warning,error'). A level shows only its own lines: Warnings never include errors and Errors never include warnings.
  // levelOrder() is a function, not a var: the test export near the top returns before a var here would be assigned.
  function levelOrder() { return ['info', 'warning', 'error']; }
  function levelSet(level) {
    var k = str(level).toLowerCase();
    if (!k || k === 'all') return [];
    return levelOrder().filter(function (x) { return k.split(',').indexOf(x) >= 0; });
  }
  function levelPasses(level, lineLevel) {
    var s = levelSet(level);
    if (!s.length) return true;
    var l = str(lineLevel).toLowerCase();
    return s.indexOf(l === 'warning' || l === 'error' ? l : 'info') >= 0;
  }
  // The filter after a click on a level button: All clears the selection; a level is switched on or off; none, or all three,
  // is All again.
  function toggleLevel(level, clicked) {
    if (clicked === 'all') return 'all';
    var s = levelSet(level), i = s.indexOf(clicked);
    if (i >= 0) s.splice(i, 1); else s.push(clicked);
    s = levelOrder().filter(function (x) { return s.indexOf(x) >= 0; });
    return !s.length || s.length === levelOrder().length ? 'all' : s.join(',');
  }

  function lineMatches(l, win) {
    var f = app.filter;
    if (!levelPasses(f.level, l.level)) return false;
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
      app.filter.level = toggleLevel(app.filter.level, b.getAttribute('data-level'));
      pressLevelButtons();
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

  // ?demo=1&route=osconfig: an OS configuration run of three machines (example names): iic-azl-n01 is ZTP and has converged
  // after one retry of a lost Arc Run Command; iic-azl-n02 is an ISO install whose OEM drivers step failed (its network
  // change was committed and it restarted for its computer name); iic-azl-n03 is ZTP and still applying. The run moves on
  // while the page is open (planned, applying, converged). Sample data only; no API calls.
  function startOsConfigDemo(iso, M, manual) {
    var NAMES = ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'], now = Date.now(), r = 4.95, base = now - r * M;
    function provMachine(name, i) {
      return { name: name, route: 'simplified', lifecycle: 'Provisioned', lifecycleMessage: 'Machine has been successfully provisioned.', status: 'success', percent: 100, reportedPercent: 100,
        arcMachineName: '00000000-0000-0000-0000-00000000000' + (i + 1) + '-1', arcSource: 'edgeMachine.job', arcStatus: 'Connected', extensions: [], start: iso(150 * M), end: iso(40 * M), errors: [],
        ztp: { complete: true, device: { status: 'success' }, network: { status: 'success' }, restore: { status: 'success' } }, tree: [] };
    }
    var provNodes = manual ? [] : NAMES.map(provMachine);
    // A manual install: every machine was installed from an ISO, so the toolkit resolves them as ISO machines over WinRM.
    function oscState() {
      var o = oscDemoState(r, base, 3);
      if (manual) o.nodes.forEach(function (n) {
        n.method = 'Iso'; n.methodSource = n.methodSource === 'resolved' ? 'resolved' : 'expected'; n.methodNote = 'scenario.os_install is iso'; n.declared = 'iso'; n.declaredMethod = 'Iso'; n.mismatch = false; n.warnings = [];
        n.transport = n.transport ? 'WinRM' : ''; if (n.address && n.address.value) { n.address.source = 'file'; n.address.sourceLabel = 'Infrastructure file'; }
      });
      return o;
    }
    var state = {
      cluster: 'iic-azl-c01', mode: null, provisioningState: null, phase: 'provisioning', activePhase: 'provisioning', monitor: 'Auto',
      provisioning: manual
        ? { manualInstall: true, route: 'oem-image', routeSource: 'config', phase: 'provisioning', status: 'notstarted', readyForValidate: false, ztpComplete: false, nextStep: null, nodes: [] }
        : { manualInstall: false, route: 'simplified', routeSource: 'config', phase: 'provisioning', status: 'success', readyForValidate: false, ztpComplete: true, nextStep: null, nodes: provNodes },
      discovery: demoDiscovery(NAMES, 'discovered', iso, M),
      osConfiguration: oscState(),
      extensions: { shown: false, status: 'notstarted', nodes: [] },
      validation: { status: 'notstarted', tree: [], counts: {} }, deployment: { status: 'notstarted', tree: [], counts: {} },
      nodes: NAMES.map(function (name, i) { return { name: name, arcStatus: 'Connected', arcMachineName: '00000000-0000-0000-0000-00000000000' + (i + 1) + '-1', arcSource: 'edgeMachine.job', lastStatusChange: iso(30 * M) }; }),
      current: { phase: 'provisioning', stepPath: [], stepName: null }, warnings: [], polledAt: iso(4000)
    };
    // The page opens on OS configuration here (the demo shows that mode); a click on Discovery shows the stage before ZTP.
    state.discovery.nodes.forEach(function (n) { n.found = true; });
    applyConfig({ cluster: 'iic-azl-c01', resourceGroup: 'rg-iic-azl-c01', identityModel: 'ActiveDirectory', pollSeconds: 20, provisioningRoute: manual ? 'oem-image' : 'simplified',
      nodes: NAMES.map(function (n, i) { return { name: n, seed: i === 0 }; }), logPaths: ['C:\\Windows\\System32\\Bootstrap\\Logs'] });
    app.guidance = demoGuidance();
    applyState(state);
    applyTailer({ state: 'connected', reason: '', node: NAMES[0], credential: 'supplied' });
    applyFiles([{ path: 'C:\\Windows\\System32\\Bootstrap\\Logs\\setup.log' }]);
    var seq = 0, shown = 0;
    function feed() {
      var lines = oscDemoLines(r, base, 3);
      var fresh = lines.slice(shown);
      shown = lines.length;
      if (fresh.length) applyLogBatch(fresh.map(function (l) { return { seq: ++seq, time: l.time, received: l.time, timeSource: 'line', file: 'os-config-events', level: l.level, text: l.text }; }), { source: 'live' });
    }
    feed();
    setInterval(function () {
      if (r < 6.6) r = Math.round((r + 0.15) * 100) / 100;
      state.osConfiguration = oscState();
      state.polledAt = new Date().toISOString();
      applyState(state);
      feed();
    }, 15000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }

  // The toolkit's ARM Validate and Deploy run as the page receives it (state.arm), r minutes after the run began (base = ms of
  // r 0). Sample data only (example names): 18 checks (the Arc machine of iic-azl-n02 is named after its device ID: a
  // warning), Validate passes at r 2.6, Deploy starts at r 2.9 and fails at step 0.41 (the device-ID Arc name problem) at r 4.9.
  function armDemoState(r, base) {
    var M = 60000;
    function at(m) { return new Date(base + m * M).toISOString(); }
    function phaseBase(name, label) {
      return { name: name, label: label, status: 'notstarted', kind: 'notstarted', text: 'Not started', started: null, completed: null, elapsedSeconds: null, deploymentName: '', submitted: null,
        attached: false, skipped: false, resumed: null, carriedOver: false, runId: 'a1b2c3d4e5f6', checkCounts: { total: 0, failed: 0, warning: 0, skipped: 0, passed: 0 },
        stepCounts: { total: 0, success: 0, running: 0, error: 0, skipped: 0, unknown: 0 }, current: null, failing: null, knownIssue: '', hint: null, hintSource: '',
        preventiveHint: null, refused: null, message: '', nextAction: '', pollErrors: 0, pollError: '', tree: [] };
    }
    var v = phaseBase('validation', 'Validate'), d = phaseBase('deployment', 'Deploy');
    var arm = { configured: true, hasData: r >= 0.3, status: 'notstarted', state: 'waiting', activePhase: '', awaitingApproval: false,
      run: { runId: 'a1b2c3d4e5f6', mode: 'ValidateAndDeploy', cluster: 'iic-azl-c01', started: at(0.3), completed: null, exitCode: null, state: '', finalState: '', template: 'create-cluster',
        parameterHash: 'afe7afd61584', schemaVersion: '5.6.0', lastEventAt: at(Math.min(r, 4.9)), events: 0, message: '', nextAction: '', failed: false, planned: false, offline: false, approval: null },
      validation: v, deployment: d, hints: [], warnings: [] };
    if (r < 0.3) return arm;

    // checks: arrive one every 0.03 minutes from r 0.3
    function checkItem(c, i, phase) {
      var warnNaming = c[0] === 'ArcMachineNaming' && c[1] === 'iic-azl-n02';
      var result = warnNaming ? 'Warning' : 'Passed';
      var label = c[0] + (c[1] !== '*' ? ' (' + c[1] + ')' : '');
      var evidence = warnNaming ? 'Arc machine 00000000-0000-0000-0000-000000000002-1 is named after the device ID, not after the host name iic-azl-n02. On build 2690 the Deploy stops at step 0.41.' :
        c[0] === 'OsBuildConsistent' ? 'Every node runs OS build 10.0.26100.32230.' : c[0] + ' is fine.';
      return { id: 'check:' + c[0] + '|' + c[1], name: label, description: evidence, status: 'success', rawStatus: result, start: null, end: null, durationSeconds: null, errors: [], children: [],
        arm: { kind: 'check', result: result, node: c[1], check: c[0], nextAction: warnNaming ? 'Register the node with Azure Arc under its host name before the Deploy (known issue arc-device-id-name).' : '', hint: '' } };
    }
    var shown = ARM_DEMO_CHECKS.filter(function (c, i) { return r >= 0.3 + i * 0.03; });
    var kids = shown.map(checkItem).sort(function (a, b) { return (a.arm.result === 'Warning' ? 0 : 1) - (b.arm.result === 'Warning' ? 0 : 1); });
    var warns = kids.filter(function (k) { return k.arm.result === 'Warning'; }).length;
    function checksGroup(phase, label) {
      return { id: phase + '.checks', name: 'Checks before ' + label, description: (kids.length - warns) + ' passed' + (warns ? ', ' + warns + ' with a warning' : ''), status: 'success', rawStatus: '',
        start: null, end: null, durationSeconds: null, errors: [], children: kids, arm: { kind: 'group', group: 'checks', hint: '' } };
    }
    var counts = { total: kids.length, failed: 0, warning: warns, skipped: 0, passed: kids.length - warns };
    v.checkCounts = counts;
    if (kids.length) v.tree.push(checksGroup('validation', 'Validate'));
    v.status = 'checking'; v.kind = 'running'; v.text = 'Checking before Validate';
    if (warns) v.preventiveHint = { id: 'arc-device-id-name', title: 'The Arc machines are named after the device ID', text: 'Simplified provisioning names the Arc machine <device-id>-1; on build 2690 the Deploy stops at step 0.41.', phase: 'Deploy', nodes: ['iic-azl-n02'] };
    arm.state = 'checking'; arm.status = 'running'; arm.activePhase = 'validation';

    // validation steps
    function steps(list, t0, per, depthOf) {
      return list.map(function (x, i) {
        var s = t0 + i * per, e = s + per * 0.9;
        if (r < s) return null;
        var running = r < e;
        return { id: x[0], name: x[1], description: '', status: running ? 'running' : 'success', rawStatus: running ? 'InProgress' : 'Success', start: at(s), end: running ? null : at(e),
          durationSeconds: Math.round(((running ? r : e) - s) * 60), errors: [], children: [], arm: { kind: 'step', step: x[0], depth: depthOf ? depthOf(x) : 0, failing: false, hint: '' } };
      }).filter(Boolean);
    }
    if (r >= 1.0) {
      var vs = steps(ARM_DEMO_VSTEPS, 1.0, 0.2);
      var vdone = r >= 2.6;
      v.status = vdone ? 'passed' : 'running'; v.kind = vdone ? 'success' : 'running'; v.text = vdone ? 'Validation passed' : 'Validating';
      v.started = at(1.0); v.completed = vdone ? at(2.6) : null; v.elapsedSeconds = Math.round(((vdone ? 2.6 : r) - 1.0) * 60); v.deploymentName = 'azl-validate-afe7afd61584'; v.submitted = at(1.0);
      v.stepCounts = { total: vs.length, success: vs.filter(function (x) { return x.status === 'success'; }).length, running: vs.filter(function (x) { return x.status === 'running'; }).length, error: 0, skipped: 0, unknown: 0 };
      v.current = vs.filter(function (x) { return x.status === 'running'; }).map(function (x) { return { step: x.id, name: x.name }; })[0] || null;
      v.tree.push({ id: 'validation.steps', name: 'Validation results', description: vs.length + ' reported, failures first', status: vdone ? 'success' : 'running', rawStatus: '', start: null, end: null, durationSeconds: null, errors: [], children: vs, arm: { kind: 'group', group: 'steps', hint: '' } });
      v.message = vdone ? 'Validation succeeded.' : '';
      arm.state = vdone ? 'validated' : 'validating'; arm.status = vdone ? 'success' : 'running';
      v.azure = vs;
    }

    // deployment
    if (r >= 2.8) {
      var dk = kids.slice();
      d.checkCounts = counts;
      var dchecks = { id: 'deployment.checks', name: 'Checks before Deploy', description: (kids.length - warns) + ' passed' + (warns ? ', ' + warns + ' with a warning' : ''), status: 'success', rawStatus: '', start: null, end: null, durationSeconds: null,
        errors: [], children: dk, arm: { kind: 'group', group: 'checks', hint: '' } };
      d.tree.push(dchecks);
      d.status = 'running'; d.kind = 'running'; d.text = 'Deploying'; arm.state = 'deploying'; arm.status = 'running'; arm.activePhase = 'deployment';
      arm.run.approval = { mode: 'none', requested: true, granted: true };
      if (warns) d.preventiveHint = v.preventiveHint;
    }
    if (r >= 2.9) {
      var t0 = 2.9, specs = [['0.30', 'Configure networking', 0.4], ['0.31', 'Install the roles', 0.4], ['0.38', 'Create the cluster', 0.4], ['0.40', 'Configure Storage Spaces Direct', 0.4]];
      var dsteps = [], t = t0;
      specs.forEach(function (x) {
        var s = t, e = t + x[2]; t = e;
        if (r < s) return;
        var running = r < e;
        dsteps.push({ id: x[0], name: x[1], description: '', status: running ? 'running' : 'success', rawStatus: running ? 'InProgress' : 'Success', start: at(s), end: running ? null : at(e), durationSeconds: Math.round(((running ? r : e) - s) * 60), errors: [], children: [], arm: { kind: 'step', step: x[0], depth: 0, failing: false, hint: '' } });
      });
      var failed = r >= 4.9;
      if (r >= t) {
        var kid1 = { id: '0.41.1', name: 'Download the Arc resource bridge image', description: '', status: 'success', rawStatus: 'Success', start: at(t), end: at(t + 0.15), durationSeconds: 9, errors: [], children: [], arm: { kind: 'step', step: '0.41.1', depth: 1, failing: false, hint: '' } };
        var hintText = 'Simplified provisioning names each Arc machine <device-id>-1, and on build 2690 the Arc infrastructure step looks it up by the host name (ParentResourceNotFound). Validate passes, Deploy fails at step 0.41. Resubmitting does not fix it.';
        var hintTitle = 'The Arc machines are named after the device ID';
        var kid2 = { id: '0.41.2', name: 'DeployVmoArcExtension', description: '', status: failed ? 'error' : 'running', rawStatus: failed ? 'Error' : 'InProgress', start: at(t + 0.15), end: failed ? at(4.9) : null, durationSeconds: Math.round(((failed ? 4.9 : r) - t - 0.15) * 60),
          errors: failed ? ['ParentResourceNotFound: The Resource Microsoft.HybridCompute/machines/iic-azl-n02 was not found'] : [], children: [], arm: { kind: 'step', step: '0.41.2', depth: 1, failing: failed, hint: failed ? hintTitle + ': ' + hintText : '' } };
        dsteps.push({ id: '0.41', name: 'Deploy Arc infrastructure components', description: '', status: failed ? 'error' : 'running', rawStatus: failed ? 'Error' : 'InProgress', start: at(t), end: failed ? at(4.9) : null,
          durationSeconds: Math.round(((failed ? 4.9 : r) - t) * 60), errors: failed ? ['ParentResourceNotFound: parent resource machines/iic-azl-n02 was not found'] : [], children: [kid1].concat(r >= t + 0.15 ? [kid2] : []), arm: { kind: 'step', step: '0.41', depth: 0, failing: false, hint: '' } });
        if (failed) {
          d.status = 'failed'; d.kind = 'error'; d.text = 'Deployment failed at step 0.41.2 DeployVmoArcExtension'; arm.state = 'failed'; arm.status = 'error';
          d.knownIssue = 'arc-device-id-name'; d.hintSource = 'event'; d.failing = { step: '0.41.2', name: 'DeployVmoArcExtension', message: 'Deployment failed at step 0.41.2 \'DeployVmoArcExtension\': ParentResourceNotFound: machines/iic-azl-n02 was not found' };
          d.hint = { id: 'arc-device-id-name', title: 'The Arc machines are named after the device ID', text: hintText, phase: 'Deploy' };
          d.message = d.failing.message; d.nextAction = 'Known issue arc-device-id-name: Do not run Validate again for this instance (license sync).';
          arm.hints = [{ id: 'arc-device-id-name', title: d.hint.title, text: hintText, phase: 'deployment', preventive: false, step: '0.41.2' }];
          arm.run.completed = at(4.9); arm.run.exitCode = 1; arm.run.state = 'DeploymentFailed'; arm.run.nextAction = d.nextAction;
          d.completed = at(4.9);
        }
      }
      var cur = dsteps.filter(function (x) { return x.status === 'running'; }).map(function (x) { return { step: x.id, name: x.name }; });
      d.started = at(t0); d.submitted = at(t0); d.deploymentName = 'azl-deploy-afe7afd61584'; d.elapsedSeconds = Math.round(((failed ? 4.9 : r) - t0) * 60);
      d.stepCounts = { total: 0, success: 0, running: 0, error: 0, skipped: 0, unknown: 0 };
      (function count(list) { list.forEach(function (x) { d.stepCounts.total++; d.stepCounts[x.status === 'error' ? 'error' : x.status === 'running' ? 'running' : 'success']++; count(x.children); }); })(dsteps);
      d.current = cur.length ? cur[cur.length - 1] : null;
      d.tree.push({ id: 'deployment.steps', name: 'Deployment steps', description: d.stepCounts.total + ' reported, in order', status: failed ? 'error' : 'running', rawStatus: '', start: null, end: null, durationSeconds: null, errors: [], children: dsteps, arm: { kind: 'group', group: 'steps', hint: '' } });
      d.azure = dsteps;
    }
    arm.run.events = 12 + kids.length + (v.stepCounts.total * 2) + (d.stepCounts.total * 2);
    return arm;
  }

  // The event lines of the ARM demo up to r, as the log pane shows them.
  function armDemoLines(r, base) {
    var out = [];
    function at(m) { return new Date(base + m * 60000).toISOString(); }
    function add(m, node, state, step, level, text) { if (m <= r) out.push({ time: at(m), level: level, text: at(m) + ' [arm] ' + node + ' ' + state + (step ? ' (' + step + ')' : '') + ': ' + text }); }
    add(0.3, '*', 'RunStarted', '', 'info', 'ARM deployment run: mode ValidateAndDeploy, 3 node(s).');
    add(0.31, '*', 'ParametersGenerated', '', 'info', '54 parameters for template create-cluster; hash afe7afd61584.');
    ARM_DEMO_CHECKS.forEach(function (c, i) {
      var warn = c[0] === 'ArcMachineNaming' && c[1] === 'iic-azl-n02';
      add(0.3 + i * 0.03, c[1], 'PreconditionChecked', c[0], warn ? 'warning' : 'info', warn ? 'Arc machine 00000000-0000-0000-0000-000000000002-1 is named after the device ID, not after the host name iic-azl-n02. (warning)' : c[0] + ' is fine.');
    });
    add(1.0, '*', 'ValidationSubmitted', '', 'info', 'Submitted Validate as deployment azl-validate-afe7afd61584.');
    ARM_DEMO_VSTEPS.forEach(function (x, i) { add(1.0 + i * 0.2, '*', 'ValidationStep', x[0], 'info', x[1] + ': InProgress'); add(1.0 + i * 0.2 + 0.18, '*', 'ValidationStep', x[0], 'info', x[1] + ': Success'); });
    add(2.6, '*', 'ValidationPassed', '', 'info', 'Validation succeeded.');
    add(2.7, '*', 'ApprovalGranted', '', 'info', 'Approved.');
    add(2.9, '*', 'DeploymentSubmitted', '', 'info', 'Submitted Deploy as deployment azl-deploy-afe7afd61584.');
    [['0.30', 'Configure networking', 2.9], ['0.31', 'Install the roles', 3.3], ['0.38', 'Create the cluster', 3.7], ['0.40', 'Configure Storage Spaces Direct', 4.1]].forEach(function (x) {
      add(x[2], '*', 'DeploymentStep', x[0], 'info', x[1] + ': InProgress'); add(x[2] + 0.38, '*', 'DeploymentStep', x[0], 'info', x[1] + ': Success');
    });
    add(4.5, '*', 'DeploymentStep', '0.41', 'info', 'Deploy Arc infrastructure components: InProgress');
    add(4.9, '*', 'DeploymentStep', '0.41', 'error', 'Deploy Arc infrastructure components: Error - ParentResourceNotFound: parent resource machines/iic-azl-n02 was not found (error)');
    add(4.9, '*', 'DeploymentFailed', '0.41.2', 'error', 'Deployment failed at step 0.41.2 \'DeployVmoArcExtension\': ParentResourceNotFound: machines/iic-azl-n02 was not found -> next: Known issue arc-device-id-name: Do not run Validate again for this instance (license sync). (error)');
    add(4.9, '*', 'RunCompleted', '', 'error', 'Run finished in state DeploymentFailed, exit code 1. (error)');
    return out;
  }

  // ?demo=1&route=arm: the toolkit's ARM Validate and Deploy run for three machines (example names): checks, Validate, Deploy and
  // the step 0.41 failure (the device-ID Arc name problem). The run moves on while the page is open. Sample data only; no API calls.
  function startArmDemo(iso, M) {
    var NAMES = ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'], now = Date.now(), r = 0.2, base = now - r * M;
    function provMachine(name, i) {
      return { name: name, route: 'simplified', lifecycle: 'Provisioned', lifecycleMessage: 'Machine has been successfully provisioned.', status: 'success', percent: 100, reportedPercent: 100,
        arcMachineName: '00000000-0000-0000-0000-00000000000' + (i + 1) + '-1', arcSource: 'edgeMachine.job', arcStatus: 'Connected', extensions: [], start: iso(150 * M), end: iso(40 * M), errors: [],
        ztp: { complete: true, device: { status: 'success' }, network: { status: 'success' }, restore: { status: 'success' } }, tree: [] };
    }
    var provNodes = NAMES.map(provMachine);
    var state = {
      cluster: 'iic-azl-c01', mode: null, provisioningState: null, phase: 'provisioning', activePhase: 'provisioning',
      provisioning: { route: 'simplified', routeSource: 'config', phase: 'provisioning', status: 'success', readyForValidate: false, ztpComplete: true, nextStep: null, nodes: provNodes },
      osConfiguration: oscDemoState(6.9, now - 20 * M, 3),
      arm: armDemoState(r, base),
      extensions: { shown: false, status: 'notstarted', nodes: [] },
      validation: { status: 'notstarted', tree: [], counts: {} }, deployment: { status: 'notstarted', tree: [], counts: {} },
      nodes: provNodes.map(function (n) { return { name: n.name, arcStatus: n.arcStatus, arcMachineName: n.arcMachineName, arcSource: n.arcSource, lastStatusChange: iso(30 * M) }; }),
      current: { phase: 'provisioning', stepPath: [], stepName: null }, warnings: [], polledAt: iso(4000)
    };
    // Azure's own trees follow the same steps once they exist (Azure reports them as it runs them).
    function azureOf(list) {
      return list.map(function (x) { return { id: x.id, name: x.name, description: '', status: x.status, rawStatus: x.rawStatus, start: x.start, end: x.end, durationSeconds: x.durationSeconds, errors: x.errors, children: azureOf(x.children) }; });
    }
    function sync() {
      var a = armDemoState(r, base);
      state.arm = a;
      var vt = a.validation.azure || [], dt = a.deployment.azure || [];
      state.validation = { status: vt.length ? (a.validation.status === 'passed' ? 'Success' : 'InProgress') : 'notstarted', tree: azureOf(vt), counts: {} };
      state.deployment = { status: dt.length ? (a.deployment.status === 'failed' ? 'Failed' : 'InProgress') : 'notstarted', tree: azureOf(dt), counts: {} };
      state.phase = dt.length ? (a.deployment.status === 'failed' ? 'failed' : 'deployment') : vt.length ? 'validation' : 'provisioning';
      state.activePhase = dt.length ? 'deployment' : vt.length ? 'validation' : 'provisioning';
      state.mode = dt.length ? 'Deploy' : vt.length ? 'Validate' : null;
      state.current = { phase: state.activePhase, stepPath: [], stepName: null };
      state.polledAt = new Date().toISOString();
    }
    sync();
    applyConfig({ cluster: 'iic-azl-c01', resourceGroup: 'rg-iic-azl-c01', identityModel: 'ActiveDirectory', pollSeconds: 20, provisioningRoute: 'simplified',
      nodes: NAMES.map(function (n, i) { return { name: n, seed: i === 0 }; }), logPaths: ['C:\\CloudDeployment\\Logs'] });
    app.guidance = demoGuidance();
    applyState(state);
    applyTailer({ state: 'connected', reason: '', node: NAMES[0], credential: 'supplied' });
    applyFiles([{ path: 'C:\\CloudDeployment\\Logs\\setup.log' }]);
    var seq = 0, shown = 0;
    function feed() {
      var lines = armDemoLines(r, base);
      var fresh = lines.slice(shown);
      shown = lines.length;
      if (fresh.length) applyLogBatch(fresh.map(function (l) { return { seq: ++seq, time: l.time, received: l.time, timeSource: 'line', file: 'arm-events', level: l.level, text: l.text }; }), { source: 'live' });
    }
    feed();
    setInterval(function () {
      if (r < 5.4) r = Math.round((r + 0.15) * 100) / 100;
      sync();
      applyState(state);
      feed();
    }, 15000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }
  // Demo of the Discovery stage alone (?demo=1&route=discovery): the machines appear one by one, the summary comes last.
  function startDiscoveryDemo(iso, M) {
    var NAMES = ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'], kinds = ['waiting', 'partial', 'discovered'], i = 0;
    function build() {
      var d = demoDiscovery(NAMES, kinds[i], iso, M);
      return { cluster: 'iic-azl-c01', mode: null, provisioningState: null, phase: 'provisioning', activePhase: 'provisioning', monitor: 'Auto',
        provisioning: { manualInstall: false, route: 'simplified', routeSource: 'config', phase: 'provisioning', status: 'notstarted', readyForValidate: false, ztpComplete: false, nextStep: null, nodes: [] },
        discovery: d, osConfiguration: { configured: false, status: 'notstarted', state: 'waiting', ready: false, run: {}, nodesTotal: 0, nodes: [], warnings: [] },
        extensions: { shown: false, status: 'notstarted', nodes: [] }, validation: { status: 'notstarted', tree: [], counts: {} }, deployment: { status: 'notstarted', tree: [], counts: {} },
        nodes: [], current: { phase: 'provisioning', stepPath: [], stepName: null }, warnings: [], polledAt: new Date().toISOString() };
    }
    applyConfig({ cluster: 'iic-azl-c01', resourceGroup: 'rg-iic-azl-c01', identityModel: 'ActiveDirectory', pollSeconds: 20, provisioningRoute: 'simplified',
      nodes: NAMES.map(function (n, k) { return { name: n, seed: k === 0 }; }), logPaths: [] });
    app.guidance = demoGuidance();
    applyState(build());
    setInterval(function () { if (i < kinds.length - 1) i++; applyState(build()); }, 15000);
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
    if (route === 'osconfig') { startOsConfigDemo(iso, M); return; }
    if (route === 'arm') { startArmDemo(iso, M); return; }
    if (route === 'iso') { startOsConfigDemo(iso, M, true); return; }
    if (route === 'discovery') { startDiscoveryDemo(iso, M); return; }
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
