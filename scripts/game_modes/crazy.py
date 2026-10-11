"""Crazy 8 room invitations. Gameplay runs in the original live room engine."""
import re
import secrets
import uuid
from .shared import terminal_marker

TITLE = 'Crazy 8'
SCENE = 'CrazyScene'
EXTRA = {'room'}
IMMUTABLE = ('room',)
REALTIME = True


def validate_configuration(d):
    # Original factory: conversation participant UUID plus eight random characters.
    room = d.get('room', '')
    if not re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[A-Za-z0-9]{8}', room):
        raise ValueError('crazy_room')


def invitation_options(options):
    room = str(uuid.uuid4()).upper() + ''.join(secrets.choice('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') for _ in range(8))
    d = dict(room=room)
    validate_configuration(d)
    return d


def inspect_turn(d, decoded):
    validate_configuration(d)
    decoded['room'] = d['room']
    return decoded


def validate_transition(before, after, decoded):
    if before['room'] != after['room']:
        raise ValueError('crazy_room_changed')


def result(d, decoded):
    return terminal_marker(d)
