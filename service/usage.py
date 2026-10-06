"""Codex usage helpers shared by source and watch push paths."""


def valid_reading(value):
    return (isinstance(value, dict) and value.get('provider') == 'codex'
        and type(value.get('remaining')) is int and 0 <= value['remaining'] <= 100
        and type(value.get('window')) is int and value['window'] in (1, 2)
        and type(value.get('updatedAt')) is int and 1704067200 <= value['updatedAt']
        and type(value.get('resetsAt')) is int and value['updatedAt'] < value['resetsAt'] <= 3155759999
        and (value.get('windowDurationMins') is None or
             type(value['windowDurationMins']) is int and 1 <= value['windowDurationMins'] <= 10080))


def readings(snapshot):
    if isinstance(snapshot.get('allowances'), list):
        return [r for r in snapshot['allowances'] if valid_reading(r)]
    reading = snapshot.get('allowance')
    return [reading] if valid_reading(reading) else []


def selected_reading(values, now=None):
    usable = [r for r in values if valid_reading(r) and
              (now is None or r['updatedAt'] <= now < r['resetsAt'])]
    return min(usable, key=lambda r: (r['remaining'], r['window'] != 1)) if usable else None
