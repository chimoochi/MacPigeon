"""Wire adapters for the original engines, traced from the supplied IPA.

These validate replay structure and session continuity, not replacement physics or
board-rule engines. OriginalHost owns gameplay and invitation generation.
"""
from dataclasses import dataclass
from .shared import integer, numeric_list, terminal_marker


def records(text, delimiter='|', maximum=2048):
    if not isinstance(text,str) or len(text)>65536:raise ValueError('replay_limit')
    parts=[p for p in text.split(delimiter) if p]
    if not 1<=len(parts)<=maximum:raise ValueError('replay_records')
    return parts


def numbers(text, counts=None, lo=-1000000, hi=1000000):
    pieces=text.split(',')
    if counts is not None and len(pieces) not in counts:raise ValueError('replay_width')
    values=numeric_list(text,len(pieces))
    if any(not lo<=v<=hi for v in values):raise ValueError('replay_range')
    return values


def ints(text, count=None, lo=0, hi=1000000):
    pieces=text.split(',')
    if count is not None and len(pieces)!=count:raise ValueError('replay_width')
    return [integer(v,lo,hi) for v in pieces]


def tagged(text, allowed, separator='&', pair=':'):
    result={}
    for raw in records(text,separator):
        key,sep,value=raw.partition(pair)
        if not sep or key not in allowed or key in result:raise ValueError('replay_key')
        result[key]=numeric_list(value,1)[0]
    return result


def parse_board(game,text):
    actions=[]
    for part in records(text):
        key,sep,value=part.partition(':')
        allowed={'checkers':{'board','move','attack'},'fill':{'board','move','attack'},'reversi':{'board','move','attack'},'dots':{'board','line','square'}}.get(game,{'board','move'})
        if not sep or key not in allowed:raise ValueError('board_action')
        if key=='board':
            if game=='mancala':
                pits=value.split('&')
                if len(pits)!=14:raise ValueError('mancala_pits')
                data=[ints(p.strip(','),lo=0,hi=13) if p.strip(',') else [] for p in pits]
                if sum(map(len,data))>256:raise ValueError('mancala_stones')
            elif game=='dots':
                data=[ints(p,count=5 if len(p.split(','))==5 else 3,lo=0,hi=6) for p in records(value,'#',256)] if value else []
            else:
                data=ints(value,lo=0,hi=99)
                if game in ('checkers','reversi') and len(data)!=64:raise ValueError('board_size')
                if game=='fill' and not 1<=len(data)<=1024:raise ValueError('board_size')
        elif game=='checkers':data=ints(value,4,0,7)
        elif game=='reversi':data=ints(value,3,0,7)
        elif game=='fill':data=integer(value,0,99)
        elif game=='mancala':data=ints(value,2,0,13)
        elif game=='dots':data=ints(value,5 if key=='line' else 3,0,6)
        else:raise ValueError('board_action')
        if game!='dots' and key in ('line','square'):raise ValueError('board_action')
        actions.append((key,data))
    if actions[0][0]!='board':raise ValueError('board_snapshot')
    return actions


def parse_physics(game,text):
    frames=[]
    for part in records(text):
        key,sep,value=part.partition(':')
        if not sep:raise ValueError('physics_action')
        if game=='paint':
            fields=tagged(part,{'hp1','hp2','pos1','pos2','target1','target2'},',')
            if set(fields)!={'hp1','hp2','pos1','pos2','target1','target2'}:raise ValueError('paint_snapshot')
            frames.append(('board',fields));continue
        if key=='board':
            if game=='tanks':
                data=tagged(value,{'height','wind','tank1x','tank1rot','tank1power','tank1hp','tank2x','tank2rot','tank2power','tank2hp'},'&',',')
                if len(data)!=10:raise ValueError('tank_snapshot')
            else:
                data=[numbers(v,{2,6} if game=='shuffle' else {1,6}) for v in records(value,'#',128)]
        elif key=='move' and game in ('shuffle','knock'):data=numbers(value,{5})
        elif key=='shoot':data=numbers(value) if value else []
        else:raise ValueError('physics_action')
        frames.append((key,data))
    if frames[0][0]!='board':raise ValueError('physics_snapshot')
    return frames


