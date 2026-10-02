-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

addon.name    = 'winecursor';
addon.author  = 'Bates LLC';
addon.version = '1.0';
addon.desc    = 'Keep the FFXI mouse cursor visible under Wine.';
addon.link    = 'https://batesai.org';

local ffi = require('ffi');

ffi.cdef[[
int ShowCursor(int show);
void* LoadCursorA(void* instance, const char* name);
void* SetCursor(void* cursor);
]]

local target = 1;
local arrow = nil;
local arrow_id = ffi.cast('const char*', 32512);

ashita.events.register('d3d_present', 'winecursor_present', function ()
    if arrow == nil then arrow = ffi.C.LoadCursorA(nil, arrow_id); end
    if arrow ~= nil then ffi.C.SetCursor(arrow); end

    local count = ffi.C.ShowCursor(1);
    local guard = 0;
    while count > target and guard < 16 do
        count = ffi.C.ShowCursor(0);
        guard = guard + 1;
    end
    while count < target and guard < 32 do
        count = ffi.C.ShowCursor(1);
        guard = guard + 1;
    end
end);
