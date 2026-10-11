"""Explicit, scoped GamePigeon import. Metadata first; one user choice, then one session.
Never selects ordinary message text or follows attachment paths.
"""
import base64, datetime as dt, hashlib, json, os, plistlib, sqlite3, subprocess, sys, time, uuid
from contextlib import closing
from pathlib import Path
import game_session as gs
import sync_selected_game as sync

MAX_BYTES=262144
EPOCH=dt.datetime(2001,1,1,tzinfo=dt.timezone.utc)

def handle(value):
    if not isinstance(value,str) or not value.startswith('tel:+') or not value[5:].isascii() or not value[5:].isdigit() or not 7<=len(value[5:])<=15:raise ValueError('recipient_unsupported')
    return value[4:]

def db_open(database):
    db=sqlite3.connect(Path(database).as_uri()+'?mode=ro',uri=True,timeout=2)
    db.execute('PRAGMA query_only=ON');db.execute('BEGIN');return db

def private_write(path,value):
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True);path.parent.chmod(0o700)
    tmp=path.with_suffix('.tmp');fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f:json.dump(value,f,separators=(',',':'));f.flush();os.fsync(f.fileno())
    os.replace(tmp,path);path.chmod(0o600)

def metadata(recipient,database,guid=None,prefer_current=False,latest=False):
    sender=handle(recipient)
    known=None
    try:
        current=gs.load()
        if current['recipient']==recipient and gs.read(sync.AUTH).get('scope')==sync.scope(current):known=uuid.UUID(current['session_hex'])
    except (OSError,ValueError,KeyError,TypeError):pass
    with closing(db_open(database)) as db:
        where='h.id=? AND m.balloon_bundle_id=?';args=[sender,sync.BUNDLE]
        if guid:
            uuid.UUID(guid);where+=' AND upper(m.guid)=upper(?)';args.append(guid)
        # Only compare an already-authorized session UUID in SQLite. No URLs,
        # text, or unknown game payloads are fetched to populate the picker.
        match='0';prefix=[]
        if known:
            match='(instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0)'
            prefix=[known.bytes,str(known).encode(),str(known).upper().encode()]
        rows=db.execute('SELECT m.ROWID,m.guid,m.date,m.is_from_me,length(m.payload_data),'+match+' FROM message m JOIN handle h ON h.ROWID=m.handle_id WHERE '+where+' ORDER BY m.date DESC,m.ROWID DESC LIMIT 21',prefix+args).fetchall()
    if guid and len(rows)!=1:raise ValueError('selected_bubble_unavailable')
    # Bubble-open fallback resumes the current authorized game only when the
    # newest visible metadata row belongs to it. Older unrelated games remain
    # available through the explicit chooser, never read by this shortcut.
    if latest and guid is None:rows=rows[:1]
    current_shortcut=bool(prefer_current and guid is None and rows and rows[0][5])
    if current_shortcut:rows=[row for row in rows if row[5]][:1]
    token=uuid.uuid4().hex;choices=[];private=[]
    grouped_known=False
    for rowid,message_guid,date,out,size,same_session in rows[:20]:
        if same_session and grouped_known:continue
        if size is None or not 0<size<=MAX_BYTES:continue
        if not isinstance(date,int):continue
        seconds=date/1e9 if abs(date)>10**12 else date
        when=(EPOCH+dt.timedelta(seconds=seconds)).astimezone()
        choice=uuid.uuid4().hex
        choices.append({'id':choice,'date':when.isoformat(),'outgoing':bool(out),'known_session':bool(same_session)})
        if same_session:grouped_known=True
        private.append({'id':choice,'rowid':rowid,'guid':message_guid,'date':date,'outgoing':out})
    private_write(gs.STORE.with_name('import-choice.json'),{'token':token,'recipient':recipient,'expires_at':time.time()+300,'choices':private})
    return {'ok':True,'token':token,'choices':choices,'exact':guid is not None,'automatic':len(choices)==1 and (latest or current_shortcut or guid is not None or (len(rows)<=20 and all(row[5] for row in rows)))}

