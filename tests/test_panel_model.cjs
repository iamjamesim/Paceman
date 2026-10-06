const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const model = vm.createContext({});
vm.runInContext(readFileSync(path.join(__dirname, '../omarchy/plugin/PanelModel.js'), 'utf8'), model);
const now = 1000;
function present(counts, overrides = {}) {
  const priority = ['needs_input', 'failed', 'working', 'finished'];
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
test('failed turns remain visible alone and in mixed activity', () => {
  const failed = present({ needs_input: 0, failed: 1, working: 0, finished: 0 });
  assert.equal(failed.activity, 'Failed');
  const mixed = present({ needs_input: 0, failed: 1, working: 1, finished: 0 });
  assert.equal(mixed.activityTitle, 'Codex');
  assert.equal(mixed.activity, 'Failed');
  assert.equal(mixed.activityBreakdown, '');
  const active = present({ needs_input: 0, failed: 1, working: 2, finished: 0 });
  assert.equal(active.activityTitle, 'Codex · 2 active');
  assert.equal(active.activity, 'Failed');
  assert.equal(active.activityBreakdown, '1 failed · 2 working');
  const verified = present({ needs_input: 0, failed: 1, working: 0, finished: 1, idle: 0 }, { sessionLiveness: 'process' });
  assert.equal(verified.activityTitle, 'Codex · 2 sessions');
  assert.equal(verified.activityBreakdown, '1 failed · 1 finished');
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
    assert.equal(value.activity, 'Needs input');
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
  assert.equal(value.connections[0].status, 'Last contact')
  assert.equal(value.connections[0].recent, false)
  assert.equal(value.connections[0].canRemove, true)
})

test('last-contact copy stays stable across recency and sharing states', () => {
  const client = {id: 'a', name: 'Alex’s iPhone', platform: 'ios'};
  const cases = [
    [{lastContactAt: now - 2}, {}, 'Last contact'],
    [{lastContactAt: now - 40}, {}, 'Last contact'],
    [{lastContactAt: 0}, {}, 'No contact yet'],
    [{lastContactAt: now - 2}, {updatedAt: now - 20}, 'Last contact'],
    [{lastContactAt: now - 2}, {sharingEnabled: false}, 'Last contact']
  ];
  for (const [contact, overrides, expected] of cases) {
    const value = present({}, {clients: [{...client, ...contact}], ...overrides});
    assert.equal(value.connections[0].status, expected);
  }
});

test('empty-panel guidance follows the available pairing action', () => {
  const cases = [
    [{}, 'Install Paceman on your iPhone, then use the QR button above.'],
    [{sharingEnabled: false}, 'Turn on sharing to connect your phone.'],
    [{updatedAt: now - 20}, 'Restart Paceman to connect your phone.']
  ];
  for (const [overrides, expected] of cases) {
    assert.equal(present({}, overrides).guidance, expected);
  }
});

test('new installations explain how to start receiving Codex activity', () => {
  const phone = [{ id: 'phone-1', name: 'iPhone', platform: 'ios' }];
  const unpaired = present({ needs_input: 0, working: 0, finished: 0 }, {lastAgentEventAt: 0});
  assert.equal(unpaired.activityGuidance, '');
  const empty = present({ needs_input: 0, working: 0, finished: 0 }, {clients: phone, lastAgentEventAt: 0});
  assert.equal(empty.activityGuidance, "Review Paceman's hooks in Codex with /hooks, then start a new local task.");
  const observed = present({ needs_input: 0, working: 0, finished: 0 }, {clients: phone, lastAgentEventAt: now - 2});
  assert.equal(observed.activityGuidance, '');
  const paused = present({ needs_input: 0, working: 0, finished: 0 }, {clients: phone, sharingEnabled: false});
  assert.equal(paused.activityGuidance, '');
});

test('agent selection and status stay independent, including first use and stale sources', () => {
  const state = {configuredProviders: ['codex', 'claude'], detectedProviders: ['claude'],
    lastAgentEventByProvider: {codex: now}, providerCounts: {codex: {working: 1}}};
  const value = present({working: 1, needs_input: 0, finished: 0}, state);
  assert.equal(value.agents[0].label, 'Working');
  assert.equal(value.agents[1].label, 'Waiting for activity');
  assert.match(value.agents[1].guidance, /hooks/);
  const paused = present({}, {...state, sharingEnabled: false});
  assert.equal(paused.agents[0].label, 'Paused');
  assert.equal(paused.agents[1].guidance, '');
  const stale = present({}, {...state, updatedAt: now - 21});
  assert.equal(stale.agents[0].label, 'Unavailable');
  const disabled = present({}, {...state, configuredProviders: ['codex']});
  assert.equal(disabled.agents[1].enabled, false);
  assert.equal(disabled.agents[1].label, 'Available');
  const empty = present({}, {...state, configuredProviders: []});
  assert.equal(empty.agents[0].enabled, false);
  assert.equal(empty.agents[1].enabled, false);
});

test('setup guidance is shared only when both agents have never been observed', () => {
  const state = {configuredProviders: ['codex', 'claude'], sessionLiveness: 'process'};
  assert.match(present({}, state).agentGuidance, /each enabled agent/);
  const upgraded = present({}, {...state, providerCounts: {codex: {working: 1}}});
  assert.equal(upgraded.agents[0].label, 'Working');
  assert.equal(upgraded.agents[0].guidance, '');
  assert.equal(upgraded.agentGuidance, '');
  assert.match(upgraded.agents[1].guidance, /hooks/);
});
