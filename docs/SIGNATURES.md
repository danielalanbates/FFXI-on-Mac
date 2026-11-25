# Repairing a stale Ashita signature

Ashita finds the game's functions and tables by scanning `FFXiMain.dll` for byte patterns.
When Square Enix recompiles the client, patterns go stale: the pointer resolves to 0, the
addon that needed it stops working, and **nothing says so where a player would see it**. This
is the record of finding and fixing two of them on client `30251101_2`, so the next one takes
an hour instead of a day.

Fixed here, and shipped as `patches/ashita/custom.pointers.ini`:

| pointer | was | is | what broke without it |
| --- | --- | --- | --- |
| `packets.queuepacket1` | not found | `01D9BFB0` (rva `0xFBFB0`) | `AddOutgoingPacket` was a silent no-op **for every addon** |
| `player.haskeyitem` | not found | `01D279BB` (rva `0x879BB`) | key-item lookups |

## Why you cannot scan the file on disk

`FFXiMain.dll`'s `.text` section has a **raw size of zero**. The code is not in the file; the
`POL1` section unpacks it at run time. So every pattern in `ashita.pointers.ini` matches
nothing at all when tested against the file, including the ones that work perfectly in game.
An hour can go into concluding "the whole packet subsystem changed" from that.

    .text   vsize 0x32542E  vaddr 0x1000    rawsize 0x0        <-- nothing on disk
    .rdata  vsize 0x253F5   vaddr 0x327000  rawsize 0x26000
    POL1    vsize 0x1E49C8  vaddr 0x9CA000  rawsize 0x1E4A00   <-- the unpacker

The bytes only exist inside a live process, which is why the tool is an addon.

## The tool: `addons/sigscan`

    /sigscan info                     module base and .text bounds, read from the PE headers
    /sigscan find <pattern> [off] [n] run Ashita's own scanner and report the address
    /sigscan dump <hexaddr> <hexlen>  raw bytes to a file
    /sigscan text                     the whole .text section (about 3.3 MB, a few seconds)

Then disassemble the dump off to one side. Anything that reads 32-bit x86 will do:

    python3 -m venv venv && ./venv/bin/pip install capstone

## The method that worked

Start from what still resolves. Only two pointers failed, so the module had not moved --
`packets.queuepacket2` resolved at `01D7DA60`, and that is a foothold.

1. **Find the neighbours.** Scan the dump for `E8` call sites whose target is the working
   function. `queuepacket2`'s twenty callers are the "build packet X and send it" routines.
2. **Read one caller.** Each one allocates, fills, then stamps:

        push 1 ; push 1 ; push 0Dh
        call 01D9BFB0            <-- the allocator: this is queuepacket1
        mov word ptr [eax+4], 0
        push 0 ; push 8 ; push eax
        call 01D7DA60            <-- queuepacket2, the known-good one

3. **Compare against the stale pattern.** The function was byte-for-byte what Ashita expects
   apart from one constant:

        01D9BFB0  A128DB1702      mov eax, ds:[0217DB28]
        01D9BFB5  56              push esi
        01D9BFB6  85C0            test eax, eax
        01D9BFB8  57              push edi
        01D9BFB9  0F84DD000000    je   fail
        01D9BFBF  8B74240C        mov  esi, [esp+0Ch]     ; packet id
        01D9BFC3  81FE1E010000    cmp  esi, 11Eh          ; <-- Ashita expects 120h
        01D9BFC9  0F8DCD000000    jge  fail

   The packet-id table went from 0x120 entries to 0x11E. **One byte**, and every addon on the
   client lost the ability to send anything.

4. **Wildcard what moved, then prove it is unique.** `81FE????????` matches exactly once in
   `.text`, so the next change to that bound will not break the scan again.

## Verifying

Restart and read the log -- this is the only place the answer appears:

    PointerManager::Update | Pointer: (01D9BFB0) [Ok!] packets.queuepacket1
    PacketManager::Update  | <End> [Status: Ok!]

Then prove it end to end, because a resolved pointer is not a sent packet. Send something and
watch it leave (`injected=true` in a `packet_out` log), then check the **server** received it.
Ours did, and rejected it, and that log line was worth more than everything before it:

    [map][warn] Bad packet size for GP_CLI_COMMAND_ACTION (0x01a) from Test:
                 got 16, expected [28, 28]

Injection was working perfectly; the packet was the wrong length. From inside the client those
two look identical. Read the server's log.

## Notes for whoever is next

- A pointer that fails is logged **once, at startup, at DEBUG**. Grep for `[Error!]` after
  every client update; it is the cheapest possible check.
- `custom.pointers.ini` overrides `ashita.pointers.ini` and survives Ashita updates. Never
  edit the stock file.
- Two pointers went stale in this client generation. If a third appears, the method above does
  not care which one it is.

Copyright (c) 2026 Bates LLC. All rights reserved. https://batesai.org -- help@batesai.org
