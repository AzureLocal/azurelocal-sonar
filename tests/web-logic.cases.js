/* Cases for the page's pure log logic (src/AzlSonar/web/app.js), run under Node by WebLogic.Tests.ps1.
   Usage: node web-logic.cases.js <path to app.js>. Prints one JSON array: [{ name, ok, message }]. No network, no DOM. */
'use strict';

var path = process.argv[2];
var m = require(path);
var cases = [];

function eq(actual, expected, what) {
  var a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error((what ? what + ': ' : '') + 'expected ' + e + ' but got ' + a);
}
function test(name, fn) {
  try { fn(); cases.push({ name: name, ok: true, message: '' }); }
  catch (err) { cases.push({ name: name, ok: false, message: String(err && err.message || err) }); }
}
function line(seq, extra) {
  var l = { seq: seq, time: '2026-10-10T18:00:00.000Z', received: '2026-10-10T18:00:00.000Z', timeSource: 'received', file: 'C:\\MASLogs\\a.log', level: 'info', text: 'line ' + seq };
  if (extra) Object.keys(extra).forEach(function (k) { l[k] = extra[k]; });
  return l;
}
function lines(from, to, extra) { var out = []; for (var i = from; i <= to; i++) out.push(line(i, extra)); return out; }
function seqs(store) { return store.lines.map(function (l) { return l.seq; }); }

// ---------------------------------------------------------------- item 2: sequencing

test('deduplicates by seq across catch-up and live batches', function () {
  var s = m.createLogStore(100);
  var a = m.logStoreIngest(s, lines(1, 3), { server: 'A', source: 'catchup', lastSeq: 3 });
  var b = m.logStoreIngest(s, lines(3, 4), { server: 'A', source: 'live' });
  var c = m.logStoreIngest(s, lines(1, 4), { server: 'A', source: 'catchup', lastSeq: 4 });
  eq(seqs(s), [1, 2, 3, 4]);
  eq(a.fresh.length, 3, 'first batch');
  eq(b.fresh.map(function (l) { return l.seq; }), [4], 'live batch');
  eq(c.fresh.length, 0, 'repeated catch-up');
});

test('merges a late catch-up answer into seq order and reports it as out of order', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 2), { server: 'A', source: 'catchup', lastSeq: 2 });
  m.logStoreStreamOpened(s, 6, 'A');
  m.logStoreIngest(s, lines(7, 8), { server: 'A', source: 'live' });
  var r = m.logStoreIngest(s, lines(3, 8), { server: 'A', source: 'catchup', lastSeq: 8 });
  eq(seqs(s), [1, 2, 3, 4, 5, 6, 7, 8]);
  eq(r.outOfOrder, true, 'outOfOrder');
  eq(r.fresh.map(function (l) { return l.seq; }), [3, 4, 5, 6], 'fresh lines in seq order');
});

test('keeps the catch-up cursor apart from the highest live seq (no skipped gap)', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 3), { server: 'A', source: 'catchup', lastSeq: 3 });
  // reconnect: the new stream continues after seq 10, so 4..10 are still missing
  m.logStoreStreamOpened(s, 10, 'A');
  m.logStoreIngest(s, lines(11, 12), { server: 'A', source: 'live' });
  eq(s.liveSeq, 12, 'liveSeq');
  eq(s.catchupSeq, 3, 'catch-up cursor must stay before the gap');
  m.logStoreIngest(s, lines(4, 12), { server: 'A', source: 'catchup', lastSeq: 12 });
  eq(s.catchupSeq, 12, 'cursor after catch-up');
  eq(seqs(s), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
});

test('a stream that starts at or before the cursor moves the cursor with it', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 5), { server: 'A', source: 'catchup', lastSeq: 5 });
  m.logStoreStreamOpened(s, 5, 'A');
  m.logStoreIngest(s, lines(6, 9), { server: 'A', source: 'live' });
  eq(s.catchupSeq, 9);
});

test('a catch-up answer covers up to lastSeq even when its last lines left the ring', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 2), { server: 'A', source: 'catchup', lastSeq: 7 });
  eq(s.catchupSeq, 7);
});

test('live lines without a stream start (older back end, no hello) never move the cursor', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 2), { source: 'catchup' });
  m.logStoreIngest(s, lines(5, 6), { source: 'live' });
  eq(s.catchupSeq, 2);
  eq(s.liveSeq, 6);
});

test('a closed stream stops moving the cursor', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 2), { server: 'A', source: 'catchup', lastSeq: 2 });
  m.logStoreStreamOpened(s, 2, 'A');
  m.logStoreStreamClosed(s);
  m.logStoreIngest(s, lines(3, 4), { server: 'A', source: 'live' });
  eq(s.catchupSeq, 2);
});

test('detects a back-end restart by a new server id in a log batch and leaves the store for the caller to reset', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 50), { server: 'A', source: 'catchup', lastSeq: 50 });
  var r = m.logStoreIngest(s, lines(1, 3), { server: 'B', source: 'live' });
  eq(r.restart, true, 'restart');
  eq(r.fresh.length, 0, 'nothing ingested from the other instance');
  eq(s.lines.length, 50, 'store untouched');
});

test('detects a back-end restart by a new server id in the stream hello', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 5), { server: 'A', source: 'catchup', lastSeq: 5 });
  eq(m.logStoreStreamOpened(s, 0, 'B').restart, true);
});

