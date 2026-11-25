local ADDON_NAME, ns = ...

local Core = {}
ns.Core = Core

local function isSecret(value)
    if type(issecretvalue) ~= "function" then
        return false
    end
    local ok, result = pcall(issecretvalue, value)
    return not ok or result == true
end

function Core.IsSafe(value)
    if isSecret(value) then
        return false
    end
    return value ~= nil
end

function Core.IsMissing(value)
    return not isSecret(value) and value == nil
end

function Core.SafeString(value, allowEmpty)
    if not Core.IsSafe(value) or type(value) ~= "string" then
        return nil
    end
    if not allowEmpty and value == "" then
        return nil
    end
    return value
end

function Core.SafeFiniteNumber(value, minimum)
    if not Core.IsSafe(value) or type(value) ~= "number" then
        return nil
    end
    if value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    if value < (minimum or 0) then
        return nil
    end
    return value
end

function Core.SafeNumber(value, minimum)
    value = Core.SafeFiniteNumber(value, minimum)
    if value == nil or value ~= math.floor(value) then
        return nil
    end
    return value
end

function Core.SafeBoolean(value)
    if not Core.IsSafe(value) or type(value) ~= "boolean" then
        return nil
    end
    return value
end

function Core.NormalizeFullName(name)
    name = Core.SafeString(name, false)
    if not name then
        return nil
    end
    -- Do not strip a surname or realm-like suffix. Forever character names are
    -- matched as complete names; live-client formatting must be verified.
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    if name == "" then
        return nil
    end
    -- Forever folds case for common accented Latin characters while preserving
    -- their accents; it is not a general Unicode normalization function.
    if type(CaseAccentInsensitiveParse) ~= "function" then
        return nil
    end
    local ok, normalized = pcall(CaseAccentInsensitiveParse, name)
    if not ok or not Core.IsSafe(normalized) or type(normalized) ~= "string" or normalized == "" then
        return nil
    end
    return normalized
end

local function positiveInteger(value)
    return Core.SafeNumber(value, 1)
end

function Core.ValidatePreset(name, priceCopper, cap)
    name = Core.SafeString(name, false)
    if not name then
        return false, "Enter a name for these ticket rules."
    end
    priceCopper = positiveInteger(priceCopper)
    if not priceCopper then
        return false, "Enter a ticket price as a positive whole number of copper (10,000 copper = 1 gold)."
    end
    if cap ~= nil and cap ~= "" then
        cap = positiveInteger(cap)
        if not cap then
            return false, "Enter a positive whole-number ticket limit, or leave it blank for no limit."
        end
    else
        cap = nil
    end
    return true, {
        name = name,
        price_copper = priceCopper,
        cap_per_character = cap,
    }
end

local function ensureTable(parent, key)
    if type(parent[key]) ~= "table" then
        parent[key] = {}
    end
    return parent[key]
end

local DEFAULT_PRESETS = {
    {
        id = "10s",
        name = "10s per ticket",
        price_copper = 1000,
        cap_per_character = nil,
    },
    {
        id = "1g",
        name = "1g per ticket",
        price_copper = 10000,
        cap_per_character = 1,
    },
}

local function maxIntegerKey(values)
    local maximum = 0
    for key in pairs(values) do
        if type(key) == "number" and key == math.floor(key) and key > maximum then
            maximum = key
        end
    end
    return maximum
end

