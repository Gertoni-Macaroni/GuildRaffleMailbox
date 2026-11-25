local ADDON_NAME, ns = ...

local Core = ns.Core
local Test = {}
ns.SelfTest = Test

local function skip(reason)
    return {
        skipped = true,
        reason = reason,
    }
end

local function collectTests()
    local tests = {}

    table.insert(tests, {
        name = "Forever build and required APIs",
        run = function()
            local compatible, reason = ns.VerifyClientAPI()
            assert(compatible, reason or "The installed client is not verified for collection.")
        end,
    })

    table.insert(tests, {
        name = "accented name normalization",
        run = function()
            assert(type(CaseAccentInsensitiveParse) == "function",
                "CaseAccentInsensitiveParse is unavailable.")
            local upper = Core.NormalizeFullName("  ÉMILE ØRAN  ")
            local lower = Core.NormalizeFullName("émile øran")
            assert(upper == lower,
                "Upper/lowercase accented Latin names did not normalize to the same key.")
            assert(Core.NormalizeFullName("Émile") ~= Core.NormalizeFullName("Emile"),
                "Normalization unexpectedly removed the accent.")
        end,
    })

    table.insert(tests, {
        name = "isolated full-backup round-trip",
        run = function()
            local db = Core.InitializeDB(nil)
            local started, round = Core.StartRound(
                db,
                "Self-test raffle",
                "10s",
                1,
                "Self-test guild",
                1
            )
            assert(started, round)

            local senderKey = Core.NormalizeFullName("Łukasz")
            assert(senderKey, "Could not normalize the temporary sender name.")
            db.sender_aliases[senderKey] = {
                sender = "Łukasz",
                guild_id = 1,
                member_name = "Lukasz",
                member_key = Core.NormalizeFullName("Lukasz"),
                member_guid = "SelfTest-Player",
            }
            db.sender_reviews[1] = {
                id = 1,
                round_id = round.id,
                sender = "ŁUKASZ",
                sender_key = senderKey,
                status = "needs_review",
                current_count = 1,
                current_copper = 1000,
                last_seen_count = 1,
            }
            db.next_sender_review_id = 2

            local text, encodeReason = ns.Backup.Encode(db)
            assert(text, encodeReason or "Temporary database could not be exported.")
            local restored, decodeReason, metadata = ns.Backup.Decode(text, Core)
            assert(restored, decodeReason or "Temporary backup could not be restored.")
            assert(restored.sender_aliases[senderKey].member_guid == "SelfTest-Player",
                "The temporary sender match did not survive backup and restore.")
            assert(#Core.GetSenderReviewCases(restored) == 1,
                "The temporary sender review did not survive backup and restore.")
            assert(metadata.unresolved_sender_names == 1,
                "The restore preview did not count the temporary sender review.")
        end,
    })

    table.insert(tests, {
        name = "foreign sender review, match, and close workflow",
        run = function()
            local db = Core.InitializeDB(nil)
            local started, round = Core.StartRound(
                db,
                "Self-test raffle",
                "10s",
                1,
                "Self-test guild",
                1
            )
            assert(started, round)

            local memberName = "łukasz"
            local member = {
                name = memberName,
                key = Core.NormalizeFullName(memberName),
                guid = "SelfTest-Player",
            }
            local controller = ns.Controller.new(db, {
                now = function() return 1 end,
                serverTime = function() return 1 end,
                isInGuild = function() return true end,
                getGuildClubId = function() return 1 end,
                getGuildName = function() return "Self-test guild" end,
            })
            controller.roster = {
                members = { member },
                by_name = { [member.key] = { member } },
            }
            controller.roster_ready = true
            controller.roster_guild_id = 1
            controller.roster_at = 1

            local function row(sender)
                return {
                    sender = sender,
                    subject = "self-test",
                    money = 1000,
                    cod = 0,
                    attachment_count = 0,
                    returned = false,
                    can_reply = true,
                    is_gm = false,
                }
            end

            local caseRow = row("ŁUKASZ")
            controller.snapshot = {
                complete = true,
                loaded = 1,
                total = 1,
                rows = { caseRow },
            }
            controller:ClassifyRow(caseRow, round, true)
            controller:SyncSenderReviewCases(round)
            if not caseRow.eligible then
                assert(caseRow.sender_review_needed,
                    "An unmatched foreign sender was not flagged for review.")
                local review = Core.GetSenderReviewCases(db)[1]
                assert(review, "The unmatched foreign sender was not added to Review.")
                local matched = controller:ResolveSenderReview(review.id, memberName)
                assert(matched, "The sender could not be matched using the roster name.")
            end
            assert(caseRow.eligible,
                "A supported match or manually repaired sender did not become eligible.")
            assert(#Core.GetRoundEntries(db, round.id) == 0,
                "The sender test unexpectedly created a raffle receipt.")

            local dismissRow = row("ЖУКА")
            controller.snapshot = {
                complete = true,
                loaded = 1,
                total = 1,
                rows = { dismissRow },
            }
            controller:ClassifyRow(dismissRow, round, true)
            controller:SyncSenderReviewCases(round)
            local review = Core.GetSenderReviewCases(db)[1]
            assert(review, "A second unmatched foreign sender was not added to Review.")
            assert(controller:DismissSenderReview(review.id),
                "An unmatched sender review could not be closed.")
            assert(#Core.GetSenderReviewCases(db) == 0,
                "Closing a sender review left it in the open queue.")
            assert(#Core.GetRoundEntries(db, round.id) == 0,
                "Closing a sender review unexpectedly created a raffle receipt.")
        end,
    })

    table.insert(tests, {
        name = "isolated manual entry and correction",
        run = function()
            local db = Core.InitializeDB(nil)
            local started, round = Core.StartRound(
                db,
                "Self-test raffle",
                "1g",
                1,
                "Self-test guild",
                1
            )
            assert(started, round)

            local controller = ns.Controller.new(db, {
                now = function() return 1 end,
                serverTime = function() return 2 end,
                isInGuild = function() return true end,
                getGuildClubId = function() return 1 end,
                getGuildName = function() return "Self-test guild" end,
            })
            local added, receipt = controller:AddManualEntry(round.id, "Typo Name", 10000)
            assert(added, receipt or "Could not add a temporary manual entry.")
            assert(receipt.character == "Typo Name" and receipt.character_guid == nil,
                "Manual entry unexpectedly required a roster match.")
            assert(receipt.tickets == 1 and receipt.manual_entry == true,
                "Temporary manual entry has incorrect ticket or source details.")

            local memberName = "SelfTest Member"
            local member = {
                name = memberName,
                key = Core.NormalizeFullName(memberName),
                guid = "SelfTest-Player",
            }
            controller.roster = {
                members = { member },
                by_name = { [member.key] = { member } },
            }
            controller.roster_ready = true
            controller.roster_guild_id = 1
            controller.roster_at = 1
            local edited, editResult = controller:EditConfirmedEntry(
                round.id,
                receipt.id,
                memberName,
                10000
            )
            assert(edited, editResult or "Could not correct the temporary manual entry.")
            assert(receipt.character == memberName
                and receipt.character_guid == member.guid
                and receipt.manually_edited_at == 2,
                "Temporary manual entry correction was not recorded.")

            local csv = Core.ExportCSV(db, round.id)
            assert(string.find(csv, ",manual,true,", 1, true),
                "Manual-entry source was missing from the temporary CSV.")
        end,
    })

    table.insert(tests, {
        name = "read-only mail API probe",
        run = function()
            local api = ns.Controller.CreateDefaultAPI()
            if not api.compatible then
                return skip("The required client APIs are not available.")
            end

            local countsOK, loaded, total = pcall(api.getInboxCounts)
            if not countsOK then
                error("Inbox counts API raised an error: " .. tostring(loaded))
            end
            loaded = Core.SafeNumber(loaded, 0)
            total = Core.SafeNumber(total, 0)
            if loaded == nil or total == nil then
                return skip("Inbox counts are not readable in the current client state.")
            end
            assert(total >= loaded, "The inbox API reported fewer total messages than loaded messages.")

            local pendingOK, pending = pcall(api.commandPending)
            if not pendingOK then
                error("Mail command status API raised an error: " .. tostring(pending))
            end
            if Core.SafeBoolean(pending) == nil then
                return skip("Mail command status is restricted in the current client state.")
            end

            local checkOK, canCheck = pcall(api.canCheckInbox)
            if not checkOK then
                error("Inbox check status API raised an error: " .. tostring(canCheck))
            end
            if Core.SafeBoolean(canCheck) == nil then
                return skip("Inbox check status is restricted in the current client state.")
            end

            local moneyOK, money = pcall(api.getWallet)
            if not moneyOK then
                error("Character money API raised an error: " .. tostring(money))
            end
            if Core.SafeNumber(money, 0) == nil then
                return skip("Character money is restricted in the current client state.")
            end

            local timeOK, serverTime = pcall(api.serverTime)
            if not timeOK then
                error("Server time API raised an error: " .. tostring(serverTime))
            end
            if Core.SafeNumber(serverTime, 0) == nil then
                return skip("Server time is restricted in the current client state.")
            end
        end,
    })

    table.insert(tests, {
        name = "read-only inbox header probe",
        run = function()
            local frame = MailFrame
            if not frame or type(frame.IsShown) ~= "function" then
                return skip("Cannot confirm that the mailbox window is closed.")
            end
            local shownOK, shown = pcall(frame.IsShown, frame)
            if not shownOK or type(shown) ~= "boolean" then
                return skip("Mailbox window state is unavailable.")
            end
            if shown then
                return skip("Close the mailbox window before probing an inbox header.")
            end

            local api = ns.Controller.CreateDefaultAPI()
            if not api.compatible then
                return skip("The required client APIs are not available.")
            end
            local countsOK, loaded, total = pcall(api.getInboxCounts)
            if not countsOK then
                error("Inbox counts API raised an error: " .. tostring(loaded))
            end
            loaded = Core.SafeNumber(loaded, 0)
            total = Core.SafeNumber(total, 0)
            if loaded == nil or total == nil then
                return skip("Inbox counts are not readable in the current client state.")
            end
            if loaded == 0 then
                return skip("There are no loaded messages to inspect.")
            end

            local headerOK, row = pcall(api.getInboxHeader, 1)
            if not headerOK then
                return skip("The client did not expose an inbox header while the mailbox was closed.")
            end
            if type(row) ~= "table" then
                return skip("The first inbox header is unavailable.")
            end
            local sender = Core.SafeString(row.sender, false)
            local money = Core.SafeNumber(row.money, 0)
            if not sender or money == nil then
                return skip("The first message's sender or attached-money value is restricted.")
            end
            local senderKey = Core.NormalizeFullName(sender)
            assert(senderKey and senderKey ~= "", "The live inbox sender produced an empty match key.")
        end,
    })

    table.insert(tests, {
        name = "read-only guild roster name probe",
        run = function()
            local inGuildOK, inGuild = pcall(IsInGuild)
            if not inGuildOK then
                error("Guild membership API raised an error: " .. tostring(inGuild))
            end
            if Core.SafeBoolean(inGuild) ~= true then
                return skip("This character is not currently in a guild.")
            end

            local countOK, countValue = pcall(GetNumGuildMembers)
            if not countOK then
                error("Guild roster count API raised an error: " .. tostring(countValue))
            end
            local count = Core.SafeNumber(countValue, 0)
            if not count or count == 0 then
                return skip("The guild roster is not loaded.")
            end

            local readable = 0
            local sampleLimit = math.min(count, 10)
            for index = 1, sampleLimit do
                local infoOK, name = pcall(function()
                    return GetGuildRosterInfo(index)
                end)
                if not infoOK then
                    error("Guild roster name API raised an error at row " .. tostring(index) .. ".")
                end
                name = Core.SafeString(name, false)
                if name then
                    local key = Core.NormalizeFullName(name)
                    assert(key and key ~= "", "A readable guild name produced an empty match key.")
                    readable = readable + 1
                end
            end
            if readable == 0 then
                return skip("Guild roster names are not readable in the current client state.")
            end
        end,
    })

    return tests
