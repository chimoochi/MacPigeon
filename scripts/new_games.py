"""Fresh invitations using the original app's inspected start-game fields."""
import base64,json,re,secrets,string,subprocess,uuid
from pathlib import Path
from urllib.parse import quote
from connect_codec import transform
from game_catalog import GAMES
from game_messages import options_for

def encoded_url(fields):
    encode=lambda pairs:'&'.join(quote(k,safe='')+'='+quote(v,safe='') for k,v in pairs)
    inner='?'+encode([(k,v) for k,v in fields.items() if k!='ver'])
    return 'data:?'+encode([('ver','52'),('data',transform(inner))])

def serialize(url,session,title):
    resources=Path(__file__).resolve().parent;helper=resources/'macpigeon-balloon'
    if not helper.exists():helper=resources.parent/'runtime/balloon/target/release/macpigeon-balloon-probe'
    r=subprocess.run([str(helper)],input=json.dumps({'mode':'new_invitation','url':url,'session':session,'caption':title}).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    if r.returncode or len(r.stdout)>1048576:raise ValueError('serialization_failed')
    raw=bytes(json.loads(r.stdout)['wire'])
    if len(raw)>262144:raise ValueError('wire_limit')
    return base64.b64encode(raw).decode()

def prepare(current,recipient,game,options,serializer=serialize):
    from game_session import validate,fields
    current=validate(dict(current));profile=fields(current['own_url'])
    if not re.fullmatch(r'tel:\+\d{7,15}',recipient):raise ValueError('recipient')
    config=options_for(game,options);own=current['own_id']
    avatar=profile.get('avatar'+profile['player'])
    if not avatar:raise ValueError('avatar_reference_required')
    alphabet=string.ascii_letters+string.digits
    fields_out=dict(sender=own,version='5',tver='5',ios=profile.get('ios','16.3.1'),start='',caption="Let's play "+GAMES[game][0]+'!',id=''.join(secrets.choice(alphabet) for _ in range(16)),player='2',player2=own,avatar2=avatar,game=game,game_name=GAMES[game][0],num='1',build=''.join(secrets.choice(alphabet) for _ in range(23)))
    fields_out.update(config);url=encoded_url(fields_out);session=str(uuid.uuid4())
    state=validate(dict(version=2,recipient=recipient,session_hex=session,own_url=url,url=url,pending=True,parent_url=current['url'],new_invitation=True))
    state['wire']=serializer(url,session,GAMES[game][0]);return state

def prepare_original(current,recipient,game,output,serializer=serialize):
    from game_session import validate
    from game_messages import checked_fields
    output=checked_fields(output)
    if not re.fullmatch(r'tel:\+\d{7,15}',recipient):raise ValueError('recipient')
    if output.get('game')!=game or game not in GAMES or output.get('num')!='1' or output.get('player')!='2' or 'start' not in output or not output.get('id') or not output.get('avatar2'):raise ValueError('original_invitation')
    if current is not None:current=validate(dict(current))
    url=encoded_url(output);session=str(uuid.uuid4())
    state=validate(dict(version=2,recipient=recipient,session_hex=session,own_url=url,url=url,pending=True,parent_url=current['url'] if current else '',new_invitation=True,native_invitation=True))
    state['wire']=serializer(url,session,GAMES[game][0])
    return state

def commit(current,proposed):
    from game_session import validate,fields
    if current is not None:current=validate(dict(current))
    proposed=validate(dict(proposed))
    if not proposed.get('new_invitation') or proposed['board']['kind']!='invitation' or proposed.get('parent_url')!=(current['url'] if current else ''):raise ValueError('invitation_binding')
    if not proposed.get('native_invitation'):
        if current is None or proposed['own_id']!=current['own_id'] or fields(proposed['url']).get('player2')!=current['own_id']:raise ValueError('identity')
    # Preserve the previous session before selecting the newly sent invitation.
    import game_session as gs
    import sync_selected_game as sync
    from import_mac_game import private_write
    if current is not None:private_write(gs.STORE.parent/'Sessions'/(sync.scope(current)+'.json'),current)
    proposed.pop('new_invitation',None);proposed.pop('parent_url',None)
    return proposed
