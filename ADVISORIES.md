# Advisory: pickup persistence and crash recovery

## Issue

The addon relies on the game's SavedVariables mechanism. Changes are written to disk on a normal `/reload`, logout, or client exit; an addon cannot request an immediate SavedVariables flush or write an arbitrary file itself. If the client crashes after a server-side mail pickup but before the next normal save, the in-memory staged/confirmed record can be lost.

## Impact

The gold can reach the collector while the local raffle ledger does not contain a matching confirmed entry. The addon cannot reconstruct the missing in-memory state after a crash.

## Recommended approach

1. **First verify persistence on the exact supported client build.** Public reports described SavedVariables failing to load in Forever build 69913, then users reported the issue fixed by build 70009 (September 2026). This addon targets 1.60.1.71037, so the older incident does not establish that the current build is affected. Do a controlled test: save a distinctive DB value, `/reload`, then fully exit and relaunch; verify the value both times before handling real raffle payments.
2. **Use normal saves as checkpoints.** After each settled collection run, export the CSV and `/reload` or log out normally. Smaller runs and more frequent checkpoints reduce the amount of confirmed activity exposed to a later crash, but cannot eliminate the short interval between a transfer and a save.
3. **Keep an independent operator record for high-stakes draws.** Record/export settled batches outside the game. If a crash occurs during or immediately after a pickup, stop collection and reconcile the collector's wallet, inbox, and any external record before manually resolving the entry. Never assume a missing ledger entry means the transfer failed.

An external helper can back up a SavedVariables file after the client writes it, but cannot capture addon state that is still only in memory. Moving the data to account-wide SavedVariables would have the same write timing. A true immediate durable write would require client support or an out-of-game workflow; the addon sandbox does not provide a supported arbitrary-file write API.

## Evidence and limits

- [Forever SavedVariables report, September 2026](https://us.forums.blizzard.com/en/wow/t/uiaddon-settings-wiped-on-client-restart/2353992): reports failure to restore SavedVariables around build 69913 and subsequent community reports that a later patch fixed it.
- [WoW API: SavedVariables](https://warcraft.wiki.gg/wiki/Saving_variables_between_game_sessions): SavedVariables are managed by the client and saved at session boundaries.

Forum posts are community reports, not a guarantee for every platform or installation. A controlled test on the actual client remains the decisive check.

The active-round entry-clear action is intentionally not exposed; closed raffles remain read-only. Live UI validation is deferred until the operator is ready to provide the client-side review details.
