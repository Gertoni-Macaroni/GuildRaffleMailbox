local root = "."
local addonName = "GuildRaffleMailbox"
local ns = {}

local accentPairs = {
    { "À", "à" }, { "Á", "á" }, { "Â", "â" }, { "Ã", "ã" }, { "Ä", "ä" },
    { "Å", "å" }, { "Æ", "æ" }, { "Ç", "ç" }, { "È", "è" }, { "É", "é" },
    { "Ê", "ê" }, { "Ë", "ë" }, { "Ì", "ì" }, { "Í", "í" }, { "Î", "î" },
    { "Ï", "ï" }, { "Ð", "ð" }, { "Ñ", "ñ" }, { "Ò", "ò" }, { "Ó", "ó" },
    { "Ô", "ô" }, { "Õ", "õ" }, { "Ö", "ö" }, { "Ø", "ø" }, { "Ù", "ù" },
    { "Ú", "ú" }, { "Û", "û" }, { "Ü", "ü" }, { "Ý", "ý" }, { "Þ", "þ" },
}
CaseAccentInsensitiveParse = function(value)
    for _, pair in ipairs(accentPairs) do
        value = string.gsub(value, pair[1], pair[2])
    end
    return string.lower(value)
end

assert(loadfile(root .. "/Core.lua"))(addonName, ns)
assert(loadfile(root .. "/Backup.lua"))(addonName, ns)
assert(loadfile(root .. "/Mailbox.lua"))(addonName, ns)
assert(loadfile(root .. "/SelfTest.lua"))(addonName, ns)

local Core = ns.Core
local Controller = ns.Controller
local testsRun = 0

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function truthy(value, message)
    if not value then
        error(message or "expected truthy value", 2)
    end
end

local function contains(text, fragment, message)
    if not string.find(text or "", fragment, 1, true) then
        error(message or ("expected text to contain " .. fragment), 2)
    end
end

local function test(name, callback)
    callback()
    testsRun = testsRun + 1
    io.write("ok - " .. name .. "\n")
end

test("full-name normalization folds case for accented Latin names", function()
    equal(Core.NormalizeFullName("  ÉMILE ØRAN  "), "émile øran")
    truthy(Core.NormalizeFullName("Émile") ~= Core.NormalizeFullName("Emile"),
        "name normalization should preserve accents rather than erase them")
    local fold = CaseAccentInsensitiveParse
    CaseAccentInsensitiveParse = nil
    equal(Core.NormalizeFullName("Rina Ashleaf"), nil)
    CaseAccentInsensitiveParse = fold
end)

local function mail(sender, money, extra)
    local value = {
        sender = sender,
        subject = "entry",
        money = money,
        cod = 0,
        attachment_count = nil,
        returned = false,
        can_reply = true,
        is_gm = false,
    }
    for key, field in pairs(extra or {}) do
        value[key] = field
    end
    return value
end

