# GuildRaffleMailbox

GuildRaffleMailbox helps one officer record raffle payments sent by mail for one guild. It shows what is in the inbox before doing anything; it only takes attached gold when you click **Collect payments**.

The addon records entries and prepares reports. It does **not** run the winner draw, send prizes, or return late payments. Those remain the officers’ responsibility.

## Install and open

1. Put this project folder in the Forever client’s `Interface/AddOns/` directory. The folder you install must contain `GuildRaffleMailbox.toc` directly.
2. Enable **GuildRaffleMailbox** in the game’s AddOns list and log in.
3. On the character you use to collect raffle payments, type `/raffle` or `/guildraffle`.

Use one collector character on one game installation as the raffle ledger. Disable other mail-collection addons on that character. When you enable **Use this character to collect**, GuildRaffleMailbox also disables Blizzard’s **Open All**.

## Run a raffle

### 1. Set the ticket rules

Open **Raffle Setup**. Choose or create a ticket-price preset, and set an optional ticket limit per member. For example, if one ticket costs 10 silver, a 30-silver payment earns three tickets. Payments must be exact multiples of the ticket price.

Start the raffle after the character’s guild roster has loaded. Each raffle keeps its own copy of its ticket rules.

### 2. Collect payments

Ask members to mail attached gold from the character they want entered. The mail subject does not matter.

Open the mailbox and check the **Collect** tab. Looking at the inbox is read-only. Click **Collect payments** when you are ready; the addon checks the inbox and your character’s money before crediting a payment. A collection run handles up to 20 payments. **Stop collection** lets the current pickup finish before stopping.

Messages that do not meet the raffle rules are left alone. If a pickup’s result is uncertain, it appears on **Review** and is not automatically tried again.

### 3. Check the entries

**Active Raffle** shows the current totals and entries. You can export a CSV or correct an entry here.

- **Edit** changes a confirmed entry’s name or amount. The replacement name must match exactly one member in the current guild roster.
- **Manual entry** adds a ledger entry without checking the name against the roster or verifying the payment. Enter the amount; the addon previews the ticket count and checks the per-name ticket limit using what you typed. It does not take or move gold.

Manual names are free text by design. A typo can affect the ticket limit and winner matching, so check names and guild membership yourself when pulling winners. Closed raffles are locked and cannot be edited in the addon. Manual additions and later edits are marked in the entry list and CSV.

## Review items

There are two kinds of review item:

### Uncertain pickup

If mail or money changes unexpectedly during collection, the addon stops and puts the pickup on **Review**. Compare the saved details with what happened in game:

- Choose **Register payment** only if you verified that the gold reached the collector and is no longer attached to the mail.
- Choose **Dismiss** if the payment was not received. This adds no tickets.

An unresolved pickup blocks further collection and prevents closing its raffle. Do not register it if it could be the same payment as mail still in the inbox.

### Unmatched sender name

If an otherwise eligible payment has a sender name the addon cannot safely match to the roster, it appears on **Review**.

- Enter the member’s full roster name and choose **Match sender**. This saves the match and rechecks the message; it does not take gold or add tickets. Collect it normally if it becomes eligible.
- Choose **Close review** to leave the mail untouched without matching or crediting it.

These sender reviews do not stop collection of other identifiable payments, but they must be resolved or closed before you close the raffle.

## Close a raffle and handle late mail

Before closing, scan the mailbox, collect eligible payments for that raffle, and resolve its review items. The close confirmation summarizes the scan and anything still waiting. After closing, the raffle is read-only in **History**.

The game does not provide a reliable mail sent time. A payment received after the cutoff can look like a payment for the current raffle. Check for late mail before starting the next raffle; decide and handle any returns manually. GuildRaffleMailbox never deletes, returns, or refunds mail.

## Reports and backups

- **Session Report** summarizes a collection session.
- **Export CSV** gives you the entries and ticket ranges for one raffle. Select all and copy the text into your spreadsheet.
- **Full Export** copies the complete addon record—including raffles, entries, reviews, presets, and mail history. Save it outside the game.
- **Full Import** replaces the current addon record. Use it with the mailbox closed and collection stopped, then check the restored data before collecting.

After a settled collection, the addon may prompt you to save a full backup before enabling **Reload UI**. It cannot tell whether you actually saved the text. The import does not restore a live inbox scan or resume an unfinished pickup.

### CSV fields

Each raffle’s CSV includes a per-raffle `entry_number`, a database-wide `receipt_id`, payment and ticket details, ticket ranges, registration time in UTC, and the registration source (`mailbox` or `manual`). `manual_entry` identifies operator-added entries; `manually_edited_at_utc` is filled in when an existing entry is corrected.

## Testing

### In-game check

Run **`/raffletest`** in chat, even on first startup. It checks the client APIs and runs isolated tests for name handling, review actions, manual entries, and backup/restore.

The self-test uses temporary tables and does not change `GuildRaffleMailboxDB`, collect mail, or request a roster refresh. It may skip checks when the required live state is unavailable, such as when the inbox header cannot be read. Failed and skipped checks are named in chat.

### Developer tests

From this project folder, run:

```sh
luajit tests/run.lua
for file in ./*.lua tests/*.lua; do luajit -b "$file" /dev/null || exit 1; done
```

These tests use mocked game APIs. They do not replace a small live-client test before relying on the addon.

## Compatibility and first-use checklist

This addon targets World of Warcraft: Forever 1.60.1 (interface 16001) and requires Forever’s `CaseAccentInsensitiveParse` name-matching API. It folds supported letter case while preserving accents; it is not general Unicode normalization. Names the addon cannot match safely go to **Review**.

Before using it for a real raffle:

- Run `/raffletest`.
- Check that mailbox and roster names look the same in your client.
- Test one small payment and confirm it is credited only after collection succeeds.
- Confirm **Open All** and other mail collectors are not being used on the collector character.

The automated tests cannot verify the live game UI or mailbox behavior. Perform these checks yourself in game.
