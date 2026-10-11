"""Registry and common envelope checks for the per-game adapters.

Game modules own options, replay formats, transitions and result interpretation.
Session identity, message order and transport remain in game_session/new_games.
"""
import re
from connect_codec import query_items, unwrap
from game_modes import connect, chess, pool, golf, sea, crazy
from game_modes.original_games import ADAPTERS as ORIGINAL_ADAPTERS
from game_modes.shared import integer, terminal_marker

ADAPTERS = {'connect': connect, 'chess': chess, 'pool': pool, 'golf': golf, 'sea': sea, 'crazy': crazy}
ADAPTERS.update(ORIGINAL_ADAPTERS)
from game_modes.pool_variants import NINE_BALL, EIGHT_BALL_PLUS
ADAPTERS.update(pool2=NINE_BALL,pool3=EIGHT_BALL_PLUS)
GAMES = {key: (adapter.TITLE, adapter.SCENE) for key, adapter in ADAPTERS.items()}
REALTIME_GAMES = frozenset(key for key, adapter in ADAPTERS.items() if getattr(adapter, 'REALTIME', False))
COMMON = {'id', 'game', 'player', 'player1', 'player2', 'sender', 'avatar1', 'avatar2',
          'num', 'version', 'tver', 'ios', 'caption', 'game_name', 'build', 'ver', 'winner', 'start'}
EXTRA = {key: adapter.EXTRA for key, adapter in ADAPTERS.items()}
IMMUTABLE = {key: adapter.IMMUTABLE for key, adapter in ADAPTERS.items()}

def get(game):
    try:
        return ADAPTERS[game]
    except (KeyError, TypeError):
        raise ValueError('game') from None

def invitation_options(game,options):
    if not isinstance(options,dict) or len(options)>48 or any(not isinstance(k,str) or not isinstance(v,str) or len(v)>65536 for k,v in options.items()):raise ValueError('invitation_options')
    adapter=get(game)
    if options.get('__native')=='1':
        config={k:v for k,v in options.items() if k!='__native'}
        if set(config)-(EXTRA[game]|{'version','tver','ios','build','ver'}):raise ValueError('invitation_field')
        adapter.validate_configuration(config)
        if hasattr(adapter,'validate_invitation'):adapter.validate_invitation(config)
        return config
    return adapter.invitation_options(options)

def fields(url):
    pairs=query_items(unwrap(url));d=dict(pairs)
    if len(d)!=len(pairs):raise ValueError('duplicate_fields')
    if d.get('game') not in GAMES:raise ValueError('game')
    if any(not isinstance(v,str) for v in d.values()):raise ValueError('field_value')
    if not re.fullmatch(r'[1-9]\d{0,8}',d.get('num','')):raise ValueError('ordinal')
    return d

def inspect(d):
    adapter = get(d['game'])
    avatars = {str(i): d['avatar' + str(i)] for i in (1, 2) if d.get('avatar' + str(i))}
    decoded = {'game': d['game'], 'num': d['num'], 'avatars': avatars,
               'kind': 'played-turn', 'board': None, 'move': None}
    if any(len(v) > 16384 for v in avatars.values()):
        raise ValueError('avatar')
    adapter.validate_configuration(d)
    if 'start' in d:
        initial_replay=hasattr(adapter,'validate_invitation')
        if d['num'] != '1' or d.get('player') != '2' or d.get('sender') != d.get('player2') or not d.get('player2') or d.get('player1') or (not initial_replay and (d.get('replay') or d.get('replay2'))):
            raise ValueError('invitation')
        if initial_replay:adapter.validate_invitation(d)
        decoded['kind'] = 'invitation'
        return decoded
    return adapter.inspect_turn(d, decoded)

def same_configuration(before,after):
    if before['game']!=after['game']:raise ValueError('game_changed')
    for key in IMMUTABLE[before['game']]:
        if key in before and key in after:
            a,b=before[key],after[key]
            if key=='seed':a,b=integer(a,-2147483648,4294967295)%4294967296,integer(b,-2147483648,4294967295)%4294967296
            if key=='lang' and before['game'] in ('hunt','wordbites'):
                a='en' if a=='gp_en2' else a;b='en' if b=='gp_en2' else b
            if a!=b:raise ValueError('configuration_changed')

def transition(before, after):
    same_configuration(before, after)
    decoded = inspect(after)
    if decoded['kind'] != 'played-turn':
        raise ValueError('invitation_transition')
    get(before['game']).validate_transition(before, after, decoded)
    return decoded

def result(d, decoded):
    if decoded['kind'] == 'invitation':
        return dict(finished=False, winner=None, draw=False)
    return get(d['game']).result(d, decoded)

# Compatibility for existing callers; new game-specific code imports its module.
chess_replay = chess.parse_replay
pool_replay = pool.parse_replay
golf_replay = golf.parse_replay
terminal = terminal_marker