local function makeWorld(mails, roster, options)
    local world = {
        mails = mails or {},
        roster = roster or {
            { name = "Rina Ashleaf", guid = "Player-1", online = false },
        },
        options = options or {},
        wallet = 10000,
        pending = false,
        open_all_running = false,
        time = 1,
        server_time = 1795559400,
        timers = {},
        take_calls = 0,
        check_calls = 0,
        roster_requests = 0,
        guild_id = 701,
        in_guild = true,
        total_override = nil,
        loaded_override = nil,
    }

    local function loadedCount()
        local loaded = world.loaded_override or #world.mails
        return math.min(loaded, #world.mails)
    end

    local api = {
        compatible = true,
        now = function()
            return world.time
        end,
        serverTime = function()
            return world.server_time
        end,
        isInGuild = function()
            return world.in_guild
        end,
        getGuildClubId = function()
            return world.guild_id
        end,
        getGuildName = function()
            return "Test Guild"
        end,
        requestRoster = function()
            world.roster_requests = world.roster_requests + 1
        end,
        getGuildMemberCount = function()
            return #world.roster
        end,
        getGuildMemberInfo = function(index)
            local member = world.roster[index]
            return member and member.name, member and member.guid
        end,
        getInboxCounts = function()
            return loadedCount(), world.total_override or #world.mails
        end,
        getInboxHeader = function(index)
            if index <= loadedCount() then
                return world.mails[index]
            end
            return nil
        end,
        getWallet = function()
            return world.wallet
        end,
        commandPending = function()
            return world.pending
        end,
        isOpenAllRunning = function()
            return world.open_all_running
        end,
        canCheckInbox = function()
            return true, 0
        end,
        checkInbox = function()
            world.check_calls = world.check_calls + 1
        end,
        after = function(seconds, callback)
            table.insert(world.timers, {
                due = world.time + seconds,
                callback = callback,
            })
        end,
    }

    local controller = Controller.new(Core.InitializeDB(nil), api)
    world.controller = controller
    controller.db.collector_enabled = true
    controller:RefreshRoster()
    local started, round = controller:StartRound("Test raffle", "10s")
    truthy(started, round)
    controller:OnEvent("MAIL_SHOW")
    controller:OnEvent("MAIL_INBOX_UPDATE")

    api.takeMoney = function(index)
        world.take_calls = world.take_calls + 1
        local behavior = world.options.take_behavior or "success"
        if behavior == "failure" then
            return false
        end
        if behavior == "mailfailed" then
            world.pending = true
            controller:OnEvent("MAIL_FAILED", nil)
            world.pending = false
            return nil
        end
        local target = world.mails[index]
        if not target or not target.money or target.money <= 0 then
            return false
        end

        local amount = target.money
        world.pending = true
        if world.options.remove_mail then
            table.remove(world.mails, index)
        else
            target.money = 0
        end
        if world.options.mask_with_identical then
            table.insert(world.mails, mail(target.sender, amount, {
                subject = target.subject,
                cod = target.cod,
                attachment_count = target.attachment_count,
                returned = target.returned,
                can_reply = target.can_reply,
                is_gm = target.is_gm,
            }))
        end
        if behavior ~= "timeout" then
            world.wallet = world.wallet + amount
        end

        if behavior == "timeout" then
            world.pending = false
            return nil
        elseif behavior == "close" then
            world.pending = false
            controller:OnEvent("MAIL_CLOSED")
            return nil
        elseif behavior == "partial" then
            world.pending = false
            world.mails[index] = {
                sender = nil,
                subject = nil,
                money = nil,
                cod = nil,
                returned = nil,
                can_reply = nil,
                is_gm = nil,
            }
            controller:OnEvent("MAIL_INBOX_UPDATE")
            return nil
        end

        if world.options.stop_during_take then
            controller:StopCollection()
        end
        if world.options.event_order == "success-money-inbox" then
            controller:OnEvent("MAIL_SUCCESS", nil)
            world.pending = false
            controller:OnEvent("PLAYER_MONEY")
            controller:OnEvent("MAIL_INBOX_UPDATE")
        else
            controller:OnEvent("MAIL_INBOX_UPDATE")
            world.pending = false
            controller:OnEvent("MAIL_SUCCESS", nil)
            controller:OnEvent("PLAYER_MONEY")
        end
        return nil
    end
    return world
end

local function advance(world, duration)
    local target = world.time + duration
    while true do
        local nextIndex, nextDue
        for index, timer in ipairs(world.timers) do
            if timer.due <= target and (not nextDue or timer.due < nextDue) then
                nextIndex = index
                nextDue = timer.due
            end
        end
        if not nextIndex then
            break
        end
        local timer = table.remove(world.timers, nextIndex)
        world.time = timer.due
        timer.callback()
    end
    world.time = target
end

local function collectToEnd(world)
    local controller = world.controller
    truthy(controller:StartCollection())
    local iterations = 0
    while controller.collection and controller.collection.running and iterations < 50 do
        advance(world, 1)
        iterations = iterations + 1
    end
    truthy(iterations < 50, "collection batch did not stop")
end

local function countConfirmed(db, roundId)
    return #Core.GetRoundEntries(db, roundId)
end

test("initial presets, integer price rules, and unique rounds", function()
    local db = Core.InitializeDB(nil)
    equal(db.presets["10s"].price_copper, 1000)
    equal(db.presets["1g"].cap_per_character, 1)
    local ok, round = Core.StartRound(db, "Week A", "10s", 99, "Guild", 100)
    truthy(ok)
    equal(round.id, 1)
    equal(round.preset.price_copper, 1000)
    local bad, reason = Core.SavePreset(db, "10s", "Bad", 0, nil)
    equal(bad, false)
    contains(reason, "positive")
end)

test("manual raffle entries accept typed names, enforce ticket rules, and stay ledger-only", function()
    local db = Core.InitializeDB(nil)
    local started, round = Core.StartRound(db, "Manual entries", "1g", 701, "Guild", 100)
    truthy(started)

    local receipt, reason = Core.CreateManualEntry(db, round.id, "  Typo Name  ", 10000, 200)
    truthy(receipt, reason)
    equal(receipt.character, "Typo Name")
    equal(receipt.character_key, "typo name")
    equal(receipt.character_guid, nil)
    equal(receipt.registration_source, "manual")
    equal(receipt.manual_entry, true)
    equal(receipt.tickets, 1)
    equal(receipt.registered_at, 200)
    equal(Core.GetRoundTotals(db, round.id), 1)

    local invalid, invalidReason = Core.CreateManualEntry(db, round.id, "Another Name", 15000, 201)
    equal(invalid, nil)
    contains(invalidReason, "exact multiple")
    local overCap, capReason = Core.CreateManualEntry(db, round.id, "typo name", 10000, 202)
    equal(overCap, nil)
    contains(capReason, "ticket limit")

    local edited, updated = Core.UpdateConfirmedEntry(db, round.id, receipt.id, {
        character = "Correct Guild Member",
        character_guid = "Player-1",
        paid_copper = 10000,
    }, 300)
    truthy(edited, updated)
    equal(updated.character, "Correct Guild Member")
    equal(updated.character_guid, "Player-1")
    equal(updated.manually_edited_at, 300)
    equal(updated.registered_at, 200)
    contains(Core.ExportCSV(db, round.id), ",manual,true,")
    local backup = assert(ns.Backup.Encode(db))
    local restored = assert(ns.Backup.Decode(backup, Core))
    equal(restored.receipts[receipt.id].manual_entry, true)
    equal(restored.receipts[receipt.id].manually_edited_at, 300)

    local tooMany, editReason = Core.UpdateConfirmedEntry(db, round.id, receipt.id, {
        character = "Correct Guild Member",
        character_guid = "Player-1",
        paid_copper = 20000,
    }, 301)
    equal(tooMany, false)
    contains(editReason, "ticket limit")
    equal(receipt.paid_copper, 10000)

    truthy(Core.CloseRound(db, round.id, 400))
    local closedEdit, closedEditReason = Core.UpdateConfirmedEntry(db, round.id, receipt.id, {
        character = "Correct Guild Member",
        character_guid = "Player-1",
        paid_copper = 10000,
    }, 401)
    equal(closedEdit, false)
    contains(closedEditReason, "active raffle")
    local closedAdd, closedAddReason = Core.CreateManualEntry(db, round.id, "Later Name", 10000, 401)
    equal(closedAdd, nil)
    contains(closedAddReason, "active raffle")
end)

test("manual entry controller skips guild lookup but existing-entry edits require a roster match", function()
    local world = makeWorld({})
    local controller = world.controller
    local roundId = controller.db.active_round_id
    local rosterRequests = world.roster_requests
    local wallet = world.wallet

    local added, receipt = controller:AddManualEntry(roundId, "  Typo Name  ", 1000)
    truthy(added, receipt)
    equal(receipt.character, "Typo Name")
    equal(receipt.character_guid, nil)
    equal(world.roster_requests, rosterRequests)
    equal(world.take_calls, 0)
    equal(world.wallet, wallet)

    local rejected, reason = controller:EditConfirmedEntry(
        roundId,
        receipt.id,
        "Not In Guild",
        1000
    )
    equal(rejected, false)
    contains(reason, "not in the current guild roster")
    equal(receipt.character, "Typo Name")

    local edited, result = controller:EditConfirmedEntry(
        roundId,
        receipt.id,
        "Rina Ashleaf",
        2000
    )
    truthy(edited, result)
    equal(receipt.character, "Rina Ashleaf")
    equal(receipt.character_guid, "Player-1")
    equal(receipt.tickets, 2)
    equal(receipt.manually_edited_at, world.server_time)
    equal(world.take_calls, 0)
    equal(world.wallet, wallet)
end)

test("opening, closing, and reopening scans without touching money or ledger", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    local db = world.controller.db
    local beforeWallet = world.wallet
    local roundId = db.active_round_id
    world.controller:OnEvent("MAIL_CLOSED")
    world.controller:OnEvent("MAIL_SHOW")
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(world.take_calls, 0)
    equal(world.wallet, beforeWallet)
    equal(countConfirmed(db, roundId), 0)
    equal(world.controller.snapshot.loaded, 1)
end)

test("mail history archives all messages only while collection is enabled and deduplicates scans", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Mira Sunleaf", 0),
    })
    local history = world.controller.db.mail_history
    equal(#history, 2)
    equal(history[1].sender, "Rina Ashleaf")
    equal(history[2].sender, "Mira Sunleaf")
    equal(history[1].money, 1000)
    equal(history[1].recorded_at, world.server_time)

    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(#history, 2)

    world.controller:SetCollectorEnabled(false)
    table.insert(world.mails, mail("Tavi Moonbrook", 250))
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(#history, 2)

    world.controller:SetCollectorEnabled(true)
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(#history, 3)
    equal(history[3].sender, "Tavi Moonbrook")
end)

test("collection action archives the current inbox before pickup changes it", function()
    local world = makeWorld({ mail("Rina Ashleaf", 0) })
    world.controller:SetCollectorEnabled(false)
    table.insert(world.mails, mail("Mira Sunleaf", 500))
    world.controller:SetCollectorEnabled(true)
    local started = world.controller:StartCollection()
    truthy(started)
    equal(#world.controller.db.mail_history, 2)
    equal(world.controller.db.mail_history[2].sender, "Mira Sunleaf")
    equal(world.controller.db.mail_history[2].money, 500)
end)

test("controller refuses collection while native Open All is running", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    world.open_all_running = true
    local started, reason = world.controller:StartCollection()
    equal(started, false)
    contains(reason, "Stop Open All")
    equal(world.take_calls, 0)
    equal(world.controller.collection, nil)
end)

test("identical funded mails count separately and event repeats do not duplicate", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Rina Ashleaf", 1000),
    }, nil, { remove_mail = true, event_order = "success-money-inbox" })
    local controller = world.controller
    local roundId = controller.db.active_round_id
    collectToEnd(world)
    equal(world.take_calls, 2)
    equal(countConfirmed(controller.db, roundId), 2)
    equal(Core.GetRoundTotals(controller.db, roundId), 2)
    controller:OnEvent("MAIL_SUCCESS", nil)
    controller:OnEvent("PLAYER_MONEY")
    controller:OnEvent("MAIL_INBOX_UPDATE")
    advance(world, 30)
    equal(world.take_calls, 2)
    equal(countConfirmed(controller.db, roundId), 2)
end)

test("30s buys three tickets while a 25s payment stays attached", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 3000),
        mail("Rina Ashleaf", 2500),
    })
    local roundId = world.controller.db.active_round_id
    collectToEnd(world)
    equal(countConfirmed(world.controller.db, roundId), 1)
    equal(Core.GetRoundEntries(world.controller.db, roundId)[1].tickets, 3)
    equal(world.mails[2].money, 2500)
    equal(world.take_calls, 1)
