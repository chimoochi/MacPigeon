"""Mini Golf run records and opponent-run preservation; original physics is reused."""
import secrets
from .shared import integer, numeric_list, terminal_marker

TITLE = 'Mini Golf'
SCENE = 'GolfScene'
EXTRA = {'size', 'map', 'mode', 'seed', 'v2', 'v3', 'replay', 'replay2'}
IMMUTABLE = ('mode', 'seed')

def parse_replay(text,mode):
    # Standard holes record direction and power. Race records ball snapshots.
    width=4 if mode=='race' else 2
    holes=[]
    for raw in text.split('|'):
        shots=[numeric_list(v,width) for v in raw.split('&')]
        if not 1<=len(shots)<=256:raise ValueError('golf_shots')
        holes.append(shots)
    if not 1<=len(holes)<= (256 if mode=='race' else int(mode)):raise ValueError('golf_holes')
    return holes

def validate_configuration(d):
    if d.get('mode', '3') not in ('3', '5', 'race'):
        raise ValueError('golf_mode')
    if 'seed' in d:
        integer(d['seed'], -2147483648, 4294967295)

def inspect_turn(d, result):
    if not any(d.get(k) for k in ('replay', 'replay2')):
        raise ValueError('golf_replay')
    for key in ('replay', 'replay2'):
        if d.get(key):
            parse_replay(d[key], d.get('mode', '3'))
    return result

def validate_transition(before, after, decoded):
    if after.get('mode', '3') != 'race':
        other = 'replay2' if after['player'] == '1' else 'replay'
        if before.get(other) and after.get(other) != before[other]:
            raise ValueError('golf_opponent_replay_changed')

def invitation_options(options):
    mode = options.get('size', options.get('mode', '3'))
    if mode not in ('3', '5', 'race'):
        raise ValueError('golf_mode')
    return {'mode': mode, 'seed': str(secrets.randbits(32)), 'v3': '3', 'version': '41'}

def result(d, decoded):
    return terminal_marker(d)
