local ADDON_NAME, ns = ...

local Core = ns.Core
local UI = {
    initialized = false,
    active_tab = "collect",
    review_ack_receipt_id = nil,
    history_buttons = {},
    review_buttons = {},
    mail_history_page = 1,
}
ns.UI = UI
local showReportWindow
local showReloadBackupWindow

local TAB_LABELS = {
    { id = "collect", text = "Collect" },
    { id = "setup", text = "Raffle Setup" },
    { id = "active", text = "Active Raffle" },
    { id = "history", text = "History" },
    { id = "mail_history", text = "Mail History" },
    { id = "review", text = "Review" },
}

local nativeOpenAllButton
local nativeOpenAllRunning = false
local nativeOpenAllController
local openEntryDialog

local function syncNativeOpenAll()
    local controller = nativeOpenAllController
    local button = _G.OpenAllMail or (_G.InboxFrame and _G.InboxFrame.OpenAllMail)
    if not controller or not button then
        return
    end

    if button ~= nativeOpenAllButton then
        nativeOpenAllButton = button
        nativeOpenAllRunning = false
        local startOpening = button.StartOpening
        local stopOpening = button.StopOpening
        if type(startOpening) == "function" then
            -- Gamepad calls OnClick directly, so disabling the button alone is insufficient.
            button.StartOpening = function(self, ...)
                controller:ArchiveCurrentInbox("Open All")
                if controller.db.collector_enabled == true then
                    nativeOpenAllRunning = false
                    if self.Disable then
                        self:Disable()
                    end
                    controller:SetStatus("Open All is disabled while this character is collecting raffle payments.")
                    return
                end
                nativeOpenAllRunning = true
                return startOpening(self, ...)
            end
        end
        if type(stopOpening) == "function" then
            button.StopOpening = function(self, ...)
                nativeOpenAllRunning = false
                local result = stopOpening(self, ...)
                syncNativeOpenAll()
                return result
            end
        end
    end

    if controller.db.collector_enabled == true then
        if nativeOpenAllRunning and type(button.StopOpening) == "function" then
            button:StopOpening()
        elseif nativeOpenAllRunning then
            nativeOpenAllRunning = false
        end
        if button.Disable then
            button:Disable()
        end
    elseif not nativeOpenAllRunning and button.Enable then
        button:Enable()
    end
end

local function createLabel(parent, text, point, relativeTo, relativePoint, x, y, width, height, font)
    local label = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    label:SetPoint(point, relativeTo or parent, relativePoint or point, x or 0, y or 0)
    if width then
        label:SetWidth(width)
    end
    if height then
        label:SetHeight(height)
    end
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetText(text or "")
    return label
end

local function createButton(parent, text, width, height, point, relativeTo, relativePoint, x, y, callback)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetPoint(point, relativeTo or parent, relativePoint or point, x or 0, y or 0)
    button:SetText(text)
    button:SetScript("OnClick", callback)
    return button
end

local function createEditBox(parent, width, height, point, relativeTo, relativePoint, x, y)
    local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    edit:SetSize(width, height)
    edit:SetPoint(point, relativeTo or parent, relativePoint or point, x or 0, y or 0)
    edit:SetAutoFocus(false)
    edit:SetTextInsets(5, 5, 2, 2)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    return edit
end

local function createScrollText(parent, width, height, x, y, editable)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width, height)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    edit:SetWidth(width - 28)
    edit:SetHeight(height)
    if edit.SetWordWrap then
        edit:SetWordWrap(true)
    end
    edit:SetPoint("TOPLEFT", scroll, "TOPLEFT", 2, -2)
    edit:SetTextInsets(5, 5, 5, 5)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if self.read_only and userInput and self.saved_text
            and self:GetText() ~= self.saved_text then
            self:SetText(self.saved_text)
            self:SetCursorPosition(0)
            return
        end
        local text = self:GetText() or ""
        local charactersPerLine = math.max(24, math.floor((width - 42) / 7))
        local lines = 0
        for line in string.gmatch(text .. "\n", "(.-)\n") do
            lines = lines + math.max(1, math.ceil(string.len(line) / charactersPerLine))
        end
        self:SetHeight(math.max(height, lines * 16 + 12))
    end)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    edit.read_only = not editable
    if not editable then
        edit:SetScript("OnChar", function(self)
            if self.saved_text then
                self:SetText(self.saved_text)
                self:SetCursorPosition(0)
            end
        end)
    end
    scroll:SetScrollChild(edit)
    return scroll, edit
end

local function setReadOnlyText(edit, text)
    edit.saved_text = text or ""
    edit:SetText(edit.saved_text)
    edit:SetCursorPosition(0)
end

local function addPanel(parent, x, y, width, height, accent)
    if type(parent.CreateTexture) ~= "function" then
        return
    end
    local ok, background = pcall(parent.CreateTexture, parent, nil, "BACKGROUND")
    if not ok or not background then
        return
    end
    background:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    background:SetSize(width, height)
    if background.SetColorTexture then
        background:SetColorTexture(0.025, 0.04, 0.06, 0.82)
    end
    local accentOK, bar = pcall(parent.CreateTexture, parent, nil, "BACKGROUND")
    if accentOK and bar then
        bar:SetPoint("TOPLEFT", background, "TOPLEFT", 0, 0)
        bar:SetSize(3, height)
        if bar.SetColorTexture then
            bar:SetColorTexture(accent[1], accent[2], accent[3], 0.95)
        end
    end
end

local function createCard(parent, title, x, y, width, height, accent)
    addPanel(parent, x, y, width, height, accent)
    return createLabel(
        parent,
        title,
        "TOPLEFT",
        parent,
        "TOPLEFT",
        x + 14,
        y - 13,
        width - 28,
        20,
        "GameFontNormal"
    )
end

local function makePage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -88)
    page:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 12)
    page:Hide()
    return page
end

local function formatMoney(copper)
    copper = Core.SafeNumber(copper, 0) or 0
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local remainder = copper % 100
    local parts = {}
    if gold > 0 then
        table.insert(parts, tostring(gold) .. "g")
    end
    if silver > 0 then
        table.insert(parts, tostring(silver) .. "s")
    end
    if remainder > 0 or #parts == 0 then
        table.insert(parts, tostring(remainder) .. "c")
    end
    return table.concat(parts, " ")
end

local function shorten(text, maxLength)
    text = tostring(text or "")
    if string.len(text) > maxLength then
        return string.sub(text, 1, maxLength - 3) .. "..."
    end
    return text
end

local function setPopup(name, definition)
    StaticPopupDialogs = StaticPopupDialogs or {}
    StaticPopupDialogs[name] = definition
end

