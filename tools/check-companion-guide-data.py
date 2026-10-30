#!/usr/bin/env python3
"""Check that a companion bundle includes every allowed static guide-data file.
Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
"""
from pathlib import Path
import sys

source, bundle = (Path(p) for p in sys.argv[1:])
target = bundle / 'Contents/Resources/Vanaguide'
files = sorted(set(source.glob('guides/*.lua')) | set(source.glob('data/*.lua')) |
               set(source.glob('data/servers/*/*.lua')))
assert files, 'No source data found'
for file in files:
    relative = file.relative_to(source)
    packaged = target / relative
    assert packaged.is_file(), f'Missing packaged data: {relative}'
    assert packaged.read_bytes() == file.read_bytes(), f'Different packaged data: {relative}'
print(f'{len(files)} static guide-data files match source, including server folders.')
