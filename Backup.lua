local ADDON_NAME, ns = ...

local Backup = {}
ns.Backup = Backup

local FORMAT_NAME = "GuildRaffleMailboxBackup"
local FORMAT_VERSION = 1
local MAX_DEPTH = 100

local function quoteString(value)
    return '"' .. string.gsub(value, '[%z\1-\31\\"]', function(character)
        local escapes = {
            ['\\'] = '\\\\',
            ['"'] = '\\"',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
        }
        return escapes[character] or string.format('\\%03d', string.byte(character))
    end) .. '"'
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" then
            error("Backup data contains an unsupported table key.")
        end
        if type(key) == "number" and (key ~= key or key == math.huge or key == -math.huge) then
            error("Backup data contains an invalid numeric key.")
        end
        table.insert(keys, key)
    end
    table.sort(keys, function(left, right)
        if type(left) ~= type(right) then
            return type(left) < type(right)
        end
        return left < right
    end)
    return keys
end

local function encodeValue(value, seen, depth)
    if depth > MAX_DEPTH then
        error("Backup data is nested too deeply.")
    end
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    elseif valueType == "boolean" then
        return value and "true" or "false"
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("Backup data contains an invalid number.")
        end
        return string.format("%.17g", value)
    elseif valueType == "string" then
        return quoteString(value)
    elseif valueType ~= "table" then
        error("Backup data contains an unsupported value.")
    end

    if seen[value] then
        error("Backup data contains a circular reference.")
    end
    seen[value] = true
    local lines = { "{" }
    for _, key in ipairs(sortedKeys(value)) do
        local encodedKey
        if type(key) == "number" then
            encodedKey = "[" .. string.format("%.17g", key) .. "]"
        else
            encodedKey = "[" .. quoteString(key) .. "]"
        end
        table.insert(lines, string.rep(" ", (depth + 1) * 2) .. encodedKey .. " = "
            .. encodeValue(value[key], seen, depth + 1) .. ",")
    end
    table.insert(lines, string.rep(" ", depth * 2) .. "}")
    seen[value] = nil
    return table.concat(lines, "\n")
end

