const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const model = vm.createContext({});
vm.runInContext(readFileSync(path.join(__dirname, '../desktop/plugin/PanelModel.js'), 'utf8'), model);
const now = 1000;
function present(counts, overrides = {}) {
  const priority = ['needs_input', 'working', 'finished'];
  return model.present({
    running: true, sharingEnabled: true, updatedAt: now,
    pairedPhones: 1, lastPhoneFetchAt: now - 3,
    sessions: Object.values(counts).reduce((sum, count) => sum + count, 0),
    sessionCounts: counts, activity: priority.find(key => counts[key]) || 'idle',
    ...overrides
  }, now);
}

test('one session keeps the simple row', () => {
  const value = present({ needs_input: 0, working: 1, finished: 0 });
  assert.equal(value.activityTitle, 'Codex');
  assert.equal(value.activity, 'Working');
  assert.equal(value.activityBreakdown, '');
});
test('matching states use a counted label without a second line', () => {
  for (const [state, label] of [['working', '2 working'], ['needs_input', '2 need input']]) {
    const value = present({ needs_input: 0, working: 0, finished: 0, [state]: 2 });
    assert.equal(value.activityTitle, 'Codex · 2 active');
    assert.equal(value.activity, label);
    assert.equal(value.activityBreakdown, '');
  }
});
test('attention takes priority without hiding work', () => {
  const value = present({ needs_input: 1, working: 1, finished: 0 });
  assert.equal(value.activityTitle, 'Codex · 2 active');
  assert.equal(value.activity, 'Needs input');
  assert.equal(value.activityBreakdown, '1 needs input · 1 working');
});
test('one working session and retained completions remain one simple row', () => {
  const value = present({ needs_input: 0, working: 1, finished: 2 });
  assert.equal(value.activityTitle, 'Codex');
  assert.equal(value.activity, 'Working');
  assert.equal(value.activityBreakdown, '');
});
test('mixed active states exclude retained completions', () => {
  const value = present({ needs_input: 2, working: 3, finished: 1 });
  assert.equal(value.activityTitle, 'Codex · 5 active');
  assert.equal(value.activityBreakdown, '2 need input · 3 working');
});
test('retained completions never appear as ongoing sessions', () => {
  const value = present({ needs_input: 0, working: 0, finished: 3 });
  assert.equal(value.activityTitle, 'Codex');
  assert.equal(value.activity, 'Finished');
  assert.equal(value.activityBreakdown, '');
});
test('off and stale sources do not advertise old session counts', () => {
  for (const [overrides, label] of [[{ sharingEnabled: false }, 'Paused'], [{ updatedAt: now - 20 }, 'Unavailable']]) {
    const value = present({ needs_input: 1, working: 1, finished: 0 }, overrides);
    assert.equal(value.activityTitle, 'Codex');
    assert.equal(value.activity, label);
    assert.equal(value.activityBreakdown, '');
  }
});
test('legacy or inconsistent counts fall back to the known aggregate', () => {
  for (const overrides of [{ sessionCounts: undefined }, { sessions: 3 }]) {
    const value = present({ needs_input: 1, working: 1, finished: 0 }, overrides);
    assert.equal(value.activityTitle, 'Codex');
    assert.equal(value.activity, 'Needs your input');
    assert.equal(value.activityBreakdown, '');
  }
});
test('zero sessions remains a simple idle row', () => {
  const value = present({ needs_input: 0, working: 0, finished: 0 });
  assert.equal(value.activityTitle, 'Codex');
  assert.equal(value.activity, 'No active work');
  assert.equal(value.activityBreakdown, '');
});

test('one verified finished session keeps its latest status', () => {
  const value = present({ needs_input: 0, working: 0, finished: 1, idle: 0 }, { sessionLiveness: 'process' });
  assert.equal(value.activityTitle, 'Codex');
  assert.equal(value.activity, 'Finished');
  assert.equal(value.activityBreakdown, '');
});
test('multiple verified finished sessions count as open sessions', () => {
  const value = present({ needs_input: 0, working: 0, finished: 2, idle: 0 }, { sessionLiveness: 'process' });
  assert.equal(value.activityTitle, 'Codex · 2 sessions');
  assert.equal(value.activity, '2 finished');
});
test('a verified finished session stays in a mixed live summary', () => {
  const value = present({ needs_input: 0, working: 1, finished: 1, idle: 0 }, { sessionLiveness: 'process' });
  assert.equal(value.activityTitle, 'Codex · 2 sessions');
  assert.equal(value.activity, 'Working');
  assert.equal(value.activityBreakdown, '1 working · 1 finished');
});
test('interrupted but still-open sessions contribute an idle state', () => {
  const value = present({ needs_input: 1, working: 0, finished: 0, idle: 1 }, { sessionLiveness: 'process' });
  assert.equal(value.activityTitle, 'Codex · 2 sessions');
  assert.equal(value.activity, 'Needs input');
  assert.equal(value.activityBreakdown, '1 needs input · 1 idle');
});


test('connection names and contact are scoped to each installation', () => {
  const value = present({}, {clients: [
    {id: 'a', name: 'Alex’s iPhone', platform: 'ios', lastContactAt: now - 2},
    {id: 'b', name: 'Alex’s iPhone', platform: 'ios', lastContactAt: now - 500}
  ]})
  assert.equal(value.connections[0].recent, true)
  assert.equal(value.connections[1].recent, false)
  assert.equal(value.connections[0].title, 'Alex’s iPhone')
  assert.equal(value.connectionHeading, 'PHONES')
})

test('an old status row without identity does not appear as a phantom connection', () => {
  const value = present({}, {clients: [{id: 'old', name: null, platform: null}], pairedPhones: 2})
  assert.equal(value.paired, false)
  assert.equal(value.connections.length, 0)
})

test('sharing off preserves connection identity and removal without claiming contact', () => {
  const value = present({}, {sharingEnabled: false, clients: [
    {id: 'a', name: '<b>My phone</b>', platform: 'ios', lastContactAt: now - 2}
  ]})
  assert.equal(value.connections[0].title, '<b>My phone</b>')
  assert.equal(value.connections[0].status, 'Sharing is off')
  assert.equal(value.connections[0].recent, false)
  assert.equal(value.connections[0].canRemove, true)
})