def parse_scoring(game,text):
    frames=[]
    if game=='basketball':
        return [numbers(part,{4}) for part in records(text)] if text else []
    if game=='beer':
        alphabet=set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789~!@*()_+-.';")
        for part in records(text):
            key,sep,value=part.partition(':')
            if not sep:raise ValueError('cup_action')
            if key=='board':
                sides=value.split('&')
                if len(sides)!=2:raise ValueError('cup_board')
                data=[ints(side.strip(','),lo=0,hi=9) if side.strip(',') else [] for side in sides]
                if any(len(side)>10 or len(side)!=len(set(side)) for side in data):raise ValueError('cup_board')
            elif key=='move':
                encoded,sep,sound=value.partition('&')
                if not sep or not encoded or len(encoded)%6 not in (0,1) or any(c not in alphabet for c in encoded):raise ValueError('cup_move')
                if len(encoded)%6 and encoded[-1] not in '0123456789':raise ValueError('cup_hit')
                data=(encoded,ints(sound.strip(','),lo=0,hi=1000000) if sound.strip(',') else [])
            elif key=='overtime':data=value
            else:raise ValueError('cup_action')
            frames.append((key,data))
        if frames[0][0]!='board':raise ValueError('cup_snapshot')
        return frames
    for part in records(text):
        key,sep,value=part.partition(':')
        if not sep or key not in ('state','move'):raise ValueError('score_action')
        count=(2 if game=='darts' else 5) if key=='state' else (6 if game=='darts' else 4)
        frames.append((key,numbers(value,{count})))
    return frames


def parse_questions(text):
    entries=[]
    for raw in records(text,'|][',20):
        pieces=raw.split('^&*')
        if len(pieces)!=3 or not pieces[0].strip() or len(pieces[0])>4096:raise ValueError('question_record')
        number=integer(pieces[1],0,20);answer=integer(pieces[2],0,4)
        entries.append((pieces[0],number,answer))
    if len({entry[1] for entry in entries})!=len(entries):raise ValueError('question_number')
    return entries


@dataclass(frozen=True)
class OriginalAdapter:
    game: str
    TITLE: str
    SCENE: str
    family: str
    EXTRA: frozenset
    IMMUTABLE: tuple = ('mode','size','seed')

    def validate_configuration(self,d):
        for key in ('seed','seed2'):
            if key in d:integer(d[key],-2147483648,4294967295)
        for key in ('style1','style2','v2','v3','v4','v5'):
            if key in d:integer(d[key],0,999999)
        if 'size' in d:integer(d['size'],1,32)
        modes={'checkers':{'n','h'},'mancala':{'n','h','an','ah'},'shuffle':{'1','2','3'},'knock':{'1','2','3'},'darts':{'101','301','501'},'beer':{'n','h'},'basketball':{'n','h'},'hunt':{'1','2','3','4'},'wordbites':{'1'}}
        if self.game in modes and 'mode' in d and d['mode'] not in modes[self.game]:raise ValueError(self.game+'_mode')
        if self.family=='words':
            letters=d.get('letters','')
            if (not letters and self.game!='wordbites') or len(letters)>256 or any(ord(c)<32 for c in letters):raise ValueError('word_letters')
            languages=('en','gp_en2') if self.game in ('hunt','wordbites') else ('en','ru','es','de','fr','it')
            if d.get('lang','en') not in languages:raise ValueError('word_language')
            if self.game=='wordbites':
                if not d.get('level') or len(d['level'])>16384:raise ValueError('word_level')
                for row in records(d['level'],'|',256):
                    parts=row.split('&')
                    if len(parts)>256:raise ValueError('word_level')
        if self.game=='questions':
            answer=d.get('answer','')
            if not answer.strip() or len(answer)>1024 or '\x00' in answer:raise ValueError('question_answer')

    def invitation_options(self,options):
        # Complex setup is generated by the original invitation factory, never guessed.
        defaults={'checkers':{'mode':'n'},'reversi':{},'fill':{},'dots':{'size':'4'},'renju':{},'darts':{'mode':'301'},'archery':{},'paint':{'style2':'0'},'beer':{'mode':'n'},'basketball':{'mode':'n'}}
        if self.game not in defaults:raise ValueError('original_setup_required')
        d=dict(defaults[self.game]);d.update({k:v for k,v in options.items() if k in self.EXTRA and k not in ('replay','replay2','replay3','replay4')})
        if self.game in ('fill','archery','beer','basketball'):
            import secrets
            d.setdefault('seed',str(secrets.randbits(32)))
        if self.game=='basketball':
            import secrets
            d.update(seed2=str(secrets.randbits(32)),round='1',score1='0',score2='0',skip_score1='0',skip_score2='0')
        self.validate_configuration(d);return d

    def validate_invitation(self,d):
        if self.game in ('mancala','tanks','knock'):
            self.parse(d.get('replay',''))
        if self.game=='shuffle' and not d.get('map'):raise ValueError('shuffle_map')

    def parse(self,text):
        if self.family=='board':return parse_board(self.game,text)
        if self.family=='physics':return parse_physics(self.game,text)
        if self.family=='scoring':return parse_scoring(self.game,text)
        raise ValueError('replay_family')

    def inspect_turn(self,d,result):
        if self.game=='renju':
            raw=d.get('map','')
            if len(raw)!=169 or any(c not in '012' for c in raw):raise ValueError('gomoku_board')
            board=list(map(int,raw));move=ints(d.get('move',''),3,0,12)
            if move[2] not in (1,2):raise ValueError('gomoku_actor')
            y,x,color=move
            if board[y*13+x]!=0:raise ValueError('gomoku_occupied')
            board[y*13+x]=color
            result['position']=board;result['placement']=move
        elif self.family=='words':
            for actor in (1,2):
                if 'score'+str(actor) in d:integer(d['score'+str(actor)],0,1000000)
                if 'words'+str(actor) in d:integer(d['words'+str(actor)],0,10000)
                if len(d.get('words_list'+str(actor),''))>65536:raise ValueError('word_list')
            if 'score1' not in d and 'score2' not in d:raise ValueError('word_score')
        elif self.game=='questions':
            result['questions']=parse_questions(d.get('questions',''))
        else:
            replays=[d[k] for k in ('replay','replay2','replay3','replay4') if k in d and (d[k] or self.game=='basketball')]
            if not replays:raise ValueError('replay_missing')
            for text in replays:self.parse(text)
            result['frames']=sum(len(self.parse(text)) for text in replays)
        return result

    def validate_transition(self,before,after,decoded):
        if self.game=='renju' and 'start' not in before:
            previous=self.inspect_turn(before,{})['position']
            if after['map']!=''.join(map(str,previous)):raise ValueError('gomoku_snapshot_changed')
        if self.family=='words':
            actor=after['player'];other=str(3-int(actor))
            for prefix in ('score','words','words_list'):
                key=prefix+other
                if before.get(key) is not None and after.get(key)!=before[key]:raise ValueError('opponent_score_changed')
            if 'score'+actor not in after:raise ValueError('word_score')
        if self.game=='questions':
            previous=parse_questions(before['questions']) if before.get('questions') else []
            current=decoded['questions']
            if len(current)<len(previous):raise ValueError('question_history')
            for old,new in zip(previous,current):
                if old[:2]!=new[:2] or (old[2]!=0 and old[2]!=new[2]):raise ValueError('question_history')
            if after['player']=='1':
                if len(current)<=len(previous) or any(entry[2] for entry in current[len(previous):]):raise ValueError('question_actor')
            elif len(current)!=len(previous) or current==previous:raise ValueError('question_actor')

    def result(self,d,decoded):
        if self.game=='questions':
            entries=decoded['questions']
            if any(entry[2]==4 for entry in entries):return dict(finished=True,winner=1,draw=False)
            if len(entries)==20 and all(entry[2] for entry in entries):return dict(finished=True,winner=2,draw=False)
        if self.family=='words' and 'score1' in d and 'score2' in d:
            a,b=int(d['score1']),int(d['score2'])
            return dict(finished=True,winner=1 if a>b else 2 if b>a else None,draw=a==b)
        return terminal_marker(d)


