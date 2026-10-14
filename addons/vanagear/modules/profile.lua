-- Vanagear :: the on-disk document. Sets, modes, locks, settings.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
--
-- The player never edits this file. The addon writes it in response to macro
-- commands, which is the whole point of the project: the gear lives in the game,
-- not in a Lua profile the player has to hand-maintain.

local compat = require('modules.compat');
local slots  = require('modules.slots');

local M = {};

M.VERSION = 1;

local function defaults()
    return {
        version  = M.VERSION,
        sets     = {},   -- ['ws.rampage'] = { head = 'Walahra Turban', ... }
        modes    = {},   -- ['offense'] = { 'normal', 'acc' }
        active   = {},   -- ['offense'] = 'acc'
        locks    = {},   -- ['main'] = true
        settings = {
            auto     = true,   -- intercept actions and swap automatically
            precast  = true,   -- hold the action packet to land precast gear
            equipset = true,   -- batch swaps into one 0x51 instead of many 0x50
            hud      = false,  -- panel open, remembered between sessions
            conditions = true, -- derive tokens from hp/mp/tp/movement/sub-job
            debug    = false,
        },
    };
end
M.defaults = defaults;

-- ---------------------------------------------------------------- serializing

local function quote(text)
    return ('%q'):format(text):gsub('\\\n', '\\n');
end

local function isArray(tbl)
    local count = 0;
    for key in pairs(tbl) do
        if type(key) ~= 'number' then return false; end
        count = count + 1;
    end
    return count == #tbl;
end

local function serialize(value, indent)
    local pad = ('    '):rep(indent);
    local t = type(value);
    if t == 'string' then return quote(value); end
    if t == 'number' or t == 'boolean' then return tostring(value); end
    if t ~= 'table' then return 'nil'; end

    local out = {};
    if isArray(value) then
        for _, item in ipairs(value) do
            out[#out + 1] = pad .. '    ' .. serialize(item, indent + 1) .. ',';
        end
    else
        local keys = {};
        for key in pairs(value) do keys[#keys + 1] = key; end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b); end);
        for _, key in ipairs(keys) do
            local name;
            if type(key) == 'string' and key:match('^[%a_][%w_]*$') then
                name = key;
            elseif type(key) == 'string' then
                name = '[' .. quote(key) .. ']';
            else
                name = '[' .. tostring(key) .. ']';
            end
            out[#out + 1] = ('%s    %s = %s,'):format(pad, name, serialize(value[key], indent + 1));
        end
    end
    if #out == 0 then return '{}'; end
    return '{\n' .. table.concat(out, '\n') .. '\n' .. pad .. '}';
end
M.serialize = serialize;

-- ------------------------------------------------------------------ file i/o

-- '\\' under Ashita on Windows, '/' in the head-less test harness.
local SEP = package.config:sub(1, 1);
M.SEP = SEP;

function M.directory()
    return table.concat({ compat.installPath(), 'config', 'addons', 'vanagear' }, SEP);
end

-- Character-and-job scoped, so BLM sets never collide with WAR sets.
function M.path(character, job)
    local safe = (character or 'unknown'):gsub('[^%w]', '');
    return ('%s%s%s_%s.lua'):format(M.directory(), SEP, safe, job or 'NON');
end

-- Measured in game 2026-08-23: `ashita.file` does not exist on this build and
-- os.execute does nothing, so the config directory was never created and every
-- write failed. `ashita.fs.create_dir` is the one that works, and it creates
-- intermediate directories.
local function ensureDirectory(dir)
    local made = false;
    pcall(function() made = ashita.fs.create_dir(dir) and true or made; end);
    pcall(function() made = ashita.fs.create_directory(dir) and true or made; end);
    if not made then
        pcall(function()
            if SEP == '\\' then
                os.execute('mkdir "' .. dir .. '"');
            else
                os.execute('mkdir -p "' .. dir .. '"');
            end
        end);
    end
end

function M.read(path)
    local file = io.open(path, 'r');
    if file == nil then return nil; end
    local body = file:read('*a');
    file:close();
    local chunk = loadstring and loadstring(body) or load(body);
    if chunk == nil then return nil; end
    local ok, data = pcall(chunk);
    if not ok or type(data) ~= 'table' then return nil; end
    return data;
end

function M.write(path, data)
    ensureDirectory(path:match('^(.*)[\\/][^\\/]*$') or '.');
    local file = io.open(path, 'w');
    if file == nil then return false; end
    file:write('-- Vanagear profile. Written by the addon; safe to delete, safe to copy.\n');
    file:write('-- Edit it in game with /vgear rather than by hand.\n');
    file:write('return ' .. serialize(data, 0) .. ';\n');
    file:close();
    return true;
end

-- --------------------------------------------------------------- the document

-- Merges a loaded document onto the defaults so an older file keeps working
-- when a new setting is added.
function M.normalize(data)
    local doc = defaults();
    if type(data) ~= 'table' then return doc; end
    for _, key in ipairs({ 'sets', 'modes', 'active', 'locks' }) do
        if type(data[key]) == 'table' then doc[key] = data[key]; end
    end
    if type(data.settings) == 'table' then
        for key, value in pairs(doc.settings) do
            if type(data.settings[key]) == type(value) then
                doc.settings[key] = data.settings[key];
            end
        end
    end
    return doc;
end

-- Set names are case-insensitive and space-insensitive so a macro can say
-- "/vgear equip WS.Rampage" or "/vgear equip ws.rampage" and mean the same thing.
function M.key(name)
    if type(name) ~= 'string' then return nil; end
    local key = name:lower():gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '');
    if #key == 0 then return nil; end
    return key;
end

-- A set is a plain slot -> item map. Items are a string or a list of strings
-- tried in order, which is how one saved set survives losing a piece of gear.
function M.sanitizeSet(raw)
    local out = {};
    if type(raw) ~= 'table' then return out; end
    for name, value in pairs(raw) do
        local slot = slots.resolve(name);
        if slot ~= nil then
            if type(value) == 'string' then
                out[slot] = value;
            elseif type(value) == 'table' then
                local list = {};
                for _, entry in ipairs(value) do
                    if type(entry) == 'string' then list[#list + 1] = entry; end
                end
                if #list == 1 then out[slot] = list[1];
                elseif #list > 1 then out[slot] = list; end
            end
        end
    end
    return out;
end

return M;
