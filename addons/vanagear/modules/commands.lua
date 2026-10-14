-- Vanagear :: the macro surface. Everything the player can do, they do from a
-- macro line, because that is the entire premise of the addon.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

local compat  = require('modules.compat');
local engine  = require('modules.engine');
local gear    = require('modules.gear');
local hud     = require('modules.hud');
local profile = require('modules.profile');
local rules   = require('modules.rules');
local slots   = require('modules.slots');

local M = {};

local function say(text)
    compat.print(text);
end

local function join(args, from)
    local parts = {};
    for i = from, #args do parts[#parts + 1] = args[i]; end
    return table.concat(parts, ' ');
end

local function onOff(value, current)
    if value == nil then return not current; end
    value = value:lower();
    if value == 'on' or value == 'true' or value == '1' then return true; end
    if value == 'off' or value == 'false' or value == '0' then return false; end
    return not current;
end

local function describeSet(set)
    local parts = {};
    for _, slot in ipairs(slots.order) do
        local value = set[slot];
        if value ~= nil then
            if type(value) == 'table' then value = table.concat(value, ' | '); end
            parts[#parts + 1] = ('  %-6s %s'):format(slot, value);
        end
    end
    return parts;
end

-- ------------------------------------------------------------------ handlers

local handlers = {};

handlers.help = function()
    say('gear capture   /vgear save <set>   [over <base>]   /vgear naked');
    say('edit           /vgear set <set> <slot> <item>  |  /vgear add ...  |  /vgear clear <set> [slot]');
    say('manage         /vgear list  /vgear show <set>  /vgear copy <a> <b>  /vgear rename <a> <b>  /vgear del <set>');
    say('use            /vgear equip <set>   /vgear refresh   /vgear why');
    say('modes          /vgear mode <group> <value>   /vgear cycle <group>   /vgear modes');
    say('conditions     /vgear tokens        (a set named tp:hp25 applies only below 25% hp)');
    say('locks          /vgear lock <slot>   /vgear unlock <slot>   /vgear locks');
    say('switches       /vgear auto|precast|equipset|debug [on|off]   /vgear status');
    say('Set names the engine looks for: idle, resting, tp, precast[.spell], midcast[.spell],');
    say('ws[.name], ja[.name], preshot, midshot, item[.name].');
    say('Add ":<token>" to any of them - a mode you made, or hp25/mp25/tp3000/moving/sub-nin.');
end

handlers.save = function(session, args)
    local name = profile.key(args[1]);
    if name == nil then return say('usage: /vgear save <set name> [over <base set>]'); end

    local captured = gear.capture();
    if args[2] and args[2]:lower() == 'over' then
        local base = profile.key(join(args, 3));
        local baseSet = session.doc.sets[base];
        if baseSet == nil then return say('no set named "' .. tostring(base) .. '"'); end
        for slot, value in pairs(baseSet) do
            if type(value) == 'string' and gear.normalizeName(value) == gear.normalizeName(captured[slot]) then
                captured[slot] = nil;
            end
        end
    end

    session.doc.sets[name] = profile.sanitizeSet(captured);
    session.save();
    local count = 0;
    for _ in pairs(session.doc.sets[name]) do count = count + 1; end
    say(('saved "%s" (%d slots)'):format(name, count));
end

handlers.set = function(session, args)
    local name = profile.key(args[1]);
    local slot = slots.resolve(args[2] or '');
    local item = join(args, 3);
    if name == nil or slot == nil or #item == 0 then
        return say('usage: /vgear set <set> <slot> <item name>');
    end
    local set = session.doc.sets[name] or {};
    set[slot] = item;
    session.doc.sets[name] = set;
    session.save();
    say(('%s.%s = %s'):format(name, slot, item));
end

handlers.add = function(session, args)
    local name = profile.key(args[1]);
    local slot = slots.resolve(args[2] or '');
    local item = join(args, 3);
    if name == nil or slot == nil or #item == 0 then
        return say('usage: /vgear add <set> <slot> <fallback item name>');
    end
    local set = session.doc.sets[name] or {};
    local value = set[slot];
    if value == nil then
        set[slot] = item;
    elseif type(value) == 'string' then
        set[slot] = { value, item };
    else
        value[#value + 1] = item;
    end
    session.doc.sets[name] = set;
    session.save();
    local shown = set[slot];
    if type(shown) == 'table' then shown = table.concat(shown, ' | '); end
    say(('%s.%s = %s'):format(name, slot, shown));
end

handlers.clear = function(session, args)
    local name = profile.key(args[1]);
    if name == nil or session.doc.sets[name] == nil then
        return say('no set named "' .. tostring(args[1]) .. '"');
    end
    local slot = slots.resolve(args[2] or '');
    if slot ~= nil then
        session.doc.sets[name][slot] = nil;
        say(('cleared %s.%s'):format(name, slot));
    else
        session.doc.sets[name] = {};
        say(('emptied %s'):format(name));
    end
    session.save();
end

handlers.del = function(session, args)
    local name = profile.key(args[1]);
    if name == nil or session.doc.sets[name] == nil then
        return say('no set named "' .. tostring(args[1]) .. '"');
    end
    session.doc.sets[name] = nil;
    session.save();
    say('deleted ' .. name);
end
handlers.delete = handlers.del;

handlers.copy = function(session, args)
    local from = profile.key(args[1]);
    local to   = profile.key(join(args, 2));
    if from == nil or to == nil or session.doc.sets[from] == nil then
        return say('usage: /vgear copy <existing set> <new set>');
    end
    local copy = {};
    for slot, value in pairs(session.doc.sets[from]) do copy[slot] = value; end
    session.doc.sets[to] = copy;
    session.save();
    say(('copied %s -> %s'):format(from, to));
end

handlers.rename = function(session, args)
    local from = profile.key(args[1]);
    local to   = profile.key(join(args, 2));
    if from == nil or to == nil or session.doc.sets[from] == nil then
        return say('usage: /vgear rename <set> <new name>');
    end
    session.doc.sets[to] = session.doc.sets[from];
    session.doc.sets[from] = nil;
    session.save();
    say(('renamed %s -> %s'):format(from, to));
end

handlers.list = function(session, args)
    local filter = (args[1] or ''):lower();
    local names = {};
    for name in pairs(session.doc.sets) do
        if filter == '' or name:find(filter, 1, true) then names[#names + 1] = name; end
    end
    table.sort(names);
    if #names == 0 then return say('no sets saved yet - wear some gear and /vgear save idle'); end
    say(('%d set(s) for %s'):format(#names, session.label));
    for _, name in ipairs(names) do
        local count = 0;
        for _ in pairs(session.doc.sets[name]) do count = count + 1; end
        say(('  %-28s %d slots'):format(name, count));
    end
end

handlers.show = function(session, args)
    local name = profile.key(join(args, 1));
    local set = name and session.doc.sets[name];
    if set == nil then return say('no set named "' .. tostring(name) .. '"'); end
    say(name .. ':');
    for _, line in ipairs(describeSet(set)) do say(line); end
end

handlers.equip = function(session, args)
    local name = profile.key(join(args, 1));
    if name == nil then return say('usage: /vgear equip <set>'); end
    local actions, matched = engine.equipNamed(name);
    if actions == nil then return say('no set named "' .. name .. '"'); end
    say(('equipped %s (%d change%s)'):format(table.concat(matched, ' > '),
        #actions, (#actions == 1) and '' or 's'));
end

handlers.naked = function(session)
    local set = {};
    for _, slot in ipairs(slots.order) do
        if slot ~= 'main' and slot ~= 'sub' and slot ~= 'range' and slot ~= 'ammo' then
            set[slot] = 'remove';
        end
    end
    engine.busyUntil = os.clock() + 5.0;
    local actions = gear.apply(session.doc, set);
    say(('stripped %d slot(s) - base gear returns in 5s or on /vgear refresh'):format(#actions));
end

handlers.refresh = function()
    engine.busyUntil = 0;
    engine.nextTick = 0;
    engine.equipEvent({ kind = 'base' }, 'refresh');
end

handlers.why = function(session)
    local last = engine.lastChain;
    if last == nil or last.event == nil then return say('nothing swapped yet'); end
    say(('last event: %s %s'):format(last.event.kind, last.event.name or ''));
    say('considered: ' .. table.concat(last.considered, ', '));
    say('matched:    ' .. ((#last.matched > 0) and table.concat(last.matched, ' > ') or 'none'));
end

handlers.mode = function(session, args)
    local group = (args[1] or ''):lower();
    local value = (args[2] or ''):lower();
    if #group == 0 then return handlers.modes(session); end
    if #value == 0 then
        return say(('%s = %s'):format(group, session.doc.active[group] or 'normal'));
    end
    local list = session.doc.modes[group] or { 'normal' };
    local known = false;
    for _, entry in ipairs(list) do if entry == value then known = true; end end
    if not known then list[#list + 1] = value; end
    session.doc.modes[group] = list;
    session.doc.active[group] = value;
    session.save();
    say(('%s = %s'):format(group, value));
    handlers.refresh(session);
end

handlers.cycle = function(session, args)
    local group = (args[1] or ''):lower();
    local list = session.doc.modes[group];
    if list == nil or #list == 0 then return say('no mode group named "' .. group .. '"'); end
    local current = session.doc.active[group] or list[1];
    local nextIndex = 1;
    for index, entry in ipairs(list) do
        if entry == current then nextIndex = (index % #list) + 1; end
    end
    session.doc.active[group] = list[nextIndex];
    session.save();
    say(('%s = %s'):format(group, list[nextIndex]));
    handlers.refresh(session);
end

handlers.modes = function(session)
    local names = {};
    for name in pairs(session.doc.modes) do names[#names + 1] = name; end
    table.sort(names);
    if #names == 0 then return say('no modes defined - try /vgear mode offense acc'); end
    for _, name in ipairs(names) do
        say(('  %-12s %s   [%s]'):format(name, session.doc.active[name] or 'normal',
            table.concat(session.doc.modes[name], ', ')));
    end
end

handlers.lock = function(session, args)
    local slot = slots.resolve(args[1] or '');
    if slot == nil then return say('usage: /vgear lock <slot>'); end
    session.doc.locks[slot] = true;
    session.save();
    say(slot .. ' locked - nothing will swap it');
end

handlers.unlock = function(session, args)
    local slot = slots.resolve(args[1] or '');
    if slot == nil then return say('usage: /vgear unlock <slot>'); end
    session.doc.locks[slot] = nil;
    session.save();
    say(slot .. ' unlocked');
end

handlers.locks = function(session)
    local names = {};
    for slot in pairs(session.doc.locks) do names[#names + 1] = slot; end
    table.sort(names);
    say((#names > 0) and ('locked: ' .. table.concat(names, ', ')) or 'nothing locked');
end

handlers.tokens = function(session)
    local active = engine.tokens();
    local names = {};
    for token in pairs(active) do names[#names + 1] = token; end
    table.sort(names);
    if #names == 0 then
        say('no conditions are true right now');
    else
        say('true right now: ' .. table.concat(names, ', '));
    end
    say('name a set "<set>:<token>" and it only applies while that token holds');
end
handlers.conds = handlers.tokens;

local switches = { auto = true, precast = true, equipset = true, debug = true, conditions = true };
for switch in pairs(switches) do
    handlers[switch] = function(session, args)
        session.doc.settings[switch] = onOff(args[1], session.doc.settings[switch]);
        session.save();
        say(('%s %s'):format(switch, session.doc.settings[switch] and 'on' or 'off'));
    end
end

handlers.hud = function(session, args)
    local open = hud.toggle(args[1] and onOff(args[1], hud.open[1]) or nil);
    session.doc.settings.hud = open;
    session.save();
    say('panel ' .. (open and 'open' or 'closed'));
end
handlers.gui   = handlers.hud;
handlers.panel = handlers.hud;

handlers.status = function(session)
    local s = session.doc.settings;
    say(('profile %s   auto:%s precast:%s equipset:%s conditions:%s debug:%s'):format(session.label,
        s.auto and 'on' or 'off', s.precast and 'on' or 'off',
        s.equipset and 'on' or 'off', s.conditions and 'on' or 'off',
        s.debug and 'on' or 'off'));
    handlers.modes(session);
    handlers.tokens(session);
    handlers.locks(session);
end

handlers.reload = function(session)
    session.reload();
    say('profile reloaded from disk');
end

-- ------------------------------------------------------------------ dispatch

function M.split(text)
    local args = {};
    for word in tostring(text or ''):gmatch('%S+') do args[#args + 1] = word; end
    return args;
end

-- Returns true when the command was ours, so the caller can block it.
function M.handle(session, argsText)
    local args = M.split(argsText);
    local verb = (table.remove(args, 1) or 'help'):lower();
    local handler = handlers[verb];
    if handler == nil then
        say('unknown command "' .. verb .. '" - try /vgear help');
        return true;
    end
    local ok, err = pcall(handler, session, args);
    if not ok then say('error: ' .. tostring(err)); end
    return true;
end

M.handlers = handlers;
return M;
