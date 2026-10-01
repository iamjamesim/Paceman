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
  var labels = {working: "Working", needs_input: "Needs input", finished: "Finished", idle: "No active work"}
  var result = {title: "Codex", label: labels[state.activity] || "Waiting for activity", breakdown: ""}
  if (!available) return result
  var counts = state.sessionCounts || {}
  var verified = state.sessionLiveness === "process"
  var order = verified ? ["needs_input", "working", "finished", "idle"] : ["needs_input", "working", "finished"]
  var valid = order.every(function(key) { return Number.isInteger(counts[key]) && counts[key] >= 0 })
  var total = order.reduce(function(sum, key) { return sum + (counts[key] || 0) }, 0)
  // Older status files contain only an aggregate; never guess the breakdown.
  if (!valid || total !== state.sessions) return result
  // New sources verify every session's process, including quiet/finished ones.
  // Older sources retained completions without proving they were still open.
  var visibleCount = verified ? total : counts.needs_input + counts.working
  if (visibleCount < 2) return result
  result.title = "Codex · " + visibleCount + (verified ? " sessions" : " active")
  var parts = (verified ? order : ["needs_input", "working"]).filter(function(key) { return counts[key] > 0 }).map(function(key) {
    return counts[key] + (key === "needs_input" ? (counts[key] === 1 ? " needs input" : " need input")
      : " " + key)
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
  var clients = Array.isArray(state.clients) ? state.clients.filter(function(client) {
    return client && typeof client.id === "string" && typeof client.name === "string" && !!client.name
      && typeof client.platform === "string"
  }) : []
  var paired = clients.length > 0
  var sharing = state.sharingEnabled !== false
  var activity = activitySummary(state, running && sharing)
  var connections = clients.map(function(client) {
    var contact = Number(client.lastContactAt || 0)
    var age = now - contact
    var recent = running && sharing && contact > 0 && age >= 0 && age < 30
    var phone = client.platform === "ios" || client.platform === "android"
    return {id: client.id, title: client.name, platform: client.platform,
      phone: phone, recent: recent,
      lastContactAt: contact, pairedAt: Number(client.pairedAt || 0),
      canRemove: client.removable !== false && !!client.id,
      status: contact > 0 ? "Last contact" : "No contact yet",
      guidance: !sharing ? "Turn sharing on to resume updates."
        : !running ? "Restart Paceman to resume updates."
        : phone ? "Open Paceman on your phone to check for updates."
        : "Open the paired app on this device to check for updates."}
  })
  return {
    connections: connections,
    connectionHeading: connections.some(function(client) { return !client.phone }) ? "CONNECTIONS"
      : connections.length > 1 ? "PHONES" : "PHONE",
    running: running, paired: paired, sharing: sharing,
    subtitle: !sharing ? "SHARING OFF" : !running ? "SHARING UNAVAILABLE" : "SHARING ACTIVITY",
    guidance: !sharing ? "Turn on sharing to connect your phone."
      : !running ? "Restart Paceman to connect your phone."
      : "On your iPhone, open Paceman → Connect computer → Scan QR code.",
    activityTitle: activity.title,
    activityBreakdown: activity.breakdown,
    activity: !sharing ? "Paused" : !running ? "Unavailable" : activity.label
  }
}