test('after a reset the new instance numbers from 1 again and is fetched since 0', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 50), { server: 'A', source: 'catchup', lastSeq: 50 });
  m.logStoreReset(s, 'B');
  eq(s.catchupSeq, 0, 'cursor back to 0');
  var r = m.logStoreIngest(s, lines(1, 3), { server: 'B', source: 'catchup', lastSeq: 3 });
  eq(r.restart, false);
  eq(seqs(s), [1, 2, 3]);
  eq(s.serverId, 'B');
});

test('adopts the server id of the first batch', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, lines(1, 1), { server: 'A', source: 'catchup', lastSeq: 1 });
  eq(s.serverId, 'A');
});

test('trims the oldest lines past the cap and never takes them back', function () {
  var s = m.createLogStore(10);
  var r = m.logStoreIngest(s, lines(1, 15), { server: 'A', source: 'catchup', lastSeq: 15 });
  eq(r.trimmed, true, 'trimmed');
  eq(seqs(s), [7, 8, 9, 10, 11, 12, 13, 14, 15]);
  var again = m.logStoreIngest(s, lines(3, 4), { server: 'A', source: 'catchup', lastSeq: 15 });
  eq(again.fresh.length, 0, 'trimmed seqs stay out');
});

// ---------------------------------------------------------------- item 1: event time and the step filter

test('reads time, received and timeSource; older back ends (no timeSource) count as received', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, [
    line(1, { time: '2026-10-10T17:00:00.000Z', received: '2026-10-10T18:00:00.000Z', timeSource: 'line' }),
    { seq: 2, time: '2026-10-10T18:05:00.000Z', file: 'f', level: 'info', text: 'old back end' }
  ], { source: 'catchup' });
  eq(s.lines[0].timeSource, 'line');
  eq(s.lines[0].t, Date.parse('2026-10-10T17:00:00.000Z'));
  eq(s.lines[0].r, Date.parse('2026-10-10T18:00:00.000Z'));
  eq(s.lines[1].timeSource, 'received');
  eq(s.lines[1].r, Date.parse('2026-10-10T18:05:00.000Z'));
});

test('step filter: a line with its own timestamp matches by event time, not by receive time', function () {
  var win = m.stepWindowOf({ status: 'success', start: '2026-10-10T17:00:00Z', end: '2026-10-10T17:10:00Z', name: 's' });
  var s = m.createLogStore(100);
  m.logStoreIngest(s, [
    line(1, { time: '2026-10-10T17:05:00.000Z', received: '2026-10-10T17:30:00.000Z', timeSource: 'line' }),
    line(2, { time: '2026-10-10T17:20:00.000Z', received: '2026-10-10T17:09:00.000Z', timeSource: 'line' })
  ], { source: 'catchup' });
  eq(m.lineInWindow(s.lines[0], win), true, 'logged inside, received late');
  eq(m.lineInWindow(s.lines[1], win), false, 'logged after the step');
});

test('step filter: a line without a timestamp is approximate and matches only when received inside the window', function () {
  var win = m.stepWindowOf({ status: 'success', start: '2026-10-10T17:00:00Z', end: '2026-10-10T17:10:00Z', name: 's' });
  var s = m.createLogStore(100);
  m.logStoreIngest(s, [
    line(1, { time: '2026-10-10T17:05:00.000Z', received: '2026-10-10T17:05:00.000Z', timeSource: 'received' }),
    line(2, { time: '2026-10-10T17:15:00.000Z', received: '2026-10-10T17:15:00.000Z', timeSource: 'received' })
  ], { source: 'catchup' });
  eq(m.lineInWindow(s.lines[0], win), true);
  eq(m.lineInWindow(s.lines[1], win), false);
});

test('step filter: a line timed by its file name matches by that time or by its receive time', function () {
  var win = m.stepWindowOf({ status: 'success', start: '2026-10-10T17:00:00Z', end: '2026-10-10T17:10:00Z', name: 's' });
  var s = m.createLogStore(100);
  m.logStoreIngest(s, [
    line(1, { time: '2026-10-10T16:50:00.000Z', received: '2026-10-10T17:05:00.000Z', timeSource: 'file' }),
    line(2, { time: '2026-10-10T17:01:00.000Z', received: '2026-10-10T17:30:00.000Z', timeSource: 'file' }),
    line(3, { time: '2026-10-10T16:50:00.000Z', received: '2026-10-10T17:30:00.000Z', timeSource: 'file' })
  ], { source: 'catchup' });
  eq(m.lineInWindow(s.lines[0], win), true, 'received inside');
  eq(m.lineInWindow(s.lines[1], win), true, 'file time inside');
  eq(m.lineInWindow(s.lines[2], win), false, 'neither inside');
});

test('no step selected: every line matches', function () {
  eq(m.lineInWindow(line(1), null), true);
});

// ---------------------------------------------------------------- item 6: the step window changes

test('a running step has an open window; when it finishes the window closes and the signature changes', function () {
  var running = m.stepWindowOf({ status: 'InProgress', start: '2026-10-10T17:00:00Z', end: '', name: 's' });
  var done = m.stepWindowOf({ status: 'Success', start: '2026-10-10T17:00:00Z', end: '2026-10-10T17:10:00Z', name: 's' });
  eq(running.end, Infinity);
  eq(done.end, Date.parse('2026-10-10T17:10:00Z') + 1000);
  eq(m.windowSignature(running) !== m.windowSignature(done), true, 'signature changes');
  eq(m.stepWindowOf({ status: 'NotStarted', start: '', name: 's' }), null, 'no start time: no window');
});

