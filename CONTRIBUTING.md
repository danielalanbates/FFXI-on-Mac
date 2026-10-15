# Contributing

All help welcome, and you do not need to be a programmer to give the most useful kind.

## The most useful thing: test it on your Mac

This project has been tested on exactly one machine — an M1 MacBook Pro with 8 GB of memory. Any
report from a different Mac is genuinely valuable, even "it worked fine".

Open an issue with:

- Mac model and memory (Apple menu → About This Mac)
- macOS version
- Which server you played on
- Roughly what frame rate you got, and where you were standing
- Anything that looked wrong

## Reporting a bug

Include the contents of the log pane at the bottom of the app, and what you were doing when it
happened. The log almost always names the exact file or setting that failed.

If the game won't start at all, open **Setup & Diagnostics** first and paste what the checks say.

## Working on the code

The app is Swift (SwiftUI, built with Swift Package Manager) plus shell and Python scripts. No
Xcode needed — Apple's Command Line Tools are enough.

```sh
./app/bundle.sh ~/Downloads/FFXI-build    # build the .app there (an output folder is required)
HXI_SIGN_ID=<Developer ID SHA-1> ./scripts/package.sh   # signed, notarised .dmg into dist/
```

`app/VERSION` holds the version and build. `bundle.sh` refuses `/Applications` while the launcher,
a game client or wine runs, and archives the bundle it replaces instead of deleting it.
`package.sh` needs a Developer ID, a `notarytool` keychain profile (`HXI_NOTARY_PROFILE`, default
`batesai-notary`) and clean `vanaguide`/`vanavoice` checkouts beside this repo.

The measurement harness in [`scripts/harness/`](scripts/harness) launches the game, walks it to a
known spot, samples the frame rate and shuts it down, so performance claims can be reproduced
rather than eyeballed.

A few house rules, learned the hard way:

- **Measure before and after.** Several "obvious" speedups in this project turned out to be
  nothing, or to be faster only because they broke the game. If a change claims fps, include the
  numbers and how you got them.
- **Retract things that turn out to be wrong** rather than quietly deleting them. `docs/` records
  the dead ends on purpose so nobody walks them twice.
- **Never commit a game file.** No client DATs, no `FFXiMain.dll`, no wrapper. They belong to
  Square Enix or to CrossOver and cannot be redistributed.
- **Never commit an account name or password.** Credentials live in the macOS Keychain.

## Licence of contributions

This project is PolyForm Noncommercial 1.0.0 with a commercial rider ([`LICENSE`](LICENSE)), and
Bates LLC sells commercial licences to it. So a contribution has to come in on terms that let it
ship under both. By opening a pull request or otherwise submitting a contribution, you:

- grant Bates LLC a perpetual, worldwide, irrevocable, royalty-free, non-exclusive licence to use,
  copy, modify, distribute and sublicense your contribution under any terms, including commercial
  licences, plus a matching patent licence for any of your patent claims it necessarily infringes;
- confirm it is your own work, or that you have the right to submit it on these terms, and that
  it contains no code you copied under a licence that does not allow this;
- keep your copyright, and may still use your own contribution however you like.

Third-party code keeps its own licence: say so in the pull request and keep its licence file
beside it (see [`LICENSING.md`](LICENSING.md)). Questions: help@batesai.org.

## Server rules

Addons that a server hasn't approved can get a player banned. If you add or change an addon list,
cite the server's own published rules — see [`docs/ADDON-POLICY.md`](docs/ADDON-POLICY.md). When
a server's rules can't be sourced, the app says so rather than guessing.