function Core.InitializeDB(db)
    if type(db) ~= "table" then
        db = {}
    end
    db.schema_version = 1
    db.presets = ensureTable(db, "presets")
    db.preset_order = ensureTable(db, "preset_order")
    db.rounds = ensureTable(db, "rounds")
    db.round_order = ensureTable(db, "round_order")
    db.receipts = ensureTable(db, "receipts")
    db.mail_history = ensureTable(db, "mail_history")
    db.mail_history_seen_counts = ensureTable(db, "mail_history_seen_counts")
    db.sender_aliases = ensureTable(db, "sender_aliases")
    db.sender_reviews = ensureTable(db, "sender_reviews")
    db.next_receipt_id = Core.SafeNumber(db.next_receipt_id, 1) or 1
    db.next_round_id = Core.SafeNumber(db.next_round_id, 1) or 1
    db.next_mail_history_id = Core.SafeNumber(db.next_mail_history_id, 1) or 1
    db.next_sender_review_id = Core.SafeNumber(db.next_sender_review_id, 1) or 1
    db.collector_enabled = db.collector_enabled == true

    if #db.preset_order == 0 then
        for _, preset in ipairs(DEFAULT_PRESETS) do
            db.presets[preset.id] = {
                id = preset.id,
                name = preset.name,
                price_copper = preset.price_copper,
                cap_per_character = preset.cap_per_character,
            }
            table.insert(db.preset_order, preset.id)
        end
    else
        for _, preset in ipairs(DEFAULT_PRESETS) do
            if not db.presets[preset.id] then
                db.presets[preset.id] = {
                    id = preset.id,
                    name = preset.name,
                    price_copper = preset.price_copper,
                    cap_per_character = preset.cap_per_character,
                }
                table.insert(db.preset_order, preset.id)
            end
        end
    end

    if not db.presets[db.selected_preset_id] then
        db.selected_preset_id = db.preset_order[1]
    end

    local maximumRound = maxIntegerKey(db.rounds)
    if db.next_round_id <= maximumRound then
        db.next_round_id = maximumRound + 1
    end
    local maximumReceipt = maxIntegerKey(db.receipts)
    if db.next_receipt_id <= maximumReceipt then
        db.next_receipt_id = maximumReceipt + 1
    end
    local maximumMailHistoryId = 0
    for _, entry in pairs(db.mail_history) do
        if type(entry) == "table" then
            local id = Core.SafeNumber(entry.id, 0)
            if id and id > maximumMailHistoryId then
                maximumMailHistoryId = id
            end
        end
    end
    if db.next_mail_history_id <= maximumMailHistoryId then
        db.next_mail_history_id = maximumMailHistoryId + 1
    end
    local maximumSenderReviewId = maxIntegerKey(db.sender_reviews)
    if db.next_sender_review_id <= maximumSenderReviewId then
        db.next_sender_review_id = maximumSenderReviewId + 1
    end

    -- A staged operation is never replayed after reload. Its outcome is
    -- ambiguous until an officer reviews the saved evidence.
    for _, receipt in pairs(db.receipts) do
        if type(receipt) == "table" and receipt.status == "pending" then
            receipt.status = "needs_review"
            receipt.review_reason = "The game closed before this pickup could be confirmed. Check the character's money and inbox before recording it."
            receipt.restored_for_review = true
        end
    end

    local activeRound = db.active_round_id and db.rounds[db.active_round_id]
    if not activeRound or activeRound.status ~= "active" then
        db.active_round_id = nil
    end
    return db
end

function Core.GetPreset(db, presetId)
    return db and db.presets and db.presets[presetId] or nil
end

function Core.SavePreset(db, presetId, name, priceCopper, cap)
    local ok, presetOrReason = Core.ValidatePreset(name, priceCopper, cap)
    if not ok then
        return false, presetOrReason
    end

    local id = presetId
    if not id or id == "" then
        id = "custom-" .. tostring((db.next_custom_preset_id or 1))
        db.next_custom_preset_id = (db.next_custom_preset_id or 1) + 1
        while db.presets[id] do
            id = "custom-" .. tostring(db.next_custom_preset_id)
            db.next_custom_preset_id = db.next_custom_preset_id + 1
        end
        table.insert(db.preset_order, id)
    elseif not db.presets[id] then
        return false, "That ticket-rules preset is no longer available."
    end

    local preset = presetOrReason
    preset.id = id
    db.presets[id] = preset
    db.selected_preset_id = id
    return true, id
end

