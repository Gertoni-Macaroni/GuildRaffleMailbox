# GuildRaffleMailbox: user-benefit improvements

## Scope

This addon is for one operator running raffles for one guild. Recommendations below are limited to changes that could prevent an operator mistake, correct information shown to you, or improve an existing workflow. This is not a general code-quality or public-release roadmap. There are no plans to localize it.

The operator manually returns payments received after the cutoff. The addon must not infer mail age, return mail, or make the cutoff decision. Clearing entries from an active raffle is intentionally out of scope. Live-client testing is always performed manually by the operator; the coding assistant cannot launch or interact with the game.

## Worth doing

### 1. Refresh or clearly warn before closing on an old inbox scan

**Why it matters to the operator:** The close checklist uses the latest scan; it does not refresh the inbox itself. A payment can arrive after that scan and therefore be absent from the checklist.

**User-visible improvement:** Make the checklist clearly show whether the mailbox is open and how recent/complete the scan is. If it is stale or incomplete, direct the operator to refresh and review before closing. Whether a payment is past cutoff and should be returned remains a manual decision.

**If left as-is:** The checklist can look reassuring while describing an older view of the inbox. The existing age/incomplete indication helps, but the operator must notice it and refresh manually.

## Optional polish, not urgent

- Format individual payment amounts in the Session Report as gold/silver/copper, matching its totals. This only matters if the copied report is hard to read in practice.
- Improve the current-versus-incoming database comparison in Restore Preview only if the existing preview and confirmation prove insufficient. For personal use, a more elaborate restore workflow may add clutter.
- Strengthen backup data validation if an actual backup fails to import or a restore test reveals malformed state. The importer already parses its own data-only format without executing it; extra validation/checksum work is not the first use-experience priority.

## Not recommended now

- **General UI/code deduplication:** It may make future edits easier but does not improve raffle operation by itself.
- **Separating the backup trigger from its completion wording:** The current wording is stable, and future changes to this single-user addon will be reviewed with the code context. If that message is ever changed, update the completion check in the same change; a separate refactor has no current user benefit.
- **A full collection-state-machine rewrite:** It touches timing-sensitive pickup handling and has no immediate user benefit.
- **Automatic Mail History pruning:** The estimated size for the expected workload is modest; deleting history creates more risk than value right now.
- **An extra text-length feature:** The backup fields have no addon-set character cap, and the documented widget default is unlimited. Only revisit this if a manual large-copy/paste test fails.
- **Active-raffle entry clearing, mail disposition logging, or multi-operator workflows:** These are intentionally not part of this addon’s workflow.

## Manual checks for the recommended items

The coding assistant cannot run these checks; the operator must test them in the supported client:

1. Let an inbox scan age, then open the close checklist. Confirm stale/incomplete status is obvious and refresh produces updated waiting-payment information.
2. Complete a fully loaded pull with no eligible mail remaining and no unresolved pickup or sender-name review. Confirm the backup prompt appears.
3. Test a member name with a character the client's case-folding API does not support. Confirm Review offers a name match, matching makes the inbox payment eligible without collecting it, and **Close review** leaves the mail untouched without credit.

## Current verification

The mocked suite has 36 tests and Lua syntax checks pass. It covers unmatched sender-name review, mapping, dismissal, and backup preservation, but does not fully exercise the recent backup/reload and close-summary UI flows. All live visual and behavior checks are the operator’s responsibility.