local function definePopups()
    local yes = YES or "Confirm"
    local no = NO or "Cancel"
    setPopup("GUILD_RAFFLE_CLOSE", {
        text = "%s\n\nClose this raffle now? Payments have no reliable sent-time. Return any mail received after the cutoff to its sender.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, reason = data.controller:CloseRound(data.round_id)
            data.controller:SetStatus(ok
                and "Raffle closed. Its history is still available."
                or reason)
            if ok and UI.ShowCloseSummary then
                UI.ShowCloseSummary(data.controller.db.last_closed_round_summary)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_START", {
        text = "Start this raffle after checking for leftover payments. Mail has no reliable sent-time, so a late payment could be counted in this raffle.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, result = data.controller:StartRound(data.label, data.preset_id)
            data.controller:SetStatus(ok
                and ("Raffle #" .. tostring(result.id) .. " is now accepting payments.")
                or result)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_RESET", {
        text = "Clear %s entries from '%s'? This removes them from raffle history; gold already collected stays with this character.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, payments, tickets = data.controller:ResetRound(data.round_id)
            if ok then
                data.controller:SetStatus(string.format(
                    "Cleared %d payment(s) and %d ticket(s) from this raffle. Collected gold was not changed.",
                    payments,
                    tickets
                ))
            else
                data.controller:SetStatus(payments)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_MANUAL_CONFIRM", {
        text = "Register this payment manually in its original raffle? Only continue after checking the saved details against your money and inbox.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, reason = data.controller:ConfirmReviewManually(data.receipt_id, true)
            if not ok then
                data.controller:SetStatus(reason)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_ENTRY_CONFIRM", {
        text = "%s\n\nThis changes the raffle record only. The addon does not inspect mail, confirm that payment reached this character, or move gold.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, result
            if data.action == "add" then
                ok, result = data.controller:AddManualEntry(
                    data.round_id,
                    data.character,
                    data.paid_copper
                )
            else
                ok, result = data.controller:EditConfirmedEntry(
                    data.round_id,
                    data.receipt_id,
                    data.character,
                    data.paid_copper
                )
            end
            if not ok then
                data.controller:SetStatus(result)
                return
            end
            if UI.entry_dialog then
                UI.entry_dialog:Hide()
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_DISMISS", {
        text = "Dismiss this pickup attempt without adding tickets? Use this only if you confirmed that the payment was not received.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, reason = data.controller:DismissReview(data.receipt_id)
            if not ok then
                data.controller:SetStatus(reason)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_MATCH_SENDER", {
        text = "Match mail sender '%s' to guild member '%s'? This saves a match for future mail and rechecks the current message against raffle rules. It does not collect gold or enter tickets.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, result = data.controller:ResolveSenderReview(data.review_id, data.member_name)
            if not ok then
                data.controller:SetStatus(result)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_DISMISS_SENDER", {
        text = "Close this sender-name review without matching or crediting a payment? The mail remains in your inbox and will not be automatically collected.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, reason = data.controller:DismissSenderReview(data.review_id)
            if not ok then
                data.controller:SetStatus(reason)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
    setPopup("GUILD_RAFFLE_IMPORT", {
        text = "Replace this character's entire GuildRaffleMailbox saved state with the pasted backup? This replaces raffle history, presets, mail history, and review records.",
        button1 = yes,
        button2 = no,
        OnAccept = function(_, data)
            local ok, reason = data.controller:ImportBackup(data.text)
            data.controller:SetStatus(ok
                and "Full backup imported. Review restored pickups and sender-name matches before collecting."
                or reason)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    })
end

local function activeRound(controller)
    return controller:GetActiveRound()
end

local function selectedRound(controller)
    local round = Core.GetRound(controller.db, controller.db.selected_round_id)
    if round and round.status == "closed" then
        return round
    end
    for index = #controller.db.round_order, 1, -1 do
        round = Core.GetRound(controller.db, controller.db.round_order[index])
        if round and round.status == "closed" then
            controller.db.selected_round_id = round.id
            return round
        end
    end
    controller.db.selected_round_id = nil
    return nil
end

local function showCloseConfirmation(ui)
    local active = activeRound(ui.controller)
    if not active then
        ui.controller:SetStatus("There is no raffle currently accepting payments.")
        return
    end
    local checklist = ui.controller:GetCloseChecklist(active.id)
    local ageText = checklist.scan_age_seconds
        and string.format(" Last scan %.0f second(s) ago%s.",
            checklist.scan_age_seconds,
            checklist.scan_age_seconds > 60 and " — refresh before closing if possible" or "")
        or ""
    local scanText = checklist.scan_complete
        and string.format("Inbox scan: complete (%d/%d messages).%s", checklist.loaded, checklist.total, ageText)
        or checklist.total > 0
            and string.format("Inbox scan: incomplete (%d/%d messages).%s", checklist.loaded, checklist.total, ageText)
            or "Inbox scan: unavailable; open and scan the mailbox before closing if possible."
    local checklistText = string.format(
        "CUTOFF CHECKLIST\n[ ] %s\n[ ] %d currently eligible payment(s) remain in the scanned inbox (%s).\n[ ] %d item(s) need review%s.\n[ ] Return any mail received after the cutoff to its sender.",
        scanText,
        checklist.eligible_waiting,
        formatMoney(checklist.waiting_copper),
        checklist.unresolved,
        checklist.unresolved > 0 and " — closing is blocked until resolved" or ""
    )
    if StaticPopup_Show then
        StaticPopup_Show("GUILD_RAFFLE_CLOSE", checklistText, nil, {
            controller = ui.controller,
            round_id = active.id,
        })
    end
end

local function selectTab(tabId)
    local ui = UI.instance
    if not ui or not ui.pages[tabId] then
        return
    end
    UI.active_tab = tabId
    for id, page in pairs(ui.pages) do
        if id == tabId then
            page:Show()
        else
            page:Hide()
        end
    end
    UI.Refresh()
end

local function createTabs(ui)
    local x = 14
    for _, tab in ipairs(TAB_LABELS) do
        local button = createButton(
            ui.frame,
            tab.text,
            118,
            24,
            "TOPLEFT",
            ui.frame,
            "TOPLEFT",
            x,
            -34,
            function()
                selectTab(tab.id)
            end
        )
        ui.tabs[tab.id] = button
        x = x + 122
    end
end

local function loadPresetForm(ui)
    local preset = Core.GetPreset(ui.controller.db, ui.controller.db.selected_preset_id)
    if not preset then
        return
    end
    ui.preset_name:SetText(preset.name or "")
    local price = Core.SafeNumber(preset.price_copper, 0) or 0
    ui.preset_gold:SetText(tostring(math.floor(price / 10000)))
    ui.preset_silver:SetText(tostring(math.floor((price % 10000) / 100)))
    ui.preset_copper:SetText(tostring(price % 100))
    ui.preset_cap:SetText(preset.cap_per_character and tostring(preset.cap_per_character) or "")
end

function UI.LoadPresetForm()
    local ui = UI.instance
    if ui then
        loadPresetForm(ui)
    end
end

local function savePreset(ui)
    local function coinValue(input)
        local text = input:GetText()
        if text == "" then
            return 0
        end
        return Core.SafeNumber(tonumber(text), 0)
    end
    local gold = coinValue(ui.preset_gold)
    local silver = coinValue(ui.preset_silver)
    local copper = coinValue(ui.preset_copper)
    if not gold or not silver or not copper or silver > 99 or copper > 99 then
        ui.controller:SetStatus("Enter whole-number gold, silver, and copper amounts. Silver and copper must each be 0–99.")
        return
    end
    local price = gold * 10000 + silver * 100 + copper
    local capText = ui.preset_cap:GetText()
    local cap = capText ~= "" and tonumber(capText) or nil
    local ok, result = Core.SavePreset(
        ui.controller.db,
        ui.controller.db.selected_preset_id,
        ui.preset_name:GetText(),
        price,
        cap
    )
    if ok then
        ui.controller:SetStatus("Ticket rules saved. Any raffle already in progress keeps its original rules.")
        loadPresetForm(ui)
    else
        ui.controller:SetStatus(result)
    end
    UI.Refresh()
end

local function startNewPreset(ui)
    ui.previous_preset_id = ui.controller.db.selected_preset_id
    ui.controller.db.selected_preset_id = nil
    ui.preset_name:SetText("")
    ui.preset_gold:SetText("")
    ui.preset_silver:SetText("")
    ui.preset_copper:SetText("")
    ui.preset_cap:SetText("")
    ui.preset_name:SetFocus()
    UI.Refresh()
end

local function reviewItems(ui)
    local items = {}
    for _, receipt in ipairs(Core.GetReviewReceipts(ui.controller.db)) do
        table.insert(items, {
            key = "pickup:" .. tostring(receipt.id),
            kind = "pickup",
            id = receipt.id,
            receipt = receipt,
        })
    end
    for _, senderReview in ipairs(Core.GetSenderReviewCases(ui.controller.db)) do
        table.insert(items, {
            key = "sender:" .. tostring(senderReview.id),
            kind = "sender",
            id = senderReview.id,
            sender_review = senderReview,
        })
    end
    table.sort(items, function(left, right)
        if left.kind ~= right.kind then
            return left.kind == "pickup"
        end
        return left.id < right.id
    end)
    return items
end

local function getSelectedReview(ui)
    local reviews = reviewItems(ui)
    if #reviews == 0 then
        return nil, reviews
    end
    if not ui.selected_review_key then
        return reviews[1], reviews
    end
    for _, review in ipairs(reviews) do
        if review.key == ui.selected_review_key then
            return review, reviews
        end
    end
    return reviews[1], reviews
end

local function selectedReviewIndex(reviews, selected)
    if not selected then
        return 1
    end
    for index, current in ipairs(reviews) do
        if current.key == selected.key then
            return index
        end
    end
    return 1
end

local function walletText(controller)
    local ok, copper = pcall(controller.api.getWallet)
    copper = ok and Core.SafeNumber(copper, 0) or nil
    return copper and formatMoney(copper) or "unavailable"
end

local function pendingText(value)
    if value == true then
        return "Yes"
    elseif value == false then
        return "No"
    end
    return "Unavailable"
end

local function reviewDetails(ui, review, index, count)
    if not review then
        return "There are no items waiting for review.\n\nUnmatched non-ASCII sender names and uncertain pickup attempts appear here."
    end
    if review.kind == "sender" then
        local senderReview = review.sender_review
        local round = Core.GetRound(ui.controller.db, senderReview.round_id)
        local raffleName = round and round.label or ("Raffle #" .. tostring(senderReview.round_id))
        local inInbox = senderReview.current_count or 0
        return string.format(
            "Sender-name review %d of %d\nSender: %s\nRaffle: %s\nMatching funded messages in the latest complete scan: %d\nTotal gold still attached: %s\n\nWhy it needs review: %s\n\nMatching this sender lets the addon recheck those messages against the raffle rules. It does not collect gold or add raffle entries. Closing the review does not match or credit the sender.",
            index,
            count,
            senderReview.sender or "Name unavailable",
            raffleName,
            inInbox,
            formatMoney(senderReview.current_copper or 0),
            senderReview.review_reason or "The sender could not be matched safely."
        )
    end
    local receipt = review.receipt
    local round = Core.GetRound(ui.controller.db, receipt.round_id)
    local raffleName = round and round.label or ("Raffle #" .. tostring(receipt.round_id))
    local evidence = receipt.evidence or {}
    local attempt = receipt.review_evidence or {}
    local matchesBefore = evidence.signature_count ~= nil
        and (tostring(evidence.signature_count) .. " in the loaded inbox") or "Unavailable"
    local matchesAfter = "Unavailable — inbox scan was incomplete."
    if attempt.inbox_complete == true
        and attempt.inbox_loaded ~= nil
        and attempt.inbox_total == attempt.inbox_loaded
        and attempt.matching_funded_count ~= nil then
        matchesAfter = tostring(attempt.matching_funded_count) .. " matching message(s)"
    end
    local inboxMatches = "Unavailable — scan the inbox to compare."
    if ui.controller.snapshot and ui.controller.snapshot.complete
        and ui.controller.snapshot.loaded == ui.controller.snapshot.total
        and evidence.signature then
        inboxMatches = tostring(ui.controller.snapshot.signature_counts[evidence.signature] or 0)
            .. " matching message(s)"
    end
    local inboxSize = "Not scanned"
    if ui.controller.snapshot then
        inboxSize = tostring(ui.controller.snapshot.loaded) .. " loaded of "
            .. tostring(ui.controller.snapshot.total)
        if not ui.controller.snapshot.complete then
            inboxSize = inboxSize .. " (scan incomplete)"
        end
    end
    local walletChange = attempt.wallet_delta ~= nil and formatMoney(math.abs(attempt.wallet_delta))
        or "Unavailable"
    if attempt.wallet_delta and attempt.wallet_delta < 0 then
        walletChange = "-" .. walletChange
    end
    return string.format(
        "Pickup attempt %d of %d — reference #%s\nRaffle: %s\nSender: %s\nPayment: %s (%s ticket(s) at %s each)\n\nCharacter money before pickup: %s\nCharacter money after attempt: %s (change: %s)\nCharacter money now: %s\nMessages with matching payment details before pickup: %s\nMatching messages after attempt: %s\nMatching messages now: %s\nInbox now: %s\nWas WoW still processing mail after the attempt? %s\n\nWhy it needs review: %s",
        index,
        count,
        tostring(receipt.id),
        raffleName,
        receipt.character or "Name unavailable",
        formatMoney(receipt.paid_copper),
        tostring(receipt.tickets or "?"),
        formatMoney(receipt.ticket_price_copper),
        formatMoney(receipt.pre_wallet),
        attempt.wallet_after and formatMoney(attempt.wallet_after) or "Unavailable",
        walletChange,
        walletText(ui.controller),
        matchesBefore,
        matchesAfter,
        inboxMatches,
        inboxSize,
        pendingText(attempt.mail_command_pending),
        receipt.review_reason or "The pickup result could not be confirmed."
    )
end

local function distinctParticipants(entries)
    local parent = {}
    local function find(key)
        if parent[key] ~= key then
            parent[key] = find(parent[key])
        end
        return parent[key]
    end
    local function add(key)
        if key and not parent[key] then
            parent[key] = key
        end
    end
    for _, receipt in ipairs(entries) do
        local guid = receipt.character_guid and ("guid:" .. receipt.character_guid) or nil
        local name = receipt.character_key or Core.NormalizeFullName(receipt.character)
        name = name and ("name:" .. name) or nil
        add(guid)
        add(name)
        if guid and name then
            local guidRoot, nameRoot = find(guid), find(name)
            if guidRoot ~= nameRoot then
                parent[nameRoot] = guidRoot
            end
        end
    end
    local roots = {}
    for key in pairs(parent) do
        roots[find(key)] = true
    end
    local count = 0
    for _ in pairs(roots) do count = count + 1 end
    return count
end

local function historyDetails(round)
    local ui = UI.instance
    if not round then
        setReadOnlyText(ui.history_entries, "Select a raffle from the list to see its registered payments.")
        ui.history_title:SetText("No raffle selected")
        ui.history_status:SetText("")
        ui.history_payments:SetText("0")
        ui.history_tickets:SetText("0")
        ui.history_gold:SetText("0c")
        ui.history_people:SetText("0")
        ui.history_export:SetEnabled(false)
        ui.history_reset:SetEnabled(false)
        return
    end

    local entries = Core.GetRoundEntries(ui.controller.db, round.id)
    local payments, tickets, copper = Core.GetRoundTotals(ui.controller.db, round.id)
    ui.history_title:SetText(shorten(round.label, 48))
    ui.history_status:SetText("Closed raffle — archived and locked · Raffle #" .. tostring(round.id))
    ui.history_payments:SetText(tostring(payments))
    ui.history_tickets:SetText(tostring(tickets))
    ui.history_gold:SetText(formatMoney(copper))
    ui.history_people:SetText(tostring(distinctParticipants(entries)))

    local lines = {}
    if #entries == 0 then
        table.insert(lines, "No payments have been registered in this raffle yet.")
    else
        for entryNumber, receipt in ipairs(entries) do
            local registered = Core.FormatUTC(receipt.registered_at)
            if registered == "" then
                registered = "Time unavailable"
            else
                registered = registered .. " UTC"
            end
            local source = receipt.manual_entry and " · entered manually"
                or receipt.registration_source == "manual" and " · reviewed manually"
                or ""
            if receipt.manually_edited_at then
                source = source .. " · edited manually"
            end
            table.insert(lines, string.format(
                "#%d  %s  ·  %s  ·  %d ticket(s)  ·  %s%s",
                entryNumber,
                receipt.character or "Unknown member",
                formatMoney(receipt.paid_copper),
                receipt.tickets or 0,
                registered,
                source
            ))
        end
    end
    setReadOnlyText(ui.history_entries, table.concat(lines, "\n"))
    ui.history_export:SetEnabled(true)
    ui.history_reset:SetEnabled(round.status ~= "closed"
        and not Core.HasUnresolvedForRound(ui.controller.db, round.id)
        and ui.controller.collection_state == "idle")
end

local function refreshActiveRound(ui, round)
    if not round then
        ui.active_round_title:SetText("No active raffle")
        ui.active_page_info:SetText("Start a raffle in Raffle Setup to see its details here.")
        ui.active_round_payments:SetText("0")
        ui.active_round_tickets:SetText("0")
        ui.active_round_gold:SetText("0c")
        ui.active_round_members:SetText("0")
        ui.active_entries_content:SetHeight(1)
        ui.active_entries_empty:SetText("There are no registered payments in an active raffle.")
        ui.active_entries_empty:Show()
        for _, row in ipairs(ui.active_entry_rows) do
            row:Hide()
        end
        ui.active_round_export:SetEnabled(false)
        ui.active_round_close:SetEnabled(false)
        ui.active_entry_add:SetEnabled(false)
        return
    end

    local entries = Core.GetRoundEntries(ui.controller.db, round.id)
    local payments, tickets, copper = Core.GetRoundTotals(ui.controller.db, round.id)
    local cap = round.preset.cap_per_character
        and (tostring(round.preset.cap_per_character) .. " tickets per member")
        or "No per-member ticket limit"
    local started = Core.FormatUTC(round.start_time)
    ui.active_round_title:SetText("Raffle #" .. tostring(round.id) .. " · " .. shorten(round.label, 48))
    ui.active_page_info:SetText(string.format(
        "Guild: %s  ·  Ticket price: %s  ·  %s  ·  Started: %s UTC",
        round.guild_name or "Unknown guild",
        formatMoney(round.preset.price_copper),
        cap,
        started ~= "" and started or "Unknown"
    ))
    ui.active_round_payments:SetText(tostring(payments))
    ui.active_round_tickets:SetText(tostring(tickets))
    ui.active_round_gold:SetText(formatMoney(copper))
    ui.active_round_members:SetText(tostring(distinctParticipants(entries)))

    local canEdit = not (ui.controller.in_flight
        or (ui.controller.collection and ui.controller.collection.running)
        or ui.controller.collection_state == "collecting"
        or ui.controller.collection_state == "settling"
        or ui.controller.collection_state == "stopping")
    ui.active_entries_content:SetHeight(math.max(1, #entries * 38))
    if #entries == 0 then
        ui.active_entries_empty:SetText("No payments have been registered in this raffle yet.")
        ui.active_entries_empty:Show()
    else
        ui.active_entries_empty:Hide()
    end
    for entryNumber, receipt in ipairs(entries) do
        local row = ui.active_entry_rows[entryNumber]
        if not row then
            row = CreateFrame("Frame", nil, ui.active_entries_content)
            row:SetSize(660, 36)
            row.member = createLabel(row, "", "TOPLEFT", row, "TOPLEFT", 2, -2, 520, 18)
            row.details = createLabel(row, "", "TOPLEFT", row, "TOPLEFT", 2, -19, 520, 16, "GameFontHighlightSmall")
            row.edit = createButton(row, "Edit", 62, 24, "RIGHT", row, "RIGHT", -4, 0, function()
                if openEntryDialog then
                    openEntryDialog(ui, "edit", row.receipt_id)
                end
            end)
            ui.active_entry_rows[entryNumber] = row
        end
        row.receipt_id = receipt.id
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.active_entries_content, "TOPLEFT", 2, -((entryNumber - 1) * 38))
        local registered = Core.FormatUTC(receipt.registered_at)
        registered = registered ~= "" and (registered .. " UTC") or "time unavailable"
        local source = receipt.manual_entry and " · manual entry"
            or receipt.registration_source == "manual" and " · reviewed manually"
            or ""
        if receipt.manually_edited_at then
            source = source .. " · edited manually"
        end
        row.member:SetText(string.format("#%d  %s", entryNumber, receipt.character or "Unknown member"))
        row.details:SetText(string.format(
            "%s  ·  %d ticket(s)  ·  %s%s",
            formatMoney(receipt.paid_copper),
            receipt.tickets or 0,
            registered,
            source
        ))
        row.edit:SetEnabled(canEdit)
        row:Show()
    end
    for index = #entries + 1, #ui.active_entry_rows do
        ui.active_entry_rows[index]:Hide()
    end
    ui.active_round_export:SetEnabled(true)
    ui.active_round_close:SetEnabled(true)
    ui.active_entry_add:SetEnabled(canEdit)
end

local function refreshRoundList(ui)
    local order = {}
    for _, roundId in ipairs(ui.controller.db.round_order) do
        local round = Core.GetRound(ui.controller.db, roundId)
        if round and round.status == "closed" then
            table.insert(order, roundId)
        end
    end
    local selected = selectedRound(ui.controller)
    local selectedId = selected and selected.id
    local contentHeight = math.max(1, #order * 38)
    ui.history_content:SetHeight(contentHeight)
    if #order == 0 then
        ui.history_empty:SetText("Closed raffles will appear here as read-only archives.")
        ui.history_empty:Show()
    else
        ui.history_empty:Hide()
    end

    for index, roundId in ipairs(order) do
        local round = Core.GetRound(ui.controller.db, roundId)
        local row = ui.history_buttons[index]
        if not row then
            row = createButton(ui.history_content, "", 154, 34, "TOPLEFT", ui.history_content, "TOPLEFT", 0, 0, function()
                local id = row.round_id
                ui.controller.db.selected_round_id = id
                UI.Refresh()
            end)
            ui.history_buttons[index] = row
        end
        row.round_id = roundId
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.history_content, "TOPLEFT", 0, -((index - 1) * 38))
        local prefix = roundId == selectedId and "> " or ""
        local label = round and round.label or ("Raffle #" .. tostring(roundId))
        if string.len(label) > 18 then
            label = string.sub(label, 1, 15) .. "..."
        end
        row:SetText(prefix .. "#" .. tostring(roundId) .. " · " .. label)
        row:Show()
    end
    for index = #order + 1, #ui.history_buttons do
        ui.history_buttons[index]:Hide()
    end

    historyDetails(selected)
end

local function refreshReviewList(ui, selected, reviews)
    local contentHeight = math.max(1, #reviews * 48)
    ui.review_content:SetHeight(contentHeight)
    if #reviews == 0 then
        ui.review_empty:SetText("No items need review.")
        ui.review_empty:Show()
    else
        ui.review_empty:Hide()
    end
    for index, receipt in ipairs(reviews) do
        local row = ui.review_buttons[index]
        if not row then
            row = createButton(ui.review_content, "", 154, 42, "TOPLEFT", ui.review_content, "TOPLEFT", 0, 0, function()
                ui.selected_review_key = row.review_key
                UI.Refresh()
            end)
            ui.review_buttons[index] = row
        end
        row.review_key = receipt.key
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", ui.review_content, "TOPLEFT", 0, -((index - 1) * 48))
        if receipt.kind == "sender" then
            local senderReview = receipt.sender_review
            row:SetText(string.format(
                "Name match · %s\n%d message(s) · %s",
                senderReview.sender or "Unknown sender",
                senderReview.current_count or 0,
                formatMoney(senderReview.current_copper or 0)
            ))
        else
            local pickup = receipt.receipt
            row:SetText(string.format(
                "Pickup #%d · %s\n%s",
                pickup.id,
                pickup.character or "Unknown member",
                formatMoney(pickup.paid_copper)
            ))
        end
        row:SetEnabled(not selected or receipt.key ~= selected.key)
        row:Show()
    end
    for index = #reviews + 1, #ui.review_buttons do
        ui.review_buttons[index]:Hide()
    end
end

local MAIL_HISTORY_PAGE_SIZE = 12

local function refreshMailHistory(ui)
    local entries = {}
    for _, entry in ipairs(ui.controller.db.mail_history or {}) do
        if type(entry) == "table" then
            table.insert(entries, entry)
        end
    end
    table.sort(entries, function(left, right)
        local leftTime = Core.SafeFiniteNumber(left.recorded_at, 0) or 0
        local rightTime = Core.SafeFiniteNumber(right.recorded_at, 0) or 0
        if leftTime == rightTime then
            return (Core.SafeNumber(left.id, 0) or 0) > (Core.SafeNumber(right.id, 0) or 0)
        end
        return leftTime > rightTime
    end)

    local totalPages = math.max(1, math.ceil(#entries / MAIL_HISTORY_PAGE_SIZE))
    UI.mail_history_page = math.max(1, math.min(UI.mail_history_page, totalPages))
    local firstIndex = (UI.mail_history_page - 1) * MAIL_HISTORY_PAGE_SIZE + 1
    for rowIndex, row in ipairs(ui.mail_history_rows) do
        local entry = entries[firstIndex + rowIndex - 1]
        if entry then
            local timestamp = Core.SafeFiniteNumber(entry.recorded_at, 0)
            local timeText = timestamp and type(date) == "function"
                and date("%Y-%m-%d %H:%M", timestamp) or "Unknown"
            row.sender:SetText(shorten(entry.sender or "Unknown sender", 48))
            row.money:SetText(formatMoney(entry.money))
            row.time:SetText(timeText)
            row.sender:Show()
            row.money:Show()
            row.time:Show()
        else
            row.sender:Hide()
            row.money:Hide()
            row.time:Hide()
        end
    end
    ui.mail_history_empty:SetShown(#entries == 0)
    ui.mail_history_page_label:SetText(string.format(
        "%d mail message(s) · Page %d of %d",
        #entries,
        UI.mail_history_page,
        totalPages
    ))
    ui.mail_history_previous:SetEnabled(UI.mail_history_page > 1)
    ui.mail_history_next:SetEnabled(UI.mail_history_page < totalPages)
end

local function refresh(ui)
    local controller = ui.controller
    local db = controller.db
    syncNativeOpenAll()
    local active = activeRound(controller)
    refreshActiveRound(ui, active)

    local warning = controller.api.compatible == false
        and controller.api.compatibility_message or controller.discrepancy
    ui.global_warning:SetText(warning or "")
    if controller.discrepancy ~= nil and controller.api.compatible ~= false then
        ui.global_ack:Show()
    else
        ui.global_ack:Hide()
    end
    local inboxFullyScanned = controller.snapshot ~= nil and controller.snapshot.complete
        and controller.snapshot.loaded == controller.snapshot.total
    ui.global_ack:SetText(inboxFullyScanned and "Acknowledge" or "Scan inbox first")
    ui.global_ack:SetEnabled(inboxFullyScanned)
    local reviews = reviewItems(ui)
    for _, tab in ipairs(TAB_LABELS) do
        local button = ui.tabs[tab.id]
        local label = tab.text
        if tab.id == "review" and #reviews > 0 then
            label = "Review (" .. tostring(#reviews) .. ")"
        end
        button:SetText(tab.id == UI.active_tab and ("> " .. label) or label)
        if tab.id == UI.active_tab then
            button:Disable()
        else
            button:Enable()
        end
    end
    refreshMailHistory(ui)

    local preset = Core.GetPreset(db, db.selected_preset_id)
    if UIDropDownMenu_SetSelectedValue and preset then
        UIDropDownMenu_SetSelectedValue(ui.preset_dropdown, preset.id)
    end
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(ui.preset_dropdown, preset and preset.name or "New ticket rules")
    end
    ui.new_preset:SetText(db.selected_preset_id and "New preset" or "Cancel new")
    ui.save_preset:SetEnabled(preset ~= nil or db.selected_preset_id == nil)

    if active then
        ui.setup_round_info:SetText(string.format(
            "Raffle #%d — %s is accepting payments.",
            active.id,
            shorten(active.label, 58)
        ))
    else
        ui.setup_round_info:SetText("No raffle is currently accepting payments.")
    end
    ui.start_button:SetEnabled(active == nil and preset ~= nil)
    ui.close_button:SetEnabled(active ~= nil)

    local activeName = active and active.label or "No raffle is accepting payments."
    ui.collect_active:SetText(active and ("Raffle #" .. tostring(active.id) .. " · " .. shorten(activeName, 48))
        or "Start a raffle in Raffle Setup before collecting.")
    if active then
        local cap = active.preset.cap_per_character
            and (tostring(active.preset.cap_per_character) .. " tickets per member")
            or "No per-member ticket limit"
        ui.collect_rules:SetText(string.format(
            "Ticket price: %s  ·  %s  ·  Guild: %s",
            formatMoney(active.preset.price_copper),
            cap,
            active.guild_name or "current guild"
        ))
    else
        ui.collect_rules:SetText("Your inbox stays unchanged until you choose Collect payments.")
    end

    local ready, reason = controller:GetCollectionReadiness()
    ui.collect_ready:SetText(controller.collection_state == "collecting"
        and "Collection is running."
        or controller.collection_state == "settling"
            and "Waiting for the current pickup to finish."
            or controller.collection_state == "stopping"
                and "Stopping after this pickup finishes."
                or controller.collection_state == "needs-review"
                    and "A pickup needs review before collection can continue."
                    or (ready and "Ready to collect eligible payments."
                        or (reason or "Not ready to collect.")))
    ui.collect_button:SetEnabled(ready and controller.collection_state == "idle")
    ui.stop_button:SetEnabled(controller.collection_state == "collecting"
        or controller.collection_state == "settling"
        or controller.collection_state == "stopping")
    ui.refresh_button:SetEnabled(controller.mailbox_open)
    ui.collector_check:SetChecked(db.collector_enabled == true)
    local report = db.last_collection_report
    local lastBackup = Core.SafeNumber(db.last_full_backup_confirmed_at, 0)
    if report and (not lastBackup or not report.ended_at or lastBackup < report.ended_at) then
        ui.backup_reminder:SetText("Backup reminder: export this collection state and save it outside the game. The addon cannot verify that the copy was saved.")
    elseif lastBackup then
        local confirmed = Core.FormatUTC(lastBackup)
        ui.backup_reminder:SetText("You confirmed a local full backup " .. (confirmed ~= "" and (confirmed .. " UTC") or "previously")
            .. " · the addon cannot verify the file.")
    else
        ui.backup_reminder:SetText("No full export has been generated on this character yet.")
    end
    ui.session_report:SetEnabled(type(report) == "table")

    local snapshot = controller.snapshot
    local eligible, skipped = 0, 0
    for _, row in ipairs(controller:GetPaymentRows()) do
        if row.eligible then
            eligible = eligible + 1
        else
            skipped = skipped + 1
        end
    end
    if snapshot then
        ui.inbox_count:SetText(string.format("%d of %d loaded", snapshot.loaded, snapshot.total))
        ui.eligible_count:SetText(tostring(eligible))
        ui.skipped_count:SetText(tostring(skipped))
    else
        ui.inbox_count:SetText("Not scanned")
        ui.eligible_count:SetText("—")
        ui.skipped_count:SetText("—")
    end

    local preview = {}
    if snapshot then
        for _, row in ipairs(snapshot.rows) do
            if row.money and row.money > 0 then
                table.insert(preview, string.format(
                    "%s  ·  %s  ·  %s",
                    row.sender or "Sender unavailable",
                    formatMoney(row.money),
                    row.reason or "This payment has not been checked."
                ))
            elseif row.unverified then
                table.insert(preview, string.format(
                    "Message %d  ·  Details unavailable; left untouched.",
                    row.index or 0
                ))
            end
        end
        if snapshot.total > snapshot.loaded then
            table.insert(preview, string.format(
                "%d more message(s) have not loaded. The add-on will not open unrelated mail to make room.",
                snapshot.total - snapshot.loaded
            ))
        end
    end
    if #preview == 0 then
        table.insert(preview, snapshot and "No gold payments in the loaded inbox."
            or "Open the mailbox to scan for raffle payments.")
    end
    setReadOnlyText(ui.inbox_rows, table.concat(preview, "\n"))

    refreshRoundList(ui)

    local review, orderedReviews = getSelectedReview(ui)
    if review then
        ui.selected_review_key = review.key
    else
        ui.selected_review_key = nil
    end
    refreshReviewList(ui, review, orderedReviews)
    setReadOnlyText(ui.review_details, reviewDetails(
        ui,
        review,
        selectedReviewIndex(orderedReviews, review),
        #orderedReviews
    ))
    local reviewKey = review and review.key or nil
    if UI.review_ack_receipt_id ~= reviewKey then
        UI.review_ack_receipt_id = reviewKey
        ui.review_ack:SetChecked(false)
        ui.review_sender_member:SetText("")
    end
    local pickupReview = review and review.kind == "pickup"
    local senderReview = review and review.kind == "sender"
    if pickupReview then
        ui.review_pickup_instructions:Show()
        ui.review_ack:Show()
        ui.review_ack_text:Show()
        ui.review_register:Show()
        ui.review_sender_instruction:Hide()
        ui.review_sender_member_label:Hide()
        ui.review_sender_member:Hide()
        ui.review_sender_match:Hide()
        ui.review_register:SetEnabled(true)
        ui.review_dismiss:SetText("Dismiss attempt")
    elseif senderReview then
        ui.review_pickup_instructions:Hide()
        ui.review_ack:Hide()
        ui.review_ack_text:Hide()
        ui.review_register:Hide()
        ui.review_sender_instruction:Show()
        ui.review_sender_member_label:Show()
        ui.review_sender_member:Show()
        ui.review_sender_match:Show()
        ui.review_sender_match:SetEnabled(true)
        ui.review_dismiss:SetText("Close review")
    else
        ui.review_pickup_instructions:Hide()
        ui.review_ack:Hide()
        ui.review_ack_text:Hide()
        ui.review_register:Hide()
        ui.review_sender_instruction:Hide()
        ui.review_sender_member_label:Hide()
        ui.review_sender_member:Hide()
        ui.review_sender_match:Hide()
        ui.review_dismiss:SetText("Dismiss")
    end
    ui.review_ack:SetEnabled(pickupReview == true)
    ui.review_register:SetEnabled(pickupReview == true)
    ui.review_dismiss:SetEnabled(review ~= nil)

    local latest = controller.latest_status or ""
    if not warning and controller.api.compatibility_message then
        latest = controller.api.compatibility_message
    end
    ui.global_status:SetText(warning and "" or latest)
end

function UI.Refresh()
    if UI.instance then
        refresh(UI.instance)
    end
end

local function makeExportWindow(csv)
    if UI.export_frame then
        UI.export_text:SetText(csv)
        UI.export_text:SetCursorPosition(0)
        UI.export_frame:Show()
        return
    end
    local frame = CreateFrame("Frame", "GuildRaffleMailboxExportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(650, 470)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    if frame.SetClampedToScreen then
        frame:SetClampedToScreen(true)
    end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.TitleText then
        frame.TitleText:SetText("Raffle payment export")
    end
    createLabel(frame, "Copy this CSV into your spreadsheet.", "TOPLEFT", frame, "TOPLEFT", 14, -38, 610, 20)
    local selectAll = createButton(frame, "Select all", 100, 24, "TOPLEFT", frame, "TOPLEFT", 14, -62, function()
        UI.export_text:SetFocus()
        UI.export_text:HighlightText()
    end)
    createButton(frame, CLOSE or "Close", 90, 24, "TOPRIGHT", frame, "TOPRIGHT", -14, -62, function()
        frame:Hide()
    end)
    local _, edit = createScrollText(frame, 610, 345, 12, -96, true)
    edit:SetText(csv)
    edit:SetCursorPosition(0)
    UI.export_frame = frame
    UI.export_text = edit
    UI.export_select_all = selectAll
end

local function makeBackupWindow(ui, mode)
    if not UI.backup_frame then
        local frame = CreateFrame("Frame", "GuildRaffleMailboxBackupFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(680, 500)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        if frame.SetClampedToScreen then
            frame:SetClampedToScreen(true)
        end
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        if frame.TitleText then
            frame.TitleText:SetText("Full addon backup")
        end
        local instruction = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -38, 648, 38, "GameFontHighlightSmall")
        local selectAll = createButton(frame, "Select all", 100, 24, "TOPLEFT", frame, "TOPLEFT", 14, -78, function()
            UI.backup_text:SetFocus()
            UI.backup_text:HighlightText()
        end)
        local preview = createButton(frame, "Preview restore", 120, 24, "TOPLEFT", frame, "TOPLEFT", 122, -78, function()
            local text = UI.backup_text:GetText()
            local imported, reason, metadata = ns.Backup.Decode(text, Core)
            if not imported then
                UI.pending_import_text = nil
                UI.backup_apply:Hide()
                UI.backup_instruction:SetText("Backup could not be previewed: " .. tostring(reason))
                return
            end
            local active = metadata.active_round
            local activeText = active
                and string.format("Active raffle: #%d · %s", active.id, active.label or "Unnamed")
                or "Active raffle: none"
            local exported = Core.FormatUTC(metadata.exported_at)
            UI.pending_import_text = text
            UI.backup_instruction:SetText(string.format(
                "RESTORE · %s · %d raffle(s) · %d confirmed payment(s) · review: %d pickup / %d sender name(s) · %d mail row(s) · %s",
                exported ~= "" and (exported .. " UTC") or "time unavailable",
                metadata.rounds,
                metadata.confirmed_payments,
                metadata.unresolved_pickups,
                metadata.unresolved_sender_names,
                metadata.mail_history,
                activeText
            ))
            UI.backup_apply:Show()
        end)
        local apply = createButton(frame, "Replace saved state", 150, 24, "LEFT", preview, "RIGHT", 8, 0, function()
            if UI.backup_text:GetText() ~= UI.pending_import_text then
                UI.pending_import_text = nil
                UI.backup_apply:Hide()
                UI.backup_instruction:SetText("Backup text changed. Preview it again before importing.")
                return
            end
            if StaticPopup_Show then
                StaticPopup_Show("GUILD_RAFFLE_IMPORT", nil, nil, {
                    controller = ui.controller,
                    text = UI.pending_import_text,
                })
            end
        end)
        apply:Hide()
        local backupSaved = createButton(frame, "Backup saved — continue", 180, 24, "TOPLEFT", frame, "TOPLEFT", 122, -78, function()
            local confirmed, reason = ui.controller:MarkBackupConfirmedLocally()
            if not confirmed then
                ui.controller:SetStatus(reason)
                return
            end
            UI.Refresh()
            local backupText = UI.backup_text:GetText()
            if UI.backup_mode == "post_collection" then
                UI.backup_frame:Hide()
                showReloadBackupWindow(backupText)
            else
                UI.backup_instruction:SetText("Local backup confirmation recorded. Keep this text saved outside the game.")
            end
        end)
        backupSaved:Hide()
        createButton(frame, CLOSE or "Close", 90, 24, "TOPRIGHT", frame, "TOPRIGHT", -14, -78, function()
            frame:Hide()
        end)
        local previewLabel = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -107, 648, 30, "GameFontHighlightSmall")
        local _, edit = createScrollText(frame, 640, 350, 12, -137, true)
        UI.backup_frame = frame
        UI.backup_instruction = instruction
        UI.backup_preview = previewLabel
        UI.backup_text = edit
        UI.backup_import = preview
        UI.backup_apply = apply
        UI.backup_saved = backupSaved
        UI.backup_select_all = selectAll
    end

    if mode == "export" or mode == "post_collection" then
        local previousExport = ui.controller.db.last_full_export_generated_at
        ui.controller:MarkFullExportGenerated()
        UI.Refresh()
        local contents, reason = ns.Backup.Encode(ui.controller.db)
        if not contents then
            ui.controller.db.last_full_export_generated_at = previousExport
            UI.Refresh()
            ui.controller:SetStatus("Could not export full backup: " .. tostring(reason))
            return
        end
        UI.backup_instruction:SetText(mode == "post_collection"
            and "Collection is complete. Select all, copy this entire backup, and save it locally before continuing to reload."
            or "Copy all of this data and save it outside the game. It contains the complete persistent addon database.")
        UI.backup_import:Hide()
        UI.backup_apply:Hide()
        UI.backup_saved:SetShown(mode ~= "import")
        UI.backup_saved:SetText(mode == "post_collection"
            and "Backup saved — continue"
            or "I saved a local copy")
        UI.backup_preview:SetText("")
        UI.backup_text:SetText(contents)
    else
        UI.backup_instruction:SetText("Paste a GuildRaffleMailbox full backup below. Import replaces all current saved addon data; collection must be stopped and the mailbox closed.")
        UI.backup_import:Show()
        UI.backup_apply:Hide()
        UI.backup_saved:Hide()
        UI.backup_preview:SetText("")
        UI.pending_import_text = nil
        UI.backup_text:SetText("")
    end
    UI.backup_mode = mode
    UI.backup_text:SetCursorPosition(0)
    UI.backup_frame:Show()
end

showReloadBackupWindow = function(contents)
    if not UI.reload_backup_frame then
        local frame = CreateFrame("Frame", "GuildRaffleMailboxReloadBackupFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(680, 540)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        if frame.SetClampedToScreen then
            frame:SetClampedToScreen(true)
        end
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        if frame.TitleText then
            frame.TitleText:SetText("Confirm backup before reload")
        end
        createLabel(frame, "The same complete backup is shown again below. Reload writes in-memory SavedVariables but cannot verify your external copy. If the button is blocked, type /reload manually.", "TOPLEFT", frame, "TOPLEFT", 14, -38, 648, 32, "GameFontHighlightSmall")
        local _, backupText = createScrollText(frame, 640, 350, 12, -108, false)
        createButton(frame, "Select all", 100, 24, "TOPLEFT", frame, "TOPLEFT", 14, -76, function()
            UI.reload_backup_text:SetFocus()
            UI.reload_backup_text:HighlightText()
        end)
        local confirmed = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        confirmed:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 45)
        local confirmLabel = createLabel(frame, "I ABSOLUTELY MADE A BACKUP", "LEFT", confirmed, "RIGHT", 2, 0, 400, 24, "GameFontNormal")
        local reload = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
        reload:SetSize(125, 26)
        reload:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -112, 16)
        reload:SetText("Reload UI")
        reload:RegisterForClicks("AnyUp")
        reload:SetAttribute("type", "macro")
        reload:SetAttribute("macrotext", "/reload")
        reload:Disable()
        createButton(frame, CLOSE or "Cancel", 90, 26, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 16, function()
            frame:Hide()
        end)
        confirmed:SetScript("OnClick", function(self)
            if self:GetChecked() == true then
                reload:Enable()
            else
                reload:Disable()
            end
        end)
        frame:SetScript("OnShow", function()
            confirmed:SetChecked(false)
            reload:Disable()
        end)
        UI.reload_backup_frame = frame
        UI.reload_backup_text = backupText
        UI.reload_backup_confirm = confirmed
        UI.reload_backup_confirm_label = confirmLabel
        UI.reload_backup_button = reload
    end
    setReadOnlyText(UI.reload_backup_text, contents)
    UI.reload_backup_frame:Show()
end

function UI.OnCollectionFinished(controller, report)
    if report and report.complete_mailbox_pull and UI.instance then
        makeBackupWindow(UI.instance, "post_collection")
    end
end

local function showCopyableReport(title, subtitle, text)
    if not UI.report_frame then
        local frame = CreateFrame("Frame", "GuildRaffleMailboxReportFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(660, 470)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        if frame.SetClampedToScreen then
            frame:SetClampedToScreen(true)
        end
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        local titleText = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -38, 620, 24, "GameFontNormal")
        local subtitleText = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -61, 620, 30, "GameFontHighlightSmall")
        local editScroll, edit = createScrollText(frame, 620, 340, 12, -96, false)
        local selectAll = createButton(frame, "Select all", 100, 24, "BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14, function()
            UI.report_text:SetFocus()
            UI.report_text:HighlightText()
        end)
        createButton(frame, CLOSE or "Close", 90, 24, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14, function()
            frame:Hide()
        end)
        UI.report_frame = frame
        UI.report_title = titleText
        UI.report_subtitle = subtitleText
        UI.report_text = edit
        UI.report_scroll = editScroll
        UI.report_select_all = selectAll
    end
    if UI.report_frame.TitleText then
        UI.report_frame.TitleText:SetText(title)
    end
    UI.report_title:SetText(title)
    UI.report_subtitle:SetText(subtitle)
    setReadOnlyText(UI.report_text, text)
    UI.report_frame:Show()
end

local function collectionReportText(report)
    if type(report) ~= "table" then
        return nil
    end
    local lines = {
        "Collection session — Raffle #" .. tostring(report.raffle_id or "?")
            .. " · " .. tostring(report.raffle_label or "Unnamed"),
        "Started: " .. (Core.FormatUTC(report.started_at) ~= ""
            and (Core.FormatUTC(report.started_at) .. " UTC") or "unavailable"),
        "Finished: " .. (Core.FormatUTC(report.ended_at) ~= ""
            and (Core.FormatUTC(report.ended_at) .. " UTC") or "unavailable"),
        string.format("Payments registered: %d · Tickets: %d · Gold: %s",
            report.payments or 0, report.tickets or 0, formatMoney(report.copper)),
        string.format("Eligible at start: %d · Not eligible at start: %d",
            report.eligible_at_start or 0, report.skipped_at_start or 0),
        "Result: " .. tostring(report.result or "Unavailable"),
        "",
        "Session activity:",
    }
    if type(report.items) == "table" and #report.items > 0 then
        for _, item in ipairs(report.items) do
            table.insert(lines, tostring(item))
        end
    else
        table.insert(lines, "No pickups were registered in this session.")
    end
    return table.concat(lines, "\n")
end

function UI.ShowCloseSummary(summary)
    if type(summary) ~= "table" then
        return
    end
    local closed = Core.FormatUTC(summary.closed_at)
    local scan = summary.scan_complete
        and string.format("complete (%d/%d messages)", summary.loaded or 0, summary.total or 0)
        or string.format("incomplete (%d/%d messages)", summary.loaded or 0, summary.total or 0)
    local text = string.format(
        "Raffle #%s — %s\nClosed: %s\nPayments: %d\nTickets: %d\nGold recorded: %s\nDistinct members: %d\nInbox at close: %s\nEligible payments still waiting at close: %d (%s)\nUnresolved review items at close: %d",
        tostring(summary.raffle_id or "?"),
        tostring(summary.raffle_label or "Unnamed"),
        closed ~= "" and (closed .. " UTC") or "time unavailable",
        summary.payments or 0,
        summary.tickets or 0,
        formatMoney(summary.copper),
        summary.members or 0,
        scan,
        summary.eligible_waiting or 0,
        formatMoney(summary.waiting_copper),
        summary.unresolved or 0
    )
    showCopyableReport(
        "Raffle close summary",
        "Select all and copy this summary into your guild records. Export the raffle CSV separately.",
        text
    )
end

local function buildCollectPage(ui)
    local page = ui.pages.collect
    createCard(page, "Current raffle", 8, -8, 728, 132, { 0.25, 0.68, 0.78 })
    ui.collect_active = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 22, -39, 490, 24, "GameFontNormalLarge")
    ui.collect_rules = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 22, -67, 690, 18)
    ui.collect_ready = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 22, -88, 690, 18, "GameFontHighlightSmall")
    ui.collector_check = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    ui.collector_check:SetPoint("TOPLEFT", page, "TOPLEFT", 535, -28)
    ui.collector_check:SetScript("OnClick", function(self)
        ui.controller:SetCollectorEnabled(self:GetChecked() == true)
    end)
    createLabel(page, "Use this character to collect", "TOPLEFT", page, "TOPLEFT", 559, -34, 165, 28, "GameFontHighlightSmall")

    ui.collect_button = createButton(page, "Collect payments", 170, 28, "TOPLEFT", page, "TOPLEFT", 22, -99, function()
        local ok, reason = ui.controller:StartCollection()
        if not ok and reason then
            ui.controller:SetStatus(reason)
        end
    end)
    ui.stop_button = createButton(page, "Stop collection", 112, 28, "LEFT", ui.collect_button, "RIGHT", 8, 0, function()
        ui.controller:StopCollection()
    end)
    ui.refresh_button = createButton(page, "Refresh inbox", 110, 28, "LEFT", ui.stop_button, "RIGHT", 8, 0, function()
        if not ui.controller.mailbox_open then
            ui.controller:SetStatus("Open the mailbox before refreshing.")
            return
        end
        local ok, canCheck, wait = pcall(ui.controller.api.canCheckInbox)
        canCheck = ok and Core.SafeBoolean(canCheck) or nil
        if canCheck then
            pcall(ui.controller.api.checkInbox)
            ui.controller:SetStatus("Inbox refresh requested.")
        elseif ok and Core.SafeNumber(wait, 0) and wait > 0 then
            ui.controller:SetStatus(string.format("You can refresh the inbox in %.1f seconds.", wait))
        else
            ui.controller:SetStatus("Inbox refresh is not available right now.")
        end
    end)

    createCard(page, "Inbox summary", 8, -149, 231, 78, { 0.34, 0.62, 0.78 })
    createCard(page, "Eligible payments", 256, -149, 231, 78, { 0.28, 0.7, 0.52 })
    createCard(page, "Not eligible", 505, -149, 231, 78, { 0.83, 0.59, 0.3 })
    ui.inbox_count = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 24, -194, 195, 25, "GameFontNormalLarge")
    ui.eligible_count = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 272, -194, 195, 25, "GameFontNormalLarge")
    ui.skipped_count = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 521, -194, 195, 25, "GameFontNormalLarge")

    createCard(page, "Payments in the loaded inbox", 8, -239, 728, 307, { 0.32, 0.61, 0.73 })
    local _, inboxRows = createScrollText(page, 694, 235, 20, -278, false)
    ui.inbox_rows = inboxRows
    createLabel(
        page,
        "Only eligible gold payments are collected. Other messages are left alone.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        22,
        -523,
        690,
        18,
        "GameFontHighlightSmall"
    )
    ui.backup_reminder = createLabel(page, "", "BOTTOMLEFT", page, "BOTTOMLEFT", 22, 43, 690, 28, "GameFontHighlightSmall")
    ui.full_export = createButton(page, "Full Export", 110, 24, "BOTTOMLEFT", page, "BOTTOMLEFT", 22, 12, function()
        makeBackupWindow(ui, "export")
    end)
    ui.full_import = createButton(page, "Full Import", 110, 24, "LEFT", ui.full_export, "RIGHT", 8, 0, function()
        makeBackupWindow(ui, "import")
    end)
    ui.session_report = createButton(page, "Session Report", 120, 24, "LEFT", ui.full_import, "RIGHT", 8, 0, function()
        local report = ui.controller.db.last_collection_report
        local text = collectionReportText(report)
        if not text then
            ui.controller:SetStatus("No collection session report is available yet.")
            return
        end
        showCopyableReport(
            "Collection session report",
            "Select all and copy this session summary into your local records.",
            text
        )
    end)
