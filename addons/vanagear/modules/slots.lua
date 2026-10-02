-- Vanagear :: slot and container tables.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

local M = {};

-- Equipment slot ids as the game numbers them. Order matters: it is the order
-- sets are printed in and the order equip packets are queued in.
M.order = {
    'main', 'sub', 'range', 'ammo',
    'head', 'body', 'hands', 'legs', 'feet',
    'neck', 'waist', 'ear1', 'ear2', 'ring1', 'ring2', 'back',
};

M.id = {
    main = 0, sub = 1, range = 2, ammo = 3,
    head = 4, body = 5, hands = 6, legs = 7, feet = 8,
    neck = 9, waist = 10, ear1 = 11, ear2 = 12,
    ring1 = 13, ring2 = 14, back = 15,
};

M.name = {};
for k, v in pairs(M.id) do M.name[v] = k; end

-- Spellings people actually type in a macro.
M.alias = {
    weapon = 'main', mainhand = 'main', offhand = 'sub', shield = 'sub',
    ranged = 'range', bullet = 'ammo', arrow = 'ammo',
    hand = 'hands', glove = 'hands', gloves = 'hands',
    leg = 'legs', pants = 'legs', foot = 'feet', boots = 'feet',
    earring1 = 'ear1', earring2 = 'ear2', lear = 'ear1', rear = 'ear2',
    ear = 'ear1', ring = 'ring1', lring = 'ring1', rring = 'ring2',
    cape = 'back', mantle = 'back', belt = 'waist',
};

-- Resolve whatever the player typed to a canonical slot name, or nil.
function M.resolve(text)
    if type(text) ~= 'string' then return nil; end
    local key = text:lower():gsub('[^%a%d]', '');
    if M.id[key] ~= nil then return key; end
    return M.alias[key];
end

-- Containers that gear can legally be equipped straight out of.
M.containers = { 0, 8, 10, 11, 12, 13, 14, 15, 16 };

return M;