function Core.StartRound(db, label, presetId, guildId, guildName, startTime)
    label = Core.SafeString(label, false)
    local preset = Core.GetPreset(db, presetId)
    if not label then
        return false, "Enter a name for this raffle."
    end
    if db.active_round_id and db.rounds[db.active_round_id]
        and db.rounds[db.active_round_id].status == "active" then
        return false, "Close the current raffle before starting another."
    end
    if not preset then
        return false, "Choose valid ticket rules before starting the raffle."
    end
    if not Core.IsSafe(guildId) then
        return false, "Guild details are not ready yet. Wait for the guild roster to load."
    end
    if type(guildId) == "number" then
        guildId = Core.SafeNumber(guildId, 1)
    elseif type(guildId) == "string" then
        guildId = Core.SafeString(guildId, false)
    else
        guildId = nil
    end
    if not guildId then
        return false, "Guild details are not ready yet. Wait for the guild roster to load."
    end
    if not Core.SafeNumber(startTime, 0) then
        return false, "The current game time is unavailable."
    end

    local id = db.next_round_id
    db.next_round_id = id + 1
    local round = {
        id = id,
        label = label,
        status = "active",
        start_time = startTime,
        guild_id = guildId,
        guild_name = Core.SafeString(guildName, true),
        preset = {
            id = preset.id,
            name = preset.name,
            price_copper = preset.price_copper,
            cap_per_character = preset.cap_per_character,
        },
    }
    db.rounds[id] = round
    table.insert(db.round_order, id)
    db.active_round_id = id
    db.selected_round_id = id
    return true, round
end

function Core.GetRound(db, roundId)
    if not db or not db.rounds then
        return nil
    end
    return db.rounds[roundId]
end

function Core.GetRoundEntries(db, roundId)
    local entries = {}
    for _, receipt in pairs(db.receipts or {}) do
        if type(receipt) == "table"
            and receipt.round_id == roundId
            and receipt.status == "confirmed" then
            table.insert(entries, receipt)
        end
    end
    table.sort(entries, function(left, right)
        return left.id < right.id
    end)
    return entries
end

function Core.GetRoundTotals(db, roundId)
    local payments, tickets = 0, 0
    local entries = Core.GetRoundEntries(db, roundId)
    for _, receipt in ipairs(entries) do
        payments = payments + (receipt.paid_copper or 0)
        tickets = tickets + (receipt.tickets or 0)
    end
    return #entries, tickets, payments
end

function Core.HasUnresolvedSenderReviewsForRound(db, roundId)
    for _, review in pairs(db.sender_reviews or {}) do
        if type(review) == "table"
            and review.round_id == roundId
            and review.status == "needs_review"
            and Core.SafeNumber(review.id, 1)
            and Core.SafeString(review.sender_key, false) then
            return true
        end
    end
    return false
end

function Core.HasUnresolvedForRound(db, roundId)
    for _, receipt in pairs(db.receipts or {}) do
        if type(receipt) == "table"
            and receipt.round_id == roundId
            and (receipt.status == "pending" or receipt.status == "needs_review") then
            return true
        end
    end
    return Core.HasUnresolvedSenderReviewsForRound(db, roundId)
end

function Core.CloseRound(db, roundId, closeTime)
    local round = Core.GetRound(db, roundId)
    if not round or round.status ~= "active" then
        return false, "This raffle is not currently accepting payments."
    end
    if Core.HasUnresolvedForRound(db, roundId) then
        return false, "Resolve or dismiss all pending review items before closing this raffle."
    end
    if not Core.SafeNumber(closeTime, 0) then
        return false, "The current game time is unavailable."
    end
    round.status = "closed"
    round.close_time = closeTime
    if db.active_round_id == roundId then
        db.active_round_id = nil
    end
    return true
end