end

local function createCoinInput(parent, x, width, texturePath, maxLetters, y)
    local input = createEditBox(parent, width, 24, "TOPLEFT", parent, "TOPLEFT", x, y or -101)
    input:SetNumeric(true)
    input:SetMaxLetters(maxLetters)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(texturePath)
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", input, "RIGHT", 3, 0)
    return input
end

local function parseCoinPart(edit, maxDigits)
    local text = edit:GetText() or ""
    if text == "" then
        return 0
    end
    if string.len(text) > maxDigits then
        return nil
    end
    local value = tonumber(text)
    return Core.SafeNumber(value, 0)
end

local function entryDialogAmount(dialog)
    local gold = parseCoinPart(dialog.gold, 8)
    local silver = parseCoinPart(dialog.silver, 2)
    local copper = parseCoinPart(dialog.copper, 2)
    if gold == nil or silver == nil or copper == nil or silver > 99 or copper > 99 then
        return nil, "Enter gold and valid silver/copper values from 0 to 99."
    end
    local amount = gold * 10000 + silver * 100 + copper
    amount = Core.SafeNumber(amount, 1)
    if not amount then
        return nil, "Enter a positive payment amount."
    end
    return amount
end

local function setEntryDialogMoney(dialog, amount)
    amount = Core.SafeNumber(amount, 0) or 0
    dialog.gold:SetText(tostring(math.floor(amount / 10000)))
    dialog.silver:SetText(tostring(math.floor((amount % 10000) / 100)))
    dialog.copper:SetText(tostring(amount % 100))