end)

test("one-ticket cap leaves a second 1g and a 2g payment in the inbox", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 10000),
        mail("Rina Ashleaf", 10000),
        mail("Rina Ashleaf", 20000),
    })
    local db = world.controller.db
    local saved, presetId = Core.SavePreset(db, nil, "Capped", 10000, 1)
    truthy(saved)
    local initialRound = db.active_round_id
    truthy(Core.CloseRound(db, initialRound, 2))
    local started, round = world.controller:StartRound("Capped raffle", presetId)
    truthy(started)
    round.id = db.active_round_id
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    collectToEnd(world)
    equal(countConfirmed(db, round.id), 1)
    equal(db.receipts[1].tickets, 1)
    equal(world.mails[2].money, 10000)
    equal(world.mails[3].money, 20000)
    equal(world.take_calls, 1)
end)

test("offline full-name member qualifies; similar and ambiguous names do not", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Rina", 1000),
        mail("Oren Flintvale", 1000),
    }, {
        { name = "Rina Ashleaf", guid = "Player-1", online = false },
        { name = "Oren Flintvale", guid = "Player-2" },
        { name = "Oren Flintvale", guid = "Player-3" },
    })
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    local payments = world.controller:GetPaymentRows()
    truthy(payments[1].eligible, "offline roster member should qualify")
    contains(payments[2].reason, "not listed")
    contains(payments[3].reason, "More than one")
    collectToEnd(world)
    equal(world.take_calls, 1)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 1)
end)

test("unmatched exotic sender can be mapped without collecting or crediting immediately", function()
    local world = makeWorld({
        mail("ŁUKASZ", 1000),
    }, {
        { name = "łukasz", guid = "Player-Lukasz", online = false },
    })
    local controller = world.controller
    local row = controller:GetPaymentRows()[1]
    equal(row.eligible, false)
    contains(row.reason, "Review")

    local reviews = Core.GetSenderReviewCases(controller.db)
    equal(#reviews, 1)
    equal(reviews[1].sender, "ŁUKASZ")
    equal(reviews[1].current_count, 1)
    equal(reviews[1].current_copper, 1000)
    local backupText = assert(ns.Backup.Encode(controller.db))
    local restored, _, metadata = ns.Backup.Decode(backupText, Core)
    truthy(restored)
    equal(#Core.GetSenderReviewCases(restored), 1)
    equal(metadata.unresolved_sender_names, 1)
    equal(controller:CloseRound(controller.db.active_round_id), false)

    local matched, member = controller:ResolveSenderReview(reviews[1].id, "łukasz")
    truthy(matched)
    equal(member.guid, "Player-Lukasz")
    equal(controller:GetPaymentRows()[1].eligible, true)
    equal(world.take_calls, 0)
    equal(countConfirmed(controller.db, controller.db.active_round_id), 0)
    local mappedBackup = assert(ns.Backup.Encode(controller.db))
    local restoredMapping = assert(ns.Backup.Decode(mappedBackup, Core))
    equal(restoredMapping.sender_aliases[reviews[1].sender_key].member_guid, "Player-Lukasz")

    collectToEnd(world)
    equal(world.take_calls, 1)
    equal(countConfirmed(controller.db, controller.db.active_round_id), 1)
    equal(controller.db.receipts[1].character_guid, "Player-Lukasz")
end)

test("sender review can be closed without credit and reopens for a later payment", function()
    local world = makeWorld({
        mail("ŁUKASZ", 1000),
    }, {
        { name = "łukasz", guid = "Player-Lukasz", online = false },
    })
    local controller = world.controller
    local review = Core.GetSenderReviewCases(controller.db)[1]

    truthy(controller:DismissSenderReview(review.id))
    equal(#Core.GetSenderReviewCases(controller.db), 0)
    equal(controller:GetPaymentRows()[1].eligible, false)
    contains(controller:GetPaymentRows()[1].reason, "closed without action")
    equal(world.take_calls, 0)
    equal(countConfirmed(controller.db, controller.db.active_round_id), 0)

    controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(#Core.GetSenderReviewCases(controller.db), 0, "rescanning the same message should not reopen a closed review")
    table.insert(world.mails, mail("ŁUKASZ", 1000))
    controller:OnEvent("MAIL_INBOX_UPDATE")
    local reopened = Core.GetSenderReviewCases(controller.db)
    equal(#reopened, 1)
    equal(reopened[1].current_count, 2)
    equal(controller:CloseRound(controller.db.active_round_id), false)

    truthy(controller:DismissSenderReview(reopened[1].id))
    truthy(controller:CloseRound(controller.db.active_round_id))
    equal(world.take_calls, 0)
    equal(countConfirmed(controller.db, controller.db.active_round_id), 0)
end)

test("a member joining during an active raffle qualifies after the guild roster updates", function()
    local world = makeWorld({ mail("New Member", 1000) })
    local row = world.controller:GetPaymentRows()[1]
    equal(row.eligible, false)
    table.insert(world.roster, { name = "New Member", guid = "Player-new", online = false })
    world.controller:OnEvent("GUILD_ROSTER_UPDATE")
    row = world.controller:GetPaymentRows()[1]
    equal(row.eligible, true)
    equal(row.member_guid, "Player-new")
    collectToEnd(world)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 1)
end)

test("full-name fallback tickets carry across when the roster later supplies a GUID", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Rina Ashleaf", 1000),
    }, {
        { name = "Rina Ashleaf", guid = nil },
    }, { remove_mail = true })
    local controller = world.controller
    local db = controller.db
    truthy(controller:CloseRound(db.active_round_id))
    local saved, presetId = Core.SavePreset(db, nil, "One ticket", 1000, 1)
    truthy(saved)
    truthy(controller:StartRound("Fallback identity", presetId))
    controller:OnEvent("MAIL_INBOX_UPDATE")
    truthy(controller:StartCollection())
    equal(world.take_calls, 1)

    world.roster[1].guid = "Player-1"
    truthy(controller:RefreshRoster())
    advance(world, 1)
    equal(world.take_calls, 1)
    equal(countConfirmed(db, db.active_round_id), 1)
    contains(controller:GetPaymentRows()[1].reason, "ticket limit")
end)

test("backlog is shown and the addon refreshes after a pickup", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Unrelated Sender", 0),
    })
    world.loaded_override = 1
    world.total_override = 2
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(world.controller.snapshot.loaded, 1)
    equal(world.controller.snapshot.total, 2)
    collectToEnd(world)
    advance(world, 1)
    truthy(world.check_calls >= 1, "expected explicit refresh after a pickup")
end)

