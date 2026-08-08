-- Roblox Game Server Script for License Trading API
-- Add this Script to ServerScriptService
-- SECURITY NOTE: This script runs on the server, so secrets are not exposed to players.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

-- ============================================================
-- CONFIGURATION
-- ============================================================

local API_BASE_URL = "https://roblox-trading-api.onrender.com"
local Secrets = require(ServerStorage:WaitForChild("Folder"):WaitForChild("Secrets"))

local API_KEY = Secrets.API_KEY
local CLAIM_SECRET = Secrets.CLAIM_SECRET

local UNIVERSE_ID = 9820377522
local GAMEPASS_ID = 1748525718

local TRADE_FEE_PRODUCT_ID = 3612832194 -- Developer Product charged to the requester on confirm

local REQUEST_TIMEOUTS = {
	DEFAULT = 60,
	GET_LICENSES = 120,
}
local MAX_RETRIES = 2

assert(type(API_KEY) == "string" and API_KEY ~= "", "Missing API_KEY")
assert(type(CLAIM_SECRET) == "string" and CLAIM_SECRET ~= "", "Missing CLAIM_SECRET")

if not HttpService.HttpEnabled then
	error("CRITICAL: HttpService is disabled in Game Settings. Enable HTTP requests in Game Settings -> Security -> Enable HTTP Requests")
end

local RATE_COOLDOWNS = {
	SYNC = 5,
	CLAIM = 10,
	TRANSFER = 10,
	EXECUTE_TRADE = 15,
	VERIFY = 5,
	TRADE_HISTORY = 5,
	GET_LICENSES = 2,
}

local REMOTE_SPAM_LIMIT = 0.25
local MAX_LICENSES_PER_TRADE = 50
local OWNERSHIP_CACHE_TTL = 10

local ENDPOINTS = {
	SYNC = "/v1/players/:userId/sync-licenses",
	CLAIM = "/v1/license/claim",
	VERIFY = "/v1/licenses/verify-instance",
	TRANSFER = "/v1/licenses/:licenseId/transfer",
	EXECUTE_TRADE = "/v1/trades/execute",
	TRADE_HISTORY = "/v1/players/:userId/trades",
	GET_LICENSES = "/v1/players/:userId/licenses",
}

local playerCooldowns = {}
local lastRemoteCall = {}
local ownershipCache = {}

-- ============================================================
-- VALIDATION
-- ============================================================

local function validateUUID(uuid)
	return type(uuid) == "string"
		and #uuid == 36
		and uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function validateUserId(userId)
	if type(userId) ~= "number" or userId == 0 or userId ~= math.floor(userId) then
		return false
	end
	if RunService:IsStudio() then
		-- Studio's local multi-client test mode assigns negative UserIds to
		-- simulated players. Only relax the positive-number requirement here,
		-- and only while actually running inside Studio - never on a
		-- published, live server.
		return true
	end
	return userId > 0
end

local function validateUniverseId(universeId)
	return type(universeId) == "number" and universeId > 0 and universeId == math.floor(universeId)
end

local function validateRequestId(requestId)
	if type(requestId) == "string" then
		return #requestId > 0 and #requestId <= 100
	end

	if type(requestId) == "number" then
		return requestId > 0
	end

	return false
end

local function validateSyncResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.createdCount) ~= "number" then return false end
	return true
end

local function validateClaimResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.licenseId) ~= "string" or not validateUUID(data.data.licenseId) then return false end
	return true
end

local function validateVerifyResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.valid) ~= "boolean" then return false end
	return true
end

local function validateTransferResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.tradeId) ~= "string" or not validateUUID(data.data.tradeId) then return false end
	if type(data.data.licenseId) ~= "string" or not validateUUID(data.data.licenseId) then return false end
	if type(data.data.fromUserId) ~= "string" then return false end
	if type(data.data.toUserId) ~= "string" then return false end
	return true
end

local function validateExecuteTradeResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.tradeId) ~= "string" or not validateUUID(data.data.tradeId) then return false end
	if type(data.data.transferredLicenses) ~= "table" then return false end

	for _, transfer in ipairs(data.data.transferredLicenses) do
		if type(transfer) ~= "table" then return false end
		if type(transfer.licenseId) ~= "string" or not validateUUID(transfer.licenseId) then return false end
		if type(transfer.fromUserId) ~= "string" then return false end
		if type(transfer.toUserId) ~= "string" then return false end
	end

	return true
end

local function validateTradeHistoryResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.trades) ~= "table" then return false end
	return true
end