end

local function updateEntryDialogPreview(dialog)
    local round = dialog.controller and dialog.controller:GetActiveRound()
    if not round then
        dialog.preview:SetText("There is no active raffle.")
        return
    end
    local amount = entryDialogAmount(dialog)
    if not amount then
        dialog.preview:SetText(string.format(
            "Enter an amount that is an exact multiple of %s.",
            formatMoney(round.preset.price_copper)
        ))
        return
    end
    local price = round.preset.price_copper
    if amount % price ~= 0 then
        dialog.preview:SetText(string.format(
            "Amount must be an exact multiple of %s.",
            formatMoney(price)
        ))
        return
    end
    dialog.preview:SetText(string.format(
        "%s at %s per ticket = %d ticket(s).",
        formatMoney(amount),
        formatMoney(price),
        amount / price
    ))
end

local function ensureEntryDialog(ui)
    if UI.entry_dialog then
        UI.entry_dialog.controller = ui.controller
        return UI.entry_dialog
    end

    local frame = CreateFrame("Frame", "GuildRaffleMailboxEntryFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 330)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    if frame.SetClampedToScreen then
        frame:SetClampedToScreen(true)
    end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    if frame.TitleText then
        frame.TitleText:SetText("Raffle entry")
    end

    frame.instructions = createLabel(
        frame,
        "",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        16,
        -38,
        425,
        44,
        "GameFontHighlightSmall"
    )
    createLabel(frame, "Member name", "TOPLEFT", frame, "TOPLEFT", 20, -90, 390, 18, "GameFontHighlightSmall")
    frame.member = createEditBox(frame, 410, 24, "TOPLEFT", frame, "TOPLEFT", 20, -108)
    frame.member:SetMaxLetters(96)

    createLabel(frame, "Gold", "TOPLEFT", frame, "TOPLEFT", 20, -143, 90, 18, "GameFontHighlightSmall")
    createLabel(frame, "Silver", "TOPLEFT", frame, "TOPLEFT", 150, -143, 70, 18, "GameFontHighlightSmall")
    createLabel(frame, "Copper", "TOPLEFT", frame, "TOPLEFT", 250, -143, 70, 18, "GameFontHighlightSmall")
    frame.gold = createCoinInput(frame, 20, 88, "Interface\\MoneyFrame\\UI-GoldIcon", 8, -160)
    frame.silver = createCoinInput(frame, 150, 50, "Interface\\MoneyFrame\\UI-SilverIcon", 2, -160)
    frame.copper = createCoinInput(frame, 250, 50, "Interface\\MoneyFrame\\UI-CopperIcon", 2, -160)
    frame.preview = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 20, -199, 410, 32, "GameFontHighlightSmall")
    frame.member:SetScript("OnTextChanged", function()
        updateEntryDialogPreview(frame)
    end)
    for _, input in ipairs({ frame.gold, frame.silver, frame.copper }) do
        input:SetScript("OnTextChanged", function()
            updateEntryDialogPreview(frame)
        end)
    end

    frame.save = createButton(frame, "Save", 120, 26, "BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 18, function()
        local round = frame.controller and frame.controller:GetActiveRound()
        if not round or round.id ~= frame.round_id then
            frame.controller:SetStatus("The active raffle changed. Reopen the entry form and try again.")
            frame:Hide()
            return
        end
        local character = Core.SafeString(frame.member:GetText(), false)
        if character then
            character = string.gsub(character, "^%s+", "")
            character = string.gsub(character, "%s+$", "")
        end
        if not character or character == "" or string.len(character) > 96
            or string.find(character, "%c") then
            frame.controller:SetStatus("Enter the member name to record.")
            return
        end
        local amount, reason = entryDialogAmount(frame)
        if not amount then
            frame.controller:SetStatus(reason)
            return
        end
        local price = round.preset.price_copper
        if amount % price ~= 0 then
            frame.controller:SetStatus("Payment must be an exact multiple of this raffle's ticket price.")
            return
        end
        local action = frame.mode == "add" and "add" or "edit"
        local summary = action == "add"
            and string.format(
                "Add manual entry for %s: %s = %d ticket(s)?",
                character,
                formatMoney(amount),
                amount / price
            )
            or string.format(
                "Correct entry #%d to %s: %s = %d ticket(s)?",
                frame.receipt_id,
                character,
                formatMoney(amount),
                amount / price
            )
        if StaticPopup_Show then
            StaticPopup_Show("GUILD_RAFFLE_ENTRY_CONFIRM", summary, nil, {
                action = action,
                controller = frame.controller,
                round_id = frame.round_id,
                receipt_id = frame.receipt_id,
                character = character,
                paid_copper = amount,
            })
        end
    end)
    frame.cancel = createButton(frame, CLOSE or "Cancel", 100, 26, "LEFT", frame.save, "RIGHT", 10, 0, function()
        frame:Hide()
    end)

    UI.entry_dialog = frame
    return frame
