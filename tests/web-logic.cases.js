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

test('modeStates: the five tiles for a ZTP run with one machine still installing', function () {
  var tiles = m.modeStates(ztpState(THREE));
  eq(tiles.map(function (t) { return t.id; }), ['prov', 'validate', 'deploy', 'update', 'health']);
  eq(tiles.map(function (t) { return t.status; }), ['run', 'idle', 'idle', 'idle', 'idle']);
  eq(tiles[0].name, 'Provisioning (ZTP)');
  eq(tiles[0].line, '2 of 3 machines ready');
  eq(tiles[0].hidden, false);
});

test('modeStates: a waiting tile has no state line and says when it starts; no tile says "not started"', function () {
  var tiles = m.modeStates(ztpState(THREE));
  tiles.filter(function (t) { return t.status === 'idle'; }).forEach(function (t) {
    eq(t.line, '', t.id + ' has no state line');
    eq(t.tip.length > 0, true, t.id + ' tooltip says when it starts');
  });
  eq(tiles[1].tip, 'Starts after ZTP and OS configuration are done');
  eq(tiles[2].tip, 'Starts after validation passes');
  eq(JSON.stringify(tiles).toLowerCase().indexOf('not started'), -1, 'no "not started" text anywhere');
});

test('modeStates: Provisioning is named after the route; the OEM image route says OS image', function () {
  var s = ztpState([zNode('n1', 'Bootstrapping', 'running', 'NotFound')]);
  s.provisioning.route = 'oem-image'; s.phase = 'arc-registration'; s.activePhase = 'arc-registration';
  eq(m.modeStates(s)[0].name, 'Provisioning (OS image)');
  eq(m.modeName('prov', 'simplified'), 'Provisioning (ZTP)');
  eq(m.modeStates(s)[1].tip, 'Starts when every machine is registered');
});

test('modeStates: Provisioning is hidden when the run has no machines and is past it (a plain deployment)', function () {
  var s = { phase: 'deployment', activePhase: 'deployment', validation: { status: 'Success', tree: [{ id: '1', name: 'v', status: 'success', children: [] }] },
    deployment: { status: 'InProgress', tree: [{ id: '2', name: 'Deploy', status: 'running', children: [
      { id: '2.1', name: 'a', status: 'success', children: [] }, { id: '2.2', name: 'b', status: 'running', children: [] }, { id: '2.3', name: 'c', status: 'notstarted', children: [] }] }] } };
  var tiles = m.modeStates(s);
  eq(tiles[0].hidden, true);
  eq(tiles.map(function (t) { return t.status; }), ['ok', 'ok', 'run', 'idle', 'idle']);
  eq(tiles[1].line, 'Passed');
  eq(tiles[2].line, 'Step 2 of 3');
});

test('activeModeId: the active phase picks the selected mode; a failed run stays on the mode that failed; done is Health', function () {
  eq(m.activeModeId({ phase: 'provisioning', activePhase: 'provisioning' }), 'prov');
  eq(m.activeModeId({ phase: 'arc-registration', activePhase: 'arc-registration' }), 'prov');
  eq(m.activeModeId({ phase: 'validation', activePhase: 'validation' }), 'validate');
  eq(m.activeModeId({ phase: 'deployment', activePhase: 'deployment' }), 'deploy');
  eq(m.activeModeId({ phase: 'update', activePhase: 'update' }), 'update');
  eq(m.activeModeId({ phase: 'failed', activePhase: 'deployment' }), 'deploy');
  eq(m.activeModeId({ phase: 'done', activePhase: 'deployment' }), 'health');
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

test('mode sections: each mode shows only its own steps; Health has none', function () {
  eq(m.MODE_SECTIONS, { prov: ['provisioning'], validate: ['validation', 'extensions'], deploy: ['deployment'], update: ['update'], health: [] });
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

test('stepsEmptyText: a waiting mode says when it begins, Health says there are no steps', function () {
  eq(m.stepsEmptyText('validate', 'idle', 'Starts after validation passes', true), 'The steps appear here when this mode begins. Starts after validation passes.');
  eq(m.stepsEmptyText('health', 'ok', '', true).indexOf('There are no steps here.'), 0);
  eq(m.stepsEmptyText('prov', 'run', '', false), 'No machines reported yet.');
  eq(m.stepsEmptyText('deploy', 'run', '', true), 'No steps reported yet.');
});

// ---------------------------------------------------------------- redesign: route from the phase, plural

test('modeStates: Arc registration without machine data is still the OS image route', function () {
  var tiles = m.modeStates({ phase: 'arc-registration', activePhase: 'arc-registration' });
  eq(tiles[0].name, 'Provisioning (OS image)');
  eq(tiles[0].hidden, false);
  eq(tiles[0].line, 'Waiting for the machines');
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

process.stdout.write(JSON.stringify(cases));