test("unverified ordinary-mail fields and item/COD attachments stay untouched", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000, { cod = 100 }),
        mail("Rina Ashleaf", 1000, { attachment_count = 1 }),
        mail("Rina Ashleaf", 1000, { is_gm = true }),
        mail("Rina Ashleaf", 1000, { returned = true }),
        mail("Rina Ashleaf", 1000, { can_reply = false }),
    })
    collectToEnd(world)
    equal(world.take_calls, 0)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 0)
    for _, row in ipairs(world.controller:GetPaymentRows()) do
        truthy(row.reason)
    end
end)

test("secret mailbox fields are unverified and never collected", function()
    local secret = {}
    local priorSecretCheck = issecretvalue
    issecretvalue = function(value)
        return value == secret
    end
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    world.mails[1].sender = secret
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    equal(world.controller.snapshot.complete, false)
    equal(world.controller:StartCollection(), false)
    equal(world.take_calls, 0)
    issecretvalue = priorSecretCheck
end)

test("failed pickup is staged for review and cannot be replayed after reopen", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "failure" })
    local controller = world.controller
    local roundId = controller.db.active_round_id
    local beforeWallet = world.wallet
    controller:StartCollection()
    equal(world.take_calls, 1)
    local receipt = controller.db.receipts[1]
    equal(receipt.status, "needs_review")
    equal(receipt.round_id, roundId)
    equal(receipt.character, "Rina Ashleaf")
    equal(receipt.paid_copper, 1000)
    equal(receipt.tickets, 1)
    equal(receipt.review_evidence.wallet_after, beforeWallet)
    equal(receipt.review_evidence.wallet_delta, 0)
    equal(receipt.review_evidence.inbox_loaded, 1)
    equal(receipt.review_evidence.matching_funded_count, 1)
    controller:OnEvent("MAIL_CLOSED")
    controller:OnEvent("MAIL_SHOW")
    controller:OnEvent("MAIL_INBOX_UPDATE")
    local started = controller:StartCollection()
    equal(started, false)
    equal(world.take_calls, 1)
    equal(countConfirmed(controller.db, roundId), 0)
end)

test("timeout and partial post-pickup data remain uncredited for review", function()
    local timeoutWorld = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "timeout" })
    timeoutWorld.controller:StartCollection()
    advance(timeoutWorld, 19)
    equal(timeoutWorld.controller.db.receipts[1].status, "needs_review")
    equal(countConfirmed(timeoutWorld.controller.db, timeoutWorld.controller.db.active_round_id), 0)

    local partialWorld = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "partial" })
    partialWorld.controller:StartCollection()
    equal(partialWorld.controller.db.receipts[1].status, "needs_review")
    equal(countConfirmed(partialWorld.controller.db, partialWorld.controller.db.active_round_id), 0)
end)

test("newly loaded identical mail masking the pickup forces review", function()
    local world = makeWorld(
        { mail("Rina Ashleaf", 1000), mail("Rina Ashleaf", 1000) },
        nil,
        { remove_mail = true, mask_with_identical = true }
    )
    world.controller:StartCollection()
    equal(world.take_calls, 1)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 0)
    advance(world, 19)
    equal(world.controller.db.receipts[1].status, "needs_review")
    equal(world.controller.db.receipts[1].review_evidence.matching_funded_count, 2)
    equal(world.mails[1].money, 1000)
end)

test("MAIL_FAILED event preserves the staged attempt for officer review", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "mailfailed" })
    world.controller:StartCollection()
    equal(world.controller.db.receipts[1].status, "needs_review")
    contains(world.controller.db.receipts[1].review_reason, "reported")
    equal(world.take_calls, 1)
    equal(world.mails[1].money, 1000)
end)

test("mailbox close during pickup holds the receipt and prevents replay", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "close" })
    world.controller:StartCollection()
    equal(world.controller.db.receipts[1].status, "needs_review")
    equal(world.take_calls, 1)
    world.controller:OnEvent("MAIL_SHOW")
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    world.controller:StartCollection()
    equal(world.take_calls, 1)
end)

test("Stop lets the current observable pickup settle and prevents the next one", function()
    local world = makeWorld({
        mail("Rina Ashleaf", 1000),
        mail("Rina Ashleaf", 1000),
    }, nil, { stop_during_take = true })
    world.controller:StartCollection()
    equal(world.take_calls, 1)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 1)
    equal(world.controller.collection.running, false)
    equal(world.mails[2].money, 1000)
end)

test("manual review requires reconciliation and uses the original receipt ID", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "failure" })
    world.controller:StartCollection()
    local denied = world.controller:ConfirmReviewManually(1, false)
    equal(denied, false)
    local confirmed, receipt = world.controller:ConfirmReviewManually(1, true)
    truthy(confirmed)
    equal(receipt.id, 1)
    equal(receipt.registration_source, "manual")
    equal(receipt.registered_at, world.server_time)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 1)
    local duplicate = world.controller:ConfirmReviewManually(1, true)
    equal(duplicate, false)
end)

test("reload restores pending operations as review and never replays them", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) }, nil, { take_behavior = "timeout" })
    world.controller:StartCollection()
    local db = Core.InitializeDB(world.controller.db)
    equal(db.receipts[1].status, "needs_review")
    equal(world.take_calls, 1)
    local newController = Controller.new(db, world.controller.api)
    newController.mailbox_open = true
    newController:OnEvent("MAIL_INBOX_UPDATE")
    local started = newController:StartCollection()
    equal(started, false)
    equal(world.take_calls, 1)
end)

