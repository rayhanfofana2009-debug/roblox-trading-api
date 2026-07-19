-- Claim licenses based on gamepass ownership
-- Uses MarketplaceService:UserOwnsGamePassAsync to verify ownership
-- Calls backend claim endpoint to create/retrieve licenses
-- Caches licenses for gameplay scripts
--
-- Flow: Player joins → Check gamepass ownership → Claim license → Cache → Gameplay reads cache only
--
-- Gameplay scripts check ownership via:
--   local LicenseCache = require(game.ServerStorage.LicenseCache)
--   LicenseCache.checkOwnership(userId, licenseId)  --> true/false/nil

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Secrets = require(game.ServerStorage.secrets.secrets)
local LicenseCache = require(game.ServerStorage.LicenseCache)

local API_KEY = Secrets.API_KEY
local CLAIM_SECRET = Secrets.CLAIM_SECRET
local UNIVERSE_ID = 3779887885
local GAMEPASS_ID = 1748525718
local MAX_RETRIES = 2

assert(type(API_KEY) == "string" and API_KEY ~= "", "Missing API_KEY")
assert(type(CLAIM_SECRET) == "string" and CLAIM_SECRET ~= "", "Missing CLAIM_SECRET")
assert(type(UNIVERSE_ID) == "number" and UNIVERSE_ID > 0 and UNIVERSE_ID == math.floor(UNIVERSE_ID), "Invalid UNIVERSE_ID")

if not HttpService.HttpEnabled then
	error("CRITICAL: HttpService is disabled. Enable HTTP Requests in Game Settings → Security")
end

local API_BASE_URL = "https://roblox-trading-api.onrender.com"

local ENDPOINTS = {
	CLAIM = "/v1/license/claim",
	GET_LICENSES = "/v1/players/:userId/licenses",
}

-- Test if Roblox can reach external APIs
task.spawn(function()
	local success, result = pcall(function()
		return HttpService:RequestAsync({
			Url = "https://api.github.com",
			Method = "GET",
		})
	end)
	if success and type(result) == "table" and result.StatusCode then
		print("External API test SUCCESS - Roblox can reach GitHub API (Status:", result.StatusCode, ")")
	else
		print("External API test FAILED - Roblox cannot reach external APIs:", tostring(result))
	end
end)


-- Validation

local function validateUUID(uuid)
	return type(uuid) == "string" and #uuid == 36 and uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
end

local function validateClaimResponse(data)
	if type(data) ~= "table" then return false end
	if type(data.data) ~= "table" then return false end
	if type(data.data.success) ~= "boolean" then return false end
	if type(data.data.licenseId) ~= "string" or not validateUUID(data.data.licenseId) then return false end
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

-- HTTP with retry (handles Render.com cold starts)

local function shouldRetry(statusCode)
	return type(statusCode) ~= "number" or statusCode == 429 or statusCode >= 500
end

local function isTimeoutError(errorMsg)
	return type(errorMsg) == "string" and errorMsg:lower():find("timeout") ~= nil
end

