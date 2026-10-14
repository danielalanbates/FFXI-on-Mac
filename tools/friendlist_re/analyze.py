#!/usr/bin/env python3
# Analysis of the FFXiMain.dll in-memory dump (see README.txt).
# Reproduces the 2026-09-12 native-friend-list findings. Usage: python3 analyze.py
#
# Copyright (c) 2026 Daniel Bates. All rights reserved.
# PolyForm Noncommercial + 10% revenue rider - see batesai.org, help@batesai.org
import re
import struct

BASE = 0x01CA0000
DUMP = 'ffximain-unpacked-2026-09-12.mem'

data = open(DUMP, 'rb').read()


def va(off):
    return BASE + off


# 1. Text-command table: 277 entries of 0x18 bytes at 0x1ff3418.
#    Layout: char name[16]; u32 pad; u16 command_id; u16 flags;
print('== command table (friend-relevant entries) ==')
o = 0x1ff3418 - BASE
while data[o] == 0x2F:
    name = data[o:o + 16].split(b'\0')[0].decode()
    cid, flags = struct.unpack_from('<HH', data, o + 20)
    if any(k in name for k in ('friend', 'flist', 'black', 'sea', 'mute')):
        print(f'  {va(o):08x} {name:14s} id=0x{cid:02x} flags=0x{flags:02x}')
    o += 0x18

# 2. Dispatcher: 0x1d1fe53 looks the name up, then 0x1d20020(id) executes.
#    0x1d20110 maps command_id -> menu id via 0xe4 pairs of s16 at 0x1fcabb0.
print('== command id -> menu id map (friend-relevant) ==')
o = 0x1fcabb0 - BASE
for i in range(0xE4):
    a, b = struct.unpack_from('<hh', data, o + i * 4)
    if a in (0x0D, 0x3A, 0x3B, 0x3C, 0x3D):
        print(f'  cmd 0x{a:02x} -> menu 0x{b:04x}')

# 3. Menu resource names present in the loaded client.
print('== friend menu resources ==')
for m in re.finditer(rb'menu    (friend|flistmai|flmes|olstat)', data):
    print(f'  {va(m.start()):08x} {m.group().decode()}')
