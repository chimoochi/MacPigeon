"""Private helper: decode one authorized game URL; emit only board fields."""
import json
import sys
from connect_codec import inspect_url


def main():
    data=sys.stdin.buffer.readline(262145)
    if len(data)>262144:
        raise ValueError('input_limit')
    obj=json.loads(data)
    url=obj.get('url')
    if not isinstance(url,str) or len(url)>131072:
        raise ValueError('url_schema')
    parsed=inspect_url(url)
    if parsed.get('game')!='connect':
        raise ValueError('game_mismatch')
    fields={k:parsed.get(k) for k in ['game','board','move','num','kind']}
    fields['kind']='played-turn'
    if isinstance(fields['move'],tuple):
        fields['move']=list(fields['move'])
    board=fields['board'];move=fields['move']
    if not isinstance(board,list) or len(board)!=42 or any(type(x)!=int or x not in range(3) for x in board):
        raise ValueError('board_schema')
    if not isinstance(move,list) or len(move)!=3 or any(type(x)!=int for x in move):
        raise ValueError('move_schema')
    if not parsed.get('gravity_valid'):
        raise ValueError('gravity_schema')
    print(json.dumps({'ok':True,'sanitized_game':fields},separators=(',',':')))


if __name__=='__main__':
    try:
        main()
    except Exception:
        print(json.dumps({'ok':False,'stage':'selected_game_decode_failed'}))
        sys.exit(2)
