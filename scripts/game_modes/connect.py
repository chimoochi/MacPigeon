"""Four in a Row: independent gravity, drop, transition and win checks."""
from urllib.parse import urlencode
from connect_codec import Replay, inspect_url

def outcome(cells):
    winners=set()
    for y in range(6):
        for x in range(7):
            p=cells[y*7+x]
            if p and any(all(0<=x+i*dx<7 and 0<=y+i*dy<6 and cells[(y+i*dy)*7+x+i*dx]==p for i in range(1,4)) for dx,dy in ((1,0),(0,1),(1,1),(1,-1))):winners.add(p)
    if len(winners)>1:raise ValueError('multiple_winners')
    winner=next(iter(winners),None)
    return {'finished':winner is not None or 0 not in cells,'winner':winner,'draw':winner is None and 0 not in cells}

TITLE = 'Four in a Row'
SCENE = 'ConnectScene'
EXTRA = {'size', 'replay'}
IMMUTABLE = ('size',)

def validate_configuration(d):
    if d.get('size', '4') != '4':
        raise ValueError('connect_size')

def inspect_turn(d, result):
    decoded = inspect_url('?' + urlencode(d))
    cells = decoded['board']
    if not decoded.get('gravity_valid') or not isinstance(cells, list) or len(cells) != 42 or any(type(p) != int or p not in (0, 1, 2) for p in cells):
        raise ValueError('board')
    move = list(decoded['move'])
    if len(move) != 3 or any(type(p) != int for p in move) or not 0 <= move[0] < 7 or not 0 <= move[1] < 6 or move[2] not in (1, 2) or cells[move[1] * 7 + move[0]] != move[2]:
        raise ValueError('move')
    result.update(board=cells, move=move, num=str(int(decoded['num'])))
    return result

def validate_transition(before, after, decoded):
    if 'start' in before:
        if decoded['move'][1] != 0 or decoded['move'][2] != 1 or sum(v != 0 for v in decoded['board']) != 1:
            raise ValueError('first_move')
        return
    previous = inspect_turn(before, {})['board']
    differences = [i for i, (a, b) in enumerate(zip(previous, decoded['board'])) if a != b]
    move = decoded['move']
    actor = int(after['player'])
    if differences != [move[1] * 7 + move[0]] or previous[differences[0]] != 0 or decoded['board'][differences[0]] != actor or move[2] != actor:
        raise ValueError('illegal_transition')

def invitation_options(options):
    if options.get('size', '4') != '4':
        raise ValueError('connect_size')
    return {}

def result(d, decoded):
    if decoded['move'][2] != int(d['player']):
        raise ValueError('actor_move')
    return outcome(decoded['board'])

def drop(decoded, column, actor):
    if type(column) != int or not 0 <= column < 7:
        raise ValueError('column')
    cells = decoded['board'] if decoded['kind'] != 'invitation' else [0] * 42
    if outcome(cells)['winner'] is not None:
        raise ValueError('finished')
    row = next((y for y in range(6) if cells[y * 7 + column] == 0), None)
    if row is None:
        raise ValueError('full')
    return Replay(tuple(cells), (column, row, actor))

def native_column(output):
    move = output.get('replay', '').rsplit('|move:', 1)[-1].split(',')
    if len(move) != 3:
        raise ValueError('move')
    return int(move[0])