local function validateLicensesResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end

	for _, license in ipairs(data.data) do
		if type(license) ~= "table" then return false end
		if type(license.licenseId) ~= "string" or not validateUUID(license.licenseId) then return false end
		if type(license.licenseTypeId) ~= "string" or not validateUUID(license.licenseTypeId) then return false end
		if type(license.displayName) ~= "string" then return false end
		if type(license.ownerUserId) ~= "string" then return false end
		if type(license.status) ~= "string" then return false end
		if type(license.origin) ~= "string" then return false end
	end

	return true
end

-- ============================================================
-- RATE LIMITING
-- ============================================================

local function allowRemote(player, actionName)
	if not player or not validateUserId(player.UserId) then
		return false
	end

	local now = os.clock()
	if not lastRemoteCall[player.UserId] then
		lastRemoteCall[player.UserId] = {}
	end

	local lastCall = lastRemoteCall[player.UserId][actionName]

	if lastCall and now - lastCall < REMOTE_SPAM_LIMIT then
		return false
	end

	lastRemoteCall[player.UserId][actionName] = now
	return true
end

local function checkRateLimit(player, actionType)
	if not player or not validateUserId(player.UserId) then
		return false, "Invalid player"
	end

	if not playerCooldowns[player.UserId] then
		playerCooldowns[player.UserId] = {}
	end

	local lastRequest = playerCooldowns[player.UserId][actionType]
	local cooldown = RATE_COOLDOWNS[actionType] or 1
	local now = os.clock()

	if lastRequest and now - lastRequest < cooldown then
		return false, "Rate limit exceeded. Please wait " .. math.ceil(cooldown - (now - lastRequest)) .. " seconds."
	end

	playerCooldowns[player.UserId][actionType] = now
	return true
end

local function shouldRetry(statusCode)
	return type(statusCode) ~= "number" or statusCode == 429 or statusCode >= 500
end

-- ============================================================
-- HTTP
-- ============================================================

local function urlEncodeForGsub(value)
	-- string.gsub's replacement-string argument treats "%" as an escape
	-- character (e.g. "%1" refers to a pattern capture group). Roblox's
	-- UrlEncode can produce sequences like "%2D" for "-" (as happens with
	-- negative Studio-test UserIds), and gsub would misread "%2" as a
	-- reference to capture group 2 - which doesn't exist here - and error
	-- with "invalid capture index". Doubling any "%" makes gsub treat it as
	-- a literal percent sign instead.
	local encoded = HttpService:UrlEncode(tostring(value))
	return (encoded:gsub("%%", "%%%%"))
end

local function makeRequest(method, endpoint, data, headers, validator, timeout, skipRetryOnTimeout)
	local url = API_BASE_URL .. endpoint
	local requestData = data and table.clone(data) or {}

	if requestData.licenseId then
		local newUrl = url:gsub(":licenseId", urlEncodeForGsub(requestData.licenseId))
		if newUrl ~= url then
			url = newUrl
			requestData.licenseId = nil
		end
	end

	if requestData.userId then
		local newUrl = url:gsub(":userId", urlEncodeForGsub(requestData.userId))
		if newUrl ~= url then
			url = newUrl
			requestData.userId = nil
		end
	end

	local requestHeaders = {
		["Content-Type"] = "application/json",
	}

	if headers then
		for key, value in pairs(headers) do
			requestHeaders[key] = value
		end
	end

	local function attemptRequest()
		local success, response = pcall(function()
			local options = {
				Url = url,
				Method = method,
				Headers = requestHeaders,
			}

			if method ~= "GET" then
				options.Body = HttpService:JSONEncode(requestData)
			end

			return HttpService:RequestAsync(options)
		end)

		if not success then
			local errorMsg = tostring(response)
			-- Check if it's actually a timeout by inspecting the error message
			local isTimeout = errorMsg:lower():find("timeout") ~= nil
			return nil, isTimeout and nil or "network_error", errorMsg
		end

		local decodeSuccess, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)

		if response.StatusCode >= 200 and response.StatusCode < 300 then
			if not decodeSuccess then
				return nil, response.StatusCode, "JSON decode failed"
			end

			return decoded, response.StatusCode, nil
		end

		if decodeSuccess and type(decoded) == "table" then
			return nil, response.StatusCode, decoded.error or decoded.message or tostring(response.StatusCode)
		end

		return nil, response.StatusCode, tostring(response.StatusCode)
	end

	local lastError = "Unknown error"

	for attempt = 1, MAX_RETRIES + 1 do
		local result, statusCode, errorMessage = attemptRequest()

		if result then
			if validator and not validator(result) then
				return nil, "Invalid response structure"
			end

			return result, nil
		end

		lastError = errorMessage or tostring(statusCode or "network error")

		if skipRetryOnTimeout and statusCode == nil then
			return nil, "Request timed out: " .. lastError
		end

		if not shouldRetry(statusCode) then
			return nil, lastError
		end

		if attempt <= MAX_RETRIES then
			task.wait(2 ^ (attempt - 1))
		end
	end

	return nil, "Request failed after retries: " .. tostring(lastError)