test("closing and editing presets preserve round snapshots and CSV ranges", function()
    local world = makeWorld({ mail("Rina Ashleaf", 3000), mail("Oren Flintvale", 1000) }, {
        { name = "Rina Ashleaf", guid = "Player-1" },
        { name = "Oren Flintvale", guid = "Player-2" },
    }, { remove_mail = true })
    local controller = world.controller
    local db = controller.db
    local firstRoundId = db.active_round_id
    collectToEnd(world)
    local closed, reason = controller:CloseRound(firstRoundId)
    truthy(closed, reason)
    local oldPrice = db.rounds[firstRoundId].preset.price_copper
    local saved = Core.SavePreset(db, "10s", "10s changed", 2000, nil)
    truthy(saved)
    local secondStarted, second = controller:StartRound("Week B", "10s")
    truthy(secondStarted)
    equal(db.rounds[firstRoundId].preset.price_copper, oldPrice)
    equal(second.preset.price_copper, 2000)
    equal(countConfirmed(db, firstRoundId), 2)

    local csv = Core.ExportCSV(db, firstRoundId)
    contains(csv, "raffle_id,receipt_id,entry_number,character,paid_copper")
    contains(csv, "1,1,1,Rina Ashleaf,3000,1000,3,1,3,")
    contains(csv, "1,2,2,Oren Flintvale,1000,1000,1,4,4,")
    contains(csv, "2026-11-")
    equal(Core.ExportCSV(db, second.id),
        "raffle_id,receipt_id,entry_number,character,paid_copper,ticket_price_copper,tickets,first_ticket,last_ticket,registered_at_utc,registration_source,manual_entry,manually_edited_at_utc")
end)

test("CSV escapes names, keeps monotonic IDs after reset, and reset is round-local", function()
    local db = Core.InitializeDB(nil)
    local _, first = Core.StartRound(db, "A", "10s", 99, "Guild", 100)
    local receipt = Core.CreateStagedReceipt(db, {
        round_id = first.id,
        character = 'Rina, "Ashleaf"',
        character_key = 'rina, "ashleaf"',
        character_guid = "Player-1",
        paid_copper = 1000,
        tickets = 1,
        pre_wallet = 100,
        staged_at = 100,
        evidence = { signature = "test", signature_count = 1, loaded = 1, total = 1, observed_at = 100 },
    })
    Core.ConfirmReceipt(db, receipt.id, 1795559400, "mailbox")
    Core.CloseRound(db, first.id, 101)
    local _, second = Core.StartRound(db, "B", "10s", 99, "Guild", 102)
    local nextReceipt = Core.CreateStagedReceipt(db, {
        round_id = second.id,
        character = "Oren Flintvale",
        character_key = "oren flintvale",
        character_guid = "Player-2",
        paid_copper = 1000,
        tickets = 1,
        pre_wallet = 100,
        staged_at = 100,
        evidence = { signature = "test", signature_count = 1, loaded = 1, total = 1, observed_at = 100 },
    })
    Core.ConfirmReceipt(db, nextReceipt.id, 1795559401, "mailbox")
    local csv = Core.ExportCSV(db, first.id)
    contains(csv, '"Rina, ""Ashleaf"""')
    local closedReset, closedReason = Core.ResetRoundEntries(db, first.id)
    equal(closedReset, false)
    contains(closedReason, "archives")
    equal(countConfirmed(db, first.id), 1)
    local reset, payments, tickets = Core.ResetRoundEntries(db, second.id)
    truthy(reset)
    equal(payments, 1)
    equal(tickets, 1)
    equal(countConfirmed(db, first.id), 1)
    equal(countConfirmed(db, second.id), 0)
    local afterReset = Core.CreateStagedReceipt(db, {
        round_id = second.id,
        character = "Rina Ashleaf",
        character_key = "rina ashleaf",
        character_guid = "Player-3",
        paid_copper = 1000,
        tickets = 1,
        pre_wallet = 100,
        staged_at = 100,
        evidence = { signature = "test", signature_count = 1, loaded = 1, total = 1, observed_at = 100 },
    })
    equal(afterReset.id, 3)
end)

test("raffle entry numbers restart per round without resetting receipt IDs", function()
    local db = Core.InitializeDB(nil)
    local _, first = Core.StartRound(db, "First raffle", "10s", 99, "Guild", 100)
    for index = 1, 2 do
        local receipt = Core.CreateStagedReceipt(db, {
            round_id = first.id,
            character = "Member " .. tostring(index),
            character_key = "member " .. tostring(index),
            character_guid = "Player-" .. tostring(index),
            paid_copper = 1000,
            tickets = 1,
            pre_wallet = 100,
            staged_at = 100 + index,
            evidence = { signature = "mail-" .. tostring(index), signature_count = 1, loaded = 1, total = 1, observed_at = 100 },
        })
        truthy(Core.ConfirmReceipt(db, receipt.id, 200 + index, "mailbox"))
    end
    truthy(Core.CloseRound(db, first.id, 300))

    local _, second = Core.StartRound(db, "Second raffle", "10s", 99, "Guild", 301)
    local receipt = Core.CreateStagedReceipt(db, {
        round_id = second.id,
        character = "Member 3",
        character_key = "member 3",
        character_guid = "Player-3",
        paid_copper = 1000,
        tickets = 1,
        pre_wallet = 100,
        staged_at = 302,
        evidence = { signature = "mail-3", signature_count = 1, loaded = 1, total = 1, observed_at = 100 },
    })
    equal(receipt.id, 3)
    truthy(Core.ConfirmReceipt(db, receipt.id, 303, "mailbox"))

    local csv = Core.ExportCSV(db, second.id)
    contains(csv, "2,3,1,Member 3,1000,1000,1,1,1,")
    equal(db.next_receipt_id, 4)
end)

