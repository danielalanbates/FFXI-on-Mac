-- Vanagear :: turning a named set into equip packets.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

local compat = require('modules.compat');
local slots  = require('modules.slots');

local M = {};

local EMPTY = { ['remove'] = true, ['none'] = true, ['empty'] = true, ['-'] = true };

-- ------------------------------------------------------------------ merging

-- Merge the named sets generic-first. A later set only overrides the slots it
-- names, which is what lets "ws.rampage" be two lines instead of sixteen.
function M.merge(doc, names)
    local out = {};
    local matched = {};
    for _, name in ipairs(names) do
        local set = doc.sets[name];
        if type(set) == 'table' then
            matched[#matched + 1] = name;
            for slot, value in pairs(set) do
                if slots.id[slot] ~= nil then out[slot] = value; end
            end
        end
    end
    return out, matched;
end

-- ------------------------------------------------------------- item lookup

local function normalizeName(text)
    return tostring(text or ''):lower():gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '');
end
M.normalizeName = normalizeName;

-- One pass over the bags, keyed by lowercase item name.
function M.snapshotBags()
    local byName = {};
    for _, container in ipairs(slots.containers) do
        local count = compat.containerCount(container) or 0;
        for index = 1, count do
            local item = compat.containerItem(container, index);
            if item ~= nil and (item.Id or 0) ~= 0 and (item.Count or 0) ~= 0 then
                local res = compat.itemResource(item.Id);
                local names = compat.itemNames(res);
                local entry = {
                    Container = container,
                    Index     = index,
                    Id        = item.Id,
                    Resource  = res,
                };
                -- Name and LogName normalize to the same string for most
                -- items, so the same bag slot must not be listed twice.
                local seen = {};
                for _, name in ipairs(names) do
                    local key = normalizeName((name:gsub('%z.*$', '')));
                    if #key > 0 and not seen[key] then
                        seen[key] = true;
                        byName[key] = byName[key] or {};
                        byName[key][#byName[key] + 1] = entry;
                    end
                end
            end
        end
    end
    return byName;
end

local function bit_test(value, index)
    if value == nil or value == 0 then return true; end -- unrestricted / unknown
    local mask = 2 ^ index;
    return math.floor(value / mask) % 2 == 1;
end

-- Hard gate. The slot mask is not a convention this project had to guess at:
-- it was checked against all 15,522 equippable items in the game (tests/corpus)
-- and every one of them lands inside the sixteen known slots. The server would
-- reject the equip anyway, so a last-resort fallback into the wrong slot is not
-- a safety net, it is a wasted packet.
function M.fits(entry, slotName)
    local res = entry.Resource;
    if res == nil then return true; end
    if res.Slots == nil or res.Slots == 0 then return true; end
    return bit_test(res.Slots, slots.id[slotName]);
end

-- Advisory: a candidate that fails these is skipped in favour of the next one,
-- but if every candidate fails we equip the first one that fits the slot. The
-- job, level and race conventions were read off other addons rather than
-- proven, and a wrong bitmask must never leave the player naked.
function M.usable(entry, slotName, ctx)
    local res = entry.Resource;
    if res == nil then return true; end
    if not M.fits(entry, slotName) then return false; end
    if ctx == nil then return true; end
    if ctx.job and ctx.job > 0 and res.Jobs ~= nil and res.Jobs ~= 0 then
        if not bit_test(res.Jobs, ctx.job) then return false; end
    end
    if ctx.level and res.Level ~= nil and res.Level > 0 and res.Level > ctx.level then
        return false;
    end
    -- Measured in game 2026-08-23: Hume M gear reads Races = 2 on a Hume M
    -- character, so the bit is the race id itself, not id - 1.
    if ctx.race and ctx.race > 0 and res.Races ~= nil and res.Races ~= 0 then
        if not bit_test(res.Races, ctx.race) then return false; end
    end
    return true;
end

-- Resolve one slot's declaration to a bag entry. Declarations are a name, or a
-- list of names tried in order so a set survives losing a piece of gear.
function M.pick(declaration, slotName, bags, ctx, used)
    local candidates = {};
    if type(declaration) == 'string' then
        candidates[1] = declaration;
    elseif type(declaration) == 'table' then
        for _, entry in ipairs(declaration) do candidates[#candidates + 1] = entry; end
    end

    local fallback = nil;
    for _, candidate in ipairs(candidates) do
        local key = normalizeName(candidate);
        if EMPTY[key] then return 'remove'; end
        for _, entry in ipairs(bags[key] or {}) do
            local token = entry.Container .. ':' .. entry.Index;
            if not (used and used[token]) and M.fits(entry, slotName) then
                if M.usable(entry, slotName, ctx) then
                    if used then used[token] = true; end
                    return entry;
                end
                fallback = fallback or entry;
            end
        end
    end

    if fallback ~= nil then
        local token = fallback.Container .. ':' .. fallback.Index;
        if used then used[token] = true; end
        return fallback, 'unverified';
    end
    return nil;
end

-- ------------------------------------------------------------------ current

function M.currentSlot(slotName)
    local equipped = compat.equippedItem(slots.id[slotName]);
    if equipped == nil then return nil; end
    local packed = equipped.Index or 0;
    local index = packed % 256;
    if index == 0 then return nil; end
    local container = math.floor(packed / 256);
    local item = compat.containerItem(container, index);
    if item == nil or (item.Id or 0) == 0 then return nil; end
    return { Container = container, Index = index, Id = item.Id };
end

-- ------------------------------------------------------------------ packets

local function equipPacket(index, slotId, container)
    local packet = { 0, 0, 0, 0, 0, 0, 0, 0 };
    packet[5] = index;
    packet[6] = slotId;
    packet[7] = container;
    return packet;
end

local function equipSetPacket(actions)
    local packet = {};
    for i = 1, 72 do packet[i] = 0; end
    packet[5] = #actions;
    for position, action in ipairs(actions) do
        local offset = 4 + (position * 4) + 1;
        packet[offset]     = action.index;
        packet[offset + 1] = action.slotId;
        packet[offset + 2] = action.container;
    end
    return packet;
end
M.equipPacket = equipPacket;
M.equipSetPacket = equipSetPacket;

-- Work out the minimum set of changes and send them. Returns the action list so
-- the tests (and /vgear debug) can see exactly what would go out.
function M.apply(doc, setMap, opts)
    opts = opts or {};
    local bags = opts.bags or M.snapshotBags();
    local ctx  = opts.ctx or {
        job   = compat.mainJob(),
        level = compat.mainJobLevel(),
        race  = compat.playerRace(),
    };

    local used = {};
    -- Reserve what is already on, so a slot that is not changing cannot have
    -- its item stolen by another slot in the same swap.
    for _, slotName in ipairs(slots.order) do
        local current = M.currentSlot(slotName);
        if current ~= nil then used[current.Container .. ':' .. current.Index] = true; end
    end

    local actions = {};
    local misses  = {};
    for _, slotName in ipairs(slots.order) do
        local declaration = setMap[slotName];
        if declaration ~= nil and not doc.locks[slotName] then
            local current = M.currentSlot(slotName);
            if current ~= nil then used[current.Container .. ':' .. current.Index] = nil; end

            local pick, flag = M.pick(declaration, slotName, bags, ctx, used);
            if pick == 'remove' then
                if current ~= nil then
                    actions[#actions + 1] = {
                        slot = slotName, slotId = slots.id[slotName],
                        index = 0, container = current.Container, name = 'remove',
                    };
                end
            elseif pick == nil then
                misses[#misses + 1] = slotName;
                if current ~= nil then used[current.Container .. ':' .. current.Index] = true; end
            elseif current ~= nil and current.Container == pick.Container and current.Index == pick.Index then
                used[pick.Container .. ':' .. pick.Index] = true; -- already worn
            else
                if current ~= nil then used[current.Container .. ':' .. current.Index] = true; end
                actions[#actions + 1] = {
                    slot = slotName, slotId = slots.id[slotName],
                    index = pick.Index, container = pick.Container,
                    id = pick.Id, unverified = (flag == 'unverified'),
                };
            end
        end
    end

    if #actions == 0 then return actions, misses; end

    if doc.settings.equipset and #actions > 1 then
        compat.sendPacket(0x51, equipSetPacket(actions));
    else
        for _, action in ipairs(actions) do
            compat.sendPacket(0x50, equipPacket(action.index, action.slotId, action.container));
        end
    end
    return actions, misses;
end

-- What the player is wearing right now, as a saveable set.
function M.capture()
    local set = {};
    for _, slotName in ipairs(slots.order) do
        local current = M.currentSlot(slotName);
        if current ~= nil then
            set[slotName] = compat.itemName(current.Id);
        end
    end
    return set;
end

return M;