test('a new state re-renders the log pane when the window changed, clears the filter when the step is gone', function () {
  eq(m.stepFilterChange(null, false, null, null), 'none');
  eq(m.stepFilterChange('deployment/1', false, 'a', null), 'clear');
  eq(m.stepFilterChange('deployment/1', true, '1|Infinity', '1|2000'), 'rerender');
  eq(m.stepFilterChange('deployment/1', true, '1|2000', '1|2000'), 'keep');
});

// ---------------------------------------------------------------- item 5: the file filter

test('file options are the reported files plus the files of the held lines', function () {
  var s = m.createLogStore(100);
  m.logStoreIngest(s, [line(1, { file: 'C:\\x\\c.log' }), line(2, { file: 'C:\\x\\a.log' })], { source: 'catchup' });
  eq(m.fileOptionList(['C:\\x\\b.log', 'C:\\x\\a.log'], s.fileCounts), ['C:\\x\\a.log', 'C:\\x\\b.log', 'C:\\x\\c.log']);
});

test('a file drops out of the options once it is neither reported nor in the held lines', function () {
  var s = m.createLogStore(10);
  m.logStoreIngest(s, lines(1, 3, { file: 'C:\\x\\old.log' }), { source: 'catchup' });
  eq(m.fileOptionList([], s.fileCounts), ['C:\\x\\old.log'], 'held lines keep it');
  m.logStoreIngest(s, lines(4, 20, { file: 'C:\\x\\new.log' }), { source: 'catchup' });
  eq(s.fileCounts.has('C:\\x\\old.log'), false, 'its lines were trimmed');
  var list = m.fileOptionList(['C:\\x\\new.log'], s.fileCounts);
  eq(list, ['C:\\x\\new.log']);
  eq(m.keptFileSelection(list, 'C:\\x\\old.log'), '', 'selection dropped');
  eq(m.keptFileSelection(list, 'C:\\x\\new.log'), 'C:\\x\\new.log', 'selection kept');
});

// ---------------------------------------------------------------- item 8: level fallback for lines without a level

test('zero-count summaries are not problems (fallback for lines without a level)', function () {
  eq(m.normLevel('', 'error=0'), 'info');
  eq(m.normLevel('', 'Failed: 0'), 'info');
  eq(m.normLevel('', 'Tests: 12 passed, 0 failed'), 'info');
  eq(m.normLevel('', 'warning count=0'), 'info');
  eq(m.normLevel('', 'errors: 0'), 'info');
  eq(m.normLevel('', 'error=0x80070005'), 'error');
  eq(m.normLevel('', '10 failed'), 'error');
  eq(m.normLevel('', '0 errors, 1 warning'), 'warning');
  eq(m.normLevel('warning', 'whatever'), 'warning', 'a level from the back end wins');
});

// ---------------------------------------------------------------- S-8: provisioning panel (both routes)

function provState(phase, activePhase, route, nodes) {
  return { phase: phase, activePhase: activePhase, provisioning: { route: route, phase: route === 'oem-image' ? 'arc-registration' : 'provisioning', status: 'running', nodes: nodes } };
}

test('phase labels: Provisioning, Arc registration; a failed run names the phase that failed', function () {
  eq(m.phaseLabel('provisioning'), 'Provisioning');
  eq(m.phaseLabel('arc-registration'), 'Arc registration');
  eq(m.phaseLabel('validation'), 'Validation');
  eq(m.phaseChipText({ phase: 'arc-registration', activePhase: 'arc-registration' }), 'Arc registration');
  eq(m.phaseChipText({ phase: 'provisioning' }), 'Provisioning', 'older back ends without activePhase');
  eq(m.phaseChipText({ phase: 'failed', activePhase: 'provisioning' }), 'Failed: Provisioning');
  eq(m.phaseChipText({ phase: 'failed', activePhase: 'deployment' }), 'Failed: Deployment');
  eq(m.phaseChipText({ phase: 'done', activePhase: 'deployment' }), 'Done');
});

test('provisioningTreeOf: one item per machine with the tree as children and the summary in .prov', function () {
  var jobStep = { id: 'job.17', name: 'InstallExtensions', status: 'error', errors: ['Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server'], children: [] };
  var tree = m.provisioningTreeOf(provState('failed', 'provisioning', 'simplified', [
    { name: 'node-01', route: 'simplified', lifecycle: 'Provisioned', status: 'success', percent: 100, reportedPercent: 50, arcMachineName: '0000-1', arcSource: 'edgeMachine.job',
      extensions: [{ name: 'AzureEdgeDeviceManagement', status: 'success' }, { name: 'AzureEdgeLifecycleManager', status: 'success' }], tree: [] },
    { name: 'node-02', lifecycle: 'InstallingOs', lifecycleMessage: 'Installing OS in progress.', status: 'error', percent: 140,
      errors: ['ProvisionOs: InstallExtensionsFailed: x'], start: '2026-10-10T17:53:31Z', tree: [{ id: 'job', name: 'ProvisionOs job', status: 'error', children: [jobStep] }] },
    null
  ]));
  eq(tree.length, 2, 'null entries are skipped');
  eq(tree[0].id, 'node-01');
  eq(tree[0].status, 'success');
  eq(tree[0].prov.lifecycle, 'Provisioned');
  eq(tree[0].prov.reportedPercent, 50);
  eq(tree[0].prov.extensionsReady + '/' + tree[0].prov.extensionsTotal, '2/2');
  eq(tree[1].prov.percent, 100, 'percent is clamped to 0..100');
  eq(tree[1].prov.route, 'simplified', 'route falls back to the provisioning route');
  eq(tree[1].description, 'Installing OS in progress.');
  eq(tree[1].errors, ['ProvisionOs: InstallExtensionsFailed: x']);
  eq(tree[1].children[0].children[0].errors, ['Failed to download extension AzureEdgeRemoteSupport: unable to connect to the remote server']);
  eq(m.provisioningTreeOf({ phase: 'deployment' }), [], 'no provisioning data: no items');
});