function Core.ResetRoundEntries(db, roundId)
    local round = Core.GetRound(db, roundId)
    if not round then
        return false, "This raffle is no longer available."
    end
    if round.status ~= "active" then
        return false, "Only an active raffle's entries can be cleared; closed raffles are archives."
    end
    if Core.HasUnresolvedForRound(db, roundId) then
        return false, "Resolve or dismiss all pending review items before clearing this raffle's entries."
    end

    local oldEntries = Core.GetRoundEntries(db, roundId)
    local tickets = 0
    for _, receipt in ipairs(oldEntries) do
        tickets = tickets + (receipt.tickets or 0)
        if receipt.review_outcome then
            -- Keep a manually resolved staged operation as an audit record,
            -- while removing it from the confirmed-entry ledger.
            receipt.status = "reset"
            receipt.ledger_cleared = true
        else
            db.receipts[receipt.id] = nil
        end
    end
    return true, #oldEntries, tickets
end

local function sameIdentity(receipt, identity)
    if receipt.character_guid and identity.guid then
        return receipt.character_guid == identity.guid
    end
    return receipt.character_key ~= nil and receipt.character_key == identity.key
end

function Core.GetTicketsForIdentity(db, roundId, identity, excludedReceiptId)
    local tickets = 0
    for _, receipt in ipairs(Core.GetRoundEntries(db, roundId)) do
        if receipt.id ~= excludedReceiptId and sameIdentity(receipt, identity) then
            tickets = tickets + (receipt.tickets or 0)
        end
    end
    return tickets
end

local function validateLedgerEntry(round, character, paidCopper)
    character = Core.SafeString(character, false)
    if not character then
        return nil, "Enter the member name to record."
    end
    character = string.gsub(character, "^%s+", "")
    character = string.gsub(character, "%s+$", "")
    if character == "" or string.len(character) > 96 or string.find(character, "%c") then
        return nil, "Enter a member name up to 96 characters, without line breaks."
    end
    local characterKey = Core.NormalizeFullName(character)
    if not characterKey or characterKey == "" then
        return nil, "That member name could not be normalized."
    end
    paidCopper = Core.SafeNumber(paidCopper, 1)
    if not paidCopper then
        return nil, "Enter a positive whole-copper payment amount."
    end
    local price = round and round.preset and Core.SafeNumber(round.preset.price_copper, 1)
    if not price or paidCopper % price ~= 0 then
        return nil, "Payment must be an exact multiple of this raffle's ticket price."
    end
    local tickets = Core.SafeNumber(paidCopper / price, 1)
    if not tickets then
        return nil, "That payment does not produce a valid whole-number ticket count."
    end
    return {
        character = character,
        character_key = characterKey,
        paid_copper = paidCopper,
        ticket_price_copper = price,
        tickets = tickets,
    }
end

function Core.CreateManualEntry(db, roundId, character, paidCopper, registeredAt)
    local round = Core.GetRound(db, roundId)
    if not round or round.status ~= "active" or db.active_round_id ~= roundId then
        return nil, "Manual entries can only be added to an active raffle."
    end
    registeredAt = Core.SafeNumber(registeredAt, 0)
    if registeredAt == nil then
        return nil, "The current game time is unavailable."
    end
    local values, reason = validateLedgerEntry(round, character, paidCopper)
    if not values then
        return nil, reason
    end

    local identity = { key = values.character_key }
    local currentTickets = Core.GetTicketsForIdentity(db, roundId, identity)
    local cap = round.preset.cap_per_character
    if cap and currentTickets + values.tickets > cap then
        return nil, "Adding this entry would exceed the ticket limit for this name."
    end

    local id = db.next_receipt_id
    db.next_receipt_id = id + 1
    local receipt = {
        id = id,
        round_id = roundId,
        status = "confirmed",
        character = values.character,
        character_key = values.character_key,
        paid_copper = values.paid_copper,
        ticket_price_copper = values.ticket_price_copper,
        tickets = values.tickets,
        registered_at = registeredAt,
        registration_source = "manual",
        manual_entry = true,
    }
    db.receipts[id] = receipt
    return receipt
end

