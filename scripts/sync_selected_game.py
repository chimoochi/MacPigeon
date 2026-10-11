"""Read only GamePigeon payloads bound to the authorized saved recipient/session."""
import argparse, hashlib, json, plistlib, sqlite3, uuid
from contextlib import closing
from pathlib import Path
from game_session import STORE, load, fields, reconcile, write
from messages_scope import recipient_predicate

BUNDLE='com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext'
AUTH=STORE.with_name('messages-sync-authorization.json')
MAX_BYTES=262144

def scope(state):
    return hashlib.sha256((state['recipient']+'|'+state['session_hex']).encode()).hexdigest()

def authorize():
    state=load();AUTH.parent.mkdir(parents=True,exist_ok=True)
    AUTH.write_text(json.dumps({'scope':scope(state)}));AUTH.chmod(0o600)

def game_url(payload):
    stack=[(plistlib.loads(payload),0)];seen=0;urls=set()
    while stack:
        value,depth=stack.pop();seen+=1
        if seen>10000 or depth>32:raise ValueError('archive_limit')
        if isinstance(value,dict):stack.extend((x,depth+1) for x in value.values())
        elif isinstance(value,list):stack.extend((x,depth+1) for x in value)
        elif isinstance(value,bytes) and value.startswith((b'bplist00',b'<?xml')):
            if len(value)>MAX_BYTES:raise ValueError('archive_limit')
            stack.append((plistlib.loads(value),depth+1))
        elif isinstance(value,str) and value.startswith(('data:','https:','http:')):
            try:
                fields(value);urls.add(value)
            except (ValueError,KeyError,UnicodeError):pass
    if len(urls)!=1:raise ValueError('ambiguous_game_url')
    return urls.pop()

def synchronize(apply=True,database=None):
    original=load()
    if not AUTH.exists() or json.loads(AUTH.read_text()).get('scope')!=scope(original):return {'status':'not_authorized','updated':False}
    recipient=original['recipient'][4:]
    session=uuid.UUID(original['session_hex'])
    database=database or Path.home()/'Library/Messages/chat.db'
    # Match the session's raw UUID inside the archive BEFORE fetching any payload.
    state=original
    try:
        with closing(sqlite3.connect(database.as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
            db.execute('PRAGMA query_only=ON');db.execute('BEGIN')
            sql_scope,scope_args=recipient_predicate(db,recipient)
            predicate=sql_scope+' AND m.balloon_bundle_id=? AND (instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0)'
            args=scope_args+(BUNDLE,session.bytes,str(session).encode(),str(session).upper().encode())
            rows=db.execute('SELECT m.ROWID,m.is_from_me,length(m.payload_data) FROM message m WHERE '+predicate+' ORDER BY m.date DESC,m.ROWID DESC LIMIT 65',args).fetchall()
            if len(rows)>64:return {'status':'history_limit','updated':False}
            candidates=[]
            for rowid,outgoing,size in reversed(rows):
                if size is None or not 0<size<=MAX_BYTES:raise ValueError('payload_limit')
                row=db.execute('SELECT m.payload_data FROM message m WHERE m.ROWID=? AND '+predicate,(rowid,)+args).fetchone()
                if row is None or not isinstance(row[0],bytes):raise ValueError('payload_storage')
                url=game_url(row[0]);f=fields(url)
                if int(f.get('num','0'))<=int(original['board']['num']):continue
                before=fields(original['url'])
                if any(before.get(k) and f.get(k)!=before[k] for k in ('game','id','player1','player2')):raise ValueError('session_identity')
                if bool(outgoing)!=(int(f['player'])==original['own_player']):raise ValueError('sender_identity')
                candidates.append((int(f['num']),url))
            for _,url in sorted(candidates,key=lambda x:x[0]):
                if url==state['url']:continue
                state=reconcile(state,url)
    except sqlite3.Error:return {'status':'messages_access_required','updated':False}
    except (ValueError,KeyError,TypeError,plistlib.InvalidFileException) as error:
        stage=str(error) if isinstance(error,ValueError) and str(error) in {'archive_limit','ambiguous_game_url','payload_limit','payload_storage','session_identity','sender_identity','identity','turn_gap','illegal_transition'} else 'payload_validation'
        return {'status':'validation_failed','stage':stage,'updated':False}
    changed=state['url']!=original['url']
    if changed and apply:
        current=load()
        if current['url']!=original['url'] or current.get('pending')!=original.get('pending'):return {'status':'state_changed','updated':False}
        write(state)
    return {'status':'updated' if changed else 'current','updated':changed,'num':int(state['board']['num']),'can_play':state['can_play']}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--authorize-selected-session',action='store_true');parser.add_argument('--check-only',action='store_true');a=parser.parse_args()
    if a.authorize_selected_session:authorize()
    print(json.dumps(synchronize(apply=not a.check_only)))