test("large CSV exports every receipt with contiguous ticket ranges and timestamps", function()
    local db = Core.InitializeDB(nil)
    local _, round = Core.StartRound(db, "Large raffle", "10s", 99, "Guild", 100)
    local expectedTickets = 0
    for index = 1, 125 do
        local tickets = index % 4 + 1
        local receipt = Core.CreateStagedReceipt(db, {
            round_id = round.id,
            character = "Member " .. tostring(index),
            character_key = "member " .. tostring(index),
            character_guid = "Player-" .. tostring(index),
            paid_copper = tickets * 1000,
            tickets = tickets,
            pre_wallet = 100,
            staged_at = 100,
            evidence = {
                signature = "large-" .. tostring(index),
                signature_count = 1,
                loaded = 1,
                total = 1,
                observed_at = 100.5,
            },
        })
        truthy(receipt)
        truthy(Core.ConfirmReceipt(db, receipt.id, 1795559400 + index, "mailbox"))
        expectedTickets = expectedTickets + tickets
    end
    local csv = Core.ExportCSV(db, round.id)
    local lines = {}
    for line in string.gmatch(csv, "[^\n]+") do
        table.insert(lines, line)
    end
    equal(#lines, 126)
    local last = lines[#lines]
    local _, lastTicket = string.match(last, ",(%d+),(%d+),[^,]+,mailbox,false,$")
    lastTicket = tonumber(lastTicket)
    equal(lastTicket, expectedTickets)
    contains(lines[2], "2026-11-")
end)

test("reset removes manual ledger entry but preserves its review outcome", function()
    local db = Core.InitializeDB(nil)
    local _, round = Core.StartRound(db, "Review raffle", "10s", 99, "Guild", 100)
    local receipt = Core.CreateStagedReceipt(db, {
        round_id = round.id,
        character = "Rina Ashleaf",
        character_key = "rina ashleaf",
        character_guid = "Player-1",
        paid_copper = 1000,
        tickets = 1,
        pre_wallet = 100,
        staged_at = 100,
        evidence = {
            signature = "review",
            signature_count = 1,
            loaded = 1,
            total = 1,
            observed_at = 100,
        },
    })
    Core.MarkNeedsReview(db, receipt.id, "Officer verified after timeout.")
    truthy(Core.ManuallyConfirmReceipt(db, receipt.id, 200, true))
    local reset = Core.ResetRoundEntries(db, round.id)
    truthy(reset)
    equal(Core.GetRoundTotals(db, round.id), 0)
    equal(db.receipts[receipt.id].status, "reset")
    equal(db.receipts[receipt.id].review_outcome, "officer_confirmed")
    equal(db.receipts[receipt.id].ledger_cleared, true)
end)

test("uncommanded removal of a previously observed funded mail is surfaced", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    world.mails = {}
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    contains(world.controller.discrepancy, "disappeared unexpectedly")
    equal(world.take_calls, 0)
end)

test("discrepancy blocks collection until a complete scan is acknowledged", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    world.mails = {}
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    truthy(world.controller.discrepancy)
    local started, reason = world.controller:StartCollection()
    equal(started, false)
    contains(reason, "warning")
    world.loaded_override = 0
    world.total_override = 1
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    local acknowledged, blockedReason = world.controller:AcknowledgeDiscrepancy()
    equal(acknowledged, false)
    contains(blockedReason, "complete inbox")
    world.loaded_override = nil
    world.total_override = nil
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    truthy(world.controller:AcknowledgeDiscrepancy())
    equal(world.controller.discrepancy, nil)
end)

test("comparable latest mailbox observation survives a normal reload", function()
    local world = makeWorld({ mail("Rina Ashleaf", 1000) })
    local db = world.controller.db
    truthy(db.last_observation)
    local reloaded = Controller.new(db, world.controller.api)
    world.mails = {}
    reloaded:OnEvent("MAIL_SHOW")
    reloaded:OnEvent("MAIL_INBOX_UPDATE")
    contains(reloaded.discrepancy, "disappeared unexpectedly")
end)

test("default API adapter checks Forever build and documented mail/roster positions", function()
    local globals = {
        "GetBuildInfo", "GetInboxNumItems", "GetInboxHeaderInfo", "TakeInboxMoney",
        "GetMoney", "GetServerTime", "C_Mail", "C_GuildInfo", "C_Club", "C_Timer",
        "GetNumGuildMembers", "GetGuildRosterInfo", "GetTime", "IsInGuild",
        "GetGuildInfo", "CheckInbox", "CaseAccentInsensitiveParse",
        "DEFAULT_CHAT_FRAME", "GuildRaffleMailboxDB",
    }
    local saved = {}
    for _, name in ipairs(globals) do
        saved[name] = _G[name]
    end
    GetBuildInfo = function()
        return "1.60.1", "71037", "test", 16001
    end
    GetInboxNumItems = function()
        return 1, 1
    end
    GetInboxHeaderInfo = function()
        return "package", "stationery", "Rina Ashleaf", "entry", 1000, 0, 30,
            nil, false, false, nil, true, false
    end
    TakeInboxMoney = function() end
    GetMoney = function()
        return 100
    end
    GetServerTime = function()
        return 1795559400
    end
    C_Mail = {
        IsCommandPending = function()
            return false
        end,
        CanCheckInbox = function()
            return true, 0
        end,
    }
    C_GuildInfo = { GuildRoster = function() end }
    C_Club = { GetGuildClubId = function() return 10 end }
    C_Timer = { After = function() end }
    GetNumGuildMembers = function()
        return 1
    end
    GetGuildRosterInfo = function()
        local values = { [1] = "Rina Ashleaf", [17] = "Player-1" }
        return unpack(values, 1, 17)
    end
    GetTime = function() return 1.5 end
    IsInGuild = function() return true end
    GetGuildInfo = function() return "Test Guild" end
    CheckInbox = function() end

    local api = Controller.CreateDefaultAPI()
    truthy(api.compatible)
    equal(api.now(), 1.5)
    equal(api.getInboxCounts(), 1)
    local header = api.getInboxHeader(1)
    equal(header.sender, "Rina Ashleaf")
    equal(header.money, 1000)
    equal(header.can_reply, true)
    equal(header.is_gm, false)
    local name, guid = api.getGuildMemberInfo(1)
    equal(name, "Rina Ashleaf")
    equal(guid, "Player-1")
    CaseAccentInsensitiveParse = nil
    local missingNameFoldApi = Controller.CreateDefaultAPI()
    equal(missingNameFoldApi.compatible, false)
    contains(missingNameFoldApi.compatibility_message, "name-matching API")

    CaseAccentInsensitiveParse = saved["CaseAccentInsensitiveParse"]
    truthy(type(SlashCmdList.GUILDRAFFLETEST) == "function")
    equal(SLASH_GUILDRAFFLETEST1, "/raffletest")
    local chatMessages = {}
    DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message)
            table.insert(chatMessages, message)
        end,
    }
    GuildRaffleMailboxDB = { self_test_sentinel = "unchanged" }
    local passed, failed, skipped = ns.SelfTest.Run()
    equal(passed, 8)
    equal(failed, 0)
    equal(skipped, 1)
    contains(table.concat(chatMessages, "\n"), "SKIP|r read-only inbox header probe")
    contains(table.concat(chatMessages, "\n"), "Self-test: 8/8 passed (1 skipped).")
    equal(GuildRaffleMailboxDB.self_test_sentinel, "unchanged")

    chatMessages = {}
    local actualNameFolder = CaseAccentInsensitiveParse
    CaseAccentInsensitiveParse = function(value) return value end
    local passesWithBrokenFolder, failuresWithBrokenFolder = ns.SelfTest.Run()
    equal(passesWithBrokenFolder, 7)
    equal(failuresWithBrokenFolder, 1)
    contains(table.concat(chatMessages, "\n"), "FAIL|r accented name normalization")
    contains(table.concat(chatMessages, "\n"), "Self-test: 7/8 passed (1 skipped).")
    CaseAccentInsensitiveParse = actualNameFolder
    for _, name in ipairs(globals) do
        _G[name] = saved[name]
    end
end)

