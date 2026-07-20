-- TradeClient (LocalScript)
-- Complete 7-phase trading UI client
-- Phases: Player List → Request Popup → Trade Window → Inventory → Offers → Ready/Confirm → Success

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GameRemotes = ReplicatedStorage:WaitForChild("GameRemotes")

-- RemoteEvents
local SendTradeRequestRE = GameRemotes:WaitForChild("SendTradeRequest")
local TradeRequestResponseRE = GameRemotes:WaitForChild("TradeRequestResponse")
local TradeStartedRE = GameRemotes:WaitForChild("TradeStarted")
local TradeUpdateRE = GameRemotes:WaitForChild("TradeUpdate")
local TradeConfirmRE = GameRemotes:WaitForChild("TradeConfirm")
local TradeCancelledRE = GameRemotes:WaitForChild("TradeCancelled")
local GetPlayerLicensesRE = GameRemotes:WaitForChild("GetPlayerLicenses")

-- ============================================================
-- THEME
-- ============================================================
local COLORS = {
	bg = Color3.fromRGB(30, 30, 35),
	bgLight = Color3.fromRGB(40, 40, 48),
	bgDark = Color3.fromRGB(20, 20, 25),
	bgHover = Color3.fromRGB(50, 50, 58),
	accent = Color3.fromRGB(0, 170, 255),
	accentDark = Color3.fromRGB(0, 120, 200),
	green = Color3.fromRGB(0, 200, 80),
	greenDark = Color3.fromRGB(0, 150, 60),
	red = Color3.fromRGB(220, 50, 50),
	redDark = Color3.fromRGB(180, 30, 30),
	yellow = Color3.fromRGB(255, 200, 0),
	text = Color3.fromRGB(240, 240, 240),
	textDim = Color3.fromRGB(160, 160, 170),
	textDark = Color3.fromRGB(100, 100, 110),
	border = Color3.fromRGB(60, 60, 70),
	success = Color3.fromRGB(50, 205, 50),
	gold = Color3.fromRGB(255, 215, 0),
	disabled = Color3.fromRGB(80, 80, 90),
}

local FONTS = {
	title = Enum.Font.GothamBold,
	header = Enum.Font.GothamSemibold,
	body = Enum.Font.Gotham,
	small = Enum.Font.GothamMedium,
}

-- ============================================================
-- STATE
-- ============================================================
local state = {
	currentTradeId = nil,
	partnerName = nil,
	partnerId = nil,
	myLicenses = {},
	myOffer = {},
	theirOffer = {},
	myReady = false,
	theirReady = false,
	myConfirmed = false,
	theirConfirmed = false,
	requestPending = false,
	licensesRetryCount = 0,
	licensesStatus = "idle",
	-- Button state management
	buttonStates = {
		ready = false,
		unready = false,
		confirm = false,
		cancel = false,
		retryLicenses = false,
	},
	-- Local debounce timers
	lastButtonPress = {
		ready = 0,
		unready = 0,
		confirm = 0,
		cancel = 0,
		retryLicenses = 0,
	},
}

local LICENSE_MAX_RETRIES = 3
local LICENSE_RETRY_DELAYS = {6, 12, 20}
local currentFetchRequestId = nil
local BUTTON_DEBOUNCE_TIME = 0.5 -- seconds

-- Fix #4: Connection table to prevent memory leaks
local connections = {}

-- ============================================================
-- UI HELPERS
-- ============================================================
local function addCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function addStroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or COLORS.border
	s.Thickness = thickness or 1
	s.Parent = parent
	return s
end

local function addPadding(parent, t, b, l, r)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, t or 0)
	p.PaddingBottom = UDim.new(0, b or 0)
	p.PaddingLeft = UDim.new(0, l or 0)
	p.PaddingRight = UDim.new(0, r or 0)
	p.Parent = parent
	return p
end

