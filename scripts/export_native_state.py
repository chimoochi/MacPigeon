import json,sys,hashlib
from game_session import load,fields
from connect_codec import unwrap
from sync_selected_game import synchronize
import game_adapters as adapters
try:
 sync=synchronize() if "--sync" in sys.argv else {"status":"deferred"}
 s=load();own=fields(s['own_url']);url=unwrap(s['url'])
 print(json.dumps({'game':s['board']['game'],'realtime':s['board']['game'] in adapters.REALTIME_GAMES,'kind':s['board']['kind'],'url':url,'recipient':s['recipient'],'own_id':s['own_id'],'own_player':s['own_player'],'num':int(s['board']['num']),'finished':s['finished'],'winner':s['winner'],'draw':s['draw'],'revision':hashlib.sha256(s['url'].encode()).hexdigest(),'sync_status':sync['status'],'sync_stage':sync.get('stage')}))
except Exception:
 print('{}');sys.exit(2)
