"""Standard 8 Ball shot controls and ball snapshots; original physics is reused."""
import secrets
from .shared import integer, numeric_list, terminal_marker

TITLE = '8 Ball'
SCENE = 'PoolScene'
EXTRA = {'mode', 'seed', 'v2', 'v3', 'v4', 'v5', 'style1', 'style2', 'replay'}
IMMUTABLE = ('mode', 'seed')

def parse_replay(text, *, eight_ball_plus=False):
    frames=[]
    for part in text.split('|'):
        frame={}
        for piece in part.strip('&').split('&'):
            key,sep,value=piece.partition(':')
            aliases={'pocket':'o','dir':'d','spin_x':'x','spin_y':'y','power':'p'}
            key=aliases.get(key,key)
            if not sep or key in frame or key not in ('balls','stripes','move','win','d','x','y','p','s','o','setup'):raise ValueError('pool_replay')
            if key=='balls':
                balls=[];ids={}
                for raw in value.strip('#').split('#'):
                    count=len(raw.split(','))
                    if count not in (6,8):raise ValueError('pool_ball')
                    ball=numeric_list(raw,count);number=integer(raw.split(',')[4],0,15)
                    # PoolScene3 sends 30 balls: two of each colored number,
                    # plus one cue ball (0) and one black ball (8).
                    limit=2 if eight_ball_plus and number not in (0,8) else 1
                    ids[number]=ids.get(number,0)+1
                    if ids[number]>limit:raise ValueError('pool_duplicate_ball')
                    balls.append(ball)
                if not 1<=len(balls)<=(30 if eight_ball_plus else 16):raise ValueError('pool_balls')
                frame[key]=balls
            # Original PoolScene.playReplay accepts both names for the called pocket.
            elif key=='o':frame[key]=integer(value,0,5)
            elif key=='setup':frame[key]=integer(value,0,999999)
            elif key in ('d','x','y','p'):frame[key]=numeric_list(value,1)[0]
            else:frame[key]=integer(value,-1 if key=='win' else 0,2 if key in ('stripes','s') else 1)
        # Original replay permits shot-only entries between ball snapshots.
        if 'balls' not in frame and not {'d','x','y','p','s'}<=frame.keys():raise ValueError('pool_snapshot')
        if any(k in frame for k in ('d','x','y','p','s')) and not {'d','x','y','p','s'}<=frame.keys():raise ValueError('pool_shot')
        frames.append(frame)
    if not 1<=len(frames)<=256:raise ValueError('pool_frames')
    if 'balls' not in frames[0] or 'balls' not in frames[-1]:raise ValueError('pool_snapshot')
    return frames

def validate_configuration(d):
    if d.get('mode', 'n') not in ('n', 'h'):
        raise ValueError('pool_mode')
    if 'seed' in d:
        integer(d['seed'], -2147483648, 4294967295)

def inspect_turn(d, result):
    result['frames'] = len(parse_replay(d.get('replay', '')))
    return result

def validate_transition(before, after, decoded):
    # Replay structure was checked by inspect_turn; no replacement physics engine.
    pass

def invitation_options(options):
    mode = options.get('mode', 'n')
    if mode not in ('n', 'h') or options.get('game', 'n') not in ('n', ''):
        raise ValueError('pool_variant')
    return {'mode': mode, 'seed': str(secrets.randbits(32))}

def result(d, decoded):
    return terminal_marker(d)
