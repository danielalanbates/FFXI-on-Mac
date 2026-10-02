-- Vanagear :: the part that decides when to swap.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

local compat = require('modules.compat');
local gear   = require('modules.gear');
local rules  = require('modules.rules');
local slots  = require('modules.slots');

local M = {};

M.doc = nil;            -- set by the addon on load
M.busyUntil = 0;        -- while an action is in flight the base set stays off
M.pendingMidcast = nil; -- event to equip on the next frame
M.lastChain = {};       -- for /vgear why

local function now()
    return os.clock();
end

-- Everything that is true right now, as a set of tokens. A set may name any of
-- these after a colon and it will only apply when they hold.
function M.tokens()
    local doc = M.doc;
    local active = {};

    -- The player's own modes.
    for _, value in pairs(doc.active or {}) do
        if type(value) == 'string' and value ~= 'normal' then active[value:lower()] = true; end
    end

    if not doc.settings.conditions then return active; end

    local sub = compat.subJob();
    if sub ~= nil and sub > 0 then active['sub-' .. compat.jobName(sub):lower()] = true; end

    -- Thresholds, coarse on purpose: a set called "hp25" should fire at 25% and
    -- below, and a player should not have to think about the boundary.
    local hp = compat.hpPercent();
    if hp ~= nil then
        for _, step in ipairs({ 25, 50, 75 }) do
            if hp <= step then active['hp' .. step] = true; end
        end
    end
    local mp = compat.mpPercent();
    if mp ~= nil then
        for _, step in ipairs({ 25, 50, 75 }) do
            if mp <= step then active['mp' .. step] = true; end
        end
    end
    local tp = compat.tp();
    if tp ~= nil then
        for _, step in ipairs({ 1000, 2000, 3000 }) do
            if tp >= step then active['tp' .. step] = true; end
        end
    end

    if compat.isMoving() then active['moving'] = true; end

    local day = compat.dayElement();
    if day ~= nil then active[day:lower() .. 'sday'] = true; end
    local weather = compat.weatherElement();
    if weather ~= nil then active['weather-' .. weather:lower()] = true; end

    return active;
end

local function activeCtx()
    local status = compat.status();
    return {
        engaged = (status == 1 or status == 3),
        resting = (status == 33),
        tokens  = M.tokens(),
    };
end
M.activeCtx = activeCtx;

function M.debug(text)
    if M.doc and M.doc.settings.debug then compat.print(text); end
end

