"""Sea Battle wire snapshots and shots; the original engine owns gameplay."""
from .shared import integer, terminal_marker

TITLE = 'Sea Battle'
SCENE = 'SeaScene'
EXTRA = {'size', 'mode', 'ships1', 'ships2', 'bullets1', 'bullets2',
         'skip_ships', 'skip_bullets', 'replay', 'style1', 'style2'}
IMMUTABLE = ('size', 'mode')
MAPS = {'1': ('10', '1,2,3,4', '5'), '2': ('9', '3,5,0,0', '6'),
        '3': ('8', '1,3,3,0', '19'), '4': ('7', '2,0,4,0', '7')}


def configuration(d):
    size = d.get('size', '10')
    mode = d.get('mode', '1,2,3,4')
    if (size, mode) not in {(s, m) for s, m, _ in MAPS.values()}:
        raise ValueError('sea_configuration')
    return int(size)


def ships(text, size):
    if not isinstance(text, str) or not text or len(text) > 8192:
        raise ValueError('sea_ships')
    result = []
    for record in text.split('|'):
        values = {}
        for field in record.split('&'):
            key, sep, value = field.partition(':')
            if not sep or key not in {'pos', 'num', 'rot'} or key in values:
                raise ValueError('sea_ship_field')
            values[key] = value
        if set(values) != {'pos', 'num', 'rot'}:
            raise ValueError('sea_ship_field')
        pos = tuple(integer(v, 0, size - 1) for v in values['pos'].split(','))
        hits = tuple(integer(v, 0, 1) for v in values['num'].split(','))
        rotation = integer(values['rot'], 0, 3)
        if len(pos) != 2 or not 1 <= len(hits) <= 4:
            raise ValueError('sea_ship_width')
        result.append((pos, rotation, hits))
    if not 1 <= len(result) <= 20:
        raise ValueError('sea_fleet_size')
    return result


def bullets(text, size):
    values = tuple(integer(v, 0, 1) for v in text.split(','))
    if len(values) != size * size:
        raise ValueError('sea_bullets_size')
    return values


def shots(text, size):
    if not isinstance(text, str) or len(text) > 4096:
        raise ValueError('sea_replay_limit')
    if not text:
        return []
    result = [tuple(integer(v, 0, size - 1) for v in part.split(','))
              for part in text.split('|')]
    if len(result) > size * size or any(len(p) != 2 for p in result) or len(set(result)) != len(result):
        raise ValueError('sea_shots')
    return result


def validate_configuration(d):
    size = configuration(d)
    for key in ('style1', 'style2'):
        if key in d:
            integer(d[key], 0, 999999)
    for key in ('ships1', 'ships2', 'skip_ships'):
        if key in d:
            ships(d[key], size)
    for key in ('bullets1', 'bullets2', 'skip_bullets'):
        if key in d:
            bullets(d[key], size)
    if 'replay' in d:
        shots(d['replay'], size)


def invitation_options(options):
    selection = options.get('map', '1')
    if selection not in MAPS:
        raise ValueError('sea_map')
    size, mode, version = MAPS[selection]
    d = dict(size=size, mode=mode, version=version)
    for key in ('size', 'mode'):
        if key in options:
            d[key] = options[key]
    validate_configuration(d)
    return d


def validate_invitation(d):
    if any(key in d for key in EXTRA - {'size', 'mode', 'style1', 'style2'}):
        raise ValueError('sea_invitation_state')


def inspect_turn(d, decoded):
    size = configuration(d)
    if not any(key in d for key in ('ships1', 'ships2')):
        raise ValueError('sea_fleet_missing')
    for actor in (1, 2):
        if ('ships' + str(actor) in d) != ('bullets' + str(actor) in d):
            raise ValueError('sea_snapshot_pair')
    decoded['shots'] = shots(d.get('replay', ''), size)
    if decoded['shots'] and not all(key in d for key in ('ships1', 'ships2', 'skip_ships', 'skip_bullets')):
        raise ValueError('sea_shot_snapshot')
    return decoded


def validate_transition(before, after, decoded):
    # Incoming replay can update hit masks. Established ship positions stay fixed.
    size = configuration(after)
    for key in ('ships1', 'ships2'):
        if key in before:
            old = ships(before[key], size)
            new = ships(after.get(key, ''), size)
            if [(p, r, len(h)) for p, r, h in old] != [(p, r, len(h)) for p, r, h in new]:
                raise ValueError('sea_fleet_changed')
            if any(a > b for (_, _, h1), (_, _, h2) in zip(old, new) for a, b in zip(h1, h2)):
                raise ValueError('sea_hit_removed')
    for key in ('bullets1', 'bullets2'):
        if key in before and any(a > b for a, b in zip(bullets(before[key], size), bullets(after.get(key, ''), size))):
            raise ValueError('sea_bullet_removed')


def result(d, decoded):
    # skip_ships is the target fleet after replay; ships1/2 are before replay.
    if decoded.get('shots') and 'skip_ships' in d:
        fleet = ships(d['skip_ships'], configuration(d))
        if all(all(hits) for _, _, hits in fleet):
            return dict(finished=True, winner=int(d['player']), draw=False)
    return terminal_marker(d)
