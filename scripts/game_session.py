"""Private companion game store. No Messages DB, text messages, or phone access."""
import base64, hashlib, json, os, sys, uuid
from pathlib import Path
import game_messages as messages

SUPPORT=Path.home()/'Library/Application Support/MacPigeon'
STORE=SUPPORT/'Games/current.json'

def read(path):
    if path.stat().st_size > 262144: raise ValueError('limit')
    return json.loads(path.read_bytes())

def fields(url):
    return messages.fields(url)

def board(url):
    return messages.describe(fields(url))

def write(state):
    STORE.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    STORE.parent.chmod(0o700)
    temporary=STORE.with_suffix('.tmp')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f:
        json.dump(state,f,separators=(',',':')); f.flush(); os.fsync(f.fileno())
    os.replace(temporary,STORE); STORE.chmod(0o600)

def validate(state):
    own,latest=fields(state['own_url']),fields(state['url'])
    invitation='start' in latest
    joining=invitation and state.get('joining') is True
    player=1 if joining else int(own['player'])
    own_id=own['sender']
    if player not in (1,2) or not own.get('id'):raise ValueError('identity')
    if not joining:
        if own.get('id')!=latest.get('id') or own.get('game')!=latest.get('game') or own.get('sender')!=own.get('player'+str(player)):raise ValueError('identity')
        for key in ('player1','player2'):
            if own.get(key) and own.get(key)!=latest.get(key):raise ValueError('identity')
        if latest.get('player'+str(player))!=own_id:raise ValueError('identity')
    elif own_id==latest.get('player2'):raise ValueError('identity')
    actor=int(latest['player'])
    if actor not in (1,2) or latest.get('sender')!=latest.get('player'+str(actor)): raise ValueError('actor')
    recipient=state['recipient']
    if not recipient.startswith('tel:+') or not recipient[5:].isdigit(): raise ValueError('recipient')
    uuid.UUID(state['session_hex'])
    state['board']=board(state['url']); state['own_player']=player;state['own_id']=own_id
    history=list(state.get('seen_url_hashes',[]))
    for key in ('url','own_url'):
        digest=hashlib.sha256(state[key].encode()).hexdigest()
        if digest not in history: history.append(digest)
    state['seen_url_hashes']=history[-64:]
    state.update(messages.result(latest))
    state['can_play']=actor!=player and not state.get('pending',False) and not state['finished']
    state['board']['finished']=state['finished']
    return state

def load():
    if STORE.exists(): return validate(read(STORE))
    old=SUPPORT/'Delivery'
    sent=read(old/'mac-reply-candidate-private.json');received=read(old/'live-selected-game-private.json');selector=read(old/'mac-test-selector.json')
    state=validate(dict(version=1,recipient='tel:'+selector['sender'],session_hex=sent['session_identifier_hex'],own_url=sent['url'],url=received['url'],wire=base64.b64encode((old/'rustpush-candidate-balloon.bin').read_bytes()).decode(),pending=False))
    write(state); return state

def accept(state,url):
    return advance(state,url,opponent_only=True)

def reconcile(state,url):
    """Accept the next session-bound original turn without interpreting its replay."""
    state=validate(dict(state))
    return state if url==state['url'] else advance(state,url)

def advance(state,url,opponent_only=False):
    state=validate(dict(state));old,new=fields(state['url']),fields(url)
    actor=int(new['player'])
    if state['finished'] or int(new['num'])!=int(old['num'])+1:raise ValueError('turn_gap')
    if new.get('id')!=old.get('id') or new.get('player2')!=old.get('player2') or new.get('sender')!=new.get('player'+str(actor)):raise ValueError('identity')
    if actor not in (1,2) or actor==int(old['player']) or (opponent_only and actor==state['own_player']):raise ValueError('identity')
    if old.get('player1'):
        if new.get('player1')!=old['player1']:raise ValueError('identity')
    elif 'start' not in old or actor!=1 or not new.get('player1') or new['player1']==new['player2']:raise ValueError('first_reply')
    if new['game']!=old['game']:raise ValueError('identity')
    updated=dict(state,url=url,pending=False,joining=False)
    if actor==state['own_player']:updated['own_url']=url
    return validate(updated)

def prepare_native(state,output,expected):
    state=validate(dict(state));old=fields(state['url']);game=old['game']
    if not state['can_play'] or int(old['num'])!=int(expected):raise ValueError('stale_or_not_your_turn')
    output=messages.checked_fields(output)
    if output.get('game')!=game or output.get('id')!=old['id'] or output.get('player')!=str(state['own_player']) or output.get('num')!=str(int(expected)+1) or output.get('sender')!=state['own_id']:raise ValueError('native_identity')
    from new_games import encoded_url
    proposed=dict(old);proposed.pop('start',None);proposed.pop('winner',None);proposed.update(output)
    proposed['sender']=state['own_id']
    if state.get('joining'):proposed['player1']=state['own_id']
    for key in ('player1','player2'):
        if old.get(key) and proposed.get(key)!=old[key]:raise ValueError('identity')
    url=encoded_url(proposed)
    return validate(dict(state,url=url,own_url=url,pending=True,joining=False,native_fields=output))

def main():
    request=json.loads(sys.stdin.buffer.readline(262145));action=request['action']
    state=load()
    if action=='prepare_native':state=prepare_native(state,request['fields'],request['expected_num'])
    elif action=='prepare_invitation':
        from new_games import prepare
        state=prepare(state,request['recipient'],request['game'],request.get('options',{}))
    elif action=='commit_invitation':
        from new_games import commit
        state=commit(state,request['state']);write(state)
        from sync_selected_game import authorize
        authorize()
    elif action=='commit':
        proposed=request['state']; current=load()
        if int(proposed['board']['num'])!=int(current['board']['num'])+1: raise ValueError('stale_commit')
        # Reconstruct independently from current state instead of trusting private input.
        state=prepare_native(current,proposed['native_fields'],int(current['board']['num']))
        if state['url']!=proposed['url']: raise ValueError('commit_binding')
        write(state)
    elif action=='receive': state=accept(state,request['url']);write(state)
    elif action!='load': raise ValueError('action')
    print(json.dumps(dict(ok=True,state=state),separators=(',',':')))

if __name__=='__main__':
    try: main()
    except Exception: print('{"ok":false,"stage":"game_state_validation"}');sys.exit(2)