-- Resolve, merge, equip. Everything that swaps gear comes through here.
function M.equipEvent(event, reason)
    local doc = M.doc;
    if doc == nil then return; end
    local ctx = activeCtx();
    local names = rules.resolve(doc.sets, event, ctx);
    local setMap, matched = gear.merge(doc, names);
    M.lastChain = { event = event, considered = names, matched = matched };
    if next(setMap) == nil then
        M.debug(('%s: no set matched (%s)'):format(reason or event.kind, names[#names] or '?'));
        return;
    end
    local actions, misses = gear.apply(doc, setMap);
    if doc.settings.debug then
        local parts = {};
        for _, action in ipairs(actions) do
            parts[#parts + 1] = ('%s=%s'):format(action.slot,
                action.name or compat.itemName(action.id));
        end
        compat.print(('%s [%s] -> %s'):format(reason or event.kind,
            table.concat(matched, ' > '),
            (#parts > 0) and table.concat(parts, ', ') or 'no change'));
        if #misses > 0 then
            compat.print('missing: ' .. table.concat(misses, ', '));
        end
    end
    return actions, misses;
end

-- Equip a set by name, ignoring the rule chain. This is what a macro line like
-- "/vgear equip ws.rampage" calls.
function M.equipNamed(name)
    local doc = M.doc;
    local ctx = activeCtx();
    -- A named equip still honours conditions: "/vgear equip tp" picks up
    -- "tp:acc" when acc is on, exactly as the automatic path would.
    local names = rules.select(doc.sets, { name }, ctx.tokens);
    local setMap, matched = gear.merge(doc, names);
    if next(setMap) == nil then return nil; end
    -- A hand-driven equip holds off the base tick for a few seconds. Longer
    -- than that and the player wants /vgear auto off, not a longer timer.
    M.busyUntil = now() + 3.0;
    local actions = gear.apply(doc, setMap);
    return actions, matched;
end

-- ------------------------------------------------------------ base refresh

-- Instead of decoding every action-completion packet, the base set is simply
-- re-asserted on a slow tick. Nothing is sent unless a slot actually differs,
-- so this is cheap, and it self-heals after zoning, death, a manual swap, or a
-- missed aftercast.
M.nextTick = 0;

function M.tick(interval)
    local doc = M.doc;
    if doc == nil or not doc.settings.auto then return; end
    if compat.isZoning() then return; end

    if M.pendingMidcast ~= nil then
        local event = M.pendingMidcast;
        M.pendingMidcast = nil;
        M.equipEvent(event, 'midcast');
        return;
    end

    local time = now();
    if time < M.nextTick then return; end
    M.nextTick = time + (interval or 0.5);
    if time < M.busyUntil then return; end

    local status = compat.status();
    if status == 2 or status == 3 then return; end -- dead
    M.equipEvent({ kind = 'base' }, 'base');
end

-- ---------------------------------------------------------- action packets

local function u16(data, offset)
    local low  = data:byte(offset + 1) or 0;
    local high = data:byte(offset + 2) or 0;
    return low + (high * 256);
end
M.u16 = u16;

-- Categories in the 0x1A action packet.
local CATEGORY = {
    [0x03] = 'spell',
    [0x07] = 'ws',
    [0x09] = 'ja',
    [0x10] = 'ranged',
};

-- Describe an outgoing action. Returns the precast event and the midcast event
-- that should follow it, either of which may be nil.
function M.describeAction(data)
    local category = u16(data, 0x0A);
    local actionId = u16(data, 0x0C);
    local kind = CATEGORY[category];
    if kind == nil then return nil; end

    if kind == 'spell' then
        local res = compat.spellResource(actionId);
        local name = compat.try(function() return res.Name[1]; end, nil);
        local skill = compat.skillName(compat.try(function() return res.Skill; end, nil));
        -- CastTime is in quarter-seconds. The base tick must not fight midcast
        -- gear part-way through a long cast, so the hold covers the whole cast.
        local cast = compat.try(function() return res.CastTime * 0.25; end, 4) or 4;
        return { kind = 'precast', name = name, skill = skill, hold = cast + 2 },
               { kind = 'midcast', name = name, skill = skill, hold = cast + 2 };
    elseif kind == 'ws' then
        local res = compat.abilityResource(actionId);
        local name = compat.try(function() return res.Name[1]; end, nil);
        local skill = compat.skillName(compat.try(function() return res.Skill; end, nil));
        return { kind = 'ws', name = name, skill = skill, hold = 2.5 }, nil;
    elseif kind == 'ja' then
        local res = compat.abilityResource(actionId + 0x200);
        local name = compat.try(function() return res.Name[1]; end, nil);
        return { kind = 'ja', name = name, hold = 2.0 }, nil;
    elseif kind == 'ranged' then
        return { kind = 'preshot', hold = 6 }, { kind = 'midshot', hold = 6 };
    end
end

-- Called from the packet_out hook. Returns true when the caller should block
-- the original packet, because we have already re-sent it behind the gear.
function M.handleActionOut(data, reinject)
    local doc = M.doc;
    if doc == nil or not doc.settings.auto then return false; end
    local pre, mid = M.describeAction(data);
    if pre == nil then return false; end

    M.busyUntil = now() + (pre.hold or 3.0);

    if not doc.settings.precast then
        -- Non-blocking mode: the action goes out untouched and the gear lands
        -- a beat late. Safe, but fast cast and weaponskill gear will not count.
        M.equipEvent(pre, pre.kind);
        M.pendingMidcast = mid;
        return false;
    end

    -- Equip packets are queued ahead of the re-sent action, so the server
    -- processes the swap first and the action goes off in the right gear.
    M.equipEvent(pre, pre.kind);
    reinject(data);
    M.pendingMidcast = mid;
    return true;
end

return M;
