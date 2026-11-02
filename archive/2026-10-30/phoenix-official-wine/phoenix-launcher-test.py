#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import os, subprocess, tempfile
from pathlib import Path
script=Path(__file__).resolve().parents[1]/'phoenix-launcher.sh'
with tempfile.TemporaryDirectory(prefix='phoenix-helper-',dir=Path(__file__).resolve().parents[3]) as tmp:
    base=Path(tmp);root=base/'Phoenix with spaces';app=root/'prefix/drive_c/PhoenixLauncher/phoenix-launcher.exe';app.parent.mkdir(parents=True);app.write_text('fixture')
    wine=base/'mock wine';wine.write_text('#!/bin/sh\nif [ "$1" = reg ]; then exit 0; fi\nprintf "SECRET_FIXTURE\\n"\nprintf "%s" "$WINEPREFIX" > "'+str(base/'prefix-used')+'"\n');wine.chmod(0o700)
    run=lambda:subprocess.run(['/bin/zsh',str(script),str(wine),str(root)],capture_output=True,text=True)
    result=run();assert result.returncode==0,result.stderr
    assert 'SECRET_FIXTURE' not in result.stdout+result.stderr
    assert 'SECRET_FIXTURE' in (root/'logs/phoenix-runtime.log').read_text()
    assert (base/'prefix-used').read_text()==str(root/'prefix')
    assert not (root/'.launcher-lock').exists()
    (root/'.launcher-lock').mkdir();(root/'.launcher-lock/pid').write_text(str(os.getpid()))
    (base/'prefix-used').unlink();result=run();assert result.returncode==0 and 'already open' in result.stdout and not (base/'prefix-used').exists()
    (root/'.launcher-lock/pid').write_text('99999999');result=run();assert result.returncode==0 and (base/'prefix-used').exists()
    invalid=subprocess.run(['/bin/zsh',str(script),str(wine),'/'],capture_output=True);assert invalid.returncode==2
print('PASS: private output, prefix isolation, spaces, active/stale locks, unsafe root')
