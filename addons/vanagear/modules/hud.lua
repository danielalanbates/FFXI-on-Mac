-- Vanagear :: the panel. Point at a set, click, wear it.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
--
-- The addon is usable with nothing but macros and that stays true. This window
-- is for the part macros are genuinely bad at: seeing every set at once,
-- checking a set against what you actually still own, and fixing one slot
-- without retyping its name.

local compat  = require('modules.compat');
local engine  = require('modules.engine');
local rules   = require('modules.rules');
local gear    = require('modules.gear');
local profile = require('modules.profile');
local slots   = require('modules.slots');

local M = {};

local imgui = nil;   -- resolved lazily; absent in the head-less tests
local function ui()
    if imgui == nil then
        local ok, module = pcall(require, 'imgui');
        imgui = ok and module or false;
    end
    return imgui or nil;
end

M.open      = { false };
M.selected  = nil;      -- set name
M.newName   = { '' };
M.newMode   = { '' };
M.filter    = { '' };
M.status    = '';       -- one-line result of the last button pressed
M.showLocks = { false };

local GREEN = { 0.55, 0.85, 0.55, 1.0 };
local RED   = { 0.90, 0.45, 0.45, 1.0 };
local GREY  = { 0.60, 0.60, 0.60, 1.0 };

M.sizeFrames = 0;

function M.toggle(value)
    local before = M.open[1];
    if value == nil then
        M.open[1] = not M.open[1];
    else
        M.open[1] = value and true or false;
    end
    -- Opening re-asserts the size for a few frames. FirstUseEver is no help
    -- once ImGui has remembered an oversized window from an earlier session.
    if M.open[1] and not before then M.sizeFrames = 3; end
    return M.open[1];
end

-- --------------------------------------------------------------- small parts

