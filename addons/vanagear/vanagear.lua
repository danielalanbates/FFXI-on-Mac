-- Vanagear - macro-driven gear swapping for Final Fantasy XI (Ashita v4).
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Licensed under PolyForm Noncommercial 1.0.0 with a commercial-use royalty
-- addendum. See LICENSE. https://batesai.org - help@batesai.org
--
-- The idea: nobody should have to write Lua to swap gear. Wear the set, save it
-- from a macro, and the addon works out the rest.

addon.name     = 'vanagear';
addon.author   = 'Daniel Bates (batesai.org)';
addon.version  = '1.0.0';
addon.desc     = 'Gear swapping driven entirely by in-game macros. No profile scripting.';

require('common');

-- Ashita keeps package.loaded across an addon unload/load on some builds, so an
-- updated module file can be ignored until the client restarts. Purging our own
-- entries first makes /addon unload + load a real reload.
for _, module in ipairs({ 'modules.compat', 'modules.slots', 'modules.profile',
                          'modules.rules', 'modules.gear', 'modules.engine',
                          'modules.commands', 'modules.hud' }) do
    package.loaded[module] = nil;
end

local compat   = require('modules.compat');
local commands = require('modules.commands');
local engine   = require('modules.engine');
local hud      = require('modules.hud');
local profile  = require('modules.profile');

local session = {
    doc   = profile.defaults(),
    path  = nil,
    label = 'unloaded',
};

local function currentLabel()
    local character = compat.playerName();
    local job = compat.jobName(compat.mainJob());
    return character, job, ('%s/%s'):format(character, job);
end

function session.reload()
    local character, job, label = currentLabel();
    session.path  = profile.path(character, job);
    session.label = label;
    session.doc   = profile.normalize(profile.read(session.path));
    engine.doc    = session.doc;
    hud.toggle(session.doc.settings.hud);
    engine.nextTick = 0;
end

function session.save()
    if session.path == nil then return; end
    if not profile.write(session.path, session.doc) then
        compat.print('could not write ' .. session.path);
    end
end

-- Reload the profile when the player changes job, so BLM gear never fires on
-- WAR. Cheap enough to check on the same slow tick the base refresh uses.
local watchedJob = nil;
local watchedName = nil;
local function checkProfile()
    local character, job = currentLabel();
    if job ~= watchedJob or character ~= watchedName then
        watchedJob, watchedName = job, character;
        if character ~= 'unknown' then
            session.reload();
            compat.print(('profile: %s'):format(session.label));
        end
    end
end

ashita.events.register('load', 'vanagear_load', function()
    session.reload();
    compat.print(('v%s loaded. /vgear help for the commands, /vgear hud for the panel.'):format(addon.version));
end);

ashita.events.register('unload', 'vanagear_unload', function()
    session.save();
end);

ashita.events.register('command', 'vanagear_command', function(e)
    local text = e.command;
    local verb, rest = text:match('^%s*/([%a]+)%s*(.*)$');
    if verb == nil then return; end
    verb = verb:lower();
    -- NOT '/vg': Vanaguide, this project's other addon, already owns it. Two
    -- addons answering the same slash command means whichever loaded last wins
    -- and the other silently stops responding.
    if verb ~= 'vgear' and verb ~= 'vanagear' and verb ~= 'gs' then return; end
    e.blocked = true;
    commands.handle(session, rest);
end);

-- Outgoing action packets. This is where precast lives: the action is held, the
-- gear goes out ahead of it, and the action is re-sent behind it in the same
-- frame so the server sees the swap first.
local function reinject(data)
    local bytes = {};
    for index = 1, #data do bytes[index] = data:byte(index); end
    compat.sendPacket(0x1A, bytes);
end

ashita.events.register('packet_out', 'vanagear_packet_out', function(e)
    if e.id ~= 0x1A or e.injected then return; end
    local ok, blocked = pcall(engine.handleActionOut, e.data, reinject);
    if ok and blocked then e.blocked = true; end
end);

ashita.events.register('d3d_present', 'vanagear_present', function()
    checkProfile();
    engine.tick(0.5);
    hud.render(session);
end);