end

openEntryDialog = function(ui, mode, receiptId)
    local controller = ui.controller
    local round = activeRound(controller)
    if not round or round.status ~= "active" then
        controller:SetStatus("Only entries in an active raffle can be changed.")
        return
    end
    if controller.in_flight or (controller.collection and controller.collection.running)
        or controller.collection_state == "collecting"
        or controller.collection_state == "settling"
        or controller.collection_state == "stopping" then
        controller:SetStatus("Wait for the current collection operation to finish before changing entries.")
        return
    end

    local receipt
    if mode == "edit" then
        for _, candidate in ipairs(Core.GetRoundEntries(controller.db, round.id)) do
            if candidate.id == receiptId then
                receipt = candidate
                break
            end
        end
        if not receipt then
            controller:SetStatus("This confirmed entry could not be found in the active raffle.")
            return
        end
    end

    local dialog = ensureEntryDialog(ui)
    dialog.controller = controller
    dialog.mode = mode
    dialog.round_id = round.id
    dialog.receipt_id = receiptId
    dialog.member:SetText(receipt and receipt.character or "")
    setEntryDialogMoney(dialog, receipt and receipt.paid_copper or 0)
    if mode == "add" then
        if dialog.TitleText then
            dialog.TitleText:SetText("Add manual raffle entry")
        end
        dialog.instructions:SetText(
            "Manual entry only: the name is not checked against the guild roster. A typo can affect per-member limits and winner matching. Verify names and membership when pulling winners; closed raffles cannot be edited."
        )
        dialog.save:SetText("Add entry")
    else
        if dialog.TitleText then
            dialog.TitleText:SetText("Edit raffle entry")
        end
        dialog.instructions:SetText(
            "Correct an existing entry. The member name must match exactly one person in the current guild roster."
        )
        dialog.save:SetText("Save correction")
    end
    updateEntryDialogPreview(dialog)
    dialog:Show()
    dialog.member:SetFocus()