local function makeLabel(parent, text, font, size, color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text or ""
	l.Font = font or FONTS.body
	l.TextSize = size or 14
	l.TextColor3 = color or COLORS.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = UDim2.new(1, 0, 0, 20)
	l.Parent = parent
	return l
end

local function makeButton(parent, text, bgColor, textColor, font, textSize)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = bgColor or COLORS.accent
	b.TextColor3 = textColor or COLORS.text
	b.Text = text or ""
	b.Font = font or FONTS.header
	b.TextSize = textSize or 14
	b.AutoButtonColor = true
	b.Size = UDim2.new(1, 0, 0, 36)
	addCorner(b, 6)
	addStroke(b, Color3.new(0, 0, 0), 0)
	b.Parent = parent
	return b
end

local function setButtonEnabled(button, enabled)
	if not button then return end
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.TextColor3 = enabled and COLORS.text or COLORS.textDim
	button.BackgroundColor3 = enabled and COLORS.accent or COLORS.disabled
end

local function clearChildren(frame, className)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA(className or "Frame") then
			child:Destroy()
		end
	end
end

-- ============================================================
-- LOADING SPINNER
-- ============================================================
local function createLoadingSpinner(parent)
	local spinner = Instance.new("Frame")
	spinner.Name = "LoadingSpinner"
	spinner.Size = UDim2.new(0, 40, 0, 40)
	spinner.Position = UDim2.new(0.5, -20, 0.5, -20)
	spinner.BackgroundTransparency = 1
	spinner.Parent = parent

	local dot1 = Instance.new("Frame")
	dot1.Size = UDim2.new(0, 8, 0, 8)
	dot1.Position = UDim2.new(0.5, -12, 0.5, -12)
	dot1.BackgroundColor3 = COLORS.accent
	dot1.BorderSizePixel = 0
	addCorner(dot1, 4)
	dot1.Parent = spinner

	local dot2 = Instance.new("Frame")
	dot2.Size = UDim2.new(0, 8, 0, 8)
	dot2.Position = UDim2.new(0.5, 4, 0.5, -12)
	dot2.BackgroundColor3 = COLORS.accent
	dot2.BorderSizePixel = 0
	addCorner(dot2, 4)
	dot2.Parent = spinner

	local dot3 = Instance.new("Frame")
	dot3.Size = UDim2.new(0, 8, 0, 8)
	dot3.Position = UDim2.new(0.5, -4, 0.5, 4)
	dot3.BackgroundColor3 = COLORS.accent
	dot3.BorderSizePixel = 0
	addCorner(dot3, 4)
	dot3.Parent = spinner

	local dot4 = Instance.new("Frame")
	dot4.Size = UDim2.new(0, 8, 0, 8)
	dot4.Position = UDim2.new(0.5, 12, 0.5, 4)
	dot4.BackgroundColor3 = COLORS.accent
	dot4.BorderSizePixel = 0
	addCorner(dot4, 4)
	dot4.Parent = spinner

	local dots = {dot1, dot2, dot3, dot4}
	local animationConn = nil

	local function animate()
		local time = 0
		animationConn = RunService.RenderStepped:Connect(function(dt)
			time += dt
			for i, dot in ipairs(dots) do
				local offset = (time * 3 + i * 0.5) % 2
				local alpha = offset < 1 and offset or 2 - offset
				dot.BackgroundColor3 = COLORS.accent:Lerp(COLORS.textDim, alpha)
				dot.Size = UDim2.new(0, 8 * (0.7 + 0.3 * alpha), 0, 8 * (0.7 + 0.3 * alpha))
			end
		end)
	end

	local function stop()
		if animationConn then
			animationConn:Disconnect()
			animationConn = nil
		end
	end

	return spinner, animate, stop
end

-- ============================================================
-- MAIN SCREEN GUI
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TradeUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true
screenGui.Parent = playerGui

-- ============================================================
-- PHASE 1: TRADE BUTTON + PLAYER LIST
-- ============================================================
local tradeButton = Instance.new("TextButton")
tradeButton.Name = "TradeButton"
tradeButton.Size = UDim2.new(0, 120, 0, 40)
tradeButton.Position = UDim2.new(1, -140, 1, -60)
tradeButton.BackgroundColor3 = COLORS.accent
tradeButton.TextColor3 = COLORS.text
tradeButton.Text = "Trade [T]"
tradeButton.Font = FONTS.header
tradeButton.TextSize = 14
addCorner(tradeButton, 8)
addStroke(tradeButton, COLORS.accentDark, 2)
tradeButton.Parent = screenGui

-- Player List Frame
local playerListFrame = Instance.new("Frame")
playerListFrame.Name = "PlayerListFrame"
playerListFrame.Size = UDim2.new(0, 300, 0, 400)
playerListFrame.Position = UDim2.new(0.5, -150, 0.5, -200)
playerListFrame.BackgroundColor3 = COLORS.bg
playerListFrame.BorderSizePixel = 0
playerListFrame.Visible = false
addCorner(playerListFrame, 12)
addStroke(playerListFrame, COLORS.border, 2)
playerListFrame.Parent = screenGui

local playerListTitle = makeLabel(playerListFrame, "Select Player to Trade", FONTS.title, 18, COLORS.text)
playerListTitle.Size = UDim2.new(1, -50, 0, 40)
playerListTitle.Position = UDim2.new(0, 15, 0, 5)

local playerListClose = makeButton(playerListFrame, "X", COLORS.red, COLORS.text, FONTS.header, 16)
playerListClose.Size = UDim2.new(0, 30, 0, 30)
playerListClose.Position = UDim2.new(1, -40, 0, 10)

local playerScrollFrame = Instance.new("ScrollingFrame")
playerScrollFrame.Size = UDim2.new(1, -20, 1, -60)
playerScrollFrame.Position = UDim2.new(0, 10, 0, 50)
playerScrollFrame.BackgroundTransparency = 1
playerScrollFrame.BorderSizePixel = 0
playerScrollFrame.ScrollBarThickness = 4
playerScrollFrame.ScrollBarImageColor3 = COLORS.accent
playerScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
playerScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
playerScrollFrame.Parent = playerListFrame

local playerListLayout = Instance.new("UIListLayout")
playerListLayout.SortOrder = Enum.SortOrder.LayoutOrder
playerListLayout.Padding = UDim.new(0, 6)
playerListLayout.Parent = playerScrollFrame

-- ============================================================
-- PHASE 2: REQUEST POPUP
-- ============================================================
local requestPopupFrame = Instance.new("Frame")
requestPopupFrame.Name = "RequestPopup"
requestPopupFrame.Size = UDim2.new(0, 350, 0, 180)
requestPopupFrame.Position = UDim2.new(0.5, -175, 0.5, -90)
requestPopupFrame.BackgroundColor3 = COLORS.bg
requestPopupFrame.BorderSizePixel = 0
requestPopupFrame.Visible = false
addCorner(requestPopupFrame, 12)
addStroke(requestPopupFrame, COLORS.accent, 2)
requestPopupFrame.Parent = screenGui

local requestTitle = makeLabel(requestPopupFrame, "Trade Request!", FONTS.title, 20, COLORS.accent)
requestTitle.Size = UDim2.new(1, 0, 0, 35)
requestTitle.Position = UDim2.new(0, 0, 0, 10)
requestTitle.TextXAlignment = Enum.TextXAlignment.Center

local requestNameLabel = makeLabel(requestPopupFrame, "", FONTS.body, 16, COLORS.text)
requestNameLabel.Size = UDim2.new(1, 0, 0, 25)
requestNameLabel.Position = UDim2.new(0, 0, 0, 50)
requestNameLabel.TextXAlignment = Enum.TextXAlignment.Center

local requestTimerBar = Instance.new("Frame")
requestTimerBar.Size = UDim2.new(0.8, 0, 0, 4)
requestTimerBar.Position = UDim2.new(0.1, 0, 0, 85)
requestTimerBar.BackgroundColor3 = COLORS.accent
requestTimerBar.BorderSizePixel = 0
addCorner(requestTimerBar, 2)
requestTimerBar.Parent = requestPopupFrame

local requestBtnFrame = Instance.new("Frame")
requestBtnFrame.Size = UDim2.new(0.8, 0, 0, 40)
requestBtnFrame.Position = UDim2.new(0.1, 0, 1, -55)
requestBtnFrame.BackgroundTransparency = 1
requestBtnFrame.Parent = requestPopupFrame

local acceptBtn = makeButton(requestBtnFrame, "Accept", COLORS.green, COLORS.text, FONTS.header, 16)
acceptBtn.Size = UDim2.new(0.48, 0, 1, 0)
acceptBtn.Position = UDim2.new(0, 0, 0, 0)

local declineBtn = makeButton(requestBtnFrame, "Decline", COLORS.red, COLORS.text, FONTS.header, 16)
declineBtn.Size = UDim2.new(0.48, 0, 1, 0)
declineBtn.Position = UDim2.new(0.52, 0, 0, 0)

-- ============================================================
-- PHASE 3-6: TRADE WINDOW
-- ============================================================
local tradeWindow = Instance.new("Frame")
tradeWindow.Name = "TradeWindow"
tradeWindow.Size = UDim2.new(0, 700, 0, 500)
tradeWindow.Position = UDim2.new(0.5, -350, 0.5, -250)
tradeWindow.BackgroundColor3 = COLORS.bg
tradeWindow.BorderSizePixel = 0
tradeWindow.Visible = false
addCorner(tradeWindow, 12)
addStroke(tradeWindow, COLORS.border, 2)
tradeWindow.Parent = screenGui

-- Title bar
local tradeTitleBar = Instance.new("Frame")
tradeTitleBar.Size = UDim2.new(1, 0, 0, 45)
tradeTitleBar.BackgroundColor3 = COLORS.bgDark
tradeTitleBar.BorderSizePixel = 0
addCorner(tradeTitleBar, 12)
tradeTitleBar.Parent = tradeWindow

local tradeTitleLabel = makeLabel(tradeTitleBar, "Trading with ...", FONTS.title, 16, COLORS.text)
tradeTitleLabel.Size = UDim2.new(1, -80, 1, 0)
tradeTitleLabel.Position = UDim2.new(0, 15, 0, 0)

local tradeCloseBtn = makeButton(tradeTitleBar, "Cancel", COLORS.red, COLORS.text, FONTS.header, 13)
tradeCloseBtn.Size = UDim2.new(0, 70, 0, 28)
tradeCloseBtn.Position = UDim2.new(1, -80, 0.5, -14)

-- Content area
local tradeContent = Instance.new("Frame")
tradeContent.Size = UDim2.new(1, 0, 1, -45)
tradeContent.Position = UDim2.new(0, 0, 0, 45)
tradeContent.BackgroundTransparency = 1
tradeContent.Parent = tradeWindow

-- LEFT: Inventory Panel (Phase 4)
local inventoryPanel = Instance.new("Frame")
inventoryPanel.Name = "InventoryPanel"
inventoryPanel.Size = UDim2.new(0.3, -5, 1, -60)
inventoryPanel.Position = UDim2.new(0, 10, 0, 5)
inventoryPanel.BackgroundColor3 = COLORS.bgLight
inventoryPanel.BorderSizePixel = 0
addCorner(inventoryPanel, 8)
addStroke(inventoryPanel, COLORS.border, 1)
inventoryPanel.Parent = tradeContent

local inventoryTitle = makeLabel(inventoryPanel, "My Licenses", FONTS.header, 14, COLORS.accent)
inventoryTitle.Size = UDim2.new(1, 0, 0, 30)
inventoryTitle.Position = UDim2.new(0, 10, 0, 5)

local inventoryScroll = Instance.new("ScrollingFrame")
inventoryScroll.Size = UDim2.new(1, -10, 1, -40)
inventoryScroll.Position = UDim2.new(0, 5, 0, 35)
inventoryScroll.BackgroundTransparency = 1
inventoryScroll.BorderSizePixel = 0
inventoryScroll.ScrollBarThickness = 4
inventoryScroll.ScrollBarImageColor3 = COLORS.accent
inventoryScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
inventoryScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
inventoryScroll.Parent = inventoryPanel

local inventoryListLayout = Instance.new("UIListLayout")
inventoryListLayout.SortOrder = Enum.SortOrder.LayoutOrder
inventoryListLayout.Padding = UDim.new(0, 4)
inventoryListLayout.Parent = inventoryScroll

-- CENTER: Offers Panel (Phase 5)
local offersPanel = Instance.new("Frame")
offersPanel.Size = UDim2.new(0.4, -10, 1, -60)
offersPanel.Position = UDim2.new(0.3, 5, 0, 5)
offersPanel.BackgroundTransparency = 1
offersPanel.Parent = tradeContent

-- My Offer
local myOfferFrame = Instance.new("Frame")
myOfferFrame.Name = "MyOfferFrame"
myOfferFrame.Size = UDim2.new(1, 0, 0.48, -5)
myOfferFrame.Position = UDim2.new(0, 0, 0, 0)
myOfferFrame.BackgroundColor3 = COLORS.bgLight
myOfferFrame.BorderSizePixel = 0
addCorner(myOfferFrame, 8)
addStroke(myOfferFrame, COLORS.border, 1)
myOfferFrame.Parent = offersPanel

local myOfferTitle = makeLabel(myOfferFrame, "Your Offer (0)", FONTS.header, 13, COLORS.green)
myOfferTitle.Size = UDim2.new(1, 0, 0, 25)
myOfferTitle.Position = UDim2.new(0, 10, 0, 3)

local myOfferScroll = Instance.new("ScrollingFrame")
myOfferScroll.Size = UDim2.new(1, -10, 1, -30)
myOfferScroll.Position = UDim2.new(0, 5, 0, 28)
myOfferScroll.BackgroundTransparency = 1
myOfferScroll.BorderSizePixel = 0
myOfferScroll.ScrollBarThickness = 3
myOfferScroll.ScrollBarImageColor3 = COLORS.accent
myOfferScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
myOfferScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
myOfferScroll.Parent = myOfferFrame

local myOfferLayout = Instance.new("UIListLayout")
myOfferLayout.SortOrder = Enum.SortOrder.LayoutOrder
myOfferLayout.Padding = UDim.new(0, 3)
myOfferLayout.Parent = myOfferScroll

-- Arrow between offers
local arrowFrame = Instance.new("Frame")
arrowFrame.Size = UDim2.new(1, 0, 0, 20)
arrowFrame.Position = UDim2.new(0, 0, 0.48, -5)
arrowFrame.BackgroundTransparency = 1
arrowFrame.Parent = offersPanel

local arrowLabel = makeLabel(arrowFrame, "\226\135\133", FONTS.title, 18, COLORS.textDim)
arrowLabel.Size = UDim2.new(1, 0, 1, 0)
arrowLabel.TextXAlignment = Enum.TextXAlignment.Center

-- Their Offer
local theirOfferFrame = Instance.new("Frame")
theirOfferFrame.Name = "TheirOfferFrame"
theirOfferFrame.Size = UDim2.new(1, 0, 0.48, -5)
theirOfferFrame.Position = UDim2.new(0, 0, 0.52, 5)
theirOfferFrame.BackgroundColor3 = COLORS.bgLight
theirOfferFrame.BorderSizePixel = 0
addCorner(theirOfferFrame, 8)
addStroke(theirOfferFrame, COLORS.border, 1)
theirOfferFrame.Parent = offersPanel

local theirOfferTitle = makeLabel(theirOfferFrame, "Their Offer (0)", FONTS.header, 13, COLORS.yellow)
theirOfferTitle.Size = UDim2.new(1, 0, 0, 25)
theirOfferTitle.Position = UDim2.new(0, 10, 0, 3)

local theirOfferScroll = Instance.new("ScrollingFrame")
theirOfferScroll.Size = UDim2.new(1, -10, 1, -30)
theirOfferScroll.Position = UDim2.new(0, 5, 0, 28)
theirOfferScroll.BackgroundTransparency = 1
theirOfferScroll.BorderSizePixel = 0
theirOfferScroll.ScrollBarThickness = 3
theirOfferScroll.ScrollBarImageColor3 = COLORS.accent
theirOfferScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
theirOfferScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
theirOfferScroll.Parent = theirOfferFrame

local theirOfferLayout = Instance.new("UIListLayout")
theirOfferLayout.SortOrder = Enum.SortOrder.LayoutOrder
theirOfferLayout.Padding = UDim.new(0, 3)
theirOfferLayout.Parent = theirOfferScroll

-- RIGHT: Status Panel (Phase 6)
local statusPanel = Instance.new("Frame")
statusPanel.Name = "StatusPanel"
statusPanel.Size = UDim2.new(0.3, -5, 1, -60)
statusPanel.Position = UDim2.new(0.7, 5, 0, 5)
statusPanel.BackgroundColor3 = COLORS.bgLight
statusPanel.BorderSizePixel = 0
addCorner(statusPanel, 8)
addStroke(statusPanel, COLORS.border, 1)
statusPanel.Parent = tradeContent

local statusTitle = makeLabel(statusPanel, "Trade Status", FONTS.header, 14, COLORS.accent)
statusTitle.Size = UDim2.new(1, 0, 0, 30)
statusTitle.Position = UDim2.new(0, 10, 0, 5)

local myReadyLabel = makeLabel(statusPanel, "\226\151\139 You: Not Ready", FONTS.body, 13, COLORS.textDim)
myReadyLabel.Size = UDim2.new(1, -20, 0, 22)
myReadyLabel.Position = UDim2.new(0, 10, 0, 40)

local theirReadyLabel = makeLabel(statusPanel, "\226\151\139 Partner: Not Ready", FONTS.body, 13, COLORS.textDim)
theirReadyLabel.Size = UDim2.new(1, -20, 0, 22)
theirReadyLabel.Position = UDim2.new(0, 10, 0, 65)

local divider1 = Instance.new("Frame")
divider1.Size = UDim2.new(0.8, 0, 0, 1)
divider1.Position = UDim2.new(0.1, 0, 0, 92)
divider1.BackgroundColor3 = COLORS.border
divider1.BorderSizePixel = 0
divider1.Parent = statusPanel

local myConfirmLabel = makeLabel(statusPanel, "\226\151\139 You: Not Confirmed", FONTS.body, 13, COLORS.textDim)
myConfirmLabel.Size = UDim2.new(1, -20, 0, 22)
myConfirmLabel.Position = UDim2.new(0, 10, 0, 100)

local theirConfirmLabel = makeLabel(statusPanel, "\226\151\139 Partner: Not Confirmed", FONTS.body, 13, COLORS.textDim)
theirConfirmLabel.Size = UDim2.new(1, -20, 0, 22)
theirConfirmLabel.Position = UDim2.new(0, 10, 0, 125)

local warningLabel = makeLabel(statusPanel, "", FONTS.small, 11, COLORS.yellow)
warningLabel.Size = UDim2.new(1, -20, 0, 50)
warningLabel.Position = UDim2.new(0, 10, 0, 155)
warningLabel.TextWrapped = true
warningLabel.Visible = false

-- BOTTOM: Action Buttons (Phase 6)
local actionFrame = Instance.new("Frame")
actionFrame.Size = UDim2.new(1, -20, 0, 45)
actionFrame.Position = UDim2.new(0, 10, 1, -55)
actionFrame.BackgroundTransparency = 1
actionFrame.Parent = tradeWindow

local readyBtn = makeButton(actionFrame, "Ready Up", COLORS.green, COLORS.text, FONTS.header, 15)
readyBtn.Size = UDim2.new(0.3, -5, 1, 0)
readyBtn.Position = UDim2.new(0.02, 0, 0, 0)

local unreadyBtn = makeButton(actionFrame, "Unready", COLORS.yellow, Color3.fromRGB(30, 30, 35), FONTS.header, 15)
unreadyBtn.Size = UDim2.new(0.3, -5, 1, 0)
unreadyBtn.Position = UDim2.new(0.02, 0, 0, 0)
unreadyBtn.Visible = false

local confirmBtn = makeButton(actionFrame, "Confirm Trade", COLORS.gold, Color3.fromRGB(30, 30, 35), FONTS.header, 15)
confirmBtn.Size = UDim2.new(0.3, -5, 1, 0)
confirmBtn.Position = UDim2.new(0.35, 0, 0, 0)
confirmBtn.Visible = false

-- ============================================================
-- PHASE 7: SUCCESS SCREEN
-- ============================================================
local successFrame = Instance.new("Frame")
successFrame.Name = "SuccessFrame"
successFrame.Size = UDim2.new(0, 400, 0, 300)
successFrame.Position = UDim2.new(0.5, -200, 0.5, -150)
successFrame.BackgroundColor3 = COLORS.bg
successFrame.BorderSizePixel = 0
successFrame.Visible = false
addCorner(successFrame, 12)
addStroke(successFrame, COLORS.success, 2)
successFrame.Parent = screenGui

local successTitle = makeLabel(successFrame, "Trade Complete!", FONTS.title, 24, COLORS.success)
successTitle.Size = UDim2.new(1, 0, 0, 40)
successTitle.Position = UDim2.new(0, 0, 0, 15)
successTitle.TextXAlignment = Enum.TextXAlignment.Center

local successSubtitle = makeLabel(successFrame, "You received:", FONTS.body, 14, COLORS.textDim)
successSubtitle.Size = UDim2.new(1, 0, 0, 20)
successSubtitle.Position = UDim2.new(0, 0, 0, 55)
successSubtitle.TextXAlignment = Enum.TextXAlignment.Center

local successScroll = Instance.new("ScrollingFrame")
successScroll.Size = UDim2.new(0.9, 0, 0, 150)
successScroll.Position = UDim2.new(0.05, 0, 0, 80)
successScroll.BackgroundTransparency = 1
successScroll.BorderSizePixel = 0
successScroll.ScrollBarThickness = 4
successScroll.ScrollBarImageColor3 = COLORS.accent
successScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
successScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
successScroll.Parent = successFrame

local successListLayout = Instance.new("UIListLayout")
successListLayout.SortOrder = Enum.SortOrder.LayoutOrder
successListLayout.Padding = UDim.new(0, 4)
successListLayout.Parent = successScroll

local successCloseBtn = makeButton(successFrame, "Close", COLORS.accent, COLORS.text, FONTS.header, 14)
successCloseBtn.Size = UDim2.new(0.5, 0, 0, 36)
successCloseBtn.Position = UDim2.new(0.25, 0, 1, -50)

-- ============================================================
-- TOAST NOTIFICATION
-- ============================================================
local toastFrame = Instance.new("Frame")
toastFrame.Name = "ToastFrame"
toastFrame.Size = UDim2.new(0, 320, 0, 50)
toastFrame.Position = UDim2.new(0.5, -160, 0, 20)
toastFrame.BackgroundColor3 = COLORS.bgDark
toastFrame.BorderSizePixel = 0
toastFrame.Visible = false
addCorner(toastFrame, 8)
addStroke(toastFrame, COLORS.accent, 1)
toastFrame.Parent = screenGui

local toastLabel = makeLabel(toastFrame, "", FONTS.body, 13, COLORS.text)
toastLabel.Size = UDim2.new(1, -20, 1, 0)
toastLabel.Position = UDim2.new(0, 10, 0, 0)
toastLabel.TextXAlignment = Enum.TextXAlignment.Center

-- ============================================================
-- TOAST LOGIC
-- ============================================================
local toastQueue = {}
local toastBusy = false

local function processToastQueue()
	toastBusy = true
	while #toastQueue > 0 do
		local msg = table.remove(toastQueue, 1)
		toastLabel.Text = msg
		toastFrame.Visible = true
		toastFrame.BackgroundTransparency = 1
		local fadeIn = TweenService:Create(toastFrame, TweenInfo.new(0.3), {BackgroundTransparency = 0})
		fadeIn:Play()
		task.wait(3)
		local fadeOut = TweenService:Create(toastFrame, TweenInfo.new(0.3), {BackgroundTransparency = 1})
		fadeOut:Play()
		fadeOut.Completed:Wait()
		toastFrame.Visible = false
		task.wait(0.1)
	end
	toastBusy = false
end

local function showToast(message)
	table.insert(toastQueue, message)
	if not toastBusy then
		task.spawn(processToastQueue)
	end
end

-- ============================================================
-- BUTTON STATE MANAGEMENT
-- ============================================================
local function setAllButtonsEnabled(enabled)
	setButtonEnabled(readyBtn, enabled)
	setButtonEnabled(unreadyBtn, enabled)
	setButtonEnabled(confirmBtn, enabled)
	setButtonEnabled(tradeCloseBtn, enabled)
end

local function resetButtonStates()
	state.buttonStates = {
		ready = false,
		unready = false,
		confirm = false,
		cancel = false,
		retryLicenses = false,
	}
end

-- ============================================================
-- PHASE 1: PLAYER LIST LOGIC
-- ============================================================
local function refreshPlayerList()
	clearChildren(playerScrollFrame, "Frame")

	local otherPlayers = {}
	for _, p in Players:GetPlayers() do
		if p ~= player then
			table.insert(otherPlayers, p)
		end
	end

	if #otherPlayers == 0 then
		local emptyLabel = makeLabel(playerScrollFrame, "No other players online", FONTS.body, 13, COLORS.textDim)
		emptyLabel.Size = UDim2.new(1, 0, 0, 30)
		emptyLabel.TextXAlignment = Enum.TextXAlignment.Center
		return
	end

	for i, p in ipairs(otherPlayers) do
		local entry = Instance.new("Frame")
		entry.Size = UDim2.new(1, 0, 0, 40)
		entry.BackgroundColor3 = COLORS.bgDark
		entry.BorderSizePixel = 0
		addCorner(entry, 6)
		entry.Parent = playerScrollFrame

		local nameLabel = makeLabel(entry, p.Name, FONTS.body, 14, COLORS.text)
		nameLabel.Size = UDim2.new(0.6, 0, 1, 0)
		nameLabel.Position = UDim2.new(0, 10, 0, 0)

		local tradeBtn = makeButton(entry, "Trade", COLORS.accent, COLORS.text, FONTS.small, 12)
		tradeBtn.Size = UDim2.new(0, 60, 0, 28)
		tradeBtn.Position = UDim2.new(1, -70, 0.5, -14)

		-- Fix #1: Store targetUserId as attribute to prevent wrong player selection
		tradeBtn:SetAttribute("TargetUserId", p.UserId)

		local conn = tradeBtn.MouseButton1Click:Connect(function()
			if state.currentTradeId then
				showToast("You are already in a trade!")
				return
			end
			local targetUserId = tradeBtn:GetAttribute("TargetUserId")
			SendTradeRequestRE:FireServer({targetUserId = targetUserId})
			showToast("Trade request sent to " .. p.Name)
			playerListFrame.Visible = false
		end)
		table.insert(connections, conn)
	end
end

-- ============================================================
-- PHASE 4: INVENTORY LOGIC
-- ============================================================
local function resetReadyState()
	state.myReady = false
	state.theirReady = false
	state.myConfirmed = false
	state.theirConfirmed = false

	myReadyLabel.Text = "\226\151\139 You: Not Ready"
	myReadyLabel.TextColor3 = COLORS.textDim
	theirReadyLabel.Text = "\226\151\139 Partner: Not Ready"
	theirReadyLabel.TextColor3 = COLORS.textDim
	myConfirmLabel.Text = "\226\151\139 You: Not Confirmed"
	myConfirmLabel.TextColor3 = COLORS.textDim
	theirConfirmLabel.Text = "\226\151\139 Partner: Not Confirmed"
	theirConfirmLabel.TextColor3 = COLORS.textDim

	readyBtn.Visible = true
	unreadyBtn.Visible = false
	confirmBtn.Visible = false
	warningLabel.Visible = false
end

local function refreshInventory()
	clearChildren(inventoryScroll, "Frame")

	if state.licensesStatus == "loading" and #state.myLicenses == 0 then
		-- Improved loading message with spinner
		local loadingContainer = Instance.new("Frame")
		loadingContainer.Size = UDim2.new(1, 0, 0, 80)
		loadingContainer.BackgroundTransparency = 1
		loadingContainer.Parent = inventoryScroll

		local spinner, animate, stop = createLoadingSpinner(loadingContainer)
		animate()

		local loadingLabel = makeLabel(loadingContainer, "Loading licenses...", FONTS.body, 13, COLORS.textDim)
		loadingLabel.Size = UDim2.new(1, 0, 0, 20)
		loadingLabel.Position = UDim2.new(0, 0, 1, -25)
		loadingLabel.TextXAlignment = Enum.TextXAlignment.Center

		local subLabel = makeLabel(loadingContainer, "This may take a few seconds.", FONTS.small, 11, COLORS.textDark)
		subLabel.Size = UDim2.new(1, 0, 0, 16)
		subLabel.Position = UDim2.new(0, 0, 1, -5)
		subLabel.TextXAlignment = Enum.TextXAlignment.Center

		-- Store stop function to clean up later
		loadingContainer:SetAttribute("SpinnerStop", true)
		task.delay(0.1, function()
			if loadingContainer and loadingContainer.Parent then
				stop()
				loadingContainer:Destroy()
			end
		end)
		return
	end

	if state.licensesStatus == "retrying" and #state.myLicenses == 0 then
		local retryLabel = makeLabel(inventoryScroll, "Retrying...", FONTS.body, 13, COLORS.yellow)
		retryLabel.Size = UDim2.new(1, 0, 0, 30)
		retryLabel.TextXAlignment = Enum.TextXAlignment.Center
		return
	end

	if state.licensesStatus == "error" and #state.myLicenses == 0 then
		local errorLabel = makeLabel(inventoryScroll, "Failed to load licenses", FONTS.body, 13, COLORS.red)
		errorLabel.Size = UDim2.new(1, 0, 0, 30)
		errorLabel.TextXAlignment = Enum.TextXAlignment.Center

		local retryBtn = makeButton(inventoryScroll, "Retry", COLORS.accent, COLORS.text, FONTS.small, 12)
		retryBtn.Size = UDim2.new(0.6, 0, 0, 30)
		retryBtn.Position = UDim2.new(0.2, 0, 0, 35)

		local conn = retryBtn.MouseButton1Click:Connect(function()
			-- Debounce check
			if tick() - state.lastButtonPress.retryLicenses < BUTTON_DEBOUNCE_TIME then
				return
			end
			state.lastButtonPress.retryLicenses = tick()
			
			if state.buttonStates.retryLicenses then return end
			state.buttonStates.retryLicenses = true
			setButtonEnabled(retryBtn, false)
			
			fetchLicenses()
		end)
		table.insert(connections, conn)
		return
	end

	local offeredSet = {}
	for _, licId in ipairs(state.myOffer) do
		offeredSet[licId] = true
	end

	local NON_TRADEABLE = {TRANSFERRED = true, REVOKED = true, EXPIRED = true}

	for i, lic in ipairs(state.myLicenses) do
		if offeredSet[lic.id] then continue end
		if NON_TRADEABLE[lic.status] then continue end

		local entry = Instance.new("Frame")
		entry.Size = UDim2.new(1, 0, 0, 36)
		entry.BackgroundColor3 = COLORS.bgDark
		entry.BorderSizePixel = 0
		addCorner(entry, 6)
		entry.Parent = inventoryScroll

		-- Display license name instead of UUID
		local displayName = lic.displayName or lic.name or "Unknown License"
		local nameLabel = makeLabel(entry, displayName, FONTS.small, 12, COLORS.text)
		nameLabel.Size = UDim2.new(0.5, 0, 1, 0)
		nameLabel.Position = UDim2.new(0, 8, 0, 0)

		local statusLabel = makeLabel(entry, lic.status, FONTS.small, 10, COLORS.textDim)
		statusLabel.Size = UDim2.new(0.22, 0, 1, 0)
		statusLabel.Position = UDim2.new(0.5, 0, 0, 0)
		statusLabel.TextXAlignment = Enum.TextXAlignment.Center

		local addBtn = makeButton(entry, "+", COLORS.green, COLORS.text, FONTS.header, 14)
		addBtn.Size = UDim2.new(0, 28, 0, 28)
		addBtn.Position = UDim2.new(1, -34, 0.5, -14)

		local conn = addBtn.MouseButton1Click:Connect(function()
			if not state.currentTradeId then return end
			-- Reset ready state locally for immediate UI feedback (without clearing offers)
			resetReadyState()

			TradeUpdateRE:FireServer({
				tradeId = state.currentTradeId,
				action = "AddLicense",
				licenseId = lic.id,
			})
		end)
		table.insert(connections, conn)
	end
end

-- ============================================================
-- PHASE 5: OFFER LOGIC
-- ============================================================
local function refreshOffers(tradeState)
	clearChildren(myOfferScroll, "Frame")
	clearChildren(theirOfferScroll, "Frame")

	for i, lic in ipairs(tradeState.myOfferedLicenses) do
		local entry = Instance.new("Frame")
		entry.Size = UDim2.new(1, 0, 0, 32)
		entry.BackgroundColor3 = COLORS.bgDark
		entry.BorderSizePixel = 0
		addCorner(entry, 6)
		entry.Parent = myOfferScroll

		-- Display license name instead of UUID
		local displayName = lic.displayName or lic.name or "Unknown License"
		local nameLabel = makeLabel(entry, displayName, FONTS.small, 12, COLORS.text)
		nameLabel.Size = UDim2.new(0.7, 0, 1, 0)
		nameLabel.Position = UDim2.new(0, 8, 0, 0)

		local removeBtn = makeButton(entry, "\226\136\146", COLORS.red, COLORS.text, FONTS.header, 14)
		removeBtn.Size = UDim2.new(0, 24, 0, 24)
		removeBtn.Position = UDim2.new(1, -30, 0.5, -12)

		local conn = removeBtn.MouseButton1Click:Connect(function()
			if not state.currentTradeId then return end
			-- Reset ready state locally for immediate UI feedback (without clearing offers)
			resetReadyState()

			TradeUpdateRE:FireServer({
				tradeId = state.currentTradeId,
				action = "RemoveLicense",
				licenseId = lic.id,
			})
		end)
		table.insert(connections, conn)
	end

	for i, lic in ipairs(tradeState.theirOfferedLicenses) do
		local entry = Instance.new("Frame")
		entry.Size = UDim2.new(1, 0, 0, 32)
		entry.BackgroundColor3 = COLORS.bgDark
		entry.BorderSizePixel = 0
		addCorner(entry, 6)
		entry.Parent = theirOfferScroll

		-- Display license name instead of UUID
		local displayName = lic.displayName or lic.name or "Unknown License"
		local nameLabel = makeLabel(entry, displayName, FONTS.small, 12, COLORS.text)
		nameLabel.Size = UDim2.new(1, -10, 1, 0)
		nameLabel.Position = UDim2.new(0, 8, 0, 0)
	end

	myOfferTitle.Text = "Your Offer (" .. #tradeState.myOfferedLicenses .. ")"
	theirOfferTitle.Text = "Their Offer (" .. #tradeState.theirOfferedLicenses .. ")"
end

-- ============================================================
-- PHASE 6: READY/CONFIRM STATUS LOGIC
-- ============================================================
local function updateStatus(tradeState)
	myReadyLabel.Text = tradeState.myReady and "\226\156\147 You: Ready" or "\226\151\139 You: Not Ready"
	myReadyLabel.TextColor3 = tradeState.myReady and COLORS.green or COLORS.textDim

	theirReadyLabel.Text = tradeState.theirReady and "\226\156\147 Partner: Ready" or "\226\151\139 Partner: Not Ready"
	theirReadyLabel.TextColor3 = tradeState.theirReady and COLORS.green or COLORS.textDim

	myConfirmLabel.Text = tradeState.myConfirmed and "\226\156\147 You: Confirmed" or "\226\151\139 You: Not Confirmed"
	myConfirmLabel.TextColor3 = tradeState.myConfirmed and COLORS.green or COLORS.textDim

	theirConfirmLabel.Text = tradeState.theirConfirmed and "\226\156\147 Partner: Confirmed" or "\226\151\139 Partner: Not Confirmed"
	theirConfirmLabel.TextColor3 = tradeState.theirConfirmed and COLORS.green or COLORS.textDim

	if tradeState.myConfirmed then
		readyBtn.Visible = false
		unreadyBtn.Visible = false
		confirmBtn.Visible = false
		warningLabel.Text = "Waiting for partner to confirm..."
		warningLabel.TextColor3 = COLORS.accent
		warningLabel.Visible = true
	elseif tradeState.myReady then
		readyBtn.Visible = false
		unreadyBtn.Visible = true
		if tradeState.theirReady then
			confirmBtn.Visible = true
			warningLabel.Text = "Both ready! Confirm to complete trade."
			warningLabel.TextColor3 = COLORS.gold
			warningLabel.Visible = true
		else
			confirmBtn.Visible = false
			warningLabel.Text = "Waiting for partner to ready up..."
			warningLabel.TextColor3 = COLORS.textDim
			warningLabel.Visible = true
		end
	else
		readyBtn.Visible = true
		unreadyBtn.Visible = false
		confirmBtn.Visible = false
		warningLabel.Visible = false
	end

	-- Re-enable buttons after server response
	setAllButtonsEnabled(true)
	resetButtonStates()

	state.myReady = tradeState.myReady
	state.theirReady = tradeState.theirReady
	state.myConfirmed = tradeState.myConfirmed
	state.theirConfirmed = tradeState.theirConfirmed
	state.myOffer = {}
	for _, lic in ipairs(tradeState.myOfferedLicenses) do
		table.insert(state.myOffer, lic.id)
	end
	state.theirOffer = tradeState.theirOfferedLicenses
end

-- ============================================================
-- PHASE 7: SUCCESS LOGIC
-- ============================================================
local function showSuccess(receivedLicenses)
	clearChildren(successScroll, "Frame")

	if #receivedLicenses == 0 then
		local emptyLabel = makeLabel(successScroll, "No licenses received", FONTS.body, 13, COLORS.textDim)
		emptyLabel.Size = UDim2.new(1, 0, 0, 30)
		emptyLabel.TextXAlignment = Enum.TextXAlignment.Center
	else
		for i, lic in ipairs(receivedLicenses) do
			local entry = Instance.new("Frame")
			entry.Size = UDim2.new(1, 0, 0, 32)
			entry.BackgroundColor3 = COLORS.bgLight
			entry.BorderSizePixel = 0
			addCorner(entry, 6)
			entry.Parent = successScroll

			-- Display license name instead of UUID
			local displayName = lic.displayName or lic.name or "Unknown License"
			local nameLabel = makeLabel(entry, displayName, FONTS.body, 13, COLORS.success)
			nameLabel.Size = UDim2.new(1, -10, 1, 0)
			nameLabel.Position = UDim2.new(0, 10, 0, 0)
		end
	end

	successFrame.Visible = true
	tradeWindow.Visible = false
end

-- ============================================================
-- RESET
-- ============================================================
local function resetTradeUI()
	state.currentTradeId = nil
	state.partnerName = nil
	state.partnerId = nil
	state.myOffer = {}
	state.theirOffer = {}
	state.myReady = false
	state.theirReady = false
	state.myConfirmed = false
	state.theirConfirmed = false

	tradeWindow.Visible = false
	requestPopupFrame.Visible = false
	successFrame.Visible = false

	-- Clear all UI elements
	clearChildren(myOfferScroll, "Frame")
	clearChildren(theirOfferScroll, "Frame")
	resetReadyState()
	
	-- Re-enable buttons
	setAllButtonsEnabled(true)
	resetButtonStates()
end

-- ============================================================
-- FETCH LICENSES
-- ============================================================
local function fetchLicenses()
	if state.licensesStatus == "loading" then return end
	local requestId = "fetch_" .. tostring(math.floor(tick() * 1000))
	currentFetchRequestId = requestId
	state.licensesStatus = "loading"
	state.licensesRetryCount = 0
	refreshInventory()
	GetPlayerLicensesRE:FireServer(requestId)
end

-- ============================================================
-- BUTTON HANDLERS
-- ============================================================

-- Trade button / keybind
local tradeButtonConn = tradeButton.MouseButton1Click:Connect(function()
	if state.currentTradeId then
		tradeWindow.Visible = not tradeWindow.Visible
	else
		playerListFrame.Visible = not playerListFrame.Visible
		if playerListFrame.Visible then
			refreshPlayerList()
		end
	end
end)
table.insert(connections, tradeButtonConn)

local inputBeganConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.T then
		if state.currentTradeId then
			tradeWindow.Visible = not tradeWindow.Visible
		else
			playerListFrame.Visible = not playerListFrame.Visible
			if playerListFrame.Visible then
				refreshPlayerList()
			end
		end
	end
end)
table.insert(connections, inputBeganConn)