STYLE={'style1','style2'}
SCORE={'map','mode','seed','seed2','round','score1','score2','skip_score1','skip_score2','v2','replay','replay2','replay3','replay4'}|STYLE
WORDS={'lang','mode','letters','level','score1','score2','words1','words2','words_list1','words_list2'}

def adapter(game,title,scene,family,extra,immutable=('mode','size','seed')):
    return OriginalAdapter(game,title,scene,family,frozenset(extra),immutable)

ADAPTERS={
 'renju':adapter('renju','Gomoku','RenjuScene','placement',{'map','move'},()),
 'reversi':adapter('reversi','Reversi','ReversiScene','board',{'size','mode','replay'}),
 'fill':adapter('fill','Filler','FillScene','board',{'size','mode','seed','replay'}),
 'dots':adapter('dots','Dots & Boxes','DotsScene','board',{'size','replay'}),
 'mancala':adapter('mancala','Mancala','MancalaScene','board',{'size','mode','replay'}|STYLE),
 'checkers':adapter('checkers','Checkers','CheckersScene','board',{'size','mode','replay'}),
 'darts':adapter('darts','Darts','DartsScene','scoring',{'mode','replay'}|STYLE),
 'archery':adapter('archery','Archery','ArcheryScene','scoring',{'seed','replay'}),
 'beer':adapter('beer','Cup Pong','BeerScene','scoring',SCORE),
 'basketball':adapter('basketball','Basketball','BasketballScene','scoring',SCORE),
 'shuffle':adapter('shuffle','Shuffleboard','ShuffleScene','physics',{'map','mode','replay'},('map','mode')),
 'knock':adapter('knock','Knockout','KnockScene','physics',{'mode','replay'}),
 'tanks':adapter('tanks','Tanks','TanksScene','physics',{'replay'}),
 'paint':adapter('paint','Paintball','PaintScene','physics',{'replay'}|STYLE),
 'anagrams':adapter('anagrams','Anagrams','AnagramsScene','words',WORDS,('lang','letters')),
 'hunt':adapter('hunt','Word Hunt','HuntScene','words',WORDS,('lang','letters','mode')),
 'wordbites':adapter('wordbites','Word Bites','HuntScene','words',WORDS,('lang','letters','level','mode')),
 'questions':adapter('questions','20 Questions','QuestionsScene','questions',{'answer','questions'},('answer',)),
}
