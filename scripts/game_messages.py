"""Common message metadata. Game-specific fields stay opaque to Python."""
import re
from connect_codec import query_items, unwrap
from game_catalog import GAMES, REALTIME_GAMES

IDENTITY = {'id','game','game_name','num','player','player1','player2','sender','avatar1','avatar2','start','caption','winner'}

def checked_fields(value):
    if not isinstance(value,dict) or not 1<=len(value)<=128:raise ValueError('message_fields')
    if any(not isinstance(k,str) or not k or len(k)>256 or not isinstance(v,str) or len(v)>131072 for k,v in value.items()):raise ValueError('message_field')
    return dict(value)

def fields(url):
    pairs=query_items(unwrap(url));d=checked_fields(dict(pairs))
    if len(d)!=len(pairs):raise ValueError('duplicate_fields')
    if d.get('game') not in GAMES:raise ValueError('game')
    if not re.fullmatch(r'[1-9]\d{0,8}',d.get('num','')):raise ValueError('ordinal')
    return d

def options_for(game,options):
    if game not in GAMES:raise ValueError('game')
    config=checked_fields(options)
    if config.pop('__native',None)!='1':raise ValueError('original_setup_required')
    if set(config)&IDENTITY:raise ValueError('setup_identity')
    return config

def result(d):
    # Interpret the original game's common completion marker, never calculate a win.
    marker=d.get('winner')
    if not marker:return dict(finished=False,winner=None,draw=False)
    token,sep,score=marker.rpartition('|')
    if not sep or token not in (d.get('player1'),d.get('player2')) or score not in ('-1','0','1'):raise ValueError('winner')
    actor=1 if token==d.get('player1') else 2
    return dict(finished=True,winner=None if score=='0' else actor if score=='1' else 3-actor,draw=score=='0')

def describe(d):
    return dict(game=d['game'],num=d['num'],kind='invitation' if 'start' in d else 'played-turn',
                board=None,move=None,avatars={str(i):d['avatar'+str(i)] for i in (1,2) if d.get('avatar'+str(i))},**result(d))