local function sortedSets(doc, filter)
    local names = {};
    for name in pairs(doc.sets) do
        if filter == nil or filter == '' or name:find(filter, 1, true) then
            names[#names + 1] = name;
        end
    end
    table.sort(names);
    return names;
end

local function declarationText(value)
    if type(value) == 'table' then return table.concat(value, ' | '); end
    return tostring(value);
end

-- Is the first candidate for this slot actually in a bag right now?
local function ownership(value, slotName, bags)
    local candidates = (type(value) == 'table') and value or { value };
    for index, candidate in ipairs(candidates) do
        local key = gear.normalizeName(candidate);
        if key == 'remove' or key == 'none' or key == 'empty' or key == '-' then
            return 'remove', candidate;
        end
        if bags[key] ~= nil then
            return (index == 1) and 'have' or 'fallback', candidate;
        end
    end
    return 'missing', candidates[1];
end

-- ------------------------------------------------------------------- panes

local function drawSetList(gui, session)
    local doc = session.doc;
    gui.Text('Sets');
    gui.SameLine();
    gui.TextDisabled('(filter)');
    gui.PushItemWidth(176);
    gui.InputText('##vgfilter', M.filter, 32);
    gui.PopItemWidth();

    -- Two arguments only: this build's binding has no border parameter, and a
    -- third argument is a hard sol error rather than an ignored extra.
    gui.BeginChild('##vgsetlist', { 176, 186 });
    local names = sortedSets(doc, M.filter[1]);
    if #names == 0 then
        gui.TextDisabled('none yet');
    end
    local active = engine.tokens();
    for _, name in ipairs(names) do
        if gui.Selectable(name, name == M.selected) then
            M.selected = name;
        end
        -- Show at a glance whether a conditional set could fire right now.
        local _, tokens = rules.parse(name);
        if #tokens > 0 then
            local live = true;
            for _, token in ipairs(tokens) do
                if not active[token] then live = false; break; end
            end
            gui.SameLine();
            if live then gui.TextColored(GREEN, '*'); else gui.TextDisabled('*'); end
        end
    end
    gui.EndChild();

    gui.PushItemWidth(176);
    gui.InputText('##vgnewset', M.newName, 48);
    gui.PopItemWidth();
    if gui.Button('Save worn as this##vgnew') then
        local key = profile.key(M.newName[1]);
        if key == nil then
            M.status = 'name the set first';
        else
            doc.sets[key] = profile.sanitizeSet(gear.capture());
            session.save();
            M.selected = key;
            M.newName[1] = '';
            M.status = 'saved ' .. key .. ' from what you are wearing';
        end
    end
end

local function drawSetDetail(gui, session, bags)
    local doc = session.doc;
    -- Land on something rather than an empty pane: the first set, alphabetically.
    if M.selected == nil or doc.sets[M.selected] == nil then
        M.selected = sortedSets(doc, nil)[1];
    end
    local name = M.selected;
    if name == nil or doc.sets[name] == nil then
        gui.TextDisabled('Pick a set on the left, or save what you are wearing as a new one.');
        return;
    end
    local set = doc.sets[name];

    gui.Text(name);
    gui.SameLine();
    gui.TextDisabled(('(%s)'):format(session.label));

    if gui.Button('Equip##vgequip') then
        local actions = engine.equipNamed(name);
        M.status = (actions == nil) and 'nothing in that set'
            or ('equipped %s, %d change(s)'):format(name, #actions);
    end
    gui.SameLine();
    if gui.Button('From worn##vgover') then
        doc.sets[name] = profile.sanitizeSet(gear.capture());
        session.save();
        M.status = name .. ' now holds what you are wearing';
    end
    gui.SameLine();
    if gui.Button('Copy##vgdup') then
        local copy = {};
        for slot, value in pairs(set) do copy[slot] = value; end
        local target = name .. ' copy';
        doc.sets[target] = copy;
        session.save();
        M.selected = target;
        M.status = 'copied to ' .. target;
    end
    gui.SameLine();
    if gui.Button('Delete##vgdel') then
        doc.sets[name] = nil;
        session.save();
        M.selected = nil;
        M.status = 'deleted ' .. name;
        return;
    end

    gui.Separator();

    -- One row per slot: what the set asks for, whether you still own it, and
    -- the two edits worth making without typing - take the worn item, or clear.
    for _, slotName in ipairs(slots.order) do
        local value = set[slotName];
        gui.Text(('%-6s'):format(slotName));
        gui.SameLine(70);

        if value == nil then
            gui.TextColored(GREY, '-');
        else
            local state = ownership(value, slotName, bags);
            local text = declarationText(value);
            if state == 'have' then
                gui.TextColored(GREEN, text);
            elseif state == 'fallback' then
                gui.TextColored(GREEN, text);
                gui.SameLine();
                gui.TextDisabled('(on fallback)');
            elseif state == 'remove' then
                gui.TextDisabled('(empty this slot)');
            else
                gui.TextColored(RED, text);
                gui.SameLine();
                gui.TextDisabled('(not in your bags)');
            end
        end

        gui.SameLine(300);
        if gui.SmallButton('worn##vgtake' .. slotName) then
            local current = gear.currentSlot(slotName);
            if current == nil then
                set[slotName] = 'remove';
            else
                set[slotName] = compat.itemName(current.Id);
            end
            session.save();
            M.status = ('%s.%s set from what you are wearing'):format(name, slotName);
        end
        gui.SameLine();
        if gui.SmallButton('x##vgclear' .. slotName) then
            set[slotName] = nil;
            session.save();
            M.status = ('%s.%s cleared'):format(name, slotName);
        end
    end
end

local function drawModes(gui, session)
    local doc = session.doc;
    local groups = {};
    for group in pairs(doc.modes) do groups[#groups + 1] = group; end
    table.sort(groups);

    for _, group in ipairs(groups) do
        gui.Text(('%-10s'):format(group));
        gui.SameLine(90);
        for index, value in ipairs(doc.modes[group]) do
            if index > 1 then gui.SameLine(); end
            local active = (doc.active[group] or 'normal') == value;
            local label = (active and '[' .. value .. ']' or ' ' .. value .. ' ')
                .. '##vgmode' .. group .. value;
            if gui.Button(label) then
                doc.active[group] = value;
                session.save();
                engine.busyUntil = 0;
                engine.nextTick = 0;
                M.status = ('%s = %s'):format(group, value);
            end
        end
    end

    gui.PushItemWidth(140);
    gui.InputText('##vgnewmode', M.newMode, 48);
    gui.PopItemWidth();
    gui.SameLine();
    gui.TextDisabled('group value');
    gui.SameLine();
    if gui.Button('Add mode##vgaddmode') then
        local group, value = M.newMode[1]:match('^%s*(%S+)%s+(%S+)%s*$');
        if group == nil then
            M.status = 'type "group value", e.g. offense acc';
        else
            group, value = group:lower(), value:lower();
            local list = doc.modes[group] or { 'normal' };
            local known = false;
            for _, entry in ipairs(list) do if entry == value then known = true; end end
            if not known then list[#list + 1] = value; end
            doc.modes[group] = list;
            doc.active[group] = value;
            session.save();
            M.newMode[1] = '';
            M.status = ('%s = %s'):format(group, value);
        end
    end
end

local function drawSwitches(gui, session)
    local doc = session.doc;
    local order = { 'auto', 'precast', 'equipset', 'conditions', 'debug' };
    for index, key in ipairs(order) do
        if index > 1 then gui.SameLine(); end
        local box = { doc.settings[key] };
        if gui.Checkbox(key .. '##vgsw' .. key, box) then
            doc.settings[key] = box[1];
            session.save();
            M.status = ('%s %s'):format(key, box[1] and 'on' or 'off');
        end
    end

    gui.Checkbox('show slot locks##vglockshow', M.showLocks);
    if M.showLocks[1] then
        for index, slotName in ipairs(slots.order) do
            if index % 4 ~= 1 then gui.SameLine(); end
            local box = { doc.locks[slotName] == true };
            if gui.Checkbox(slotName .. '##vglock' .. slotName, box) then
                doc.locks[slotName] = box[1] and true or nil;
                session.save();
                M.status = slotName .. (box[1] and ' locked' or ' unlocked');
            end
        end
    end
end

local function drawConditions(gui)
    local active = engine.tokens();
    local names = {};
    for token in pairs(active) do names[#names + 1] = token; end
    table.sort(names);
    if #names == 0 then
        gui.TextDisabled('nothing is true right now');
    else
        gui.Text(table.concat(names, ', '));
    end
    gui.TextDisabled('name a set "<set>:<token>" to make it conditional');
end

local function drawWhy(gui)
    local last = engine.lastChain;
    if last == nil or last.event == nil then
        gui.TextDisabled('nothing has swapped yet');
        return;
    end
    gui.Text(('last: %s %s'):format(last.event.kind, last.event.name or ''));
    gui.TextDisabled('considered: ' .. table.concat(last.considered, ', '));
    gui.Text('matched: ' .. ((#last.matched > 0) and table.concat(last.matched, ' > ') or 'none'));
end

-- ------------------------------------------------------------------- render

local function body(gui, session)
    local bags = gear.snapshotBags();

    gui.BeginChild('##vgleft', { 190, 290 });
    drawSetList(gui, session);
    gui.EndChild();

    gui.SameLine();

    gui.BeginChild('##vgright', { 370, 290 });
    drawSetDetail(gui, session, bags);
    gui.EndChild();

    gui.Separator();
    if gui.CollapsingHeader('Modes##vgmodes') then drawModes(gui, session); end
    if gui.CollapsingHeader('Conditions##vgconds') then drawConditions(gui); end
    if gui.CollapsingHeader('Switches##vgswitches') then drawSwitches(gui, session); end
    if gui.CollapsingHeader('Why##vgwhy') then drawWhy(gui); end

    if M.status ~= '' then
        gui.Separator();
        gui.TextDisabled(M.status);
    end
end

-- A UI fault must never take the addon down with it, so the whole frame runs
-- inside a pcall and reports once rather than every frame.
local reported = false;
function M.render(session)
    if not M.open[1] then return; end
    local gui = ui();
    if gui == nil then return; end

    -- Without a starting size the window grew wider than the game window on
    -- first open. FirstUseEver, so a player who drags it keeps their size.
    -- Without this the window opened wider than the game window itself, and a
    -- FirstUseEver condition could not shrink one ImGui had already remembered.
    if M.sizeFrames > 0 then
        M.sizeFrames = M.sizeFrames - 1;
        pcall(function() gui.SetNextWindowSize({ 600, 430 }); end);
    end

    local ok, err = pcall(function()
        if gui.Begin(('Vanagear %s - %s'):format(_G.addon and addon.version or '?', session.label or ''), M.open) then
            body(gui, session);
        end
        gui.End();
    end);

    if not ok and not reported then
        reported = true;
        compat.print('panel error, closing it: ' .. tostring(err));
        M.open[1] = false;
    end
end

return M;