end

local function chatMessage(message)
    local prefix = "|cff65d7ff[GuildRaffleMailbox]|r "
    local frame = DEFAULT_CHAT_FRAME
    if frame and type(frame.AddMessage) == "function" then
        frame:AddMessage(prefix .. message)
    elseif type(print) == "function" then
        print(prefix .. message)
    end
end

function Test.Run()
    local savedVariables = rawget(_G, "GuildRaffleMailboxDB")
    local passed, failed, skipped = 0, 0, 0
    local failures = {}
    local skippedTests = {}

    for _, test in ipairs(collectTests()) do
        local ok, result = pcall(test.run)
        if not ok then
            failed = failed + 1
            table.insert(failures, test.name .. ": " .. tostring(result))
        elseif type(result) == "table" and result.skipped then
            skipped = skipped + 1
            table.insert(skippedTests, test.name .. ": " .. tostring(result.reason or "unavailable"))
        else
            passed = passed + 1
        end
    end

    local savedVariablesUntouched = rawequal(savedVariables, rawget(_G, "GuildRaffleMailboxDB"))
    if savedVariablesUntouched then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(failures, "SavedVariables isolation: the database reference changed.")
    end

    for _, failure in ipairs(failures) do
        chatMessage("|cffff5555FAIL|r " .. failure)
    end
    for _, skippedTest in ipairs(skippedTests) do
        chatMessage("|cffffd966SKIP|r " .. skippedTest)
    end
    local total = passed + failed
    local suffix = skipped > 0 and string.format(" (%d skipped)", skipped) or ""
    chatMessage(string.format("Self-test: %d/%d passed%s.", passed, total, suffix))
    return passed, failed, skipped
end

SLASH_GUILDRAFFLETEST1 = "/raffletest"
SlashCmdList = SlashCmdList or {}
SlashCmdList.GUILDRAFFLETEST = function()
    Test.Run()
end