end

local function buildSetupPage(ui)
    local page = ui.pages.setup
    createCard(page, "Ticket rules", 8, -8, 728, 238, { 0.77, 0.62, 0.3 })
    ui.preset_dropdown = CreateFrame("Frame", "GuildRafflePresetDropdown", page, "UIDropDownMenuTemplate")
    ui.preset_dropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -27)
    if UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(ui.preset_dropdown, 210)
    end
    UIDropDownMenu_Initialize(ui.preset_dropdown, function(_, level)
        for _, presetId in ipairs(ui.controller.db.preset_order) do
            local preset = Core.GetPreset(ui.controller.db, presetId)
            if preset then
                local selectedPresetId = presetId
                local info = UIDropDownMenu_CreateInfo()
                info.text = preset.name
                info.value = selectedPresetId
                info.func = function()
                    ui.controller.db.selected_preset_id = selectedPresetId
                    loadPresetForm(ui)
                    UI.Refresh()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)
    ui.new_preset = createButton(page, "New preset", 100, 24, "LEFT", ui.preset_dropdown, "RIGHT", 0, 0, function()
        if not ui.controller.db.selected_preset_id then
            ui.controller.db.selected_preset_id = ui.previous_preset_id
                or ui.controller.db.preset_order[1]
            ui.previous_preset_id = nil
            loadPresetForm(ui)
            UI.Refresh()
        else
            startNewPreset(ui)
        end
    end)

    createLabel(page, "Preset name", "TOPLEFT", page, "TOPLEFT", 22, -83, 210, 18, "GameFontHighlightSmall")
    createLabel(page, "Ticket price", "TOPLEFT", page, "TOPLEFT", 252, -83, 265, 18, "GameFontHighlightSmall")
    createLabel(page, "Ticket limit per member (blank = no limit)", "TOPLEFT", page, "TOPLEFT", 526, -83, 195, 18, "GameFontHighlightSmall")
    ui.preset_name = createEditBox(page, 210, 24, "TOPLEFT", page, "TOPLEFT", 22, -101)
    ui.preset_name:SetMaxLetters(60)
    ui.preset_gold = createCoinInput(page, 252, 56, "Interface\\MoneyFrame\\UI-GoldIcon", 8)
    ui.preset_silver = createCoinInput(page, 342, 40, "Interface\\MoneyFrame\\UI-SilverIcon", 2)
    ui.preset_copper = createCoinInput(page, 414, 40, "Interface\\MoneyFrame\\UI-CopperIcon", 2)
    ui.preset_cap = createEditBox(page, 190, 24, "TOPLEFT", page, "TOPLEFT", 526, -101)
    ui.preset_cap:SetNumeric(true)
    ui.preset_cap:SetMaxLetters(8)
    ui.save_preset = createButton(page, "Save ticket rules", 140, 26, "TOPLEFT", page, "TOPLEFT", 22, -140, function()
        savePreset(ui)
    end)
    createLabel(
        page,
        "Example: 10 silver is 1,000 copper. Existing raffles keep the ticket price and limit they started with.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        22,
        -179,
        690,
        32,
        "GameFontHighlightSmall"
    )

    createCard(page, "Raffle controls", 8, -249, 728, 296, { 0.3, 0.66, 0.57 })
    ui.setup_round_info = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 22, -281, 690, 26, "GameFontNormal")
    ui.round_label_caption = createLabel(page, "Name for the next raffle", "TOPLEFT", page, "TOPLEFT", 22, -321, 300, 18, "GameFontHighlightSmall")
    ui.round_label = createEditBox(page, 300, 24, "TOPLEFT", page, "TOPLEFT", 22, -340)
    ui.round_label:SetMaxLetters(80)
    ui.round_label:SetText("Weekly raffle")
    ui.start_button = createButton(page, "Start raffle", 130, 28, "TOPLEFT", page, "TOPLEFT", 22, -382, function()
        if activeRound(ui.controller) then
            ui.controller:SetStatus("Close the active raffle before starting another.")
            return
        end
        if StaticPopup_Show then
            StaticPopup_Show("GUILD_RAFFLE_START", nil, nil, {
                controller = ui.controller,
                label = ui.round_label:GetText(),
                preset_id = ui.controller.db.selected_preset_id,
            })
        end
    end)
    ui.close_button = createButton(page, "Close active raffle", 160, 28, "LEFT", ui.start_button, "RIGHT", 10, 0, function()
        showCloseConfirmation(ui)
    end)
    createLabel(
        page,
        "Before starting or closing, check for late or unreviewed payments. Mail does not show a reliable sent-time.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        22,
        -432,
        690,
        36,
        "GameFontHighlightSmall"
    )
