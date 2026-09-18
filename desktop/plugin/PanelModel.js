function relativeTime(value, now) {
  if (!Number(value)) return "No contact yet"
  var age = Math.max(0, now - Number(value))
  if (age < 10) return "Just now"
  if (age < 60) return Math.floor(age) + "s ago"
  if (age < 3600) return Math.floor(age / 60) + "m ago"
  if (age < 86400) return Math.floor(age / 3600) + "h ago"
  return Math.floor(age / 86400) + "d ago"
}

function activitySummary(state, available) {
  var labels = {working: "Working", needs_input: "Needs your input", finished: "Finished", idle: "No active work"}
  var result = {title: "Codex", label: labels[state.activity] || "Waiting for activity", breakdown: ""}
  if (!available) return result
  var counts = state.sessionCounts || {}
  var order = ["needs_input", "working", "finished"]
  var valid = order.every(function(key) { return Number.isInteger(counts[key]) && counts[key] >= 0 })
  var total = order.reduce(function(sum, key) { return sum + (counts[key] || 0) }, 0)
  // Older status files contain only an aggregate; never guess the breakdown.
  if (!valid || total !== state.sessions || total < 2) return result
  result.title = "Codex · " + total + " sessions"
  var parts = order.filter(function(key) { return counts[key] > 0 }).map(function(key) {
    return counts[key] + (key === "needs_input" ? (counts[key] === 1 ? " needs input" : " need input")
      : key === "working" ? " working" : " finished")
  })
  if (parts.length === 1) result.label = parts[0]
  else {
    result.label = state.activity === "needs_input" ? "Needs input" : result.label
    result.breakdown = parts.join(" · ")
  }
  return result
}

function present(state, now) {
  var age = now - Number(state.updatedAt || 0)
  var running = state.running === true && age >= 0 && age < 20
  var contactAge = now - Number(state.lastPhoneFetchAt || 0)
  var recent = running && Number(state.lastPhoneFetchAt || 0) > 0 && contactAge >= 0 && contactAge < 30
  var paired = Number(state.pairedPhones || 0) > 0
  var sharing = state.sharingEnabled !== false
  var activity = activitySummary(state, running && sharing)
  return {
    running: running, recent: recent && sharing, paired: paired, sharing: sharing,
    subtitle: !sharing ? "SHARING OFF" : !running ? "SHARING UNAVAILABLE" : "SHARING ACTIVITY",
    phoneTitle: paired ? "Your phone" : "Connect your phone",
    phoneStatus: !sharing ? "Sharing is off" : !running ? "Desktop unavailable"
      : !paired ? "Pair once to receive updates" : recent ? "Receiving updates" : "Waiting for contact",
    guidance: !sharing ? "Turn sharing on to send updates from this computer."
      : !running ? "Paceman isn't running. Restart it to resume sharing."
      : !paired ? "Open Paceman on your iPhone and scan a pairing code."
      : "Open Paceman on your iPhone to reconnect.",
    activityTitle: activity.title,
    activityBreakdown: activity.breakdown,
    activity: !sharing ? "Paused" : !running ? "Unavailable" : activity.label
  }
}
