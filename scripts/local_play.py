"""Pass-and-play turns only. No account, network, Messages, or remote game store."""
import hashlib,json,sys,uuid
from urllib.parse import urlencode,quote
import game_adapters as adapters

PLAYERS={1:'macpigeon-local-player-1',2:'macpigeon-local-player-2'}

def render(d,actor,initial_options=None):
    decoded=adapters.inspect(d);result=adapters.result(d,decoded)
    url='?'+urlencode(sorted(d.items()),quote_via=quote)
    revision=hashlib.sha256((url+'|'+str(actor)).encode()).hexdigest()
    rendered=dict(format=1,mode='local',fields=d,game=d['game'],title=adapters.GAMES[d['game']][0],
                kind=decoded['kind'],url=url,own_player=actor,own_id=PLAYERS[actor],num=int(d['num']),
                revision=revision,can_play=not result['finished'],status='Game finished.' if result['finished'] else f"Player {actor}'s turn",**result)
    if initial_options is not None:
        adapters.invitation_options(d['game'],initial_options)
        rendered['initial_options']=dict(initial_options)
    return rendered

def validate(state):
    if state.get('format')!=1 or state.get('mode')!='local':raise ValueError('local_session')
    d=state['fields'];actor=state['own_player']
    if d.get('game') in adapters.REALTIME_GAMES:raise ValueError('online_game_required')
    if type(actor)!=int or actor not in PLAYERS or not isinstance(d,dict) or len(d)>48:raise ValueError('local_player')
    if any(not isinstance(k,str) or not isinstance(v,str) or len(v)>65536 for k,v in d.items()):raise ValueError('local_fields')
    if set(d)-(adapters.COMMON|adapters.EXTRA[d['game']]):raise ValueError('local_field')
    if d.get('player2')!=PLAYERS[2] or ('player1' in d and d['player1']!=PLAYERS[1]):raise ValueError('local_identity')
    latest=int(d['player'])
    if latest not in PLAYERS or d.get('sender')!=PLAYERS[latest]:raise ValueError('local_actor')
    if not d.get('id') or not d.get('num','').isdigit() or not 1<=int(d['num'])<=999999999:raise ValueError('local_ordinal')
    rendered=render(d,actor,state.get('initial_options'))
    if not rendered['finished'] and actor!=3-latest:raise ValueError('local_turn')
    if state.get('revision')!=rendered['revision']:raise ValueError('local_revision')
    return rendered

def load(state):
    # Validate the original save before upgrading locally generated metadata.
    checked=validate(state)
    d=dict(checked['fields'])
    if 'ver' not in d:d['ver']='52'  # Original wire-envelope protocol revision.
    if 'start' in d and d['game']=='pool':
        for key,value in dict(v2='1',v3='1',v4='2',v5='2').items():
            d.setdefault(key,value)
    return validate(render(d,checked['own_player'],checked.get('initial_options')))

def start(game,options,avatar=''):
    if game in adapters.REALTIME_GAMES:raise ValueError('online_game_required')
    adapter=adapters.get(game);config=adapters.invitation_options(game,options)
    if not isinstance(avatar,str) or len(avatar)>16384:raise ValueError('local_avatar')
    d=dict(game=game,id=uuid.uuid4().hex,player='2',player2=PLAYERS[2],sender=PLAYERS[2],num='1',start='',version='5',tver='5',ver='52',game_name=adapter.TITLE)
    if avatar:d.update(avatar1=avatar,avatar2=avatar)
    d.update(config)
    if game in ('pool','pool2','pool3'):
        for key,value in dict(v2='2' if game=='pool3' else '1',v3='2' if game=='pool3' else '1',v4='2',v5='2').items():d.setdefault(key,value)
    if game=='chess':d['version']='19'
    return validate(render(d,1,dict(config,__native='1')))

def play(state,output,revision):
    state=validate(state);before=state['fields'];actor=state['own_player']
    if state['finished'] or revision!=state['revision']:raise ValueError('local_stale_or_finished')
    if not isinstance(output,dict) or len(output)>48 or any(not isinstance(k,str) or not isinstance(v,str) or len(v)>65536 for k,v in output.items()):raise ValueError('local_move_fields')
    if set(output)-(adapters.COMMON|adapters.EXTRA[before['game']]):raise ValueError('local_move_field')
    if output.get('game')!=before['game'] or output.get('id')!=before['id'] or output.get('player')!=str(actor) or output.get('sender')!=PLAYERS[actor] or output.get('num')!=str(int(before['num'])+1):raise ValueError('local_move_identity')
    after=dict(before);after.pop('start',None);after.pop('winner',None);after.update(output);after['player1']=PLAYERS[1]
    if after['player2']!=PLAYERS[2] or output.get('player1',PLAYERS[1])!=PLAYERS[1]:raise ValueError('local_identity')
    decoded=adapters.transition(before,after);result=adapters.result(after,decoded)
    return validate(render(after,actor if result['finished'] else 3-actor,state.get('initial_options')))

def main():
    data=sys.stdin.buffer.readline(262145)
    if len(data)>262144:raise ValueError('local_limit')
    r=json.loads(data)
    if r['action']=='start':state=start(r['game'],r.get('options',{}),r.get('avatar',''))
    elif r['action']=='play':state=play(r['state'],r['fields'],r['revision'])
    elif r['action']=='load':state=load(r['state'])
    else:raise ValueError('local_action')
    print(json.dumps(dict(ok=True,state=state),separators=(',',':')))

if __name__=='__main__':
    try:main()
    except Exception:print('{"ok":false,"error":"This local turn could not be loaded. Try again or start a new game."}');sys.exit(2)