local function makeRequest(method, endpoint, data, headers, validator)
	local url = API_BASE_URL .. endpoint
	local requestData = data and table.clone(data) or {}

	if url:find(":userId") and requestData.userId then
		url = url:gsub(":userId", HttpService:UrlEncode(tostring(requestData.userId)))
		requestData.userId = nil
	end

	local requestHeaders = { ["Content-Type"] = "application/json" }
	if headers then
		for key, value in pairs(headers) do
			requestHeaders[key] = value
		end
	end

	local lastError
	for attempt = 1, MAX_RETRIES + 1 do
		print("REQUEST:", method, url)
		print("HEADERS:")
		for k, v in pairs(requestHeaders) do
			if k:lower() == "authorization" then
				print(k, "Bearer ********")
			else
				print(k, v)
			end
		end
		local success, response = pcall(function()
			local options = {
				Url = url,
				Method = method,
				Headers = requestHeaders,
			}
			if method ~= "GET" then
				print("BODY TABLE:")
				for k,v in pairs(requestData) do
					if k:lower() == "secret" then
						print(k, "********")
					else
						print(k, v, typeof(v))
					end
				end
				local logData = table.clone(requestData)
				if logData.secret then
					logData.secret = "********"
				end
				print("JSON:")
				print(HttpService:JSONEncode(logData))
				options.Body = HttpService:JSONEncode(requestData)
			end
			return HttpService:RequestAsync(options)
		end)

		print("SUCCESS:", success)
		if success then
			print("STATUS:", response.StatusCode)
		else
			print("ERROR:", tostring(response))
		end

		if not success then
			local errorMsg = tostring(response)
			lastError = isTimeoutError(errorMsg) and "Request timed out" or errorMsg
			lastStatusCode = nil
			if attempt <= MAX_RETRIES then
				task.wait(2 ^ (attempt - 1))
			end
			continue
		end

		if response.StatusCode >= 200 and response.StatusCode < 300 then
			local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
			if decodeOk then
				if validator and not validator(decoded) then
					return nil, "Invalid response structure"
				end
				return decoded
			end
			return nil, "JSON decode failed"
		else
			local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
			lastError = (decodeOk and decoded and decoded.error) and decoded.error or tostring(response.StatusCode)
			lastStatusCode = response.StatusCode
			if not shouldRetry(response.StatusCode) then
				return nil, lastError
			end
			if attempt <= MAX_RETRIES then
				task.wait(2 ^ (attempt - 1))
			end
		end
	end

	return nil, "Request failed after retries: " .. tostring(lastError)
end

-- API calls

local function claimLicense(player)
	local data = { 
		userId = player.UserId, 
		gamepassId = GAMEPASS_ID, 
		universeId = UNIVERSE_ID,
		secret = CLAIM_SECRET
	}
	local headers = { ["Authorization"] = "Bearer " .. API_KEY }
	return makeRequest("POST", ENDPOINTS.CLAIM, data, headers, validateClaimResponse)
end

local function fetchLicenses(player)
	local data = { userId = player.UserId }
	local headers = { ["Authorization"] = "Bearer " .. API_KEY }
	return makeRequest("GET", ENDPOINTS.GET_LICENSES, data, headers, validateLicensesResponse)
end

-- Background retry after initial failure
local function scheduleBackgroundRetry(player, retryCount)
	if not player or not player.Parent then
		return
	end

	local userId = player.UserId
	local delay = 300 * (2 ^ ((retryCount or 1) - 1))  -- 5 minutes, doubling each retry (300, 600, 1200, 2400...)

	task.spawn(function()
		task.wait(delay)
		
		-- Check if player is still in server
		if not player or not player.Parent then
			return
		end

		print("Background retry for " .. player.Name .. " (attempt " .. tostring(retryCount or 1) .. ")")
		
		-- Check gamepass ownership
		local success, ownsGamepass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS_ID)
		end)

		if not success then
			warn("Ownership check failed")
			return
		end

		if not ownsGamepass then
			print("Player does not own gamepass, skipping claim")
			return
		end
		
		local claimResult, claimErr = claimLicense(player)
		if not claimResult then
			warn("Background claim failed for " .. player.Name .. ": " .. tostring(claimErr))
			-- Schedule another retry if this wasn't the last attempt
			if (retryCount or 1) < 3 then
				scheduleBackgroundRetry(player, (retryCount or 1) + 1)
			end
			return
		end

		print("Background claim succeeded for " .. player.Name)

		local licensesResult, licensesErr = fetchLicenses(player)
		if not licensesResult then
			warn("Background fetch failed for " .. player.Name .. ": " .. tostring(licensesErr))
			-- Schedule another retry if this wasn't the last attempt
			if (retryCount or 1) < 3 then
				scheduleBackgroundRetry(player, (retryCount or 1) + 1)
			end
			return
		end

		if licensesResult.data then
			LicenseCache.remove(userId)
			LicenseCache.set(userId, licensesResult.data)
			LicenseCache.setLastSync(userId, os.time())
			print("Background cache updated for " .. player.Name .. ": " .. #licensesResult.data .. " licenses")
		end
	end)
end

-- Player join: check ownership → claim → fetch → cache

local CLAIM_RETRIES = 3
local CLAIM_RETRY_DELAYS = {10, 30, 60}  -- seconds between retries
local FETCH_RETRIES = 3
local FETCH_RETRY_DELAYS = {5, 15, 30}  -- seconds between retries