test('provisioningSummary counts machines by status', function () {
  var tree = m.provisioningTreeOf(provState('arc-registration', 'arc-registration', 'oem-image', [
    { name: 'a', status: 'success' }, { name: 'b', status: 'running' }, { name: 'c', status: 'error' }, { name: 'd', status: 'notstarted' }, { name: 'e', status: 'unknown' }
  ]));
  eq(m.provisioningSummary(tree), { total: 5, ready: 1, failed: 1, running: 1, waiting: 2 });
});

test('the provisioning section collapses once when validation starts and opens again for a new provisioning run', function () {
  eq(m.provisioningCollapse('provisioning', false), 'keep');
  eq(m.provisioningCollapse('arc-registration', false), 'keep');
  eq(m.provisioningCollapse('validation', false), 'collapse');
  eq(m.provisioningCollapse('validation', true), 'keep', 'the user may have opened it again');
  eq(m.provisioningCollapse('deployment', true), 'keep');
  eq(m.provisioningCollapse('provisioning', true), 'expand');
  eq(m.provisioningCollapse('', false), 'keep');
});

test('Arc machine name sources are explained', function () {
  eq(/edge machine/.test(m.arcSourceText('edgeMachine.job')), true);
  eq(/arcMachineName/.test(m.arcSourceText('config')), true);
  eq(/host/.test(m.arcSourceText('nodeName')), true);
  eq(m.arcSourceText('bogus'), '');
});

// ---------------------------------------------------------------- OEM image route: Arc registration as the node reports it

function oemNode(name, lifecycle, status, extra) {
  var n = { name: name, route: 'oem-image', lifecycle: lifecycle, status: status, extensions: [],
    tree: [{ id: 'update', name: 'OS image update', status: 'running', children: [] }, { id: 'bootstrap', name: 'Bootstrap', status: 'notstarted', children: [] },
      { id: 'arc', name: 'Azure registration', status: 'notstarted', children: [] }] };
  if (extra) Object.keys(extra).forEach(function (k) { n[k] = extra[k]; });
  return n;
}

test('OEM lifecycle keys read as words; other routes keep the reported lifecycle', function () {
  eq(m.lifecycleLabel('oem-image', 'UpdatingOsImage'), 'Updating OS image');
  eq(m.lifecycleLabel('oem-image', 'Bootstrapping'), 'Bootstrapping');
  eq(m.lifecycleLabel('oem-image', 'Registered'), 'Registered (Connected)');
  eq(m.lifecycleLabel('oem-image', 'NotStarted'), 'Not started');
  eq(m.lifecycleLabel('oem-image', 'Failed'), 'Failed');
  eq(m.lifecycleLabel('oem-image', ''), 'Unknown');
  eq(m.lifecycleLabel('simplified', 'InstallingOs'), 'InstallingOs');
  eq(m.lifecycleLabel('oem-image', 'SomethingNew'), 'SomethingNew', 'an unknown key is shown as reported');
});

test('provisioningTreeOf (OEM): three groups per machine, update and bootstrap step counts, no extensions', function () {
  var tree = m.provisioningTreeOf(provState('arc-registration', 'arc-registration', 'oem-image', [
    oemNode('node01', 'UpdatingOsImage', 'running', {
      lifecycleMessage: 'Updating the OS image (zero-day solution update): Download. Learn: typically 40-45 minutes, then a reboot; Invoke-AzStackHciArcInitialization is run again after the reboot.',
      update: { state: 'read', status: 'running', done: 1, total: 3, current: 'Download' },
      bootstrap: { state: 'read', status: 'notstarted', done: 0, total: 9, current: null },
      probe: { state: 'ok', unreachableSince: null } }),
    oemNode('node02', 'Bootstrapping', 'running', {
      update: { state: 'notAvailable', status: 'unknown', done: 0, total: 0 },
      bootstrap: { state: 'read', status: 'InProgress', done: '7', total: 9, current: 'ArcConfiguration > ArcRegistration' } })
  ]));
  eq(tree[0].children.map(function (c) { return c.name; }), ['OS image update', 'Bootstrap', 'Azure registration']);
  eq(tree[0].prov.lifecycleLabel, 'Updating OS image');
  eq(tree[0].prov.update, { status: 'running', done: 1, total: 3, current: 'Download', state: 'read' });
  eq(/40-45 minutes/.test(tree[0].description), true, 'the update note is the machine description');
  eq(tree[0].prov.extensionsTotal, 0, 'no extensions during Arc registration');
  eq(tree[1].prov.bootstrap.status, 'running', 'raw InProgress is normalised');
  eq(tree[1].prov.bootstrap.done, 7, 'counts are numbers');
  eq(tree[1].prov.bootstrap.current, 'ArcConfiguration > ArcRegistration');
  eq(m.stepGroupOf(null), null, 'simplified nodes have no update/bootstrap groups');
});

