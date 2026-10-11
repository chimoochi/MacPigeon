"""Shared game URL codec; no transport or message access.

Derived from the inspected extension and checked against native game captures.
Query items remain ordered pairs to preserve unknown fields and duplicates.
"""
from dataclasses import dataclass
import json
import re
import sys
from urllib.parse import unquote, urlsplit

MAX_UNITS = 131072  # Match the imported game URL bound, including encoded replays.


def units(text):
    raw = text.encode('utf-16-le', 'surrogatepass')
    if len(raw) // 2 > MAX_UNITS:
        raise ValueError('Input exceeds offline inspection limit')
    return [int.from_bytes(raw[i:i+2], 'little') for i in range(0, len(raw), 2)]


def string(values):
    return b''.join(v.to_bytes(2, 'little') for v in values).decode('utf-16-le', 'surrogatepass')


def shuffle_indices(count):
    state = (((239 * count) & 0xffffffff) << 16) | 0x330e
    for remaining in range(count, 0, -1):
        state = (0x5deece66d * state + 0xb) & ((1 << 48) - 1)
        yield (state * remaining) // (1 << 48)


def transform(text, *, modern=True, decode=False):
    data = units(text)
    if not modern:
        direction = -1 if decode else 1
        return string([(v + direction * ((43+i) % 31 + (11+i) % 26)) & 0xffff
                       for i, v in enumerate(data)])
    indices = list(shuffle_indices(len(data)))
    result = []
    if decode:
        for i in range(len(data)-1, -1, -1):
            result.insert(indices[i], data[i])
    else:
        for index in indices:
            result.append(data.pop(index))
    return string(result)


def query_items(url):
    # Foundation query items treat '+' literally, unlike form-urlencoded parsers.
    units(url)
    query = urlsplit(url).query
    if not query:
        return []
    items = []
    for part in query.split('&'):
        key, sep, value = part.partition('=')
        items.append((unquote(key, errors='strict'), unquote(value, errors='strict') if sep else None))
    return items


def objc_int(text):
    # Relevant NSString intValue prefix behavior for the outer version selector.
    match = re.match(r'\s*([+-]?\d+)', text or '')
    return int(match[1]) if match else 0


def unwrap(url):
    outer = dict(query_items(url))
    if 'data' not in outer:
        return url
    if outer['data'] is None:
        raise ValueError('Missing envelope data value')
    version = outer.get('ver')
    inner = transform(outer['data'], modern=objc_int(version) != 0, decode=True)
    if version is not None:
        inner += '&ver=' + version
    return inner


@dataclass(frozen=True)
class Replay:
    board: tuple[int, ...]  # row zero first, seven columns per row
    move: tuple[int, int, int] | None

    def __post_init__(self):
        if len(self.board) != 42 or any(v not in (0, 1, 2) for v in self.board):
            raise ValueError('Expected 42 board cells with values 0, 1 or 2')
        if self.move is not None:
            x, y, player = self.move
            if not (0 <= x < 7 and 0 <= y < 6 and player in (1, 2)):
                raise ValueError('Invalid move coordinates or player')
            if self.board[y * 7 + x] != 0:
                raise ValueError('Newest move must be absent from board snapshot')

    def encode(self):
        text = 'board:' + ','.join(map(str, self.board))
        if self.move is not None:
            text += '|move:' + ','.join(map(str, self.move))
        return text

    def applied(self):
        board = list(self.board)
        if self.move is not None:
            x, y, player = self.move
            board[y * 7 + x] = player
        return tuple(board)

    def gravity_valid(self):
        # touchDown scans y=0 upward and chooses the first unoccupied cell.
        board = self.applied()
        for x in range(7):
            empty = False
            for y in range(6):
                if board[y * 7 + x] == 0:
                    empty = True
                elif empty:
                    return False
        return True


def parse_replay(text):
    units(text)
    fields = {}
    for part in text.split('|'):
        name, sep, value = part.partition(':')
        if not sep or name in fields or name not in ('board', 'move'):
            raise ValueError('Unsupported or duplicate replay field')
        if not re.fullmatch(r'-?\d+(,-?\d+)*', value):
            raise ValueError('Invalid replay integer list')
        fields[name] = tuple(map(int, value.split(',')))
    if 'board' not in fields or ('move' in fields and len(fields['move']) != 3):
        raise ValueError('Missing board or invalid move length')
    return Replay(fields['board'], fields.get('move'))


def inspect_url(url):
    items = query_items(unwrap(url))
    fields = dict(items)
    if fields.get('game') != 'connect':
        raise ValueError('This offline decoder accepts game=connect only')
    replay = parse_replay(fields['replay']) if fields.get('replay') else None
    # Identity fields are deliberately omitted from the display.
    return {'game': 'connect', 'num': fields.get('num'), 'size': fields.get('size'),
            'field_names': [k for k, _ in items],
            'board': list(replay.applied()) if replay else None,
            'move': replay.move if replay else None,
            'gravity_valid': replay.gravity_valid() if replay else None}


if __name__ == '__main__':
    # Read an explicitly supplied URL from stdin; never query Messages or phone.
    print(json.dumps(inspect_url(sys.stdin.read().strip()), indent=2))