test("default API adapter fails closed on an unverified build", function()
    local old = GetBuildInfo
    GetBuildInfo = function() return "1.60.1", "99999", "test", 16001 end
    local api = Controller.CreateDefaultAPI()
    equal(api.compatible, false)
    contains(api.compatibility_message, "not verified")
    GetBuildInfo = old
end)

test("panel initialization exposes the collector toggle and slash command", function()
    local priorCreateFrame = CreateFrame
    local priorSlashCmdList = SlashCmdList
    local priorOpenAllMail = OpenAllMail
    local priorStaticPopupShow = StaticPopup_Show
    local priorDropdownInitialize = UIDropDownMenu_Initialize
    local priorDropdownCreateInfo = UIDropDownMenu_CreateInfo
    local priorDropdownAddButton = UIDropDownMenu_AddButton
    local priorDropdownSetWidth = UIDropDownMenu_SetWidth
    local priorDropdownSetSelectedValue = UIDropDownMenu_SetSelectedValue
    local priorDropdownSetText = UIDropDownMenu_SetText
    local dropdownItems = {}
    local lastPopupName
    local lastPopupData
    StaticPopup_Show = function(name, _, _, data)
        lastPopupName = name
        lastPopupData = data
    end
    UIDropDownMenu_Initialize = function(frame, callback)
        frame.dropdown_initialize = callback
    end
    UIDropDownMenu_CreateInfo = function()
        return {}
    end
    UIDropDownMenu_AddButton = function(info)
        table.insert(dropdownItems, info)
    end
    UIDropDownMenu_SetWidth = function(frame, width)
        frame.dropdown_width = width
    end
    UIDropDownMenu_SetSelectedValue = function(frame, value)
        frame.dropdown_selected = value
    end
    UIDropDownMenu_SetText = function(frame, text)
        frame.dropdown_text = text
    end
    local nativeOpenAll = { enabled = true, running = false }
    function nativeOpenAll:Disable()
        self.enabled = false
    end
    function nativeOpenAll:Enable()
        self.enabled = true
    end
    function nativeOpenAll:StartOpening()
        self.running = true
    end
    function nativeOpenAll:StopOpening()
        self.running = false
        self:Enable()
    end
    function nativeOpenAll:OnClick()
        self:StartOpening()
    end
    OpenAllMail = nativeOpenAll
    local function fakeFrame()
        local frame = {
            scripts = {},
            text = "",
            checked = false,
            shown = false,
            enabled = true,
        }
        function frame:CreateFontString()
            return fakeFrame()
        end
        function frame:CreateTexture()
            return fakeFrame()
        end
        function frame:SetScript(name, callback)
            self.scripts[name] = callback
        end
        function frame:SetPoint(point, relativeTo, relativePoint, x, y)
            self.point = {
                point = point,
                relative_to = relativeTo,
                relative_point = relativePoint,
                x = x,
                y = y,
            }
        end
        function frame:ClearAllPoints()
            self.point = nil
        end
        function frame:SetText(value)
            self.text = value
        end
        function frame:SetSize(width, height)
            self.width = width
            self.height = height
        end
        function frame:GetWidth()
            return self.width
        end
        function frame:GetHeight()
            return self.height
        end
        function frame:GetText()
            return self.text
        end
        function frame:SetChecked(value)
            self.checked = value
        end
        function frame:GetChecked()
            return self.checked
        end
        function frame:SetEnabled(value)
            self.enabled = value
        end
        function frame:SetFrameStrata(value)
            self.strata = value
        end
        function frame:SetToplevel(value)
            self.toplevel = value
        end
        function frame:Show()
            self.shown = true
        end
        function frame:Hide()
            self.shown = false
        end
        function frame:IsShown()
            return self.shown
        end
        function frame:GetCursorPosition()
            return 0
        end
        return setmetatable(frame, {
            __index = function(_, key)
                if key == "TitleText" then
                    return nil
                end
                return function() end
            end,
        })
    end

    UIParent = fakeFrame()
    CreateFrame = function()
        return fakeFrame()
    end
    assert(loadfile(root .. "/UI.lua"))(addonName, ns)
    local uiMails = { mail("Rina Ashleaf", 1000) }
    for index = 1, 12 do
        table.insert(uiMails, mail("Member " .. tostring(index), 0))
    end
    local world = makeWorld(uiMails)
    ns.UI.Initialize(world.controller)
    truthy(ns.UI.instance)
    truthy(ns.UI.instance.collect_button.enabled)
    equal(#world.controller.db.mail_history, 13)
    equal(nativeOpenAll.enabled, false)
    table.insert(world.mails, mail("Mira Sunleaf", 0))
    nativeOpenAll:OnClick()
    equal(nativeOpenAll.running, false)
    equal(#world.controller.db.mail_history, 14)
    equal(ns.UI.instance.frame.strata, "DIALOG")
    equal(ns.UI.instance.frame.toplevel, true)
    truthy(ns.UI.instance.tabs.collect)
    truthy(ns.UI.instance.tabs.setup)
    truthy(ns.UI.instance.tabs.active)
    truthy(ns.UI.instance.tabs.history)
    truthy(ns.UI.instance.tabs.mail_history)
    truthy(ns.UI.instance.tabs.review)
    contains(ns.UI.instance.review_ack_text.text, "checked my character's money and inbox")
    equal(ns.UI.instance.preset_silver:GetText(), "10")
    ns.UI.instance.preset_dropdown.dropdown_initialize(ns.UI.instance.preset_dropdown, 1)
    equal(#dropdownItems, 2)
    for _, item in ipairs(dropdownItems) do
        if item.value == "1g" then
            item.func()
            break
        end
    end
    equal(world.controller.db.selected_preset_id, "1g")
    ns.UI.instance.preset_gold:SetText("1")
    ns.UI.instance.preset_silver:SetText("2")
    ns.UI.instance.preset_copper:SetText("3")
    ns.UI.instance.save_preset.scripts.OnClick()
    equal(world.controller.db.presets["1g"].price_copper, 10203)
    local activeId = world.controller.db.active_round_id
    ns.UI.instance.tabs.active.scripts.OnClick()
    truthy(ns.UI.instance.pages.active.shown)
    contains(ns.UI.instance.active_round_title.text, "Test raffle")
    truthy(ns.UI.instance.active_round_export.enabled)
    ns.UI.instance.active_round_close.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_CLOSE")
    collectToEnd(world)
    ns.UI.Refresh()
    equal(ns.UI.instance.active_round_payments.text, "1")
    ns.UI.instance.tabs.setup.scripts.OnClick()
    ns.UI.instance.close_button.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_CLOSE")
    truthy(world.controller:CloseRound(activeId))
    ns.UI.Refresh()
    equal(ns.UI.instance.active_round_title.text, "No active raffle")
    equal(ns.UI.instance.history_reset.enabled, false)
    ns.UI.instance.tabs.history.scripts.OnClick()
    truthy(ns.UI.instance.pages.history.shown)
    equal(ns.UI.instance.pages.collect.shown, false)
    equal(world.controller.db.active_round_id, nil)
    equal(ns.UI.instance.history_payments.text, "1")
    contains(ns.UI.instance.history_entries.saved_text, "Rina Ashleaf")
    ns.UI.instance.tabs.review.scripts.OnClick()
    truthy(ns.UI.instance.pages.review.shown)
    ns.UI.instance.tabs.mail_history.scripts.OnClick()
    truthy(ns.UI.instance.pages.mail_history.shown)
    equal(ns.UI.instance.mail_history_page_label.text, "15 mail message(s) · Page 1 of 2")
    equal(ns.UI.instance.mail_history_rows[1].sender.text, "Rina Ashleaf")
    ns.UI.instance.mail_history_next.scripts.OnClick()
    equal(ns.UI.instance.mail_history_page_label.text, "15 mail message(s) · Page 2 of 2")
    truthy(ns.UI.instance.mail_history_previous.enabled)
    ns.UI.instance.tabs.setup.scripts.OnClick()
    truthy(ns.UI.instance.pages.setup.shown)
    world.controller:SetCollectorEnabled(false)
    ns.UI.Refresh()
    equal(nativeOpenAll.enabled, true)
    nativeOpenAll:OnClick()
    equal(nativeOpenAll.running, true)
    world.controller.db.collector_enabled = true
    local takeCallsBeforeGuard = world.take_calls
    local started, reason = world.controller:StartCollection()
    equal(started, false)
    contains(reason, "Stop Open All")
    equal(world.take_calls, takeCallsBeforeGuard)
    world.controller:SetCollectorEnabled(true)
    ns.UI.Refresh()
    equal(nativeOpenAll.running, false)
    equal(nativeOpenAll.enabled, false)
    nativeOpenAll:OnClick()
    equal(nativeOpenAll.running, false)
    world.controller:SetCollectorEnabled(false)
    ns.UI.Refresh()
    world.controller.db.collector_enabled = false
    ns.UI.Refresh()
    equal(ns.UI.instance.collect_button.enabled, false)
    truthy(type(SlashCmdList.GUILDRAFFLE) == "function")
    equal(SLASH_GUILDRAFFLE2, "/raffle")
    SlashCmdList.GUILDRAFFLE()
    equal(ns.UI.instance.frame.shown, true)

    local reviewRoundStarted = world.controller:StartRound("Name review UI test", "10s")
    truthy(reviewRoundStarted)
    table.insert(world.mails, mail("ЖУКА", 1000))
    world.controller:OnEvent("MAIL_SHOW")
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    ns.UI.Refresh()
    ns.UI.instance.tabs.review.scripts.OnClick()
    truthy(ns.UI.instance.review_sender_member.shown)
    local takeCallsBeforeDismiss = world.take_calls
    ns.UI.instance.review_sender_member:SetText("Rina Ashleaf")
    ns.UI.instance.review_sender_match.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_MATCH_SENDER")
    local senderReview = Core.GetSenderReviewCases(world.controller.db)[1]
    truthy(senderReview)
    StaticPopupDialogs.GUILD_RAFFLE_MATCH_SENDER.OnAccept({}, {
        controller = world.controller,
        review_id = senderReview.id,
        member_name = "Rina Ashleaf",
    })
    ns.UI.Refresh()
    equal(world.controller:GetPaymentRows()[#world.controller:GetPaymentRows()].eligible, true)
    equal(world.take_calls, takeCallsBeforeDismiss)
    equal(countConfirmed(world.controller.db, world.controller.db.active_round_id), 0)

    table.insert(world.mails, mail("ЖУКИ", 1000))
    world.controller:OnEvent("MAIL_INBOX_UPDATE")
    ns.UI.Refresh()
    equal(ns.UI.instance.review_dismiss.text, "Close review")
    ns.UI.instance.review_dismiss.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_DISMISS_SENDER")
    local senderReviewToClose = Core.GetSenderReviewCases(world.controller.db)[1]
    truthy(senderReviewToClose)
    StaticPopupDialogs.GUILD_RAFFLE_DISMISS_SENDER.OnAccept({}, {
        controller = world.controller,
        review_id = senderReviewToClose.id,
    })
    ns.UI.Refresh()
    equal(#Core.GetSenderReviewCases(world.controller.db), 0)
    equal(world.mails[#world.mails].money, 1000)
    equal(world.take_calls, takeCallsBeforeDismiss)

    local manualRoundId = world.controller.db.active_round_id
    local manualWallet = world.wallet
    local manualTakeCalls = world.take_calls
    local manualRosterRequests = world.roster_requests
    ns.UI.instance.active_entry_add.scripts.OnClick()
    truthy(ns.UI.entry_dialog:IsShown())
    ns.UI.entry_dialog.member:SetText("Typo Name")
    ns.UI.entry_dialog.gold:SetText("0")
    ns.UI.entry_dialog.silver:SetText("10")
    ns.UI.entry_dialog.copper:SetText("0")
    ns.UI.entry_dialog.save.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_ENTRY_CONFIRM")
    truthy(lastPopupData)
    StaticPopupDialogs.GUILD_RAFFLE_ENTRY_CONFIRM.OnAccept({}, lastPopupData)
    ns.UI.Refresh()
    local manualEntries = Core.GetRoundEntries(world.controller.db, manualRoundId)
    equal(#manualEntries, 1)
    equal(manualEntries[1].character, "Typo Name")
    equal(manualEntries[1].manual_entry, true)
    equal(manualEntries[1].tickets, 1)
    equal(world.roster_requests, manualRosterRequests)
    equal(world.take_calls, manualTakeCalls)
    equal(world.wallet, manualWallet)

    ns.UI.instance.active_entry_rows[1].edit.scripts.OnClick()
    ns.UI.entry_dialog.member:SetText("Rina Ashleaf")
    ns.UI.entry_dialog.save.scripts.OnClick()
    equal(lastPopupName, "GUILD_RAFFLE_ENTRY_CONFIRM")
    StaticPopupDialogs.GUILD_RAFFLE_ENTRY_CONFIRM.OnAccept({}, lastPopupData)
    ns.UI.Refresh()
    equal(manualEntries[1].character, "Rina Ashleaf")
    equal(manualEntries[1].character_guid, "Player-1")
    truthy(manualEntries[1].manually_edited_at)
    equal(world.take_calls, manualTakeCalls)
    equal(world.wallet, manualWallet)

    CreateFrame = priorCreateFrame
    SlashCmdList = priorSlashCmdList
    OpenAllMail = priorOpenAllMail
    StaticPopup_Show = priorStaticPopupShow
    UIDropDownMenu_Initialize = priorDropdownInitialize
    UIDropDownMenu_CreateInfo = priorDropdownCreateInfo
    UIDropDownMenu_AddButton = priorDropdownAddButton
    UIDropDownMenu_SetWidth = priorDropdownSetWidth
    UIDropDownMenu_SetSelectedValue = priorDropdownSetSelectedValue
    UIDropDownMenu_SetText = priorDropdownSetText
end)

io.write(string.format("%d targeted tests passed.\n", testsRun))
