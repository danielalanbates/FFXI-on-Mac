--[[
sigscan -- find and dump FFXiMain.dll code so a stale Ashita signature can be re-derived.

Why this exists
---------------
Ashita resolves game functions by byte-pattern.  When Square Enix recompiles the client the
patterns go stale, the pointer resolves to 0, and every addon that depends on it silently
stops working.  On this install exactly two go stale:

    ERROR | PointerManager::Update | Pointer: (00000000) [Error!] packets.queuepacket1
    ERROR | PointerManager::Update | Pointer: (00000000) [Error!] player.haskeyitem

`packets.queuepacket1` is the one that hurts: without it `AddOutgoingPacket` is a no-op for
*every* addon, so nothing can talk to an NPC, pick a menu option, or send any action at all.

FFXiMain.dll cannot be scanned on disk -- its `.text` section has a raw size of zero and is
unpacked at run time by the POL1 section -- so those bytes only exist inside a live process.
That is the whole reason this is an addon and not a Python script.

Commands (answers go to `addons\sigscan\answers.txt`, because the unattended harness drives
the client through a file and cannot read the game's chat log)

    /sigscan info                       module base, .text bounds
    /sigscan find <pattern> [off] [n]   run Ashita's own scanner, report the address
    /sigscan dump <hexaddr> <hexlen>    write raw bytes to addons\sigscan\dump-<addr>-<len>.bin
    /sigscan text                       dump the whole .text section

Copyright (c) 2026 Bates LLC.  All rights reserved.
https://batesai.org -- help@batesai.org
]]--

addon.name    = 'sigscan';
addon.author  = 'Bates LLC';
addon.version = '1.0';
addon.desc    = 'Dump FFXiMain code so stale Ashita signatures can be re-derived.';

-- Ashita 4.3 faults inside LuaJIT's mcode patcher (Addons.dll+0xA0761A) when a jitted addon
-- touches the FFI. Every addon in this project turns the JIT off for the same reason.
jit.off();

require('common');
local ffi = require('ffi');

-- `common` does not bring `chat` in on this Ashita build; without this every call to say()
-- dies on a nil global and the addon unloads itself before printing the reason.
local chat = _G.chat or require('chat');

local ANSWERS = 'C:\\HorizonXI\\addons\\sigscan\\answers.txt';

local function say(fmt, ...)
    local msg = fmt;
    if (select('#', ...) > 0) then
        local ok, out = pcall(string.format, fmt, ...);
        msg = ok and out or ('format error: ' .. tostring(out));
    end
    pcall(print, chat.header('sigscan') .. chat.message(msg));
    local f = io.open(ANSWERS, 'a');
    if (f ~= nil) then f:write('[sigscan] ' .. msg .. '\n'); f:close(); end
end

-- Another addon in the same Lua state may already have declared this, and a duplicate cdef
-- is a hard error in LuaJIT -- which would kill this addon before it printed anything.
pcall(function ()
    ffi.cdef[[ void* __stdcall GetModuleHandleA(const char* lpModuleName); ]];
end);

local S = { base = 0, text = 0, textsize = 0 };

--- Locate FFXiMain.dll and its .text section by walking the PE headers in memory.
--- Bounds matter: reading outside a mapped section faults the game.
local function locate()
    local h = ffi.C.GetModuleHandleA('FFXiMain.dll');
    if (h == nil) then return false, 'FFXiMain.dll is not loaded'; end
    local base = tonumber(ffi.cast('uintptr_t', h));
    local pe   = base + ashita.memory.read_uint32(base + 0x3C);
    if (ashita.memory.read_uint32(pe) ~= 0x00004550) then return false, 'no PE signature'; end
    local nsec = ashita.memory.read_uint16(pe + 0x06);
    local opt  = ashita.memory.read_uint16(pe + 0x14);
    local sec  = pe + 0x18 + opt;
    for i = 0, nsec - 1 do
        local s    = sec + (i * 40);
        local name = '';
        for j = 0, 7 do
            local c = ashita.memory.read_uint8(s + j);
            if (c == 0) then break; end
            name = name .. string.char(c);
        end
        if (name == '.text') then
            S.base     = base;
            S.text     = base + ashita.memory.read_uint32(s + 0x0C);
            S.textsize = ashita.memory.read_uint32(s + 0x08);
            return true;
        end
    end
    return false, 'no .text section';
end

--- Write `len` bytes from `addr` to a file, in chunks, so one bad read cannot lose the lot.
local function dump(addr, len)
    local path = ('C:\\HorizonXI\\addons\\sigscan\\dump-%08X-%X.bin'):format(addr, len);
    local f = io.open(path, 'wb');
    if (f == nil) then return nil, 'cannot open ' .. path; end
    local CHUNK = 0x1000;
    local done  = 0;
    while (done < len) do
        local n = math.min(CHUNK, len - done);
        local ok, arr = pcall(ashita.memory.read_array, addr + done, n);
        if (not ok) then f:close(); return nil, ('read failed at %08X'):format(addr + done); end
        local out = {};
        for i = 1, n do out[i] = string.char(arr[i]); end
        f:write(table.concat(out));
        done = done + n;
    end
    f:close();
    return path;
end

ashita.events.register('command', 'sigscan_cmd', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/sigscan') then return; end
    e.blocked = true;

    local pok, ok, err = pcall(locate);
    if (not pok) then say('locate() threw: %s', tostring(ok)); return; end
    if (not ok) then say('cannot locate module: %s', tostring(err)); return; end

    local sub = (args[2] or 'info'):lower();

    if (sub == 'info') then
        say('FFXiMain base=%08X  .text=%08X size=%X (ends %08X)',
            S.base, S.text, S.textsize, S.text + S.textsize);

    elseif (sub == 'find') then
        local pattern = args[3];
        if (pattern == nil) then say('usage: /sigscan find <pattern> [offset] [count]'); return; end
        local off  = tonumber(args[4] or '0') or 0;
        local cnt  = tonumber(args[5] or '0') or 0;
        local fok, addr = pcall(ashita.memory.find, 0, 0, pattern, off, cnt);
        if (not fok) then say('find threw: %s', tostring(addr)); return; end
        if (addr == nil or addr == 0) then
            say('find: NO MATCH for %s', pattern);
        else
            say('find: %s -> %08X (rva %X)', pattern, addr, addr - S.base);
        end

    elseif (sub == 'dump') then
        local addr = tonumber(args[3] or '', 16) or S.text;
        local len  = tonumber(args[4] or '', 16) or 0x1000;
        local path, derr = dump(addr, len);
        if (path == nil) then say('dump failed: %s', tostring(derr));
        else say('dump: %X bytes from %08X -> %s', len, addr, path); end

    elseif (sub == 'text') then
        local path, derr = dump(S.text, S.textsize);
        if (path == nil) then say('dump failed: %s', tostring(derr));
        else say('text: %X bytes from %08X (base %08X) -> %s',
                 S.textsize, S.text, S.base, path); end

    else
        say('unknown subcommand: %s', sub);
    end
end);

ashita.events.register('load', 'sigscan_load', function ()
    local pok, ok, err = pcall(locate);
    if (not pok) then say('load: locate() threw: %s', tostring(ok)); return; end
    if (ok) then say('ready: base=%08X .text=%08X size=%X', S.base, S.text, S.textsize);
    else say('loaded, but %s', tostring(err)); end
end);