test('probeNote: Rebooting / unreachable since <time> only while the node does not answer', function () {
  eq(m.probeNote({ state: 'ok' }), '');
  eq(m.probeNote(null), '');
  eq(m.probeNote({ state: 'unreachable', unreachableSince: '2026-10-11T06:32:00Z' }), 'Rebooting / unreachable since 2026-10-11T06:32:00Z');
  eq(m.probeNote({ state: 'unreachable', unreachableSince: '2026-10-11T06:32:00Z' }, function (t) { return 'T' + t; }), 'Rebooting / unreachable since T' + Date.parse('2026-10-11T06:32:00Z'), 'the page formats the time');
  eq(m.probeNote({ state: 'unreachable' }), 'Rebooting / unreachable since the last poll');
});

test('Ready for Validate only when the back end says every machine is registered', function () {
  var s = provState('arc-registration', 'arc-registration', 'oem-image', [oemNode('node01', 'Registered', 'success')]);
  eq(m.readyForValidate(s), false, 'no flag');
  s.provisioning.readyForValidate = true;
  eq(m.readyForValidate(s), true);
  eq(m.readyForValidate({ phase: 'validation' }), false);
});

test('extensionsTreeOf: the mandatory extensions appear only once the back end shows them (Validate started)', function () {
  eq(m.extensionsTreeOf({ extensions: { shown: false, nodes: [{ name: 'node01' }] } }), []);
  eq(m.extensionsTreeOf({ phase: 'arc-registration' }), [], 'older back ends without the group');
  var tree = m.extensionsTreeOf({ extensions: { shown: true, status: 'running', nodes: [
    { name: 'node01', status: 'error', ready: 1, total: 4, errors: ['AzureEdgeTelemetryAndDiagnostics: failed'],
      tree: [{ id: 'ext.AzureEdgeDeviceManagement', name: 'AzureEdgeDeviceManagement', status: 'success', children: [] }] },
    null
  ] } });
  eq(tree.length, 1);
  eq(tree[0].id, 'ext:node01', 'ids differ from the machine items of the Arc registration panel');
  eq(tree[0].status, 'error');
  eq(tree[0].description, 'Extensions 1 of 4 succeeded');
  eq(tree[0].errors, ['AzureEdgeTelemetryAndDiagnostics: failed']);
  eq(tree[0].children[0].name, 'AzureEdgeDeviceManagement');
});

// ---------------------------------------------------------------- record and replay (S-11)

var fs = require('fs');
var pathMod = require('path');
var FIXTURE = pathMod.join(__dirname, 'fixtures', 'recording-sample.jsonl');
function T(hms) { return Date.parse('2026-10-11T' + hms + 'Z'); }
function sample() { return m.replayLoad(m.replayParseLines(fs.readFileSync(FIXTURE, 'utf8')).events, {}); }
// Key order does not matter for a state: compare with sorted keys.
function canon(v) {
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ':' + canon(v[k]); }).join(',') + '}';
  return JSON.stringify(v);
}
// The state at t the slow way: every state event from the start, keyframes replacing, deltas applied.
function naiveStateAt(rec, t) {
  var s = null;
  rec.states.forEach(function (e) { if (e.t <= t) s = e.full ? JSON.parse(JSON.stringify(e.full)) : m.replayApplyOps(s, e.ops); });
  return s;
}

test('replay: the sample recording loads (two sessions, keyframes and deltas, renumbered log lines)', function () {
  var rec = sample();
  eq(rec.sessions.length, 2);
  eq(rec.start, T('08:00:00'));
  eq(rec.end, T('09:06:00'));
  eq(rec.cluster, 'clus01');
  eq(rec.states.filter(function (s) { return s.full; }).length > 1, true, 'a keyframe after the first');
  eq(rec.states.some(function (s) { return s.ops; }), true, 'deltas');
  eq(rec.lines.map(function (l) { return l.line.seq; }), [1, 2, 3, 4, 5, 6, 7, 8, 9], 'each session numbers from 1; the replay numbers across sessions');
  eq(rec.invalid, 0);
});

test('replay: the state at a time is the keyframe plus the deltas up to that time', function () {
  var rec = sample();
  eq(m.replayStateAt(rec, T('07:59:00')), null, 'before the first state');
  var s = m.replayStateAt(rec, T('08:03:00'));
  eq([s.phase, s.polledAt, s.provisioning.status], ['arc-registration', '2026-10-11T08:00:21Z', 'running']);
  s = m.replayStateAt(rec, T('08:07:00'));
  eq([s.provisioning.status, s.provisioning.readyForValidate], ['success', true]);
  s = m.replayStateAt(rec, T('08:11:00'));
  eq([s.phase, s.validation.tree[0].status, s.validation.tree.length], ['validation', 'running', 2], 'after the restart (keyframe of session 2)');
  s = m.replayStateAt(rec, T('08:13:00'));
  eq([s.validation.tree[0].status, s.validation.tree[1].status, s.current.stepName], ['success', 'running', 'Validate Hardware']);
  s = m.replayStateAt(rec, T('08:35:00'));
  eq([s.phase, s.deployment.tree[0].status, s.deployment.tree[1].status, s.deployment.tree[2].status], ['deployment', 'success', 'running', 'notstarted']);
  s = m.replayStateAt(rec, T('08:52:00'));
  eq([s.phase, s.deployment.tree[2].status], ['failed', 'error']);
  eq(s.deployment.tree[2].errors[0].indexOf('***') > 0, true, 'the recorded error text is masked');
  s = m.replayStateAt(rec, T('08:56:00'));
  eq([s.phase, s.deployment.tree[2].status, s.deployment.tree[2].errors], ['deployment', 'running', []], 'retry: the error is gone');
  s = m.replayStateAt(rec, T('09:59:00'));
  eq(s.phase, 'done', 'after the end: the last state');
});

