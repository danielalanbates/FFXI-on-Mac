# Getting an account, per world

Every private server runs its own account database. The launcher cannot create accounts, so the
hero column carries a permanent **Getting an account** card: the selected world's route plus a
button, and a "Every other world" list with a link for each of the other nine.

Sourced 2026-08-21, each against the server's own site (Discord invites resolved live through
`https://discord.com/api/v9/invites/<code>`, which returns the guild name). Anything not verified
is written as unknown rather than guessed.

| World | Signup route | Link in the launcher |
|---|---|---|
| HorizonXI | Web form (`/register` is a real route in their SPA bundle) | https://horizonxi.com/register |
| CatsEyeXI | Web form; the site account then issues the game account | https://www.catseyexi.com/register |
| FFEra | Web form, their Register tab | https://www.ffera.com/?p=register |
| Gaia XI | Web account, which also gates their client download | https://gaiaxi.com/account/index.xi |
| ValhallaXI | **No signup page.** Account is created in the loader console; UCP manages it after | https://ucp.valhalla.group/ |
| Eden | **No signup page.** Their Discord bot issues a registration code (`!getcode`, 7 digits, 10 minutes), then the account is created in the loader console | Discord only (invite `S3EAWr2Jec`, guild "Eden") |
| Supernova | **No signup page.** Loader console, then linked to Discord from their Get Started guide | Discord only (invite `QBBdfQh`) |
| OmicronXI | No signup form published; omicronffxi.com is behind a Cloudflare challenge | https://omicronxi.fandom.com/wiki/Connecting_to_OmicronXI |
| Tabula Rasa XI | None — tabularasaxi.com is a parked domain | none |
| Local server | Loader console, on your own machine | none |

## Why some worlds get no "Create account" button

Because pointing at a page that cannot create an account is worse than saying there is none.
Four of these worlds put account creation in the xiloader console that opens when you press
Play — that is where the account is typed, and the card says exactly that. Discord is offered as
a secondary link, never as the account route.

## Where this lives in the code

- `Server.accountURL` / `accountHow` / `discordURL` — `app/Sources/HorizonXILauncher/Servers.swift`.
  All three are decoded with `decodeIfPresent` and back-filled from `builtins` for any world the
  user has not renamed, so an older `servers.json` picks them up without a reset.
- `accountCard`, `signupVerb` — `App.swift`. `signupVerb` names what the link actually is
  ("Create account" only for a real registration form). Since beta 59 the card shows only while
  no account is saved for the selected world (`Credentials.hasSavedAccount`), never for the local
  world, and the "every other world" list (`signupRow`, `FFXI_ON_MAC_SHOW_SIGNUPS`) is gone.

## Notes for whoever picks this up

- The hero column is a ScrollView now. It had to be: with the list open the cards overflow a
  632pt window, and an overflowing VStack pushes the game's title off the top rather than
  clipping the bottom.
- A `ScrollView` inside a plain `VStack` asks for zero height and renders as an empty gap — the
  list needs an explicit `.frame(height:)`.
- Eden's site is a client-rendered SPA with no signup route in its bundle; if Eden ever ships one,
  it is a one-line change to `accountURL`.
- horizonxi.com's SPA bundle also lists a `/news` route. Nobody has checked whether an actual news
  endpoint sits behind it; if one does, `ServerFeeds.parseFeed` is already written for it.
