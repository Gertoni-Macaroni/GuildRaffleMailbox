local ADDON_NAME, ns = ...

local Core = ns.Core
local Controller = {}
Controller.__index = Controller
ns.Controller = Controller

local MAX_BATCH_PAYMENTS = 20
local PICKUP_TIMEOUT = 18
local PICKUP_DELAY = 0.8
local ROSTER_REFRESH_INTERVAL = 15
local ROSTER_MAX_AGE = 120

local function safeCall(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

local function sameGuild(left, right)
    if not Core.IsSafe(left) or not Core.IsSafe(right) then
        return false
    end
    return type(left) == type(right) and left == right
end

local function encodePart(value)
    local text = tostring(value)
    return tostring(string.len(text)) .. ":" .. text
end

local function paymentSignature(row)
    return table.concat({
        encodePart(row.sender),
        encodePart(row.money),
        encodePart(row.subject),
        encodePart(row.cod),
        encodePart(row.attachment_count),
        encodePart(row.returned and "1" or "0"),
        encodePart(row.can_reply and "1" or "0"),
        encodePart(row.is_gm and "1" or "0"),
    }, "|")
end

local function mailHistorySignature(row)
    return table.concat({
        encodePart(row.sender),
        encodePart(row.subject),
        encodePart(row.money),
        encodePart(row.cod),
        encodePart(row.returned and "1" or "0"),
        encodePart(row.can_reply and "1" or "0"),
        encodePart(row.is_gm and "1" or "0"),
    }, "|")
end

local function hasNonAscii(text)
    return type(text) == "string" and string.find(text, "[\128-\255]") ~= nil
end

local function resolveSenderAlias(roster, alias)
    if type(alias) ~= "table" then
        return nil
    end
    local found
    for _, member in ipairs(roster and roster.members or {}) do
        local matches = alias.member_guid and member.guid == alias.member_guid
            or not alias.member_guid and member.key == alias.member_key
        if matches then
            if found then
                return nil
            end
            found = member
        end
    end
    return found
end

local function findSenderReviewCase(db, roundId, senderKey)
    for _, review in pairs(db.sender_reviews or {}) do
        if type(review) == "table"
            and review.round_id == roundId
            and review.sender_key == senderKey then
            return review
        end
    end
    return nil
end

local function getCommandPending(api)
    local ok, pending = safeCall(api.commandPending)
    if not ok then
        return nil
    end
    return Core.SafeBoolean(pending)
end

local function anyUnresolved(db)
    for _, receipt in pairs(db.receipts or {}) do
        if type(receipt) == "table"
            and (receipt.status == "pending" or receipt.status == "needs_review") then
            return true
        end
    end
    return false
end

local function loadStoredObservation(db)
    local saved = db.last_observation
    if not Core.IsSafe(saved) or type(saved) ~= "table" then
        return nil
    end
    local loaded = Core.SafeNumber(saved.loaded, 0)
    local total = Core.SafeNumber(saved.total, 0)
    local complete = Core.SafeBoolean(saved.complete)
    local observedAt = Core.SafeFiniteNumber(saved.observed_at, 0)
    if loaded == nil or total == nil or not complete or not observedAt then
        return nil
    end
    local counts = {}
    local savedCounts = saved.signature_counts
    if not Core.IsSafe(savedCounts) or type(savedCounts) ~= "table" then
        return nil
    end
    for signature, count in pairs(savedCounts) do
        signature = Core.SafeString(signature, false)
        count = Core.SafeNumber(count, 1)
        if not signature or not count then
            return nil
        end
        counts[signature] = count
    end
    return {
        loaded = loaded,
        total = total,
        complete = complete,
        observed_at = observedAt,
        signature_counts = counts,
    }
end

function Controller.new(db, api, onUpdate)
    return setmetatable({
        db = db,
        api = api,
        onUpdate = onUpdate,
        mailbox_open = false,
        snapshot = nil,
        roster = nil,
        roster_ready = false,
        roster_guild_id = nil,
        roster_at = nil,
        last_roster_request = -1000000,
        latest_status = "Mailbox is closed. Open it to scan for raffle payments.",
        discrepancy = nil,
        previous_observation = loadStoredObservation(db),
        collection = nil,
        collection_state = "idle",
        in_flight = nil,
        inbox_generation = 0,
    }, Controller)
end

function Controller:StoreObservation(snapshot)
    if not snapshot or not snapshot.complete then
        return
    end
    local counts = {}
    for signature, count in pairs(snapshot.signature_counts or {}) do
        if Core.SafeString(signature, false) and Core.SafeNumber(count, 1) then
            counts[signature] = count
        end
    end
    local observedAt = Core.SafeFiniteNumber(snapshot.observed_at, 0)
    if not observedAt then
        return
    end
    local saved = {
        loaded = snapshot.loaded,
        total = snapshot.total,
        complete = true,
        observed_at = observedAt,
        signature_counts = counts,
    }
    self.db.last_observation = saved
    self.previous_observation = saved
end

function Controller:Notify()
    if type(self.onUpdate) == "function" then
        pcall(self.onUpdate, self)
    end
end

function Controller:SetStatus(message)
    self.latest_status = message
    self:Notify()
end

function Controller:SetCollectorEnabled(enabled)
    self.db.collector_enabled = enabled == true
    if not self.db.collector_enabled then
        self:StopCollection()
    end
    self:SetStatus(self.db.collector_enabled
        and "Payment collection is enabled on this character."
        or "Payment collection is disabled on this character.")
end

function Controller:ResetRound(roundId)
    if self.collection and self.collection.running then
        return false, "Stop collection before resetting raffle entries."
    end
    return Core.ResetRoundEntries(self.db, roundId)
end

local function ledgerMutationBlocked(controller)
    local state = controller.collection_state
    return controller.in_flight ~= nil
        or (controller.collection and controller.collection.running)
        or state == "collecting"
        or state == "settling"
        or state == "stopping"
end

function Controller:AddManualEntry(roundId, character, paidCopper)
    if ledgerMutationBlocked(self) then
        return false, "Wait for the current collection operation to finish before changing entries."
    end
    local round = self:GetActiveRound()
    if not round or round.status ~= "active" or round.id ~= roundId then
        return false, "Manual entries can only be added to an active raffle."
    end
    local timeOK, registeredAt = safeCall(self.api.serverTime)
    local receipt, reason = Core.CreateManualEntry(
        self.db,
        round.id,
        character,
        paidCopper,
        timeOK and registeredAt or nil
    )
    if not receipt then
        return false, reason
    end
    self:SetStatus("Manual entry added for " .. receipt.character
        .. ". This changed the raffle record only; no gold was collected or verified.")
    return true, receipt
end

function Controller:EditConfirmedEntry(roundId, receiptId, memberName, paidCopper)
    if ledgerMutationBlocked(self) then
        return false, "Wait for the current collection operation to finish before changing entries."
    end
    local round = self:GetActiveRound()
    if not round or round.status ~= "active" or round.id ~= roundId then
        return false, "Only entries in an active raffle can be edited."
    end
    local rosterReady, rosterReason = self:EnsureRoster(round)
    if not rosterReady then
        return false, rosterReason
    end

    local memberKey = Core.NormalizeFullName(memberName)
    local matches = memberKey and self.roster.by_name[memberKey] or nil
    if not matches or #matches == 0 then
        return false, "That name is not in the current guild roster. Enter the member's full name exactly as shown."
    end
    if #matches ~= 1 then
        return false, "That name matches more than one guild member. The entry cannot be assigned safely."
    end

    local member = matches[1]
    local timeOK, editedAt = safeCall(self.api.serverTime)
    local ok, result = Core.UpdateConfirmedEntry(
        self.db,
        round.id,
        receiptId,
        {
            character = member.name,
            character_guid = member.guid,
            paid_copper = paidCopper,
        },
        timeOK and editedAt or nil
    )
    if not ok then
        return false, result
    end
    self:SetStatus("Entry corrected for " .. member.name
        .. ". No gold or mail was changed.")
    return true, result
end

function Controller:AcknowledgeDiscrepancy()
    if not self.discrepancy then
        return false, "There is no mailbox discrepancy to acknowledge."
    end
    if not self.snapshot or not self.snapshot.complete
        or self.snapshot.loaded ~= self.snapshot.total then
        return false, "Scan the complete inbox before acknowledging this warning."
    end
    self.discrepancy = nil
    self:SetStatus("Inbox difference acknowledged. Future changes will still be flagged.")
    return true
end

function Controller:GetCollectionReadiness()
    local ready, reason = self:CanCollect()
    return ready, reason
end

function Controller:GetActiveRound()
    if not self.db.active_round_id then
        return nil
    end
    return Core.GetRound(self.db, self.db.active_round_id)
end

function Controller:GetGuild()
    local ok, inGuild = safeCall(self.api.isInGuild)
    if not ok or Core.SafeBoolean(inGuild) ~= true then
        return false, nil, nil
    end
    local idOK, guildId = safeCall(self.api.getGuildClubId)
    if not idOK or not Core.IsSafe(guildId) then
        return true, nil, nil
    end
    if type(guildId) == "number" then
        guildId = Core.SafeNumber(guildId, 1)
    elseif type(guildId) == "string" then
        guildId = Core.SafeString(guildId, false)
    else
        guildId = nil
    end
    if not guildId then
        return true, nil, nil
    end
    local nameOK, guildName = safeCall(self.api.getGuildName)
    if not nameOK then
        guildName = nil
    end
    return true, guildId, Core.SafeString(guildName, true)
end

function Controller:InvalidateRoster()
    self.roster = nil
    self.roster_ready = false
    self.roster_guild_id = nil
    self.roster_at = nil
end

function Controller:RequestRoster()
    local now = self.api.now()
    if now - self.last_roster_request < ROSTER_REFRESH_INTERVAL then
        if not self.roster_request_scheduled then
            self.roster_request_scheduled = true
            self.api.after(ROSTER_REFRESH_INTERVAL - (now - self.last_roster_request), function()
                self.roster_request_scheduled = false
                self:RequestRoster()
            end)
        end
        return false
    end
    self.last_roster_request = now
    safeCall(self.api.requestRoster)
    return true
end

function Controller:RefreshRoster()
    local inGuild, guildId = self:GetGuild()
    if not inGuild or not guildId then
        self:InvalidateRoster()
        self:SetStatus("Waiting for guild roster. Collection will be available when the roster loads.")
        return false
    end

    local countOK, count = safeCall(self.api.getGuildMemberCount)
    count = countOK and Core.SafeNumber(count, 0) or nil
    if not count or count == 0 then
        self:InvalidateRoster()
        self:RequestRoster()
        self:SetStatus("Waiting for guild roster. Collection will be available when the roster loads.")
        return false
    end

    local byName = {}
    local roster = {}
    local complete = true
    for index = 1, count do
        local infoOK, name, guid = safeCall(self.api.getGuildMemberInfo, index)
        if not infoOK then
            complete = false
            break
        end
        name = Core.SafeString(name, false)
        local nameKey = Core.NormalizeFullName(name)
        if not name or not nameKey then
            complete = false
            break
        end

        if Core.IsMissing(guid) then
            guid = nil
        elseif not Core.IsSafe(guid) or type(guid) ~= "string" or guid == "" then
            complete = false
            break
        end
        local member = {
            name = name,
            key = nameKey,
            guid = guid,
        }
        table.insert(roster, member)
        byName[nameKey] = byName[nameKey] or {}
        table.insert(byName[nameKey], member)
    end

    if not complete or #roster ~= count then
        self:InvalidateRoster()
        self:RequestRoster()
        self:SetStatus("Waiting for guild roster. Collection will be available when the roster loads.")
        return false
    end

    self.roster = {
        members = roster,
        by_name = byName,
    }
    self.roster_ready = true
    self.roster_guild_id = guildId
    self.roster_at = self.api.now()

    local active = self:GetActiveRound()
    if active and not sameGuild(active.guild_id, guildId) then
        self:StopForGuildChange("Collector guild differs from this raffle.")
    end
    self:ReclassifySnapshot()
    self:Notify()
    return true
end

function Controller:EnsureRoster(round)
    local inGuild, guildId = self:GetGuild()
    if not inGuild then
        self:InvalidateRoster()
        return false, "This character must be in the raffle's guild."
    end
    if not guildId then
        self:InvalidateRoster()
        self:RequestRoster()
        return false, "Waiting for guild roster. Collection will be available when the roster loads."
    end
    if self.roster_guild_id and not sameGuild(self.roster_guild_id, guildId) then
        self:InvalidateRoster()
    end
    if round and not sameGuild(round.guild_id, guildId) then
        return false, "This character is no longer in the guild that started this raffle."
    end
    if self.roster_ready and self.roster_at
        and self.api.now() - self.roster_at <= ROSTER_MAX_AGE then
        return true
    end
    self.roster_ready = false
    self:RequestRoster()
    return false, "Waiting for guild roster. Collection will be available when the roster loads."
end

function Controller:BuildSnapshot()
    local countOK, loaded, total = safeCall(self.api.getInboxCounts)
    loaded = countOK and Core.SafeNumber(loaded, 0) or nil
    total = countOK and Core.SafeNumber(total, 0) or nil
    if not loaded or not total or total < loaded then
        return {
            loaded = loaded or 0,
            total = total or 0,
            complete = false,
            rows = {},
            signature_counts = {},
        }
    end

    local snapshot = {
        loaded = loaded,
        total = total,
        complete = true,
        rows = {},
        signature_counts = {},
        observed_at = self.api.now(),
    }
    for index = 1, loaded do
        local headerOK, raw = safeCall(self.api.getInboxHeader, index)
        if not headerOK or not Core.IsSafe(raw) or type(raw) ~= "table" then
            snapshot.complete = false
            table.insert(snapshot.rows, { index = index, unverified = true })
        else
            local attachments = raw.attachment_count
            if Core.IsMissing(attachments) then
                -- GetInboxHeaderInfo documents nil as zero for this field.
                attachments = 0
            end
            local row = {
                index = index,
                sender = Core.SafeString(raw.sender, false),
                subject = Core.SafeString(raw.subject, true),
                money = Core.SafeNumber(raw.money, 0),
                cod = Core.SafeNumber(raw.cod, 0),
                attachment_count = Core.SafeNumber(attachments, 0),
                returned = Core.SafeBoolean(raw.returned),
                can_reply = Core.SafeBoolean(raw.can_reply),
                is_gm = Core.SafeBoolean(raw.is_gm),
            }
            if not row.sender or row.subject == nil or row.money == nil or row.cod == nil
                or row.attachment_count == nil or row.returned == nil
                or row.can_reply == nil or row.is_gm == nil then
                row.unverified = true
                snapshot.complete = false
            else
                row.signature = paymentSignature(row)
                if row.money > 0 then
                    snapshot.signature_counts[row.signature] =
                        (snapshot.signature_counts[row.signature] or 0) + 1
                end
            end
            table.insert(snapshot.rows, row)
        end
    end
    return snapshot
end

function Controller:ArchiveMailSnapshot(snapshot, source)
    if self.db.collector_enabled ~= true or not snapshot or not snapshot.complete
        or snapshot.loaded ~= snapshot.total then
        return 0
    end

    local timeOK, recordedAt = safeCall(self.api.serverTime)
    recordedAt = timeOK and Core.SafeFiniteNumber(recordedAt, 0) or nil
    if not recordedAt then
        return 0
    end

    local seenCounts = self.db.mail_history_seen_counts
    if type(seenCounts) ~= "table" then
        seenCounts = {}
        self.db.mail_history_seen_counts = seenCounts
    end
    local occurrences = {}
    local currentCounts = {}
    local added = 0

    for _, row in ipairs(snapshot.rows or {}) do
        if not row.unverified and row.sender and row.money ~= nil then
            local signature = mailHistorySignature(row)
            occurrences[signature] = (occurrences[signature] or 0) + 1
            local occurrence = occurrences[signature]
            currentCounts[signature] = occurrence
            local previousCount = Core.SafeNumber(seenCounts[signature], 0) or 0
            if occurrence > previousCount then
                local id = self.db.next_mail_history_id or 1
                table.insert(self.db.mail_history, {
                    id = id,
                    sender = row.sender,
                    subject = row.subject or "",
                    money = row.money,
                    recorded_at = recordedAt,
                    source = source or "Inbox scan",
                })
                self.db.next_mail_history_id = id + 1
                added = added + 1
            end
        end
    end

    for signature in pairs(seenCounts) do
        seenCounts[signature] = nil
    end
    for signature, count in pairs(currentCounts) do
        seenCounts[signature] = count
    end
    if added > 0 then
        self:Notify()
    end
    return added
end

function Controller:ArchiveCurrentInbox(source)
    if self.db.collector_enabled ~= true then
        return 0
    end
    return self:ArchiveMailSnapshot(self:BuildSnapshot(), source)
end

function Controller:CompareObservation(snapshot)
    local previous = self.previous_observation
    if previous and previous.complete and previous.loaded == previous.total
        and snapshot.complete and snapshot.loaded == snapshot.total then
        for signature, oldCount in pairs(previous.signature_counts) do
            local newCount = snapshot.signature_counts[signature] or 0
            if newCount < oldCount then
                self.discrepancy = "A gold payment message disappeared unexpectedly. Check your inbox and character money before collecting."
                break
            end
        end
    end
    if snapshot.complete and snapshot.loaded == snapshot.total then
        self:StoreObservation(snapshot)
    end
end

function Controller:ClassifyRow(row, round, rosterAvailable)
    row.eligible = false
    row.reason = nil
    row.sender_review_needed = nil
    row.sender_review_key = nil
    if row.unverified then
        row.reason = "Mail details could not be verified, so this message was left alone."
        return
    end
    if row.money <= 0 then
        return
    end
    if row.returned then
        row.reason = "Returned mail cannot be entered in a raffle."
        return
    end
    if row.is_gm then
        row.reason = "Game Master mail cannot be entered."
        return
    end
    if not row.can_reply then
        row.reason = "This could not be verified as regular player mail."
        return
    end
    if row.cod ~= 0 then
        row.reason = "Cash on Delivery mail cannot be entered."
        return
    end
    if row.attachment_count ~= 0 then
        row.reason = "This message includes an item attachment; it was left alone."
        return
    end
    if not round or round.status ~= "active" then
        row.reason = "No raffle is accepting payments. Start one in Raffle Setup."
        return
    end
    if not rosterAvailable then
        row.reason = "Waiting for guild roster. Collection will be available when the roster loads."
        return
    end

    local nameKey = Core.NormalizeFullName(row.sender)
    local alias = nameKey and self.db.sender_aliases[nameKey] or nil
    local manualMember = type(alias) == "table" and sameGuild(alias.guild_id, round.guild_id)
        and resolveSenderAlias(self.roster, alias) or nil
    local matches = manualMember and { manualMember }
        or (nameKey and self.roster.by_name[nameKey] or nil)
    if not matches or #matches == 0 then
        if hasNonAscii(row.sender) and nameKey then
            row.sender_review_needed = true
            row.sender_review_key = nameKey
            local review = findSenderReviewCase(self.db, round.id, nameKey)
            row.reason = review and review.status == "dismissed"
                and "This sender review was closed without action. The mail remains untouched."
                or "This sender's name could not be matched to a guild member. See Review to match it manually."
        else
            row.reason = "This sender is not listed in the collector's guild."
        end
        return
    end
    if #matches ~= 1 then
        if hasNonAscii(row.sender) and nameKey then
            row.sender_review_needed = true
            row.sender_review_key = nameKey
            local review = findSenderReviewCase(self.db, round.id, nameKey)
            row.reason = review and review.status == "dismissed"
                and "This sender review was closed without action. The mail remains untouched."
                or "This sender matches multiple guild members. See Review to select the correct member."
        else
            row.reason = "More than one guild member has this name, so the sender cannot be identified safely."
        end
        return
    end

    local member = matches[1]
    local price = round.preset.price_copper
    if row.money % price ~= 0 then
        row.reason = "This amount does not match a whole number of tickets at this raffle's price."
        return
    end
    local tickets = row.money / price
    local identity = {
        key = member.key,
        guid = member.guid,
    }
    local current = Core.GetTicketsForIdentity(self.db, round.id, identity)
    local cap = round.preset.cap_per_character
    if cap and current + tickets > cap then
        row.reason = string.format(
            "This would exceed the ticket limit; this member can receive %d more ticket(s).",
            math.max(0, cap - current)
        )
        return
    end

    row.eligible = true
    row.reason = "Ready to enter: " .. tostring(tickets) .. " ticket(s)."
    row.tickets = tickets
    row.member_name = member.name
    row.member_key = member.key
    row.member_guid = member.guid
end

function Controller:ReclassifySnapshot()
    if not self.snapshot then
        return
    end
    local round = self:GetActiveRound()
    local rosterAvailable = round and self:EnsureRoster(round) or false
    for _, row in ipairs(self.snapshot.rows) do
        self:ClassifyRow(row, round, rosterAvailable)
    end
    if self.snapshot.complete and self.snapshot.loaded == self.snapshot.total
        and round and rosterAvailable then
        self:SyncSenderReviewCases(round)
    end
end

function Controller:SyncSenderReviewCases(round)
    local observations = {}
    for _, row in ipairs(self.snapshot and self.snapshot.rows or {}) do
        if row.sender_review_needed and row.sender_review_key then
            local observation = observations[row.sender_review_key]
            if not observation then
                observation = {
                    sender = row.sender,
                    count = 0,
                    copper = 0,
                }
                observations[row.sender_review_key] = observation
            end
            observation.count = observation.count + 1
            observation.copper = observation.copper + row.money
        end
    end

    local seen = {}
    for _, review in pairs(self.db.sender_reviews or {}) do
        if type(review) == "table" and review.round_id == round.id
            and Core.SafeString(review.sender_key, false) then
            local observation = observations[review.sender_key]
            local count = observation and observation.count or 0
            local previousCount = Core.SafeNumber(review.last_seen_count, 0) or 0
            review.current_count = count
            review.current_copper = observation and observation.copper or 0
            review.last_seen_count = count
            seen[review.sender_key] = true

            if observation and count > 0 and review.status == "resolved" then
                -- A saved match no longer identifies a current guild member.
                review.status = "needs_review"
                review.review_reason = "The saved guild-member match is no longer available."
            elseif observation and count > previousCount and review.status == "dismissed" then
                -- A later payment from a dismissed sender is a new case.
                review.status = "needs_review"
                review.review_reason = "A new payment from this unmatched sender was found."
            end
        end
    end

    for senderKey, observation in pairs(observations) do
        if not seen[senderKey] then
            local id = self.db.next_sender_review_id or 1
            self.db.next_sender_review_id = id + 1
            self.db.sender_reviews[id] = {
                id = id,
                round_id = round.id,
                sender = observation.sender,
                sender_key = senderKey,
                status = "needs_review",
                review_reason = "This sender's name could not be matched to one guild member.",
                current_count = observation.count,
                current_copper = observation.copper,
                last_seen_count = observation.count,
                created_at = self.api.now(),
            }
        end
    end

    for _, row in ipairs(self.snapshot and self.snapshot.rows or {}) do
        if row.sender_review_needed and row.sender_review_key then
            local review = findSenderReviewCase(self.db, round.id, row.sender_review_key)
            if review and review.status == "dismissed" then
                row.reason = "This sender review was closed without action. The mail remains untouched."
            elseif review and review.status == "needs_review" then
                row.reason = "This sender's name needs review. See the Review tab to match it manually."
            end
        end
    end
end

function Controller:AcceptSnapshot(snapshot, compare)
    self.snapshot = snapshot
    if compare then
        self:CompareObservation(snapshot)
    end
    self:ReclassifySnapshot()
    self:Notify()
end

function Controller:OnMailboxShow()
    self.mailbox_open = true
    self.snapshot = nil
    self.latest_status = "Loading the inbox. Keep the mailbox open while it scans."
    self:EnsureRoster(self:GetActiveRound())
    self:Notify()
end

function Controller:OnMailboxClosed()
    self.mailbox_open = false
    if self.collection and self.collection.running then
        self.collection.stop_requested = true
    end
    if self.in_flight then
        self:ReviewFlight("Mailbox closed before pickup confirmation.")
    end
    if self.collection then
        self:FinishCollection("Mailbox is closed. Collection stopped.")
    end
    self.collection_state = anyUnresolved(self.db) and "needs-review" or "idle"
    self.latest_status = "Mailbox is closed. Open it to scan for raffle payments."
    self:Notify()
end

function Controller:OnInboxUpdate()
    if not self.mailbox_open then
        return
    end
    self.inbox_generation = self.inbox_generation + 1
    local snapshot = self:BuildSnapshot()
    self:ArchiveMailSnapshot(snapshot, "Inbox scan")
    if self.in_flight then
        self.in_flight.saw_post_inbox = true
        self.in_flight.post_generation = self.inbox_generation
        self:AcceptSnapshot(snapshot, false)
        self:EvaluateFlight()
    else
        self:AcceptSnapshot(snapshot, true)
        if snapshot.total > snapshot.loaded then
            self.latest_status = string.format(
                "Inbox loaded %d of %d messages; more mail remains to check.",
                snapshot.loaded,
                snapshot.total
            )
        else
            self.latest_status = string.format("Inbox scanned: %d of %d messages.", snapshot.loaded, snapshot.total)
        end
        self:Notify()
    end
end

function Controller:OnGuildRosterUpdate()
    self:RefreshRoster()
    local active = self:GetActiveRound()
    local inGuild, guildId = self:GetGuild()
    if active and (not inGuild or not guildId or not sameGuild(active.guild_id, guildId)) then
        self:StopForGuildChange("Guild membership changed, so payment collection stopped.")
    end
end

function Controller:StopForGuildChange(reason)
    if self.collection then
        self.collection.stop_requested = true
        self.collection.running = false
    end
    if self.in_flight then
        self:ReviewFlight(reason or "Guild changed during pickup.")
    end
    self:InvalidateRoster()
    if not self.in_flight then
        self.collection_state = "idle"
    end
    self.latest_status = reason or "Guild changed. Waiting for the guild roster to load."
    self:Notify()
end

function Controller:OnPlayerGuildUpdate()
    self:InvalidateRoster()
    if self.collection then
        self.collection.stop_requested = true
    end
    if self.in_flight then
        self:ReviewFlight("Collector guild changed during pickup.")
    else
        self.collection_state = "idle"
    end
    self:RequestRoster()
    self.latest_status = "Guild changed. Waiting for the guild roster to load."
    self:Notify()
end

function Controller:GetPaymentRows()
    local payments = {}
    for _, row in ipairs(self.snapshot and self.snapshot.rows or {}) do
        if row.money and row.money > 0 then
            table.insert(payments, row)
        end
    end
    return payments
end

function Controller:CanCollect()
    if self.api.compatible == false then
        return false, self.api.compatibility_message or "This game version is not verified. Payment collection is disabled."
    end
    if self.db.collector_enabled ~= true then
        return false, "Turn on 'Use this character to collect' in the Collect tab first."
    end
    if type(self.api.isOpenAllRunning) == "function" then
        local openAllOK, openAllRunning = safeCall(self.api.isOpenAllRunning)
        if not openAllOK then
            return false, "Could not verify whether Open All is running. Try again before collecting."
        end
        if Core.SafeBoolean(openAllRunning) == true then
            return false, "Stop Open All before collecting raffle payments."
        end
    end
    if self.discrepancy then
        return false, "Check and acknowledge the inbox warning before collecting again."
    end
    if not self.mailbox_open then
        return false, "Open the mailbox before collecting payments."
    end
    local round = self:GetActiveRound()
    if not round then
        return false, "No raffle is accepting payments. Start one in Raffle Setup."
    end
    if anyUnresolved(self.db) then
        return false, "Review the pending pickup on the Review tab before collecting again."
    end
    local rosterReady, rosterReason = self:EnsureRoster(round)
    if not rosterReady then
        return false, rosterReason
    end
    local pending = getCommandPending(self.api)
    if pending ~= false then
        return false, "Waiting for WoW to finish the previous mail action."
    end
    local snapshot = self.snapshot
    if not snapshot or not snapshot.complete then
        return false, "Waiting for the inbox scan to finish. Keep the mailbox open."
    end
    return true
end

function Controller:StartCollection()
    local canCollect, reason = self:CanCollect()
    if not canCollect then
        self:SetStatus(reason)
        return false, reason
    end
    if self.collection and self.collection.running then
        return false, "Payment collection is already running."
    end

    local snapshot = self:BuildSnapshot()
    self:ArchiveMailSnapshot(snapshot, "Collect")
    self:AcceptSnapshot(snapshot, true)
    if not snapshot.complete then
        self:SetStatus("Waiting for the inbox scan to finish. Keep the mailbox open.")
        return false, "Inbox details are incomplete."
    end
    local round = self:GetActiveRound()
    local startOK, startedAt = safeCall(self.api.serverTime)
    self.collection = {
        running = true,
        stop_requested = false,
        payments_taken = 0,
        copper_taken = 0,
        tickets_added = 0,
        report_items = {},
        round_id = round and round.id,
        round_label = round and round.label,
        started_at = startOK and Core.SafeNumber(startedAt, 0) or nil,
        eligible_at_start = 0,
        skipped_at_start = 0,
    }
    for _, row in ipairs(self:GetPaymentRows()) do
        if row.eligible then
            self.collection.eligible_at_start = self.collection.eligible_at_start + 1
        else
            self.collection.skipped_at_start = self.collection.skipped_at_start + 1
        end
    end
    self.collection_state = "collecting"
    self.latest_status = "Collection started. Eligible payments will be collected one at a time."
    self:Notify()
    self:PumpCollection()
    return true
end

function Controller:StopCollection()
    if not self.collection or not self.collection.running then
        self:SetStatus("There is no payment collection to stop.")
        return
    end
    self.collection.stop_requested = true
    if not self.in_flight then
        self:FinishCollection("Payment collection stopped.")
    else
        self.collection_state = "stopping"
        self:SetStatus("Stopping after the current pickup finishes.")
    end
end

function Controller:FinishCollection(message)
    local collection = self.collection
    local completedFullPull = false
    if collection then
        collection.running = false
        if not collection.report_saved then
            collection.report_saved = true
            local timeOK, endedAt = safeCall(self.api.serverTime)
            local snapshot = self.snapshot
            local pending = getCommandPending(self.api)
            completedFullPull = message == "No eligible payments found in the loaded inbox."
                and (collection.payments_taken or 0) > 0
                and snapshot ~= nil
                and snapshot.complete == true
                and snapshot.loaded == snapshot.total
                and pending == false
                and self.in_flight == nil
                and not anyUnresolved(self.db)
                and not Core.HasUnresolvedSenderReviewsForRound(self.db, collection.round_id)
            self.db.last_collection_report = {
                raffle_id = collection.round_id,
                raffle_label = collection.round_label,
                started_at = collection.started_at,
                ended_at = timeOK and Core.SafeNumber(endedAt, 0) or nil,
                result = message,
                payments = collection.payments_taken or 0,
                copper = collection.copper_taken or 0,
                tickets = collection.tickets_added or 0,
                eligible_at_start = collection.eligible_at_start or 0,
                skipped_at_start = collection.skipped_at_start or 0,
                items = collection.report_items or {},
                complete_mailbox_pull = completedFullPull,
            }
        end
    end
    self.collection_state = anyUnresolved(self.db) and "needs-review" or "idle"
    self.latest_status = message
    self:Notify()
    if completedFullPull and ns.UI and type(ns.UI.OnCollectionFinished) == "function" then
        pcall(ns.UI.OnCollectionFinished, self, self.db.last_collection_report)
    end
end

function Controller:PumpCollection()
    local collection = self.collection
    if not collection or not collection.running or self.in_flight then
        return
    end
    if collection.stop_requested then
        self:FinishCollection("Payment collection stopped.")
        return
    end
    if collection.payments_taken >= MAX_BATCH_PAYMENTS then
        self:FinishCollection("Stopped after 20 pickups. Review the inbox before collecting again.")
        return
    end
    if not self.mailbox_open then
        self:FinishCollection("Mailbox closed. Payment collection stopped.")
        return
    end

    local canCollect, reason = self:CanCollect()
    if not canCollect then
        self:FinishCollection(reason)
        return
    end
    local snapshot = self:BuildSnapshot()
    self:AcceptSnapshot(snapshot, true)
    if not snapshot.complete then
        self:FinishCollection("Inbox details became unavailable. Payment collection stopped.")
        return
    end

    local selected
    for _, row in ipairs(snapshot.rows) do
        if row.eligible then
            selected = row
            break
        end
    end
    if not selected then
        self:FinishCollection("No eligible payments found in the loaded inbox.")
        return
    end

    local pending = getCommandPending(self.api)
    if pending ~= false then
        self:FinishCollection("Waiting for WoW to finish the previous mail action.")
        return
    end
    local walletOK, wallet = safeCall(self.api.getWallet)
    wallet = walletOK and Core.SafeNumber(wallet, 0) or nil
    if wallet == nil then
        self:FinishCollection("Could not read this character's money. No payment was collected.")
        return
    end

    local round = self:GetActiveRound()
    if not round or not selected.signature or not selected.member_name then
        self:FinishCollection("Payment details could not be verified. No payment was collected.")
        return
    end
    local countBefore = snapshot.signature_counts[selected.signature] or 0
    local stageTimeOK, stagedAt = safeCall(self.api.serverTime)
    stagedAt = stageTimeOK and Core.SafeNumber(stagedAt, 0) or nil
    if not stagedAt then
        self:FinishCollection("The current time could not be read. No payment was collected.")
        return
    end
    local receipt, stageReason = Core.CreateStagedReceipt(self.db, {
        round_id = round.id,
        character = selected.member_name,
        character_key = selected.member_key,
        character_guid = selected.member_guid,
        paid_copper = selected.money,
        tickets = selected.tickets,
        pre_wallet = wallet,
        staged_at = stagedAt,
        evidence = {
            signature = selected.signature,
            signature_count = countBefore,
            loaded = snapshot.loaded,
            total = snapshot.total,
            observed_at = snapshot.observed_at,
        },
    })
    if not receipt then
        self:FinishCollection(stageReason or "Could not prepare the payment record. No gold was collected.")
        return
    end

    self.in_flight = {
        receipt_id = receipt.id,
        signature = selected.signature,
        count_before = countBefore,
        amount = selected.money,
        wallet_before = wallet,
        started_at = self.api.now(),
        saw_post_inbox = false,
        post_generation = nil,
    }
    self.collection_state = "settling"
    local flight = self.in_flight
    self.api.after(PICKUP_TIMEOUT, function()
        if self.in_flight == flight then
            self:ReviewFlight("The pickup did not finish in time. Check this character's money and inbox.")
        end
    end)

    local callOK, result = safeCall(self.api.takeMoney, selected.index)
    if self.in_flight ~= flight then
        -- A mock or a client event may settle synchronously from inside the
        -- API call. Do not overwrite the resulting confirmed/review status.
        return
    end
    if not callOK or result == false then
        self:ReviewFlight("WoW could not collect the gold attached to this message.")
        return
    end
    self.latest_status = "Pickup in progress. Checking the inbox and character money before recording it."
    self:Notify()
end

function Controller:EvaluateFlight()
    local flight = self.in_flight
    if not flight then
        return
    end
    if not self.mailbox_open then
        self:ReviewFlight("Mailbox closed before pickup confirmation.")
        return
    end
    local round = self:GetActiveRound()
    local _, guildId = self:GetGuild()
    if not round or not guildId or not sameGuild(round.guild_id, guildId) then
        self:ReviewFlight("The guild or active raffle changed during the pickup.")
        return
    end
    if not flight.saw_post_inbox then
        return
    end
    local pending = getCommandPending(self.api)
    if pending ~= false then
        return
    end

    local snapshot = self:BuildSnapshot()
    if not snapshot.complete then
        self:ReviewFlight("Inbox details could not be read after the pickup.")
        return
    end
    local countAfter = snapshot.signature_counts[flight.signature] or 0
    local expectedCount = flight.count_before - 1
    if countAfter < expectedCount then
        self:ReviewFlight("More than one matching payment message changed during pickup.")
        return
    end

    local walletOK, wallet = safeCall(self.api.getWallet)
    wallet = walletOK and Core.SafeNumber(wallet, 0) or nil
    if wallet == nil then
        self:ReviewFlight("This character's money could not be read after the pickup.")
        return
    end
    local walletGain = wallet - flight.wallet_before

    if countAfter == expectedCount and walletGain == flight.amount then
        self:CommitFlight(snapshot)
        return
    end
    if countAfter == expectedCount and walletGain > flight.amount then
        self:ReviewFlight("This character's money increased by more than this message's payment.")
    elseif walletGain > flight.amount then
        self:ReviewFlight("This character's money changed by an unexpected amount during pickup.")
    end
end

function Controller:CommitFlight(snapshot)
    local flight = self.in_flight
    if not flight then
        return
    end
    local nowOK, registeredAt = safeCall(self.api.serverTime)
    registeredAt = nowOK and Core.SafeNumber(registeredAt, 0) or nil
    if not registeredAt then
        self:ReviewFlight("The pickup may have succeeded, but its registration time could not be saved.")
        return
    end
    local receipt = self.db.receipts[flight.receipt_id]
    local ok = Core.ConfirmReceipt(self.db, flight.receipt_id, registeredAt, "mailbox")
    if not ok then
        self:ReviewFlight("The payment could not be saved to raffle history.")
        return
    end

    self.in_flight = nil
    self.collection_state = "collecting"
    self.collection.payments_taken = self.collection.payments_taken + 1
    self.collection.copper_taken = self.collection.copper_taken + flight.amount
    self.collection.tickets_added = self.collection.tickets_added + (receipt and receipt.tickets or 0)
    table.insert(self.collection.report_items, string.format(
        "%s — %s — %d ticket(s)",
        receipt and receipt.character or "Unknown member",
        tostring(flight.amount) .. " copper",
        receipt and receipt.tickets or 0
    ))
    self.snapshot = snapshot
    -- The inbox change is expected for the just-confirmed pickup. Retain even
    -- partial snapshots so a later load does not mistake this pickup for an
    -- unrelated disappearance.
    self:StoreObservation(snapshot)
    self:ReclassifySnapshot()
    self:Notify()

    if self.collection.stop_requested then
        self:FinishCollection("Payment recorded. Collection stopped.")
        return
    end
    if self.collection.payments_taken >= MAX_BATCH_PAYMENTS then
        self:FinishCollection("Stopped after 20 pickups. Review the inbox before continuing.")
        return
    end

    self.latest_status = "Payment recorded. Checking the inbox before the next pickup."
    self:Notify()
    self.api.after(PICKUP_DELAY, function()
        if self.collection and self.collection.running and not self.in_flight then
            if self.mailbox_open then
                self:RequestInboxRefreshIfNeeded()
                self:PumpCollection()
            else
                self:FinishCollection("Mailbox closed. Payment collection stopped.")
            end
        end
    end)
end

function Controller:RequestInboxRefreshIfNeeded()
    if not self.mailbox_open or not self.snapshot
        or self.snapshot.total <= self.snapshot.loaded then
        return
    end
    local ok, canCheck, wait = safeCall(self.api.canCheckInbox)
    if not ok then
        return
    end
    canCheck = Core.SafeBoolean(canCheck)
    if canCheck then
        safeCall(self.api.checkInbox)
    elseif Core.SafeNumber(wait, 0) and wait > 0 then
        self.api.after(wait, function()
            if self.mailbox_open then
                local retryOK, retryCanCheck = safeCall(self.api.canCheckInbox)
                if retryOK and Core.SafeBoolean(retryCanCheck) == true then
                    safeCall(self.api.checkInbox)
                end
            end
        end)
    end
end

function Controller:ReviewFlight(reason)
    local flight = self.in_flight
    if not flight then
        return
    end
    local snapshot = self:BuildSnapshot()
    local walletOK, walletAfter = safeCall(self.api.getWallet)
    walletAfter = walletOK and Core.SafeNumber(walletAfter, 0) or nil
    local pending = getCommandPending(self.api)
    local evidence = {
        wallet_after = walletAfter,
        wallet_delta = walletAfter and (walletAfter - flight.wallet_before) or nil,
        inbox_loaded = snapshot.loaded,
        inbox_total = snapshot.total,
        inbox_complete = snapshot.complete,
        matching_funded_count = snapshot.signature_counts[flight.signature],
        mail_command_pending = pending,
    }
    Core.MarkNeedsReview(self.db, flight.receipt_id, reason, evidence)
    self.in_flight = nil
    self.collection_state = "needs-review"
    if self.collection then
        self.collection.running = false
        self.collection.stop_requested = true
    end
    if snapshot.complete then
        self.snapshot = snapshot
        self:StoreObservation(snapshot)
    end
    self:ReclassifySnapshot()
    self.latest_status = "Pickup needs review: " .. reason
    if self.collection then
        table.insert(self.collection.report_items, string.format(
            "Pickup #%s — needs review: %s",
            tostring(flight.receipt_id),
            reason
        ))
        self:FinishCollection(self.latest_status)
    else
        self:Notify()
    end
end

function Controller:OnMailSuccess()
    self:EvaluateFlight()
end

function Controller:OnMailFailed()
    if self.in_flight then
        self:ReviewFlight("WoW reported that it could not collect the gold.")
    end
end

function Controller:OnPlayerMoney()
    self:EvaluateFlight()
end

function Controller:ReviewReceipt(receiptId)
    local receipt = self.db.receipts[receiptId]
    if not receipt or receipt.status ~= "needs_review" then
        return false, "This pickup is no longer waiting for review."
    end
    return true, receipt
end

function Controller:DismissReview(receiptId)
    local ok, reason = Core.DismissReceipt(self.db, receiptId, {
        time = self.api.serverTime(),
        text = "Officer dismissed without credit.",
    })
    if ok then
        self.collection_state = anyUnresolved(self.db) and "needs-review" or "idle"
        self:SetStatus("Pickup attempt dismissed. No tickets were added.")
    end
    return ok, reason
end

function Controller:ResolveSenderReview(reviewId, memberName)
    local review = Core.GetSenderReviewCase(self.db, reviewId)
    if not review or review.status ~= "needs_review" then
        return false, "This sender review is no longer waiting for action."
    end
    if self.in_flight or self.collection and self.collection.running then
        return false, "Wait for collection to stop before matching a sender. The mail will remain untouched."
    end
    local round = Core.GetRound(self.db, review.round_id)
    if not round then
        return false, "The raffle for this sender review could not be found."
    end
    local rosterReady, rosterReason = self:EnsureRoster(round)
    if not rosterReady or not self.roster then
        return false, rosterReason
    end
    local memberKey = Core.NormalizeFullName(memberName)
    local matches = memberKey and self.roster.by_name[memberKey] or nil
    if not matches or #matches == 0 then
        return false, "That name is not in the current guild roster. Enter the member's full name exactly as shown."
    end
    if #matches ~= 1 then
        return false, "That name matches more than one guild member. The sender cannot be assigned safely."
    end

    local member = matches[1]
    self.db.sender_aliases[review.sender_key] = {
        sender = review.sender,
        guild_id = round.guild_id,
        member_name = member.name,
        member_key = member.key,
        member_guid = member.guid,
    }
    review.status = "resolved"
    review.review_outcome = "matched_to_guild_member"
    review.matched_member_name = member.name
    local timeOK, reviewedAt = safeCall(self.api.serverTime)
    review.reviewed_at = timeOK and Core.SafeNumber(reviewedAt, 0) or nil
    review.review_reason = nil
    self:ReclassifySnapshot()
    self:SetStatus("Sender matched to " .. member.name .. ". The mail stays in your inbox and is rechecked against the raffle rules; collect it from the Collect tab if eligible.")
    return true, member
end

function Controller:DismissSenderReview(reviewId)
    local review = Core.GetSenderReviewCase(self.db, reviewId)
    if not review or review.status ~= "needs_review" then
        return false, "This sender review is no longer waiting for action."
    end
    review.status = "dismissed"
    review.review_outcome = "dismissed_without_credit"
    local timeOK, reviewedAt = safeCall(self.api.serverTime)
    review.reviewed_at = timeOK and Core.SafeNumber(reviewedAt, 0) or nil
    self:ReclassifySnapshot()
    self:SetStatus("Sender review closed without credit or a name match. The mail was left untouched.")
    return true
end

function Controller:ConfirmReviewManually(receiptId, reconciled)
    local ok, result = Core.ManuallyConfirmReceipt(
        self.db,
        receiptId,
        self.api.serverTime(),
        reconciled
    )
    if ok then
        self.collection_state = anyUnresolved(self.db) and "needs-review" or "idle"
        self:SetStatus("Payment added to its original raffle after manual review.")
    end
    return ok, result
end

function Controller:CloseRound(roundId)
    local round = Core.GetRound(self.db, roundId)
    local checklist = self:GetCloseChecklist(roundId)
    local entries = Core.GetRoundEntries(self.db, roundId)
    local identities = {}
    for _, receipt in ipairs(entries) do
        local key = receipt.character_guid and ("guid:" .. receipt.character_guid)
            or ("name:" .. tostring(receipt.character_key or receipt.character or ""))
        identities[key] = true
    end
    local payments, tickets, copper = Core.GetRoundTotals(self.db, roundId)
    local closeOK, closeTime = safeCall(self.api.serverTime)
    local ok, reason = Core.CloseRound(
        self.db,
        roundId,
        closeOK and Core.SafeNumber(closeTime, 0) or nil
    )
    if ok and self.collection and self.collection.running then
        self.collection.stop_requested = true
        self:FinishCollection("Collection ended because the raffle was closed.")
    end
    if ok and round then
        self.db.last_closed_round_summary = {
            raffle_id = round.id,
            raffle_label = round.label,
            closed_at = closeTime,
            payments = payments,
            tickets = tickets,
            copper = copper,
            members = Core.SafeNumber((function()
                local count = 0
                for _ in pairs(identities) do count = count + 1 end
                return count
            end)(), 0),
            eligible_waiting = checklist.eligible_waiting,
            waiting_copper = checklist.waiting_copper,
            loaded = checklist.loaded,
            total = checklist.total,
            scan_complete = checklist.scan_complete,
            unresolved = checklist.unresolved,
        }
    end
    return ok, reason
end

function Controller:GetCloseChecklist(roundId)
    local snapshot = self.mailbox_open and self.snapshot or nil
    local complete = snapshot and snapshot.complete and snapshot.loaded == snapshot.total or false
    local observedAt = snapshot and Core.SafeFiniteNumber(snapshot.observed_at, 0) or nil
    local now = Core.SafeFiniteNumber(self.api.now(), 0)
    local scanAge = observedAt and now and math.max(0, now - observedAt) or nil
    local eligible, waitingCopper = 0, 0
    if snapshot and snapshot.round_id == roundId or snapshot and roundId == self.db.active_round_id then
        for _, row in ipairs(snapshot.rows or {}) do
            if row.eligible then
                eligible = eligible + 1
                waitingCopper = waitingCopper + (row.money or 0)
            end
        end
    end
    local unresolved = 0
    for _, receipt in pairs(self.db.receipts or {}) do
        if type(receipt) == "table" and receipt.round_id == roundId
            and (receipt.status == "pending" or receipt.status == "needs_review") then
            unresolved = unresolved + 1
        end
    end
    for _, review in pairs(self.db.sender_reviews or {}) do
        if type(review) == "table" and review.round_id == roundId
            and review.status == "needs_review"
            and Core.SafeNumber(review.id, 1)
            and Core.SafeString(review.sender_key, false) then
            unresolved = unresolved + 1
        end
    end
    return {
        scan_complete = complete,
        loaded = snapshot and snapshot.loaded or 0,
        total = snapshot and snapshot.total or 0,
        scan_age_seconds = scanAge,
        eligible_waiting = eligible,
        waiting_copper = waitingCopper,
        unresolved = unresolved,
    }
end

function Controller:MarkFullExportGenerated()
    local ok, timestamp = safeCall(self.api.serverTime)
    timestamp = ok and Core.SafeNumber(timestamp, 0) or nil
    if not timestamp then
        return false, "The current time is unavailable; the export was not timestamped."
    end
    self.db.last_full_export_generated_at = timestamp
    return true
end

function Controller:MarkBackupConfirmedLocally()
    local ok, timestamp = safeCall(self.api.serverTime)
    timestamp = ok and Core.SafeNumber(timestamp, 0) or nil
    if not timestamp then
        return false, "The current time is unavailable."
    end
    self.db.last_full_backup_confirmed_at = timestamp
    return true
end

function Controller:ImportBackup(text)
    if self.mailbox_open or self.in_flight
        or (self.collection and self.collection.running) then
        return false, "Close the mailbox and stop collection before importing a backup."
    end
    local imported, reason = ns.Backup.Decode(text, Core)
    if not imported then
        return false, reason
    end
    self.db = imported
    GuildRaffleMailboxDB = imported
    ns.db = imported
    self.previous_observation = loadStoredObservation(imported)
    self.snapshot = nil
    self.discrepancy = nil
    self:InvalidateRoster()
    self.collection = nil
    self.collection_state = anyUnresolved(imported) and "needs-review" or "idle"
    self.latest_status = "Full backup imported. Unfinished pickups and open sender-name reviews are in Review; verify the restored state before collecting."
    self:Notify()
    return true
end

function Controller:StartRound(label, presetId)
    local inGuild, guildId, guildName = self:GetGuild()
    if not inGuild or not guildId then
        return false, "Collector must be in a guild with initialized club data."
    end
    local ready, reason = self:EnsureRoster(nil)
    if not ready then
        return false, reason
    end
    return Core.StartRound(self.db, label, presetId, guildId, guildName, self.api.serverTime())
end

function Controller:OnEvent(event, ...)
    if event == "MAIL_SHOW" then
        self:OnMailboxShow()
    elseif event == "MAIL_INBOX_UPDATE" then
        self:OnInboxUpdate()
    elseif event == "MAIL_CLOSED" then
        self:OnMailboxClosed()
    elseif event == "GUILD_ROSTER_UPDATE" then
        self:OnGuildRosterUpdate()
    elseif event == "PLAYER_GUILD_UPDATE" then
        self:OnPlayerGuildUpdate()
    elseif event == "MAIL_SUCCESS" then
        self:OnMailSuccess(...)
    elseif event == "MAIL_FAILED" then
        self:OnMailFailed(...)
    elseif event == "PLAYER_MONEY" then
        self:OnPlayerMoney()
    end
end

function Controller.CreateDefaultAPI()
    local api = {}
    local buildMessage = nil
    local interfaceId = nil
    if type(GetBuildInfo) == "function" then
        -- The fourth result is select(4, GetBuildInfo()), the TOC/interface id.
        local ok, version, build, _, interface = pcall(GetBuildInfo)
        if ok then
            interfaceId = Core.SafeNumber(interface, 0)
            if interfaceId ~= 16001 then
                buildMessage = "This client uses interface " .. tostring(interface or "unknown")
                    .. "; GuildRaffleMailbox requires Forever interface 16001."
            elseif version ~= "1.60.1" or build ~= "71037" then
                buildMessage = "This game version is not verified for GuildRaffleMailbox. Payment collection is disabled."
            end
        else
            buildMessage = "Could not verify this game version. Payment collection is disabled."
        end
    else
        buildMessage = "Could not verify this game version. Payment collection is disabled."
    end

    local required = {
        type(GetInboxNumItems) == "function",
        type(GetInboxHeaderInfo) == "function",
        type(TakeInboxMoney) == "function",
        type(GetMoney) == "function",
        type(GetServerTime) == "function",
        type(C_Mail) == "table" and type(C_Mail.IsCommandPending) == "function",
        type(C_Mail) == "table" and type(C_Mail.CanCheckInbox) == "function",
        type(CheckInbox) == "function",
        type(C_GuildInfo) == "table" and type(C_GuildInfo.GuildRoster) == "function",
        type(C_Club) == "table" and type(C_Club.GetGuildClubId) == "function",
        type(C_Timer) == "table" and type(C_Timer.After) == "function",
        type(GetNumGuildMembers) == "function",
        type(GetGuildRosterInfo) == "function",
        type(CaseAccentInsensitiveParse) == "function",
    }
    local missing = false
    for _, available in ipairs(required) do
        if not available then
            missing = true
        end
    end
    if missing then
        local missingMessage
        if type(CaseAccentInsensitiveParse) ~= "function" then
            missingMessage = "The required name-matching API is unavailable. Payment collection is disabled."
        else
            missingMessage = "A required mail or guild feature is unavailable. Payment collection is disabled."
        end
        buildMessage = buildMessage or missingMessage
    end
    api.compatible = interfaceId == 16001 and not missing
        and buildMessage == nil
    api.compatibility_message = buildMessage

    api.now = function()
        if type(GetTime) == "function" then
            local value = GetTime()
            return Core.SafeFiniteNumber(value, 0) or 0
        end
        return 0
    end
    api.serverTime = function()
        if type(GetServerTime) == "function" then
            return GetServerTime()
        end
        return nil
    end
    api.isInGuild = function()
        return type(IsInGuild) == "function" and IsInGuild() or false
    end
    api.getGuildClubId = function()
        return C_Club.GetGuildClubId()
    end
    api.getGuildName = function()
        if type(GetGuildInfo) == "function" then
            return GetGuildInfo("player")
        end
        return nil
    end
    api.requestRoster = function()
        return C_GuildInfo.GuildRoster()
    end
    api.getGuildMemberCount = function()
        return GetNumGuildMembers()
    end
    api.getGuildMemberInfo = function(index)
        local values = { GetGuildRosterInfo(index) }
        -- Forever's roster name is return 1 and the member GUID is return 17.
        return values[1], values[17]
    end
    api.getInboxCounts = function()
        return GetInboxNumItems()
    end
    api.getInboxHeader = function(index)
        -- Forever header positions: sender 3, subject 4, money 5, COD 6,
        -- attachments 8, returned 10, can-reply 12, and GM 13.
        local _, _, sender, subject, money, cod, _, attachments, _, returned, _, canReply, isGM =
            GetInboxHeaderInfo(index)
        return {
            sender = sender,
            subject = subject,
            money = money,
            cod = cod,
            attachment_count = attachments,
            returned = returned,
            can_reply = canReply,
            is_gm = isGM,
        }
    end
    api.getWallet = function()
        return GetMoney()
    end
    api.commandPending = function()
        return C_Mail.IsCommandPending()
    end
    api.isOpenAllRunning = function()
        return false
    end
    api.takeMoney = function(index)
        return TakeInboxMoney(index)
    end
    api.canCheckInbox = function()
        return C_Mail.CanCheckInbox()
    end
    api.checkInbox = function()
        return CheckInbox()
    end
    api.after = function(seconds, callback)
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(seconds, callback)
        end
    end
    return api
end

local function verifyBuildInfo()
    local api = Controller.CreateDefaultAPI()
    return api.compatible, api.compatibility_message
end
ns.VerifyClientAPI = verifyBuildInfo

local function initializeAddon()
    local db = Core.InitializeDB(GuildRaffleMailboxDB)
    GuildRaffleMailboxDB = db
    local api = Controller.CreateDefaultAPI()
    local controller = Controller.new(db, api, function()
        if ns.UI and ns.UI.Refresh then
            ns.UI.Refresh()
        end
    end)
    ns.db = db
    ns.controller = controller
    if api.compatible then
        controller:RequestRoster()
    else
        controller.latest_status = api.compatibility_message or "Client API verification failed."
    end
    if ns.UI and ns.UI.Initialize then
        ns.UI.Initialize(controller)
    end
end

if type(CreateFrame) == "function" then
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "ADDON_LOADED" then
            local loadedName = ...
            if loadedName == ADDON_NAME then
                eventFrame:UnregisterEvent("ADDON_LOADED")
                initializeAddon()
                local events = {
                    "MAIL_SHOW",
                    "MAIL_INBOX_UPDATE",
                    "MAIL_CLOSED",
                    "MAIL_SUCCESS",
                    "MAIL_FAILED",
                    "PLAYER_MONEY",
                    "GUILD_ROSTER_UPDATE",
                    "PLAYER_GUILD_UPDATE",
                }
                for _, registeredEvent in ipairs(events) do
                    eventFrame:RegisterEvent(registeredEvent)
                end
            end
        elseif ns.controller then
            ns.controller:OnEvent(event, ...)
        end
    end)
end