function Backup.Encode(db)
    local ok, result = pcall(function()
        local envelope = {
            format = FORMAT_NAME,
            format_version = FORMAT_VERSION,
            saved_at = type(GetServerTime) == "function" and GetServerTime() or nil,
            data = db,
        }
        return "return " .. encodeValue(envelope, {}, 0)
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

local function parseBackup(text)
    local position = 1
    local length = #text

    local function skipSpace()
        while position <= length and string.match(string.sub(text, position, position), "%s") do
            position = position + 1
        end
    end

    local function expect(token)
        skipSpace()
        if string.sub(text, position, position + #token - 1) ~= token then
            error("Invalid backup syntax near character " .. tostring(position) .. ".")
        end
        position = position + #token
    end

    local parseValue
    local function parseString()
        expect('"')
        local result = {}
        while position <= length do
            local character = string.sub(text, position, position)
            position = position + 1
            if character == '"' then
                return table.concat(result)
            elseif character == "\\" then
                if position > length then
                    error("Incomplete escape in backup string.")
                end
                local escape = string.sub(text, position, position)
                position = position + 1
                local replacements = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["n"] = "\n",
                    ["r"] = "\r",
                    ["t"] = "\t",
                }
                if replacements[escape] then
                    table.insert(result, replacements[escape])
                elseif string.match(escape, "%d") then
                    local digits = escape
                    for _ = 1, 2 do
                        local nextDigit = string.sub(text, position, position)
                        if not string.match(nextDigit, "%d") then
                            break
                        end
                        digits = digits .. nextDigit
                        position = position + 1
                    end
                    local byte = tonumber(digits)
                    if not byte or byte > 255 then
                        error("Invalid byte escape in backup string.")
                    end
                    table.insert(result, string.char(byte))
                else
                    error("Unsupported escape in backup string.")
                end
            else
                table.insert(result, character)
            end
        end
        error("Unterminated string in backup.")
    end

    local function parseTable(depth)
        if depth > MAX_DEPTH then
            error("Backup data is nested too deeply.")
        end
        expect("{")
        local value = {}
        skipSpace()
        while string.sub(text, position, position) ~= "}" do
            expect("[")
            local key = parseValue(depth + 1)
            if type(key) ~= "string" and type(key) ~= "number" then
                error("Invalid key type in backup.")
            end
            expect("]")
            expect("=")
            if value[key] ~= nil then
                error("Duplicate key in backup.")
            end
            value[key] = parseValue(depth + 1)
            skipSpace()
            local separator = string.sub(text, position, position)
            if separator == "," then
                position = position + 1
                skipSpace()
            elseif separator ~= "}" then
                error("Expected a comma or closing brace in backup.")
            end
        end
        expect("}")
        return value
    end

    parseValue = function(depth)
        skipSpace()
        local character = string.sub(text, position, position)
        if character == "{" then
            return parseTable(depth)
        elseif character == '"' then
            return parseString()
        end

        local rest = string.sub(text, position)
        for _, literal in ipairs({ "true", "false", "nil" }) do
            if string.sub(rest, 1, #literal) == literal then
                position = position + #literal
                if literal == "nil" then
                    return nil
                end
                return literal == "true"
            end
        end
        local numberText = string.match(rest, "^-?%d+%.?%d*[eE]?[+-]?%d*")
        local number = numberText and tonumber(numberText)
        if numberText and number then
            position = position + #numberText
            return number
        end
        error("Unsupported value in backup near character " .. tostring(position) .. ".")
    end

    -- The only accepted top-level syntax is the data-only format generated above.
    expect("return")
    local result = parseValue(0)
    skipSpace()
    if position <= length then
        error("Unexpected trailing content in backup.")
    end
    return result
end

local function validateDatabase(db)
    if type(db) ~= "table" then
        return false, "Backup does not contain a database."
    end
    for _, field in ipairs({
        "presets",
        "preset_order",
        "rounds",
        "round_order",
        "receipts",
        "mail_history",
        "mail_history_seen_counts",
    }) do
        if type(db[field]) ~= "table" then
            return false, "Backup is missing required database data: " .. field .. "."
        end
    end
    for id, preset in pairs(db.presets) do
        if type(id) ~= "string" or type(preset) ~= "table" or preset.id ~= id
            or type(preset.name) ~= "string"
            or type(preset.price_copper) ~= "number"
            or preset.price_copper < 1 or preset.price_copper ~= math.floor(preset.price_copper) then
            return false, "Backup contains an invalid ticket-rules preset."
        end
    end
    for id, round in pairs(db.rounds) do
        if type(id) ~= "number" or id < 1 or id ~= math.floor(id)
            or type(round) ~= "table" or round.id ~= id
            or (round.status ~= "active" and round.status ~= "closed")
            or type(round.preset) ~= "table"
            or type(round.preset.price_copper) ~= "number"
            or round.preset.price_copper < 1 then
            return false, "Backup contains an invalid raffle record."
        end
    end
    for id, receipt in pairs(db.receipts) do
        if type(id) ~= "number" or id < 1 or id ~= math.floor(id)
            or type(receipt) ~= "table" or receipt.id ~= id
            or type(receipt.round_id) ~= "number" or not db.rounds[receipt.round_id] then
            return false, "Backup contains an invalid payment record."
        end
    end
    return true
end

function Backup.Decode(text, core)
    if type(text) ~= "string" or text == "" then
        return nil, "Paste a GuildRaffleMailbox full backup first."
    end
    local ok, envelope = pcall(parseBackup, text)
    if not ok then
        return nil, tostring(envelope)
    end
    if type(envelope) ~= "table" or envelope.format ~= FORMAT_NAME
        or envelope.format_version ~= FORMAT_VERSION then
        return nil, "This is not a supported GuildRaffleMailbox backup."
    end
    local db = envelope.data
    local valid, reason = validateDatabase(db)
    if not valid then
        return nil, reason
    end
    db = core.InitializeDB(db)
    local rounds, confirmed, unresolved, unresolvedSenderNames = 0, 0, 0, 0
    for _, round in pairs(db.rounds) do
        if type(round) == "table" then
            rounds = rounds + 1
        end
    end
    for _, receipt in pairs(db.receipts) do
        if type(receipt) == "table" then
            if receipt.status == "confirmed" then
                confirmed = confirmed + 1
            elseif receipt.status == "pending" or receipt.status == "needs_review" then
                unresolved = unresolved + 1
            end
        end
    end
    unresolvedSenderNames = #core.GetSenderReviewCases(db)
    local metadata = {
        exported_at = envelope.saved_at,
        rounds = rounds,
        confirmed_payments = confirmed,
        unresolved_pickups = unresolved,
        unresolved_sender_names = unresolvedSenderNames,
        mail_history = #db.mail_history,
        active_round = db.active_round_id and db.rounds[db.active_round_id] or nil,
    }
    return db, nil, metadata
end
