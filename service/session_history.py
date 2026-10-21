"""Bounded completion metadata, independent of live session membership."""
import json

FINISHED_DISPLAY_DURATION = 30 * 60
COMPLETED_RETENTION = 7 * 24 * 60 * 60
MAX_COMPLETED_SESSIONS = 128


def completed_sessions(db, sessions, now, providers=None):
    """Remember the latest result per session; new activity supersedes it."""
    known = {(row['provider'], row['id']): dict(row) for row in
             db.execute('SELECT * FROM completed_sessions')}
    for session in sessions:
        key = (session['provider'], session['id'])
        previous = known.get(key)
        if session['state'] not in ('finished', 'failed'):
            if previous:
                db.execute('DELETE FROM completed_sessions WHERE provider=? AND id=?', key)
            continue
        completed_at = previous['completed_at'] if previous else session.get('resultObservedAt', now)
        session['resultObservedAt'] = completed_at
        payload = json.dumps(session, sort_keys=True, separators=(',', ':'))
        if not previous or previous['payload'] != payload:
            db.execute('INSERT OR REPLACE INTO completed_sessions VALUES (?,?,?,?)',
                       (*key, completed_at, payload))
    db.execute('DELETE FROM completed_sessions WHERE completed_at<=?', (now - COMPLETED_RETENTION,))
    if providers is not None:
        for provider, in db.execute('SELECT DISTINCT provider FROM completed_sessions').fetchall():
            if provider not in providers:
                db.execute('DELETE FROM completed_sessions WHERE provider=?', (provider,))
    db.execute('DELETE FROM completed_sessions WHERE rowid IN '
               '(SELECT rowid FROM completed_sessions ORDER BY completed_at DESC,provider,id LIMIT -1 OFFSET ?)',
               (MAX_COMPLETED_SESSIONS,))
    return [json.loads(row[0]) for row in db.execute(
        'SELECT payload FROM completed_sessions ORDER BY completed_at DESC,provider,id')]


def recover_completed_sessions(db, now):
    # Existing event snapshots can recover recent results on the first upgrade.
    # Replaying live states also removes a result superseded by a later turn.
    if db.execute("SELECT 1 FROM metadata WHERE key='completed_sessions_migrated'").fetchone():
        return
    for row in db.execute('SELECT at,payload FROM events WHERE at>? ORDER BY seq',
                          (now - COMPLETED_RETENTION,)).fetchall():
        payload = json.loads(row['payload'] or '{}')
        completed_sessions(db, payload.get('sessions') or [], row['at'])
    completed_sessions(db, [], now)
    db.execute("INSERT INTO metadata VALUES ('completed_sessions_migrated','1')")


def display_sessions(sessions, completed, now):
    """A closed agent still leaves its result visible for the glance window."""
    live = {(session['provider'], session['id']) for session in sessions}
    return sorted(sessions + [session for session in completed
        if (session['provider'], session['id']) not in live
        and now - FINISHED_DISPLAY_DURATION < session['resultObservedAt'] <= now],
        key=lambda session: (session['id'], session['provider']))


def retained_completions(sessions, completed):
    live = {(session['provider'], session['id']) for session in sessions}
    result, size = [], 0
    for session in completed:
        if (session['provider'], session['id']) in live:
            continue
        size += len(json.dumps(session, ensure_ascii=True).encode('utf-8'))
        if size > 24 * 1024:
            break
        result.append(session)
    return result
