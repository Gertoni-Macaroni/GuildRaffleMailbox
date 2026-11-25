# GuildRaffleMailbox

An officer-operated, character-local raffle payment ledger for **World of Warcraft: Forever 1.60.1.71037**. It previews mail without changing it and only collects validated attached gold after an explicit button click.
The addon does not run the draw or send prizes; those remain in the guild officers’ workflow.
It keeps a local comparison of inbox messages with attached gold and warns if one disappears unexpectedly. These comparisons are separate from confirmed raffle entries.
The guild roster is read at runtime rather than saved as a raffle-start snapshot. Members who join during an active raffle can qualify after the guild roster updates and the inbox is rescanned.

## Install

1. Copy the `GuildRaffleMailbox/` folder into the Forever client’s `Interface/AddOns/` directory. The installed folder must contain `GuildRaffleMailbox.toc` directly.
2. Start the game and enable **GuildRaffleMailbox** in the AddOns list.
3. Log in on the dedicated raffle character, type `/guildraffle` or `/raffle`, and enable **Use this character to collect** on the **Collect** tab.

The addon uses `## Interface: 16001` and per-character `GuildRaffleMailboxDB` SavedVariables. Use one collector character on one game installation as the ledger of record. Disable other mail collectors on that character. When **Use this character to collect** is enabled, the addon disables Blizzard’s **Open All** and blocks its mouse and gamepad actions; it also stops an Open All sequence if collection mode is enabled mid-run. Use only **Collect payments** on the addon’s **Collect** tab.

## Operator workflow

1. On **Raffle Setup**, choose ticket rules from the dropdown or create a preset. Enter the price in the gold, silver, and copper fields; silver and copper must each be 0–99. Leave the ticket limit blank for no limit.
2. Start a raffle after confirming the collector’s guild roster is ready. The round stores its own guild identity and copy of the ticket rules; later edits affect only future raffles.
3. Guild members send attached gold from the character they are entering with. Any subject is accepted. Opening the mailbox is read-only; the **Collect** tab shows eligible payments and why other messages were left alone.
4. Click **Collect payments**. The addon records each pickup attempt before requesting the gold, checks the inbox and character money, and records the payment only when the evidence agrees. A run is limited to 20 pickups. **Stop collection** lets the current pickup finish; uncertain outcomes appear on the **Review** tab and are never retried automatically.
5. **Active Raffle** shows the current raffle’s details, totals, and registered payments. Use **Edit** on a row to correct its member or amount; edits require an exact, unique current guild-roster match. **Manual entry** adds a record without checking the typed member name against the roster. The amount must be an exact multiple of the ticket price, and the per-name ticket limit is still checked using the typed name. A typo may affect that limit and winner matching, so check names and membership manually when pulling winners. Closed raffles are locked and cannot be corrected in the addon. Both actions change the ledger only: they do not inspect mail, verify payment, or move gold. Manual entries and later corrections are marked in the list and CSV. Entry numbers start at 1 for each raffle. Export its CSV or close it there; closing uses the same confirmation as the Raffle Setup tab. CSV `receipt_id` values remain globally unique database IDs; `entry_number` is the per-raffle display number.
6. **History** contains closed raffles as read-only archives. Their entries cannot be cleared or changed. Clearing entries from an active raffle is intentionally not part of the operator workflow.
7. **Mail History** archives safely readable inbox messages while collection is enabled, including the sender, attached gold, and when the message was first recorded. It updates on inbox scans and before collection actions; the native **Open All** remains blocked while collection is enabled. WoW does not expose a reliable mail sent/received timestamp, so “First recorded” is the time the addon observed it.
8. After each settled collection session, review/copy the **Session Report**. When a complete mailbox pull finishes with no unresolved pickups or unmatched sender-name reviews, the addon displays the full backup string. Save it outside the game and confirm; a second prompt shows the same backup and requires **I ABSOLUTELY MADE A BACKUP** before enabling the secure **Reload UI** button. The addon cannot verify that you saved the copy. A crash between the server transfer and a disk save can still lose the latest pickup attempt or confirmed entry.
9. After the final payment window, collect and review the old raffle, then close it. The close confirmation shows scan coverage, eligible mail still waiting, and unresolved review items. Resolve or close Review items before closing; the addon provides a copyable close summary after confirmation. Before starting another raffle, check for late payments.

### Between rounds and late mail

Allow time for the previous raffle’s payments to arrive. Before starting another, refresh and inspect the old mailbox, collect eligible payments under the old raffle, and resolve leftover funded mail under the guild’s policy. Per the current policy, mail received after the cutoff is returned to its sender rather than entered in the next raffle. The addon does not delete, return, or refund mail; officers handle returns manually. Start the next raffle only after the old-round mailbox is settled as far as practical, and tell members the new payment window.

Mail expiry is not a trustworthy send timestamp. With amount-based entry, a late payment can match the next active round; the addon records registration time, not inferred send time. The CSV has no subject or body fields. Never assume a payment belongs to a round based on its expiry countdown.

### Reviewing an uncertain pickup

After timeout, failure, mailbox close, guild change, partial data, or reload, collection stops and the pickup appears on the **Review** tab. The officer can dismiss it without adding tickets or manually register it against its original raffle. Before manual registration, compare the saved character’s money and inbox details with what happened in game; confirm that the gold arrived and is no longer attached to the message. The checkbox states this in plain language. Manual registration uses the original pickup reference and ticket rules, plus a new registration time.

An unresolved pickup blocks further collection and closing or clearing its raffle. Do not register it manually while a message with matching details might still be the same payment.

### Reviewing an unmatched sender name

