"""Chess snapshots and move records; the original engine owns move legality."""
from .shared import integer, terminal_marker

TITLE = 'Chess'
SCENE = 'ChessScene'
EXTRA = {'size', 'mode', 'replay'}
IMMUTABLE = ('size', 'mode')

def parse_replay(text):
    actions=[];snapshot=None
    for part in text.split('|'):
        key,sep,value=part.partition(':')
        if not sep:raise ValueError('chess_replay')
        if key=='board':
            cells=[integer(v,0,26) for v in value.split(',')]
            if len(cells)!=64 or any(v and v not in {*range(11,17),*range(21,27)} for v in cells):raise ValueError('chess_board')
            if snapshot is None:snapshot=cells
            actions.append((key,cells))
        elif key in ('move','attack'):
            move=[integer(v,0,7) for v in value.split(',')]
            if len(move)!=4 or move[:2]==move[2:]:raise ValueError('chess_move')
            actions.append((key,move))
        else:raise ValueError('chess_action')
    if snapshot is None or actions[0][0]!='board' or not 1<=len(actions)<=16:raise ValueError('chess_snapshot')
    # Preserve authoritative post-move snapshots (promotion/castling), where supplied.
    cells=list(snapshot);last=None
    for key,value in actions[1:]:
        if key=='board':cells=list(value)
        else:
            ox,oy,x,y=value;origin=oy*8+ox;target=y*8+x
            if not cells[origin]:raise ValueError('chess_origin')
            cells[target]=cells[origin];cells[origin]=0;last=value
    return {'snapshot':snapshot,'board':cells,'move':last,'actions':actions}

def validate_configuration(d):
    if d.get('mode', 'n') != 'n':
        raise ValueError('chess_mode')

def inspect_turn(d, result):
    replay = parse_replay(d.get('replay', ''))
    result.update(board=replay['board'], move=replay['move'])
    return result

def validate_transition(before, after, decoded):
    replay = parse_replay(after['replay'])
    if 'start' not in before and replay['snapshot'] != parse_replay(before['replay'])['board']:
        raise ValueError('chess_snapshot_changed')
    moves = [v for k, v in replay['actions'] if k in ('move', 'attack')]
    if not 1 <= len(moves) <= 3:
        raise ValueError('chess_move_count')
    ox, oy, _, _ = moves[0]
    if replay['snapshot'][oy * 8 + ox] // 10 != int(after['player']):
        raise ValueError('chess_actor')

def invitation_options(options):
    return {}

def result(d, decoded):
    return terminal_marker(d)