local playerListCloseConn = playerListClose.MouseButton1Click:Connect(function()
	playerListFrame.Visible = false
end)
table.insert(connections, playerListCloseConn)

-- Phase 2: Accept/Decline
local currentRequestId = nil
local requestTimerConn = nil

local acceptBtnConn = acceptBtn.MouseButton1Click:Connect(function()
	if currentRequestId then
		TradeRequestResponseRE:FireServer({
			accepted = true,
			requestId = currentRequestId,
		})
		requestPopupFrame.Visible = false
		currentRequestId = nil
		if requestTimerConn then
			requestTimerConn:Disconnect()
			requestTimerConn = nil
		end
	end
end)
table.insert(connections, acceptBtnConn)

local declineBtnConn = declineBtn.MouseButton1Click:Connect(function()
	if declineBtn.Active == false then return end -- Debounce
	if currentRequestId then
		TradeRequestResponseRE:FireServer({
			accepted = false,
			requestId = currentRequestId,
		})
		requestPopupFrame.Visible = false
		currentRequestId = nil
		if requestTimerConn then
			requestTimerConn:Disconnect()
			requestTimerConn = nil
		end
	end
end)
table.insert(connections, declineBtnConn)

-- Phase 6: Ready/Unready/Confirm
local readyBtnConn = readyBtn.MouseButton1Click:Connect(function()
	if not state.currentTradeId then return end
	if state.buttonStates.ready then return end
	
	-- Debounce check
	if tick() - state.lastButtonPress.ready < BUTTON_DEBOUNCE_TIME then
		return
	end
	state.lastButtonPress.ready = tick()
	
	state.buttonStates.ready = true
	setButtonEnabled(readyBtn, false)
	
	TradeUpdateRE:FireServer({
		tradeId = state.currentTradeId,
		action = "Ready",
		ready = true,
	})
end)
table.insert(connections, readyBtnConn)

