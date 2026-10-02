-- Vanagear :: which sets apply to what is happening, and in what order.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
--
-- Everything here is pure: an event plus the player's mode state in, an ordered
-- list of set names out. Sets are merged generic-first, so a specific set only
-- has to name the slots it actually changes.

local M = {};

local function push(list, name)
    if name == nil then return; end
    name = tostring(name):lower():gsub('%s+', ' ');
    if #name == 0 then return; end
    list[#list + 1] = name;
end

-- The set that holds while nothing is being cast or swung.
local function baseChain(ctx)
    local list = {};
    push(list, 'idle');
    if ctx.resting then push(list, 'resting'); end
    if ctx.engaged then push(list, 'tp'); end
    return list;
end
M.baseChain = baseChain;

-- Generic -> specific. The last name that exists wins each slot.
function M.chain(event, ctx)
    ctx = ctx or {};
    event = event or {};
    local kind = event.kind or 'base';
    local list = baseChain(ctx);

    local function layer(prefix)
        push(list, prefix);
        if event.skill then push(list, prefix .. '.' .. event.skill); end
        if event.name then push(list, prefix .. '.' .. event.name); end
    end

    if kind == 'base' then
        -- baseChain is the whole story.
    elseif kind == 'precast' then
        layer('precast');
    elseif kind == 'midcast' then
        layer('midcast');
    elseif kind == 'ws' then
        layer('ws');
    elseif kind == 'ja' then
        push(list, 'ja');
        if event.name then push(list, 'ja.' .. event.name); end
    elseif kind == 'preshot' then
        push(list, 'preshot');
    elseif kind == 'midshot' then
        push(list, 'midshot');
        if event.name then push(list, 'midshot.' .. event.name); end
    elseif kind == 'item' then
        push(list, 'item');
        if event.name then push(list, 'item.' .. event.name); end
    else
        layer(kind);
    end

    return list;
end

-- ------------------------------------------------------------ condition tokens
--
-- A set name may carry any number of ":token" suffixes, and the set only
-- applies when every one of its tokens is currently true. "tp:acc" is a mode,
-- "midcast.stone:earthsday" is a day, "idle:moving" is movement gear, and
-- "ws.rampage:acc:tp3000" is all three -- one mechanism instead of a special
-- case per condition.
--
-- The naive way to do this is to enumerate every subset of the active tokens
-- and look each one up, which is 2^n lookups and puts a hard ceiling on how
-- many conditions can exist. This walks the saved names instead: the cost is
-- the number of sets the player has actually saved, and the number of possible
-- tokens stops mattering.

-- "ws.rampage:acc:tp3000" -> "ws.rampage", { "acc", "tp3000" }
function M.parse(name)
    local base = name:match('^([^:]*)');
    local tokens = {};
    for token in name:gmatch(':([^:]+)') do tokens[#tokens + 1] = token; end
    return base, tokens;
end

-- Which saved sets apply, generic first, least specific first. Sets whose
-- tokens are not all currently active are simply not returned.
function M.select(setNames, chain, active)
    active = active or {};
    local position = {};
    for index, base in ipairs(chain) do
        if position[base] == nil then position[base] = index; end
    end

    local matches = {};
    for name in pairs(setNames) do
        local base, tokens = M.parse(name);
        local rank = position[base];
        if rank ~= nil then
            local ok = true;
            for _, token in ipairs(tokens) do
                if not active[token] then ok = false; break; end
            end
            if ok then
                matches[#matches + 1] = { name = name, rank = rank, depth = #tokens };
            end
        end
    end

    -- Chain order first, then how many conditions the set demanded: a set that
    -- asked for more and got it is the more specific answer.
    table.sort(matches, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank; end
        if a.depth ~= b.depth then return a.depth < b.depth; end
        return a.name < b.name;
    end);

    local out = {};
    for _, match in ipairs(matches) do out[#out + 1] = match.name; end
    return out;
end

-- The names the engine will merge, in order. ctx.tokens is the set of
-- conditions that are true right now.
function M.resolve(setNames, event, ctx)
    ctx = ctx or {};
    return M.select(setNames, M.chain(event, ctx), ctx.tokens);
end

return M;
