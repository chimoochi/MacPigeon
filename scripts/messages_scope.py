"""Match a single-recipient conversation, including sent rows with no handle."""
def recipient_predicate(db, sender):
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if {'chat_message_join', 'chat_handle_join'} <= tables:
        return ('''EXISTS (SELECT 1 FROM chat_message_join cm
            JOIN chat_handle_join ch ON ch.chat_id=cm.chat_id
            JOIN handle h ON h.ROWID=ch.handle_id
            WHERE cm.message_id=m.ROWID AND h.id=?
            AND (SELECT count(*) FROM chat_handle_join members
                 WHERE members.chat_id=cm.chat_id)=1)''', (sender,))
    # Older/minimal stores have only direct per-message handles.
    return ('EXISTS (SELECT 1 FROM handle h WHERE h.ROWID=m.handle_id AND h.id=?)', (sender,))