end

local function buildActivePage(ui)
    local page = ui.pages.active
    createCard(page, "Active raffle details", 8, -8, 728, 548, { 0.77, 0.62, 0.3 })
    ui.active_round_title = createLabel(page, "No active raffle", "TOPLEFT", page, "TOPLEFT", 22, -39, 690, 28, "GameFontNormalLarge")
    ui.active_page_info = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 22, -69, 690, 32, "GameFontHighlightSmall")

    createCard(page, "Payments", 20, -105, 155, 68, { 0.34, 0.65, 0.79 })
    createCard(page, "Tickets", 190, -105, 155, 68, { 0.32, 0.7, 0.51 })
    createCard(page, "Gold recorded", 360, -105, 170, 68, { 0.82, 0.65, 0.31 })
    createCard(page, "Members", 545, -105, 175, 68, { 0.6, 0.49, 0.75 })
    ui.active_round_payments = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 32, -146, 130, 26, "GameFontNormalLarge")
    ui.active_round_tickets = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 202, -146, 130, 26, "GameFontNormalLarge")
    ui.active_round_gold = createLabel(page, "0c", "TOPLEFT", page, "TOPLEFT", 372, -146, 145, 26, "GameFontNormalLarge")
    ui.active_round_members = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 557, -146, 145, 26, "GameFontNormalLarge")

    createCard(page, "Registered payments", 8, -182, 728, 326, { 0.35, 0.62, 0.76 })
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetSize(694, 238)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 20, -220)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(664, 1)
    scroll:SetScrollChild(content)
    ui.active_entries_scroll = scroll
    ui.active_entries_content = content
    ui.active_entry_rows = {}
    ui.active_entries_empty = createLabel(
        content,
        "No payments have been registered in this raffle yet.",
        "TOPLEFT",
        content,
        "TOPLEFT",
        4,
        -4,
        610,
        20,
        "GameFontHighlightSmall"
    )
    ui.active_round_export = createButton(page, "Export CSV", 120, 28, "BOTTOMLEFT", page, "BOTTOMLEFT", 22, 18, function()
        local active = activeRound(ui.controller)
        if active then
            makeExportWindow(Core.ExportCSV(ui.controller.db, active.id))
        end
    end)
    ui.active_entry_add = createButton(page, "Manual entry", 132, 28, "LEFT", ui.active_round_export, "RIGHT", 8, 0, function()
        if openEntryDialog then
            openEntryDialog(ui, "add")
        end
    end)
    ui.active_round_close = createButton(page, "Close Raffle", 140, 28, "LEFT", ui.active_entry_add, "RIGHT", 8, 0, function()
        showCloseConfirmation(ui)
    end)
end