function Core.UpdateConfirmedEntry(db, roundId, receiptId, values, editedAt)
    local round = Core.GetRound(db, roundId)
    if not round or round.status ~= "active" or db.active_round_id ~= roundId then
        return false, "Only entries in an active raffle can be edited."
    end
    local receipt = db.receipts and db.receipts[receiptId]
    if not receipt or receipt.status ~= "confirmed" or receipt.round_id ~= roundId then
        return false, "This confirmed entry could not be found in the active raffle."
    end
    if type(values) ~= "table" then
        return false, "Entry details are unavailable."
    end
    editedAt = Core.SafeNumber(editedAt, 0)
    if editedAt == nil then
        return false, "The current game time is unavailable."
    end
    local validated, reason = validateLedgerEntry(round, values.character, values.paid_copper)
    if not validated then
        return false, reason
    end
    local characterGuid = values.character_guid
    if not Core.IsMissing(characterGuid)
        and (not Core.IsSafe(characterGuid)
            or type(characterGuid) ~= "string"
            or characterGuid == "") then
        return false, "The selected guild member could not be identified safely."
    end

    local identity = {
        key = validated.character_key,
        guid = characterGuid,
    }
    local currentTickets = Core.GetTicketsForIdentity(db, roundId, identity, receiptId)
    local cap = round.preset.cap_per_character
    if cap and currentTickets + validated.tickets > cap then
        return false, "This correction would exceed the ticket limit for that guild member."
    end

    receipt.character = validated.character
    receipt.character_key = validated.character_key
    receipt.character_guid = characterGuid
    receipt.paid_copper = validated.paid_copper
    receipt.ticket_price_copper = validated.ticket_price_copper
    receipt.tickets = validated.tickets
    receipt.manually_edited_at = editedAt
    return true, receipt
end

function Core.CreateStagedReceipt(db, values)
    local round = Core.GetRound(db, values.round_id)
    if not round or round.status ~= "active" then
        return nil, "The raffle is no longer active."
    end
    local character = Core.SafeString(values.character, false)
    local characterKey = Core.SafeString(values.character_key, false)
    local amount = Core.SafeNumber(values.paid_copper, 1)
    local tickets = Core.SafeNumber(values.tickets, 1)
    local wallet = Core.SafeNumber(values.pre_wallet, 0)
    local stagedAt = Core.SafeNumber(values.staged_at, 0)
    local evidence = values.evidence
    local signature = Core.IsSafe(evidence) and type(evidence) == "table"
        and Core.SafeString(evidence.signature, false) or nil
    local signatureCount = Core.IsSafe(evidence) and type(evidence) == "table"
        and Core.SafeNumber(evidence.signature_count, 1) or nil
    local loaded = Core.IsSafe(evidence) and type(evidence) == "table"
        and Core.SafeNumber(evidence.loaded, 0) or nil
    local total = Core.IsSafe(evidence) and type(evidence) == "table"
        and Core.SafeNumber(evidence.total, 0) or nil
    local observedAt = Core.IsSafe(evidence) and type(evidence) == "table"
        and Core.SafeFiniteNumber(evidence.observed_at, 0) or nil
    if not character or not characterKey or not amount or not tickets or wallet == nil or not stagedAt then
        return nil, "Could not verify the sender, payment, or current character money. No gold was collected."
    end
    if not signature or not signatureCount or loaded == nil or total == nil
        or observedAt == nil or total < loaded then
        return nil, "Inbox details could not be verified. No gold was collected."
    end
    if not Core.IsMissing(values.character_guid)
        and (not Core.IsSafe(values.character_guid)
            or type(values.character_guid) ~= "string"
            or values.character_guid == "") then
        return nil, "The sender could not be matched to one guild member. No gold was collected."
    end
    if amount % round.preset.price_copper ~= 0
        or amount / round.preset.price_copper ~= tickets then
        return nil, "Payment does not match the raffle's ticket price."
    end
    local id = db.next_receipt_id
    db.next_receipt_id = id + 1
    local receipt = {
        id = id,
        round_id = values.round_id,
        status = "pending",
        character = character,
        character_key = characterKey,
        character_guid = values.character_guid,
        paid_copper = amount,
        ticket_price_copper = round.preset.price_copper,
        tickets = tickets,
        pre_wallet = wallet,
        evidence = {
            signature = signature,
            signature_count = signatureCount,
            loaded = loaded,
            total = total,
            observed_at = observedAt,
        },
        staged_at = stagedAt,
    }
    db.receipts[id] = receipt
    return receipt