def facts(payload):
    if not isinstance(payload,bytes) or not 0<len(payload)<=MAX_BYTES:raise ValueError('payload_limit')
    archive=plistlib.loads(payload);objects=archive.get('$objects')
    if not isinstance(objects,list) or len(objects)>10000:raise ValueError('archive_schema')
    def resolve(v):
        if isinstance(v,plistlib.UID):
            if not 0<=v.data<len(objects):raise ValueError('archive_reference')
            return objects[v.data]
        return v
    top=archive['$top']
    if len(top)!=1:raise ValueError('archive_root')
    root=resolve(next(iter(top.values())))
    values={resolve(k):resolve(v) for k,v in zip(root['NS.keys'],root['NS.objects'],strict=True)}
    raw_url=resolve(values['URL']);url=resolve(raw_url['NS.relative'])
    if not isinstance(url,str) or len(url)>131072:raise ValueError('url_limit')
    session=resolve(values['sessionIdentifier'])
    if resolve(session['$class']).get('$classname')!='NSUUID' or len(session.get('NS.uuidbytes',b''))!=16:raise ValueError('session_schema')
    return {'url':url,'session':uuid.UUID(bytes=session['NS.uuidbytes'])}

def wire(payload,url,session):
    resources=Path(__file__).resolve().parent
    helper=resources/'macpigeon-balloon'
    if not helper.exists():helper=resources.parent/'runtime/balloon/target/release/macpigeon-balloon-probe'
    from game_adapters import GAMES
    result=subprocess.run([str(helper)],input=json.dumps({'payload':list(payload),'url':url,'session':str(session),'caption':GAMES[gs.fields(url)['game']][0]}).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    if result.returncode or len(result.stdout)>1048576:raise ValueError('serialization_failed')
    raw=bytes(json.loads(result.stdout)['wire'])
    if len(raw)>MAX_BYTES:raise ValueError('wire_limit')
    return base64.b64encode(raw).decode()

def selected(request,database,serialize=wire):
    ticket=gs.read(gs.STORE.with_name('import-choice.json'))
    if request.get('token')!=ticket['token'] or ticket['expires_at']<time.time() or request.get('recipient')!=ticket['recipient']:raise ValueError('selection_expired')
    chosen=[c for c in ticket['choices'] if c['id']==request.get('choice')]
    if len(chosen)!=1:raise ValueError('selection_required')
    chosen=chosen[0];recipient=ticket['recipient'];sender=handle(recipient)
    with closing(db_open(database)) as db:
        args=(chosen['rowid'],chosen['guid'],chosen['date'],chosen['outgoing'],sender,sync.BUNDLE)
        row=db.execute('SELECT m.payload_data FROM message m JOIN handle h ON h.ROWID=m.handle_id WHERE m.ROWID=? AND m.guid=? AND m.date=? AND m.is_from_me=? AND h.id=? AND m.balloon_bundle_id=?',args).fetchone()
        if row is None:raise ValueError('selected_bubble_changed')
        selected_payload=row[0];picked=facts(selected_payload);session=picked['session'];f=gs.fields(picked['url'])
        gs.board(picked['url'])
        predicate='h.id=? AND m.balloon_bundle_id=? AND (instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0 OR instr(m.payload_data,?)>0)'
        params=(sender,sync.BUNDLE,session.bytes,str(session).encode(),str(session).upper().encode())
        rows=db.execute('SELECT m.ROWID,m.is_from_me,length(m.payload_data) FROM message m JOIN handle h ON h.ROWID=m.handle_id WHERE '+predicate+' ORDER BY m.date DESC,m.ROWID DESC LIMIT 65',params).fetchall()
        if len(rows)>64:raise ValueError('history_limit')
        turns=[];owns=[]
        for rowid,out,size in rows:
            if size is None or not 0<size<=MAX_BYTES:raise ValueError('payload_limit')
            raw=db.execute('SELECT m.payload_data FROM message m JOIN handle h ON h.ROWID=m.handle_id WHERE m.ROWID=? AND '+predicate,(rowid,)+params).fetchone()[0]
            item=facts(raw)
            if item['session']!=session:raise ValueError('session_identity')
            fields=gs.fields(item['url'])
            if fields.get('id')!=f.get('id'):raise ValueError('session_identity')
            # An actual sent bubble establishes the local token; don't invent it from a number.
            if out:owns.append((int(fields['num']),item['url']))
            if 'start' not in fields:turns.append((int(fields['num']),item['url'],bool(out)))
    joining=False
    if owns:own=max(owns,key=lambda p:p[0])[1]
    elif 'start' in f:
        try:own=gs.load()['own_url'];joining=True
        except (OSError,ValueError,KeyError):raise ValueError('own_reference_required')
    else:raise ValueError('own_reference_required')
    state=gs.validate(dict(version=2,recipient=recipient,session_hex=session.hex,own_url=own,url=picked['url'],pending=False,wire='',joining=joining))
    if bool(chosen['outgoing'])!=(int(f['player'])==state['own_player']):raise ValueError('sender_identity')
    for num,url,out in sorted(turns,key=lambda p:p[0]):
        if num<int(state['board']['num']):continue
        if out!=(int(gs.fields(url)['player'])==state['own_player']):raise ValueError('sender_identity')
        if num==int(state['board']['num']):
            if url!=state['url']:raise ValueError('conflicting_turn')
            continue
        state=gs.reconcile(state,url)
    state['wire']=serialize(selected_payload,state['url'],session)
    # Preserve existing games before switching the one transport-selected session.
    sessions=gs.STORE.parent/'Sessions'
    if gs.STORE.exists():
        old=gs.load();private_write(sessions/(sync.scope(old)+'.json'),old)
    private_write(sessions/(sync.scope(state)+'.json'),state)
    gs.write(state);sync.authorize()
    return {'ok':True,'status':'imported','num':int(state['board']['num']),'can_play':state['can_play'],'finished':state['finished']}

def saved_sessions(recipient):
    handle(recipient);choices=[]
    for path in sorted((gs.STORE.parent/'Sessions').glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[:200]:
        state=gs.validate(gs.read(path))
        if state['recipient']!=recipient:continue
        choices.append({'id':path.stem,'num':int(state['board']['num']),'finished':state['finished'],'can_play':state['can_play']})
    return {'ok':True,'saved':choices}

def resume(request):
    recipient=request['recipient'];handle(recipient);key=request['choice']
    if len(key)!=64 or any(c not in '0123456789abcdef' for c in key):raise ValueError('selection_required')
    sessions=gs.STORE.parent/'Sessions';state=gs.validate(gs.read(sessions/(key+'.json')))
    if state['recipient']!=recipient or sync.scope(state)!=key:raise ValueError('recipient_changed')
    if gs.STORE.exists():
        previous=gs.load();private_write(sessions/(sync.scope(previous)+'.json'),previous)
        if sync.scope(previous)==key:state=previous
    gs.write(state);sync.authorize();return {'ok':True,'status':'resumed'}

def main():
    request=json.loads(sys.stdin.buffer.readline(65537));database=Path.home()/'Library/Messages/chat.db'
    try:
        if request['action']=='list':result=metadata(request['recipient'],database,request.get('guid'),request.get('prefer_current') is True,request.get('latest') is True)
        elif request['action']=='select':result=selected(request,database)
        elif request['action']=='saved':result=saved_sessions(request['recipient'])
        elif request['action']=='resume':result=resume(request)
        else:raise ValueError('action')
    except sqlite3.Error:result={'ok':False,'error':'messages_access_required'}
    except (ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError,plistlib.InvalidFileException) as error:
        safe={'own_reference_required','selection_expired','history_limit','turn_gap','game','invitation_not_supported','conflicting_turn','recipient_changed'}
        result={'ok':False,'error':str(error) if isinstance(error,ValueError) and str(error) in safe else 'selection_not_supported'}
    print(json.dumps(result,separators=(',',':')))
if __name__=='__main__':main()
