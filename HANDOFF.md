# GuildRaffleMailbox handoff

## Current workspace

- Project directory: `/home/gerton/Software/wow/GuildRaffleMailbox`
- GitHub repository: `Gertoni-Macaroni/GuildRaffleMailbox`
- Remote: `git@github.com:Gertoni-Macaroni/GuildRaffleMailbox.git`
- Branch: `main`, tracking `origin/main`
- Base commit checked: `ad18b4a` (`Initial import of GuildRaffleMailbox`)
- This project has no nested `GuildRaffleMailbox/` source directory. The `.toc` and addon Lua files are at the repository root; `tests/` contains the mocked suite.

## Work completed

- Added and tested Forever's `CaseAccentInsensitiveParse`-based name matching. It folds supported letter case while preserving accents; it is not general Unicode normalization and has no fallback.
- Added unmatched foreign-sender review cases, manual sender-to-guild-member matching, review dismissal, and safeguards around closing raffles and backup prompts.
- Added `/raffletest`, which probes safe live APIs and runs isolated addon logic tests using temporary tables. It must not modify `GuildRaffleMailboxDB`, collect mail, or request a roster refresh.
- Added active-raffle entry editing and manual entry:
  - Manual entries accept a typed name without a guild-roster lookup.
  - The amount must be an exact multiple of the raffle's ticket price. The per-name cap is checked using the typed name, so misspellings can affect cap totals and winner matching.
  - Editing an existing confirmed entry requires an exact, unique current guild-roster match.
  - Both actions only update the raffle ledger. They do not inspect mail, verify or move gold, or collect a payment.
  - Operations are blocked during collection. Closed raffles remain locked. Manual additions and edit timestamps are shown in the UI and CSV.
- Rewrote `README.md` as an operator-oriented guide.
- Fixed `tests/run.lua` source paths for the current repository layout.

## Latest verification

Run from the repository root:

```sh
luajit tests/run.lua
for file in ./*.lua tests/*.lua; do luajit -b "$file" /dev/null || exit 1; done
```

Latest result: **38 targeted tests passed**; LuaJIT syntax checks passed.

## Git state

Before creating this handoff file, `git status --short` showed:

```text
 M README.md
 M tests/run.lua
```

These changes are uncommitted. `HANDOFF.md` is also a new, uncommitted file.

## Product decisions and constraints

- This is for one operator and one guild; avoid adding features without a clear practical benefit.
- Late mail remains a manual officer decision. The addon must not infer mail age or return/refund mail.
- Sender-name review dismissal leaves mail and raffle credit untouched.
- Manual sender matching saves an alias and makes eligible mail available for normal collection; it does not collect or credit it.
- Manual raffle entries intentionally skip roster validation. The operator checks names and guild membership when pulling winners; closed raffles cannot be edited afterward.
- Do not add localization, payment-disposition logging, account handoff, or new active-entry deletion/clearing features without revisiting the prior scope decision.
- The assistant cannot run the Forever game client. Live API, visual, and mailbox smoke tests must be performed by the operator.

## Suggested next checks

1. Review the uncommitted README, test-path, and handoff changes; commit them if desired.
2. In game, run `/raffletest`.
3. Manually verify the Active Raffle entry dialog, typed-name behavior, roster-checked edits, ticket/cap calculations, and that no mail or wallet changes occur.
4. Perform the existing live mailbox and review smoke tests before relying on the addon.
