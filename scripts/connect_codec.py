"""Shared game URL codec; no transport or message access.

Derived from the inspected extension and checked against native game captures.
Query items remain ordered pairs to preserve unknown fields and duplicates.
"""
import re
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