local unreadyBtnConn = unreadyBtn.MouseButton1Click:Connect(function()
	if not state.currentTradeId then return end
	if state.buttonStates.unready then return end
	
	-- Debounce check
	if tick() - state.lastButtonPress.unready < BUTTON_DEBOUNCE_TIME then
		return
	end
	state.lastButtonPress.unready = tick()
	
	state.buttonStates.unready = true
	setButtonEnabled(unreadyBtn, false)
	
	TradeUpdateRE:FireServer({
		tradeId = state.currentTradeId,
		action = "Ready",
		ready = false,
	})
end)
table.insert(connections, unreadyBtnConn)

local confirmBtnConn = confirmBtn.MouseButton1Click:Connect(function()
	if not state.currentTradeId then return end
	if state.buttonStates.confirm then return end
	
	-- Debounce check
	if tick() - state.lastButtonPress.confirm < BUTTON_DEBOUNCE_TIME then
		return
	end
	state.lastButtonPress.confirm = tick()
	
	state.buttonStates.confirm = true
	setButtonEnabled(confirmBtn, false)
	
	TradeConfirmRE:FireServer({
		tradeId = state.currentTradeId,
	})
end)
table.insert(connections, confirmBtnConn)

-- Cancel trade
local tradeCloseBtnConn = tradeCloseBtn.MouseButton1Click:Connect(function()
	if not state.currentTradeId then return end
	if state.buttonStates.cancel then return end
	
	-- Debounce check
	if tick() - state.lastButtonPress.cancel < BUTTON_DEBOUNCE_TIME then
		return
	end
	state.lastButtonPress.cancel = tick()
	
	state.buttonStates.cancel = true
	setButtonEnabled(tradeCloseBtn, false)
	
	TradeUpdateRE:FireServer({
		tradeId = state.currentTradeId,
		action = "Cancel",
	})
	resetTradeUI()
end)
table.insert(connections, tradeCloseBtnConn)

