"""Bounded value parsing and the shared GamePigeon result marker."""
import math
import re

def integer(v,lo,hi):
    if not isinstance(v,str) or not re.fullmatch(r'-?\d{1,10}',v):raise ValueError('integer')
    n=int(v)
    if not lo<=n<=hi:raise ValueError('integer_range')
    return n

def numeric_list(value,count):
    v=value.split(',')
    if len(v)!=count:raise ValueError('numeric_count')
    try:n=[float(x) for x in v]
    except ValueError:raise ValueError('numeric_value')
    if any(not math.isfinite(x) or abs(x)>1000000 for x in n):raise ValueError('numeric_range')
    return n

def terminal_marker(d):
    marker=d.get('winner')
    if not marker:return dict(finished=False,winner=None,draw=False)
    token,sep,score=marker.rpartition('|')
    if not sep or token not in (d.get('player1'),d.get('player2')) or score not in ('-1','0','1'):raise ValueError('winner')
    actor=1 if token==d.get('player1') else 2
    return dict(finished=True,winner=None if score=='0' else actor if score=='1' else 3-actor,draw=score=='0')
