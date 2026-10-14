--[[
cmdpipe -- run game commands from a file, and copy the game's chat to another.

Why this is its own addon
-------------------------
Unattended verification needs two wires into a running client: one to send commands, one to
read what the game said back. Both used to live inside the guide addon being tested, and that
is a trap -- `/addon reload vanaguide` cut the wire it was travelling on, the client went deaf
mid-run, and the only way back in was a full restart (two and a half minutes each time).

A wire you can cut by reloading the thing under test is not a wire. So it lives here, in an
addon that has no reason to be reloaded, and is loaded once at boot before anything else.

    <install>\addons\cmdpipe\cmd.txt      write one command per line; each runs once
    <install>\addons\cmdpipe\chat.txt     every incoming chat line, with its mode

Both paths can be changed:

    /cmdpipe                 status
    /cmdpipe chat <file>     start copying chat to addons\cmdpipe\<file> ('off' to stop)
    /cmdpipe packets on|off  also log incoming packet ids -- noisy, for protocol work

It executes only what a player could type, and sends nothing to the server on its own.

Copyright (c) 2026 Bates LLC.  All rights reserved.
https://batesai.org -- help@batesai.org
]]--

addon.name    = 'cmdpipe';
addon.author  = 'Bates LLC';
addon.version = '1.0';
addon.desc    = 'File-driven command and chat channel for unattended runs.';

-- Ashita 4.3 faults inside LuaJIT's mcode patcher when a jitted addon touches the FFI.
jit.off();

require('common');
local chat = _G.chat or require('chat');

local BASE     = 'C:\\HorizonXI\\addons\\cmdpipe\\';
local CMD_PATH = BASE .. 'cmd.txt';

-- A second, host-side pipe. macOS TCC can leave the game volume unreadable to the
-- terminal that drives an unattended run, while Z:\tmp (the Mac's /tmp) is always
-- writable by both sides. Harmless when the directory does not exist.
local ALT_BASE     = 'Z:\\tmp\\ffxi-pipe\\';
local ALT_CMD_PATH = ALT_BASE .. 'cmd.txt';
local ALT_CHAT     = ALT_BASE .. 'chat.txt';

local state = { chat_path = BASE .. 'chat.txt', packets = false };

local function say(msg)
    pcall(print, chat.header('cmdpipe') .. chat.message(msg));
end

--- Strip FFXI's in-band control bytes so the file holds readable text.
---   0x1E/0x1F <n>  colour and emote codes
---   0x7F <n>       the "press enter to continue" marker
---   0x07           a mid-message line break
local function strip(text)
    if (text == nil) then return ''; end
    return (text:gsub('[\30\31].', '')
                :gsub('\239[\39\41].', '')
                :gsub('\127.', '')
                :gsub('\7', ' ')
                :gsub('[%z\1-\6\8\11\12\14-\29]', ''));
end

ashita.events.register('text_in', 'cmdpipe_text_in', function (e)
    if (state.chat_path == nil) then return; end
    local line = strip((e.message_modified ~= nil and e.message_modified ~= '')
                       and e.message_modified or e.message);
    if (line:match('^%s*$')) then return; end
    -- 'ab': Lua on Windows opens text mode and rewrites every \n as \r\n, which a sibling
    -- project lost whole multi-line bursts to (VanaVoice, 2026-08-22).
    local out = ('[%d] %s\n'):format(e.mode or -1, line);
    local f = io.open(state.chat_path, 'ab');
    if (f ~= nil) then f:write(out); f:close(); end
    local g = io.open(ALT_CHAT, 'ab');
    if (g ~= nil) then g:write(out); g:close(); end
end);

ashita.events.register('packet_out', 'cmdpipe_packet_out', function (e)
    if (state.chat_path == nil or not state.packets) then return; end
    local h = {};
    for i = 1, math.min(24, e.size) do h[i] = ('%02X'):format(e.data:byte(i)); end
    local f = io.open(state.chat_path, 'ab');
    if (f == nil) then return; end
    f:write(('[out] id=0x%03X size=%d injected=%s %s\n')
        :format(e.id, e.size, tostring(e.injected), table.concat(h, ' ')));
    f:close();
end);

ashita.events.register('packet_in', 'cmdpipe_packet_in', function (e)
    if (state.chat_path == nil or not state.packets) then return; end
    local h = {};
    for i = 1, math.min(24, e.size) do h[i] = ('%02X'):format(e.data:byte(i)); end
    local f = io.open(state.chat_path, 'ab');
    if (f == nil) then return; end
    f:write(('[in ] id=0x%03X size=%d %s\n'):format(e.id, e.size, table.concat(h, ' ')));
    f:close();
end);

--- Read every line of cmd.txt, empty it, then run them.
--- Emptied BEFORE running: a command that reloads an addon would otherwise leave the file
--- intact to be read again on the next frame, and run forever.
local function pump_one(path)
    local f = io.open(path, 'r');
    if (f == nil) then return; end
    local lines = {};
    for line in f:lines() do
        line = line:gsub('^%s+', ''):gsub('%s+$', '');
        if (line ~= '') then lines[#lines + 1] = line; end
    end
    f:close();
    if (#lines == 0) then return; end
    local w = io.open(path, 'w');
    if (w ~= nil) then w:close(); end
    for _, line in ipairs(lines) do
        AshitaCore:GetChatManager():QueueCommand(-1, line);
    end
end

local function pump()
    pump_one(CMD_PATH);
    pump_one(ALT_CMD_PATH);
end

ashita.events.register('d3d_present', 'cmdpipe_present', function ()
    pcall(pump);
end);

ashita.events.register('command', 'cmdpipe_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/cmdpipe') then return; end
    e.blocked = true;
    local sub = (args[2] or 'status'):lower();

    if (sub == 'chat') then
        local name = args[3] or 'off';
        state.chat_path = (name:lower() == 'off') and nil or (BASE .. name);
        say('chat -> ' .. tostring(state.chat_path));
    elseif (sub == 'packets') then
        state.packets = (args[3] or 'on'):lower() == 'on';
        say('packet log ' .. (state.packets and 'on' or 'off'));
    else
        say(('cmd=%s  chat=%s  packets=%s')
            :format(CMD_PATH, tostring(state.chat_path), tostring(state.packets)));
    end
end);

ashita.events.register('load', 'cmdpipe_load', function ()
    say('ready: ' .. CMD_PATH);
end);
