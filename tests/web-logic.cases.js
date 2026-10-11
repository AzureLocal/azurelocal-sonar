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

process.stdout.write(JSON.stringify(cases));