local function onPlayerAdded(player)
	task.spawn(function()
		-- Step 1: Check gamepass ownership
		local ownsGamepass, ownershipErr = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, GAMEPASS_ID)
		end)
		
		if not ownsGamepass then
			print("Player does not own gamepass " .. GAMEPASS_ID .. ", skipping license claim")
			if ownershipErr then
				warn("Ownership check error: " .. tostring(ownershipErr))
			end
			return
		end
		
		print("Player owns gamepass " .. GAMEPASS_ID .. ", claiming license")
		
		-- Step 2: Claim license (with retries for API outages)
		local claimResult, claimErr
		for attempt = 1, CLAIM_RETRIES + 1 do
			-- Check if player left during retry wait
			if not player or not player.Parent then
				return
			end
			
			claimResult, claimErr = claimLicense(player)
			if claimResult then break end
			
			if attempt <= CLAIM_RETRIES then
				if isTimeoutError(claimErr) then
					warn("Claim attempt " .. attempt .. " timed out for " .. player.Name .. ", retrying in " .. CLAIM_RETRY_DELAYS[attempt] .. "s")
				else
					warn("Claim attempt " .. attempt .. " failed for " .. player.Name .. ", retrying in " .. CLAIM_RETRY_DELAYS[attempt] .. "s: " .. tostring(claimErr))
				end
				
				if player.Parent then
					task.wait(CLAIM_RETRY_DELAYS[attempt])
				end
			else
				if isTimeoutError(claimErr) then
					warn("Claim attempt " .. attempt .. " timed out for " .. player.Name .. " (final attempt)")
				else
					warn("Claim attempt " .. attempt .. " failed for " .. player.Name .. " (final attempt): " .. tostring(claimErr))
				end
			end
		end

		if not claimResult then
			warn("License claim failed for " .. player.Name .. " after " .. CLAIM_RETRIES .. " retries: " .. tostring(claimErr))
			-- Schedule background retry if player is still in server
			if player and player.Parent then
				scheduleBackgroundRetry(player, 1)
			end
			return
		end

		print("License claimed for " .. player.Name)

		-- Step 3: Fetch licenses (with retries for cold starts)
		local licensesResult, licensesErr
		for attempt = 1, FETCH_RETRIES + 1 do
			-- Check if player left during retry wait
			if not player or not player.Parent then
				return
			end
			
			licensesResult, licensesErr = fetchLicenses(player)
			if licensesResult then break end
			
			if attempt <= FETCH_RETRIES then
				if isTimeoutError(licensesErr) then
					warn("Fetch attempt " .. attempt .. " timed out for " .. player.Name .. ", retrying in " .. FETCH_RETRY_DELAYS[attempt] .. "s")
				else
					warn("Fetch attempt " .. attempt .. " failed for " .. player.Name .. ", retrying in " .. FETCH_RETRY_DELAYS[attempt] .. "s: " .. tostring(licensesErr))
				end
				
				if player.Parent then
					task.wait(FETCH_RETRY_DELAYS[attempt])
				end
			else
				if isTimeoutError(licensesErr) then
					warn("Fetch attempt " .. attempt .. " timed out for " .. player.Name .. " (final attempt)")
				else
					warn("Fetch attempt " .. attempt .. " failed for " .. player.Name .. " (final attempt): " .. tostring(licensesErr))
				end
			end
		end

		if not licensesResult then
			warn("License fetch failed for " .. player.Name .. " after " .. FETCH_RETRIES .. " retries: " .. tostring(licensesErr))
			-- Schedule background retry if player is still in server
			if player and player.Parent then
				scheduleBackgroundRetry(player, 1)
			end
			return
		end

		-- Step 4: Cache
		if licensesResult.data then
			LicenseCache.set(player.UserId, licensesResult.data)
			LicenseCache.setLastSync(player.UserId, os.time())
			print("Cached " .. #licensesResult.data .. " licenses for " .. player.Name)
		end
	end)
end

-- Cleanup on leave
Players.PlayerRemoving:Connect(function(player)
	LicenseCache.remove(player.UserId)
end)

-- Handle new players
Players.PlayerAdded:Connect(onPlayerAdded)

-- Handle already-connected players
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

print("License claim system loaded for universe " .. UNIVERSE_ID)
