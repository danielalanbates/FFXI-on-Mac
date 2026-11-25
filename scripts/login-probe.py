#!/usr/bin/env python3
"""Which emulator is a world running? Ask its login server.

Modern LandSandBoat speaks JSON over TLS on port 54231 (src/login/auth_session.cpp) and answers a
stale version tuple with a verbatim "Your xiloader is too old." payload. DarkStar-lineage login
servers predate TLS entirely and never complete a handshake. That is the whole test.

One connection per server, one login attempt with a throwaway name -- the same thing any client
does on startup. Results as of 2026-08-21 are in docs/CODEBASE.md.

    python3 scripts/login-probe.py
"""
# throwaway name. Modern LandSandBoat answers JSON over TLS; DarkStar-lineage login servers
# speak the old binary protocol and never complete a TLS handshake.
import socket, ssl, json, sys
HOSTS = [("HorizonXI","play.horizonxi.com"),("CatsEyeXI","server.catseyexi.com"),
         ("Eden","play.edenxi.com"),("FFEra","ffera.com"),("Gaia XI","play.gaiaxi.com"),
         ("ValhallaXI","logon.valhalla.group"),("Supernova","login.supernovaffxi.com"),
         ("OmicronXI","OmicronFFXI.com"),("AscensionXI","play.ascensionffxi.com"),
         ("Vanadreams","vanadreams.online")]
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
for name,host in HOSTS:
    verdict=[]
    try:
        raw=socket.create_connection((host,54231),timeout=8)
    except Exception as e:
        print(f"{name:12} port 54231 closed/unreachable ({type(e).__name__})"); continue
    verdict.append("port open")
    try:
        s=ctx.wrap_socket(raw, server_hostname=host); s.settimeout(8)
        verdict.append("TLS ok")
        s.sendall(json.dumps({"command":16,"username":"zzprobe_notarealuser",
                              "password":"zzprobe",
                              # 0.0.0 is deliberately stale: it makes an LSB login server
                              # identify itself in the error text instead of closing quietly.
"version":[0,0,0]}).encode())
        data=s.recv(512)
        verdict.append("reply="+repr(data[:120]))
        s.close()
    except Exception as e:
        verdict.append(f"no TLS ({type(e).__name__}: {str(e)[:60]})")
        try: raw.close()
        except Exception: pass
    print(f"{name:12} " + " | ".join(verdict))