test('replay: seeking forward, backward and to every recorded time matches applying every event from the start', function () {
  var rec = sample(), times = rec.states.map(function (e) { return e.t; });
  var order = times.concat(times.slice().reverse()).concat([times[5], times[1], times[times.length - 1], times[2]]);
  order.forEach(function (t) {
    eq(canon(m.replayStateAt(rec, t)), canon(naiveStateAt(rec, t)), 'at ' + new Date(t).toISOString());
    eq(canon(m.replayStateAt(rec, t + 999)), canon(naiveStateAt(rec, t + 999)), 'between events');
  });
});

test('replay: a returned state is a copy (the page may change it)', function () {
  var rec = sample();
  var a = m.replayStateAt(rec, T('08:35:00'));
  a.deployment.tree[0].status = 'changed by the page';
  a.__key = 'x';
  eq(m.replayStateAt(rec, T('08:35:00')).deployment.tree[0].status, 'success');
  eq(m.replayStateAt(rec, T('08:36:00')).__key, undefined);
});

test('replay: log lines and the tailer status at a time', function () {
  var rec = sample();
  eq(m.replayLogCountAt(rec, T('07:00:00')), 0);
  eq(m.replayLogCountAt(rec, T('08:12:01')), 4);
  eq(rec.lines[3].line.text, 'WARNING: Validate Hardware: one disk has an older firmware.');
  eq(rec.lines[1].line.text, 'Connecting with password=*** and Bearer ***', 'recorded after masking');
  eq(m.replayLogCountAt(rec, T('09:59:00')), 9);
  eq(m.replayTailerIndexAt(rec, T('08:00:00')), -1);
  eq(rec.tailers[m.replayTailerIndexAt(rec, T('08:09:00'))].tailer.activeFiles, ['C:\\Windows\\System32\\Bootstrap\\Logs\\setup.log']);
  eq(rec.tailers[m.replayTailerIndexAt(rec, T('08:11:00'))].tailer.activeFiles, ['C:\\CloudDeployment\\Logs\\CloudDeployment.log']);
});

test('replay: markers for Arc registration, Validate, Deploy and its main steps, failures, the restart and the end', function () {
  var rec = sample();
  var got = rec.markers.map(function (x) { return [x.kind, x.label, new Date(x.t).toISOString().slice(11, 19)]; });
  eq(got, [
    ['phase', 'Arc registration', '08:00:01'],
    ['session', 'Sonar restarted', '08:10:00'],
    ['phase', 'Validate', '08:10:01'],
    ['phase', 'Deploy', '08:20:01'],
    ['step', 'Before Cloud Deployment', '08:20:01'],
    ['step', 'Deploy Arc infrastructure', '08:30:01'],
    ['step', 'Deploy Arc resource bridge', '08:40:01'],
    ['error', 'Failed: Deployment', '08:50:01'],
    ['error', 'Failed: Deploy Arc resource bridge', '08:50:01'],
    ['phase', 'Deploy (2)', '08:55:01'],
    ['end', 'Succeeded', '09:05:01']
  ]);
  var arc = rec.markers[0], val = rec.markers[2];
  eq(new Date(arc.origin).toISOString(), '2026-10-11T07:50:00.000Z', 'Arc registration began before the recording (earliest machine start)');
  eq(new Date(val.origin).toISOString(), '2026-10-11T08:09:30.000Z', 'Validate began at its first step');
});

test('replay: the position readout is the time since the current phase began ("Deploy +h:mm:ss")', function () {
  var rec = sample();
  eq(m.replayPosition(rec, T('08:00:00')).text, 'Recording +0:00:00');
  eq(m.replayPosition(rec, T('08:05:00')).text, 'Arc registration +0:15:00');
  eq(m.replayPosition(rec, T('08:12:00')).text, 'Validate +0:02:30');
  eq(m.replayPosition(rec, T('08:35:00')).text, 'Deploy +0:15:10');
  eq(m.replayPosition(rec, T('09:05:31')).text, 'Succeeded +0:00:30');
  eq(m.fmtOffset(6130000), '+1:42:10');
  eq(m.fmtOffset(-61000), '-0:01:01');
  eq(m.fmtOffset(0), '+0:00:00');
});