end

function Core.ConfirmReceipt(db, receiptId, registeredAt, source)
    local receipt = db.receipts[receiptId]
    if not receipt or receipt.status ~= "pending" then
        return false, "This pickup is already resolved and was not added again."
    end
    local round = Core.GetRound(db, receipt.round_id)
    if not round or round.status ~= "active" then
        return false, "Closed raffles are archives; their entries cannot be changed."
    end
    if not Core.SafeNumber(registeredAt, 0) then
        return false, "The current game time is unavailable."
    end
    if source ~= "mailbox" and source ~= "manual" then
        return false, "This payment could not be registered."
    end
    receipt.status = "confirmed"
    receipt.registered_at = registeredAt
    receipt.registration_source = source
    receipt.review_reason = nil
    return true, receipt
end

function Core.MarkNeedsReview(db, receiptId, reason, evidence)
    local receipt = db.receipts[receiptId]
    if not receipt or receipt.status ~= "pending" then
        return false
    end
    local round = Core.GetRound(db, receipt.round_id)
    if not round or round.status ~= "active" then
        return false
    end
    receipt.status = "needs_review"
    receipt.review_reason = Core.SafeString(reason, false) or "Pickup outcome could not be confirmed."
    if Core.IsSafe(evidence) and type(evidence) == "table" then
        local reviewEvidence = {}
        reviewEvidence.wallet_after = Core.SafeNumber(evidence.wallet_after, 0)
        reviewEvidence.wallet_delta = Core.SafeFiniteNumber(evidence.wallet_delta, -math.huge)
        reviewEvidence.inbox_loaded = Core.SafeNumber(evidence.inbox_loaded, 0)
        reviewEvidence.inbox_total = Core.SafeNumber(evidence.inbox_total, 0)
        reviewEvidence.inbox_complete = Core.SafeBoolean(evidence.inbox_complete)
        reviewEvidence.matching_funded_count =
            Core.SafeNumber(evidence.matching_funded_count, 0)
        reviewEvidence.mail_command_pending = Core.SafeBoolean(evidence.mail_command_pending)
        receipt.review_evidence = reviewEvidence
    end
    return true
end

function Core.DismissReceipt(db, receiptId, note)
    local receipt = db.receipts[receiptId]
    if not receipt or receipt.status ~= "needs_review" then
        return false, "This pickup is no longer waiting for review."
    end
    local round = Core.GetRound(db, receipt.round_id)
    if round and round.status == "closed" then
        return false, "Closed raffles are archives; their entries cannot be changed."
    end
    receipt.status = "dismissed"
    receipt.review_outcome = "dismissed_without_credit"
    receipt.reviewed_at = Core.SafeNumber(note and note.time, 0)
    receipt.review_note = Core.SafeString(note and note.text, true)
    return true
end