end

-- ============================================================
-- API FUNCTIONS
-- ============================================================

local function checkOwnership(userId, licenseId)
	if not validateUserId(userId) or not validateUUID(licenseId) then
		return nil
	end

	local cacheKey = tostring(userId) .. ":" .. licenseId
	local cached = ownershipCache[cacheKey]
	if cached and os.clock() - cached.timestamp < OWNERSHIP_CACHE_TTL then
		return cached.result
	end

	local data = {
		userId = userId,
		licenseId = licenseId,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, err = makeRequest("POST", ENDPOINTS.VERIFY, data, headers, validateVerifyResponse)

	local ownershipResult
	if not result then
		warn("Ownership check failed for user " .. tostring(userId) .. ", license " .. tostring(licenseId) .. ": " .. tostring(err))
		ownershipResult = nil
	elseif result.data.valid == true then
		ownershipResult = true
	elseif result.data.valid == false then
		ownershipResult = false
	else
		ownershipResult = nil
	end

	ownershipCache[cacheKey] = {
		result = ownershipResult,
		timestamp = os.clock()
	}
	return ownershipResult
end

local function syncLicenses(player)
	if not player or not validateUserId(player.UserId) or not validateUniverseId(UNIVERSE_ID) then
		return { success = false, error = "Invalid user ID or universe ID" }
	end

	local allowed, err = checkRateLimit(player, "SYNC")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		userId = player.UserId,
		universeId = UNIVERSE_ID,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("POST", ENDPOINTS.SYNC, data, headers, validateSyncResponse)

	if result then
		return { success = true, data = result }
	end

	return { success = false, error = requestErr }
end

local function claimLicense(player)
	if not player or not validateUserId(player.UserId) or not validateUniverseId(UNIVERSE_ID) then
		return { success = false, error = "Invalid user ID or universe ID" }
	end

	local ownsPassSuccess, ownsPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS_ID)
	end)

	if not ownsPassSuccess then
		return { success = false, error = "Unable to verify gamepass ownership. Please try again." }
	end

	if not ownsPass then
		return { success = false, error = "You do not own the required gamepass" }
	end

	local allowed, err = checkRateLimit(player, "CLAIM")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		userId = player.UserId,
		gamepassId = GAMEPASS_ID,
		universeId = UNIVERSE_ID,
		secret = CLAIM_SECRET,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("POST", ENDPOINTS.CLAIM, data, headers, validateClaimResponse)

	if result then
		return { success = true, data = result }
	end

	return { success = false, error = requestErr }
end

local function verifyLicense(player, licenseId)
	if not player or not validateUserId(player.UserId) or not validateUUID(licenseId) then
		return { success = false, error = "Invalid user ID or license ID" }
	end

	local allowed, err = checkRateLimit(player, "VERIFY")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		userId = player.UserId,
		licenseId = licenseId,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("POST", ENDPOINTS.VERIFY, data, headers, validateVerifyResponse)

	if result then
		return { success = true, data = result }
	end

	return { success = false, error = requestErr }
end

local function transferLicense(player, licenseId, toUserId)
	if not player or not validateUserId(player.UserId) or not validateUserId(toUserId) then
		return { success = false, error = "Invalid user ID" }
	end

	if player.UserId == toUserId then
		return { success = false, error = "Cannot transfer to yourself" }
	end

	if not validateUUID(licenseId) or not validateUniverseId(UNIVERSE_ID) then
		return { success = false, error = "Invalid license ID or universe ID" }
	end

	local ownership = checkOwnership(player.UserId, licenseId)
	if ownership == false then
		return { success = false, error = "You do not own this license" }
	elseif ownership == nil then
		return { success = false, error = "Unable to verify ownership. Please try again." }
	end

	local userExistsSuccess = pcall(function()
		Players:GetNameFromUserIdAsync(toUserId)
	end)

	if not userExistsSuccess then
		return { success = false, error = "Unable to verify recipient user. Please try again." }
	end

	local allowed, err = checkRateLimit(player, "TRANSFER")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		licenseId = licenseId,
		fromUserId = player.UserId,
		toUserId = toUserId,
		universeId = UNIVERSE_ID,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("POST", ENDPOINTS.TRANSFER, data, headers, validateTransferResponse)

	if result then
		warn(string.format("[AUDIT] Single Transfer: %d -> %d (License: %s) - Success", player.UserId, toUserId, licenseId))
		return { success = true, data = result }
	end

	warn(string.format("[AUDIT] Single Transfer: %d -> %d (License: %s) - Failed: %s", player.UserId, toUserId, licenseId, tostring(requestErr)))
	return { success = false, error = requestErr }