-- Success close
local successCloseBtnConn = successCloseBtn.MouseButton1Click:Connect(function()
	successFrame.Visible = false
	fetchLicenses()
end)
table.insert(connections, successCloseBtnConn)

-- ============================================================
-- REMOTE EVENT LISTENERS
-- ============================================================

-- Incoming trade request (Phase 2)
SendTradeRequestRE.OnClientEvent:Connect(function(data)
	if state.currentTradeId then
		TradeRequestResponseRE:FireServer({
			accepted = false,
			requestId = data.requestId,
		})
		return
	end

	currentRequestId = data.requestId
	requestNameLabel.Text = data.requesterName .. " wants to trade!"
	requestPopupFrame.Visible = true

	-- Timer animation (30s)
	if requestTimerConn then
		requestTimerConn:Disconnect()
	end
	local startTime = tick()
	local timerDuration = 30
	requestTimerConn = RunService.RenderStepped:Connect(function()
		local elapsed = tick() - startTime
		local remaining = 1 - (elapsed / timerDuration)
		if remaining <= 0 then
			requestTimerBar.Size = UDim2.new(0, 0, 0, 4)
			requestTimerBar.BackgroundColor3 = COLORS.red
			if requestTimerConn then
				requestTimerConn:Disconnect()
				requestTimerConn = nil
			end
			return
		end
		requestTimerBar.Size = UDim2.new(0.8 * remaining, 0, 0, 4)
		requestTimerBar.BackgroundColor3 = remaining < 0.3 and COLORS.red or COLORS.accent
	end)
end)

