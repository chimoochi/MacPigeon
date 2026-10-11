"""Distinct pool scenes share the original replay grammar."""
from dataclasses import dataclass
from . import pool

@dataclass(frozen=True)
class PoolVariant:
    TITLE:str
    SCENE:str
    EXTRA=frozenset(pool.EXTRA)
    IMMUTABLE=pool.IMMUTABLE
    def validate_configuration(self,d):pool.validate_configuration(d)
    def inspect_turn(self,d,result):
        result['frames']=len(pool.parse_replay(d.get('replay',''),eight_ball_plus=self.SCENE=='PoolScene3'))
        return result
    def validate_transition(self,before,after,decoded):pool.validate_transition(before,after,decoded)
    def result(self,d,decoded):return pool.result(d,decoded)
    def invitation_options(self,options):
        d=pool.invitation_options(options)
        d.update(v2='2' if self.SCENE=='PoolScene3' else '1',v3='2' if self.SCENE=='PoolScene3' else '1',v4='2',v5='2')
        if self.SCENE=='PoolScene2':d['version']='11'
        return d

NINE_BALL=PoolVariant('9 Ball','PoolScene2')
EIGHT_BALL_PLUS=PoolVariant('8 Ball+','PoolScene3')