function Core.ManuallyConfirmReceipt(db, receiptId, registeredAt, reconciled)
    local receipt = db.receipts[receiptId]
    if not receipt or receipt.status ~= "needs_review" then
        return false, "This pickup is no longer waiting for review."
    end
    if reconciled ~= true then
        return false, "Check the character's money and inbox before registering this payment."
    end
    local round = Core.GetRound(db, receipt.round_id)
    if not round then
        return false, "The raffle this payment belongs to could not be found."
    end
    if round.status ~= "active" then
        return false, "Closed raffles are archives; their entries cannot be changed."
    end
    local tickets = Core.SafeNumber(receipt.tickets, 1)
    if not tickets or not Core.SafeNumber(receipt.paid_copper, 1)
        or receipt.paid_copper ~= tickets * round.preset.price_copper then
        return false, "This payment does not match the ticket price for its original raffle."
    end

    local identity = { key = receipt.character_key, guid = receipt.character_guid }
    local currentTickets = Core.GetTicketsForIdentity(db, round.id, identity)
    local cap = round.preset.cap_per_character
    if cap and currentTickets + tickets > cap then
        return false, "Registering this payment would exceed the ticket limit for this member."
    end
    if not Core.SafeNumber(registeredAt, 0) then
        return false, "The current game time is unavailable."
    end

    receipt.status = "confirmed"
    receipt.registered_at = registeredAt
    receipt.registration_source = "manual"
    receipt.review_outcome = "officer_confirmed"
    receipt.reviewed_at = registeredAt
    return true, receipt
end

function Core.GetReviewReceipts(db)
    local reviews = {}
    for _, receipt in pairs(db.receipts or {}) do
        if type(receipt) == "table" and receipt.status == "needs_review" then
            table.insert(reviews, receipt)
        end
    end
    table.sort(reviews, function(left, right)
        return left.id < right.id
    end)
    return reviews
end

function Core.GetSenderReviewCases(db, roundId)
    local reviews = {}
    for _, review in pairs(db.sender_reviews or {}) do
        if type(review) == "table"
            and review.status == "needs_review"
            and Core.SafeNumber(review.id, 1)
            and Core.SafeString(review.sender_key, false)
            and (roundId == nil or review.round_id == roundId) then
            table.insert(reviews, review)
        end
    end
    table.sort(reviews, function(left, right)
        return left.id < right.id
    end)
    return reviews
end

function Core.GetSenderReviewCase(db, reviewId)
    local review = db and db.sender_reviews and db.sender_reviews[reviewId]
    if type(review) == "table" then
        return review
    end
    return nil
end

local function csvField(value)
    if not Core.IsSafe(value) then
        return ""
    end
    local text = tostring(value)
    if string.find(text, '[,"\r\n]') then
        text = '"' .. string.gsub(text, '"', '""') .. '"'
    end
    return text
end

function Core.FormatUTC(timestamp)
    timestamp = Core.SafeNumber(timestamp, 0)
    if not timestamp then
        return ""
    end
    local formatter = date
    if type(formatter) ~= "function" and type(os) == "table" then
        formatter = os.date
    end
    if type(formatter) ~= "function" then
        return ""
    end
    local ok, result = pcall(formatter, "!%Y-%m-%dT%H:%M:%SZ", timestamp)
    if not ok or not Core.IsSafe(result) or type(result) ~= "string" then
        return ""
    end
    return result
end

function Core.ExportCSV(db, roundId)
    local rows = {
        "raffle_id,receipt_id,entry_number,character,paid_copper,ticket_price_copper,tickets,first_ticket,last_ticket,registered_at_utc,registration_source,manual_entry,manually_edited_at_utc",
    }
    local firstTicket = 1
    for entryNumber, receipt in ipairs(Core.GetRoundEntries(db, roundId)) do
        local lastTicket = firstTicket + receipt.tickets - 1
        local values = {
            receipt.round_id,
            receipt.id,
            entryNumber,
            receipt.character,
            receipt.paid_copper,
            receipt.ticket_price_copper,
            receipt.tickets,
            firstTicket,
            lastTicket,
            Core.FormatUTC(receipt.registered_at),
            receipt.registration_source,
            receipt.manual_entry == true,
            Core.FormatUTC(receipt.manually_edited_at),
        }
        for index, value in ipairs(values) do
            values[index] = csvField(value)
        end
        table.insert(rows, table.concat(values, ","))
        firstTicket = lastTicket + 1
    end
    return table.concat(rows, "\n")
end

function Core.ReceiptTickets(db, receiptId)
    local receipt = db.receipts[receiptId]
    return receipt and receipt.tickets or 0
end