-- Trade request response (for the requester)
TradeRequestResponseRE.OnClientEvent:Connect(function(data)
	if data.accepted then
		showToast(data.targetName .. " accepted your trade request!")
	else
		local reasons = {
			declined = data.targetName .. " declined your trade request",
			expired = "Trade request to " .. data.targetName .. " expired",
			busy = data.targetName .. " is already in a trade",
			already_in_trade = "You are already in a trade",
			target_in_trade = data.targetName .. " is already in a trade",
			superseded = "Your request to " .. data.targetName .. " was superseded",
		}
		showToast(reasons[data.reason] or "Trade request failed")
	end
end)

-- Trade started (Phase 3)
TradeStartedRE.OnClientEvent:Connect(function(data)
	state.currentTradeId = data.tradeId
	state.partnerName = data.partnerName
	state.partnerId = data.partnerId

	tradeTitleLabel.Text = "Trading with " .. data.partnerName
	playerListFrame.Visible = false
	requestPopupFrame.Visible = false
	tradeWindow.Visible = true

	readyBtn.Visible = true
	unreadyBtn.Visible = false
	confirmBtn.Visible = false
	warningLabel.Visible = false

	fetchLicenses()
end)

-- Trade update (state changes, Phase 5-6)
TradeUpdateRE.OnClientEvent:Connect(function(data)
	-- Completion event (Phase 7)
	if data.action == "Completed" then
		showSuccess(data.receivedLicenses or {})
		state.currentTradeId = nil
		
		-- Auto-refresh licenses after trade completion
		task.delay(0.5, function()
			fetchLicenses()
		end)
		
		return
	end

	-- Regular trade state update
	if data.tradeId ~= state.currentTradeId then return end

	refreshOffers(data)
	updateStatus(data)
	refreshInventory()
end)

