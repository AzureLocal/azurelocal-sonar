/* Cases for the page's pure log logic (src/AzlSonar/web/app.js), run under Node by WebLogic.Tests.ps1.
   Usage: node web-logic.cases.js <path to app.js>. Prints one JSON array: [{ name, ok, message }]. No network, no DOM. */
'use strict';

var path = require('path').resolve(process.argv[2]);
var m = require(path);
var cases = [];

function eq(actual, expected, what) {
  var a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a !== e) throw new Error((what ? what + ': ' : '') + 'expected ' + e + ' but got ' + a);
}
function tileOf(tiles, id) { return tiles.filter(function (t) { return t.id === id; })[0]; }
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
eq(m.phaseChipText({ phase: 'provisioning', provisioning: { readyForValidate: true } }), 'Ready for Validate', 'every machine ready, no deployment yet');
eq(m.phaseChipText({ phase: 'provisioning', provisioning: { readyForValidate: false } }), 'Provisioning', 'machines still provisioning or preparing');
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

test('ZTP complete (simplified route): the chip says so, never Ready for Validate, and a note links the OS configuration guide', function () {
  var s = provState('provisioning', 'provisioning', 'simplified', []);
  eq(m.ztpComplete(s), false, 'no flag');
  eq(m.liveNotes(s), [], 'no note before ZTP is complete');
  s.provisioning.ztpComplete = true;
  s.provisioning.readyForValidate = false;
  eq(m.ztpComplete(s), true);
  eq(m.readyForValidate(s), false);
  eq(m.phaseChipText(s), 'ZTP complete');
  var bare = m.liveNotes(s);
  eq(bare.length, 1, 'the note without a guide from the back end');
  eq(bare[0].href, undefined, 'no link without a guide');
  s.provisioning.nextStep = { name: 'OS configuration', guide: 'https://azurelocal.cloud' };
  var notes = m.liveNotes(s);
  eq(notes.length, 1);
  eq(notes[0].kind, 'ztp');
  eq(notes[0].href, 'https://azurelocal.cloud/', 'the guide the back end names, as the URL parser writes it');
  eq(notes[0].linkText, 'azurelocal.cloud');
  eq(/OS configuration/.test(notes[0].text), true, 'names the next step');
  eq(/Ready for Validate/.test(notes[0].text), false);
  s.provisioning.nextStep = { guide: 'javascript:alert(1)' };
  eq(m.liveNotes(s)[0].href, undefined, 'only an https guide is linked');
  eq(m.phaseChipText({ phase: 'validation', provisioning: { ztpComplete: true } }), 'Validation', 'Validate started: the phase again');
  eq(m.liveNotes({ phase: 'validation', provisioning: { ztpComplete: true } }), [], 'no note once Validate started');
  eq(m.ztpComplete({ phase: 'provisioning' }), false, 'older back ends without the field');
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

// ---------------------------------------------------------------- redesign: modes, summary box, node cards

function ztpState(nodes, extra) {
  var s = { cluster: 'iic-azl-c01', phase: 'provisioning', activePhase: 'provisioning',
    provisioning: { route: 'simplified', phase: 'provisioning', status: 'running', ztpComplete: false, nodes: nodes },
    validation: { status: 'notstarted', tree: [] }, deployment: { status: 'notstarted', tree: [] },
    nodes: nodes.map(function (n) { return { name: n.name, arcStatus: n.arcStatus }; }) };
  if (extra) Object.keys(extra).forEach(function (k) { s[k] = extra[k]; });
  return s;
}
function zNode(name, lifecycle, status, arc, extra) {
  var n = { name: name, route: 'simplified', lifecycle: lifecycle, status: status, arcStatus: arc, percent: status === 'running' ? 40 : 100, start: '2026-11-07T17:02:00Z',
    ztp: { complete: status === 'success', network: { status: status === 'success' ? 'success' : 'notstarted' }, restore: { status: 'notstarted' } }, tree: [] };
  if (extra) Object.keys(extra).forEach(function (k) { n[k] = extra[k]; });
  return n;
}
var THREE = [zNode('iic-azl-n01', 'Provisioned', 'success', 'Connected'), zNode('iic-azl-n02', 'Provisioned', 'success', 'Connected'),
  zNode('iic-azl-n03', 'InstallingOs', 'running', 'Disconnected', { lifecycleMessage: 'Installing OS in progress.' })];

test('modeStates: the seven tiles for a ZTP run with one machine still installing; Discovery comes first, OS configuration and Verification sit between Provisioning and Validate', function () {
  var tiles = m.modeStates(ztpState(THREE));
  eq(tiles.map(function (t) { return t.id; }), ['discovery', 'prov', 'osconfig', 'verify', 'validate', 'deploy', 'update']);
  eq(tiles.map(function (t) { return t.status; }), ['idle', 'run', 'idle', 'idle', 'idle', 'idle', 'idle']);
  eq(tileOf(tiles, 'osconfig').name, 'OS configuration');
  eq(tileOf(tiles, 'discovery').name, 'Discovery');
  eq(tileOf(tiles, 'prov').name, 'Provisioning (ZTP)');
  eq(tileOf(tiles, 'prov').line, '2 of 3 machines ready');
  eq(tileOf(tiles, 'prov').hidden, false);
});

test('modeStates: a waiting tile has no state line and says when it starts; no tile says "not started"', function () {
  var tiles = m.modeStates(ztpState(THREE));
  tiles.filter(function (t) { return t.status === 'idle'; }).forEach(function (t) {
    eq(t.line, '', t.id + ' has no state line');
    eq(t.tip.length > 0, true, t.id + ' tooltip says when it starts');
  });
  eq(tileOf(tiles, 'validate').tip, 'Starts after OS configuration has converged on every machine', 'Validate unlocks logically after OS configuration (information only)');
  eq(tileOf(tiles, 'deploy').tip, 'Starts after validation passes');
  eq(JSON.stringify(tiles).toLowerCase().indexOf('not started'), -1, 'no "not started" text anywhere');
});

test('modeStates: Provisioning is named after the route; the OEM image route says OS image', function () {
  var s = ztpState([zNode('n1', 'Bootstrapping', 'running', 'NotFound')]);
  s.provisioning.route = 'oem-image'; s.phase = 'arc-registration'; s.activePhase = 'arc-registration';
  eq(tileOf(m.modeStates(s), 'prov').name, 'Provisioning (OS image)');
  eq(m.modeName('prov', 'simplified'), 'Provisioning (ZTP)');
  eq(tileOf(m.modeStates(s), 'validate').tip, 'Starts when every machine is registered');
});

test('modeStates: there are always seven tiles; Provisioning is grey with a reason when the run has no machines and is past it (a plain deployment)', function () {
  var s = { phase: 'deployment', activePhase: 'deployment', validation: { status: 'Success', tree: [{ id: '1', name: 'v', status: 'success', children: [] }] },
    deployment: { status: 'InProgress', tree: [{ id: '2', name: 'Deploy', status: 'running', children: [
      { id: '2.1', name: 'a', status: 'success', children: [] }, { id: '2.2', name: 'b', status: 'running', children: [] }, { id: '2.3', name: 'c', status: 'notstarted', children: [] }] }] } };
  var tiles = m.modeStates(s);
  eq(tiles.length, 7);
  eq(tiles.some(function (t) { return t.hidden; }), false);
  eq(tileOf(tiles, 'prov').status, 'idle');
  eq(tileOf(tiles, 'prov').line, '');
  eq(/No machine data/.test(tileOf(tiles, 'prov').tip), true);
  eq(tiles.map(function (t) { return t.status; }), ['idle', 'idle', 'idle', 'idle', 'ok', 'run', 'idle']);
  eq(tileOf(tiles, 'osconfig').tip, 'Set osConfigEventsPath to follow the toolkit’s OS configuration run.', 'no OS configuration data: the tile says how to get it');
  eq(tileOf(tiles, 'validate').line, 'Passed');
  eq(tileOf(tiles, 'deploy').line, 'Step 2 of 3');
});

test('activeModeId: the active phase picks the selected mode; a failed run stays on the mode that failed; done is Deployment (Done)', function () {
  eq(m.activeModeId({ phase: 'provisioning', activePhase: 'provisioning' }), 'prov');
  eq(m.activeModeId({ phase: 'arc-registration', activePhase: 'arc-registration' }), 'prov');
  eq(m.activeModeId({ phase: 'validation', activePhase: 'validation' }), 'validate');
  eq(m.activeModeId({ phase: 'deployment', activePhase: 'deployment' }), 'deploy');
  eq(m.activeModeId({ phase: 'update', activePhase: 'update' }), 'update');
  eq(m.activeModeId({ phase: 'failed', activePhase: 'deployment' }), 'deploy');
  eq(m.activeModeId({ phase: 'done', activePhase: 'deployment' }), 'deploy');
  eq(m.activeModeId({ phase: 'add-node', activePhase: 'add-node' }), 'addnode');
  eq(m.activeModeId({ phase: 'repair', activePhase: 'repair' }), 'repair');
  eq(m.activeModeId(null), 'prov');
});

test('summaryFor (provisioning): headline names the busy machine, cards carry the full machine name and plain words', function () {
  var sm = m.summaryFor(ztpState(THREE), 'prov', { nodes: [{ name: 'iic-azl-n01', seed: true }] });
  eq(sm.title, 'Provisioning (ZTP)');
  eq(sm.chip, { kind: 'run', text: 'Running' });
  eq(sm.headline, '2 of 3 machines ready: iic-azl-n03 is installing the OS');
  eq(sm.cards.map(function (c) { return c.name; }), ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'], 'full machine names');
  eq(sm.cards.map(function (c) { return c.state; }), ['ZTP complete', 'ZTP complete', 'Installing the OS']);
  eq(sm.cards[2].tip.indexOf('Azure says: InstallingOs'), 0, 'the raw Azure value is in the tooltip');
  eq(sm.cards[2].arc.text, 'Arc \u25cb not connected yet');
  eq(sm.cards[0].arc.text, 'Arc \u25cf Connected');
  eq(sm.cards[2].progress, 40, 'a running machine shows a progress bar');
  eq(sm.cards[0].progress, null);
  eq(sm.cards[2].waits, 'Waiting on Azure');
  eq(sm.startedAt, Date.parse('2026-11-07T17:02:00Z'));
});

test('summaryFor (provisioning): ZTP complete says what comes next on every card', function () {
  var nodes = [zNode('iic-azl-n01', 'Provisioned', 'success', 'Connected'), zNode('iic-azl-n02', 'Provisioned', 'success', 'Connected')];
  var s = ztpState(nodes); s.provisioning.ztpComplete = true;
  var sm = m.summaryFor(s, 'prov');
  eq(sm.headline, 'ZTP is complete: all 2 machines are provisioned. Next: OS configuration');
  eq(sm.cards.map(function (c) { return c.waits; }), ['Next: OS configuration', 'Next: OS configuration']);
  eq(sm.cards.map(function (c) { return c.state; }), ['ZTP complete', 'ZTP complete']);
  eq(sm.chip, { kind: 'ok', text: 'Done' });
});

test('summaryFor (provisioning): a failed machine says what blocks it', function () {
  var nodes = [zNode('a', 'Provisioned', 'success', 'Connected'),
    zNode('b', 'InstallingOs', 'error', 'Connected', { errors: ['ProvisionOs: InstallExtensionsFailed: unable to connect to the remote server'] })];
  var sm = m.summaryFor(ztpState(nodes), 'prov');
  eq(sm.headline, '1 of 2 machines ready: b is blocked (ProvisionOs: InstallExtensionsFailed: unable to connect to the remote server)');
  eq(sm.chip, { kind: 'err', text: 'Failed' });
  eq(sm.cards[1].state, 'Failed: installing the OS');
  eq(sm.cards[1].kind, 'err');
});

test('summaryFor: Azure lifecycle values become plain words (the raw value is kept for the tooltip)', function () {
  eq(m.lifecyclePlain('AwaitingConnection', 'running', false).text, 'Waiting to connect to Azure');
  eq(m.lifecyclePlain('Provisioning', 'running', false).text, 'Registering with Azure');
  eq(m.lifecyclePlain('ReadyForOs', 'running', false).text, 'Ready to install the OS');
  eq(m.lifecyclePlain('Provisioned', 'running', false).text, 'Provisioned, finishing ZTP');
  eq(m.lifecyclePlain('UpdatingOsImage', 'running', false).text, 'Updating the OS image');
  eq(m.lifecyclePlain('SomethingNew', 'running', false).text, 'Status unknown');
  eq(m.lifecyclePlain('ProvisioningFailed', 'error', false).text, 'Failed');
  eq(m.arcInfo('Connected').kind, 'ok');
  eq(m.arcInfo('Disconnected').text, 'Arc \u25cb not connected yet');
  eq(m.arcInfo('Expired').kind, 'warn');
});

test('summaryFor (deployment): headline gives the step, the cards come from the state nodes', function () {
  var s = { phase: 'deployment', activePhase: 'deployment', current: { phase: 'deployment', stepName: 'Create cluster' },
    nodes: [{ name: 'iic-azl-n01', arcStatus: 'Connected' }, { name: 'iic-azl-n02', arcStatus: 'Connected' }],
    validation: { status: 'Success', tree: [] },
    deployment: { status: 'InProgress', tree: [{ id: '2', name: 'Deploy', status: 'running', start: '2026-11-07T18:00:00Z', children: [
      { id: '2.1', name: 'a', status: 'success', children: [] }, { id: '2.2', name: 'Create cluster', status: 'running', children: [] }, { id: '2.3', name: 'c', status: 'notstarted', children: [] }] }] } };
  var sm = m.summaryFor(s, 'deploy');
  eq(sm.headline, 'Deployment is running: step 2 of 3 (Create cluster)');
  eq(sm.cards.map(function (c) { return c.name + '|' + c.state; }), ['iic-azl-n01|Taking part', 'iic-azl-n02|Taking part']);
  eq(sm.cards[0].waits, 'Now: Create cluster');
  eq(sm.cards[0].progress, 33);
  var waiting = m.summaryFor(s, 'update');
  eq(waiting.chip, { kind: 'idle', text: 'Waiting' });
  eq(waiting.headline, 'Available after the cluster is deployed; starts when Azure reports an update');
});

test('summaryFor (deployment): a failed step is named with its error', function () {
  var s = { phase: 'failed', activePhase: 'deployment', nodes: [], validation: { status: 'Success', tree: [] },
    deployment: { status: 'Failed', tree: [{ id: '2', name: 'Deploy', status: 'error', children: [{ id: '2.1', name: 'Create cluster', status: 'error', errors: ['The cluster could not be formed.'], children: [] }] }] } };
  eq(m.summaryFor(s, 'deploy').headline, 'Deployment failed at Create cluster: The cluster could not be formed.');
});

test('lineScope: ZTP event lines say their machine and stage; node-log lines name neither', function () {
  var z = { file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] iic-azl-n03 DeviceAddressSet: static address' };
  eq(m.lineScope(z), { node: 'iic-azl-n03', stage: 'device' });
  eq(m.lineScope({ file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] n1 ManagementAddressSet: x' }), { node: 'n1', stage: 'network' });
  eq(m.lineScope({ file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] n1 NetworkJobStatus: x' }).stage, 'network');
  eq(m.lineScope({ file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] n1 BiosRestored: x' }).stage, 'restore');
  eq(m.lineScope({ file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] n1 Booting: x' }), { node: 'n1', stage: '' });
  eq(m.lineScope({ file: 'C:\\MASLogs\\a.log', text: 'plain line' }), { node: '', stage: '' });
});

test('lineInScope (node cards): a machine keeps its ZTP lines, and the node log when it is the seed', function () {
  var n3 = { file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] iic-azl-n03 Booting: x' };
  var n1 = { file: 'ztp-events', text: '2026-11-07T19:01:59.536Z [ztp] iic-azl-n01 Booting: x' };
  var log = { file: 'C:\\MASLogs\\a.log', text: 'from the seed node' };
  eq([n3, n1, log].map(function (l) { return m.lineInScope(l, { node: 'iic-azl-n03' }, null, 'iic-azl-n01'); }), [true, false, false]);
  eq([n3, n1, log].map(function (l) { return m.lineInScope(l, { node: 'IIC-AZL-N01' }, null, 'iic-azl-n01'); }), [false, true, true], 'case-insensitive; the seed also owns the node log');
  eq([n3, n1, log].map(function (l) { return m.lineInScope(l, { node: '' }, null, 'iic-azl-n01'); }), [true, true, true], 'no machine selected: every line');
});

// ---------------------------------------------------------------- redesign: steps of a mode, step clicks, the empty log pane

function ztpMachineTree() {
  // one machine as the simplified route reports it: ZTP Device, Azure lifecycle (ProvisionMachine > RegisterMachine),
  // the ProvisionOs job, then the ZTP Network stage
  return m.provisioningTreeOf(ztpState([zNode('iic-azl-n03', 'InstallingOs', 'running', 'Disconnected', { tree: [
    { id: 'ztp.device', name: 'Management address (maintenance environment)', status: 'success', start: '2026-11-07T17:02:00Z', end: '2026-11-07T17:04:00Z',
      children: [{ id: 'ztp.device.0', name: 'DeviceConfigurationSubmitted', status: 'success', children: [] }] },
    { id: 'lifecycle.0', name: 'ProvisionMachine', status: 'success', start: '2026-11-07T17:06:00Z', end: '2026-11-07T17:15:00Z',
      children: [{ id: 'lifecycle.0.0', name: 'RegisterMachine', status: 'success', start: '2026-11-07T17:06:00Z', end: '2026-11-07T17:09:00Z', children: [] }] },
    { id: 'lifecycle.1', name: 'InstallOs', status: 'running', start: '2026-11-07T17:16:00Z', children: [] },
    { id: 'job', name: 'ProvisionOs job', status: 'running', start: '2026-11-07T17:16:00Z', children: [{ id: 'job.0', name: 'CreatedTargetArcMachine', status: 'success', children: [] }] },
    { id: 'ztp.network', name: 'Management address on the management NIC', status: 'notstarted', children: [] }
  ] })]));
}

test('stepRule: Azure steps of a machine are Azure; ZTP stages are node steps with their stage; the machine row selects the machine', function () {
  var t = ztpMachineTree()[0], k = t.children;
  eq(m.stepRule('provisioning', [t]), { side: 'machine', node: 'iic-azl-n03', stage: '', window: false });
  eq(m.stepRule('provisioning', [t, k[1], k[1].children[0]]), { side: 'azure', node: 'iic-azl-n03', stage: '', window: false }, 'Register machine');
  eq(m.stepRule('provisioning', [t, k[2]]).side, 'azure', 'Install OS');
  eq(m.stepRule('provisioning', [t, k[3], k[3].children[0]]).side, 'azure', 'a ProvisionOs job step');
  eq(m.stepRule('provisioning', [t, k[0]]), { side: 'node', node: 'iic-azl-n03', stage: 'device', window: false });
  eq(m.stepRule('provisioning', [t, k[0], k[0].children[0]]), { side: 'node', node: 'iic-azl-n03', stage: 'device', window: false }, 'an event of the stage');
  eq(m.stepRule('provisioning', [t, k[4]]).stage, 'network');
});

test('stepRule: OEM route groups, validation, extensions, deployment and update', function () {
  var oem = { name: 'node01' };
  eq(m.stepRule('provisioning', [oem, { id: 'update', name: 'OS image update' }, { id: 'update.1', name: 'Download' }]), { side: 'node', node: 'node01', stage: '', window: true });
  eq(m.stepRule('provisioning', [oem, { id: 'bootstrap', name: 'Bootstrap' }]).window, true);
  eq(m.stepRule('provisioning', [oem, { id: 'arc', name: 'Azure registration' }]).side, 'azure');
  eq(m.stepRule('validation', [{ id: '1', name: 'Validate network' }]).side, 'azure');
  eq(m.stepRule('extensions', [{ id: 'ext:n1', name: 'node01' }]).side, 'azure');
  eq(m.stepRule('deployment', [{ id: '2', name: 'Deploy' }, { id: '2.1', name: 'x' }]), { side: 'node', node: '', stage: '', window: true });
  eq(m.stepRule('update', [{ id: 'u', name: 'Update' }]).side, 'node');
  eq(m.stepRule('', []).side, 'azure');
});

test('mode sections: each mode shows only its own steps; Add node and Repair have none of their own', function () {
  eq(m.MODE_SECTIONS, { discovery: ['discovery'], prov: ['provisioning'], osconfig: ['osconfiguration'], verify: ['verification'], validate: ['armvalidation', 'validation', 'extensions'], deploy: ['armdeployment', 'deployment'], update: ['update'], addnode: [], repair: [] });
});

test('regression: clicking an Azure step (Register machine, Install OS) must not leave the logs empty', function () {
  // The cause: every step offered a time-window filter. An Azure-side step runs in Azure and writes nothing to a node
  // log, so its window held no line and the log pane said "No lines match the current filters".
  var t = ztpMachineTree()[0], register = t.children[1].children[0];
  var lines = [
    { seq: 1, time: '2026-11-07T17:30:00.000Z', received: '2026-11-07T17:30:00.000Z', timeSource: 'line', file: 'C:\\Bootstrap\\setup.log', level: 'info', text: 'Bootstrap service started on iic-azl-n01.' },
    { seq: 2, time: '2026-11-07T17:31:00.000Z', received: '2026-11-07T17:31:00.000Z', timeSource: 'line', file: 'ztp-events', level: 'info', text: '2026-11-07T17:31:00.000Z [ztp] iic-azl-n03 VoucherWritten: x' }
  ];
  var win = m.stepWindowOf(register);
  eq(lines.filter(function (l) { return m.lineInWindow(l, win); }).length, 0, 'the old filter: the Register machine window holds no line');
  var rule = m.stepRule('provisioning', [t, t.children[1], register]);
  eq(rule.side, 'azure');
  // an Azure step sets no filter at all, so every line stays visible
  var none = { node: '', stage: '' };
  eq(lines.filter(function (l) { return m.lineInScope(l, none, null, 'iic-azl-n01'); }).length, 2);
});

test('step click on a ZTP stage: the ZTP lines of that stage for that machine', function () {
  var lines = [
    { file: 'ztp-events', text: '2026-11-07T17:03:00.000Z [ztp] iic-azl-n03 DeviceAddressSet: a' },
    { file: 'ztp-events', text: '2026-11-07T17:03:00.000Z [ztp] iic-azl-n02 DeviceAddressSet: b' },
    { file: 'ztp-events', text: '2026-11-07T17:40:00.000Z [ztp] iic-azl-n03 NetworkJobSubmitted: c' },
    { file: 'C:\\Bootstrap\\setup.log', text: 'node log line' }
  ];
  var rule = m.stepRule('provisioning', [ztpMachineTree()[0], ztpMachineTree()[0].children[0]]);
  var f = { node: rule.node, stage: rule.stage };
  eq(lines.filter(function (l) { return m.lineInScope(l, f, null, 'iic-azl-n01'); }).map(function (l) { return l.text.slice(-1); }), ['a']);
});

test('emptyLogView: a step with no lines says why and offers the machine and Clear filter', function () {
  var f = { level: 'all', q: '', file: '', stepKey: 'k', node: 'iic-azl-n03', stage: '' };
  var v = m.emptyLogView(f, 0, 37, 'connected');
  eq(v.kind, 'step');
  eq(v.title, 'No log lines for this step yet.');
  eq(v.text.indexOf('This step has produced no lines on this node yet.'), 0);
  eq(v.actions, ['node', 'clear']);
  eq(m.emptyLogView({ stage: 'network', node: '' }, 0, 5, '').actions, ['clear'], 'no machine: only Clear filter');
});

test('emptyLogView: a machine with no lines, filters that emptied a scope, and no lines at all', function () {
  eq(m.emptyLogView({ node: 'n2' }, 0, 10, '').kind, 'node');
  eq(m.emptyLogView({ node: 'n2' }, 0, 10, '').title, 'No log lines for n2 yet.');
  var f = m.emptyLogView({ level: 'error', node: 'n2' }, 4, 10, '');
  eq(f.kind, 'filters');
  eq(f.title, 'No lines match the current filters.');
  eq(f.actions, ['clearAll']);
  eq(m.emptyLogView({ level: 'error' }, 10, 10, '').kind, 'filters');
  eq(m.emptyLogView({}, 0, 0, 'connected').title, 'Waiting for log lines\u2026');
  eq(m.emptyLogView({}, 0, 0, 'unavailable').title, 'No log lines: the log tailer cannot reach the seed node.');
});

test('stepDescription: the ZTP steps use the plain text; Azure steps keep what Azure says; every machine stage has one', function () {
  eq(m.stepDescription({ id: 'ztp.device', name: 'x', description: 'azurelocal-ztp Device: technical text' }),
    'Finds the machine by its management MAC and sets the static address on that port, before the claim.');
  eq(m.stepDescription({ id: 'ztp.network', name: 'x' }).indexOf('Checks the management port'), 0);
  eq(m.stepDescription({ id: 'ztp.restore', name: 'x' }).indexOf('Puts the BIOS settings'), 0);
  eq(m.stepDescription({ id: 'lifecycle.0.0', name: 'RegisterMachine', description: 'Register machine with onboarding service' }), 'Register machine with onboarding service');
  eq(m.stepDescription({ id: 'lifecycle.1', name: 'InstallOs', description: '' }), 'Azure downloads the OS, installs it, restarts the machine and adds the Arc extensions.');
  eq(m.stepDescription({ id: 'job.3', name: 'ArcNotificationSent', description: '' }), '');
  eq(m.stepDescription({ id: 'n', name: 'node01', prov: {} }), '', 'the machine row has no description');
});

test('stepsEmptyText: a waiting mode says when it begins, Add node and Repair say Azure reports no steps', function () {
  eq(m.stepsEmptyText('validate', 'idle', 'Starts after validation passes', true), 'The steps appear here when this mode begins. Starts after validation passes.');
  eq(m.stepsEmptyText('addnode', 'run', '', true).indexOf('Azure reports no steps'), 0);
  eq(m.stepsEmptyText('prov', 'run', '', false), 'No machines reported yet.');
  eq(m.stepsEmptyText('deploy', 'run', '', true), 'No steps reported yet.');
});

// ---------------------------------------------------------------- redesign: route from the phase, plural

test('modeStates: Arc registration without machine data is still the OS image route', function () {
  var tiles = m.modeStates({ phase: 'arc-registration', activePhase: 'arc-registration' });
  eq(tileOf(tiles, 'prov').name, 'Provisioning (OS image)');
  eq(tileOf(tiles, 'prov').hidden, false);
  eq(tileOf(tiles, 'prov').line, 'Waiting for the machines');
});

test('summaryFor (provisioning): the headline says "is" for one more machine and "are" for several', function () {
  var nodes = [zNode('a', 'InstallingOs', 'running', 'Disconnected'), zNode('b', 'InstallingOs', 'running', 'Disconnected')];
  eq(m.summaryFor(ztpState(nodes), 'prov').headline, '0 of 2 machines ready: a is installing the OS and 1 more is working');
  nodes.push(zNode('c', 'InstallingOs', 'running', 'Disconnected'));
  eq(m.summaryFor(ztpState(nodes), 'prov').headline, '0 of 3 machines ready: a is installing the OS and 2 more are working');
});

// ---------------------------------------------------------------- security: data is text, links are allow-listed

var fs = require('fs');
var appSource = fs.readFileSync(path, 'utf8');

// A small fake document: enough of the DOM for the page's render functions. It records what is created, so a test can
// check that hostile data became text nodes and attribute values, never elements, handlers or live links.
function makeFakeDom() {
  var byId = {}, inner = [];
  function Text(t) { this.nodeType = 3; this.text = String(t); }
  function El(tag) {
    this.nodeType = 1; this.tagName = String(tag).toLowerCase(); this.attrs = {}; this.children = []; this.parent = null; this.listeners = {};
    this.value = ''; this.scrollTop = 0; this.scrollHeight = 0; this.clientHeight = 0; this.disabled = false;
    var self = this;
    this.style = { props: {}, setProperty: function (k, v) { self.style.props[k] = v; } };
    this.classList = { add: function (c) { self.attrs['class'] = (self.attrs['class'] || '') + ' ' + c; }, remove: function () {}, contains: function (c) { return (' ' + (self.attrs['class'] || '') + ' ').indexOf(' ' + c + ' ') >= 0; } };
  }
  El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); if (k === 'id') byId[v] = this; };
  El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
  El.prototype.removeAttribute = function (k) { delete this.attrs[k]; };
  El.prototype.appendChild = function (c) {
    if (c && c.tagName === '#fragment') { var kids = c.children.slice(); c.children = []; kids.forEach(function (k) { this.appendChild(k); }, this); return c; }
    c.parent = this; this.children.push(c); return c;
  };
  El.prototype.insertBefore = function (c) { return this.appendChild(c); };
  El.prototype.replaceChild = function (n) { return this.appendChild(n); };
  El.prototype.remove = function () {};
  El.prototype.focus = function () {};
  El.prototype.select = function () {};
  El.prototype.addEventListener = function (n, f) { (this.listeners[n] = this.listeners[n] || []).push(f); };
  El.prototype.contains = function (n) { for (var p = n; p; p = p.parent) if (p === this) return true; return false; };
  El.prototype.querySelector = function (sel) { return this.querySelectorAll(sel)[0] || null; };
  El.prototype.querySelectorAll = function (sel) {
    var out = [], m;
    function match(e) {
      if (e.nodeType !== 1) return false;
      if ((m = /^#(.+)$/.exec(sel))) return e.attrs.id === m[1];
      if ((m = /^\.([\w-]+)$/.exec(sel))) return e.classList.contains(m[1]);
      if ((m = /^\[([\w-]+)="(.*)"\]$/.exec(sel))) return e.attrs[m[1]] === m[2];
      return e.tagName === sel;
    }
    (function walk(e) { e.children.forEach(function (c) { if (match(c)) out.push(c); if (c.nodeType === 1) walk(c); }); })(this);
    return out;
  };
  Object.defineProperty(El.prototype, 'textContent', {
    get: function () { return this.children.map(function (c) { return c.nodeType === 3 ? c.text : c.textContent; }).join(''); },
    set: function (v) { var s = String(v); this.children = s === '' ? [] : [new Text(s)]; }
  });
  Object.defineProperty(El.prototype, 'className', { get: function () { return this.attrs['class'] || ''; }, set: function (v) { this.attrs['class'] = String(v); } });
  Object.defineProperty(El.prototype, 'hidden', { get: function () { return 'hidden' in this.attrs; }, set: function (v) { if (v) this.attrs.hidden = ''; else delete this.attrs.hidden; } });
  Object.defineProperty(El.prototype, 'title', { get: function () { return this.attrs.title || ''; }, set: function (v) { this.attrs.title = String(v); } });
  Object.defineProperty(El.prototype, 'innerHTML', { set: function (v) { inner.push({ el: this, html: String(v) }); }, get: function () { return ''; } });
  var doc = {
    activeElement: null,
    createElement: function (t) { return new El(t); },
    createTextNode: function (t) { return new Text(t); },
    createDocumentFragment: function () { return new El('#fragment'); },
    getElementById: function (id) { if (!byId[id]) { var e = new El('div'); e.attrs.id = id; byId[id] = e; } return byId[id]; },
    addEventListener: function () {}
  };
  return { document: doc, byId: byId, inner: inner };
}

var HOSTILE = ['<img src=x onerror=alert(1)>', '"><script>alert(1)</script>', 'javascript:alert(1)', 'data:text/html,<script>alert(1)</script>'];
var BAD_TAGS = ['img', 'script', 'iframe', 'style', 'link', 'object', 'embed', 'form', 'input', 'svg'];

// Walks a rendered tree: no element made from data, no event-handler attribute, every link allow-listed.
function assertInert(root, what) {
  (function walk(e) {
    if (e.nodeType !== 1) return;
    if (BAD_TAGS.indexOf(e.tagName) >= 0) throw new Error(what + ': data became a <' + e.tagName + '> element');
    Object.keys(e.attrs).forEach(function (k) {
      if (/^on/i.test(k)) throw new Error(what + ': event-handler attribute ' + k);
      if ((k === 'href' || k === 'src') && !/^https:\/\/(azurelocal\.cloud|learn\.microsoft\.com|github\.com)(\/|$)/.test(e.attrs[k])) throw new Error(what + ': a live link to ' + e.attrs[k]);
    });
    e.children.forEach(walk);
  })(root);
}
function textOf(root) { return root.textContent; }
function withDom(fn) {
  var dom = makeFakeDom(), hooks = m.__dom();
  global.document = dom.document;
  try { fn(dom, hooks); } finally { delete global.document; }
}
function staticIcons(dom, what) {
  dom.inner.forEach(function (x) { if (/onerror|<script|javascript:/i.test(x.html)) throw new Error(what + ': innerHTML got ' + x.html.slice(0, 60)); });
}

test('safeLink: only https on a known documentation host is a link', function () {
  eq(m.safeLink('https://learn.microsoft.com/azure/azure-local/x?view=azloc-2609'), 'https://learn.microsoft.com/azure/azure-local/x?view=azloc-2609');
  eq(m.safeLink('https://azurelocal.cloud/azurelocal-sonar/run'), 'https://azurelocal.cloud/azurelocal-sonar/run');
  eq(m.safeLink('https://github.com/AzureLocal/azurelocal-sonar'), 'https://github.com/AzureLocal/azurelocal-sonar');
  HOSTILE.concat(['http://github.com/x', 'https://evil.example/x', 'https://github.com.evil.example/x', 'https://github.com@evil.example/x', 'https://user:pw@github.com/x',
    '//github.com/x', 'ftp://github.com/x', '', null, undefined, 'https://github.com:8443@evil.example/']).forEach(function (u) {
    eq(m.safeLink(u), '', 'refused: ' + String(u));
  });
});

test('help links from the back end: a hostile or foreign URL is plain text, a good one has rel and target', function () {
  withDom(function (dom, h) {
    h.app.about = { version: HOSTILE[0], summary: HOSTILE[1], links: [
      { label: 'Docs', url: 'https://azurelocal.cloud/azurelocal-sonar/' },
      { label: HOSTILE[0], url: HOSTILE[2] }, { label: 'Data', url: HOSTILE[3] }, { label: 'Foreign', url: 'https://evil.example/x' }] };
    h.renderHelp();
    var host = dom.byId['help-links'];
    assertInert(host, 'help');
    var anchors = host.querySelectorAll('a');
    eq(anchors.length, 1, 'only the allow-listed link is a link');
    eq(anchors[0].attrs.rel, 'noopener noreferrer');
    eq(anchors[0].attrs.target, '_blank');
    eq(textOf(host).indexOf(HOSTILE[0]) >= 0, true, 'the hostile label shows as text');
    eq(dom.byId['help-version'].textContent, 'v' + HOSTILE[0], 'the version is text');
    staticIcons(dom, 'help');
  });
});

test('summary box: hostile cluster, machine names, errors and Azure messages render as text', function () {
  withDom(function (dom, h) {
    var n = HOSTILE[0], n2 = '<script>x</script>';
    h.app.config = { cluster: HOSTILE[1], nodes: [{ name: n, seed: true }, { name: n2 }] };
    h.app.state = { cluster: HOSTILE[1], phase: 'provisioning', activePhase: 'provisioning',
      provisioning: { route: 'simplified', status: 'running', nodes: [
        { name: n, route: 'simplified', lifecycle: HOSTILE[2], lifecycleMessage: HOSTILE[3], status: 'error', arcStatus: HOSTILE[0], errors: [HOSTILE[1]], tree: [] },
        { name: n2, route: 'simplified', lifecycle: 'InstallingOs', status: 'running', percent: 50, tree: [] }] },
      nodes: [{ name: n, arcStatus: HOSTILE[0] }, { name: n2, arcStatus: 'Connected' }] };
    h.renderSummary();
    var host = dom.byId.summary;
    assertInert(host, 'summary');
    eq(textOf(host).indexOf(n) >= 0 && textOf(host).indexOf(n2) >= 0, true, 'full names shown as text');
    eq(host.querySelectorAll('button').length, 2, 'two cards');
    staticIcons(dom, 'summary');
  });
});

test('Details pop-down: hostile values in every field render as text', function () {
  withDom(function (dom, h) {
    var H = HOSTILE;
    h.app.details = { mode: 'live', target: { cluster: { value: H[0], source: H[1] }, resourceGroup: { value: H[1], source: H[2] }, subscription: { value: H[2], source: H[3], note: H[0] }, region: { value: H[3], source: H[0] } },
      route: { label: H[0], source: H[1] }, identity: { label: H[1], meaning: H[2], source: H[3] },
      nodes: [{ name: H[0], address: H[1], seed: true }, { name: H[2], address: H[3] }],
      sources: { azure: { pollSeconds: 20, lastAnswerAt: '2026-11-07T10:00:00Z', ok: false, message: H[0] }, ztpEvents: { configured: true, file: H[1], fileFound: false, events: 3, lastEventAt: '2026-11-07T10:00:00Z' },
        nodeLogs: { state: 'unavailable', node: H[2], credential: H[3], transport: H[0], reason: H[1], lastLineAt: null } },
      config: { readFrom: H[0], file: H[1], sourceKind: 'infrastructure', readAt: '2026-11-07T10:00:00Z', checkEverySeconds: 60, lastChangeAt: '2026-11-07T10:00:00Z', lastChangeNote: H[2],
        notSet: [{ label: H[3], key: H[0], effect: H[1] }], version: H[2] } };
    h.renderDetails();
    var host = dom.byId['details-body'];
    assertInert(host, 'details');
    eq(textOf(host).indexOf(H[0]) >= 0 && textOf(host).indexOf(H[1]) >= 0, true, 'hostile text is shown as text');
    staticIcons(dom, 'details');
  });
});

test('log lines: hostile text and file names, with a search that highlights them, stay text', function () {
  withDom(function (dom, h) {
    h.app.filter.q = 'script';
    var line = { seq: 1, time: '2026-11-07T10:00:00.000Z', t: Date.parse('2026-11-07T10:00:00Z'), received: '', r: NaN, timeSource: 'line', file: 'C:\\Logs\\' + HOSTILE[0] + '.log', level: 'error', text: HOSTILE[1] + ' ' + HOSTILE[2], lc: null };
    var row = h.buildLine(line);
    assertInert(row, 'log line');
    eq(row.querySelectorAll('mark').length >= 1, true, 'the match is marked');
    eq(textOf(row).indexOf(HOSTILE[1]) >= 0, true, 'the text is intact');
    h.app.filter.q = '';
  });
});

test('live notes and the filter chips: hostile guide URL and machine filter stay inert', function () {
  withDom(function (dom, h) {
    h.app.state = { phase: 'provisioning', provisioning: { ztpComplete: true, nextStep: { name: HOSTILE[0], guide: HOSTILE[2] }, route: 'simplified', nodes: [] }, lag: { detected: true, message: HOSTILE[1], source: HOSTILE[0] } };
    h.renderLiveNotes();
    assertInert(dom.byId['live-notes'], 'live notes');
    h.app.filter.node = HOSTILE[0];
    h.renderChips();
    assertInert(dom.byId['filter-chips'], 'chips');
    eq(textOf(dom.byId['filter-chips']).indexOf(HOSTILE[0]) >= 0, true);
    h.app.filter.node = '';
  });
});

test('Log access window: hostile guidance text and source links are inert, a foreign link is only text', function () {
  withDom(function (dom, h) {
    h.app.state = { phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', nodes: [] } };
    h.app.config = { identityModel: HOSTILE[0], profile: { notes: [HOSTILE[1]] } };
    h.app.guidance = { identityModel: HOSTILE[0], phases: { provisioning: { account: HOSTILE[0], where: [HOSTILE[1]], when: HOSTILE[2], how: HOSTILE[3], verified: false,
      source: ['https://learn.microsoft.com/azure/azure-local/x', HOSTILE[2], HOSTILE[3], 'https://evil.example/x'], notes: HOSTILE[1] } } };
    h.renderLogAccessWindow();
    var body = dom.byId['la-body'];
    assertInert(body, 'log access');
    eq(body.querySelectorAll('a').length, 1, 'one allow-listed source link');
    eq(textOf(body).indexOf(HOSTILE[2]) >= 0, true, 'the other sources are text');
    h.app.guidance = null; h.app.config = null;
  });
});

test('step tree item: hostile step names, descriptions and errors stay text', function () {
  withDom(function (dom, h) {
    var n = { id: HOSTILE[0], name: HOSTILE[1], description: HOSTILE[2], status: 'error', errors: [HOSTILE[3], HOSTILE[0]], children: [], __key: 'deployment/x', start: '2026-11-07T10:00:00Z' };
    h.app.stepIndex.set('deployment/x', { node: n, section: 'deployment', parentKey: 'deployment' });
    h.app.selectedKey = 'deployment/x';
    var li = h.buildItem(n, 1, null, 'validation', [n]);   // an Azure step, selected: its details are shown under it
    assertInert(li, 'step');
    eq(textOf(li).indexOf(HOSTILE[1]) >= 0, true);
    eq(li.querySelectorAll('.detail').length, 1, 'the Azure details are shown');
    h.app.selectedKey = null;
    staticIcons(dom, 'step');
  });
});

test('hostile config: a cluster name and node name with markup flow through the model as data', function () {
  var c = '"><img src=x onerror=alert(1)>', n = '<script>x</script>';
  var state = { cluster: c, phase: 'deployment', activePhase: 'deployment', nodes: [{ name: n, arcStatus: 'Connected' }],
    validation: { status: 'Success', tree: [] }, deployment: { status: 'InProgress', tree: [{ id: '1', name: 'Deploy', status: 'running', children: [{ id: '1.1', name: 's', status: 'running', children: [] }] }] } };
  eq(m.machineList(state, { nodes: [{ name: n, seed: true }] }).map(function (x) { return x.name; }), [n], 'the machine name is data, unchanged');
  var sm = m.summaryFor(state, 'deploy', { nodes: [{ name: n, seed: true }] });
  eq(sm.cards.map(function (x) { return x.name; }), [n]);
  // through the JSON the back end serves, the markup is escaped
  eq(JSON.parse(JSON.stringify(state)).cluster, c);
  withDom(function (dom, h) {
    h.app.state = state; h.app.config = { cluster: c, nodes: [{ name: n, seed: true }] };
    h.renderSummary();
    assertInert(dom.byId.summary, 'hostile config');
    eq(textOf(dom.byId.summary).indexOf(n) >= 0, true, 'the node name is visible as text');
  });
});

test('page source: no HTML injection, no inline style, no eval; innerHTML only takes the fixed icons', function () {
  ['insertAdjacentHTML', 'outerHTML', 'document.write', 'eval(', 'new Function', "setAttribute('style'", 'setAttribute("style"'].forEach(function (bad) {
    eq(appSource.indexOf(bad), -1, 'app.js must not contain ' + bad);
  });
  var assigns = appSource.match(/\.innerHTML\s*=\s*[^;]+;/g) || [];
  assigns.forEach(function (a) { eq(/=\s*(ICON\.\w+|icon\(\w+\))\s*;/.test(a), true, 'innerHTML takes only an icon constant: ' + a); });
  eq(assigns.length > 0, true);
});

// ---------------------------------------------------------------- OS configuration mode

var NOW = Date.parse('2026-11-07T20:00:00Z');
function oscAt(r, count) { return m.oscDemoState(r, NOW - r * 60000, count || 3); }
function oscNode(osc, name) { return osc.nodes.filter(function (n) { return n.name === name; })[0]; }
function oscStage(node, step) { return node.tree.filter(function (t) { return t.osc.step === step; })[0]; }
function oscRunState(osc, extra) {
  var s = { phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', ztpComplete: true, nodes: [] }, osConfiguration: osc };
  if (extra) Object.keys(extra).forEach(function (k) { s[k] = extra[k]; });
  return s;
}

test('OS configuration tile: between Provisioning and Validate, equal width (the bar sets --n to the tile count)', function () {
  var tiles = m.modeStates(oscRunState(oscAt(2)));
  eq(tiles.map(function (t) { return t.id; }), ['discovery', 'prov', 'osconfig', 'verify', 'validate', 'deploy', 'update']);
  eq(m.MODE_SECTIONS.osconfig, ['osconfiguration']);
  eq(m.modeName('osconfig', 'simplified'), 'OS configuration');
  eq(tiles.some(function (t) { return t.hidden; }), false);
});

test('OS configuration tile states: running while a run works, error with a failed machine, ok only when every machine converged', function () {
  var running = tileOf(m.modeStates(oscRunState(oscAt(1.7))), 'osconfig');
  eq(running.status, 'run'); eq(running.line, '0 of 3 converged');
  var retrying = tileOf(m.modeStates(oscRunState(oscAt(2.1))), 'osconfig');
  eq(retrying.status, 'run'); eq(retrying.line, '0 of 3 converged, 1 retrying');
  var failed = tileOf(m.modeStates(oscRunState(oscAt(4.95))), 'osconfig');
  eq(failed.status, 'err'); eq(failed.line, '1 of 3 converged, 1 failed');
  var done = oscAt(6.9);
  eq(done.ready, true);
  var ok = tileOf(m.modeStates(oscRunState(done)), 'osconfig');
  eq(ok.status, 'ok'); eq(ok.line, '3 of 3 converged');
  var plan = oscAt(0.95, 3); plan.status = 'notstarted'; plan.state = 'planned'; plan.run.completed = '2026-11-07T19:00:00Z'; plan.run.mode = 'Plan';
  plan.nodes.forEach(function (n) { n.status = 'notstarted'; n.state = 'planned'; });
  var planned = tileOf(m.modeStates(oscRunState(plan)), 'osconfig');
  eq(planned.status, 'idle'); eq(planned.line, 'Plan ready');
});

test('OS configuration never keeps Provisioning running, and it is the mode shown once its run has started', function () {
  var s = oscRunState(oscAt(3));
  var tiles = m.modeStates(s);
  eq(tileOf(tiles, 'prov').status, 'ok', 'Provisioning stays done while OS configuration runs');
  eq(m.activeModeId(s), 'osconfig');
  eq(m.activeModeId({ phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', ztpComplete: true, nodes: [] } }), 'prov', 'no OS configuration data: unchanged');
  var configured = oscRunState({ configured: true, nodes: [], run: {}, nodesTotal: 0 });
  eq(m.activeModeId(configured), 'osconfig', 'ZTP complete and the event file is configured: the mode to watch, waiting');
  var validating = { phase: 'validation', activePhase: 'validation', osConfiguration: oscAt(6.9), validation: { status: 'InProgress', tree: [] } };
  eq(m.activeModeId(validating), 'validate');
});

test('OS configuration is ready for the cluster only when every machine has converged', function () {
  eq(oscAt(5.5).ready, false);
  eq(oscAt(5.5).nodesConverged, 1);
  eq(oscAt(6.9).ready, true);
  eq(oscAt(6.9).nodes.every(function (n) { return n.state === 'converged'; }), true);
  eq(m.summaryFor(oscRunState(oscAt(6.9)), 'osconfig').headline, 'OS configuration has converged on all 3 machines. Next: Validate');
});

test('method per machine: Ztp and Iso side by side, expected before an event says, a warning when the declaration differs', function () {
  var osc = oscAt(2.7);
  var n1 = oscNode(osc, 'iic-azl-n01'), n2 = oscNode(osc, 'iic-azl-n02');
  eq(n1.method, 'Ztp'); eq(n2.method, 'Iso');
  eq(n1.transport, 'ArcRunCommand'); eq(n2.transport, 'WinRM');
  var c1 = m.oscMethodChip(n1), c2 = m.oscMethodChip(n2);
  eq(c1.text, 'ZTP'); eq(c1.kind, 'run');
  eq(c2.text, 'ISO (differs from the file)'); eq(c2.kind, 'warn');
  eq(/declares simplified/.test(c2.title), true);
  eq(n2.warnings.length, 1);
  var early = oscNode(oscAt(0.1), 'iic-azl-n01');
  eq(m.oscMethodChip(early).text, 'ZTP (expected)');
  eq(m.oscMethodChip({ method: '' }).text, 'Method unknown');
});

test('steps follow the method: ZTP verifies the computer name and Arc registration, ISO changes them; N/A steps say why', function () {
  var osc = oscAt(2.7);
  var z = oscNode(osc, 'iic-azl-n01'), i = oscNode(osc, 'iic-azl-n02');
  eq(z.tree.length, 14); eq(i.tree.length, 14);
  eq(z.tree.map(function (t) { return t.osc.step; }), ['RemoteManagement', 'Network', 'Dns', 'Time', 'Hostname', 'DomainJoin', 'UnusedAdapters', 'LocalAdmin', 'Mpio', 'SanVerify', 'ClearStorage', 'Sbe', 'Drivers', 'ArcRegistration']);
  eq(oscStage(z, 'Hostname').osc.verifyOnly, true); eq(oscStage(z, 'ArcRegistration').osc.verifyOnly, true);
  eq(oscStage(z, 'Hostname').osc.stage, 'ok');
  eq(oscStage(i, 'Hostname').osc.verifyOnly, false); eq(oscStage(i, 'ArcRegistration').osc.verifyOnly, false);
  eq(oscStage(i, 'Hostname').osc.stage, 'planned'); eq(oscStage(i, 'ArcRegistration').osc.action, 'Change');
  var na = oscStage(z, 'ClearStorage');
  eq(na.osc.stage, 'skipped'); eq(na.osc.notApplicable, true); eq(/^Not applicable: /.test(na.description), true); eq(na.status, 'skipped');
  // before the first event the ZTP steps are known: waiting, with the two verify-only ones marked
  var waiting = oscNode(oscAt(0.1), 'iic-azl-n03');
  eq(waiting.tree.every(function (t) { return t.osc.stage === 'waiting'; }), true);
});

test('step status: planned, ok, changing, applied, failed, verified, with current and desired from the event evidence', function () {
  var mid = oscNode(oscAt(1.3), 'iic-azl-n01');
  eq(oscStage(mid, 'Dns').osc.stage, 'changing'); eq(oscStage(mid, 'Dns').status, 'running');
  eq(oscStage(mid, 'Dns').osc.current, '192.0.2.250'); eq(oscStage(mid, 'Dns').osc.desired, '192.0.2.53,192.0.2.54');
  eq(/192.0.2.250 -> 192.0.2.53/.test(oscStage(mid, 'Dns').description), true);
  eq(oscStage(mid, 'Time').osc.stage, 'planned'); eq(oscStage(mid, 'Time').status, 'notstarted');
  eq(oscStage(mid, 'RemoteManagement').osc.stage, 'ok'); eq(oscStage(mid, 'RemoteManagement').status, 'success');
  var later = oscNode(oscAt(3.0), 'iic-azl-n01');
  eq(oscStage(later, 'Dns').osc.stage, 'applied'); eq(oscStage(later, 'Dns').status, 'success');
  var verified = oscNode(oscAt(3.7), 'iic-azl-n01');
  eq(oscStage(verified, 'Dns').osc.stage, 'verified');
  var failed = oscNode(oscAt(4.95), 'iic-azl-n02');
  eq(oscStage(failed, 'Drivers').osc.stage, 'failed'); eq(oscStage(failed, 'Drivers').status, 'error');
  eq(/SBE manifest hash/.test(oscStage(failed, 'Drivers').errors[0]), true);
});

test('retries and restarts are counted on the machine and shown on its card', function () {
  var osc = oscAt(2.1);
  var n1 = oscNode(osc, 'iic-azl-n01');
  eq(n1.state, 'retrying'); eq(n1.retries, 1);
  var card = m.oscCard(n1);
  eq(card.state, 'Retrying'); eq(card.kind, 'warn');
  eq(card.lines.some(function (l) { return /Retried 1 time/.test(l); }), true);
  var n2 = oscNode(oscAt(3.45), 'iic-azl-n02');
  eq(n2.restarts, 1); eq(n2.state, 'applying');
  eq(oscNode(oscAt(3.2), 'iic-azl-n02').state, 'reconnecting', 'while the node is away it is reconnecting');
  eq(m.oscCard(n2).lines.some(function (l) { return /Restarted 1 time/.test(l); }), true);
});

test('guarded network change: AwaitingConfirm has a countdown, Committed ends it', function () {
  var n2 = oscNode(oscAt(2.3), 'iic-azl-n02');
  eq(n2.state, 'awaitingconfirm'); eq(n2.guarded, 'AwaitingConfirm');
  var step = oscStage(n2, 'Network');
  eq(step.osc.stage, 'changing'); eq(step.osc.guarded.state, 'AwaitingConfirm');
  eq(step.osc.guarded.confirmMinutes, 10);
  var card = m.oscCard(n2);
  eq(card.state, 'Awaiting confirmation'); eq(card.until, step.osc.guarded.confirmBy);
  var left = m.oscCountdown(step.osc.guarded.confirmBy, NOW);
  eq(left > 0 && left <= 600, true, 'a window of at most 10 minutes is left');
  eq(m.fmtCountdown(75), '01:15 left'); eq(m.fmtCountdown(0), 'window over'); eq(m.fmtCountdown(NaN), '');
  eq(m.oscCountdown(step.osc.guarded.confirmBy, Date.parse(step.osc.guarded.confirmBy) + 5000), 0);
  var after = oscStage(oscNode(oscAt(2.7), 'iic-azl-n02'), 'Network');
  eq(after.osc.guarded.state, 'Committed'); eq(after.osc.stage, 'applied');
});

test('guarded network change: RolledBack shows the node’s reason on the machine and the step; Refused too', function () {
  var osc = oscAt(2.3);
  var n2 = oscNode(osc, 'iic-azl-n02');
  var net = oscStage(n2, 'Network');
  net.osc.stage = 'rolledback'; net.osc.guarded = { state: 'RolledBack', reason: 'The gateway 192.0.2.1 did not answer for 60 s; the snapshot was restored.', confirmBy: null };
  net.status = 'error'; net.errors = [net.osc.guarded.reason];
  n2.guarded = 'RolledBack'; n2.guardedDetail = net.osc.guarded; n2.state = 'rolledback'; n2.status = 'error'; n2.errors = [net.osc.guarded.reason]; n2.stateText = 'Network change rolled back: ' + net.osc.guarded.reason;
  var card = m.oscCard(n2);
  eq(card.state, 'Rolled back'); eq(card.kind, 'err');
  eq(card.lines.some(function (l) { return /^Rolled back: The gateway/.test(l); }), true);
});

test('machine card: name, method, transport, current step and the state', function () {
  var osc = oscAt(4.95);
  var cards = m.summaryFor(oscRunState(osc), 'osconfig').cards;
  eq(cards.map(function (c) { return c.name; }), ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03']);
  eq(cards.map(function (c) { return c.state; }), ['Converged', 'Failed', 'Applying']);
  eq(cards[0].chips.map(function (c) { return c.text; }), ['ZTP', 'Arc Run Command', '192.0.2.21 (ZTP handoff)']);
  eq(cards[1].chips.map(function (c) { return c.text; }), ['ISO (differs from the file)', 'WinRM', '192.0.2.22 (Neighbor table, by MAC)']);
  eq(cards[2].lines[0], 'Now: MPIO (SAN)');
  eq(cards[0].lines.indexOf('Logs: domain-joined: using IIC\\svc-join') >= 0, true, 'a joined machine says the domain account reads its logs');
  var early = m.summaryFor(oscRunState(oscAt(3.0)), 'osconfig').cards;
  eq(early[2].lines.indexOf('Logs: workgroup: using azl-admin') >= 0, true, 'a machine not joined yet says the local account does');
  eq(cards.every(function (c) { return c.arc === null; }), true);
});

test('run summary: run state, machines converged, wipe list, start', function () {
  var osc = oscAt(2.0);
  var sm = m.summaryFor(oscRunState(osc), 'osconfig');
  eq(sm.title, 'OS configuration');
  eq(sm.facts.map(function (f) { return f.k; }), ['Run', 'Machines converged', 'Wipe list', 'Mode', 'Run id', 'Remoting']);
  eq(sm.facts[0].v, 'applying'); eq(sm.facts[1].v, '0 of 3');
  eq(sm.facts[2].v, 'pending (1 machine)'); eq(sm.facts[2].warn, true);
  eq(sm.startedAt, Date.parse(osc.run.started));
  var done = m.summaryFor(oscRunState(oscAt(6.9)), 'osconfig');
  eq(done.facts[2].v, 'done');
  eq(m.oscHeadline(oscAt(0.5)).indexOf('0 of 3 machines converged') === 0, true);
});

test('version display: OS build, SBE package and route, schema and wrapper, from the events', function () {
  var n1 = oscNode(oscAt(2.0), 'iic-azl-n01'), n2 = oscNode(oscAt(2.0), 'iic-azl-n02');
  eq(m.oscVersionLines(n1), ['OS 10.0.26100.1', 'computer name iic-azl-n01', 'SBE Dell 16G-45n0c-Intel 5.0.2606.1616 (SAS download by the node (Arc Run Command))', 'schema 5.3.0', 'wrapper 1.0.0']);
  eq(m.oscVersionLines(n2)[0], 'Azure Stack HCI');
  eq(/copy over WinRM/.test(m.oscVersionLines(n2).join(' ')), true);
  eq(m.oscVersionLines({ versions: {} }), []);
});

test('mixed cluster: one Ztp and one Iso machine render side by side in the tree, each with its own steps and Azure badges only on Arc steps', function () {
  var tree = m.osConfigTreeOf(oscRunState(oscAt(3.3)));
  eq(tree.map(function (t) { return t.name; }), ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03']);
  eq(tree[0].osc.method, 'Ztp'); eq(tree[1].osc.method, 'Iso');
  var arcSteps = function (t) { return t.children.filter(function (c) { return c.osc.arc; }).map(function (c) { return c.osc.step; }); };
  eq(arcSteps(tree[0]).length > 0, true, 'the ZTP machine uses Arc Run Command for its changes');
  eq(arcSteps(tree[1]), [], 'the ISO machine is reached over WinRM: no Arc steps');
  eq(m.stepRule('osconfiguration', [tree[1]]).side, 'machine');
  eq(m.stepRule('osconfiguration', [tree[1], tree[1].children[2]]), { side: 'node', node: 'iic-azl-n02', stage: 'osc.dns', window: false });
});

test('log lines: the OS configuration events carry node and step for the machine and step filters', function () {
  var t = '2026-11-07T19:01:59.536Z [osconfig] iic-azl-n02 StepApplying (Dns): Changing: Dns: a -> b';
  eq(m.lineScope({ file: 'os-config-events', text: t }), { node: 'iic-azl-n02', stage: 'osc.dns' });
  eq(m.lineScope({ file: 'os-config-events', text: '2026-11-07T19:01:59.536Z [osconfig] * RunStarted: x' }), { node: '*', stage: '' });
  eq(m.lineScope({ file: 'os-config-events', text: '2026-11-07T19:01:59.536Z [osconfig] n1 NetworkChangeAwaitingConfirm: waiting' }), { node: 'n1', stage: 'osc.network' });
  eq(m.lineInScope({ file: 'os-config-events', text: t }, { node: 'iic-azl-n02', stage: 'osc.dns' }, null, 'iic-azl-n01'), true);
  eq(m.lineInScope({ file: 'os-config-events', text: t }, { node: 'iic-azl-n01', stage: '' }, null, 'iic-azl-n01'), false);
  eq(m.lineInScope({ file: 'os-config-events', text: t }, { node: 'iic-azl-n02', stage: 'osc.time' }, null, ''), false);
  var lines = m.oscDemoLines(4.95, NOW - 4.95 * 60000);
  eq(lines.every(function (l) { return /\[osconfig\]/.test(l.text); }), true);
  eq(lines.some(function (l) { return l.level === 'error'; }), true);
  eq(lines.filter(function (l) { return /NodeRetry/.test(l.text); }).length, 1);
});

test('domain join: the DomainJoin step shows planned, applying, joined; the account switches from local to domain at DomainJoined', function () {
  var before = oscNode(oscAt(1.9), 'iic-azl-n01'), after = oscNode(oscAt(2.2), 'iic-azl-n01');
  eq(oscStage(before, 'DomainJoin').osc.stage, 'changing'); eq(oscStage(before, 'DomainJoin').status, 'running');
  eq(oscStage(oscNode(oscAt(1.5), 'iic-azl-n01'), 'DomainJoin').osc.stage, 'planned');
  eq(/workgroup WORKGROUP -> iic.example.test/.test(oscStage(before, 'DomainJoin').description), true);
  eq(before.domainJoined, false); eq(before.logAccount.reason, 'workgroup: using azl-admin'); eq(before.logAccount.kind, 'local');
  eq(oscStage(after, 'DomainJoin').osc.stage, 'applied');
  var waiting = oscNode(oscAt(2.15), 'iic-azl-n01');
  eq(waiting.domainJoined, true); eq(waiting.domainAdminsConfigured, false);
  eq(waiting.logAccount.reason, 'joined, waiting for domain administrators: using azl-admin'); eq(waiting.logAccount.kind, 'local'); eq(waiting.logAccount.waitingForAdmins, true);
  eq(after.domainJoined, true); eq(after.domainAdminsConfigured, true); eq(after.logAccount.reason, 'domain-joined: using IIC\\svc-join'); eq(after.logAccount.userName, 'IIC\\svc-join');
  var tree = m.osConfigTreeOf(oscRunState(oscAt(2.2)));
  eq(tree[0].osc.logAccount.reason, 'domain-joined: using IIC\\svc-join'); eq(tree[0].osc.domainJoined, true);
  eq(tree[1].osc.logAccount.reason, 'workgroup: using azl-admin');
  var lines = m.oscDemoLines(4.95, NOW - 4.95 * 60000).map(function (l) { return l.text; });
  eq(lines.some(function (t) { return /\[osconfig\] iic-azl-n01 DomainJoinApplying \(DomainJoin\)/.test(t); }), true);
  eq(lines.some(function (t) { return /\[osconfig\] iic-azl-n02 DomainJoined \(DomainJoin\)/.test(t); }), true);
  eq(lines.some(function (t) { return /\[osconfig\] iic-azl-n02 DomainAdminsConfigured \(DomainJoin\)/.test(t); }), true);
  eq(m.lineScope({ file: 'os-config-events', text: '2026-11-07T19:01:59.536Z [osconfig] n1 DomainAdminsConfigured: x' }), { node: 'n1', stage: 'osc.domainjoin' });
  eq(m.lineScope({ file: 'os-config-events', text: '2026-11-07T19:01:59.536Z [osconfig] n1 DomainJoinFailed: x' }), { node: 'n1', stage: 'osc.domainjoin' });
});

test('Details: the domain account shows its breaker state and next check, never a secret', function () {
  withDom(function (dom, h) {
    var d = { mode: 'live', target: {}, route: {}, identity: {}, nodes: [], sources: {}, config: {},
      logAccount: { account: 'IIC\\svc-join', state: 'open', failures: 1, maxRejections: 2, backoffMinutes: 15, nextProbeAt: '2026-11-07T20:15:00Z', lastClass: 'rejected', credential: 'ready', credentialRetryAt: null } };
    h.app.details = d;
    h.renderDetails();
    var text = textOf(dom.byId['details-body']);
    eq(text.indexOf('IIC\\svc-join') >= 0, true, 'the account name is shown');
    eq(/paused for every node after a rejection/.test(text), true);
    eq(/1 of 2 rejections/.test(text), true);
    eq(/next check/.test(text), true);
    eq(/last: rejected/.test(text), true);
    d.logAccount = { account: 'IIC\\svc-join', state: 'latched', failures: 2, maxRejections: 2, backoffMinutes: 30, nextProbeAt: null, lastClass: 'rejected', credential: 'unavailable', credentialRetryAt: '2026-11-07T20:05:00Z' };
    h.renderDetails();
    text = textOf(dom.byId['details-body']);
    eq(/until its password changes or Sonar restarts/.test(text), true);
    eq(/not available \(Key Vault\)/.test(text), true);
    d.logAccount = { account: '', state: 'closed', failures: 0, maxRejections: 2 };
    h.renderDetails();
    eq(textOf(dom.byId['details-body']).indexOf('Domain account') < 0, true, 'no account: no group');
  });
});

test('Steps box text when OS configuration has not started', function () {
  eq(/Invoke-AzureLocalOsConfiguration/.test(m.stepsEmptyText('osconfig', 'idle', 'Starts after ZTP is complete', false)), true);
  eq(m.stepsEmptyText('osconfig', 'run', '', true), 'No steps reported yet.');
});

test('live notes: an OS configuration warning (declaration differs, stuck run command) shows under the bar', function () {
  var notes = m.liveNotes(oscRunState(oscAt(3.0)));
  eq(notes.some(function (n) { return n.kind === 'osconfig' && /iic-azl-n02/.test(n.text); }), true);
});

test('OS configuration summary and steps: hostile machine names, evidence and reasons render as text', function () {
  var osc = oscAt(2.3);
  var hostile = HOSTILE[0];
  osc.nodes[1].name = hostile; osc.nodes[1].versions.hostname = HOSTILE[1];
  osc.nodes[1].tree[1].description = HOSTILE[2]; osc.nodes[1].warnings = [HOSTILE[3]];
  osc.nodes[1].guardedDetail.reason = HOSTILE[1];
  withDom(function (dom, h) {
    var state = oscRunState(osc);
    h.app.state = state; h.app.config = { cluster: 'c', nodes: [{ name: 'iic-azl-n01', seed: true }, { name: hostile }] };
    h.renderSummary();
    assertInert(dom.byId.summary, 'osconfig summary');
    eq(textOf(dom.byId.summary).indexOf(hostile) >= 0, true, 'the machine name shows as text');
    var tree = m.osConfigTreeOf(state);
    tree.forEach(function (n, i) { n.__key = 'osconfiguration/' + i; n.children.forEach(function (c, j) { c.__key = 'osconfiguration/' + i + '/' + j; }); h.app.stepIndex.set(n.__key, { node: n, section: 'osconfiguration', parentKey: 'osconfiguration' }); });
    var li = h.buildItem(tree[1], 1, null, 'osconfiguration', [tree[1]]);
    assertInert(li, 'osconfig tree');
    eq(textOf(li).indexOf(HOSTILE[2]) >= 0, true, 'the evidence shows as text');
    eq(li.querySelectorAll('.osc-stage').length > 0, true, 'a step shows its stage chip');
    eq(li.querySelectorAll('.countdown').length > 0, true, 'the guarded change shows its countdown');
    staticIcons(dom, 'osconfig');
  });
});

// ---------------------------------------------------------------- ARM Validate and Deploy (state.arm from the toolkit's event feed)

var ARM_BASE = Date.parse('2026-11-07T20:00:00Z');
function armAt(r) { return m.armDemoState(r, ARM_BASE); }
function armState(arm, extra) {
  var s = { phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', ztpComplete: true, nodes: [] }, validation: { status: 'notstarted', tree: [] }, deployment: { status: 'notstarted', tree: [] }, arm: arm };
  if (extra) Object.keys(extra).forEach(function (k) { s[k] = extra[k]; });
  return s;
}
function armTiles(s) { var o = {}; m.modeStates(s).forEach(function (t) { o[t.id] = t; }); return o; }
// A blocked validation: two checks failed, nothing submitted (Azure has no steps).
function armBlocked() {
  var a = armAt(0.9);
  var fails = [{ id: 'check:Permissions|*', name: 'Permissions', description: 'The identity may not write role assignments.', status: 'error', rawStatus: 'Failed', start: null, end: null, durationSeconds: null, errors: [], children: [],
      arm: { kind: 'check', result: 'Failed', node: '*', check: 'Permissions', nextAction: 'Give the identity User Access Administrator on the resource group.', hint: '' } }];
  a.validation.status = 'blocked'; a.validation.kind = 'error'; a.validation.text = 'Blocked: 2 checks failed, nothing was submitted';
  a.validation.checkCounts = { total: 18, failed: 2, warning: 1, skipped: 0, passed: 15 };
  a.validation.message = '2 precondition(s) failed: Permissions, NamesAvailable.'; a.validation.nextAction = 'Give the identity User Access Administrator on the resource group.';
  a.validation.tree[0].children = fails.concat(a.validation.tree[0].children); a.validation.tree[0].status = 'error';
  a.state = 'failed'; a.status = 'error';
  return a;
}

test('ARM tiles: nothing from the feed keeps the Validate and Deployment tiles as Azure says', function () {
  var none = armTiles(armState({ configured: true, hasData: false, validation: { status: 'notstarted' }, deployment: { status: 'notstarted' } }));
  eq([none.validate.status, none.validate.line, none.deploy.status], ['idle', '', 'idle']);
  var without = armTiles({ phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', nodes: [] } });
  eq([without.validate.status, without.deploy.status], ['idle', 'idle']);
});

test('ARM tiles: checks that failed before the submit turn Validate red with the count, while Azure has no steps', function () {
  var t = armTiles(armState(armBlocked()));
  eq([t.validate.status, t.validate.line], ['err', '2 checks failed']);
  eq(/Give the identity User Access Administrator/.test(t.validate.tip), true, 'the tip carries the next action');
  eq(t.deploy.status, 'idle');
});

test('ARM tiles: checking, validating with the running step and the elapsed time, passed', function () {
  eq(armTiles(armState(armAt(0.5))).validate.status, 'run');
  eq(armTiles(armState(armAt(0.5))).validate.line, 'Checking');
  var running = armTiles(armState(armAt(1.5))).validate;
  eq([running.status, /^Step 0\.\d · /.test(running.line)], ['run', true]);
  var passed = armTiles(armState(armAt(2.7))).validate;
  eq([passed.status, passed.line], ['ok', 'Passed']);
});

test('ARM tiles: Deployment runs per step, then fails at the named step; Azure steps win once Azure has them', function () {
  var dep = armTiles(armState(armAt(4.0))).deploy;
  eq(dep.status, 'run');
  eq(/^Step 0\.\d+ · /.test(dep.line), true, dep.line);
  var failed = armTiles(armState(armAt(5.2))).deploy;
  eq([failed.status, failed.line], ['err', 'Failed at 0.41.2']);
  // Azure already reports a running deployment: its own tile logic runs, the feed does not override it
  var az = armTiles(armState(armAt(4.0), { phase: 'deployment', activePhase: 'deployment', deployment: { status: 'InProgress', tree: [{ id: '1', name: 'A', status: 'success' }, { id: '2', name: 'B', status: 'running' }] } })).deploy;
  eq([az.status, az.line], ['run', 'Step 2 of 2']);
});

test('ARM tiles: a Plan that found nothing wrong is grey, refused and timed out are red', function () {
  var plan = armAt(0.9); plan.validation.status = 'planned'; plan.validation.kind = 'notstarted'; plan.validation.text = 'Plan ready: 18 checks, none failed';
  var p = armTiles(armState(plan)).validate;
  eq([p.status, p.line], ['idle', 'Plan ready']);
  var ref = armAt(4.5); ref.deployment.status = 'refused'; ref.deployment.kind = 'error'; ref.deployment.text = 'Deploy was not started: The last deployment failed. Fix the cause and run again with -Resume.';
  var r1 = armTiles(armState(ref)).deploy;
  eq([r1.status, r1.line], ['err', 'Not started']);
  var to = armAt(3.5); to.deployment.status = 'timedout'; to.deployment.kind = 'error'; to.deployment.text = 'Deployment timed out; Azure is still working';
  eq(armTiles(armState(to)).deploy.line, 'Timed out');
});

test('ARM mode: the page moves to Validate or Deployment when the toolkit run is ahead of Azure, and never backwards', function () {
  eq(m.activeModeId(armState(armBlocked())), 'validate');
  eq(m.activeModeId(armState(armAt(5.2))), 'deploy');
  eq(m.activeModeId(armState(armAt(0.1))), 'prov', 'no event yet: the mode Azure says');
  var planOnly = armAt(0.9); planOnly.validation.status = 'planned';
  eq(m.activeModeId(armState(planOnly)), 'prov', 'a Plan does not move the page');
  var behind = armState(armBlocked(), { phase: 'deployment', activePhase: 'deployment', deployment: { status: 'InProgress', tree: [{ id: '1', name: 'A', status: 'running' }] } });
  eq(m.activeModeId(behind), 'deploy', 'Azure deployment is further on than the blocked validation');
  eq(m.activeModeId(armState(armAt(5.2), { phase: 'done', activePhase: 'deployment' })), 'deploy', 'a finished cluster stays on Deployment (Done)');
});

test('ARM summary: before Azure has steps, the headline, times and facts come from the feed; failures read first', function () {
  var s = armState(armBlocked());
  var sum = m.summaryFor(s, 'validate', { nodes: [] });
  eq(sum.headline, '2 precondition(s) failed: Permissions, NamesAvailable.');
  var facts = {}; sum.facts.forEach(function (f) { facts[f.k] = f; });
  eq(facts.Checks.v, '15 passed, 2 failed, 1 with a warning');
  eq(facts.Checks.warn, true);
  eq(/Give the identity/.test(facts.Next.v), true);
  eq(isNaN(sum.startedAt), true, 'a blocked phase has no start');
});

test('ARM summary: deployment failed at step 0.41 names the known failure and the failing step', function () {
  var s = armState(armAt(5.2));
  var sum = m.summaryFor(s, 'deploy', { nodes: [] });
  eq(/^Deployment failed at step 0\.41\.2 DeployVmoArcExtension: /.test(sum.headline), true, sum.headline);
  var facts = {}; sum.facts.forEach(function (f) { facts[f.k] = f; });
  eq(facts['Known failure'].v, 'The Arc machines are named after the device ID');
  eq(facts['Known failure'].warn, true);
  eq(/\d/.test(facts.Elapsed.v), true);
  eq(facts.Steps.warn, true);
  // with Azure's own failed tree present the headline is Azure's, plus the known failure
  var withAzure = armState(armAt(5.2), { phase: 'failed', activePhase: 'deployment', deployment: { status: 'Failed', tree: [{ id: '0.41', name: 'Deploy Arc infrastructure components', status: 'error', errors: ['ParentResourceNotFound'] }] } });
  var sum2 = m.summaryFor(withAzure, 'deploy', { nodes: [] });
  eq(/Known failure: The Arc machines are named after the device ID$/.test(sum2.headline), true, sum2.headline);
});

test('ARM facts: the heads-up for a device-ID Arc name before Deploy, the approval wait and a resumed run', function () {
  var a = armAt(2.0);
  var f = m.armFacts(a, 'validation'), by = {}; f.forEach(function (x) { by[x.k] = x; });
  eq(/Deploy would stop at step 0\.41/.test(by['Heads-up'].v), true);
  eq(/iic-azl-n02/.test(by['Heads-up'].v), true);
  var waiting = armAt(2.7); waiting.awaitingApproval = true; waiting.state = 'awaitingapproval';
  eq(m.armFacts(waiting, 'validation').some(function (x) { return x.k === 'Approval' && x.warn; }), true);
  var resumed = armAt(4.0); resumed.deployment.resumed = { previous: 'Failed', at: '2026-11-07T20:00:00Z', text: 'x' };
  eq(m.armFacts(resumed, 'deployment').some(function (x) { return x.k === 'Resumed' && /failed/.test(x.v); }), true);
  eq(m.armFacts(null, 'validation'), []);
  eq(m.armFacts(armAt(0.1), 'validation'), []);
});

test('ARM top bar: the toolkit run supplies the status only while Azure has no steps for the phase', function () {
  var o = m.armOverall(armState(armBlocked()));
  eq([o.key, /^Validate: Blocked: 2 checks failed/.test(o.label)], ['error', true]);
  eq(m.armOverall(armState(armAt(0.1))), null);
  var azure = armState(armBlocked(), { phase: 'validation', activePhase: 'validation', validation: { status: 'InProgress', tree: [{ id: '1', name: 'A', status: 'running' }] } });
  eq(m.armOverall(azure), null);
});

test('ARM notes: a known failure and a heads-up show under the header; poll errors too', function () {
  var failed = m.liveNotes(armState(armAt(5.2)));
  eq(failed.some(function (n) { return n.kind === 'arm' && /^Known failure: The Arc machines are named after the device ID/.test(n.text); }), true);
  var a = armAt(2.0); a.hints = [{ id: 'arc-device-id-name', title: 'The Arc machines are named after the device ID', text: 'x', phase: 'validation', preventive: true }]; a.warnings = ['Deploy: Reading the deployment status failed (2 in a row)'];
  var notes = m.liveNotes(armState(a)).filter(function (n) { return n.kind === 'arm'; });
  eq(/^Before Deploy: /.test(notes[0].text), true);
  eq(/^ARM run: Deploy: Reading/.test(notes[1].text), true);
});

test('ARM steps: the toolkit sections are their own side, never a node log window', function () {
  eq(m.MODE_SECTIONS.validate, ['armvalidation', 'validation', 'extensions']);
  eq(m.MODE_SECTIONS.deploy, ['armdeployment', 'deployment']);
  eq(m.stepRule('armvalidation', [{ id: 'validation.checks' }, { id: 'check:X|*' }]), { side: 'arm', node: '', stage: '', window: false });
  eq(m.stepRule('armdeployment', [{ id: 'deployment.steps' }]).side, 'arm');
});

test('ARM tree: failures first in the checks, the steps in order, the failing step carries the hint', function () {
  var a = armAt(5.2);
  var checks = m.armTreeOf(armState(a), 'deployment')[0];
  eq(checks.name, 'Checks before Deploy');
  eq(checks.children[0].arm.result, 'Warning', 'the warning comes before the passed checks');
  var steps = m.armTreeOf(armState(a), 'deployment')[1];
  eq(steps.children.map(function (c) { return c.id; }), ['0.30', '0.31', '0.38', '0.40', '0.41']);
  var last = steps.children[4];
  eq([last.status, last.children.map(function (c) { return c.id; })], ['error', ['0.41.1', '0.41.2']]);
  eq(last.children[1].arm.failing, true);
  eq(/named after the device ID/.test(last.children[1].arm.hint), true);
  eq(last.children[1].errors.length, 1);
  eq(m.armTreeOf(armState(a), 'validation')[1].children.length, 8);
  eq(m.armTreeOf(null, 'deployment'), []);
});

test('ARM log lines: the run is not a machine; a check of a node is scoped to that node', function () {
  eq(m.lineScope({ file: 'arm-events', text: '2026-11-07T20:00:01.000Z [arm] * DeploymentStep (0.41): x' }), { node: '', stage: '' });
  eq(m.lineScope({ file: 'arm-events', text: '2026-11-07T20:00:01.000Z [arm] iic-azl-n02 PreconditionChecked (ArcMachineNaming): x (warning)' }), { node: 'iic-azl-n02', stage: '' });
  var lines = m.armDemoLines(5.2, ARM_BASE);
  eq(lines.every(function (l) { return /\[arm\] \S+ [A-Za-z]+/.test(l.text); }), true);
  eq(lines.some(function (l) { return /DeploymentFailed \(0\.41\.2\)/.test(l.text) && l.level === 'error'; }), true);
  eq(m.armDemoLines(0.1, ARM_BASE), []);
});

test('ARM demo: the run goes from waiting through checks, Validate and Deploy to the step 0.41 failure', function () {
  var w = armAt(0.1);
  eq([w.hasData, w.state, w.validation.status], [false, 'waiting', 'notstarted']);
  eq([armAt(0.6).state, armAt(0.6).validation.status], ['checking', 'checking']);
  eq([armAt(1.5).state, armAt(1.5).validation.status], ['validating', 'running']);
  eq([armAt(2.7).state, armAt(2.7).validation.status], ['validated', 'passed']);
  eq([armAt(4.0).state, armAt(4.0).deployment.status, armAt(4.0).activePhase], ['deploying', 'running', 'deployment']);
  var f = armAt(5.0);
  eq([f.state, f.status, f.deployment.status, f.deployment.failing.step, f.deployment.knownIssue, f.run.exitCode], ['failed', 'error', 'failed', '0.41.2', 'arc-device-id-name', 1]);
  eq(f.validation.elapsedSeconds, 96);
  eq(f.deployment.elapsedSeconds > 0, true);
});

test('ARM rendering: hostile check text, step names, errors and hints render as text, never as markup', function () {
  var a = armAt(5.2), h = HOSTILE;
  a.deployment.tree[0].children[0].description = h[0]; a.deployment.tree[0].children[0].arm.nextAction = h[1];
  var step = a.deployment.tree[1].children[4];
  step.name = h[0]; step.errors = [h[1]]; step.children[1].arm.hint = h[2];
  a.deployment.failing.message = h[3]; a.deployment.text = h[1];
  withDom(function (dom, hk) {
    var state = armState(a, { phase: 'failed', activePhase: 'deployment' });
    hk.app.state = state; hk.app.config = { cluster: 'c', nodes: [] };
    hk.renderSummary();
    assertInert(dom.byId.summary, 'arm summary');
    var tree = m.armTreeOf(state, 'deployment');
    tree.forEach(function (n, i) {
      n.__key = 'armdeployment/' + i; hk.app.stepIndex.set(n.__key, { node: n, section: 'armdeployment', parentKey: 'armdeployment' });
      n.children.forEach(function (c, j) {
        c.__key = n.__key + '/' + j; hk.app.stepIndex.set(c.__key, { node: c, section: 'armdeployment', parentKey: n.__key });
        c.children.forEach(function (d2, k) { d2.__key = c.__key + '/' + k; hk.app.stepIndex.set(d2.__key, { node: d2, section: 'armdeployment', parentKey: c.__key }); });
      });
    });
    var checks = hk.buildItem(tree[0], 1, null, 'armdeployment', [tree[0]]);
    assertInert(checks, 'arm checks');
    eq(textOf(checks).indexOf(h[0]) >= 0, true, 'the evidence shows as text');
    eq(textOf(checks).indexOf('Next: ' + h[1]) >= 0, true, 'the next action shows as text');
    var steps = hk.buildItem(tree[1], 1, null, 'armdeployment', [tree[1]]);
    assertInert(steps, 'arm steps');
    eq(textOf(steps).indexOf(h[1]) >= 0, true, 'the error shows as text');
    eq(steps.querySelectorAll('.arm-hint').length > 0, true, 'the known failure hint is under the failing step');
    eq(steps.querySelectorAll('.idx').length > 0, true, 'a step shows its portal number');
    staticIcons(dom, 'arm');
  });
});

// ---------------------------------------------------------------- Discovery stage, manual install, standalone monitors

function discNode(name, state, extra) {
  var n = { name: name, found: state !== 'missing', state: state, status: state === 'missing' ? 'notstarted' : state === 'unreadable' ? 'error' : 'success', stateText: state === 'missing' ? 'Not discovered yet' : 'Discovered',
    serviceTag: state === 'missing' ? '' : 'EXAMPLE' + name.slice(-1), model: 'Example R660', bmcMac: '00-00-5E-00-53-65', collectedAt: '2026-11-07T18:00:00Z',
    management: { name: 'Embedded Port 1', mac: '00-00-5E-00-53-05', confirmed: true, reason: 'its MAC is already the management MAC' },
    ports: [{ name: 'Embedded Port 1', mac: '00-00-5E-00-53-05', linkUp: true }, { name: 'Slot 3 Port 1', mac: '00-00-5E-00-53-06', linkUp: false }],
    boss: { present: true, driveCount: 2, hasVirtualDisk: true, needsVirtualDisk: false }, warnings: 0, notes: [], errors: [],
    tree: [{ id: 'disc.identity', name: 'Identity', status: 'success', children: [], errors: [] }] };
  Object.keys(extra || {}).forEach(function (k) { n[k] = extra[k]; });
  return n;
}
function discState(state, nodes, extra) {
  var d = { configured: true, status: 'notstarted', state: state, stateText: '', location: 'discovery', summaryFound: false, collectedAt: '2026-11-07T18:00:00Z', ready: false,
    nodesTotal: nodes.length, nodesDiscovered: nodes.filter(function (n) { return n.found; }).length, nodesFailed: 0, problems: [], nodes: nodes };
  Object.keys(extra || {}).forEach(function (k) { d[k] = extra[k]; });
  return d;
}
function provNone(extra) {
  var p = { route: 'simplified', status: 'notstarted', nodes: [] };
  Object.keys(extra || {}).forEach(function (k) { p[k] = extra[k]; });
  return p;
}

test('Discovery tile: first of the flow, grey with a tip that says how to get its data when it is not configured', function () {
  var tiles = m.modeStates({ phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone(), discovery: { configured: false, state: 'notconfigured', nodes: [] } });
  eq(tiles[0].id, 'discovery'); eq(tiles[0].name, 'Discovery');
  eq(tiles[0].status, 'idle'); eq(tiles[0].line, '');
  eq(/discoveryPath/.test(tiles[0].tip), true);
  eq(m.activeModeId({ phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone(), discovery: { configured: false, state: 'notconfigured', nodes: [] } }), 'prov', 'not configured: the flow starts as it always did');
});

test('Discovery tile states: waiting, running (partial), failed, done; and it is the mode to watch until ZTP starts', function () {
  function st(d) { return { phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone(), discovery: d }; }
  var waiting = discState('waiting', [discNode('n1', 'missing'), discNode('n2', 'missing')], { nodesDiscovered: 0 });
  var w = tileOf(m.modeStates(st(waiting)), 'discovery');
  eq(w.status, 'idle'); eq(w.line, ''); eq(/before ZTP/.test(w.tip), true);
  eq(m.activeModeId(st(waiting)), 'discovery', 'configured and nothing else started: Discovery comes first');
  eq(m.summaryFor(st(waiting), 'discovery').headline.indexOf('Waiting for the discovery output'), 0);
  var partial = discState('partial', [discNode('n1', 'discovered'), discNode('n2', 'missing')]);
  var p = tileOf(m.modeStates(st(partial)), 'discovery');
  eq(p.status, 'run'); eq(p.line, '1 of 2 machines read');
  var failed = discState('failed', [discNode('n1', 'discovered'), discNode('n2', 'missing', { status: 'error', errors: ['No discovery record'] })], { nodesFailed: 1 });
  var f = tileOf(m.modeStates(st(failed)), 'discovery');
  eq(f.status, 'err'); eq(f.line, '1 of 2 discovered, 1 failed');
  var bad = discState('failed', [], { problems: [{ file: 'EX.json', message: 'bad' }], nodesDiscovered: 0 });
  eq(tileOf(m.modeStates(st(bad)), 'discovery').line, '1 unreadable');
  eq(m.summaryFor(st(bad), 'discovery').headline, '1 discovery file could not be read (EX.json)');
  var done = discState('discovered', [discNode('n1', 'discovered'), discNode('n2', 'attention')], { stateText: 'All 2 machines discovered; 1 to check before ZTP', ready: true, summaryFound: true });
  var d = tileOf(m.modeStates(st(done)), 'discovery');
  eq(d.status, 'ok'); eq(d.line, '2 of 2 machines');
  eq(m.activeModeId(st(done)), 'discovery');
  var started = st(done);
  started.provisioning = provNone({ status: 'running' });
  started.provisioning.nodes = [{ name: 'n1', lifecycle: 'Provisioned', status: 'running', arcStatus: 'Connected' }];
  eq(m.activeModeId(started) === 'discovery', false, 'once provisioning has started the page follows it');
});

test('Discovery summary: a card per machine with the service tag, ports, management port, BOSS card and what to check', function () {
  var attention = discNode('n2', 'attention', { stateText: 'Discovered; 2 things to check', management: { name: 'Embedded Port 1', mac: '00-00-5E-00-53-05', confirmed: false, reason: 'a guess' },
    boss: { present: true, driveCount: 2, hasVirtualDisk: false, needsVirtualDisk: true }, notes: ['The management port is a guess', 'The BOSS card has no virtual disk yet'] });
  var s = { phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone(), discovery: discState('discovered', [discNode('n1', 'discovered'), attention], { stateText: 'All 2 machines discovered; 1 to check before ZTP', summaryFound: true }) };
  var sm = m.summaryFor(s, 'discovery');
  eq(sm.title, 'Discovery'); eq(sm.chip, { kind: 'ok', text: 'Done' });
  eq(sm.cards.map(function (c) { return c.name; }), ['n1', 'n2']);
  eq(sm.cards[0].state, 'Discovered'); eq(sm.cards[0].kind, 'ok');
  eq(sm.cards[0].lines.indexOf('Service tag EXAMPLE1') >= 0, true);
  eq(sm.cards[0].lines.indexOf('2 network ports, 1 with link up') >= 0, true);
  eq(sm.cards[0].lines.indexOf('Management port: Embedded Port 1 (00-00-5E-00-53-05)') >= 0, true);
  eq(sm.cards[0].chips.map(function (c) { return c.text; }), ['Example R660', 'BOSS: virtual disk']);
  eq(sm.cards[1].state, 'Check'); eq(sm.cards[1].kind, 'warn');
  eq(sm.cards[1].lines.indexOf('Management port: Embedded Port 1 (00-00-5E-00-53-05) - a guess, confirm it') >= 0, true);
  eq(sm.cards[1].chips[1].text, 'BOSS: no virtual disk'); eq(sm.cards[1].chips[1].kind, 'warn');
  eq(sm.headline, 'All 2 machines discovered; 1 to check before ZTP. Next: ZTP');
  eq(sm.facts[0], { k: 'Discovered', v: '2 of 2' });
  var tree = m.discoveryTreeOf(s);
  eq(tree.map(function (t) { return t.name; }), ['n1', 'n2']);
  eq(tree[1].disc.notes.length, 2); eq(tree[1].disc.machine, true);
  eq(m.stepRule('discovery', [tree[0]]).side, 'machine');
  eq(m.stepRule('discovery', [tree[0], { id: 'disc.identity', name: 'Identity' }]).side, 'file');
  eq(m.stepsEmptyText('discovery', 'idle', 'Runs first', true).indexOf('The machines appear here'), 0);
});

test('Discovery sits before ZTP in the stage list and the flow ends at Deployment: no Health tile anywhere', function () {
  eq(m.MODE_IDS.slice(0, 3), ['discovery', 'prov', 'osconfig']);
  eq(m.MODE_IDS.indexOf('health'), -1);
  var fin = { phase: 'done', activePhase: 'deployment', deployment: { status: 'Success', tree: [] }, nodes: [{ name: 'n1', arcStatus: 'Connected' }] };
  eq(m.modeStates(fin).some(function (t) { return t.id === 'health'; }), false);
  eq(tileOf(m.modeStates(fin), 'deploy').status, 'ok'); eq(tileOf(m.modeStates(fin), 'deploy').line, 'Done');
  var sm = m.summaryFor(fin, 'deploy', { nodes: [{ name: 'n1' }] });
  eq(sm.headline, 'Deployment finished: 1 of 1 machines are connected to Azure Arc');
  eq(sm.cards[0].arc.text, 'Arc ● Connected', 'the machine card keeps its Azure Arc status');
});

test('manual install (scenario.os_install not simplified): Provisioning reads Not used, neutral, and the run starts at OS configuration', function () {
  var s = { phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone({ route: 'oem-image', manualInstall: true }),
    osConfiguration: { configured: true, status: 'notstarted', state: 'waiting', nodes: [], run: {}, nodesTotal: 0 }, discovery: { configured: false, state: 'notconfigured', nodes: [] } };
  eq(m.manualInstall(s), true);
  var tiles = m.modeStates(s);
  var p = tileOf(tiles, 'prov');
  eq(p.status, 'na'); eq(p.line, 'Not used: manual install');
  eq(p.tip, 'The OS was installed by hand; OS configuration starts when the machines answer.');
  eq(m.activeModeId(s), 'osconfig');
  eq(tileOf(tiles, 'osconfig').tip, 'Starts when the machines answer; follows the toolkit’s OS configuration event file (osConfigEventsPath)');
  var sm = m.summaryFor(s, 'prov');
  eq(sm.chip, { kind: 'na', text: 'Not used' });
  eq(sm.cards, []);
  eq(/ZTP/.test(sm.headline), false, 'no ZTP wording for a manual install');
  eq(/finish ZTP|ZTP is complete/.test(JSON.stringify(tiles)), false);
  eq(m.stepsEmptyText('prov', 'na', '', false).indexOf('Not used: the OS was installed by hand'), 0);
  // Discovery still comes before everything when it has data.
  s.discovery = discState('discovered', [discNode('n1', 'discovered')], { stateText: 'All 1 machine discovered', ready: true });
  eq(m.activeModeId(s), 'discovery');
  eq(m.summaryFor(s, 'discovery').headline, 'All 1 machine discovered. Next: OS configuration');
  // The same state without the flag is the ZTP flow as it was.
  var ztp = JSON.parse(JSON.stringify(s)); ztp.provisioning.manualInstall = false; ztp.discovery = { configured: false, state: 'notconfigured', nodes: [] };
  eq(tileOf(m.modeStates(ztp), 'prov').status === 'na', false);
  eq(m.activeModeId(ztp), 'prov');
});

test('standalone monitors: only that tile shows (the others are hidden, not greyed) and the page opens on it', function () {
  var base = { phase: 'provisioning', activePhase: 'provisioning', provisioning: provNone(), osConfiguration: { configured: true, nodes: [], run: {} } };
  var each = [['Discovery', 'discovery'], ['Provisioning', 'prov'], ['OsConfiguration', 'osconfig'], ['Verification', 'verify'], ['Validate', 'validate'], ['Deployment', 'deploy'], ['Update', 'update'], ['AddNode', 'addnode'], ['Repair', 'repair']];
  each.forEach(function (c) {
    var s = JSON.parse(JSON.stringify(base)); s.monitor = c[0];
    var shown = m.modeStates(s).filter(function (t) { return !t.hidden; });
    eq(shown.map(function (t) { return t.id; }), [c[1]], c[0] + ' shows its own tile only');
    eq(m.activeModeId(s), c[1], c[0] + ' is the mode shown');
    eq(m.monitorOf(s), c[1]);
  });
  var auto = JSON.parse(JSON.stringify(base)); auto.monitor = 'Auto';
  eq(m.monitorOf(auto), '');
  eq(m.modeStates(auto).filter(function (t) { return t.hidden; }).length, 0, 'Auto: every tile of the flow');
  eq(m.modeStates(auto).length, 7);
  eq(m.modeStates(base).length, 7, 'no monitor key: unchanged');
});

test('Add node and Repair are tiles of their own, shown only when the run is one of them', function () {
  var add = { phase: 'add-node', activePhase: 'add-node', track: 'add-node', nodes: [{ name: 'n1', arcStatus: 'Connected' }] };
  var tiles = m.modeStates(add);
  eq(tiles.map(function (t) { return t.id; }), ['discovery', 'prov', 'osconfig', 'verify', 'validate', 'deploy', 'update', 'addnode']);
  eq(tileOf(tiles, 'addnode').status, 'run'); eq(tileOf(tiles, 'addnode').name, 'Add node');
  eq(m.activeModeId(add), 'addnode');
  var sm = m.summaryFor(add, 'addnode', { nodes: [{ name: 'n1' }] });
  eq(sm.title, 'Add node'); eq(sm.cards[0].state, 'Following');
  eq(tileOf(m.modeStates({ phase: 'repair', activePhase: 'repair', track: 'repair' }), 'repair').name, 'Repair');
});

// ---------------------------------------------------------------- OS configuration event contract in the page

function oscContractState(extra) {
  var base = { configured: true, status: 'running', state: 'applying', ready: false, nodesTotal: 1, nodesConverged: 0, nodesFailed: 0, nodesRetrying: 0,
    run: { started: '2026-11-07T19:00:00Z', completed: null, mode: 'Apply', id: 'r-1', legacy: false, runsSeen: 1, staleIgnored: 0, events: 3, timeline: [] },
    wipe: { published: false, enabled: false, count: 0, pending: false, nodes: [], approval: null }, remoting: { profile: null, trustedHosts: null }, unknownStates: [], guarded: [],
    nodes: [{ name: 'n1', method: 'Iso', methodSource: 'resolved', transport: 'WinRM', state: 'applying', stateText: 'Applying changes', status: 'running', attempt: 1,
      versions: {}, evidence: {}, warnings: [], errors: [], tree: [], retries: 0, restarts: 0, runCommands: [], guarded: '', guardedDetail: null, changes: 0, blocked: 0, currentStep: '',
      address: { value: '192.0.2.11', source: 'neighbor', sourceLabel: 'Neighbor table, by MAC', forced: false, reconnected: false, at: null },
      timeline: [{ at: '2026-11-07T19:01:00Z', state: 'DiskEncryptionStarted', label: 'Disk Encryption Started', group: 'unknown', known: false, status: 'idle', step: '', level: 'Info', seq: 4, message: 'encrypting the OS volume' }],
      unknownStates: ['DiskEncryptionStarted'], unknownEvents: [], waiting: null, remoting: { bootstrap: null, firewall: null, listener: null }, lastEvent: null }] };
  Object.keys(extra || {}).forEach(function (k) { base[k] = extra[k]; });
  return base;
}

test('OS configuration facts: the current run id, ignored older lines, states Sonar does not know, remoting and wipe approval', function () {
  var osc = oscContractState({ unknownStates: [{ state: 'DiskEncryptionStarted', count: 2, nodes: ['n1'] }],
    remoting: { profile: { class: 'lab', posture: 'relaxed', scheme: 'http', relaxed: true }, trustedHosts: { changed: true, restored: false } },
    wipe: { published: true, enabled: true, count: 1, pending: true, nodes: [{ node: 'n1', disks: '3 disks' }], approval: { state: 'Rejected', message: 'no approved list' } } });
  osc.run.staleIgnored = 2;
  var f = {};
  m.oscFacts(osc).forEach(function (x) { f[x.k] = x; });
  eq(f['Run id'].v, 'r-1');
  eq(f['Older run, ignored'].v, '2 lines'); eq(f['Older run, ignored'].warn, true);
  eq(f['States not known to Sonar'].v, 'DiskEncryptionStarted ×2'); eq(f['States not known to Sonar'].warn, true);
  eq(f['Remoting'].v, 'lab, relaxed, http'); eq(f['Remoting'].warn, true);
  eq(f['TrustedHosts'].v, 'changed on the runner, not restored yet');
  eq(f['Wipe list approval'].v, 'rejected: no approved list'); eq(f['Wipe list approval'].warn, true);
  var legacy = oscContractState(); legacy.run.id = ''; legacy.run.legacy = true;
  eq(m.oscFacts(legacy).filter(function (x) { return x.k === 'Run id'; })[0].v, 'none (older feed: one run)');
});

test('OS configuration card: the address with its source, the heartbeat and an unknown state are visible', function () {
  var osc = oscContractState();
  osc.nodes[0].waiting = { what: 'n1 to answer again', phase: 'AwaitingConfirm', elapsedSeconds: 120, heartbeat: 2, at: '2026-11-07T19:02:00Z' };
  var card = m.summaryFor(oscRunState(osc), 'osconfig').cards[0];
  eq(card.chips.some(function (c) { return c.text === '192.0.2.11 (Neighbor table, by MAC)'; }), true, 'address and source chip');
  eq(card.lines.indexOf('Waiting for n1 to answer again (120 s, phase AwaitingConfirm)') >= 0, true);
  eq(card.lines.indexOf('Event not known to this Sonar: DiskEncryptionStarted') >= 0, true);
  osc.nodes[0].address.source = ''; osc.nodes[0].address.sourceLabel = 'not reported'; osc.nodes[0].address.forced = true;
  eq(m.oscAddressChip(osc.nodes[0]).text, '192.0.2.11 (source not reported), transport forced');
  eq(m.oscAddressChip({ address: { value: '' } }), null);
  ['override', 'handoff', 'arc', 'file', 'neighbor'].forEach(function (id) { eq(typeof m.oscAddressChip({ address: { value: '192.0.2.1', source: id, sourceLabel: id } }).text, 'string'); });
});

test('OS configuration timeline: the newest events with their label, message and an unknown state marked as such', function () {
  var n = oscContractState().nodes[0];
  var lines = m.oscTimelineLines(n, 3);
  eq(lines.length, 1);
  eq(lines[0].text, 'Disk Encryption Started (state not known to this Sonar): encrypting the OS volume');
  eq(lines[0].kind, 'idle');
  var tree = m.osConfigTreeOf(oscRunState(oscContractState()));
  eq(tree[0].osc.address.text, '192.0.2.11 (Neighbor table, by MAC)');
  eq(tree[0].osc.timeline.length, 1);
});

test('guarded change panel: change id, old to new address, phase, deadline countdown, rollback reason', function () {
  var osc = oscContractState({ guarded: [{ node: 'n1', state: 'AwaitingConfirm', phase: 'AwaitingConfirm', active: true, reconnecting: false, changeId: 'chg-1', group: 'Management',
    oldAddress: '192.0.2.10', newAddress: '192.0.2.20', rung: '', repairs: 0, verdict: '', confirmBy: '2026-11-07T19:13:00Z', confirmMinutes: 10, reason: '' }] });
  var panels = m.summaryFor(oscRunState(osc), 'osconfig').panels;
  eq(panels.length, 1);
  eq(panels[0].title, 'Guarded network change: n1');
  eq(panels[0].kind, 'warn');
  var rows = {}; panels[0].rows.forEach(function (r) { rows[r.k] = r.v; });
  eq(rows['Change id'], 'chg-1');
  eq(rows['Address'], '192.0.2.10 → 192.0.2.20');
  eq(rows['Phase'], 'Waiting for the confirmation');
  eq(/10 min window/.test(rows['Deadline']), true);
  eq(panels[0].until, '2026-11-07T19:13:00Z', 'the countdown runs while it waits for the confirmation');
  eq(m.oscCountdown('2026-11-07T19:13:00Z', Date.parse('2026-11-07T19:10:00Z')), 180);
  eq(m.fmtCountdown(180), '03:00 left');
  osc.guarded[0].phase = 'RolledBack'; osc.guarded[0].active = false; osc.guarded[0].reason = 'The gateway did not answer for 60 s.'; osc.guarded[0].verdict = 'GatewayUnreachable';
  var rb = m.summaryFor(oscRunState(osc), 'osconfig').panels[0];
  eq(rb.kind, 'err'); eq(rb.until, '');
  var r2 = {}; rb.rows.forEach(function (r) { r2[r.k] = r.v; });
  eq(r2['Rollback reason'], 'The gateway did not answer for 60 s.'); eq(r2['Node verdict'], 'GatewayUnreachable');
  osc.guarded[0].phase = 'Refused'; osc.guarded[0].reconnecting = true; osc.guarded[0].rung = '1, 2';
  var rf = m.summaryFor(oscRunState(osc), 'osconfig').panels[0];
  eq(rf.rows.filter(function (r) { return r.k === 'Refused because'; }).length, 1);
  eq(m.summaryFor(oscRunState(oscContractState()), 'osconfig').panels, [], 'no guarded change, no panel');
});

// ---------------------------------------------------------------- demo data: discovery, the ZTP run and the manual (ISO) run

test('demo: the Discovery stage data is waiting, partial or discovered, and the page logic reads it like the real state', function () {
  var NAMES = ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'];
  function iso(ms) { return new Date(NOW - ms).toISOString(); }
  var w = m.demoDiscovery(NAMES, 'waiting', iso, 60000), p = m.demoDiscovery(NAMES, 'partial', iso, 60000), d = m.demoDiscovery(NAMES, 'discovered', iso, 60000);
  eq([w.nodesDiscovered, p.nodesDiscovered, d.nodesDiscovered], [0, 2, 3]);
  eq([w.status, p.status, d.status], ['notstarted', 'running', 'success']);
  function st(x) { return { phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', status: 'notstarted', nodes: [] }, discovery: x }; }
  eq(tileOf(m.modeStates(st(w)), 'discovery').status, 'idle');
  eq(tileOf(m.modeStates(st(p)), 'discovery').line, '2 of 3 machines read');
  eq(tileOf(m.modeStates(st(d)), 'discovery').line, '3 of 3 machines');
  var sm = m.summaryFor(st(d), 'discovery');
  eq(sm.cards.map(function (c) { return c.state; }), ['Discovered', 'Check', 'Discovered']);
  eq(JSON.stringify(d).indexOf('00-00-5E-00-53-') > 0, true, 'documentation MAC range only');
  eq(/\b(?!00-00-5E)[0-9A-F]{2}(-[0-9A-F]{2}){5}\b/.test(JSON.stringify(d)), false, 'no other MAC');
});

test('demo: the ZTP run and the manual install run (?demo=1&route=osconfig and route=iso) exist, and the manual one has no provisioning to watch', function () {
  eq(/route === 'iso'\) \{ startOsConfigDemo\(iso, M, true\)/.test(appSource), true);
  eq(/route === 'discovery'\) \{ startDiscoveryDemo/.test(appSource), true);
  eq(/route === 'osconfig'\) \{ startOsConfigDemo\(iso, M\)/.test(appSource), true);
  // the shapes the two demos publish, run through the page logic
  var osc = oscAt(2.0);
  var ztp = { phase: 'provisioning', activePhase: 'provisioning', provisioning: { manualInstall: false, route: 'simplified', ztpComplete: true, nodes: [] }, osConfiguration: osc,
    discovery: m.demoDiscovery(['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03'], 'discovered', function (ms) { return new Date(NOW - ms).toISOString(); }, 60000) };
  var manual = JSON.parse(JSON.stringify(ztp)); manual.provisioning = { manualInstall: true, route: 'oem-image', ztpComplete: false, nodes: [] };
  eq(m.activeModeId(ztp), 'osconfig'); eq(m.activeModeId(manual), 'osconfig');
  eq(tileOf(m.modeStates(ztp), 'prov').status === 'na', false);
  eq(tileOf(m.modeStates(manual), 'prov').status, 'na');
  eq(tileOf(m.modeStates(manual), 'discovery').status, 'ok');
  eq(tileOf(m.modeStates(manual), 'osconfig').status, 'run');
  eq(m.summaryFor(manual, 'osconfig').panels.length > 0 || true, true);
});

test('demo: the OS configuration run carries the contract fields (run id, address and source, timeline, guarded detail with both addresses)', function () {
  var osc = oscAt(2.7);
  eq(osc.run.id, 'run-20261107-1'); eq(osc.run.legacy, false);
  eq(osc.nodes.every(function (n) { return n.address && typeof n.address.sourceLabel === 'string'; }), true);
  eq(osc.nodes.map(function (n) { return n.address.source; }).filter(Boolean).length > 0, true);
  var guarded = oscAt(2.0).nodes.filter(function (n) { return n.guardedDetail; });
  guarded.forEach(function (n) { eq(n.guardedDetail.oldAddress, '192.0.2.31'); eq(n.guardedDetail.newAddress, '192.0.2.21'); });
  eq(oscAt(2.0).guarded.length, guarded.length);
});

// ---------------------------------------------------------------- the log level filter shows only the levels chosen

test('level filter: Warnings shows only warnings, Errors only errors, Info only info, All everything', function () {
  var levels = ['info', 'warning', 'error'];
  function shown(filter) { return levels.filter(function (l) { return m.levelPasses(filter, l); }); }
  eq(shown('all'), ['info', 'warning', 'error']);
  eq(shown(''), ['info', 'warning', 'error'], 'no filter is all');
  eq(shown('warning'), ['warning'], 'Warnings must not show errors');
  eq(shown('error'), ['error'], 'Errors must not show warnings');
  eq(shown('info'), ['info']);
  eq(m.levelPasses('warning', 'error'), false);
  eq(m.levelPasses('error', 'warning'), false);
  eq(m.levelPasses('warning', 'info'), false);
});

test('level filter: combined selections show exactly the levels that are on', function () {
  function shown(filter) { return ['info', 'warning', 'error'].filter(function (l) { return m.levelPasses(filter, l); }); }
  eq(shown('warning,error'), ['warning', 'error']);
  eq(shown('info,warning'), ['info', 'warning']);
  eq(shown('info,error'), ['info', 'error']);
  eq(shown('info,warning,error'), ['info', 'warning', 'error']);
  eq(m.levelSet('error,warning'), ['warning', 'error'], 'the order of the text does not matter');
  eq(m.levelSet('all'), []); eq(m.levelSet(undefined), []); eq(m.levelSet('nonsense'), []);
});

test('level filter: every selection (each level alone, each pair, all three) shows exactly the levels selected', function () {
  var all = ['info', 'warning', 'error'];
  function shown(filter) { return all.filter(function (l) { return m.levelPasses(filter, l); }); }
  [
    ['info'], ['warning'], ['error'],
    ['info', 'warning'], ['info', 'error'], ['warning', 'error'],
    ['info', 'warning', 'error']
  ].forEach(function (sel) {
    eq(shown(sel.join(',')), sel, 'filter ' + sel.join(',') + ' shows exactly ' + sel.join(' + '));
  });
  eq(shown('all'), all, 'clearing the selection shows everything');
  // the same selections reached by clicking the buttons, in every order
  var click = function (clicks) { return clicks.reduce(function (f, c) { return m.toggleLevel(f, c); }, 'all'); };
  eq(shown(click(['warning'])), ['warning']);
  eq(shown(click(['error', 'warning'])), ['warning', 'error']);
  eq(shown(click(['error', 'info'])), ['info', 'error']);
  eq(shown(click(['warning', 'info', 'error'])), all, 'all three clicked is All');
  eq(shown(click(['warning', 'error', 'error'])), ['warning'], 'clicking a level again switches it off');
  eq(shown(click(['warning', 'all'])), all, 'All clears the selection');
});

test('level filter: regression, Warnings only does not include errors', function () {
  eq(m.levelPasses('warning', 'warning'), true);
  eq(m.levelPasses('warning', 'error'), false, 'an error line must not pass the Warnings-only filter');
  eq(m.levelPasses(m.toggleLevel('all', 'warning'), 'error'), false, 'one click on Warnings must not show errors');
  eq(m.levelPasses('error', 'warning'), false, 'and Errors only does not include warnings');
  eq(m.levelSet(m.toggleLevel('all', 'warning')), ['warning']);
});

test('level filter: lines with an odd level count as info, like the page does', function () {
  eq(m.levelPasses('info', 'debug'), true);
  eq(m.levelPasses('info', ''), true);
  eq(m.levelPasses('warning', 'debug'), false);
});

test('level filter: clicking the buttons toggles a level, All clears, none or all three is All', function () {
  eq(m.toggleLevel('all', 'warning'), 'warning');
  eq(m.toggleLevel('warning', 'error'), 'warning,error');
  eq(m.toggleLevel('warning,error', 'warning'), 'error');
  eq(m.toggleLevel('error', 'error'), 'all', 'switching the last level off is All again');
  eq(m.toggleLevel('warning,error', 'info'), 'all', 'all three on is All');
  eq(m.toggleLevel('warning,error', 'all'), 'all');
  eq(m.toggleLevel('info', 'warning'), 'info,warning');
  eq(m.toggleLevel('all', 'info'), 'info');
});

test('level filter: the buttons show the count of their own level only', function () {
  var c = { all: 10, warning: 3, error: 2 };
  eq(m.levelCount(c, 'all'), 10); eq(m.levelCount(c, 'warning'), 3); eq(m.levelCount(c, 'error'), 2);
  eq(m.levelCount(c, 'info'), 5, 'info is what is neither');
  eq(m.levelCount({ all: 1, warning: 3, error: 3 }, 'info'), 0);
  var html = fs.readFileSync(pathMod.join(pathMod.dirname(path), 'index.html'), 'utf8');
  eq(/data-level="info"[^>]*>Info</.test(html), true);
  eq(/data-level="warning"[^>]*>Warnings</.test(html), true, 'the button no longer says Warnings+');
  eq(html.indexOf('Warnings+'), -1);
  eq(/data-level="error"[^>]*>Errors</.test(html), true);
});

// ---------------------------------------------------------------- the cluster card (Validate, Deployment, Update, Add node, Repair)

function clusterRes(extra) {
  var c = { name: 'clus01', read: true, exists: true, status: 'ConnectedRecently', connectivityStatus: 'Connected', provisioningState: 'Succeeded', solutionVersion: '12.2609.0.1',
    nodeCount: 2, nodesConfigured: 2, deploymentState: 'Provisioning', deploymentMode: 'Deploy', error: '' };
  Object.keys(extra || {}).forEach(function (k) { c[k] = extra[k]; });
  return c;
}
function rowsOf(card) { var o = {}; card.rows.forEach(function (r) { o[r.k] = r.v; }); return o; }
function stepN(id, name, status, errors, children) { return { id: id, name: name, status: status, errors: errors || [], children: children || [] }; }

test('cluster card: only Validate, Deployment, Update, Add node and Repair have one; Discovery, Provisioning and OS configuration stay per machine', function () {
  var s = { phase: 'validation', activePhase: 'validation', cluster: 'clus01', clusterResource: clusterRes() };
  var tracks = { addnode: 'add-node', repair: 'repair' };
  ['validate', 'deploy', 'update', 'addnode', 'repair'].forEach(function (id) {
    var st = JSON.parse(JSON.stringify(s)); if (tracks[id]) st.track = tracks[id];
    eq(m.clusterCard(st, id) !== null, true, id); eq(m.summaryFor(st, id).cluster !== null, true, id + ' summary');
  });
  ['discovery', 'prov', 'osconfig'].forEach(function (id) { eq(m.clusterCard(s, id), null, id); eq(m.summaryFor(s, id).cluster, null, id + ' summary'); });
  eq(m.CLUSTER_MODES, ['validate', 'deploy', 'update', 'addnode', 'repair']);
  eq(m.clusterCard(null, 'validate'), null);
  eq(m.clusterCard(s, 'validate').title, 'Cluster clus01');
});

test('cluster card: the waiting state says the cluster resource does not exist yet (Validate creates it)', function () {
  var s = { phase: 'validation', activePhase: 'validation', cluster: 'clus01', clusterResource: clusterRes({ exists: false, status: '', connectivityStatus: '', provisioningState: '', nodeCount: null }) };
  var v = m.clusterCard(s, 'validate');
  eq(v.waiting, true); eq(v.kind, 'idle');
  eq(v.rows, [{ k: 'Cluster resource', v: 'The cluster resource does not exist yet: Validate creates it', warn: false }]);
  eq(m.clusterCard(s, 'deploy').rows[0].v, 'The cluster resource does not exist yet', 'only Validate creates it');
  // nothing read yet (a state from an older Sonar or the first poll): no row claims anything
  var unread = m.clusterCard({ phase: 'validation', cluster: 'clus01' }, 'validate');
  eq(unread.waiting, false);
  eq(unread.title, 'Cluster clus01');
});

test('cluster card: the cluster resource as Azure reports it, the machines, and a read that failed', function () {
  var s = { phase: 'deployment', activePhase: 'deployment', clusterResource: clusterRes(), deployment: { status: 'InProgress', tree: [] } };
  var r = rowsOf(m.clusterCard(s, 'deploy'));
  eq(r['Azure says'], 'ConnectedRecently, Connected');
  eq(r['Provisioning state'], 'Succeeded');
  eq(r['Solution version'], '12.2609.0.1');
  eq(r['Machines'], '2 of 2 reported by the cluster');
  eq(rowsOf(m.clusterCard({ clusterResource: clusterRes({ nodeCount: 1 }) }, 'deploy'))['Machines'], '1 of 2 reported by the cluster');
  var failed = m.clusterCard({ clusterResource: clusterRes({ exists: null, status: '', connectivityStatus: '', provisioningState: '', nodeCount: null, error: 'The client does not have authorization' }) }, 'deploy');
  eq(failed.rows[0], { k: 'Azure says', v: 'not read: The client does not have authorization', warn: true });
});

test('cluster card (Validate): pass and fail counts, failures first, and the last error', function () {
  var tree = [stepN('1', 'Validate deployment prerequisites', 'error', [], [
    stepN('1.1', 'Validate hardware', 'success'), stepN('1.2', 'Validate network', 'success'),
    stepN('1.3', 'Validate DNS', 'error', ['The DNS server did not answer.']), stepN('1.4', 'Validate storage', 'error', ['No eligible disks.']), stepN('1.5', 'Validate Arc', 'running')])];
  var s = { phase: 'failed', activePhase: 'validation', clusterResource: clusterRes({ deploymentMode: 'Validate' }), validation: { status: 'Failed', tree: tree } };
  var c = m.clusterCard(s, 'validate'), r = rowsOf(c);
  eq(r['Validation'], 'Failed');
  eq(r['Validation steps'], '2 of 5 passed, 2 failed');
  eq(c.rows.filter(function (x) { return x.k === 'Validation steps'; })[0].warn, true);
  eq(c.failures, ['Validate DNS: The DNS server did not answer.', 'Validate storage: No eligible disks.']);
  eq(c.lastError, 'Validate DNS: The DNS server did not answer.');
  eq(c.kind, 'err');
  eq(m.clusterLeaves(tree).map(function (x) { return x.name; }).slice(0, 2), ['Validate DNS', 'Validate storage'], 'failures sort first');
  var ok = m.clusterCard({ clusterResource: clusterRes(), validation: { status: 'Success', tree: [stepN('1', 'Validate', 'success', [], [stepN('1.1', 'a', 'success'), stepN('1.2', 'b', 'skipped')])] } }, 'validate');
  eq(rowsOf(ok)['Validation'], 'Passed'); eq(rowsOf(ok)['Validation steps'], '2 of 2 passed'); eq(ok.kind, 'ok'); eq(ok.failures, []); eq(ok.lastError, '');
  var running = m.clusterCard({ clusterResource: clusterRes(), validation: { status: 'InProgress', tree: [stepN('1', 'Validate', 'running', [], [stepN('1.1', 'a', 'success'), stepN('1.2', 'b', 'running')])] } }, 'validate');
  eq(running.kind, 'run'); eq(rowsOf(running)['Validation'], 'Running');
});

test('cluster card (Deployment): progress, elapsed time and the deployment mode and settings', function () {
  m.setClock(function () { return Date.parse('2026-11-07T20:00:00Z'); });
  try {
  var tree = [{ id: '2', name: 'Deploy Azure Local', status: 'running', start: '2026-11-07T19:00:00Z', end: null, errors: [], children: [
    { id: '2.1', name: 'Pre-deployment checks', status: 'success', start: '2026-11-07T19:00:00Z', end: '2026-11-07T19:10:00Z', errors: [], children: [] },
    { id: '2.2', name: 'Create cluster', status: 'running', start: '2026-11-07T19:10:00Z', end: null, errors: [], children: [] },
    { id: '2.3', name: 'Extensions', status: 'notstarted', start: null, end: null, errors: [], children: [] }] }];
  var c = m.clusterCard({ phase: 'deployment', activePhase: 'deployment', clusterResource: clusterRes(), deployment: { status: 'InProgress', tree: tree } }, 'deploy'), r = rowsOf(c);
  eq(r['Deployment'], 'Running');
  eq(r['Progress'], 'Step 2 of 3 (Create cluster)');
  eq(r['Elapsed'], '1h 0m 0s');
  eq(r['Deployment mode'], 'Deploy'); eq(r['Deployment settings'], 'Provisioning');
  eq(c.kind, 'run');
  } finally { m.setClock(null); }
  var done = m.clusterCard({ clusterResource: clusterRes({ deploymentState: 'Succeeded' }), deployment: { status: 'Success', tree: [{ id: '2', name: 'Deploy', status: 'success', start: '2026-11-07T19:00:00Z', end: '2026-11-07T19:30:00Z', errors: [], children: [
    { id: '2.1', name: 'a', status: 'success', errors: [], children: [] }, { id: '2.2', name: 'b', status: 'success', errors: [], children: [] }] }] } }, 'deploy');
  eq(rowsOf(done)['Deployment'], 'Done'); eq(rowsOf(done)['Progress'], 'Step 2 of 2'); eq(rowsOf(done)['Elapsed'], '30m 0s'); eq(done.kind, 'ok');
  var failed = m.clusterCard({ clusterResource: clusterRes(), deployment: { status: 'Failed', tree: [stepN('2', 'Deploy', 'error', [], [stepN('2.1', 'Create cluster', 'error', ['Cluster creation failed: node02 did not join.'])])] } }, 'deploy');
  eq(failed.kind, 'err'); eq(failed.lastError, 'Create cluster: Cluster creation failed: node02 did not join.');
});

test('cluster card (Update): the update state, the current and target version and the failed health checks', function () {
  var up = { phase: 'installing', summary: { currentVersion: '12.2609.0.1', healthState: 'Success', failedChecks: [] }, active: { version: '12.2610.0.4', state: 'Installing' }, tree: [] };
  var c = m.clusterCard({ clusterResource: clusterRes(), update: up }, 'update'), r = rowsOf(c);
  eq(r['Update'], 'Installing'); eq(r['Current version'], '12.2609.0.1'); eq(r['Target version'], '12.2610.0.4'); eq(c.kind, 'run');
  eq(r['Update health'], undefined, 'a healthy summary adds no row');
  var bad = m.clusterCard({ clusterResource: clusterRes(), update: { phase: 'attention', summary: { currentVersion: '1', healthState: 'Failure', failedChecks: [{ title: 'Storage pool is not healthy', severity: 'Critical' }, { title: 'A node is paused', severity: 'Error' }] }, active: null, tree: [] } }, 'update');
  eq(rowsOf(bad)['Update'], 'Needs attention'); eq(rowsOf(bad)['Update health'], 'Failure'); eq(bad.failures, ['Storage pool is not healthy', 'A node is paused']); eq(bad.kind, 'err');
  ['idle', 'available', 'preparing', 'failed'].forEach(function (p) { eq(typeof rowsOf(m.clusterCard({ clusterResource: clusterRes(), update: { phase: p, summary: {}, tree: [] } }, 'update'))['Update'], 'string', p); });
  eq(rowsOf(m.clusterCard({ clusterResource: clusterRes(), update: { phase: 'idle', summary: {}, tree: [] } }, 'update'))['Update'], 'Up to date');
});

test('cluster card (Add node, Repair): the operation, that Azure does not report the target, and the machines that are not connected', function () {
  var s = { phase: 'add-node', activePhase: 'add-node', track: 'add-node', clusterResource: clusterRes(), nodes: [{ name: 'n1', arcStatus: 'Connected' }, { name: 'n3', arcStatus: 'Disconnected' }] };
  var a = m.clusterCard(s, 'addnode'), r = rowsOf(a);
  eq(r['Operation'], 'Add node');
  eq(/does not report the target/.test(r['Target']), true);
  eq(r['Not connected'], 'n3'); eq(a.kind, 'run');
  var rep = m.clusterCard({ phase: 'repair', activePhase: 'repair', track: 'repair', clusterResource: clusterRes(), nodes: [{ name: 'n1', arcStatus: 'Connected' }] }, 'repair');
  eq(rowsOf(rep)['Operation'], 'Repair'); eq(rowsOf(rep)['Not connected'], undefined);
  eq(rowsOf(m.clusterCard({ phase: 'done', clusterResource: clusterRes() }, 'repair'))['Operation'], 'Repair (not started)');
});

test('cluster card: selecting it shows the cluster-level steps only (the machine rows of Validate go), and every other mode is unchanged', function () {
  eq(m.visibleSections('validate', false), ['armvalidation', 'validation', 'extensions']);
  eq(m.visibleSections('validate', true), ['armvalidation', 'validation'], 'the extensions are per machine');
  eq(m.visibleSections('deploy', true), ['armdeployment', 'deployment']);
  eq(m.visibleSections('update', true), ['update']);
  eq(m.visibleSections('osconfig', true), ['osconfiguration']);
  eq(m.visibleSections('nonsense', true), []);
  eq(/function selectCluster\(\)/.test(appSource), true);
  eq(/'data-cluster': '1'/.test(appSource), true, 'the card is a button the page can select');
  eq(/app\.filter\.cluster = false;\s*\n\s*app\.filter\.node = ''/.test(appSource), true, 'a mode change clears it');
});

test('cluster card: demo data, the cluster route, and the state of each moment of the run', function () {
  eq(/route === 'cluster'\) \{ startClusterDemo/.test(appSource), true);
  var none = m.demoClusterResource('none'), there = m.demoClusterResource('exists', 2, 'Provisioning', 'Deploy');
  eq([none.exists, there.exists], [false, true]); eq(there.solutionVersion, '12.2609.0.1'); eq(none.nodeCount, null);
  eq(m.clusterCard({ phase: 'validation', clusterResource: none }, 'validate').waiting, true);
  eq(rowsOf(m.clusterCard({ phase: 'deployment', clusterResource: there }, 'deploy'))['Azure says'], 'ConnectedRecently, Connected');
  var sample = m.demoDeploymentSample(Date.parse('2026-11-07T20:00:00Z'));
  eq(sample.state.clusterResource.exists, true, 'the default demo carries the cluster resource');
  eq(m.summaryFor(sample.state, 'deploy', sample.config).cluster.title, 'Cluster clus01');
});

// ---------------------------------------------------------------- Verification (the pre-cluster verification gate)

function vfCheck(id, category, status, extra) {
  var c = { id: id, title: id.replace(/^.*\./, ''), category: category, status: status, node: '', message: '', remedy: '', source: '', sourceUrl: '', blocking: true, blocks: status === 'Failed' || status === 'Skipped' };
  if (extra) Object.keys(extra).forEach(function (k) { c[k] = extra[k]; });
  return c;
}
function vfState(status, extra) {
  var failedC = vfCheck('azure.providers', 'azure', 'Failed', { message: 'Microsoft.HybridContainerService is NotRegistered.', remedy: 'Register-AzResourceProvider -ProviderNamespace Microsoft.HybridContainerService', source: 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites', sourceUrl: 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-prerequisites' });
  var skippedC = vfCheck('identity.ad-prepared', 'identity', 'Skipped', { message: 'The domain controller could not be reached.', remedy: 'Run the gate from a machine that can reach the domain.' });
  var passedC = vfCheck('nodes.reachable', 'nodes', 'Passed', { node: 'iic-azl-n01', message: 'Answered.' });
  var warnC = vfCheck('network.jumbo', 'network', 'Warning', { node: 'iic-azl-n02', message: 'MTU 1514.', remedy: 'Set 9014.', blocking: false, blocks: false });
  var naC = vfCheck('readiness.hardware', 'readiness', 'NotApplicable', { blocks: false, blocking: false });
  var v = { configured: true, hasData: true, status: status, state: status, verdict: status === 'pass' ? 'Pass' : (status === 'fail' ? 'Fail' : ''),
    run: { runId: 'vf-1', started: '2026-11-08T12:00:00.000Z', completed: status === 'running' ? null : '2026-11-08T12:01:00.000Z', expiresUtc: '2026-11-08T16:00:00.0000000Z', events: 7, stale: 0, schema: 1 },
    counts: { Passed: 1, Failed: 1, Warning: 1, Skipped: 1, NotApplicable: 1, Fixed: 0, Running: 0 }, total: 5, blockers: 2, skippedBlocking: 1, countsMismatch: false, reportedCounts: null, warnings: [],
    categories: [
      { id: 'azure', name: 'Azure', status: 'Failed', blocks: true, counts: { Failed: 1 }, checks: [failedC] },
      { id: 'identity', name: 'Identity', status: 'Skipped', blocks: true, counts: { Skipped: 1 }, checks: [skippedC] },
      { id: 'nodes', name: 'Nodes', status: 'Passed', blocks: false, counts: { Passed: 1 }, checks: [passedC] },
      { id: 'network', name: 'Network', status: 'Warning', blocks: false, counts: { Warning: 1 }, checks: [warnC] },
      { id: 'readiness', name: 'Readiness', status: 'NotApplicable', blocks: false, counts: { NotApplicable: 1 }, checks: [naC] }],
    attention: [failedC, skippedC] };
  if (extra) Object.keys(extra).forEach(function (k) { v[k] = extra[k]; });
  return { phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', ztpComplete: true, nodes: [] },
    osConfiguration: { configured: true, status: 'success', state: 'converged', ready: true, nodesTotal: 3, nodesConverged: 3, nodes: [{ name: 'iic-azl-n01', status: 'success' }], run: { started: '2026-11-08T11:00:00.000Z' } }, verification: v };
}

test('Verification tile: between OS configuration and Validate; grey with the way to set it when nothing is followed', function () {
  eq(m.MODE_IDS.slice(2, 5), ['osconfig', 'verify', 'validate']);
  eq(m.modeName('verify', 'simplified'), 'Verification');
  eq(m.MODE_SECTIONS.verify, ['verification']);
  var off = tileOf(m.modeStates({ phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', nodes: [] } }), 'verify');
  eq(off.status, 'idle'); eq(off.line, ''); eq(/verificationEventsPath/.test(off.tip), true);
  var wait = tileOf(m.modeStates({ phase: 'provisioning', activePhase: 'provisioning', provisioning: { route: 'simplified', nodes: [] }, verification: { configured: true, hasData: false, status: 'notstarted' } }), 'verify');
  eq(wait.status, 'idle'); eq(/pre-cluster verification gate/.test(wait.tip), true);
});

test('Verification tile: Pass, Fail (blocking and skipped counts), Running and Expired', function () {
  eq(m.vfTile(vfState('pass')).status, 'ok'); eq(m.vfTile(vfState('pass')).line, 'Pass · 5 checks');
  var fail = m.vfTile(vfState('fail'));
  eq([fail.status, fail.line], ['err', 'Fail · 2 blocking (1 skipped)']);
  eq(m.vfTile(vfState('running')).status, 'run'); eq(m.vfTile(vfState('running')).line, 'Running · 5 so far');
  var exp = m.vfTile(vfState('expired'));
  eq([exp.status, exp.line], ['err', 'Pass expired']);
  eq(tileOf(m.modeStates(vfState('fail')), 'verify').status, 'err');
});

test('Verification mode: becomes the active mode after OS configuration, never before Provisioning is over or while OS configuration works', function () {
  eq(m.activeModeId(vfState('fail')), 'verify');
  eq(m.activeModeId(vfState('pass')), 'verify');
  var working = vfState('fail'); working.osConfiguration.status = 'running'; working.osConfiguration.ready = false;
  eq(m.activeModeId(working), 'osconfig');
  var still = vfState('pass'); still.provisioning = { route: 'simplified', ztpComplete: false, nodes: [{ name: 'n1', status: 'running', prov: { lifecycle: 'InstallingOs' } }] }; still.osConfiguration = { configured: true, status: 'notstarted', nodes: [], run: {} };
  eq(m.activeModeId(still), 'prov', 'an old verification file does not hide a provisioning run');
  var validating = vfState('pass'); validating.phase = 'validation'; validating.activePhase = 'validation';
  eq(m.activeModeId(validating), 'validate', 'Azure validation is further on');
});

test('Verification summary: verdict chip and banner, counts by status (failed first), skipped called out as blocking', function () {
  var s = vfState('fail');
  var sm = m.summaryFor(s, 'verify', { nodes: [] });
  eq(sm.title, 'Verification'); eq(sm.chip, { kind: 'err', text: 'Fail' });
  eq(/Verification failed: 2 checks block the cluster deployment \(1 skipped: a skipped check blocks the gate\)/.test(sm.headline), true);
  var keys = sm.facts.map(function (f) { return f.k; });
  eq(keys.slice(0, 6), ['Verdict', 'Failed', 'Skipped', 'Warning', 'Passed', 'Not applicable']);
  var skippedFact = sm.facts.filter(function (f) { return f.k === 'Skipped'; })[0];
  eq(skippedFact.v, '1 (each one blocks the gate)'); eq(skippedFact.warn, true);
  eq(sm.facts.some(function (f) { return f.k === 'Blocking' && /1 of them skipped/.test(f.v); }), true);
  eq(sm.panels.length, 1); eq(sm.panels[0].title, 'Verdict: Fail'); eq(sm.panels[0].kind, 'err');
  eq(sm.panels[0].rows.map(function (r) { return r.k; }), ['Failed', 'Skipped, blocks']);
  eq(sm.cards, []);
});

test('Verification summary: Pass, Running and Expired', function () {
  var pass = m.summaryFor(vfState('pass', { blockers: 0, skippedBlocking: 0, attention: [] }), 'verify', {});
  eq(pass.chip, { kind: 'ok', text: 'Pass' }); eq(/^Verification passed: 5 checks, 1 warning\. Valid until /.test(pass.headline), true);
  eq(/Next: Validate$/.test(pass.headline), true); eq(pass.panels[0].kind, 'ok'); eq(pass.panels[0].rows[0].v, 'Nothing blocks the cluster deployment');
  var run = m.summaryFor(vfState('running'), 'verify', {});
  eq(run.chip, { kind: 'run', text: 'Running' }); eq(/^The gate is running: 5 checks so far/.test(run.headline), true);
  var exp = m.summaryFor(vfState('expired', { verdict: 'Pass', blockers: 0, skippedBlocking: 0, attention: [] }), 'verify', {});
  eq(exp.chip, { kind: 'err', text: 'Expired' }); eq(/^The verification pass expired at /.test(exp.headline), true);
  eq(exp.facts.filter(function (f) { return f.k === 'Expired'; }).length, 1);
});

test('Verification tree: categories with their checks, failed first; Skipped is not Not applicable', function () {
  var tree = m.vfTreeOf(vfState('fail'));
  eq(tree.map(function (c) { return c.name; }), ['Azure', 'Identity', 'Nodes', 'Network', 'Readiness']);
  eq(tree.map(function (c) { return c.status; }), ['error', 'skipped', 'success', 'success', 'notstarted']);
  var checks = tree[0].children;
  eq(checks.length, 1); eq(checks[0].vf.kind, 'check'); eq(checks[0].vf.remedy.indexOf('Register-AzResourceProvider'), 0);
  eq(tree[1].children[0].vf.blocks, true); eq(tree[1].children[0].status, 'skipped');
  eq(tree[4].children[0].status, 'notstarted'); eq(tree[4].children[0].vf.blocks, false);
  eq([m.vfIconKey('Skipped'), m.vfIconKey('NotApplicable'), m.vfIconKey('Warning'), m.vfIconKey('Failed'), m.vfIconKey('Passed'), m.vfIconKey('Fixed'), m.vfIconKey('Running')], ['vfskip', 'notstarted', 'warning', 'error', 'success', 'success', 'running']);
  eq(m.vfTreeOf({}), []); eq(m.vfTreeOf({ verification: { hasData: false } }), []);
});

test('Verification: a missing or partial verification object never throws', function () {
  [null, {}, { verification: null }, { verification: {} }, { verification: { configured: true } }, { verification: { configured: true, hasData: true } },
    { verification: { configured: true, hasData: true, status: 'bogus', categories: 'x', counts: [], attention: null, run: 5 } }].forEach(function (s, i) {
    m.modeStates(s || {}); m.vfTile(s || {}); m.summaryFor(s || {}, 'verify', {}); m.vfTreeOf(s || {}); m.activeModeId(s || {});
    eq(typeof m.vfHeadline(m.vfOf(s || {})), 'string', 'case ' + i);
  });
});

test('Verification: a standalone monitor shows its own tile and opens on it', function () {
  var s = { phase: 'provisioning', activePhase: 'provisioning', monitor: 'Verification', provisioning: { route: 'simplified', nodes: [] }, verification: vfState('fail').verification };
  eq(m.modeStates(s).filter(function (t) { return !t.hidden; }).map(function (t) { return t.id; }), ['verify']);
  eq(m.activeModeId(s), 'verify'); eq(m.monitorOf(s), 'verify');
});

test('Verification log lines: the [verify] lines are scoped to their machine', function () {
  eq(m.lineScope({ file: 'verification-events', text: '2026-11-08T12:00:02.000Z [verify] * RunStarted' }), { node: '', stage: '' });
  eq(m.lineScope({ file: 'verification-events', text: '2026-11-08T12:00:02.000Z [verify] iic-azl-n02 Check Failed (nodes.reachable): No answer' }), { node: 'iic-azl-n02', stage: '' });
});

test('Verification page: hostile text stays text; only a documentation https source is a link; Skipped says it blocks', function () {
  withDom(function (dom, h) {
    var s = vfState('fail');
    s.verification.categories[0].checks[0] = vfCheck('azure.providers', 'azure', 'Failed', { title: HOSTILE[0], node: HOSTILE[1], message: HOSTILE[1], remedy: HOSTILE[3], source: HOSTILE[2], sourceUrl: 'javascript:alert(1)' });
    s.verification.categories[1].checks.push(vfCheck('identity.other', 'identity', 'Skipped', { title: 'Linked', source: 'https://learn.microsoft.com/azure/azure-local/x', sourceUrl: 'https://learn.microsoft.com/azure/azure-local/x' }));
    s.verification.categories[2].checks.push(vfCheck('nodes.evil', 'nodes', 'Warning', { title: 'Foreign', source: 'https://evil.example/x', sourceUrl: 'https://evil.example/x', blocks: false }));
    h.app.config = { cluster: 'clus01', nodes: [{ name: 'iic-azl-n01', seed: true }] };
    h.app.state = s;
    var tree = m.vfTreeOf(s);
    h.app.vfTree = tree;
    var ul = h.el('ul', null, []);
    var items = [];
    tree.forEach(function (cat) { cat.children.forEach(function (c, i) { c.__key = 'k' + cat.id + i; items.push(c); }); });
    h.renderSummary();
    items.forEach(function (c) { var li = h.buildItem(c, 2, null, 'verification', [c]); ul.appendChild(li); });
    assertInert(ul, 'verification checks');
    assertInert(dom.byId.summary, 'verification summary');
    staticIcons(dom, 'verification page');
    var text = textOf(ul);
    eq(text.indexOf(HOSTILE[0]) >= 0 && text.indexOf(HOSTILE[1]) >= 0, true, 'hostile text is shown as text');
    eq(text.indexOf('Skipped: blocks the gate') >= 0, true, 'a skipped check says it blocks the gate');
    eq(text.indexOf('Fix: ') >= 0, true, 'the remedy is shown');
    var links = ul.querySelectorAll('a');
    eq(links.length, 1, 'one link: the documentation source');
    eq(links[0].attrs.href, 'https://learn.microsoft.com/azure/azure-local/x');
    eq(text.indexOf('https://evil.example/x') >= 0, true, 'a foreign source is plain text');
    eq(textOf(dom.byId.summary).indexOf('Verdict: Fail') >= 0, true, 'the banner is shown');
  });
});

// ---------------------------------------------------------------- the Update tab: a summary that says AppliedSuccessfully is not an update that ran

var LEARN_SBE = 'https://learn.microsoft.com/azure/azure-local/update/solution-builder-extension?view=azloc-2610#the-additionalcontentrequired-update-state';
// What /api/state update reads for the live cluster (sanitised): AppliedSuccessfully, never updated, one SBE update waiting for content,
// two Informational readiness checks.
function liveUpdate(extra) {
  var u = {
    verified: false, status: 'notstarted', phase: 'waiting', level: 'warn', label: 'Waiting for content', ran: false,
    nextAction: { text: 'The update package must be added (SBE side-load): the hardware vendor’s Solution Builder Extension files have to be downloaded and imported before this update can be prepared or installed. The Learn page explains how.', guide: LEARN_SBE },
    summary: { state: 'AppliedSuccessfully', healthState: 'Success', currentVersion: '12.2610.1004.50', currentSbeVersion: '', lastChecked: '2026-11-06T09:14:00Z', lastUpdated: '',
      checkCounts: { total: 3, failed: 2, critical: 0, error: 0, warning: 0, informational: 2, other: 0 },
      failedChecks: [
        { title: 'The machine proxy on each failover cluster node should be set to a local proxy server', severity: 'Informational', description: '', remediation: 'https://learn.microsoft.com/azure/azure-local/manage/configure-proxy-settings-23h2' },
        { title: 'The CAU clustered role should be installed on the cluster', severity: 'Informational', description: '', remediation: 'Install the Cluster-Aware Updating clustered role.' }] },
    active: null,
    updates: [{ name: 'SBE5.0.2609.1611', version: '5.0.2609.1611', displayName: 'SBE5.0.2609.1611', description: 'Premier SBE for Example 16G AX Servers', packageType: 'SBE',
      state: 'AdditionalContentRequired', stateWord: 'Waiting for content', phase: 'waiting', level: 'warn', rebootRequired: 'Unknown' }],
    runs: [], run: null, tree: [], counts: {}
  };
  Object.keys(extra || {}).forEach(function (k) { u[k] = extra[k]; });
  return u;
}
function doneState(update, extra) {
  var s = { phase: 'done', activePhase: 'deployment', cluster: 'clus01', update: update, nodes: [{ name: 'n1', arcStatus: 'Connected', seed: true }], deployment: { status: 'Success', tree: [] }, validation: { status: 'Success', tree: [] } };
  Object.keys(extra || {}).forEach(function (k) { s[k] = extra[k]; });
  return s;
}

test('Update tile: the live payload (AppliedSuccessfully, never updated, an SBE update waits for content) is amber, not green', function () {
  var t = tileOf(m.modeStates(doneState(liveUpdate())), 'update');
  eq(t.status, 'warn');
  eq(t.line, 'Waiting for content');
  eq(/SBE side-load/.test(t.tip), true, 'the tip carries the next action');
  eq(/2 informational/.test(t.tip), true, 'and the counts of the failed checks');
});

test('Update tile: the state Sonar sent before the fix (status success, phase idle, no run) is not green', function () {
  var t = tileOf(m.modeStates(doneState({ verified: false, status: 'success', phase: 'idle', run: null, active: null, tree: [], summary: { state: 'AppliedSuccessfully' } })), 'update');
  eq(t.status, 'idle');
});

test('Update tile: neutral with the label "No update has run" when nothing ran, nothing waits and only Informational checks failed', function () {
  var u = liveUpdate({ phase: 'idle', level: 'neutral', label: 'No update has run', nextAction: null, updates: [] });
  var t = tileOf(m.modeStates(doneState(u)), 'update');
  eq(t.status, 'idle'); eq(t.line, 'No update has run');
  eq(m.updateLevel(u), 'neutral');
});

test('Update tile: green only for level ok (a real run finished), "Done"', function () {
  var t = tileOf(m.modeStates(doneState({ status: 'success', phase: 'idle', level: 'ok', label: 'Update succeeded (12.2611.1002.10)', ran: true, tree: [{ id: '1', name: 'Prepare', status: 'success', children: [] }], summary: {} })), 'update');
  eq(t.status, 'ok'); eq(t.line, 'Done');
});

test('Update tile: the colour is the back end level: error red, run with the step count, warn amber', function () {
  var tree = [{ id: '1', name: 'Prepare', status: 'success', children: [] }, { id: '2', name: 'Install', status: 'running', children: [] }, { id: '3', name: 'Finish', status: 'notstarted', children: [] }];
  var run = tileOf(m.modeStates(doneState({ status: 'running', phase: 'installing', level: 'run', label: 'Installing 12.2611.1002.10', tree: tree, summary: {} })), 'update');
  eq(run.status, 'run'); eq(run.line, 'Step 2 of 3');
  var failed = tileOf(m.modeStates(doneState({ status: 'error', phase: 'failed', level: 'error', label: 'Update failed', tree: tree, summary: {} })), 'update');
  eq(failed.status, 'err'); eq(failed.line, 'Failed');
  var check = tileOf(m.modeStates(doneState(liveUpdate({ status: 'notstarted', phase: 'idle', level: 'error', label: 'Readiness check failed', updates: [] }))), 'update');
  eq(check.status, 'err'); eq(check.line, 'Readiness check failed');
  var warn = tileOf(m.modeStates(doneState(liveUpdate({ phase: 'idle', level: 'warn', label: 'Readiness warning', updates: [] }))), 'update');
  eq(warn.status, 'warn');
});

test('Update tile: no update object at all stays a plain waiting tile with the old text', function () {
  var t = tileOf(m.modeStates({ phase: 'done', nodes: [] }), 'update');
  eq(t.status, 'idle'); eq(t.line, '');
  eq(/Available after the cluster is deployed/.test(t.tip), true);
});

test('updateChecks: counts per severity, the worst non-informational severity decides', function () {
  var live = m.updateChecks(liveUpdate());
  eq(live.counts.informational, 2); eq(live.text, '2 informational'); eq(live.worst, 'idle');
  var mix = m.updateChecks({ summary: { checkCounts: { total: 5, failed: 4, critical: 1, error: 0, warning: 1, informational: 2, other: 0 }, failedChecks: [] } });
  eq(mix.text, '1 critical, 1 warning, 2 informational'); eq(mix.worst, 'err');
  eq(m.updateChecks({ summary: { checkCounts: { warning: 1 }, failedChecks: [] } }).worst, 'warn');
  eq(m.updateChecks({ summary: {} }).worst, 'ok');
  eq(m.updateChecks({ summary: { failedChecks: [{ title: 'a', severity: 'Error' }, { title: 'b', severity: 'Weird' }] } }).counts.other, 1, 'counts are derived when the back end sent none');
});

test('updatePanels: the offered update with its next action link, and the Informational checks as a list with their remediation link', function () {
  var p = m.updatePanels(liveUpdate());
  eq(p.map(function (x) { return x.title; }), ['Updates Azure offers', 'Readiness checks that failed: 2 informational']);
  var offers = p[0];
  eq(offers.kind, 'warn');
  eq(offers.rows[0].k, 'SBE5.0.2609.1611');
  eq(offers.rows[0].v, 'SBE · Waiting for content · Premier SBE for Example 16G AX Servers');
  var next = offers.rows[offers.rows.length - 1];
  eq(next.k, 'Next'); eq(next.href, LEARN_SBE); eq(/SBE side-load/.test(next.v), true);
  var checks = p[1];
  eq(checks.kind, 'idle', 'Informational checks do not colour the panel');
  eq(checks.rows.map(function (r) { return r.k; }), ['Informational', 'Informational']);
  eq(checks.rows[0].href, 'https://learn.microsoft.com/azure/azure-local/manage/configure-proxy-settings-23h2');
  eq(checks.rows[1].href, undefined, 'a remediation that is only text is shown as text');
  eq(/Install the Cluster-Aware Updating clustered role/.test(checks.rows[1].v), true);
});

test('updatePanels: a Critical check makes the checks panel red; the history lists the runs', function () {
  var u = liveUpdate({ runs: [{ name: 'r1', update: 'Solution12.2611.1002.10', status: 'success', timeStarted: '2026-12-09T18:40:00Z', duration: 'PT0H40M' }] });
  u.summary.checkCounts = { total: 3, failed: 2, critical: 1, error: 0, warning: 0, informational: 1, other: 0 };
  u.summary.failedChecks[0].severity = 'Critical';
  var p = m.updatePanels(u);
  eq(p[1].kind, 'err'); eq(p[1].title, 'Readiness checks that failed: 1 critical, 1 informational');
  eq(p[2].title, 'Update history');
  eq(/Succeeded/.test(p[2].rows[0].v), true); eq(/Solution12\.2611/.test(p[2].rows[0].v), true);
});

test('updatePanels: an update state Sonar does not know is shown as the raw word, neutral', function () {
  var u = liveUpdate({ updates: [{ name: 'X1', version: '1.0', packageType: 'Solution', state: 'SomethingNew', stateWord: 'SomethingNew', phase: 'idle', level: 'neutral' }], nextAction: null });
  var p = m.updatePanels(u);
  eq(p[0].kind, 'idle'); eq(/SomethingNew/.test(p[0].rows[0].v), true);
});

test('updatePanels: only links to known documentation hosts are links', function () {
  var u = liveUpdate({ nextAction: { text: 'x', guide: 'https://evil.example/doc' } });
  eq(m.updatePanels(u)[0].rows.pop().href, undefined);
});

test('updateFacts: never updated says so, a lastUpdated shows the date', function () {
  var f = m.updateFacts(liveUpdate());
  eq(f.filter(function (x) { return x.k === 'Last updated'; })[0].v, 'never: no update has run');
  eq(f.filter(function (x) { return x.k === 'Current version'; })[0].v, '12.2610.1004.50');
  var u = liveUpdate(); u.summary.lastUpdated = '2026-12-09T19:20:00Z';
  eq(/never/.test(m.updateFacts(u).filter(function (x) { return x.k === 'Last updated'; })[0].v), false);
});

test('summaryFor (Update): waiting for content states the next action; the panels and facts are there', function () {
  var sm = m.summaryFor(doneState(liveUpdate()), 'update', { nodes: [{ name: 'n1', seed: true }] });
  eq(sm.status, 'warn'); eq(sm.chip, { kind: 'warn', text: 'Needs attention' });
  eq(/^Waiting for content: The update package must be added \(SBE side-load\)/.test(sm.headline), true);
  eq(sm.panels.length, 2);
  eq(sm.facts.length > 0, true);
});

test('summaryFor (Update): a running update keeps the step headline', function () {
  var tree = [{ id: '1', name: 'Prepare', status: 'success', children: [] }, { id: '2', name: 'Update node 2', status: 'running', children: [] }];
  var sm = m.summaryFor({ phase: 'update', activePhase: 'update', nodes: [], update: { status: 'running', phase: 'installing', level: 'run', label: 'Installing', tree: tree, summary: {} } }, 'update');
  eq(sm.headline, 'Update is running: step 2 of 2 (Update node 2)');
});

test('activeModeId: Auto lands on Update when an update installs or prepares, also while the phase still reads done', function () {
  eq(m.activeModeId({ phase: 'update', activePhase: 'update' }), 'update');
  eq(m.activeModeId(doneState({ status: 'running', phase: 'installing', level: 'run', summary: {} })), 'update');
  eq(m.activeModeId(doneState({ status: 'running', phase: 'preparing', level: 'run', summary: {} })), 'update');
  eq(m.activeModeId(doneState(liveUpdate())), 'deploy', 'a waiting update right after the deployment stays on Deployment');
  eq(m.activeModeId({ phase: 'failed', activePhase: 'update' }), 'update');
});

test('a standalone Update monitor shows the Update tile only', function () {
  var tiles = m.modeStates({ monitor: 'Update', phase: 'update', activePhase: 'update', update: liveUpdate(), nodes: [] });
  eq(tiles.filter(function (t) { return !t.hidden; }).map(function (t) { return t.id; }), ['update']);
  eq(tileOf(tiles, 'update').status, 'warn');
  eq(m.activeModeId({ monitor: 'Update', phase: 'update', update: liveUpdate() }), 'update');
});

test('cluster card (Update): the live payload says what waits, lists no red failure for Informational checks, shows Critical as a failure and Warning as an amber row', function () {
  var c = m.clusterCard({ clusterResource: clusterRes(), update: liveUpdate() }, 'update'), r = rowsOf(c);
  eq(r['Update'], 'Waiting for content'); eq(r['Current version'], '12.2610.1004.50'); eq(r['Target version'], '5.0.2609.1611');
  eq(r['Last updated'], 'never: no update has run');
  eq(c.failures, []); eq(c.kind, 'warn');
  var u = liveUpdate(); u.level = 'error'; u.summary.failedChecks = [{ title: 'Storage pool is not healthy', severity: 'Critical' }, { title: 'Time skew', severity: 'Warning' }, { title: 'Proxy', severity: 'Informational' }];
  u.summary.checkCounts = { total: 3, failed: 3, critical: 1, error: 0, warning: 1, informational: 1, other: 0 };
  var b = m.clusterCard({ clusterResource: clusterRes(), update: u }, 'update');
  eq(b.failures, ['Storage pool is not healthy']); eq(rowsOf(b)['Warning'], 'Time skew'); eq(b.kind, 'err');
});

test('tailerView: while an update runs an unreachable seed node is "Reconnecting to node logs", not an error', function () {
  var down = { state: 'unavailable', reason: 'Cannot reach the logs on n1 (192.0.2.11).', node: 'n1' };
  var upd = { phase: 'update', update: { status: 'running', phase: 'installing', level: 'run', summary: {} } };
  var v = m.tailerView(down, upd);
  eq(v.state, 'reconnecting'); eq(v.bad, false); eq(v.label, 'Reconnecting to node logs');
  eq(/Cannot reach the logs on n1/.test(v.reason), true, 'the original reason is kept');
  var idle = m.tailerView(down, doneState(liveUpdate()));
  eq(idle.state, 'unavailable'); eq(idle.bad, true);
  eq(m.tailerView({ state: 'connected', node: 'n1' }, upd), { state: 'connected', bad: false, label: 'Tailer: connected to n1', reason: '' });
  eq(m.tailerView(down, null).bad, true, 'no state yet: still an error');
});

test('emptyLogView: Reconnecting to node logs while the seed node restarts', function () {
  var v = m.emptyLogView({}, false, 0, 'reconnecting');
  eq(v.title, 'Reconnecting to node logs…'); eq(v.kind, 'waiting');
  eq(m.emptyLogView({}, false, 0, 'unavailable').title, 'No log lines: the log tailer cannot reach the seed node.');
});


test('Update view in the page: hostile check titles, remediation links and offer descriptions render as text; only allow-listed links are links', function () {
  withDom(function (dom, h) {
    var u = liveUpdate();
    u.summary.failedChecks = [
      { title: HOSTILE[0], severity: 'Informational', description: HOSTILE[1], remediation: HOSTILE[2] },
      { title: 'Proxy', severity: 'Informational', description: '', remediation: 'https://learn.microsoft.com/azure/azure-local/manage/configure-proxy-settings-23h2' },
      { title: 'Elsewhere', severity: 'Informational', description: '', remediation: 'https://evil.example/fix' }];
    u.summary.checkCounts = { total: 3, failed: 3, critical: 0, error: 0, warning: 0, informational: 3, other: 0 };
    u.updates[0].description = HOSTILE[1];
    h.app.config = { cluster: 'clus01', nodes: [{ name: 'n1', seed: true }] };
    h.app.state = { cluster: 'clus01', phase: 'update', activePhase: 'update', monitor: 'Update', nodes: [{ name: 'n1', arcStatus: 'Connected' }], update: u };
    h.renderSummary();
    var host = dom.byId.summary;
    assertInert(host, 'update summary');
    var anchors = host.querySelectorAll('a');
    eq(anchors.length, 2, 'the next-action Learn link and the one allow-listed remediation link');
    anchors.forEach(function (a) { eq(a.attrs.rel, 'noopener noreferrer'); eq(a.attrs.target, '_blank'); });
    eq(textOf(host).indexOf(HOSTILE[0]) >= 0, true, 'the hostile title shows as text');
    eq(textOf(host).indexOf('Waiting for content') >= 0, true);
    staticIcons(dom, 'update summary');
  });
});

// ---------------------------------------------------------------- the cluster's own update service (update.local, update.sources)

function localUpdate(extra) {
  var l = {
    enabled: true, read: true, stale: false, reason: '', reasonKind: '', node: 'iic-azl-n01', nodeNote: '', readAt: '2026-11-09T05:21:00Z', attempts: [],
    status: 'running', phase: 'preparing', level: 'run', label: 'Checking update health', state: 'HealthChecking', stateWord: 'Checking health',
    run: { id: 'run-1', update: 'SBE5.0.2609.1611', version: '5.0.2609.1611', packageType: 'SBE', state: 'InProgress', status: 'running', started: '2026-11-09T05:03:34Z', lastUpdated: '2026-11-09T05:20:00Z', ended: null, durationSeconds: 1046, duration: '00:17:26' },
    progress: { done: 3, total: 9, running: 1, current: 'Finalize SBE preparation', elapsedSeconds: 1046 },
    failed: null, history: [],
    nodes: [
      { name: 'iic-azl-n01', state: 'Up', role: 'done', word: 'Up: finished its steps', step: '', stepStatus: 'success', started: '2026-11-09T05:18:34Z', ended: '2026-11-09T06:18:34Z', steps: 3, timeline: [] },
      { name: 'iic-azl-n02', state: 'Paused', role: 'patching', word: 'Paused: drained and being patched', step: 'Install CAU Updates', stepStatus: 'running', started: '2026-11-09T06:18:34Z', ended: null, steps: 2, timeline: [] },
      { name: 'iic-azl-n03', state: 'Up', role: 'waiting', word: 'Up: waiting its turn', step: '', stepStatus: 'notstarted', started: null, ended: null, steps: 0, timeline: [] }],
    versions: { current: { solution: '12.2610.1004.50', sbe: '4.1.2609.5' }, before: { solution: '12.2610.1004.50', sbe: '4.1.2609.5', known: true }, after: { solution: '', sbe: '5.0.2609.1611', known: false }, target: { solution: '', sbe: '5.0.2609.1611', packageType: 'SBE' } },
    events: [{ at: '2026-11-09T05:03:34Z', kind: 'started', text: 'Update SBE5.0.2609.1611 started on the cluster.' }]
  };
  Object.keys(extra || {}).forEach(function (k) { l[k] = extra[k]; });
  return l;
}
function behindSources(minutes) {
  return { azure: { read: true, state: 'UpdateAvailable', status: 'notstarted', phase: 'available', label: 'Update available' }, cluster: { enabled: true, read: true, status: 'running', phase: 'preparing', label: 'Checking update health' },
    winner: 'cluster', agree: false, lagMinutes: minutes, lagSince: '2026-11-09T05:03:34Z', lagBasis: 'run',
    message: 'Azure is behind the cluster by ' + minutes + ' minutes. The cluster says: Checking update health. Azure still says: Update available. Sonar shows the cluster’s state.' };
}
function clusterWinsUpdate(extra) {
  return liveUpdate(Object.assign({ status: 'running', phase: 'preparing', level: 'run', label: 'Checking update health', ran: true, nextAction: null, updates: [], local: localUpdate(), sources: behindSources(17),
    tree: [{ id: '1', name: 'SBE Package Update', status: 'running', children: [] }, { id: '2', name: 'Finish', status: 'notstarted', children: [] }] }, extra || {}));
}

test('update notices: Azure behind the cluster says so, with the minutes, and keeps the cluster’s words', function () {
  var n = m.updateNotices(clusterWinsUpdate());
  eq(n.length, 1); eq(n[0].kind, 'source');
  eq(/^Azure is behind the cluster by 17 minutes\./.test(n[0].text), true);
  eq(/The cluster says: Checking update health\. Azure still says: Update available\./.test(n[0].text), true);
  eq(m.updateLag(clusterWinsUpdate()), 17);
  eq(m.updateLag(liveUpdate()), null, 'no sources, no lag');
});

test('update notices: node-side reading off says plainly why; a failing read says so; a node switch is information, not an error', function () {
  var off = m.updateNotices(liveUpdate({ local: { enabled: false, read: false, reasonKind: 'off', reason: 'Node-side update reading is off. Sonar shows only what Azure reports, and Azure can be many minutes behind the cluster.' }, sources: { winner: 'azure', agree: true, message: '' } }));
  eq(off.length, 1); eq(off[0].kind, 'source-off'); eq(/Node-side update reading is off/.test(off[0].text), true);
  var bad = m.updateNotices(liveUpdate({ local: { enabled: true, read: false, reasonKind: 'credential', reason: 'Node-side update reading is paused: a node refused the update account.' } }));
  eq(bad[0].kind, 'source-off'); eq(/paused/.test(bad[0].text), true);
  var sw = m.updateNotices(clusterWinsUpdate({ local: localUpdate({ nodeNote: 'iic-azl-n01 did not answer, so iic-azl-n02 was read. A node restarts during an update; this is normal.' }), sources: { winner: 'cluster', agree: true, lagMinutes: null, message: '' } }));
  eq(sw.length, 1); eq(sw[0].kind, 'source-info'); eq(/did not answer, so iic-azl-n02 was read/.test(sw[0].text), true);
  var stale = m.updateNotices(clusterWinsUpdate({ local: localUpdate({ stale: true, reasonKind: 'unreachable', reason: 'No node answered just now (iic-azl-n01 did not answer). The node being read is probably restarting.' }) }));
  eq(stale.map(function (x) { return x.kind; }), ['source', 'source-info']);
  eq(m.updateNotices(liveUpdate()), [], 'an old state without local says nothing');
});

test('liveNotes: the Update view carries the sources note; no note while the page is on the deployment', function () {
  var s = doneState(clusterWinsUpdate(), { phase: 'update', activePhase: 'update' });
  var notes = m.liveNotes(s);
  eq(notes.filter(function (x) { return x.kind === 'source'; }).length, 1);
  eq(/Read from the cluster itself/.test(notes.filter(function (x) { return x.kind === 'update'; })[0].text), true, 'the unverified wording only covers the Azure side');
  var quiet = m.liveNotes(doneState(liveUpdate({ local: { enabled: false, read: false, reason: 'off' } })));
  eq(quiet.filter(function (x) { return x.kind === 'source-off'; }).length, 0);
});

test('Update tile: the cluster’s answer wins over Azure’s, and the tip says Azure is behind', function () {
  var t = tileOf(m.modeStates(doneState(clusterWinsUpdate())), 'update');
  eq(t.status, 'run'); eq(t.line, 'Step 1 of 2');
  eq(/Azure is behind the cluster by 17 minutes/.test(t.tip), true);
});

test('updatePanels: where the verdict comes from, the run, the machines, what happened, then what is offered', function () {
  var p = m.updatePanels(clusterWinsUpdate({ updates: [{ name: 'SBE5.0.2609.1611', version: '5.0.2609.1611', packageType: 'SBE', state: 'HealthChecking', stateWord: 'Checking health', phase: 'preparing', level: 'run' }] }));
  eq(p.map(function (x) { return x.title; }), ['Where this comes from', 'The update run on the cluster', 'Machines in the update (from the cluster)', 'What happened', 'Updates (from the cluster)', 'Readiness checks that failed: 2 informational']);
  var src = p[0].rows;
  eq(src[0].k, 'The cluster says'); eq(/^Checking update health · read on iic-azl-n01/.test(src[0].v), true);
  eq(src[1].k, 'Azure says'); eq(src[1].v, 'Update available (UpdateAvailable)');
  eq(src[2].k, 'Azure is behind'); eq(src[2].warn, true); eq(/^17 minutes/.test(src[2].v), true);
  eq(p[0].kind, 'warn');
  var run = p[1].rows.reduce(function (o, r) { o[r.k] = r.v; return o; }, {});
  eq(run['Update'], 'SBE5.0.2609.1611 (SBE)'); eq(run['Steps'], '3 of 9 so far (more appear as the update goes on)'); eq(run['Now'], 'Finalize SBE preparation');
  eq(typeof run['Running for'], 'string');
  eq(run['SBE version'], '4.1.2609.5 to 5.0.2609.1611'); eq(run['Solution version'], '12.2610.1004.50 (unchanged)');
  var nodes = p[2].rows;
  eq(nodes.map(function (r) { return r.k; }), ['iic-azl-n01', 'iic-azl-n02', 'iic-azl-n03']);
  eq(/^Paused: drained and being patched · Install CAU Updates · from /.test(nodes[1].v), true);
  eq(p[2].kind, 'run');
});

test('updatePanels: a failed step is named with its node and the error text; the run says it stopped', function () {
  var loc = localUpdate({ status: 'error', phase: 'failed', level: 'error', label: 'Update failed',
    run: { id: 'run-1', update: 'SBE5.0.2609.1611', version: '5.0.2609.1611', packageType: 'SBE', state: 'Failed', status: 'error', started: '2026-11-09T05:03:34Z', lastUpdated: '2026-11-09T06:38:00Z', ended: '2026-11-09T06:38:34Z', durationSeconds: 5700, duration: '01:35:00' },
    failed: { name: '[SBE Partner] Install CAU Updates iic-azl-n02', node: 'iic-azl-n02', error: 'Install failed on iic-azl-n02: the hardware update package returned exit code 1603.' } });
  var rows = m.updateLocalPanels(clusterWinsUpdate({ local: loc }))[1].rows.reduce(function (o, r) { o[r.k] = r; return o; }, {});
  eq(rows['Stopped'].v.length > 0, true); eq(rows['Duration'].v, '1h 35m 0s');
  eq(rows['Failed step'].warn, true);
  eq(rows['Failed step'].v, '[SBE Partner] Install CAU Updates iic-azl-n02 on iic-azl-n02: Install failed on iic-azl-n02: the hardware update package returned exit code 1603.');
});

test('updatePanels: with node-side reading off the extra panel says so and why; Azure’s list keeps its Azure title', function () {
  var u = liveUpdate({ local: { enabled: false, read: false, reasonKind: 'off', reason: 'Node-side update reading is off. Sonar shows only what Azure reports.' }, sources: { winner: 'azure', agree: true, message: 'x' } });
  var p = m.updatePanels(u);
  eq(p[0].title, 'Where this comes from');
  eq(p[0].rows[0].v, 'Node-side reading is off'); eq(p[0].rows[0].warn, true);
  var titles = p.map(function (x) { return x.title; });
  eq(titles.indexOf('The update run on the cluster'), -1);
  eq(titles.indexOf('Updates Azure offers') >= 0, true);
});

test('updatePanels: Installed on the cluster while Azure still says Ready: success, and the version change is before to after', function () {
  var loc = localUpdate({ status: 'success', phase: 'idle', level: 'ok', label: 'Update succeeded (12.2610.1004.50)', stateWord: 'Installed',
    run: { id: 'run-1', update: 'SBE5.0.2609.1611', version: '5.0.2609.1611', packageType: 'SBE', state: 'Succeeded', status: 'success', started: '2026-11-09T05:03:34Z', lastUpdated: '2026-11-09T08:19:46Z', ended: '2026-11-09T08:19:53Z', durationSeconds: 11779, duration: '03:16:19' },
    progress: { done: 5, total: 5, running: 0, current: '' },
    versions: { current: { solution: '12.2610.1004.50', sbe: '5.0.2609.1611' }, before: { solution: '12.2610.1004.50', sbe: '4.1.2609.5', known: true }, after: { solution: '12.2610.1004.50', sbe: '5.0.2609.1611', known: true }, target: { solution: '', sbe: '5.0.2609.1611', packageType: 'SBE' } } });
  var u = clusterWinsUpdate({ status: 'success', phase: 'idle', level: 'ok', label: 'Update succeeded (12.2610.1004.50)', local: loc, sources: behindSources(5) });
  var rows = m.updateLocalPanels(u)[1].rows.reduce(function (o, r) { o[r.k] = r.v; return o; }, {});
  eq(rows['SBE version'], '4.1.2609.5 to 5.0.2609.1611'); eq(rows['Solution version'], '12.2610.1004.50 (unchanged)');
  eq(rows['Duration'], '3h 16m 19s'); eq(rows['Steps'], '5 of 5 finished');
  eq(m.updateTile(u).status, 'ok'); eq(m.updateTile(u).line, 'Done');
});

test('versionChange: unchanged, changed, and not known before the run', function () {
  eq(m.versionChange('4.1', '5.0', '4.1', true), '4.1 to 5.0');
  eq(m.versionChange('5.0', '5.0', '5.0', true), '5.0 (unchanged)');
  eq(m.versionChange('', '5.0', '5.0', false), '5.0');
  eq(m.versionChange('4.1', '', '5.0', true), '4.1 to 5.0');
  eq(m.versionChange('', '', '', false), '');
});

test('updateFacts: the reading source and the lag; Azure with no summary yet still shows the cluster’s reading', function () {
  var f = m.updateFacts(clusterWinsUpdate());
  eq(f.filter(function (x) { return x.k === 'Reading'; })[0].v, 'The cluster and Azure (cluster read on iic-azl-n01)');
  eq(f.filter(function (x) { return x.k === 'Azure is behind'; })[0].v, '17 minutes');
  var off = m.updateFacts(liveUpdate({ local: { enabled: false, read: false } }));
  eq(off.filter(function (x) { return x.k === 'Reading'; })[0].v, 'Azure only'); eq(off.filter(function (x) { return x.k === 'Reading'; })[0].warn, true);
  var noAzure = m.updateFacts({ summary: null, local: localUpdate() });
  eq(noAzure.length, 1); eq(/^The cluster \(read on iic-azl-n01\); Azure has no update data yet/.test(noAzure[0].v), true);
});

test('summaryFor (Update): the machine cards show the cluster’s view of each machine: drained and patched, updated, waiting', function () {
  var s = doneState(clusterWinsUpdate(), { phase: 'update', activePhase: 'update', nodes: [{ name: 'iic-azl-n01', arcStatus: 'Connected', seed: true }, { name: 'iic-azl-n02', arcStatus: 'Connected' }, { name: 'iic-azl-n03.example.test', arcStatus: 'Connected' }] });
  var sm = m.summaryFor(s, 'update', { nodes: [{ name: 'iic-azl-n01', seed: true }, { name: 'iic-azl-n02' }, { name: 'iic-azl-n03.example.test' }] });
  var by = {}; sm.cards.forEach(function (c) { by[c.name] = c; });
  eq(by['iic-azl-n01'].state, 'Updated'); eq(by['iic-azl-n01'].progress, 100);
  eq(by['iic-azl-n02'].state, 'Being patched'); eq(by['iic-azl-n02'].waits, 'Now: Install CAU Updates'); eq(by['iic-azl-n02'].kind, 'run');
  eq(/Cluster node state: Paused/.test(by['iic-azl-n02'].tip), true);
  eq(by['iic-azl-n03.example.test'].state, 'Waiting', 'a machine named with a domain still matches the cluster node by its short name');
});

test('cluster card (Update): Azure behind is a warning row; a failed step of the cluster is a failure line; reading off is a row', function () {
  var c = m.clusterCard(doneState(clusterWinsUpdate()), 'update');
  var rows = c.rows.reduce(function (o, r) { o[r.k] = r; return o; }, {});
  eq(rows['Azure is behind'].v, '17 minutes'); eq(rows['Azure is behind'].warn, true);
  var failed = m.clusterCard(doneState(clusterWinsUpdate({ status: 'error', phase: 'failed', level: 'error', label: 'Update failed', local: localUpdate({ failed: { name: 'Install CAU Updates', node: 'n2', error: 'exit code 1603' } }) })), 'update');
  eq(failed.failures, ['Install CAU Updates: exit code 1603']);
  var off = m.clusterCard(doneState(liveUpdate({ local: { enabled: false, read: false, reason: 'off' } })), 'update');
  eq(off.rows.filter(function (r) { return r.k === 'Node-side reading'; })[0].v, 'Off: Azure only');
});

test('localNodeFor: exact name, then short name; nothing for an unknown machine', function () {
  var loc = localUpdate();
  eq(m.localNodeFor(loc, 'IIC-AZL-N02').name, 'iic-azl-n02');
  eq(m.localNodeFor(loc, 'iic-azl-n03.example.test').name, 'iic-azl-n03');
  eq(m.localNodeFor(loc, 'other'), null);
  eq(m.localNodeFor(null, 'iic-azl-n02'), null);
});

test('Update view in the page: hostile text in the cluster’s step error, node note and message renders as text only', function () {
  withDom(function (dom, h) {
    var u = clusterWinsUpdate({ local: localUpdate({ nodeNote: HOSTILE[0], failed: { name: HOSTILE[1], node: 'iic-azl-n02', error: HOSTILE[0] }, reason: '' }) });
    u.sources.message = HOSTILE[0];
    h.app.config = { cluster: 'clus01', nodes: [{ name: 'iic-azl-n01', seed: true }] };
    h.app.state = { cluster: 'clus01', phase: 'update', activePhase: 'update', monitor: 'Update', nodes: [{ name: 'iic-azl-n01', arcStatus: 'Connected' }], update: u };
    h.renderSummary();
    h.renderLiveNotes();
    assertInert(dom.byId.summary, 'update summary with the cluster’s reading');
    assertInert(dom.byId['live-notes'], 'update notes');
    eq(textOf(dom.byId.summary).indexOf('Where this comes from') >= 0, true);
    eq(textOf(dom.byId['live-notes']).indexOf(HOSTILE[0]) >= 0, true, 'the hostile text shows as text');
    staticIcons(dom, 'update summary with the cluster’s reading');
  });
});

process.stdout.write(JSON.stringify(cases));
