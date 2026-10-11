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
  var PHASES = ['provisioning', 'arc-registration', 'validation', 'deployment', 'done', 'failed'];
  var PHASE_LABEL = {
    provisioning: 'Provisioning', 'arc-registration': 'Arc registration', validation: 'Validation',
    deployment: 'Deployment', done: 'Done', failed: 'Failed', 'post-deployment': 'Post-deployment'
  };
  var ROUTE_LABEL = { simplified: 'Simplified machine provisioning (preview)', 'oem-image': 'OEM image + Arc registration' };
  var STATUS_LABEL = {
    notstarted: 'Not started', running: 'In progress', success: 'Succeeded',
    error: 'Failed', skipped: 'Skipped', unknown: 'Unknown'
  };
  var DEMO = typeof location !== 'undefined' && /(?:^|[?&])demo=(?:1|true|yes)(?:&|$)/i.test(location.search);
  // ?demo=1&route=simplified|oem shows the machine-readiness phase of that route instead of a running deployment.
  var DEMO_ROUTE = (function () {
    if (typeof location === 'undefined') return '';
    var m = /(?:^|[?&])route=(simplified|oem|oem-image)(?:&|$)/i.exec(location.search);
    return m ? (m[1].toLowerCase() === 'simplified' ? 'simplified' : 'oem-image') : '';
  })();

  // ------------------------------------------------------------------ state

  var app = {
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
    filter: { level: 'all', q: '', file: '', stepKey: null },
    follow: true,
    newWhilePaused: 0,
    rendered: 0,
    treeSig: { provisioning: null, validation: null, extensions: null, deployment: null },
    expanded: new Map(),        // key -> bool (user choice)
    sectionCollapsed: { provisioning: false, validation: false, extensions: false, deployment: false },
    provAutoCollapsed: false,   // the provisioning section was collapsed once validation started
    provTree: [],               // one synthetic tree item per machine (provisioningTreeOf)
    extTree: [],                // OEM image route, from Validate on: one item per machine with its extensions
    stepIndex: new Map(),       // key -> { node, section, parentKey }
    focusKey: { provisioning: null, validation: null, extensions: null, deployment: null },
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
  function fmtAgo(t) {
    if (isNaN(t)) return '';
    var s = Math.max(0, Math.round((Date.now() - t) / 1000));
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

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) {
      for (var k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
        var v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') e.className = v;
        else if (k === 'text') e.textContent = v;
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
          probe: isObj(n.probe) ? n.probe : null
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

  app.store = createLogStore(MAX_STORED_LINES);

  if (typeof module === 'object' && module && module.exports && typeof document === 'undefined') {
    module.exports = {
      createLogStore: createLogStore, logStoreReset: logStoreReset, logStoreIngest: logStoreIngest,
      logStoreStreamOpened: logStoreStreamOpened, logStoreStreamClosed: logStoreStreamClosed,
      stepWindowOf: stepWindowOf, windowSignature: windowSignature, lineInWindow: lineInWindow, stepFilterChange: stepFilterChange,
      fileOptionList: fileOptionList, keptFileSelection: keptFileSelection, normLevel: normLevel, parseTime: parseTime,
      normStatus: normStatus, phaseLabel: phaseLabel, phaseChipText: phaseChipText, provisioningTreeOf: provisioningTreeOf,
      provisioningSummary: provisioningSummary, provisioningCollapse: provisioningCollapse, arcSourceText: arcSourceText,
      lifecycleLabel: lifecycleLabel, stepGroupOf: stepGroupOf, probeNote: probeNote, extensionsTreeOf: extensionsTreeOf,
      readyForValidate: readyForValidate
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
      offline: 'The Sonar back end is not answering; retrying', connecting: 'Connecting to the Sonar back end', demo: 'Demo mode: built-in sample data, no API calls' }[c] || '';
    $('conn-label').textContent = { live: 'Live', polling: 'Polling', offline: 'Offline, retrying',
      connecting: 'Connecting', demo: 'Demo' }[c] || c;
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
    if (!prev || DEMO) return;
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
    var meta = [];
    if (c.resourceGroup) meta.push(c.resourceGroup);
    if (s.mode) meta.push('mode ' + s.mode);
    if (c.identityModel) meta.push(c.identityModel);
    if (s.provisioningState) meta.push('ARM ' + s.provisioningState);
    $('cluster-meta').textContent = meta.join(' \u00b7 ');
    document.title = (name !== 'Unknown cluster' ? name + ' \u2013 ' : '') + 'AzL Sonar';

    var phase = app.state ? normPhase(s.phase) : 'unknown';
    var chip = $('phase-chip');
    chip.setAttribute('data-phase', phase);
    chip.textContent = app.state ? phaseChipText(s) : '\u2014';

    var ov = overallStatus();
    var st = $('overall-status');
    st.setAttribute('data-status', ov.key);
    st.innerHTML = app.state ? icon(ov.key) : '';
    st.appendChild(document.createTextNode(app.state ? ov.label : '\u2014'));

    tickHeader();
    renderNodes();

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
    if (phase === 'deployment' || phase === 'validation') {
      var k = sectionStatus(s[phase]);
      var label = STATUS_LABEL[k];
      if (k === 'success' && phase === 'validation') label = 'Validation succeeded';
      if (k === 'unknown') label = str(isObj(s[phase]) ? s[phase].status : '') || 'Unknown';
      return { key: k, label: label };
    }
    if (isObj(s.provisioning) && arr(s.provisioning.nodes).length) {
      var sum = provisioningSummary(app.provTree);
      if (readyForValidate(s)) {
        return { key: 'success', label: 'Ready for Validate: ' + sum.ready + ' of ' + sum.total + ' machine' + (sum.total === 1 ? '' : 's') + ' registered' };
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
      var end = r.end === null ? Date.now() : r.end;
      e.textContent = fmtDuration((end - r.start) / 1000) || '0s';
      e.title = 'Since ' + fmtDateTime(r.start);
    }
    var lp = $('last-poll');
    var t = app.state ? parseTime(app.state.polledAt) : NaN;
    if (isNaN(t)) { lp.textContent = '\u2014'; lp.removeAttribute('data-stale'); lp.removeAttribute('title'); return; }
    lp.textContent = fmtAgo(t);
    lp.title = fmtDateTime(t);
    var pollS = Number(app.config && app.config.pollSeconds) || 20;
    lp.setAttribute('data-stale', String(Date.now() - t > Math.max(60, pollS * 3) * 1000));
  }

  function renderNodes() {
    var ul = $('node-chips');
    var byName = new Map();
    arr(app.config && app.config.nodes).forEach(function (n) {
      if (isObj(n) && n.name) byName.set(String(n.name).toLowerCase(), { name: n.name, seed: !!n.seed });
    });
    arr(app.state && app.state.nodes).forEach(function (n) {
      if (!isObj(n) || !n.name) return;
      var k = String(n.name).toLowerCase();
      var cur = byName.get(k) || { name: n.name, seed: !!n.seed };
      cur.arcStatus = n.arcStatus;
      cur.lastStatusChange = n.lastStatusChange;
      cur.arcMachineName = n.arcMachineName;
      cur.arcSource = n.arcSource;
      byName.set(k, cur);
    });
    ul.textContent = '';
    byName.forEach(function (n) {
      var arc = str(n.arcStatus) || 'Unknown';
      var tip = n.name + ': Azure Arc ' + arc;
      var lt = parseTime(n.lastStatusChange);
      if (!isNaN(lt)) tip += ' since ' + fmtDateTime(lt);
      if (n.arcMachineName && n.arcMachineName !== n.name) tip += '\nArc machine ' + n.arcMachineName + (arcSourceText(n.arcSource) ? ' (' + arcSourceText(n.arcSource) + ')' : '');
      ul.appendChild(el('li', { class: 'node-chip', 'data-arc': arc.toLowerCase(), title: tip }, [
        el('span', { class: 'dot', 'aria-hidden': 'true' }),
        el('span', { text: n.name }),
        el('span', { class: 'arc', text: arc }),
        n.seed ? el('span', { class: 'seed', text: 'seed' }) : null,
        el('span', { class: 'sr-only', text: !isNaN(lt) ? ', since ' + fmtDateTime(lt) : '' })
      ]));
    });
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
      var secs = cur.phase === 'validation' || cur.phase === 'deployment' ? [cur.phase] :
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
    ['deployment', 'validation'].forEach(function (sec) {
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
    if (st === 'running' && !isNaN(a)) return (Date.now() - a) / 1000;
    if (typeof n.durationSeconds === 'number' && n.durationSeconds >= 0) return n.durationSeconds;
    if (!isNaN(a) && !isNaN(b)) return (b - a) / 1000;
    return null;
  }

  function renderTree(autoScroll) {
    var host = $('tree-host');
    var provHost = $('prov-host');
    var active = document.activeElement;
    var hadFocus = host.contains(active) || provHost.contains(active);
    var focusedKey = hadFocus && active.getAttribute ? active.getAttribute('data-key') : null;
    var s = app.state || {};

    renderProvisioningPanel();
    ['provisioning', 'validation', 'extensions', 'deployment'].forEach(function (section) {
      var sec = section === 'provisioning' ? (isObj(s.provisioning) ? s.provisioning : {}) : (isObj(s[section]) ? s[section] : {});
      var tree = section === 'provisioning' ? app.provTree : section === 'extensions' ? app.extTree : arr(sec.tree);
      var target = section === 'provisioning' ? provHost : host;
      var sig = JSON.stringify([tree, sec.status, sec.phase, app.sectionCollapsed[section], app.selectedKey, app.currentKey,
        Array.from(app.expanded.entries())], function (k, v) { return k === '__key' ? undefined : v; });
      var wrap = target.querySelector('.tree-section[data-section="' + section + '"]');
      if (wrap && app.treeSig[section] === sig) return;
      app.treeSig[section] = sig;
      if ((section === 'provisioning' || section === 'extensions') && !tree.length) { if (wrap) wrap.remove(); return; }
      var fresh = buildSection(section, sec, tree);
      if (wrap) target.replaceChild(fresh, wrap); else target.appendChild(fresh);
    });

    // keep validation, then the extensions installed during Validate, above deployment
    var order = ['validation', 'extensions', 'deployment'].map(function (k) { return host.querySelector('[data-section="' + k + '"]'); })
      .filter(Boolean);
    for (var oi = 1; oi < order.length; oi++) {
      if (order[oi - 1].nextSibling !== order[oi]) host.insertBefore(order[oi], order[oi - 1].nextSibling);
    }

    if (focusedKey) {
      var f = treeItem(focusedKey);
      if (f) f.focus({ preventScroll: true });
    }
    $('jump-current').disabled = !app.currentKey;
    if (autoScroll) scrollToKey(app.currentKey, false);
    tickTimers();
  }

  // The panel above the step tree: shown while the state has machines to follow (both routes).
  function renderProvisioningPanel() {
    var s = app.state || {}, prov = isObj(s.provisioning) ? s.provisioning : null;
    var panel = $('prov-panel');
    panel.hidden = !app.provTree.length;
    if (!prov) return;
    $('prov-title').textContent = phaseLabel(prov.phase || (prov.route === 'oem-image' ? 'arc-registration' : 'provisioning'));
    var r = $('prov-route');
    r.textContent = ROUTE_LABEL[str(prov.route)] || '';
    r.hidden = !r.textContent;
    r.title = prov.routeSource === 'auto' ? 'Picked automatically (provisioningRoute auto): ' +
      (prov.route === 'simplified' ? 'edge machines found for the nodes' : 'no edge machines for the nodes') : 'Set by provisioningRoute in the config';
    $('prov-hint').textContent = prov.route === 'oem-image' ?
      'What Arc registration does on each machine: the OS image update and the bootstrap as the node reports them ' +
      '(Get-ArcZeroDaySolutionUpdateStatus, Get-ArcBootstrapStatus), and the Arc machine in Azure. The mandatory extensions ' +
      'install later, during Validate.' + (readyForValidate(s) ? ' Every machine is registered: ready for Validate.' : '') :
      'How each machine gets ready before validation: the lifecycle, the steps Azure reports and their errors.';
  }

  // A tree item by key, in either tree host.
  function treeItem(k) {
    var sel = '[data-key="' + cssEscape(k) + '"]';
    return $('tree-host').querySelector(sel) || $('prov-host').querySelector(sel);
  }

  function cssEscape(s) {
    if (window.CSS && CSS.escape) return CSS.escape(s);
    return String(s).replace(/["\\]/g, '\\$&');
  }

  function buildSection(section, sec, tree) {
    var isProv = section === 'provisioning' || section === 'extensions';
    var title = section === 'provisioning' ? 'Machines' : section === 'extensions' ? 'Extensions (installed during Validate)' :
      section === 'validation' ? 'Validation' : 'Deployment';
    var what = section === 'extensions' ? 'Extensions' : phaseLabel(sec.phase);
    var st = isProv ? normStatus(sec.status) : sectionStatus(sec);
    var collapsed = !!app.sectionCollapsed[section];
    var wrap = el('div', { class: 'tree-section', 'data-section': section });

    var toggle = el('button', { type: 'button', class: 'section-toggle', 'aria-expanded': String(!collapsed),
      'aria-controls': 'tree-' + section });
    toggle.innerHTML = ICON.caret;
    toggle.appendChild(el('h3', { text: title }));
    toggle.addEventListener('click', function () {
      app.sectionCollapsed[section] = !app.sectionCollapsed[section];
      renderTree(false);
      var b = (section === 'provisioning' ? $('prov-host') : $('tree-host')).querySelector('[data-section="' + section + '"] .section-toggle');
      if (b) b.focus();
    });

    var stEl = el('span', { class: 'status-text section-status', 'data-status': st });
    stEl.innerHTML = icon(st);
    stEl.appendChild(document.createTextNode(st === 'unknown' ? (str(sec.status) || 'Unknown') : STATUS_LABEL[st]));

    var head = el('div', { class: 'section-head' }, [toggle, stEl]);
    wrap.appendChild(head);

    if (isProv) {
      var sum = provisioningSummary(tree);
      var pmeta = el('div', { class: 'section-meta' });
      var pbar = el('div', { class: 'progress', role: 'progressbar', 'aria-label': what + ' progress',
        'aria-valuemin': '0', 'aria-valuemax': String(sum.total), 'aria-valuenow': String(sum.ready),
        'aria-valuetext': sum.ready + ' of ' + sum.total + ' machines ready' + (sum.failed ? ', ' + sum.failed + ' failed' : '') });
      [['success', sum.ready], ['error', sum.failed], ['running', sum.running]].forEach(function (x) {
        if (x[1]) pbar.appendChild(el('span', { class: 'p-' + x[0], style: 'width:' + (100 * x[1] / sum.total) + '%' }));
      });
      pmeta.appendChild(pbar);
      var readyWord = section === 'provisioning' && str(sec.route) === 'oem-image' ? ' machines registered' : ' machines ready';
      pmeta.appendChild(el('span', { class: 'progress-label', text: sum.ready + ' / ' + sum.total + readyWord +
        (sum.failed ? ' \u00b7 ' + sum.failed + ' failed' : '') + (sum.running ? ' \u00b7 ' + sum.running + ' in progress' : '') }));
      head.appendChild(pmeta);
      if (collapsed) return wrap;
      var pul = el('ul', { class: 'tree', role: 'tree', id: 'tree-' + section, 'aria-label': what + ' by machine' });
      var ptab = app.focusKey[section] && app.stepIndex.has(app.focusKey[section]) ? app.focusKey[section] : null;
      tree.forEach(function (n) { if (isObj(n)) pul.appendChild(buildItem(n, 1, ptab)); });
      var pfirst = pul.querySelector('[role="treeitem"][tabindex="0"]');
      if (!pfirst || !isVisibleItem(pfirst)) {
        if (pfirst) pfirst.setAttribute('tabindex', '-1');
        var pf = pul.querySelector('[role="treeitem"]');
        if (pf) pf.setAttribute('tabindex', '0');
      }
      pul.addEventListener('keydown', onTreeKey);
      wrap.appendChild(pul);
      return wrap;
    }

    var agg = aggregate(tree);
    if (!agg.total && isObj(sec.counts)) {
      // no tree yet but the back end sent counts
      Object.keys(sec.counts).forEach(function (k) {
        var nk = normStatus(k);
        var v = Number(sec.counts[k]) || 0;
        agg[nk] = (agg[nk] || 0) + v;
        agg.total += v;
      });
    }

    if (agg.total) {
      var meta = el('div', { class: 'section-meta' });
      var done = agg.success + agg.skipped;
      var bar = el('div', { class: 'progress', role: 'progressbar', 'aria-label': title + ' progress',
        'aria-valuemin': '0', 'aria-valuemax': String(agg.total), 'aria-valuenow': String(done),
        'aria-valuetext': done + ' of ' + agg.total + ' steps done' + (agg.error ? ', ' + agg.error + ' failed' : '') });
      ['success', 'skipped', 'error', 'running'].forEach(function (k) {
        if (agg[k]) bar.appendChild(el('span', { class: 'p-' + k, style: 'width:' + (100 * agg[k] / agg.total) + '%' }));
      });
      meta.appendChild(bar);
      meta.appendChild(el('span', { class: 'progress-label', text: done + ' / ' + agg.total + ' steps done' }));
      var counts = el('div', { class: 'counts', 'aria-label': title + ' step counts' });
      ['success', 'running', 'error', 'skipped', 'notstarted', 'unknown'].forEach(function (k) {
        if (!agg[k]) return;
        var c = el('span', { class: 'count', title: STATUS_LABEL[k] });
        c.innerHTML = icon(k);
        c.appendChild(el('b', { text: String(agg[k]) }));
        c.appendChild(el('span', { class: 'sr-only', text: ' ' + STATUS_LABEL[k] }));
        counts.appendChild(c);
      });
      meta.appendChild(counts);
      head.appendChild(meta);
    }

    if (collapsed) return wrap;

    if (!tree.length) {
      wrap.appendChild(el('p', { class: 'empty', id: 'tree-' + section,
        text: st === 'notstarted' ? title + ' has not started yet.' : 'No steps reported.' }));
      return wrap;
    }

    var ul = el('ul', { class: 'tree', role: 'tree', id: 'tree-' + section, 'aria-label': title + ' steps' });
    var tabKey = app.focusKey[section] && app.stepIndex.has(app.focusKey[section]) ? app.focusKey[section] :
      (app.currentKey && app.stepIndex.get(app.currentKey) && app.stepIndex.get(app.currentKey).section === section ? app.currentKey : null);
    tree.forEach(function (n) {
      if (!isObj(n)) return;
      ul.appendChild(buildItem(n, 1, tabKey));
    });
    // ensure exactly one tabbable item, and that it is visible
    var tabbable = ul.querySelector('[role="treeitem"][tabindex="0"]');
    if (!tabbable || !isVisibleItem(tabbable)) {
      if (tabbable) tabbable.setAttribute('tabindex', '-1');
      var f = ul.querySelector('[role="treeitem"]');
      if (f) f.setAttribute('tabindex', '0');
    }
    ul.addEventListener('keydown', onTreeKey);
    wrap.appendChild(ul);
    return wrap;
  }

  function buildItem(n, level, tabKey) {
    var k = n.__key;
    var st = normStatus(n.status);
    var kids = arr(n.children).filter(isObj);
    var hasKids = kids.length > 0;
    var open = hasKids && isExpanded(n);
    var dur = nodeDuration(n);
    var name = str(n.name) || str(n.description) || '(unnamed step)';
    var label = name + ', ' + (st === 'unknown' ? str(n.status) || 'unknown status' : STATUS_LABEL[st]) +
      (dur !== null ? ', ' + fmtDuration(dur) : '') + (arr(n.errors).length ? ', ' + arr(n.errors).length + ' error message(s)' : '');

    var li = el('li', { role: 'treeitem', 'data-key': k, 'aria-level': String(level), 'aria-label': label,
      'aria-selected': String(app.selectedKey === k), tabindex: tabKey === k ? '0' : '-1' });
    if (hasKids) li.setAttribute('aria-expanded', String(open));

    var row = el('div', { class: 'row', 'data-status': st, 'data-current': String(app.currentKey === k) });
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
    var inSec = (app.stepIndex.get(k) || {}).section;
    var inProv = inSec === 'provisioning' || inSec === 'extensions';   // machine-section ids are Sonar's own, not fullStepIndex
    if (!inProv && n.id !== undefined && n.id !== null && n.id !== '' && str(n.id) !== name) nameEl.appendChild(el('span', { class: 'idx', text: str(n.id) }));
    nameEl.appendChild(document.createTextNode(name));
    if (n.description && n.description !== name && !isObj(n.prov)) nameEl.appendChild(el('span', { class: 'desc', text: str(n.description) }));
    row.appendChild(nameEl);

    var durEl = el('span', { class: 'dur' });
    if (st === 'running' && !isNaN(parseTime(n.start))) {
      durEl.setAttribute('data-start', String(parseTime(n.start)));
    }
    durEl.textContent = dur !== null ? fmtDuration(dur) : '';
    var tt = [];
    if (!isNaN(parseTime(n.start))) tt.push('Start ' + fmtDateTime(parseTime(n.start)));
    if (!isNaN(parseTime(n.end))) tt.push('End ' + fmtDateTime(parseTime(n.end)));
    if (tt.length) durEl.title = tt.join('\n');
    row.appendChild(durEl);

    row.addEventListener('click', function () { selectStep(k); });
    li.appendChild(row);
    if (isObj(n.prov)) li.appendChild(buildProvMeta(n, st));

    var errs = arr(n.errors).map(str).filter(Boolean);
    if (errs.length) {
      var box = el('div', { class: 'step-errors', role: 'note', 'aria-label': 'Errors for ' + name });
      errs.forEach(function (m) { box.appendChild(el('p', { text: m })); });
      li.appendChild(box);
    }

    if (hasKids) {
      var g = el('ul', { role: 'group' });
      if (!open) g.hidden = true;
      kids.forEach(function (c) { g.appendChild(buildItem(c, level + 1, tabKey)); });
      li.appendChild(g);
    }
    return li;
  }

  // Under a machine row: lifecycle chip, progress, Arc machine and (OEM route) the extension count.
  function buildProvMeta(n, st) {
    var p = n.prov;
    var meta = el('div', { class: 'prov-meta' });
    meta.appendChild(el('span', { class: 'lc-chip', 'data-status': st, title: 'Lifecycle' + (n.description ? ': ' + n.description : '') , text: p.lifecycleLabel || p.lifecycle }));
    if (p.percent !== null) {
      var pct = el('span', { class: 'prov-pct', 'data-status': st,
        title: 'Sonar\'s estimate from the lifecycle and the finished steps' + (p.reportedPercent !== null ? '; the job reports percentComplete ' + p.reportedPercent : '') });
      var bar = el('span', { class: 'progress', role: 'progressbar', 'aria-label': n.name + ' progress', 'aria-valuemin': '0',
        'aria-valuemax': '100', 'aria-valuenow': String(p.percent) });
      bar.appendChild(el('span', { class: 'p-fill', style: 'width:' + p.percent + '%' }));
      pct.appendChild(bar);
      pct.appendChild(document.createTextNode(p.percent + '%'));
      meta.appendChild(pct);
    }
    if (p.arcMachineName) {
      meta.appendChild(el('span', { class: 'prov-arc', title: arcSourceText(p.arcSource) || 'Arc machine',
        text: 'Arc ' + p.arcMachineName + (p.arcStatus ? ' (' + p.arcStatus + ')' : '') }));
    }
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
    if (n.description) meta.appendChild(el('span', { class: 'prov-msg', text: n.description }));
    return meta;
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

  function selectStep(k) {
    var info = app.stepIndex.get(k);
    if (!info) return;
    if (app.selectedKey === k && app.filter.stepKey === k) {
      clearStepFilter();
      return;
    }
    app.selectedKey = k;
    app.focusKey[info.section] = k;
    var a = parseTime(info.node.start);
    if (isNaN(a)) {
      app.filter.stepKey = null;
      announce('Step "' + str(info.node.name) + '" has no start time, so the logs cannot be filtered to it.');
      setError('step', 'Step "' + str(info.node.name) + '" has no start time yet; the log filter needs one.');
      setTimeout(function () { setError('step', null); }, 6000);
    } else {
      app.filter.stepKey = k;
      announce('Logs filtered to step ' + str(info.node.name) + '.');
    }
    renderTree(false);
    var item = treeItem(k);
    if (item) focusItem(item);
    renderChips();
    rerenderLogs();
  }

  function clearStepFilter() {
    app.filter.stepKey = null;
    app.selectedKey = null;
    renderTree(false);
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

  function tickTimers() {
    var now = Date.now();
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

  function renderGuidance() {
    var body = $('guidance-body'), tabs = $('guidance-tabs');
    var cur = app.state ? normPhase(app.state.phase) : 'provisioning';
    var model = guidanceModel();
    var m = $('guidance-model');
    m.textContent = model ? str(model) : '';
    m.hidden = !model;

    var available = guidancePhases();
    // only the machine-readiness phase of the route Sonar follows (provisioning or arc-registration)
    var route = app.state && isObj(app.state.provisioning) ? str(app.state.provisioning.route) : '';
    var hide = route === 'simplified' ? 'arc-registration' : route === 'oem-image' ? 'provisioning' : '';
    available = available.filter(function (p) { return p !== hide; });
    var shown = ['provisioning', 'arc-registration', 'validation', 'deployment'].filter(function (p) { return available.indexOf(p) >= 0; });
    available.forEach(function (p) { if (shown.indexOf(p) < 0) shown.push(p); });
    // the phase that matches "now"; a failed run shows the phase that failed; after the run ends, prefer a
    // post-deployment entry, else deployment
    var defaultView = cur;
    var activeNow = app.state ? str(app.state.activePhase).toLowerCase() : '';
    if (cur === 'failed' && activeNow && shown.indexOf(activeNow) >= 0) defaultView = activeNow;
    else if (shown.indexOf(cur) < 0 && (cur === 'done' || cur === 'failed')) {
      defaultView = shown.filter(function (p) { return gkey(p) === 'postdeployment' || gkey(p) === 'after'; })[0] || 'deployment';
    }
    if (app.guidancePhase && shown.indexOf(app.guidancePhase) < 0) app.guidancePhase = null;
    var view = app.guidancePhase || defaultView;

    tabs.textContent = '';
    tabs.hidden = shown.length < 2;
    shown.forEach(function (p) {
      var b = el('button', { type: 'button', 'aria-pressed': String(p === view) }, [phaseLabel(p)]);
      if (p === defaultView) {
        b.appendChild(el('span', { class: 'cur-dot', title: 'Current phase', 'aria-hidden': 'true' }));
        b.appendChild(el('span', { class: 'sr-only', text: ' (current phase)' }));
      }
      b.addEventListener('click', function () {
        app.guidancePhase = p === defaultView ? null : p;
        renderGuidance();
        var nb = tabs.querySelector('[aria-pressed="true"]');
        if (nb) nb.focus();
      });
      tabs.appendChild(b);
    });

    body.textContent = '';
    if (!app.guidance) {
      body.appendChild(el('p', { class: 'muted', text: app.errors.has('guidance') ? 'Guidance is unavailable.' : 'Loading guidance\u2026' }));
      return;
    }
    var g = phaseGuidance(view);
    if (!g) {
      body.appendChild(el('p', { class: 'muted', text: 'No guidance recorded for the ' + phaseLabel(view) + ' phase.' }));
      return;
    }
    var dl = el('dl');
    function row(label, valueNode) { dl.appendChild(el('dt', { text: label })); dl.appendChild(el('dd', null, [valueNode])); }

    var account = pick(g, ['account', 'accounts', 'user', 'who', 'readBy']);
    if (account !== undefined) row('Account', textList(listOf(account), false));
    var where = pick(g, ['where', 'logs', 'logPaths', 'paths', 'location', 'locations', 'logLocation']);
    if (where !== undefined) row('Where', textList(listOf(where), true));
    var when = pick(g, ['when', 'available', 'availability', 'whenAvailable']);
    if (when !== undefined) row('When', textList(listOf(when), false));
    var how = pick(g, ['how', 'access', 'method']);
    if (how !== undefined) row('How', textList(listOf(how), false));
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
        if (/^https?:\/\//i.test(s)) li.appendChild(el('a', { href: s, target: '_blank', rel: 'noopener noreferrer', text: s }));
        else li.appendChild(document.createTextNode(s));
        ul.appendChild(li);
      });
      row('Source', ul);
    }
    body.appendChild(dl);
    var notes = pick(g, ['notes', 'note', 'details']);
    if (notes !== undefined) body.appendChild(el('p', { class: 'notes', text: listOf(notes).join(' ') }));
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

  function lineMatches(l, win) {
    var f = app.filter;
    if (f.level === 'error' && l.level !== 'error') return false;
    if (f.level === 'warning' && l.level === 'info') return false;
    if (f.file && l.file !== f.file) return false;
    if (win && !lineInWindow(l, win)) return false;
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
    var msg;
    if (!app.store.lines.length) {
      var t = app.tailer && str(app.tailer.state).toLowerCase();
      msg = t === 'unavailable' ? 'No log lines: the log tailer cannot reach the seed node (see above).' : 'Waiting for log lines\u2026';
    } else {
      msg = 'No lines match the current filters.';
    }
    view.appendChild(el('div', { class: 'log-empty', text: msg }));
  }

  function updateLogStatus() {
    var parts = [];
    var filtered = app.filter.level !== 'all' || app.filter.q || app.filter.file || app.filter.stepKey;
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
    $('banner-close').addEventListener('click', function () {
      app.bannerDismissed = Array.from(app.errors.values()).join('|');
      $('banner').hidden = true;
    });

    $('jump-current').addEventListener('click', function () {
      if (!app.currentKey) return;
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

    setInterval(function () { tickTimers(); tickHeader(); }, 1000);
  }

  function start() {
    wire();
    renderCounts();
    renderTree(false);
    rerenderLogs();
    if (DEMO) { startDemo(); return; }
    setConn('connecting');
    Promise.allSettled([loadConfig(), loadGuidance(), loadState(), loadLogs()]).then(function (res) {
      var ok = res.some(function (r) { return r.status === 'fulfilled'; });
      if (!ok) setConn('offline');
      connectSSE();
    });
  }

  // ------------------------------------------------------------------ demo mode (?demo=1): built-in sample data, no API calls

  function startDemo() {
    $('demo-badge').hidden = false;
    setConn('demo');
    var now = Date.now();
    function iso(msAgo) { return new Date(now - msAgo).toISOString(); }
    function step(id, name, status, startAgo, endAgo, children, errors, description) {
      var st = startAgo === null ? null : iso(startAgo), en = endAgo === null ? null : iso(endAgo);
      return { id: id, name: name, description: description || '', status: status, start: st, end: en,
        durationSeconds: st && en ? (startAgo - endAgo) / 1000 : (st ? startAgo / 1000 : null),
        errors: errors || [], children: children || [] };
    }
    var M = 60000;
    if (DEMO_ROUTE) { startRouteDemo(DEMO_ROUTE, iso, step, M); return; }
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
    applyConfig({ cluster: 'clus01', resourceGroup: 'rg-example-azl', identityModel: 'LocalIdentity', pollSeconds: 20,
      nodes: [{ name: 'node01', seed: true }, { name: 'node02' }], logPaths: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'] });
    app.guidance = {
      identityModel: 'LocalIdentity',
      phases: {
        provisioning: { account: 'Local administrator on each node', where: ['C:\\MASLogs'], when: 'After the operating system install finishes', source: 'Sample data (demo mode)', verified: false },
        validation: { account: 'Deployment user on the seed node', where: ['C:\\CloudDeployment\\Logs'], when: 'From the start of Validate, on the seed node first', source: 'Sample data (demo mode)', verified: false },
        deployment: { account: 'Deployment user on the seed node', where: ['C:\\CloudDeployment\\Logs', 'C:\\MASLogs'], when: 'Throughout Deploy; files rotate as steps change', source: 'Sample data (demo mode)', verified: false, notes: 'Demo guidance only. The real card reads data/phase-guidance.json through /api/guidance.' }
      }
    };
    applyState(state);
    applyTailer({ state: 'connected', reason: '', node: 'node01' });
    var f1 = 'C:\\CloudDeployment\\Logs\\CloudDeployment.2026-10-10.1.log', f2 = 'C:\\MASLogs\\Lcm.log';
    applyFiles([{ path: f1, size: 0, offset: 0 }, { path: f2, size: 0, offset: 0 }]);
    var seq = 0;
    function line(msAgo, file, level, text) { return { seq: ++seq, time: iso(msAgo), received: iso(msAgo), timeSource: 'line', file: file, level: level, text: text }; }
    applyLogBatch([
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
    ], { source: 'live' });
    var msgs = [
      ['info', 'Storage pool health: Healthy.'],
      ['info', 'Waiting for virtual disk "Infrastructure_1" to come online.'],
      ['warning', 'Warning: storage job progress unchanged for 60 s; continuing to wait.'],
      ['info', 'Storage job progress 42%.'],
      ['info', 'Storage job progress 57%.'],
      ['error', 'Retryable error: cluster resource "Infrastructure_1" is pending; will retry.'],
      ['info', 'Storage job progress 71%.']
    ];
    var mi = 0;
    setInterval(function () {
      var m = msgs[mi++ % msgs.length];
      var nowIso = new Date().toISOString();
      applyLogBatch([{ seq: ++seq, time: nowIso, received: nowIso, timeSource: 'line', file: f1, level: m[0], text: m[1] }], { source: 'live' });
    }, 2500);
    setInterval(function () {
      state.polledAt = new Date().toISOString();
      applyState(state);
    }, 20000);
    app.demoExport = function () { return { config: app.config, timeline: [state], logs: app.store.lines.map(function (l) { return { seq: l.seq, time: l.time, received: l.received, timeSource: l.timeSource, file: l.file, level: l.level, text: l.text }; }) }; };
  }

  // ?demo=1&route=simplified: three machines on simplified machine provisioning (one provisioned, one installing the
  // OS, one failed at InstallExtensions with an extension download error). ?demo=1&route=oem: two machines on
  // the OEM image route during Arc registration (node01 updating its OS image, in Download; node02 bootstrapping, in
  // ArcConfiguration > ArcRegistration). Step names as the nodes report them (read live 11 Oct 2026). Sample data
  // only; no API calls.
  function startRouteDemo(route, iso, step, M) {
    var simplified = route === 'simplified';
    var EXT = ['AzureEdgeDeviceManagement', 'AzureEdgeLifecycleManager', 'AzureEdgeRemoteSupport', 'AzureEdgeTelemetryAndDiagnostics'];
    var JOB = ['CreatedTargetArcMachine', 'CopiedSiteSettings', 'SetupPermissions', 'ArcNotificationSent', 'Initialize',
      'ResolveConfiguration', 'DownloadOSArtifacts', 'SBEDiscoveryDownload', 'SetupHybridComputeRP', 'PrepareTargetOSProvisioning',
      'InitiateTargetOSProvisioning', 'PrepareK3sShutdown', 'BootIntoTargetOS', 'ValidateStagedArtifacts', 'InvokeTPAUpdate',
      'ReportUpdateStatus', 'ProvisionOs', 'InstallExtensions', 'DeleteUnusedRoleAssignments', 'DeleteUnusedArcMachine'];
    var FAIL = 'Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server';
    var SUBS = [['Initialize', 'Initialize Resource'], ['DownloadOs', 'Download OS'], ['PrepareOs', 'Prepare OS'],
      ['RebootOs', 'Reboot into OS'], ['InstallExtensions', 'Install required Arc extensions'], ['Finalize', 'Finalize system configuration']];

    // cur: index of the current item (-1: all finished); curStatus: running or error
    function steps(prefix, names, startAgo, per, cur, curStatus, errors) {
      return names.map(function (nm, i) {
        var name = Array.isArray(nm) ? nm[0] : nm, desc = Array.isArray(nm) ? nm[1] : '';
        var a = startAgo - i * per, b = a - per;
        if (cur < 0 || i < cur) return step(prefix + i, name, 'success', a, b, null, null, desc);
        if (i === cur) return step(prefix + i, name, curStatus, a, curStatus === 'running' ? null : b, null, curStatus === 'error' ? errors : null, desc);
        return step(prefix + i, name, 'notstarted', null, null, null, null, desc);
      });
    }
    function machine(name, idx, cur, curStatus, jobCur, lifecycle) {
      var t0 = (75 - idx * 6) * M;
      var stages = [
        step('lifecycle.0', 'ProvisionMachine', 'success', t0, t0 - 9 * M, steps('lifecycle.0.', [['RegisterMachine', 'Register machine with onboarding service'],
          ['ArcEnableMaintenanceEnvironment', 'Arc enable maintenance environment'], ['InstallExtensions', 'Install required Arc extensions']], t0, 3 * M, -1), null, 'Provision machine'),
        step('lifecycle.1', 'InstallOs', cur < 0 ? 'success' : curStatus, t0 - 10 * M, cur < 0 ? t0 - 58 * M : null,
          steps('lifecycle.1.', SUBS, t0 - 10 * M, 8 * M, cur, curStatus, [FAIL]), null, 'Install OS')
      ];
      var jobStatus = jobCur < 0 ? 'success' : curStatus;
      var job = step('job', 'ProvisionOs job', jobStatus, t0 - 10 * M, jobCur < 0 ? t0 - 58 * M : (jobStatus === 'error' ? 2 * M : null),
        steps('job.', JOB, t0 - 10 * M, 2 * M + 20000, jobCur, curStatus, [FAIL]), jobStatus === 'error' ? ['InstallExtensionsFailed: ' + FAIL] : null,
        'edgeMachines/jobs/ProvisionOs');
      var done = jobCur < 0 ? JOB.length : jobCur;
      var status = jobCur < 0 ? 'success' : curStatus;
      return {
        name: name, route: 'simplified', lifecycle: lifecycle,
        lifecycleMessage: lifecycle === 'Provisioned' ? 'Machine has been successfully provisioned.' : 'Installing OS in progress. Wait for the operation to complete.',
        status: status, percent: lifecycle === 'Provisioned' ? 100 : Math.min(95, Math.round(25 + 70 * done / JOB.length)), reportedPercent: 50,
        arcMachineName: '00000000-0000-0000-0000-00000000000' + idx + '-1', arcSource: 'edgeMachine.job',
        arcStatus: lifecycle === 'Provisioned' || status === 'error' ? 'Connected' : 'Disconnected',
        extensions: EXT.map(function (e) { return { name: e, status: lifecycle === 'Provisioned' ? 'success' : 'notstarted' }; }),
        start: iso(t0), end: status === 'running' ? null : iso(status === 'error' ? 2 * M : t0 - 58 * M),
        errors: status === 'error' ? ['ProvisionOs: InstallExtensionsFailed: ' + FAIL] : [], tree: stages.concat([job])
      };
    }
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

    var names = simplified ? ['node01', 'node02', 'node03'] : ['node01', 'node02'];
    var provNodes = simplified ?
      [machine('node01', 1, -1, 'success', -1, 'Provisioned'), machine('node02', 2, 3, 'running', 12, 'InstallingOs'), machine('node03', 3, 4, 'error', 17, 'InstallingOs')] :
      [oemMachine('node01', 1, -2, -1), oemMachine('node02', -2, BOOT.length, 2)];
    var phase = simplified ? 'provisioning' : 'arc-registration';
    var provStatus = simplified ? 'error' : 'running';
    var state = {
      cluster: 'clus01', mode: null, provisioningState: null,
      phase: simplified ? 'failed' : phase, activePhase: phase,
      provisioning: { route: route, routeSource: 'auto', phase: phase, status: provStatus, readyForValidate: false, nodes: provNodes },
      extensions: { shown: false, status: 'notstarted', nodes: [] },
      validation: { status: 'notstarted', tree: [], counts: {} },
      deployment: { status: 'notstarted', tree: [], counts: {} },
      nodes: provNodes.map(function (n) { return { name: n.name, arcStatus: n.arcStatus, arcMachineName: n.arcMachineName, arcSource: n.arcSource, lastStatusChange: iso(30 * M) }; }),
      current: simplified ? { phase: phase, stepPath: ['node02', 'job', 'job.12'], stepName: 'BootIntoTargetOS' } :
        { phase: phase, stepPath: ['node02', 'bootstrap', 'bootstrap.5', 'bootstrap.5.2'], stepName: 'ArcRegistration' },
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
    applyLogBatch(simplified ? [
      line(20 * M, f1, 'info', 'Bootstrap service started on node01.'),
      line(19 * M, f2, 'info', 'Azure Connected Machine agent installed.'),
      line(18 * M, f3, 'info', 'Connecting node01 to Azure Arc as 00000000-0000-0000-0000-000000000001-1.'),
      line(12 * M, f1, 'info', 'Mandatory extensions reported Succeeded.'),
      line(9 * M, f1, 'info', 'Machine provisioned.')
    ] : [
      line(15 * M, f3, 'info', 'Invoke-AzStackHciArcInitialization started for node01.'),
      line(14 * M, f3, 'info', 'The OS image is not the latest for its release baseline: starting the solution update.'),
      line(12 * M, f1, 'info', 'Update: Scan Succeeded; Download InProgress.'),
      line(10 * M, f1, 'warning', 'Warning: the proxy bypass list is empty; using direct connections.')
    ], { source: 'live' });
    var msgs = simplified ? [['info', 'Bootstrap heartbeat: healthy.'], ['info', 'Waiting for the next provisioning task.']] :
      [['info', 'Bootstrap heartbeat: healthy.'], ['info', 'Update: Download InProgress.']];
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