-- Trade cancelled
TradeCancelledRE.OnClientEvent:Connect(function(data)
	-- Handle disconnects with friendly messages
	if data.reason == "player_left" then
		showToast("Trade cancelled.")
		showToast("The other player left the game.")
	elseif data.reason == "cancelled" then
		showToast("Trade was cancelled.")
	elseif data.reason == "timeout" then
		showToast("Trade timed out due to inactivity.")
	elseif data.reason == "validation_failed" then
		showToast("Trade validation failed.")
	else
		showToast("Trade ended: " .. tostring(data.reason))
	end
	
	resetTradeUI()
end)

-- Get player licenses response
GetPlayerLicensesRE.OnClientEvent:Connect(function(requestId, data)
	-- Ignore stale responses from previous fetch attempts
	if requestId ~= currentFetchRequestId then return end
	currentFetchRequestId = nil

	if data and data.success and data.data then
		state.myLicenses = data.data.licenses or {}
		state.licensesRetryCount = 0
		state.licensesStatus = "idle"
		state.buttonStates.retryLicenses = false
		refreshInventory()
	elseif state.licensesRetryCount < LICENSE_MAX_RETRIES then
		state.licensesRetryCount += 1
		state.licensesStatus = "retrying"
		local delay = LICENSE_RETRY_DELAYS[state.licensesRetryCount] or 20
		showToast("Failed to load licenses. Retrying in " .. delay .. "s... (" .. state.licensesRetryCount .. "/" .. LICENSE_MAX_RETRIES .. ")")
		refreshInventory()
		task.delay(delay, function()
			if state.licensesStatus ~= "retrying" then return end
			local newRequestId = "fetch_" .. tostring(math.floor(tick() * 1000))
			currentFetchRequestId = newRequestId
			state.licensesStatus = "loading"
			refreshInventory()
			GetPlayerLicensesRE:FireServer(newRequestId)
		end)
	else
		state.licensesStatus = "error"
		state.buttonStates.retryLicenses = false
		showToast("Failed to load licenses after " .. LICENSE_MAX_RETRIES .. " attempts.")
		refreshInventory()
	end
end)

-- ============================================================
-- PLAYER LIST REFRESH ON JOIN/LEAVE
-- ============================================================
local playerAddedConn = Players.PlayerAdded:Connect(function(p)
	if playerListFrame.Visible then
		refreshPlayerList()
	end
end)
table.insert(connections, playerAddedConn)

local playerRemovingConn = Players.PlayerRemoving:Connect(function(p)
	if playerListFrame.Visible then
		refreshPlayerList()
	end
end)
table.insert(connections, playerRemovingConn)

-- ============================================================
-- INITIAL LOAD
-- ============================================================
fetchLicenses()
print("[TradeClient] Loaded with improvements: button debouncing, loading spinners, friendly disconnect messages, auto-refresh on completion")
