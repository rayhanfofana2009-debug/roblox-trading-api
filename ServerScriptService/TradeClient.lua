--[[
	TradeClient.lua
	Client-side trading orchestrator - slimmed from ~2000 lines to this.
	Lives in StarterPlayerScripts.Trade, alongside Controllers/ and UI/.

	CONFIDENCE KEY:
	  [VERIFIED]      taken directly from code you pasted, unchanged
	  [RECONSTRUCTED] inferred from strong evidence but not itself confirmed -
	                  verify against the monolith before trusting in production
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") -- [VERIFIED]

-- ============================================================
-- REMOTES  [VERIFIED - lines 35-41]
-- ============================================================
local GameRemotes = ReplicatedStorage:WaitForChild("GameRemotes")
local remotes = {
	sendTradeRequest = GameRemotes:WaitForChild("SendTradeRequest"),
	tradeRequestResponse = GameRemotes:WaitForChild("TradeRequestResponse"),
	tradeStarted = GameRemotes:WaitForChild("TradeStarted"),
	tradeUpdate = GameRemotes:WaitForChild("TradeUpdate"),
	tradeConfirm = GameRemotes:WaitForChild("TradeConfirm"),
	tradeCancelled = GameRemotes:WaitForChild("TradeCancelled"),
	getPlayerLicenses = GameRemotes:WaitForChild("GetPlayerLicenses"),
}

-- ============================================================
-- SHARED MODULES  [VERIFIED]
-- ============================================================
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local TradeState = require(SharedModules:WaitForChild("TradeState"))

-- ============================================================
-- TRADE-LOCAL MODULES  [VERIFIED constructor signatures]
-- ============================================================
local Controllers = script.Parent:WaitForChild("Controllers")
local UI = script.Parent:WaitForChild("UI")

local InventoryController = require(Controllers:WaitForChild("InventoryController"))
local OfferController = require(Controllers:WaitForChild("OfferController"))
local NotificationController = require(Controllers:WaitForChild("NotificationController"))
local SuccessController = require(Controllers:WaitForChild("SuccessController"))
local StatusController = require(Controllers:WaitForChild("StatusController"))
local TradeController = require(Controllers:WaitForChild("TradeController"))

local InventoryUI = require(UI:WaitForChild("InventoryUI"))
local OfferUI = require(UI:WaitForChild("OfferUI"))
local StatusUI = require(UI:WaitForChild("StatusUI"))
local SuccessUI = require(UI:WaitForChild("SuccessUI"))
local ToastUI = require(UI:WaitForChild("ToastUI"))
local TradeWindowUI = require(UI:WaitForChild("TradeWindowUI"))
local PlayerListUI = require(UI:WaitForChild("PlayerListUI"))

-- ============================================================
-- CONFIG  [VERIFIED - from your recap]
-- ============================================================
local CONFIG = {
	FetchTimeout = 30,
	ServerAckTimeout = 5,
	ButtonDebounce = 0.5,
	LicenseMaxRetries = 3,
	LicenseRetryDelays = { 6, 12, 20 },
	RequestTimeout = 30,
}

-- ============================================================
-- RUNTIME STATE  [VERIFIED - lines 88-106]
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
	licensesRetryCount = 0,
	licensesStatus = "idle",
	buttonStates = {
		ready = false,
		unready = false,
		confirm = false,
		cancel = false,
		retryLicenses = false,
	},
}

-- ============================================================
-- GUI CONSTRUCTION  [VERIFIED - lines 388-746 from monolith]
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
tradeButton.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
tradeButton.TextColor3 = Color3.fromRGB(240, 240, 240)
tradeButton.Text = "Trade [T]"
tradeButton.Font = Enum.Font.GothamSemibold
tradeButton.TextSize = 14
local corner1 = Instance.new("UICorner")
corner1.CornerRadius = UDim.new(0, 8)
corner1.Parent = tradeButton
local stroke1 = Instance.new("UIStroke")
stroke1.Color = Color3.fromRGB(0, 120, 200)
stroke1.Thickness = 2
stroke1.Parent = tradeButton
tradeButton.Parent = screenGui

-- Player List Frame
local playerListFrame = Instance.new("Frame")
playerListFrame.Name = "PlayerListFrame"
playerListFrame.Size = UDim2.new(0, 300, 0, 400)
playerListFrame.Position = UDim2.new(0.5, -150, 0.5, -200)
playerListFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
playerListFrame.BorderSizePixel = 0
playerListFrame.Visible = false
local corner2 = Instance.new("UICorner")
corner2.CornerRadius = UDim.new(0, 12)
corner2.Parent = playerListFrame
local stroke2 = Instance.new("UIStroke")
stroke2.Color = Color3.fromRGB(60, 60, 70)
stroke2.Thickness = 2
stroke2.Parent = playerListFrame
playerListFrame.Parent = screenGui

local playerListTitle = Instance.new("TextLabel")
playerListTitle.BackgroundTransparency = 1
playerListTitle.Text = "Select Player to Trade"
playerListTitle.Font = Enum.Font.GothamBold
playerListTitle.TextSize = 18
playerListTitle.TextColor3 = Color3.fromRGB(240, 240, 240)
playerListTitle.Size = UDim2.new(1, -50, 0, 40)
playerListTitle.Position = UDim2.new(0, 15, 0, 5)
playerListTitle.Parent = playerListFrame

local playerListClose = Instance.new("TextButton")
playerListClose.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
playerListClose.TextColor3 = Color3.fromRGB(240, 240, 240)
playerListClose.Text = "X"
playerListClose.Font = Enum.Font.GothamSemibold
playerListClose.TextSize = 16
playerListClose.Size = UDim2.new(0, 30, 0, 30)
playerListClose.Position = UDim2.new(1, -40, 0, 10)
local corner3 = Instance.new("UICorner")
corner3.CornerRadius = UDim.new(0, 6)
corner3.Parent = playerListClose
local stroke3 = Instance.new("UIStroke")
stroke3.Color = Color3.new(0, 0, 0)
stroke3.Thickness = 0
stroke3.Parent = playerListClose
playerListClose.Parent = playerListFrame

local playerScrollFrame = Instance.new("ScrollingFrame")
playerScrollFrame.Size = UDim2.new(1, -20, 1, -60)
playerScrollFrame.Position = UDim2.new(0, 10, 0, 50)
playerScrollFrame.BackgroundTransparency = 1
playerScrollFrame.BorderSizePixel = 0
playerScrollFrame.ScrollBarThickness = 4
playerScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
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
requestPopupFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
requestPopupFrame.BorderSizePixel = 0
requestPopupFrame.Visible = false
local corner4 = Instance.new("UICorner")
corner4.CornerRadius = UDim.new(0, 12)
corner4.Parent = requestPopupFrame
local stroke4 = Instance.new("UIStroke")
stroke4.Color = Color3.fromRGB(0, 170, 255)
stroke4.Thickness = 2
stroke4.Parent = requestPopupFrame
requestPopupFrame.Parent = screenGui

local requestTitle = Instance.new("TextLabel")
requestTitle.BackgroundTransparency = 1
requestTitle.Text = "Trade Request!"
requestTitle.Font = Enum.Font.GothamBold
requestTitle.TextSize = 20
requestTitle.TextColor3 = Color3.fromRGB(0, 170, 255)
requestTitle.Size = UDim2.new(1, 0, 0, 35)
requestTitle.Position = UDim2.new(0, 0, 0, 10)
requestTitle.TextXAlignment = Enum.TextXAlignment.Center
requestTitle.Parent = requestPopupFrame

local requestNameLabel = Instance.new("TextLabel")
requestNameLabel.BackgroundTransparency = 1
requestNameLabel.Text = ""
requestNameLabel.Font = Enum.Font.Gotham
requestNameLabel.TextSize = 16
requestNameLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
requestNameLabel.Size = UDim2.new(1, 0, 0, 25)
requestNameLabel.Position = UDim2.new(0, 0, 0, 50)
requestNameLabel.TextXAlignment = Enum.TextXAlignment.Center
requestNameLabel.Parent = requestPopupFrame

local requestTimerBar = Instance.new("Frame")
requestTimerBar.Size = UDim2.new(0.8, 0, 0, 4)
requestTimerBar.Position = UDim2.new(0.1, 0, 0, 85)
requestTimerBar.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
requestTimerBar.BorderSizePixel = 0
local corner5 = Instance.new("UICorner")
corner5.CornerRadius = UDim.new(0, 2)
corner5.Parent = requestTimerBar
requestTimerBar.Parent = requestPopupFrame

local requestBtnFrame = Instance.new("Frame")
requestBtnFrame.Size = UDim2.new(0.8, 0, 0, 40)
requestBtnFrame.Position = UDim2.new(0.1, 0, 1, -55)
requestBtnFrame.BackgroundTransparency = 1
requestBtnFrame.Parent = requestPopupFrame

local acceptBtn = Instance.new("TextButton")
acceptBtn.BackgroundColor3 = Color3.fromRGB(0, 200, 80)
acceptBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
acceptBtn.Text = "Accept"
acceptBtn.Font = Enum.Font.GothamSemibold
acceptBtn.TextSize = 16
acceptBtn.Size = UDim2.new(0.48, 0, 1, 0)
acceptBtn.Position = UDim2.new(0, 0, 0, 0)
local corner6 = Instance.new("UICorner")
corner6.CornerRadius = UDim.new(0, 6)
corner6.Parent = acceptBtn
local stroke6 = Instance.new("UIStroke")
stroke6.Color = Color3.new(0, 0, 0)
stroke6.Thickness = 0
stroke6.Parent = acceptBtn
acceptBtn.Parent = requestBtnFrame

local declineBtn = Instance.new("TextButton")
declineBtn.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
declineBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
declineBtn.Text = "Decline"
declineBtn.Font = Enum.Font.GothamSemibold
declineBtn.TextSize = 16
declineBtn.Size = UDim2.new(0.48, 0, 1, 0)
declineBtn.Position = UDim2.new(0.52, 0, 0, 0)
local corner7 = Instance.new("UICorner")
corner7.CornerRadius = UDim.new(0, 6)
corner7.Parent = declineBtn
local stroke7 = Instance.new("UIStroke")
stroke7.Color = Color3.new(0, 0, 0)
stroke7.Thickness = 0
stroke7.Parent = declineBtn
declineBtn.Parent = requestBtnFrame

-- ============================================================
-- PHASE 3-6: TRADE WINDOW
-- ============================================================
local tradeWindow = Instance.new("Frame")
tradeWindow.Name = "TradeWindow"
tradeWindow.Size = UDim2.new(0, 700, 0, 500)
tradeWindow.Position = UDim2.new(0.5, -350, 0.5, -250)
tradeWindow.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
tradeWindow.BorderSizePixel = 0
tradeWindow.Visible = false
local corner8 = Instance.new("UICorner")
corner8.CornerRadius = UDim.new(0, 12)
corner8.Parent = tradeWindow
local stroke8 = Instance.new("UIStroke")
stroke8.Color = Color3.fromRGB(60, 60, 70)
stroke8.Thickness = 2
stroke8.Parent = tradeWindow
tradeWindow.Parent = screenGui

-- Title bar
local tradeTitleBar = Instance.new("Frame")
tradeTitleBar.Size = UDim2.new(1, 0, 0, 45)
tradeTitleBar.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
tradeTitleBar.BorderSizePixel = 0
local corner9 = Instance.new("UICorner")
corner9.CornerRadius = UDim.new(0, 12)
corner9.Parent = tradeTitleBar
tradeTitleBar.Parent = tradeWindow

local tradeTitleLabel = Instance.new("TextLabel")
tradeTitleLabel.BackgroundTransparency = 1
tradeTitleLabel.Text = "Trading with ..."
tradeTitleLabel.Font = Enum.Font.GothamBold
tradeTitleLabel.TextSize = 16
tradeTitleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
tradeTitleLabel.Size = UDim2.new(1, -80, 1, 0)
tradeTitleLabel.Position = UDim2.new(0, 15, 0, 0)
tradeTitleLabel.Parent = tradeTitleBar

local tradeCloseBtn = Instance.new("TextButton")
tradeCloseBtn.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
tradeCloseBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
tradeCloseBtn.Text = "Cancel"
tradeCloseBtn.Font = Enum.Font.GothamSemibold
tradeCloseBtn.TextSize = 13
tradeCloseBtn.Size = UDim2.new(0, 70, 0, 28)
tradeCloseBtn.Position = UDim2.new(1, -80, 0.5, -14)
local corner10 = Instance.new("UICorner")
corner10.CornerRadius = UDim.new(0, 6)
corner10.Parent = tradeCloseBtn
local stroke10 = Instance.new("UIStroke")
stroke10.Color = Color3.new(0, 0, 0)
stroke10.Thickness = 0
stroke10.Parent = tradeCloseBtn
tradeCloseBtn.Parent = tradeTitleBar

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
inventoryPanel.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
inventoryPanel.BorderSizePixel = 0
local corner11 = Instance.new("UICorner")
corner11.CornerRadius = UDim.new(0, 8)
corner11.Parent = inventoryPanel
local stroke11 = Instance.new("UIStroke")
stroke11.Color = Color3.fromRGB(60, 60, 70)
stroke11.Thickness = 1
stroke11.Parent = inventoryPanel
inventoryPanel.Parent = tradeContent

local inventoryTitle = Instance.new("TextLabel")
inventoryTitle.BackgroundTransparency = 1
inventoryTitle.Text = "My Licenses"
inventoryTitle.Font = Enum.Font.GothamSemibold
inventoryTitle.TextSize = 14
inventoryTitle.TextColor3 = Color3.fromRGB(0, 170, 255)
inventoryTitle.Size = UDim2.new(1, 0, 0, 30)
inventoryTitle.Position = UDim2.new(0, 10, 0, 5)
inventoryTitle.Parent = inventoryPanel

local inventoryScroll = Instance.new("ScrollingFrame")
inventoryScroll.Size = UDim2.new(1, -10, 1, -40)
inventoryScroll.Position = UDim2.new(0, 5, 0, 35)
inventoryScroll.BackgroundTransparency = 1
inventoryScroll.BorderSizePixel = 0
inventoryScroll.ScrollBarThickness = 4
inventoryScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
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
myOfferFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
myOfferFrame.BorderSizePixel = 0
local corner12 = Instance.new("UICorner")
corner12.CornerRadius = UDim.new(0, 8)
corner12.Parent = myOfferFrame
local stroke12 = Instance.new("UIStroke")
stroke12.Color = Color3.fromRGB(60, 60, 70)
stroke12.Thickness = 1
stroke12.Parent = myOfferFrame
myOfferFrame.Parent = offersPanel

local myOfferTitle = Instance.new("TextLabel")
myOfferTitle.BackgroundTransparency = 1
myOfferTitle.Text = "Your Offer (0)"
myOfferTitle.Font = Enum.Font.GothamSemibold
myOfferTitle.TextSize = 13
myOfferTitle.TextColor3 = Color3.fromRGB(0, 200, 80)
myOfferTitle.Size = UDim2.new(1, 0, 0, 25)
myOfferTitle.Position = UDim2.new(0, 10, 0, 3)
myOfferTitle.Parent = myOfferFrame

local myOfferScroll = Instance.new("ScrollingFrame")
myOfferScroll.Size = UDim2.new(1, -10, 1, -30)
myOfferScroll.Position = UDim2.new(0, 5, 0, 28)
myOfferScroll.BackgroundTransparency = 1
myOfferScroll.BorderSizePixel = 0
myOfferScroll.ScrollBarThickness = 3
myOfferScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
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

local arrowLabel = Instance.new("TextLabel")
arrowLabel.BackgroundTransparency = 1
arrowLabel.Text = "⇓"
arrowLabel.Font = Enum.Font.GothamBold
arrowLabel.TextSize = 18
arrowLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
arrowLabel.Size = UDim2.new(1, 0, 1, 0)
arrowLabel.TextXAlignment = Enum.TextXAlignment.Center
arrowLabel.Parent = arrowFrame

-- Their Offer
local theirOfferFrame = Instance.new("Frame")
theirOfferFrame.Name = "TheirOfferFrame"
theirOfferFrame.Size = UDim2.new(1, 0, 0.48, -5)
theirOfferFrame.Position = UDim2.new(0, 0, 0.52, 5)
theirOfferFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
theirOfferFrame.BorderSizePixel = 0
local corner13 = Instance.new("UICorner")
corner13.CornerRadius = UDim.new(0, 8)
corner13.Parent = theirOfferFrame
local stroke13 = Instance.new("UIStroke")
stroke13.Color = Color3.fromRGB(60, 60, 70)
stroke13.Thickness = 1
stroke13.Parent = theirOfferFrame
theirOfferFrame.Parent = offersPanel

local theirOfferTitle = Instance.new("TextLabel")
theirOfferTitle.BackgroundTransparency = 1
theirOfferTitle.Text = "Their Offer (0)"
theirOfferTitle.Font = Enum.Font.GothamSemibold
theirOfferTitle.TextSize = 13
theirOfferTitle.TextColor3 = Color3.fromRGB(255, 200, 0)
theirOfferTitle.Size = UDim2.new(1, 0, 0, 25)
theirOfferTitle.Position = UDim2.new(0, 10, 0, 3)
theirOfferTitle.Parent = theirOfferFrame

local theirOfferScroll = Instance.new("ScrollingFrame")
theirOfferScroll.Size = UDim2.new(1, -10, 1, -30)
theirOfferScroll.Position = UDim2.new(0, 5, 0, 28)
theirOfferScroll.BackgroundTransparency = 1
theirOfferScroll.BorderSizePixel = 0
theirOfferScroll.ScrollBarThickness = 3
theirOfferScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
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
statusPanel.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
statusPanel.BorderSizePixel = 0
local corner14 = Instance.new("UICorner")
corner14.CornerRadius = UDim.new(0, 8)
corner14.Parent = statusPanel
local stroke14 = Instance.new("UIStroke")
stroke14.Color = Color3.fromRGB(60, 60, 70)
stroke14.Thickness = 1
stroke14.Parent = statusPanel
statusPanel.Parent = tradeContent

local statusTitle = Instance.new("TextLabel")
statusTitle.BackgroundTransparency = 1
statusTitle.Text = "Trade Status"
statusTitle.Font = Enum.Font.GothamSemibold
statusTitle.TextSize = 14
statusTitle.TextColor3 = Color3.fromRGB(0, 170, 255)
statusTitle.Size = UDim2.new(1, 0, 0, 30)
statusTitle.Position = UDim2.new(0, 10, 0, 5)
statusTitle.Parent = statusPanel

local myReadyLabel = Instance.new("TextLabel")
myReadyLabel.BackgroundTransparency = 1
myReadyLabel.Text = "✹ You: Not Ready"
myReadyLabel.Font = Enum.Font.Gotham
myReadyLabel.TextSize = 13
myReadyLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
myReadyLabel.Size = UDim2.new(1, -20, 0, 22)
myReadyLabel.Position = UDim2.new(0, 10, 0, 40)
myReadyLabel.Parent = statusPanel

local theirReadyLabel = Instance.new("TextLabel")
theirReadyLabel.BackgroundTransparency = 1
theirReadyLabel.Text = "✹ Partner: Not Ready"
theirReadyLabel.Font = Enum.Font.Gotham
theirReadyLabel.TextSize = 13
theirReadyLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
theirReadyLabel.Size = UDim2.new(1, -20, 0, 22)
theirReadyLabel.Position = UDim2.new(0, 10, 0, 65)
theirReadyLabel.Parent = statusPanel

local divider1 = Instance.new("Frame")
divider1.Size = UDim2.new(0.8, 0, 0, 1)
divider1.Position = UDim2.new(0.1, 0, 0, 92)
divider1.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
divider1.BorderSizePixel = 0
divider1.Parent = statusPanel

local myConfirmLabel = Instance.new("TextLabel")
myConfirmLabel.BackgroundTransparency = 1
myConfirmLabel.Text = "✹ You: Not Confirmed"
myConfirmLabel.Font = Enum.Font.Gotham
myConfirmLabel.TextSize = 13
myConfirmLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
myConfirmLabel.Size = UDim2.new(1, -20, 0, 22)
myConfirmLabel.Position = UDim2.new(0, 10, 0, 100)
myConfirmLabel.Parent = statusPanel

local theirConfirmLabel = Instance.new("TextLabel")
theirConfirmLabel.BackgroundTransparency = 1
theirConfirmLabel.Text = "✹ Partner: Not Confirmed"
theirConfirmLabel.Font = Enum.Font.Gotham
theirConfirmLabel.TextSize = 13
theirConfirmLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
theirConfirmLabel.Size = UDim2.new(1, -20, 0, 22)
theirConfirmLabel.Position = UDim2.new(0, 10, 0, 125)
theirConfirmLabel.Parent = statusPanel

local warningLabel = Instance.new("TextLabel")
warningLabel.BackgroundTransparency = 1
warningLabel.Text = ""
warningLabel.Font = Enum.Font.GothamMedium
warningLabel.TextSize = 11
warningLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
warningLabel.Size = UDim2.new(1, -20, 0, 50)
warningLabel.Position = UDim2.new(0, 10, 0, 155)
warningLabel.TextWrapped = true
warningLabel.Visible = false
warningLabel.Parent = statusPanel

-- BOTTOM: Action Buttons (Phase 6)
local actionFrame = Instance.new("Frame")
actionFrame.Size = UDim2.new(1, -20, 0, 45)
actionFrame.Position = UDim2.new(0, 10, 1, -55)
actionFrame.BackgroundTransparency = 1
actionFrame.Parent = tradeWindow

local readyBtn = Instance.new("TextButton")
readyBtn.BackgroundColor3 = Color3.fromRGB(0, 200, 80)
readyBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
readyBtn.Text = "Ready Up"
readyBtn.Font = Enum.Font.GothamSemibold
readyBtn.TextSize = 15
readyBtn.Size = UDim2.new(0.3, -5, 1, 0)
readyBtn.Position = UDim2.new(0.02, 0, 0, 0)
local corner15 = Instance.new("UICorner")
corner15.CornerRadius = UDim.new(0, 6)
corner15.Parent = readyBtn
local stroke15 = Instance.new("UIStroke")
stroke15.Color = Color3.new(0, 0, 0)
stroke15.Thickness = 0
stroke15.Parent = readyBtn
readyBtn.Parent = actionFrame

local unreadyBtn = Instance.new("TextButton")
unreadyBtn.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
unreadyBtn.TextColor3 = Color3.fromRGB(30, 30, 35)
unreadyBtn.Text = "Unready"
unreadyBtn.Font = Enum.Font.GothamSemibold
unreadyBtn.TextSize = 15
unreadyBtn.Size = UDim2.new(0.3, -5, 1, 0)
unreadyBtn.Position = UDim2.new(0.02, 0, 0, 0)
unreadyBtn.Visible = false
local corner16 = Instance.new("UICorner")
corner16.CornerRadius = UDim.new(0, 6)
corner16.Parent = unreadyBtn
local stroke16 = Instance.new("UIStroke")
stroke16.Color = Color3.new(0, 0, 0)
stroke16.Thickness = 0
stroke16.Parent = unreadyBtn
unreadyBtn.Parent = actionFrame

local confirmBtn = Instance.new("TextButton")
confirmBtn.BackgroundColor3 = Color3.fromRGB(255, 215, 0)
confirmBtn.TextColor3 = Color3.fromRGB(30, 30, 35)
confirmBtn.Text = "Confirm Trade"
confirmBtn.Font = Enum.Font.GothamSemibold
confirmBtn.TextSize = 15
confirmBtn.Size = UDim2.new(0.3, -5, 1, 0)
confirmBtn.Position = UDim2.new(0.35, 0, 0, 0)
confirmBtn.Visible = false
local corner17 = Instance.new("UICorner")
corner17.CornerRadius = UDim.new(0, 6)
corner17.Parent = confirmBtn
local stroke17 = Instance.new("UIStroke")
stroke17.Color = Color3.new(0, 0, 0)
stroke17.Thickness = 0
stroke17.Parent = confirmBtn
confirmBtn.Parent = actionFrame

-- ============================================================
-- PHASE 7: SUCCESS SCREEN
-- ============================================================
local successFrame = Instance.new("Frame")
successFrame.Name = "SuccessFrame"
successFrame.Size = UDim2.new(0, 400, 0, 300)
successFrame.Position = UDim2.new(0.5, -200, 0.5, -150)
successFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
successFrame.BorderSizePixel = 0
successFrame.Visible = false
local corner18 = Instance.new("UICorner")
corner18.CornerRadius = UDim.new(0, 12)
corner18.Parent = successFrame
local stroke18 = Instance.new("UIStroke")
stroke18.Color = Color3.fromRGB(50, 205, 50)
stroke18.Thickness = 2
stroke18.Parent = successFrame
successFrame.Parent = screenGui

local successTitle = Instance.new("TextLabel")
successTitle.BackgroundTransparency = 1
successTitle.Text = "Trade Complete!"
successTitle.Font = Enum.Font.GothamBold
successTitle.TextSize = 24
successTitle.TextColor3 = Color3.fromRGB(50, 205, 50)
successTitle.Size = UDim2.new(1, 0, 0, 40)
successTitle.Position = UDim2.new(0, 0, 0, 15)
successTitle.TextXAlignment = Enum.TextXAlignment.Center
successTitle.Parent = successFrame

local successSubtitle = Instance.new("TextLabel")
successSubtitle.BackgroundTransparency = 1
successSubtitle.Text = "You received:"
successSubtitle.Font = Enum.Font.Gotham
successSubtitle.TextSize = 14
successSubtitle.TextColor3 = Color3.fromRGB(160, 160, 170)
successSubtitle.Size = UDim2.new(1, 0, 0, 20)
successSubtitle.Position = UDim2.new(0, 0, 0, 55)
successSubtitle.TextXAlignment = Enum.TextXAlignment.Center
successSubtitle.Parent = successFrame

local successScroll = Instance.new("ScrollingFrame")
successScroll.Size = UDim2.new(0.9, 0, 0, 150)
successScroll.Position = UDim2.new(0.05, 0, 0, 80)
successScroll.BackgroundTransparency = 1
successScroll.BorderSizePixel = 0
successScroll.ScrollBarThickness = 4
successScroll.ScrollBarImageColor3 = Color3.fromRGB(0, 170, 255)
successScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
successScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
successScroll.Parent = successFrame

local successListLayout = Instance.new("UIListLayout")
successListLayout.SortOrder = Enum.SortOrder.LayoutOrder
successListLayout.Padding = UDim.new(0, 4)
successListLayout.Parent = successScroll

local successCloseBtn = Instance.new("TextButton")
successCloseBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
successCloseBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
successCloseBtn.Text = "Close"
successCloseBtn.Font = Enum.Font.GothamSemibold
successCloseBtn.TextSize = 14
successCloseBtn.Size = UDim2.new(0.5, 0, 0, 36)
successCloseBtn.Position = UDim2.new(0.25, 0, 1, -50)
local corner19 = Instance.new("UICorner")
corner19.CornerRadius = UDim.new(0, 6)
corner19.Parent = successCloseBtn
local stroke19 = Instance.new("UIStroke")
stroke19.Color = Color3.new(0, 0, 0)
stroke19.Thickness = 0
stroke19.Parent = successCloseBtn
successCloseBtn.Parent = successFrame

-- ============================================================
-- UI INSTANCES  [VERIFIED constructor signatures]
-- ============================================================
local inventoryUI = InventoryUI.new(inventoryScroll)
local offerUI = OfferUI.new(myOfferScroll, theirOfferScroll)
local statusUI = StatusUI.new({
	myReady = myReadyLabel,
	theirReady = theirReadyLabel,
	myConfirm = myConfirmLabel,
	theirConfirm = theirConfirmLabel,
	warning = warningLabel,
})
local successUI = SuccessUI.new(successFrame, successScroll)
local toastUI = ToastUI.new(screenGui)
local tradeWindowUI = TradeWindowUI.new({
	playerList = playerListFrame,
	requestPopup = requestPopupFrame,
	tradeWindow = tradeWindow,
	success = successFrame,
})
local playerListUI = PlayerListUI.new(playerScrollFrame)

-- ============================================================
-- CONTROLLER INSTANCES  [VERIFIED constructor signatures]
-- ============================================================
local notificationController = NotificationController.new(toastUI)
local successController = SuccessController.new(successUI)
local statusController = StatusController.new(statusUI)

local tradeControllerDeps = {
	remotes = remotes,
	config = CONFIG,
	httpService = HttpService,
	frames = {
		tradeWindow = tradeWindow,
		requestPopupFrame = requestPopupFrame,
		successFrame = successFrame,
		readyBtn = readyBtn,
		unreadyBtn = unreadyBtn,
		confirmBtn = confirmBtn,
		tradeCloseBtn = tradeCloseBtn,
		inventoryPanel = inventoryPanel,
		inventoryScroll = inventoryScroll,
	},
	state = state,
	notificationController = notificationController,
	statusController = statusController,
	playerListUI = playerListUI,
	inventoryController = nil,
	offerController = nil,
}

local tradeController = TradeController.new(tradeControllerDeps)

local sharedDeps = {
	TradeState = TradeState,
	state = state,
	notificationController = notificationController,
	resetReadyState = function() tradeController:ResetReadyState() end,
	tradeUpdateRE = remotes.tradeUpdate,
}

local inventoryController = InventoryController.new(inventoryUI, sharedDeps)
local offerController = OfferController.new(offerUI, sharedDeps)

tradeControllerDeps.inventoryController = inventoryController
tradeControllerDeps.offerController = offerController

-- ============================================================
-- REMOTE EVENT HANDLERS
-- ============================================================

-- Trade started (Phase 3)
remotes.tradeStarted.OnClientEvent:Connect(function(data)
	if not data or not data.tradeId or not data.partnerName then
		warn("[TradeClient] Invalid trade started data")
		return
	end
	
	if state.currentTradeId then
		warn("[TradeClient] Ignoring trade start - already in trade")
		return
	end
	
	state.currentTradeId = data.tradeId
	state.partnerName = data.partnerName
	state.partnerId = data.partnerId

	if TradeState.Set(TradeState.Trading) then
		tradeTitleLabel.Text = "Trading with " .. data.partnerName
		tradeWindowUI:ShowTradeWindow()
		tradeController.CurrentFetchRequestId = tradeController:FetchLicenses()
	end
end)

-- Trade update (state changes, Phase 5-6)
remotes.tradeUpdate.OnClientEvent:Connect(function(data)
	if not data or not data.tradeId then
		warn("[TradeClient] Invalid trade update data")
		return
	end
	
	if data.tradeId ~= state.currentTradeId then return end
	
	if data.action == "Completed" then
		tradeWindowUI:ShowSuccess()
		successController:Show(data.receivedLicenses or {})
		state.currentTradeId = nil
		if TradeState.Set(TradeState.Completed) then
			tradeController.CurrentFetchRequestId = tradeController:FetchLicenses()
		end
		return
	end

	if data.action == "ActionRejected" then
		if data.reason == "trade_locked" then
			notificationController:Show("Cannot unready - your partner has already confirmed.")
		end

		-- Clear whichever button's optimistic timeout this rejection answers
		if tradeController.ButtonTimeoutTasks and tradeController.ButtonTimeoutTasks.unready then
			task.cancel(tradeController.ButtonTimeoutTasks.unready)
			tradeController.ButtonTimeoutTasks.unready = nil
		end
		state.buttonStates.unready = false
		if unreadyBtn.Active == false then
			unreadyBtn.Active = true
			unreadyBtn.AutoButtonColor = true
		end

		return
	end

	state.myReady = data.myReady
	state.theirReady = data.theirReady
	state.myConfirmed = data.myConfirmed
	state.theirConfirmed = data.theirConfirmed

	-- Cancel ready button timeout and toggle visibility based on myReady state
	if tradeController.ButtonTimeoutTasks and tradeController.ButtonTimeoutTasks.ready then
		task.cancel(tradeController.ButtonTimeoutTasks.ready)
		tradeController.ButtonTimeoutTasks.ready = nil
	end
	state.buttonStates.ready = false
	readyBtn.Visible = not data.myReady
	unreadyBtn.Visible = data.myReady
	if readyBtn.Active == false then
		readyBtn.Active = true
		readyBtn.AutoButtonColor = true
	end
	if unreadyBtn.Active == false then
		unreadyBtn.Active = true
		unreadyBtn.AutoButtonColor = true
	end

	-- Cancel unready button timeout
	if tradeController.ButtonTimeoutTasks and tradeController.ButtonTimeoutTasks.unready then
		task.cancel(tradeController.ButtonTimeoutTasks.unready)
		tradeController.ButtonTimeoutTasks.unready = nil
	end
	state.buttonStates.unready = false

	-- Cancel confirm button timeout and toggle visibility based on myConfirmed state
	if tradeController.ButtonTimeoutTasks and tradeController.ButtonTimeoutTasks.confirm then
		task.cancel(tradeController.ButtonTimeoutTasks.confirm)
		tradeController.ButtonTimeoutTasks.confirm = nil
	end
	state.buttonStates.confirm = false
	-- Show confirm button when both players are ready
	confirmBtn.Visible = data.myReady and data.theirReady
	if confirmBtn.Active == false then
		confirmBtn.Active = true
		confirmBtn.AutoButtonColor = true
	end

	-- Transition to Ready state when both players are ready, back to Trading if not
	if data.myReady and data.theirReady then
		if TradeState.Get() == TradeState.Trading then
			TradeState.Set(TradeState.Ready)
		end
	else
		if TradeState.Get() == TradeState.Ready then
			TradeState.Set(TradeState.Trading)
		end
	end

	-- Transition to Confirming state when player confirms
	if data.myConfirmed then
		if TradeState.Get() == TradeState.Ready then
			TradeState.Set(TradeState.Confirming)
		end
	end

	offerController:SetOffers(data.myOfferedLicenses, data.theirOfferedLicenses)
	statusController:SetReady(data.myReady, data.theirReady)
	statusController:SetConfirmed(data.myConfirmed, data.theirConfirmed)
	inventoryController:Refresh(offerController.MyOffer)
end)

-- Trade cancelled
remotes.tradeCancelled.OnClientEvent:Connect(function(data)
	if not data then
		warn("[TradeClient] Invalid trade cancelled data")
		return
	end
	
	if data.tradeId and data.tradeId ~= state.currentTradeId then
		return
	end
	
	if data.reason == "player_left" then
		notificationController:Show("Trade cancelled.")
		notificationController:Show("The other player left the game.")
	elseif data.reason == "cancelled" then
		notificationController:Show("Trade was cancelled.")
	elseif data.reason == "timeout" then
		notificationController:Show("Trade timed out due to inactivity.")
	elseif data.reason == "validation_failed" then
		notificationController:Show("Trade validation failed.")
	else
		notificationController:Show("Trade ended: " .. tostring(data.reason))
	end
	
	if TradeState.Set(TradeState.Cancelled) then
		tradeController:ResetTradeUI()
	end
end)

-- Get player licenses response
remotes.getPlayerLicenses.OnClientEvent:Connect(function(requestId, data)
	if not requestId or requestId ~= tradeController.CurrentFetchRequestId then return end
	tradeController.CurrentFetchRequestId = nil

	if data and data.success and data.data then
		state.myLicenses = data.data.licenses or {}
		state.licensesRetryCount = 0
		state.licensesStatus = "idle"
		state.buttonStates.retryLicenses = false
		if tradeController.FetchTimeoutTask then
			task.cancel(tradeController.FetchTimeoutTask)
			tradeController.FetchTimeoutTask = nil
		end
		if TradeState.Get() == TradeState.LoadingInventory then
			TradeState.Set(TradeState.Idle)
		end
		inventoryController:Refresh(offerController.MyOffer)
	elseif state.licensesRetryCount < CONFIG.LicenseMaxRetries then
		state.licensesRetryCount += 1
		state.licensesStatus = "retrying"
		local delay = CONFIG.LicenseRetryDelays[state.licensesRetryCount] or 20
		notificationController:Show("Failed to load licenses. Retrying in " .. delay .. "s... (" .. state.licensesRetryCount .. "/" .. CONFIG.LicenseMaxRetries .. ")")
		inventoryController:Refresh(offerController.MyOffer)
		tradeController.RetryTask = task.delay(delay, function()
			if state.licensesStatus ~= "retrying" then return end
			local newRequestId = HttpService:GenerateGUID(false)
			tradeController.CurrentFetchRequestId = newRequestId
			state.licensesStatus = "loading"
			inventoryController:Refresh(offerController.MyOffer)
			remotes.getPlayerLicenses:FireServer(newRequestId)
			tradeController.RetryTask = nil
		end)
	else
		state.licensesStatus = "error"
		state.buttonStates.retryLicenses = false
		notificationController:Show("Failed to load licenses after " .. CONFIG.LicenseMaxRetries .. " attempts.")
		if TradeState.Get() == TradeState.LoadingInventory then
			TradeState.Set(TradeState.Idle)
		end
		inventoryController:Refresh(offerController.MyOffer)
	end
end)

-- ============================================================
-- PLAYER LIST / TRADE REQUEST FLOW
-- ============================================================
playerListUI.PlayerSelected = function(selectedPlayer)
	tradeController:SendTradeRequest(selectedPlayer.UserId)
	TradeState.Set(TradeState.WaitingForRequestResponse)
end

if tradeButton then
	tradeButton.MouseButton1Click:Connect(function()
		TradeState.Set(TradeState.SelectingPlayer)
		playerListUI:Clear()
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer ~= player then
				playerListUI:AddPlayer(otherPlayer)
			end
		end
		tradeWindowUI:ShowPlayerList()
	end)
end

playerListClose.MouseButton1Click:Connect(function()
	tradeWindowUI:HideAll()
	TradeState.Set(TradeState.Idle)
end)

successCloseBtn.MouseButton1Click:Connect(function()
	successController:Hide()
	TradeState.Set(TradeState.Idle)
end)

-- Phase 2: Accept/Decline
local currentRequestId = nil
local requestTimerConn = nil

acceptBtn.MouseButton1Click:Connect(function()
	if currentRequestId then
		tradeController:RespondToRequest(true, currentRequestId)
		tradeWindowUI:HideAll()
		currentRequestId = nil
		if requestTimerConn then
			requestTimerConn:Disconnect()
			requestTimerConn = nil
		end
	end
end)

declineBtn.MouseButton1Click:Connect(function()
	if declineBtn.Active == false then return end
	if currentRequestId then
		tradeController:RespondToRequest(false, currentRequestId)
		tradeWindowUI:HideAll()
		currentRequestId = nil
		if requestTimerConn then
			requestTimerConn:Disconnect()
			requestTimerConn = nil
		end
		TradeState.Set(TradeState.Idle)
	end
end)

-- Incoming trade request handler
remotes.sendTradeRequest.OnClientEvent:Connect(function(data)
	if not data or not data.requestId or not data.requesterName then
		warn("[TradeClient] Invalid trade request data")
		return
	end
	
	if state.currentTradeId then
		tradeController:RespondToRequest(false, data.requestId)
		return
	end

	currentRequestId = data.requestId
	requestNameLabel.Text = data.requesterName .. " wants to trade!"
	if TradeState.Set(TradeState.IncomingRequest) then
		tradeWindowUI:ShowRequestPopup()
	end

	requestTimerBar.Size = UDim2.new(0.8, 0, 0, 4)
	requestTimerBar.BackgroundColor3 = Color3.fromRGB(0, 170, 255)

	if requestTimerConn then
		requestTimerConn:Disconnect()
	end
	local startTime = tick()
	local timerDuration = CONFIG.RequestTimeout
	requestTimerConn = game:GetService("RunService").RenderStepped:Connect(function()
		local elapsed = tick() - startTime
		local remaining = 1 - (elapsed / timerDuration)
		if remaining <= 0 then
			requestTimerBar.Size = UDim2.new(0, 0, 0, 4)
			requestTimerBar.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
			if requestTimerConn then
				requestTimerConn:Disconnect()
				requestTimerConn = nil
			end
			if currentRequestId then
				tradeController:RespondToRequest(false, currentRequestId)
				currentRequestId = nil
				tradeWindowUI:HideAll()
				TradeState.Set(TradeState.Idle)
			end
			return
		end
		requestTimerBar.Size = UDim2.new(0.8 * remaining, 0, 0, 4)
		requestTimerBar.BackgroundColor3 = remaining < 0.3 and Color3.fromRGB(220, 50, 50) or Color3.fromRGB(0, 170, 255)
	end)
end)

-- Trade request response (for the requester)
remotes.tradeRequestResponse.OnClientEvent:Connect(function(data)
	if not data or type(data.accepted) ~= "boolean" then
		warn("[TradeClient] Invalid trade request response data")
		return
	end
	
	if data.accepted then
		notificationController:Show((data.targetName or "Player") .. " accepted your trade request!")
	else
		local reasons = {
			declined = (data.targetName or "Player") .. " declined your trade request",
			expired = "Trade request to " .. (data.targetName or "Player") .. " expired",
			busy = (data.targetName or "Player") .. " is already in a trade",
			already_in_trade = "You are already in a trade",
			target_in_trade = (data.targetName or "Player") .. " is already in a trade",
			superseded = "Your request to " .. (data.targetName or "Player") .. " was superseded",
		}
		notificationController:Show(reasons[data.reason] or "Trade request failed")
		TradeState.Set(TradeState.Idle)
	end
end)
