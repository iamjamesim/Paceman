"""RAM-only native decision identities, independent of display and turn outcome."""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class PendingDecisions:
    owner: str
    # (optional turn, ID type, ID). An absent turn means session scope.
    requests: frozenset[tuple[str | None, str, str]]
    inputs: frozenset[tuple[tuple[str | None, str, str], str]] = frozenset()
    resolved: frozenset[tuple[str | None, str, str]] = frozenset()
    known_turns: frozenset[str] = frozenset()
    uncertain: bool = False
    waiting_on_human: bool = False
    # Previously observed identities that the current channel cannot reconfirm.
    unverified: frozenset[tuple[str | None, str, str]] = frozenset()
    unverified_waiting: bool = False
    uncertain_turn: str | None = None

    def __bool__(self):
        return self.uncertain or self.waiting_on_human or self.unverified_waiting or bool(self.requests)

    def for_turn(self, turn):
        return frozenset(key for key in self.requests if key[0] is None or key[0] == turn)

    def merge(self, previous):
        if not isinstance(previous, PendingDecisions) or previous.owner != self.owner:
            return self
        resolved = previous.resolved & self.requests
        return replace(self, requests=self.requests - resolved, resolved=resolved,
                       uncertain=self.uncertain or previous.uncertain)

    def resolve_input(self, input_hash):
        matching = {key for key, value in self.inputs if value == input_hash and key in self.requests}
        if len(matching) != 1:
            return self  # A server-name fallback cannot resolve concurrent forms.
        return replace(self, requests=self.requests - matching, resolved=self.resolved | matching)

    def disconnected(self):
        return replace(self, unverified=self.requests,
                       unverified_waiting=self.unverified_waiting or self.waiting_on_human, waiting_on_human=False)


def native_waiting(native, turn):
    if isinstance(native, PendingDecisions):
        inherited = native.uncertain and (native.uncertain_turn is None or native.uncertain_turn == turn)
        return inherited or native.waiting_on_human or native.unverified_waiting or bool(native.for_turn(turn))
    return bool(native and (native[0] is None or native[0] == turn) and native[1])


def native_empty(native, turn):
    return (isinstance(native, PendingDecisions) and turn in native.known_turns
            and not native_waiting(native, turn))


def native_unverified(native, turn):
    """Retain last-known attention without claiming the owner still awaits it."""
    return (isinstance(native, PendingDecisions) and native_waiting(native, turn)
            and not native.waiting_on_human and not (native.for_turn(turn) - native.unverified))