test('replay clock: speed math, speed changes, pause, seek and the end', function () {
  var c = m.clockCreate(0, 3600000, 60);
  eq(m.clockNow(c, 5000), 0, 'paused at the start');
  m.clockPlay(c, 1000);
  eq(m.clockNow(c, 11000), 600000, '10 s at 60x is 10 recorded minutes');
  m.clockSetSpeed(c, 240, 11000);
  eq(m.clockNow(c, 11000), 600000, 'changing the speed keeps the position');
  eq(m.clockNow(c, 12000), 840000, '1 s at 240x is 4 recorded minutes');
  m.clockPause(c, 12000);
  eq(m.clockNow(c, 99999999), 840000, 'paused: the position holds');
  m.clockSetSpeed(c, 1, 13000);
  m.clockPlay(c, 20000);
  eq(m.clockNow(c, 21000), 841000, '1x is real time');
  eq(m.clockNow(c, 1e12), 3600000, 'never past the end');
  eq(m.clockEnded(c, 1e12), true);
  m.clockPause(c, 1e12);
  m.clockPlay(c, 1e12 + 1);
  eq(m.clockNow(c, 1e12 + 1), 0, 'play at the end starts over');
  m.clockSeek(c, -50, 0);
  eq(c.pos, 0, 'seek clamps to the start');
  m.clockSeek(c, 9e9, 0);
  eq(c.pos, 3600000, 'seek clamps to the end');
  m.clockSetSpeed(c, 0, 0);
  eq(c.speed, 1, 'a zero speed is ignored');
});

test('replay transport bar: scrubber fraction and time round-trip, clamped', function () {
  var rec = { start: 1000, end: 11000 };
  eq(m.scrubFraction(rec, 6000), 0.5);
  eq(m.scrubTime(rec, 0.5), 6000);
  eq(m.scrubFraction(rec, 0), 0);
  eq(m.scrubFraction(rec, 99999), 1);
  eq(m.scrubTime(rec, 2), 11000);
  eq(m.scrubFraction({ start: 5, end: 5 }, 5), 0, 'a zero-length recording');
});

test('replay: timers and durations run on the playback clock', function () {
  m.setClock(function () { return T('08:35:00'); });
  try {
    eq(m.nowMs(), T('08:35:00'));
    eq(m.nodeDuration({ status: 'InProgress', start: '2026-10-11T08:29:00Z' }), 360, 'running step: 6 minutes at the playback position');
  } finally { m.setClock(null); }
  eq(Math.abs(m.nowMs() - Date.now()) < 1000, true, 'live again: wall clock');
});

test('replay: delta ops round-trip (set, delete, truncate, append, type change, root)', function () {
  var pairs = [
    [{ a: 1, b: [1, 2, 3], c: { d: 'x', e: true } }, { a: 2, b: [1, 5], c: { d: 'x', f: [1] }, g: null }],
    [{ list: [] }, { list: [{ id: 1 }, { id: 2 }] }],
    [{ v: [1, 2] }, { v: 'now a string' }],
    [{ deep: { er: { est: [0, { x: 1 }] } } }, { deep: { er: { est: [0, { x: 2, y: [] }] } } }],
    [[1, 2], { root: 'replaced' }],
    [{ same: 1 }, { same: 1 }]
  ];
  pairs.forEach(function (p, i) {
    var ops = m.replayDiff(p[0], p[1]);
    eq(canon(m.replayApplyOps(JSON.parse(JSON.stringify(p[0])), ops)), canon(p[1]), 'pair ' + i);
  });
  eq(m.replayDiff({ same: 1 }, { same: 1 }), [], 'no change, no ops');
  eq(m.replayApplyOps({ a: [] }, [['s', ['a', 2], 'x']]), { a: [null, null, 'x'] }, 'an index past the end pads with null');
});

test('replay: invalid recordings and lines', function () {
  var p = m.replayParseLines('{"t":"2026-10-11T08:00:00Z","k":"session"}\nnot json\n\n[1,2]\n{"t":"2026-10-11T08:00:01Z","k":"state","full":{"phase":"validation"}}\n{"t":"2026-10-11T08:00:02Z","k":"sta');
  eq([p.events.length, p.invalid], [2, 3], 'bad lines are counted, not thrown');
  var rec = m.replayLoad(p.events.concat([{ t: 'no time', k: 'state', full: {} }, { t: '2026-10-11T08:00:03Z', k: 'future-kind' }]), {});
  eq(rec.states.length, 1);
  eq(rec.invalid, 1, 'an event without a valid time');
  var threw = '';
  try { m.replayLoad([{ t: '2026-10-11T08:00:00Z', k: 'session' }], {}); } catch (e) { threw = e.message; }
  eq(threw, 'The recording holds no state snapshots.');
  rec = m.replayLoad([{ t: '2026-10-11T08:00:00Z', k: 'session' }, { t: '2026-10-11T08:00:01Z', k: 'state', ops: [['s', ['a'], 1]] },
    { t: '2026-10-11T08:00:02Z', k: 'state', full: { a: 0 } }], {});
  eq([rec.states.length, rec.invalid], [1, 1], 'a delta before the first keyframe of its session is skipped');
  rec = m.replayLoad([{ t: '2026-10-11T08:00:05Z', k: 'session' }, { t: '2026-10-11T08:00:01Z', k: 'state', full: { a: 1 } }], {});
  eq(rec.states[0].t, Date.parse('2026-10-11T08:00:05Z'), 'times never go backwards');
});