local function buildHistoryPage(ui)
    local page = ui.pages.history
    createCard(page, "Closed raffles", 8, -8, 202, 548, { 0.3, 0.6, 0.79 })
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetSize(184, 465)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -45)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(156, 1)
    scroll:SetScrollChild(content)
    ui.history_content = content
    ui.history_empty = createLabel(page, "Raffles you start will appear here.", "TOPLEFT", page, "TOPLEFT", 20, -62, 168, 56, "GameFontHighlightSmall")

    createCard(page, "Archived raffle", 222, -8, 514, 548, { 0.78, 0.61, 0.31 })
    ui.history_title = createLabel(page, "No raffle selected", "TOPLEFT", page, "TOPLEFT", 238, -37, 490, 26, "GameFontNormalLarge")
    ui.history_status = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 238, -61, 490, 18, "GameFontHighlightSmall")

    createCard(page, "Payments", 234, -86, 112, 75, { 0.34, 0.65, 0.79 })
    createCard(page, "Tickets", 354, -86, 112, 75, { 0.32, 0.7, 0.51 })
    createCard(page, "Gold recorded", 474, -86, 124, 75, { 0.82, 0.65, 0.31 })
    createCard(page, "Members", 606, -86, 118, 75, { 0.6, 0.49, 0.75 })
    ui.history_payments = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 246, -133, 90, 25, "GameFontNormalLarge")
    ui.history_tickets = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 366, -133, 90, 25, "GameFontNormalLarge")
    ui.history_gold = createLabel(page, "0c", "TOPLEFT", page, "TOPLEFT", 486, -133, 105, 25, "GameFontNormalLarge")
    ui.history_people = createLabel(page, "0", "TOPLEFT", page, "TOPLEFT", 618, -133, 90, 25, "GameFontNormalLarge")

    createCard(page, "Registered payments", 222, -172, 514, 369, { 0.35, 0.62, 0.76 })
    local _, entries = createScrollText(page, 478, 286, 234, -211, false)
    ui.history_entries = entries
    ui.history_export = createButton(page, "Export CSV", 120, 28, "TOPLEFT", page, "TOPLEFT", 238, -511, function()
        local round = selectedRound(ui.controller)
        if round then
            makeExportWindow(Core.ExportCSV(ui.controller.db, round.id))
        end
    end)
    ui.history_reset = createButton(page, "Clear raffle entries", 160, 28, "LEFT", ui.history_export, "RIGHT", 10, 0, function()
        local round = selectedRound(ui.controller)
        if not round then
            ui.controller:SetStatus("Select a raffle first.")
            return
        end
        if round.status == "closed" then
            ui.controller:SetStatus("Closed raffles are archives; their entries cannot be changed.")
            return
        end
        if Core.HasUnresolvedForRound(ui.controller.db, round.id) then
            ui.controller:SetStatus("Resolve or dismiss pending review items before clearing entries.")
            return
        end
        local payments, tickets = Core.GetRoundTotals(ui.controller.db, round.id)
        if StaticPopup_Show then
            StaticPopup_Show("GUILD_RAFFLE_RESET", tostring(payments) .. " payment(s) and "
                .. tostring(tickets) .. " ticket(s)", round.label, {
                    controller = ui.controller,
                    round_id = round.id,
                })
        end
    end)
end

local function buildMailHistoryPage(ui)
    local page = ui.pages.mail_history
    createCard(page, "All mail on this collector character", 8, -8, 728, 548, { 0.34, 0.68, 0.73 })
    createLabel(
        page,
        "Messages are saved while collection is enabled. “First recorded” is when the inbox first showed the mail; WoW does not provide a reliable sent time.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        22,
        -39,
        690,
        34,
        "GameFontHighlightSmall"
    )
    createLabel(page, "Sender / name", "TOPLEFT", page, "TOPLEFT", 24, -82, 310, 20, "GameFontNormal")
    createLabel(page, "Attached gold", "TOPLEFT", page, "TOPLEFT", 360, -82, 110, 20, "GameFontNormal")
    createLabel(page, "First recorded", "TOPLEFT", page, "TOPLEFT", 490, -82, 220, 20, "GameFontNormal")

    ui.mail_history_rows = {}
    for index = 1, MAIL_HISTORY_PAGE_SIZE do
        local y = -112 - ((index - 1) * 34)
        local sender = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 24, y, 310, 24, "GameFontHighlight")
        local money = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 360, y, 110, 24, "GameFontHighlight")
        local time = createLabel(page, "", "TOPLEFT", page, "TOPLEFT", 490, y, 220, 24, "GameFontHighlightSmall")
        table.insert(ui.mail_history_rows, {
            sender = sender,
            money = money,
            time = time,
        })
    end
    ui.mail_history_empty = createLabel(
        page,
        "No mail has been recorded yet. Enable collection and scan the inbox.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        24,
        -126,
        680,
        30,
        "GameFontHighlight"
    )
    ui.mail_history_previous = createButton(page, "Previous", 90, 24, "BOTTOMLEFT", page, "BOTTOMLEFT", 24, 18, function()
        UI.mail_history_page = UI.mail_history_page - 1
        UI.Refresh()
    end)
    ui.mail_history_page_label = createLabel(page, "", "BOTTOM", page, "BOTTOM", 0, 22, 330, 20, "GameFontHighlightSmall")
    ui.mail_history_next = createButton(page, "Next", 90, 24, "BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 18, function()
        UI.mail_history_page = UI.mail_history_page + 1
        UI.Refresh()
    end)
end

local function buildReviewPage(ui)
    local page = ui.pages.review
    createCard(page, "Items to review", 8, -8, 202, 548, { 0.84, 0.57, 0.29 })
    local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetSize(184, 465)
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -45)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(156, 1)
    scroll:SetScrollChild(content)
    ui.review_content = content
    ui.review_empty = createLabel(page, "There are no items waiting for review.", "TOPLEFT", page, "TOPLEFT", 20, -62, 168, 55, "GameFontHighlightSmall")

    createCard(page, "Review item details", 222, -8, 514, 266, { 0.81, 0.57, 0.3 })
    local _, details = createScrollText(page, 478, 218, 234, -45, false)
    ui.review_details = details

    createCard(page, "Resolve or close this item", 222, -273, 514, 283, { 0.69, 0.52, 0.34 })
    ui.review_pickup_instructions = createLabel(
        page,
        "Compare the saved money and inbox details with what happened in game. Make sure the gold reached this character and is no longer attached to the message. This helps prevent missing or double-counting a payment.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        238,
        -308,
        480,
        62,
        "GameFontHighlightSmall"
    )
    ui.review_sender_instruction = createLabel(
        page,
        "To fix the name match, enter the guild member's full name exactly as shown in the roster. The mail is rechecked against raffle rules; it is not collected or credited here.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        238,
        -308,
        480,
        52,
        "GameFontHighlightSmall"
    )
    ui.review_sender_member_label = createLabel(
        page,
        "Guild member's full name",
        "TOPLEFT",
        page,
        "TOPLEFT",
        238,
        -360,
        290,
        18,
        "GameFontHighlightSmall"
    )
    ui.review_sender_member = createEditBox(page, 290, 24, "TOPLEFT", page, "TOPLEFT", 238, -378)
    ui.review_ack = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    ui.review_ack:SetPoint("TOPLEFT", page, "TOPLEFT", 232, -380)
    ui.review_ack_text = createLabel(
        page,
        "I checked my character's money and inbox; the gold arrived and is no longer attached to mail.",
        "TOPLEFT",
        page,
        "TOPLEFT",
        264,
        -382,
        450,
        38,
        "GameFontHighlight"
    )
    ui.review_register = createButton(page, "Register payment", 150, 28, "TOPLEFT", page, "TOPLEFT", 238, -444, function()
        local review = getSelectedReview(ui)
        if not review or review.kind ~= "pickup" then
            return
        end
        if not ui.review_ack:GetChecked() then
            ui.controller:SetStatus("Check the money and inbox details before registering this payment.")
            return
        end
        if StaticPopup_Show then
            StaticPopup_Show("GUILD_RAFFLE_MANUAL_CONFIRM", nil, nil, {
                controller = ui.controller,
                receipt_id = review.receipt.id,
            })
        end
    end)
    ui.review_dismiss = createButton(page, "Dismiss attempt", 140, 28, "LEFT", ui.review_register, "RIGHT", 10, 0, function()
        local review = getSelectedReview(ui)
        if not review or not StaticPopup_Show then
            return
        end
        if review.kind == "pickup" then
            StaticPopup_Show("GUILD_RAFFLE_DISMISS", nil, nil, {
                controller = ui.controller,
                receipt_id = review.receipt.id,
            })
        else
            StaticPopup_Show("GUILD_RAFFLE_DISMISS_SENDER", nil, nil, {
                controller = ui.controller,
                review_id = review.sender_review.id,
            })
        end
    end)
    ui.review_sender_match = createButton(page, "Match sender", 150, 28, "TOPLEFT", page, "TOPLEFT", 548, -378, function()
        local review = getSelectedReview(ui)
        if not review or review.kind ~= "sender" then
            return
        end
        local memberName = ui.review_sender_member:GetText()
        if not Core.SafeString(memberName, false) then
            ui.controller:SetStatus("Enter the guild member's full name exactly as shown in the roster.")
            return
        end
        if StaticPopup_Show then
            StaticPopup_Show(
                "GUILD_RAFFLE_MATCH_SENDER",
                review.sender_review.sender or "Unknown sender",
                memberName,
                {
                    controller = ui.controller,
                    review_id = review.sender_review.id,
                    member_name = memberName,
                }
            )
        end
    end)
end

function UI.Initialize(controller)
    if UI.initialized or type(CreateFrame) ~= "function" then
        return
    end
    UI.initialized = true
    nativeOpenAllController = controller
    controller.api.isOpenAllRunning = function()
        return nativeOpenAllRunning
    end
    definePopups()

    local frame = CreateFrame("Frame", "GuildRaffleMailboxFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(780, 675)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    if frame.SetClampedToScreen then
        frame:SetClampedToScreen(true)
    end
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    if frame.TitleText then
        frame.TitleText:SetText("Guild raffle payments")
    end

    local ui = {
        frame = frame,
        controller = controller,
        tabs = {},
        pages = {},
        history_buttons = {},
        review_buttons = {},
    }
    UI.instance = ui
    for _, tab in ipairs(TAB_LABELS) do
        ui.pages[tab.id] = makePage(frame)
    end

    createTabs(ui)
    ui.global_warning = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -63, 610, 18, "GameFontNormalSmall")
    ui.global_status = createLabel(frame, "", "TOPLEFT", frame, "TOPLEFT", 14, -63, 720, 18, "GameFontHighlightSmall")
    ui.global_ack = createButton(frame, "Acknowledge", 130, 20, "TOPRIGHT", frame, "TOPRIGHT", -14, -60, function()
        local ok, reason = controller:AcknowledgeDiscrepancy()
        if not ok then
            controller:SetStatus(reason)
        end
    end)
    ui.global_ack:Hide()

    buildCollectPage(ui)
    buildSetupPage(ui)
    buildActivePage(ui)
    buildHistoryPage(ui)
    buildMailHistoryPage(ui)
    buildReviewPage(ui)

    UI.LoadPresetForm()
    selectTab("collect")
    if type(InCombatLockdown) ~= "function" or not InCombatLockdown() then
        showReloadBackupWindow("")
        UI.reload_backup_frame:Hide()
    end
end

function UI.Toggle()
    if not UI.instance then
        return
    end
    if UI.instance.frame:IsShown() then
        UI.instance.frame:Hide()
    else
        UI.instance.frame:Show()
        UI.Refresh()
    end
end

if type(SLASH_GUILDRAFFLE1) == "nil" then
    SLASH_GUILDRAFFLE1 = "/guildraffle"
    SLASH_GUILDRAFFLE2 = "/raffle"
    SlashCmdList = SlashCmdList or {}
    SlashCmdList.GUILDRAFFLE = function()
        UI.Toggle()
    end
end
