-- Vanagear :: every call into Ashita goes through here.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
--
-- The addon has to survive Ashita API drift and running head-less in the test
-- harness, so nothing below is allowed to throw. A missing field degrades to a
-- sane default instead of dropping the player out of the game mid-fight.

local M = {};

local function try(fn, fallback)
    local ok, result = pcall(fn);
    if not ok or result == nil then return fallback; end
    return result;
end
M.try = try;

local function core()
    return _G.AshitaCore;
end

function M.available()
    return core() ~= nil;
end

function M.memory()
    return try(function() return core():GetMemoryManager(); end, nil);
end

function M.resources()
    return try(function() return core():GetResourceManager(); end, nil);
end

function M.inventory()
    return try(function() return M.memory():GetInventory(); end, nil);
end

function M.player()
    return try(function() return M.memory():GetPlayer(); end, nil);
end

-- GetInstallPath comes back with a trailing separator on this build, which
-- doubles up when a path is joined onto it.
function M.installPath()
    local path = try(function() return core():GetInstallPath(); end, '.');
    return (path:gsub('[\\/]+$', ''));
end

function M.print(text)
    local ok = pcall(function()
        print(('\30\03[Vanagear]\30\01 %s'):format(text));
    end);
    if not ok then print('[Vanagear] ' .. tostring(text)); end
end

function M.mainJob()
    return try(function() return M.player():GetMainJob(); end, 0);
end

function M.subJob()
    return try(function() return M.player():GetSubJob(); end, 0);
end

function M.mainJobLevel()
    return try(function() return M.player():GetMainJobLevel(); end, 99);
end

-- 0 idle, 1 engaged, 2/3 dead, 33 resting. Anything else is treated as idle.
function M.status()
    return try(function() return M.player():GetStatus(); end, 0);
end

function M.isZoning()
    return try(function() return M.player():GetIsZoning() ~= 0; end, false);
end

-- Measured in game 2026-08-23: GetString returns nil for 'jobs', 'jobs_abbr'
-- and every other spelling tried, so the profile filename came out "JOB1".
-- These twenty-two never change; the resource lookup stays first in case a
-- build does answer it.
local JOBS = {
    [0] = 'NON',
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD',
    'RNG', 'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH',
    'GEO', 'RUN',
};
M.JOBS = JOBS;

-- 'jobs.names_abbr' is the spelling that actually answers; the others were
-- tried in game and returned nil.
function M.jobName(id)
    local name = try(function()
        local text = M.resources():GetString('jobs.names_abbr', id)
            or M.resources():GetString('jobs_abbr', id);
        if type(text) == 'string' then
            text = text:gsub('%z.*$', '');
            if #text > 0 then return text; end
        end
        return nil;
    end, nil);
    return name or JOBS[id] or ('JOB' .. tostring(id));
end

function M.playerName()
    return try(function()
        return M.memory():GetParty():GetMemberName(0);
    end, nil) or 'unknown';
end

function M.playerRace()
    return try(function()
        local party = M.memory():GetParty();
        local index = party:GetMemberTargetIndex(0);
        return M.memory():GetEntity():GetRace(index);
    end, 0);
end

function M.itemResource(id)
    if id == nil or id == 0 then return nil; end
    return try(function() return M.resources():GetItemById(id); end, nil);
end

-- Measured in game 2026-08-23: res.Name is userdata, not a table, and LogName
-- does not exist on this build. Indexing it works; type-checking it does not,
-- and a type check here silently emptied the entire bag index.
function M.itemNames(res)
    local names = {};
    if res == nil then return names; end
    for _, field in ipairs({ 'Name', 'LogName' }) do
        for index = 1, 3 do
            local value = try(function() return res[field][index]; end, nil);
            if type(value) == 'string' then
                value = value:gsub('%z.*$', '');
                if #value > 0 then names[#names + 1] = value; end
            end
        end
    end
    return names;
end

function M.itemName(id)
    local res = M.itemResource(id);
    return M.itemNames(res)[1] or ('#' .. tostring(id));
end

function M.spellResource(id)
    return try(function() return M.resources():GetSpellById(id); end, nil);
end

function M.abilityResource(id)
    return try(function() return M.resources():GetAbilityById(id); end, nil);
end

function M.skillName(id)
    if id == nil or id == 0 then return nil; end
    local name = try(function() return M.resources():GetString('skills', id); end, nil);
    if type(name) == 'string' then
        name = name:gsub('%z.*$', '');
        if #name > 0 then return name; end
    end
    return nil;
end

function M.containerCount(container)
    return try(function() return M.inventory():GetContainerCount(container); end, 0);
end

function M.containerItem(container, index)
    return try(function() return M.inventory():GetContainerItem(container, index); end, nil);
end

function M.equippedItem(slotId)
    return try(function() return M.inventory():GetEquippedItem(slotId); end, nil);
end

-- ----------------------------------------------------------- live conditions
--
-- Everything below feeds condition tokens. Each is wrapped so that a build
-- which does not answer simply produces no token, rather than an error.

function M.hpPercent()
    return try(function() return M.memory():GetParty():GetMemberHPPercent(0); end, nil);
end

function M.mpPercent()
    return try(function() return M.memory():GetParty():GetMemberMPPercent(0); end, nil);
end

function M.tp()
    return try(function() return M.memory():GetParty():GetMemberTP(0); end, nil);
end

local lastX, lastY, movingUntil = nil, nil, 0;

-- Position is only sampled when asked, so "moving" means "moved since the last
-- time this was called", held briefly so it does not flicker between frames.
function M.isMoving()
    local ok = pcall(function()
        local party  = M.memory():GetParty();
        local entity = M.memory():GetEntity();
        local index  = party:GetMemberTargetIndex(0);
        local x, y = entity:GetLocalPositionX(index), entity:GetLocalPositionY(index);
        if lastX ~= nil and (x ~= lastX or y ~= lastY) then
            movingUntil = os.clock() + 0.75;
        end
        lastX, lastY = x, y;
    end);
    if not ok then return false; end
    return os.clock() < movingUntil;
end

-- Vana'diel day and weather need a memory signature scan, which this project
-- has not done. They are the one condition family that is unavailable; see
-- docs/PATHWAYS.md.
function M.dayElement()
    return nil;
end

function M.weatherElement()
    return nil;
end

function M.sendPacket(id, data)
    return pcall(function()
        core():GetPacketManager():AddOutgoingPacket(id, data);
    end);
end

return M;
