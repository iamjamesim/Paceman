# Agent model boundaries

Paceman models an observation of an agent and, where supported, a bounded request
for human input. It does not mirror a provider's complete conversation, tool or
permission system. Desktop adapters own native schemas and correlation; the phone
and Watch share the same validated content and presentation semantics.

| Concept | Common meaning | Boundary |
| --- | --- | --- |
| Provider | Stable, case-sensitive identifier namespace | Common decoders accept new namespaces; adapters explicitly enable providers and interpret their native tool schemas. |
| Session | Identity scoped by computer source, provider and canonical session ID | Titles are metadata. `AgentSession.state` describes observed current/last turn activity; Finished does not finish the conversation. Native IDs and launch links remain provider-specific. |
| Activity | One of the protocol's normalized states, with observation freshness | New native statuses map only where meanings agree. Unknown common state meanings require a negotiated schema change. |
| Request | Source-scoped broker generation, request ID and immutable version | Separate from session, turn and tool-call identity. The adapter owns native correlation and request authority; content version is a different axis. |
| Tool approval | Typed action description, complete input and explicitly offered decision IDs | Labels are display text. Allow, decline, cancel, scope grants and policy amendments are not interchangeable. Native response payloads remain adapter-owned. |
| Question | The v1 bounded text/selection profile | Required questions, single/multiple selection, optional text, and selection plus comment. This is not an arbitrary form, secure input or external authentication flow. |
| Submission | An exact answer to one request/version with an idempotency key | Paceman receipt, provider consumption and subsequent work are distinct. See [lifecycle](data-lifecycle.md#questions-and-approvals). |
| Usage | Currently `CodexAllowance`, with Codex quota/window meanings | Do not reuse it for another provider until units, account scope, windows and reset meanings have an explicit common contract. |

The wire envelope keeps compatibility fields, but its validated content is a
discriminated union: legacy approval, structured tool approval, or questions.
Actions similarly validate as command, patch, file write, file edit, terminal input
or opaque tool input. Mixed variants, missing required fields, inconsistent
terminal operations and unknown content versions cannot expose decision controls.
Terminal targets are opaque strings; adapters interpret native numeric IDs.

Known schemas are decoded once on the desktop, within their provider namespace.
Complete serialized tool input is retained separately from the typed display
projection. This avoids client numeric conversion and preserves unfamiliar fields;
it does not claim to preserve the original provider's JSON whitespace or byte order.
Original input and choices are immutable for the request/version. Choice indices
in v1 answers are scoped to that immutable option list, never labels or another
request. See [wire fields and bounds](protocol.md#pending-interactions).

## Extending the model

- Adding a provider does not add a new request kind. Its adapter must supply the
  common semantics faithfully and demonstrate them with provider fixtures.
- Optional descriptive metadata may be additive. New required behavior, answer
  constraints, decision payloads or content variants need a negotiated content
  version; unknown versions retain native continuation. A required semantic must
  never be hidden in an optional field an older client can ignore.
- Native transport method names do not determine meaning: a Codex user-input RPC
  can represent an approval, while Claude has both questions and MCP elicitation.
  Classify the actual request, rather than copying the native method name.
- Structured permission subsets, plan review, typed MCP forms, optional/defaulted
  fields, secret answers and URL authentication are outside the current question
  profile. Keep them native until the complete interaction and response semantics
  can be represented; do not flatten them into unrestricted text or yes/no.
- Unknown tool arguments can use the opaque tool variant with complete input and
  explicit choices. Unknown *interaction semantics* require native continuation.
- Each extension needs desktop/client/Watch round trips, unsupported-version and
  native-continuation checks, plus identity and lifecycle regressions. Source
  snapshots, interaction content, APNs and accessory formats evolve independently.

Native reference semantics: [Codex App Server](https://learn.chatgpt.com/docs/app-server),
[Claude hooks](https://code.claude.com/docs/en/hooks), and
[MCP elicitation](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation).
These describe provider concepts, not permission to intercept their native UI.