test('replay: the built-in demo recording (?demo=1&replay=1) plays the demo deployment', function () {
  var now = Date.parse('2026-10-11T12:00:00Z');
  var events = m.demoRecording(now);
  eq(events[0].k, 'session');
  eq(events[events.length - 1].k, 'end');
  var rec = m.replayLoad(events, {});
  eq(rec.start, now - 64 * 60000);
  eq(rec.end, now);
  eq(rec.states.filter(function (s) { return s.full; }).length > 1, true, 'keyframes and deltas');
  var phases = rec.markers.filter(function (x) { return x.kind === 'phase'; }).map(function (x) { return x.label; });
  eq(phases, ['Arc registration', 'Validate', 'Deploy']);
  eq(rec.markers.filter(function (x) { return x.kind === 'step'; }).map(function (x) { return x.label; }),
    ['Run pre-deployment checks', 'Configure security baseline', 'Deploy Arc infrastructure components', 'Create cluster']);
  var end = m.replayStateAt(rec, now), live = m.demoDeploymentSample(now).state;
  eq([end.phase, end.current.stepPath], [live.phase, live.current.stepPath], 'the end of the replay is the live demo');
  eq(end.deployment.tree[0].children.map(function (c) { return c.status; }), live.deployment.tree[0].children.map(function (c) { return c.status; }));
  var mid = m.replayStateAt(rec, now - 50 * 60000);
  eq([mid.phase, mid.validation.tree[0].children[3].status, mid.deployment.tree.length], ['validation', 'running', 0], '50 minutes ago: validating storage');
  eq(m.replayLogCountAt(rec, now) > m.replayLogCountAt(rec, now - 30 * 60000), true);
});

// ---------------------------------------------------------------- hardening 2610: lag, Environment Checker stage, update track

test('liveNotes: nothing to say for a plain deployment state', function () {
  eq(m.liveNotes({ phase: 'validation', lag: { detected: false }, environmentChecker: { stage: 'none' }, update: null, track: 'auto' }), []);
  eq(m.liveNotes(null), []);
});

test('liveNotes: Azure lagging behind the node is labelled with where it was read', function () {
  var n = m.liveNotes({ lag: { detected: true, kind: 'deploy-not-reported', source: 'node log', message: 'Azure still shows Deploy not started, but the seed node is running BareMetal:X.' } });
  eq(n.length, 1);
  eq(n[0].kind, 'lag');
  eq(/read from node log, not from the Azure step list/.test(n[0].text), true);
});

test('liveNotes: the limited and full Environment Checker stages show with their source; cloud deployment does not repeat itself', function () {
  var limited = m.liveNotes({ environmentChecker: { stage: 'limited', label: 'Limited Environment Checker run', source: 'node log' } });
  eq(limited.map(function (x) { return x.text; }), ['Limited Environment Checker run (from the node log)']);
  var starting = m.liveNotes({ environmentChecker: { stage: 'starting', label: 'Deploy mode started', source: 'Learn' } });
  eq(starting.map(function (x) { return x.text; }), ['Deploy mode started (Learn)']);
  eq(m.liveNotes({ environmentChecker: { stage: 'cloud-deployment', label: 'Cloud deployment', source: 'Azure steps' } }), []);
});

test('liveNotes: the update, add-node and repair tracks are marked unverified against a live run', function () {
  var u = m.liveNotes({ update: { phase: 'installing', active: { version: '12.2610.1002.4' } } });
  eq(u.length, 1);
  eq(/12\.2610\.1002\.4: installing/.test(u[0].text) && /unverified against a live run/.test(u[0].text), true);
  eq(m.liveNotes({ update: { phase: 'idle' } }), []);
  eq(m.liveNotes({ update: { phase: 'available' } }), [], 'an update that is only available is not an operation in progress');
  var t = m.liveNotes({ track: 'add-node' });
  eq(/^Add node \(set in the config\)/.test(t[0].text) && /Unverified against a live run/.test(t[0].text), true);
  eq(m.liveNotes({ track: 'repair' })[0].text.indexOf('Repair'), 0);
});

test('the update, add-node and repair phases have labels and a header chip', function () {
  eq(m.phaseLabel('update'), 'Update');
  eq(m.phaseLabel('add-node'), 'Add node');
  eq(m.phaseChipText({ phase: 'failed', activePhase: 'update' }), 'Failed: Update');
  eq(m.phaseChipText({ phase: 'update', activePhase: 'update' }), 'Update');
});

// ---------------------------------------------------------------- S-12: the one-line Log access status

test('guidanceSummary: tailing, with the account from the guidance and the age of the last line', function () {
  var now = Date.parse('2026-10-11T12:00:00Z');
  m.setClock(function () { return now; });
  var s = m.guidanceSummary({ state: 'connected', node: 'node-01' }, { account: 'The deployment local admin (localAdminUserName): non-built-in. Learn documents no separate LCM user.' }, now - 90000, true);
  eq(s, 'Log access: Tailing node node-01 \u00b7 account: The deployment local admin (localAdminUserName): non-built-in. \u00b7 last line 1 min ago');
  m.setClock(null);
});

test('guidanceSummary: a tailer that failed says so, and the credential in use wins over the guidance', function () {
  eq(m.guidanceSummary({ state: 'unavailable', node: 'node-01', credential: 'user-01' }, { account: 'x' }, NaN, true), 'Log access: Tailer unavailable (node node-01) \u00b7 as user-01');
  eq(m.guidanceSummary(null, null, NaN, false), 'Log access: Tailer not started');
  eq(m.guidanceSummary({ state: 'connected' }, null, NaN, true), 'Log access: Tailing the seed node \u00b7 no line yet');
});

process.stdout.write(JSON.stringify(cases));