If a funded, otherwise eligible message has non-ASCII characters in its sender name and the addon cannot match that name uniquely to the guild roster, it appears on **Review** instead of being silently ignored. Select it, enter the guild member's full name exactly as shown in the roster, and choose **Match sender**. After confirmation, the sender match is saved for future mail and the current message is rechecked against the raffle rules on **Collect**. This does not take the gold or add tickets; collect the message normally if it is eligible.

If the sender does not need action, choose **Close review**. This closes the review item without matching the sender or crediting a payment. The mail remains in the inbox and is not collected. A later additional payment from that still-unmatched sender can reopen its review item. Open sender-name reviews must be matched or closed before the raffle can be closed.

The API used for name matching folds case for Basic Latin and Latin-1 accented letters (including common letters such as `É` and `Ø`) while preserving accents. It is not general Unicode normalization; unsupported character variants are routed to manual review when they cannot be matched.

### Full addon backup

**Full Export** copies the complete persistent addon database (raffles, receipts/review records, sender-name matches, presets, mail history, and observation state) into a text window. Select all, copy, and save it outside the game after collection checkpoints. The importer parses only the addon's data-only literal format and never executes pasted text. **Full Import** replaces the entire current addon database after a confirmation; use it only with the mailbox closed and collection stopped, and verify the restored raffle/history before collecting. Import does not restore a transient live inbox scan or continue an in-progress pickup; unfinished staged pickups and open sender-name reviews are in Review.

## CSV

**Export CSV** on the **Active Raffle** and **History** tabs includes every confirmed payment in stable receipt-ID order and always includes the header. Ticket ranges are contiguous within the selected raffle. `entry_number` starts at 1 for each raffle; `receipt_id` remains a globally unique database ID. Registered timestamps are formatted as ISO 8601 UTC; `mailbox` and `manual` identify the registration path. `manual_entry` marks an operator-added entry, and `manually_edited_at_utc` is populated when an existing entry was corrected. Use **Select all** in the export window and copy normally.

## Compatibility and verification

The addon checks `select(4, GetBuildInfo())` and requires interface 16001, including Forever's `CaseAccentInsensitiveParse` name-matching API. It uses the Forever API return positions for inbox sender/subject/money/Cash on Delivery/attachments/returned/can-reply/Game Master fields and guild roster name/GUID fields, including offline roster members. Character matching compares the complete name, folds supported letter case, preserves accents, trims surrounding whitespace, and does **not** strip surnames or other suffixes. Verify mailbox and roster names on the live client before running a raffle.

The reference implementation was checked against the Forever 1.60.1.71037 exported `MailFrame.lua` and generated `GuildInfoDocumentation.lua`. The coding assistant cannot launch or interact with the game client, so all live in-game smoke checks and visual validation must be performed manually by the addon operator. A build string/API mismatch is shown in the panel; verify the installed client before relying on a different build.

## Tests

From the repository root, run:

```sh
luajit tests/run.lua
for file in GuildRaffleMailbox/*.lua tests/*.lua; do luajit -b "$file" /dev/null; done
```

The mocked tests cover read-only scans and reopen, duplicate payments, 30s/25s exact-multiple behavior, per-character limits, manual entries without roster lookup and roster-checked corrections, accented-name matching and unmatched-name review/repair/dismissal, full-name/ambiguous membership, new guild members, backlog refresh, ordinary-mail rejection, failure/timeout/partial/close review, reload no-replay, manual-review checks, round/preset snapshots, reset scoping, and CSV escaping/ticket ranges.

### In-game self-test

Run **`/raffletest`** in chat, including on first startup before collecting any raffle data. It checks the installed Forever build and required APIs, accented-name normalization using the live client API, unmatched-sender review/match/close and manual-entry/correction workflows using temporary data, a full-backup round-trip using temporary data, read-only mail status APIs, and up to ten readable guild-roster names. If the mailbox is closed and a loaded message is available, it also probes that message's sender and attached-money fields without taking anything. Checks requiring unavailable state (such as a loaded guild roster or a readable inbox header) are skipped and named in chat; failed checks are likewise printed by test name with a short reason.

The command does not modify `GuildRaffleMailboxDB` (it checks only that the top-level database reference is unchanged), request a roster refresh, take mailbox payments, or reload the UI. The synthetic raffle, roster, sender, and backup records are temporary local tables. It does not test secure reload or visual layout; those still require the operator’s manual smoke test.

### Live smoke-test checklist (required before first use)

- [ ] Confirm `select(4, GetBuildInfo()) == 16001` and the client exposes `CaseAccentInsensitiveParse` plus the referenced `C_Mail`, `C_Club`, `C_GuildInfo`, inbox, money, and roster APIs.
- [ ] Verify that an offline guild member’s complete Forever name is represented the same way in `GetInboxHeaderInfo` and `GetGuildRosterInfo`.
- [ ] If available, test an accented name the API supports and an unsupported character-case variant; confirm a failed correlation enters Review, can be matched to the roster member, and then becomes eligible without being collected automatically.
- [ ] With one small payment, observe `TakeInboxMoney`, `MAIL_INBOX_UPDATE`, `C_Mail.IsCommandPending()`, `MAIL_SUCCESS`, and `PLAYER_MONEY`; confirm the ledger credits only after the evidence agrees.
- [ ] Send two matching payments and verify each creates one receipt, including after a normal `/reload`.
- [ ] Send a non-multiple payment and confirm it stays attached with a displayed reason.
- [ ] Verify another mail collector and **Open All** are unused on the collector character.

**Live checks run by the coding assistant: none are possible.** The addon operator must run the live-client checks above; source inspection and mocked tests do not replace them.
