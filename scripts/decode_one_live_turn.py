"""Read common metadata for an authorized URL; replay stays in the original game."""
import json,sys
from game_messages import fields,describe
try:
    data=sys.stdin.buffer.readline(262145)
    if len(data)>262144:raise ValueError('input_limit')
    parsed=describe(fields(json.loads(data)['url']))
    print(json.dumps(dict(ok=True,sanitized_game=parsed),separators=(',',':')))
except Exception:
    print('{"ok":false,"stage":"selected_game_decode_failed"}');sys.exit(2)