end

local function executeTrade(player, fromLicenses, toUserId, toLicenses)
	if not player or not validateUserId(player.UserId) or not validateUserId(toUserId) then
		return { success = false, error = "Invalid user ID" }
	end

	if player.UserId == toUserId then
		return { success = false, error = "Cannot trade with yourself" }
	end

	if not validateUniverseId(UNIVERSE_ID) then
		return { success = false, error = "Invalid universe ID" }
	end

	if type(fromLicenses) ~= "table" then
		return { success = false, error = "fromLicenses must be a table" }
	end

	if type(toLicenses) ~= "table" then
		toLicenses = {}
	end

	if #fromLicenses == 0 and #toLicenses == 0 then
		return { success = false, error = "At least one license must be offered" }
	end

	if #fromLicenses + #toLicenses > MAX_LICENSES_PER_TRADE then
		return { success = false, error = "Too many licenses in trade (max " .. MAX_LICENSES_PER_TRADE .. ")" }
	end

	-- Validate uniqueness of fromLicenses
	local seenFrom = {}
	for _, licenseId in ipairs(fromLicenses) do
		if type(licenseId) ~= "string" or not validateUUID(licenseId) then
			return { success = false, error = "Invalid license ID in fromLicenses" }
		end
		if seenFrom[licenseId] then
			return { success = false, error = "Duplicate license ID in fromLicenses" }
		end
		seenFrom[licenseId] = true
	end

	-- Validate uniqueness of toLicenses
	local seenTo = {}
	for _, licenseId in ipairs(toLicenses) do
		if type(licenseId) ~= "string" or not validateUUID(licenseId) then
			return { success = false, error = "Invalid license ID in toLicenses" }
		end
		if seenTo[licenseId] then
			return { success = false, error = "Duplicate license ID in toLicenses" }
		end
		seenTo[licenseId] = true
	end

	local userExistsSuccess = pcall(function()
		Players:GetNameFromUserIdAsync(toUserId)
	end)

	if not userExistsSuccess then
		return { success = false, error = "Unable to verify recipient user. Please try again." }
	end

	local allowed, err = checkRateLimit(player, "EXECUTE_TRADE")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		fromUserId = player.UserId,
		toUserId = toUserId,
		universeId = UNIVERSE_ID,
		fromLicenses = fromLicenses,
		toLicenses = toLicenses,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("POST", ENDPOINTS.EXECUTE_TRADE, data, headers, validateExecuteTradeResponse)

	if result then
		warn(string.format("[AUDIT] Atomic Trade: %d <-> %d - Success (%d licenses)", player.UserId, toUserId, #fromLicenses + #toLicenses))
		return { success = true, data = result }
	end

	warn(string.format("[AUDIT] Atomic Trade: %d <-> %d - Failed: %s", player.UserId, toUserId, tostring(requestErr)))
	return { success = false, error = requestErr }
end

local function getTradeHistory(player)
	if not player or not validateUserId(player.UserId) then
		return { success = false, error = "Invalid user ID" }
	end

	local allowed, err = checkRateLimit(player, "TRADE_HISTORY")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		userId = player.UserId,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("GET", ENDPOINTS.TRADE_HISTORY, data, headers, validateTradeHistoryResponse, nil, true)

	if result then
		return { success = true, data = result }
	end

	return { success = false, error = requestErr }
end

local function getPlayerLicenses(player)
	if not player or not validateUserId(player.UserId) then
		return { success = false, error = "Invalid user ID" }
	end

	local allowed, err = checkRateLimit(player, "GET_LICENSES")
	if not allowed then
		return { success = false, error = err }
	end

	local data = {
		userId = player.UserId,
	}

	local headers = {
		["Authorization"] = "Bearer " .. API_KEY,
	}

	local result, requestErr = makeRequest("GET", ENDPOINTS.GET_LICENSES, data, headers, validateLicensesResponse, REQUEST_TIMEOUTS.GET_LICENSES, true)

	if result then
		return { success = true, data = result }
	end

	return { success = false, error = requestErr }
end

local function transformLicenseForClient(license)
	return {
		id = license.licenseId,
		name = license.displayName,
		status = license.status,
		licenseTypeId = license.licenseTypeId,
		ownerUserId = license.ownerUserId,
		origin = license.origin,
		createdAt = license.createdAt,
	}
end

-- ============================================================
-- REMOTES
-- ============================================================

local GameRemotesFolder = ReplicatedStorage:FindFirstChild("GameRemotes")
if not GameRemotesFolder then
	GameRemotesFolder = Instance.new("Folder")
	GameRemotesFolder.Name = "GameRemotes"
	GameRemotesFolder.Parent = ReplicatedStorage
end

local function getOrCreateRemoteEvent(name)
	local existing = GameRemotesFolder:FindFirstChild(name)

	if existing then
		if existing:IsA("RemoteEvent") then
			return existing
		end

		warn("Destroying non-RemoteEvent instance '" .. name .. "' in GameRemotes folder")
		existing:Destroy()
	end

	local newEvent = Instance.new("RemoteEvent")
	newEvent.Name = name
	newEvent.Parent = GameRemotesFolder
	return newEvent
end

local SendTradeRequestRE = getOrCreateRemoteEvent("SendTradeRequest")
local TradeRequestResponseRE = getOrCreateRemoteEvent("TradeRequestResponse")
local TradeStartedRE = getOrCreateRemoteEvent("TradeStarted")
local TradeUpdateRE = getOrCreateRemoteEvent("TradeUpdate")
local TradeConfirmRE = getOrCreateRemoteEvent("TradeConfirm")
local TradeCancelledRE = getOrCreateRemoteEvent("TradeCancelled")
local GetPlayerLicensesRE = getOrCreateRemoteEvent("GetPlayerLicenses")

-- ============================================================
-- TRADE STATE
-- ============================================================

local activeTrades = {}
local tradeRequests = {}
local playerLicenseCache = {} -- [userId] = { [licenseId] = { id, name, status } }
local pendingPayments = {} -- [userId] = tradeId (awaiting confirm-fee purchase for that trade)

local function generateTradeId()
	return HttpService:GenerateGUID(false)
end

local function generateRequestId()
	return HttpService:GenerateGUID(false)
end

local function getPlayer(userId)
	if not validateUserId(userId) then
		return nil
	end

	return Players:GetPlayerByUserId(userId)
end

local function safeFireClient(player, remoteEvent, ...)
	if player and player.Parent == Players then
		remoteEvent:FireClient(player, ...)
	end
end

local function getLicenseDetails(licenseIds, ownerUserId)
	local licenses = {}
	local cache = playerLicenseCache[ownerUserId]

	for _, id in ipairs(licenseIds) do
		local cached = cache and cache[id]
		if cached then
			table.insert(licenses, { id = id, name = cached.name })
		else
			warn("[LicenseTradingAPI] No cached license data for " .. tostring(ownerUserId) .. "/" .. tostring(id))
			table.insert(licenses, { id = id, name = "License " .. string.sub(id, 1, 8) })
		end
	end

	return licenses
end

local function removeLicenseFromOffer(offer, licenseId)
	for i, id in ipairs(offer) do
		if id == licenseId then
			table.remove(offer, i)
			return true
		end
	end

	return false
end

local function offerContains(offer, licenseId)
	for _, id in ipairs(offer) do
		if id == licenseId then
			return true
		end
	end

	return false
end

local function clearTrade(trade)
	if not trade then
		return
	end

	activeTrades[trade.id] = nil
	activeTrades[trade.playerA] = nil
	activeTrades[trade.playerB] = nil
	pendingPayments[trade.playerA] = nil
end

local function buildUpdateForPlayer(trade, playerUserId)
	local isPlayerA = playerUserId == trade.playerA

	return {
		tradeId = trade.id,
		myOfferedLicenses = getLicenseDetails(
			isPlayerA and trade.playerAOffer or trade.playerBOffer,
			playerUserId
		),
		theirOfferedLicenses = getLicenseDetails(
			isPlayerA and trade.playerBOffer or trade.playerAOffer,
			isPlayerA and trade.playerB or trade.playerA
		),
		myReady = isPlayerA and trade.playerAReady or trade.playerBReady,
		theirReady = isPlayerA and trade.playerBReady or trade.playerAReady,
		myConfirmed = isPlayerA and trade.playerAConfirmed or trade.playerBConfirmed,
		theirConfirmed = isPlayerA and trade.playerBConfirmed or trade.playerAConfirmed,
	}
end

local function broadcastTradeUpdate(trade)
	local playerA = getPlayer(trade.playerA)
	local playerB = getPlayer(trade.playerB)

	safeFireClient(playerA, TradeUpdateRE, buildUpdateForPlayer(trade, trade.playerA))
	safeFireClient(playerB, TradeUpdateRE, buildUpdateForPlayer(trade, trade.playerB))
end

local function cancelTrade(trade, reason)
	if not trade then
		return
	end

	if trade.cancelled then
		return
	end

	trade.cancelled = true

	local playerA = getPlayer(trade.playerA)
	local playerB = getPlayer(trade.playerB)

	clearTrade(trade)

	safeFireClient(playerA, TradeCancelledRE, { reason = reason or "cancelled" })
	safeFireClient(playerB, TradeCancelledRE, { reason = reason or "cancelled" })
end

-- ============================================================
-- CONFIRM PROCESSING (shared by TradeConfirmRE and ProcessReceipt)
-- ============================================================

local function processConfirm(trade, isPlayerA)
	if isPlayerA then
		trade.playerAConfirmed = true
	else
		trade.playerBConfirmed = true
	end

	if not trade.playerAConfirmed or not trade.playerBConfirmed then
		broadcastTradeUpdate(trade)
		return
	end

	local playerA = Players:GetPlayerByUserId(trade.playerA)
	local playerB = Players:GetPlayerByUserId(trade.playerB)

	if not playerA or not playerB then
		cancelTrade(trade, "player_left")
		return
	end

	-- Re-verify ownership before executing trade to prevent race conditions
	for _, id in ipairs(trade.playerAOffer) do
		if checkOwnership(trade.playerA, id) ~= true then
			cancelTrade(trade, "ownership_changed")
			return
		end
	end

	for _, id in ipairs(trade.playerBOffer) do
		if checkOwnership(trade.playerB, id) ~= true then
			cancelTrade(trade, "ownership_changed")
			return
		end
	end

	local result = executeTrade(playerA, trade.playerAOffer, trade.playerB, trade.playerBOffer)

	if not result.success then
		cancelTrade(trade, "validation_failed")
		return
	end

	clearTrade(trade)

	local receivedByA = {}
	local receivedByB = {}

	for _, transfer in ipairs(result.data.data.transferredLicenses) do
		local senderCache = playerLicenseCache[tonumber(transfer.fromUserId)]
		local cached = senderCache and senderCache[transfer.licenseId]
		local name = cached and cached.name or ("License " .. string.sub(transfer.licenseId, 1, 8))

		if transfer.toUserId == tostring(trade.playerA) then
			table.insert(receivedByA, {
				id = transfer.licenseId,
				name = name,
			})
		elseif transfer.toUserId == tostring(trade.playerB) then
			table.insert(receivedByB, {
				id = transfer.licenseId,
				name = name,
			})
		end
	end

	safeFireClient(playerA, TradeUpdateRE, {
		tradeId = trade.id,
		action = "Completed",
		receivedLicenses = receivedByA,
	})

	safeFireClient(playerB, TradeUpdateRE, {
		tradeId = trade.id,
		action = "Completed",
		receivedLicenses = receivedByB,
	})
end

-- ============================================================
-- TRADE REQUEST HANDLER
-- ============================================================

SendTradeRequestRE.OnServerEvent:Connect(function(player, data)
	print("[DEBUG] Server received SendTradeRequest from", player.Name, "targeting", data and data.targetUserId)

	if not allowRemote(player, "SendTradeRequest") then
		print("[DEBUG] Blocked: allowRemote returned false (invalid player UserId OR rate limited)")
		return
	end

	if type(data) ~= "table" or not validateUserId(data.targetUserId) then
		print("[DEBUG] Blocked: invalid data or targetUserId")
		return
	end

	if data.targetUserId == player.UserId then
		print("[DEBUG] Blocked: targeting self")
		return
	end

	if activeTrades[player.UserId] then
		print("[DEBUG] Blocked: sender already has an active trade:", activeTrades[player.UserId])
		return
	end

	local targetPlayer = Players:GetPlayerByUserId(data.targetUserId)
	if not targetPlayer then
		print("[DEBUG] Blocked: target player not found (not in server?)")
		return
	end

	if activeTrades[data.targetUserId] then
		print("[DEBUG] Blocked: target already has an active trade")
		safeFireClient(player, TradeRequestResponseRE, {
			accepted = false,
			reason = "target_in_trade",
			targetName = targetPlayer.Name,
		})
		return
	end

	local requestId = generateRequestId()

	tradeRequests[requestId] = {
		requesterId = player.UserId,
		requesterName = player.Name,
		targetId = data.targetUserId,
		targetName = targetPlayer.Name,
		timestamp = os.clock(),
	}

	safeFireClient(targetPlayer, SendTradeRequestRE, {
		requestId = requestId,
		requesterId = player.UserId,
		requesterName = player.Name,
	})
	print("[DEBUG] Server sent SendTradeRequest to target:", targetPlayer.Name)

	task.delay(30, function()
		local request = tradeRequests[requestId]
		if not request then
			return
		end

		tradeRequests[requestId] = nil

		local requester = Players:GetPlayerByUserId(request.requesterId)
		safeFireClient(requester, TradeRequestResponseRE, {
			accepted = false,
			reason = "expired",
			targetName = request.targetName,
		})
	end)
end)

-- ============================================================
-- TRADE REQUEST RESPONSE HANDLER
-- ============================================================

TradeRequestResponseRE.OnServerEvent:Connect(function(player, data)
	if not allowRemote(player, "TradeRequestResponse") then
		return
	end

	if type(data) ~= "table" or type(data.requestId) ~= "string" or type(data.accepted) ~= "boolean" then
		return
	end

	local request = tradeRequests[data.requestId]
	if not request then
		return
	end

	if player.UserId ~= request.targetId then
		return
	end

	local requester = Players:GetPlayerByUserId(request.requesterId)
	if not requester then
		tradeRequests[data.requestId] = nil
		return
	end

	if data.accepted then
		if activeTrades[request.requesterId] or activeTrades[request.targetId] then
			safeFireClient(requester, TradeRequestResponseRE, {
				accepted = false,
				reason = "busy",
				targetName = player.Name,
			})

			tradeRequests[data.requestId] = nil
			return
		end

		local tradeId = generateTradeId()

		activeTrades[tradeId] = {
			id = tradeId,
			playerA = request.requesterId,
			playerAName = request.requesterName,
			playerB = request.targetId,
			playerBName = request.targetName,
			playerAOffer = {},
			playerBOffer = {},
			playerAReady = false,
			playerBReady = false,
			playerAConfirmed = false,
			playerBConfirmed = false,
			playerAPaid = false,
			startedAt = os.clock(),
		}

		activeTrades[request.requesterId] = tradeId
		activeTrades[request.targetId] = tradeId

		safeFireClient(requester, TradeStartedRE, {
			tradeId = tradeId,
			partnerName = request.targetName,
			partnerId = request.targetId,
			isSender = true,
		})

		safeFireClient(player, TradeStartedRE, {
			tradeId = tradeId,
			partnerName = request.requesterName,
			partnerId = request.requesterId,
			isSender = false,
		})
	else
		safeFireClient(requester, TradeRequestResponseRE, {
			accepted = false,
			reason = "declined",
			targetName = player.Name,
		})
	end

	tradeRequests[data.requestId] = nil
end)

-- ============================================================
-- TRADE UPDATE HANDLER
-- ============================================================

TradeUpdateRE.OnServerEvent:Connect(function(player, data)
	if not allowRemote(player, "TradeUpdate") then
		return
	end

	if type(data) ~= "table" or type(data.tradeId) ~= "string" or type(data.action) ~= "string" then
		return
	end

	local trade = activeTrades[data.tradeId]
	if not trade then
		return
	end

	local isPlayerA = player.UserId == trade.playerA
	local isPlayerB = player.UserId == trade.playerB

	if not isPlayerA and not isPlayerB then
		return
	end

	if activeTrades[player.UserId] ~= data.tradeId then
		return
	end

	if data.action == "AddLicense" then
		local licenseId = data.licenseId
		if not validateUUID(licenseId) then
			return
		end

		local offer = isPlayerA and trade.playerAOffer or trade.playerBOffer
		if offerContains(offer, licenseId) then
			return
		end

		if #offer >= MAX_LICENSES_PER_TRADE then
			return
		end

		local ownership = checkOwnership(player.UserId, licenseId)
		if ownership ~= true then
			return
		end

		table.insert(offer, licenseId)

		trade.playerAReady = false
		trade.playerBReady = false
		trade.playerAConfirmed = false
		trade.playerBConfirmed = false
	elseif data.action == "RemoveLicense" then
		local licenseId = data.licenseId
		if not validateUUID(licenseId) then
			return
		end

		local offer = isPlayerA and trade.playerAOffer or trade.playerBOffer
		local removed = removeLicenseFromOffer(offer, licenseId)

		if removed then
			trade.playerAReady = false
			trade.playerBReady = false
			trade.playerAConfirmed = false
			trade.playerBConfirmed = false
		end
	elseif data.action == "Ready" then
		if type(data.ready) ~= "boolean" then
			return
		end

		-- Reject un-ready once either side has confirmed - confirmation locks the trade
		if not data.ready and (trade.playerAConfirmed or trade.playerBConfirmed) then
			safeFireClient(player, TradeUpdateRE, {
				tradeId = trade.id,
				action = "ActionRejected",
				reason = "trade_locked",
			})
			return
		end

		if isPlayerA then
			trade.playerAReady = data.ready
			trade.playerAConfirmed = false
		else
			trade.playerBReady = data.ready
			trade.playerBConfirmed = false
		end
	elseif data.action == "Cancel" then
		cancelTrade(trade, "cancelled")
		return
	else
		return
	end

	broadcastTradeUpdate(trade)
end)

-- ============================================================
-- TRADE CONFIRM HANDLER
-- ============================================================

TradeConfirmRE.OnServerEvent:Connect(function(player, data)
	if not allowRemote(player, "TradeConfirm") then
		return
	end

	if type(data) ~= "table" or type(data.tradeId) ~= "string" then
		return
	end

	local trade = activeTrades[data.tradeId]
	if not trade then
		return
	end

	local isPlayerA = player.UserId == trade.playerA
	local isPlayerB = player.UserId == trade.playerB

	if not isPlayerA and not isPlayerB then
		return
	end

	if activeTrades[player.UserId] ~= data.tradeId then
		return
	end

	if not trade.playerAReady or not trade.playerBReady then
		return
	end

	if #trade.playerAOffer == 0 and #trade.playerBOffer == 0 then
		return
	end

	-- The requester (playerA) must pay the confirmation fee before their
	-- confirm is applied. playerB's confirm is unaffected by this gate.
	if isPlayerA and not trade.playerAPaid then
		pendingPayments[player.UserId] = trade.id
		safeFireClient(player, TradeUpdateRE, {
			tradeId = trade.id,
			action = "ActionRejected",
			reason = "payment_required",
		})
		MarketplaceService:PromptProductPurchase(player, TRADE_FEE_PRODUCT_ID)
		return
	end

	processConfirm(trade, isPlayerA)
end)

-- ============================================================
-- PROCESS RECEIPT (Developer Product purchase completion)
-- ============================================================

MarketplaceService.ProcessReceipt = function(receiptInfo)
	if receiptInfo.ProductId ~= TRADE_FEE_PRODUCT_ID then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local userId = receiptInfo.PlayerId
	local tradeId = pendingPayments[userId]
	local trade = tradeId and activeTrades[tradeId]

	if not trade or trade.playerA ~= userId then
		-- No matching trade anymore (cancelled mid-purchase, server
		-- restarted, etc). Grant anyway so Roblox stops retrying - the fee
		-- isn't refundable and there's no trade left to apply it to.
		warn("[LicenseTradingAPI] ProcessReceipt: no active trade for user "
			.. tostring(userId) .. " - granting with no trade effect")
		pendingPayments[userId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	trade.playerAPaid = true
	pendingPayments[userId] = nil
	processConfirm(trade, true)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ============================================================
-- GET PLAYER LICENSES HANDLER
-- ============================================================

GetPlayerLicensesRE.OnServerEvent:Connect(function(player, requestId)
	if not allowRemote(player, "GetPlayerLicenses") then
		return
	end

	if not validateRequestId(requestId) then
		safeFireClient(player, GetPlayerLicensesRE, requestId, {
			success = false,
			error = "Invalid request ID",
		})
		return
	end

	local result = getPlayerLicenses(player)

	if result.success and result.data and result.data.data then
		local transformedLicenses = {}
		local cache = {}

		for _, license in ipairs(result.data.data) do
			local transformed = transformLicenseForClient(license)
			table.insert(transformedLicenses, transformed)
			cache[transformed.id] = transformed
		end

		playerLicenseCache[player.UserId] = cache

		safeFireClient(player, GetPlayerLicensesRE, requestId, {
			success = true,
			data = {
				licenses = transformedLicenses,
			},
		})
	else
		safeFireClient(player, GetPlayerLicensesRE, requestId, result)
	end
end)

-- ============================================================
-- PLAYER CLEANUP
-- ============================================================

Players.PlayerRemoving:Connect(function(player)
	playerCooldowns[player.UserId] = nil
	lastRemoteCall[player.UserId] = nil
	playerLicenseCache[player.UserId] = nil
	pendingPayments[player.UserId] = nil

	for requestId, request in pairs(tradeRequests) do
		if request.requesterId == player.UserId or request.targetId == player.UserId then
			tradeRequests[requestId] = nil
		end
	end

	local tradeId = activeTrades[player.UserId]
	if tradeId and activeTrades[tradeId] then
		local trade = activeTrades[tradeId]
		local otherPlayerId = player.UserId == trade.playerA and trade.playerB or trade.playerA
		local otherPlayer = Players:GetPlayerByUserId(otherPlayerId)

		clearTrade(trade)

		safeFireClient(otherPlayer, TradeCancelledRE, {
			reason = "player_left",
		})
	end
end)

print("License Trading API integration loaded for universe " .. tostring(UNIVERSE_ID))
print("Trade system with GameRemotes folder structure loaded")
