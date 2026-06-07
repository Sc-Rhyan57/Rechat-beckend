local cloneref = cloneref or clonereference or function(i) return i end
local protectgui = protectgui or (syn and syn.protect_gui) or function() end
local gethui = gethui or function() return cloneref(game:GetService("CoreGui")) end

if shared["alsllalslallalalalalallalallalalalla-chatenable"] then return end
shared["alsllalslallalalalalallalallalalalla-chatenable"] = true

local CHAT_ICON = "rbxassetid://132620481944192"
local API_URL = "https://rechatblox-q09s.onrender.com"

local HttpService       = cloneref(game:GetService("HttpService"))
local Players           = cloneref(game:GetService("Players"))
local StarterGui        = cloneref(game:GetService("StarterGui"))
local TextChatService   = cloneref(game:GetService("TextChatService"))
local UserInputService  = cloneref(game:GetService("UserInputService"))
local RunService        = cloneref(game:GetService("RunService"))
local TweenService      = cloneref(game:GetService("TweenService"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))

local Player    = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local JobId     = game.JobId
local PlaceId   = game.PlaceId

shared.ReChatSettings = shared.ReChatSettings or {
    DragEnabled = false,
    SendToRobloxChat = false,
    IgnoreRobloxChat = false,
    ChatPosition = UDim2.new(0, 10, 0.5, -125),
    UserColors = {}
}

local function GetGitImageID(link, name)
    local fileName = "rcb_img_" .. tostring(name) .. ".png"
    if isfile and isfile(fileName) then
        local getasset = getcustomasset or getsynasset
        if getasset then
            local ok, id = pcall(getasset, fileName)
            if ok and id then return id end
        end
    end
    local ok, data = pcall(function() return game:HttpGet(link) end)
    if not ok or not data or data == "" then return nil end
    if writefile then
        pcall(writefile, fileName, data)
    end
    local getasset = getcustomasset or getsynasset
    if getasset then
        local ok2, id = pcall(getasset, fileName)
        if ok2 and id then return id end
    end
    return nil
end

local function ResolveIcon(iconSource, name)
    if type(iconSource) == "string" then
        if iconSource:find("^rbxassetid://") or iconSource:match("^%d+$") then
            return iconSource:match("^%d+$") and ("rbxassetid://" .. iconSource) or iconSource
        end
        if iconSource:find("^http") then
            local id = GetGitImageID(iconSource, name or "icon")
            return id or ""
        end
    end
    return ""
end

local ResolvedChatIcon = ResolveIcon(CHAT_ICON, "chaticon")

local ExperienceChatStates = {}
local function HideExperienceChat()
    local coreGui = cloneref(game:GetService("CoreGui"))
    local expChat = coreGui:FindFirstChild("ExperienceChat")
    if expChat then
        for _, child in ipairs(expChat:GetDescendants()) do
            if child:IsA("ScreenGui") or child:IsA("Frame") or child:IsA("ScrollingFrame") then
                ExperienceChatStates[child] = child.Visible
                child.Visible = false
            end
        end
        ExperienceChatStates[expChat] = expChat.Enabled
        if expChat:IsA("ScreenGui") then
            expChat.Enabled = false
        end
    end
end

local function RestoreExperienceChat()
    for obj, state in pairs(ExperienceChatStates) do
        if obj and obj.Parent then
            if obj:IsA("ScreenGui") then
                obj.Enabled = state
            else
                obj.Visible = state
            end
        end
    end
    ExperienceChatStates = {}
end

HideExperienceChat()

local LastMessageTimestamp  = os.time() * 1000
local MessageCache          = {}
local CurrentChatVisible    = false
local ChatInputFocused      = false
local SendToRobloxChat      = shared.ReChatSettings.SendToRobloxChat
local JustSentToRoblox      = false
local IgnoreRobloxChat      = shared.ReChatSettings.IgnoreRobloxChat or false

local POLLING_INTERVAL     = 2
local MAX_MESSAGES         = 50
local CHAT_FADE_TIME       = 9
local BACKGROUND_FADE_TIME = 0.5
local HOLD_DURATION        = 0.5

local UnreadMessages      = 0
local PollingActive       = true
local PollingThread       = nil
local FadeThread          = nil
local LastInteractionTime = tick()
local IsChatWindowFaded   = false
local isDragging          = false
local dragToggleActive    = shared.ReChatSettings.DragEnabled
local holdTimer           = 0
local fadeOutTween        = nil
local fadeInTween         = nil
local isFading            = false
local dragOrigin, frameOrigin = nil, nil
local hasShownTutorial    = false

local function Request(url, method, body)
    local success, result = pcall(function()
        return request({
            Url = url,
            Method = method or "GET",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body and HttpService:JSONEncode(body) or nil
        })
    end)
    if success and result.StatusCode == 200 then
        return pcall(function() return HttpService:JSONDecode(result.Body) end)
    end
    return false, nil
end

StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)

if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    local chatWindowConfiguration = TextChatService:WaitForChild("ChatWindowConfiguration")
    local chatInputBarConfiguration = TextChatService:WaitForChild("ChatInputBarConfiguration")
    chatWindowConfiguration.Enabled = false
    chatInputBarConfiguration.Enabled = false
    if TextChatService:FindFirstChild("ChannelTabsConfiguration") then
        TextChatService.ChannelTabsConfiguration.Enabled = false
    end
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ReChatBlox"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 10
ScreenGui.IgnoreGuiInset = true

local ok = pcall(function()
    ScreenGui.Parent = gethui()
    protectgui(ScreenGui)
end)
if not ok or not ScreenGui.Parent then
    ScreenGui.Parent = PlayerGui
end

local TopBarGui = Instance.new("ScreenGui")
TopBarGui.Name = "ReChatTopBar"
TopBarGui.ResetOnSpawn = false
TopBarGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
TopBarGui.DisplayOrder = 7
TopBarGui.IgnoreGuiInset = true

local ok2 = pcall(function()
    TopBarGui.Parent = gethui()
    protectgui(TopBarGui)
end)
if not ok2 or not TopBarGui.Parent then
    TopBarGui.Parent = PlayerGui
end

local TopBarHolder = Instance.new("Frame")
TopBarHolder.Name = "ReChatTopBarHolder"
TopBarHolder.Size = UDim2.new(0, 44, 0, 44)
TopBarHolder.Position = UDim2.new(0, 16 + 44 + 8, 0, 10)
TopBarHolder.BackgroundTransparency = 1
TopBarHolder.BorderSizePixel = 0
TopBarHolder.ZIndex = 10
TopBarHolder.Parent = TopBarGui

local TopBarButton = Instance.new("ImageButton")
TopBarButton.Name = "ReChatIconBtn"
TopBarButton.AnchorPoint = Vector2.new(0.5, 0.5)
TopBarButton.Position = UDim2.new(0.5, 0, 0.5, 0)
TopBarButton.Size = UDim2.new(0, 36, 0, 36)
TopBarButton.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
TopBarButton.BackgroundTransparency = 0.08
TopBarButton.BorderSizePixel = 0
TopBarButton.Image = ResolvedChatIcon
TopBarButton.ImageColor3 = Color3.fromRGB(247, 247, 248)
TopBarButton.ScaleType = Enum.ScaleType.Fit
TopBarButton.ZIndex = 11
TopBarButton.AutoButtonColor = true
TopBarButton.Parent = TopBarHolder

local TBCorner = Instance.new("UICorner")
TBCorner.CornerRadius = UDim.new(1, 0)
TBCorner.Parent = TopBarButton

local TBPadding = Instance.new("UIPadding")
TBPadding.PaddingTop = UDim.new(0, 6)
TBPadding.PaddingBottom = UDim.new(0, 6)
TBPadding.PaddingLeft = UDim.new(0, 6)
TBPadding.PaddingRight = UDim.new(0, 6)
TBPadding.Parent = TopBarButton

local TBHighlighter = Instance.new("Frame")
TBHighlighter.Name = "Highlighter"
TBHighlighter.AnchorPoint = Vector2.new(0.5, 0.5)
TBHighlighter.Position = UDim2.new(0.5, 0, 0.5, 0)
TBHighlighter.Size = UDim2.new(1, 0, 1, 0)
TBHighlighter.BackgroundColor3 = Color3.fromRGB(208, 217, 251)
TBHighlighter.BackgroundTransparency = 0.92
TBHighlighter.BorderSizePixel = 0
TBHighlighter.Visible = false
TBHighlighter.ZIndex = 10
TBHighlighter.Parent = TopBarButton

local TBHLCorner = Instance.new("UICorner")
TBHLCorner.CornerRadius = UDim.new(1, 0)
TBHLCorner.Parent = TBHighlighter

local UnreadBadge = Instance.new("Frame")
UnreadBadge.Name = "UnreadBadge"
UnreadBadge.Size = UDim2.new(0, 18, 0, 18)
UnreadBadge.Position = UDim2.new(1, -4, 0, -4)
UnreadBadge.AnchorPoint = Vector2.new(1, 0)
UnreadBadge.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
UnreadBadge.BorderSizePixel = 0
UnreadBadge.Visible = false
UnreadBadge.ZIndex = 13
UnreadBadge.Parent = TopBarHolder

local BadgeCorner = Instance.new("UICorner")
BadgeCorner.CornerRadius = UDim.new(1, 0)
BadgeCorner.Parent = UnreadBadge

local UnreadLabel = Instance.new("TextLabel")
UnreadLabel.Size = UDim2.new(1, 0, 1, 0)
UnreadLabel.BackgroundTransparency = 1
UnreadLabel.Font = Enum.Font.GothamBold
UnreadLabel.Text = "0"
UnreadLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
UnreadLabel.TextSize = 10
UnreadLabel.TextScaled = true
UnreadLabel.ZIndex = 14
UnreadLabel.Parent = UnreadBadge

local ActionButtonsContainer = Instance.new("Frame")
ActionButtonsContainer.Name = "ActionButtons"
ActionButtonsContainer.Size = UDim2.new(0, 168, 0, 40)
ActionButtonsContainer.Position = UDim2.new(0, 16 + 44 + 8, 0, 58)
ActionButtonsContainer.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
ActionButtonsContainer.BackgroundTransparency = 0.08
ActionButtonsContainer.BorderSizePixel = 0
ActionButtonsContainer.Visible = false
ActionButtonsContainer.ZIndex = 10
ActionButtonsContainer.Parent = TopBarGui

local ACCorner = Instance.new("UICorner")
ACCorner.CornerRadius = UDim.new(0, 12)
ACCorner.Parent = ActionButtonsContainer

local ACLayout = Instance.new("UIListLayout")
ACLayout.FillDirection = Enum.FillDirection.Horizontal
ACLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
ACLayout.VerticalAlignment = Enum.VerticalAlignment.Center
ACLayout.Padding = UDim.new(0, 6)
ACLayout.SortOrder = Enum.SortOrder.LayoutOrder
ACLayout.Parent = ActionButtonsContainer

local ACPadding = Instance.new("UIPadding")
ACPadding.PaddingLeft = UDim.new(0, 8)
ACPadding.PaddingRight = UDim.new(0, 8)
ACPadding.Parent = ActionButtonsContainer

local function MakeActionBtn(icon, color, order, iconPad)
    local btn = Instance.new("ImageButton")
    btn.Size = UDim2.new(0, 32, 0, 32)
    btn.BackgroundColor3 = color
    btn.BackgroundTransparency = 0.2
    btn.BorderSizePixel = 0
    btn.Image = icon
    btn.ImageColor3 = Color3.fromRGB(247, 247, 248)
    btn.ScaleType = Enum.ScaleType.Fit
    btn.ZIndex = 11
    btn.LayoutOrder = order
    btn.AutoButtonColor = true
    btn.Parent = ActionButtonsContainer

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(1, 0)
    c.Parent = btn

    local p = Instance.new("UIPadding")
    local pad = iconPad or 6
    p.PaddingTop = UDim.new(0, pad)
    p.PaddingBottom = UDim.new(0, pad)
    p.PaddingLeft = UDim.new(0, pad)
    p.PaddingRight = UDim.new(0, pad)
    p.Parent = btn

    return btn
end

local DragButton        = MakeActionBtn("rbxassetid://7733992358",  Color3.fromRGB(60, 60, 60),     1, 7)
local ChatModeButton    = MakeActionBtn("rbxassetid://132620481944192", Color3.fromRGB(85, 170, 255), 2, 6)
local IgnoreRobloxButton= MakeActionBtn("rbxassetid://7733911816", Color3.fromRGB(170, 85, 255),  3, 6)
local CloseButton       = MakeActionBtn("rbxassetid://7733717447", Color3.fromRGB(200, 50, 50),   4, 7)

local ChatFrame = Instance.new("Frame")
ChatFrame.Name = "ChatFrame"
ChatFrame.Size = UDim2.new(0, 400, 0, 250)
ChatFrame.Position = shared.ReChatSettings.ChatPosition
ChatFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 21)
ChatFrame.BackgroundTransparency = 1
ChatFrame.BorderSizePixel = 0
ChatFrame.Visible = false
ChatFrame.Active = true
ChatFrame.ZIndex = 5
ChatFrame.Parent = ScreenGui

local CFCorner = Instance.new("UICorner")
CFCorner.CornerRadius = UDim.new(0, 14)
CFCorner.Parent = ChatFrame

local CFStroke = Instance.new("UIStroke")
CFStroke.Color = Color3.fromRGB(60, 60, 80)
CFStroke.Thickness = 1.5
CFStroke.Transparency = 0.5
CFStroke.Parent = ChatFrame

local TopBar = Instance.new("Frame")
TopBar.Name = "TopBar"
TopBar.Size = UDim2.new(1, 0, 0, 36)
TopBar.Position = UDim2.new(0, 0, 0, 0)
TopBar.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
TopBar.BackgroundTransparency = 1
TopBar.BorderSizePixel = 0
TopBar.ZIndex = 6
TopBar.Parent = ChatFrame

local TBCorner2 = Instance.new("UICorner")
TBCorner2.CornerRadius = UDim.new(0, 14)
TBCorner2.Parent = TopBar

local ChannelDot = Instance.new("Frame")
ChannelDot.Size = UDim2.new(0, 8, 0, 8)
ChannelDot.Position = UDim2.new(0, 12, 0.5, -4)
ChannelDot.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
ChannelDot.BorderSizePixel = 0
ChannelDot.ZIndex = 7
ChannelDot.Parent = TopBar

local CDCorner = Instance.new("UICorner")
CDCorner.CornerRadius = UDim.new(1, 0)
CDCorner.Parent = ChannelDot

local ChannelLabel = Instance.new("TextLabel")
ChannelLabel.Size = UDim2.new(1, -30, 1, 0)
ChannelLabel.Position = UDim2.new(0, 26, 0, 0)
ChannelLabel.BackgroundTransparency = 1
ChannelLabel.Text = "ReChat · General"
ChannelLabel.TextColor3 = Color3.fromRGB(247, 247, 248)
ChannelLabel.TextXAlignment = Enum.TextXAlignment.Left
ChannelLabel.Font = Enum.Font.GothamBold
ChannelLabel.TextSize = 13
ChannelLabel.ZIndex = 7
ChannelLabel.Parent = TopBar

local MessageScroll = Instance.new("ScrollingFrame")
MessageScroll.Name = "MessageScroll"
MessageScroll.Size = UDim2.new(1, -10, 1, -86)
MessageScroll.Position = UDim2.new(0, 5, 0, 40)
MessageScroll.BackgroundTransparency = 1
MessageScroll.BorderSizePixel = 0
MessageScroll.ScrollBarThickness = 3
MessageScroll.ScrollBarImageColor3 = Color3.fromRGB(208, 217, 251)
MessageScroll.ScrollBarImageTransparency = 0.6
MessageScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
MessageScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
MessageScroll.ScrollingDirection = Enum.ScrollingDirection.Y
MessageScroll.ZIndex = 6
MessageScroll.Parent = ChatFrame

local MessageLayout = Instance.new("UIListLayout")
MessageLayout.Padding = UDim.new(0, 2)
MessageLayout.SortOrder = Enum.SortOrder.LayoutOrder
MessageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
MessageLayout.Parent = MessageScroll

local InputContainer = Instance.new("Frame")
InputContainer.Name = "InputContainer"
InputContainer.Size = UDim2.new(1, -10, 0, 38)
InputContainer.Position = UDim2.new(0, 5, 1, -43)
InputContainer.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
InputContainer.BackgroundTransparency = 1
InputContainer.BorderSizePixel = 0
InputContainer.ZIndex = 6
InputContainer.Parent = ChatFrame

local ICCorner = Instance.new("UICorner")
ICCorner.CornerRadius = UDim.new(0, 10)
ICCorner.Parent = InputContainer

local ICStroke = Instance.new("UIStroke")
ICStroke.Color = Color3.fromRGB(80, 80, 120)
ICStroke.Thickness = 1
ICStroke.Transparency = 0.6
ICStroke.Parent = InputContainer

local HoverDetector = Instance.new("Frame")
HoverDetector.Size = UDim2.new(1, 0, 1, 0)
HoverDetector.BackgroundTransparency = 1
HoverDetector.BorderSizePixel = 0
HoverDetector.ZIndex = 7
HoverDetector.Active = true
HoverDetector.Parent = InputContainer

local ChatInputBox = Instance.new("TextBox")
ChatInputBox.Name = "ChatInputBox"
ChatInputBox.Size = UDim2.new(1, -12, 1, -8)
ChatInputBox.Position = UDim2.new(0, 6, 0, 4)
ChatInputBox.BackgroundTransparency = 1
ChatInputBox.Text = ""
ChatInputBox.PlaceholderText = "Enviar mensagem..."
ChatInputBox.TextColor3 = Color3.fromRGB(247, 247, 248)
ChatInputBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 140)
ChatInputBox.Font = Enum.Font.Gotham
ChatInputBox.TextSize = 14
ChatInputBox.TextXAlignment = Enum.TextXAlignment.Left
ChatInputBox.ClearTextOnFocus = false
ChatInputBox.TextWrapped = false
ChatInputBox.ZIndex = 8
ChatInputBox.Parent = InputContainer

local function SetCore(name, value)
    repeat
        local ok = pcall(function() StarterGui:SetCore(name, value) end)
        if not ok then task.wait() end
    until ok
end

local function ShowNotification(title, text, duration)
    SetCore("SendNotification", { Title = title, Text = text, Duration = duration or 3 })
end

local function UpdateDragButton()
    DragButton.BackgroundColor3 = dragToggleActive and Color3.fromRGB(60, 200, 60) or Color3.fromRGB(60, 60, 60)
end

local function UpdateChatModeButton()
    if SendToRobloxChat then
        ChatModeButton.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        ChatModeButton.Image = "rbxassetid://137202017384658"
    else
        ChatModeButton.BackgroundColor3 = Color3.fromRGB(85, 170, 255)
        ChatModeButton.Image = "rbxassetid://132620481944192"
    end
end

local function UpdateIgnoreRobloxButton()
    IgnoreRobloxButton.BackgroundColor3 = IgnoreRobloxChat and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(170, 85, 255)
end

ChatModeButton.MouseButton1Click:Connect(function()
    SendToRobloxChat = not SendToRobloxChat
    shared.ReChatSettings.SendToRobloxChat = SendToRobloxChat
    UpdateChatModeButton()
end)

IgnoreRobloxButton.MouseButton1Click:Connect(function()
    IgnoreRobloxChat = not IgnoreRobloxChat
    shared.ReChatSettings.IgnoreRobloxChat = IgnoreRobloxChat
    UpdateIgnoreRobloxButton()
    ShowNotification("ReChat", IgnoreRobloxChat and "Ignorando mensagens Roblox" or "Mostrando mensagens Roblox", 2)
end)

DragButton.MouseButton1Click:Connect(function()
    dragToggleActive = not dragToggleActive
    shared.ReChatSettings.DragEnabled = dragToggleActive
    UpdateDragButton()
    ShowNotification("ReChat", dragToggleActive and "Modo arrastar ativado!" or "Modo arrastar desativado", 2)
end)

ChatFrame.InputBegan:Connect(function(input)
    if not dragToggleActive then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        isDragging = true
        dragOrigin = input.Position
        frameOrigin = ChatFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                isDragging = false
                shared.ReChatSettings.ChatPosition = ChatFrame.Position
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if isDragging and dragToggleActive and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local movement = input.Position - dragOrigin
        ChatFrame.Position = UDim2.new(frameOrigin.X.Scale, frameOrigin.X.Offset + movement.X, frameOrigin.Y.Scale, frameOrigin.Y.Offset + movement.Y)
    end
end)

local function UpdateUnreadBadge()
    if UnreadMessages > 0 and not CurrentChatVisible then
        UnreadBadge.Visible = true
        UnreadLabel.Text = UnreadMessages > 99 and "99+" or tostring(math.min(UnreadMessages, 99))
        TweenService:Create(UnreadBadge, TweenInfo.new(0.25, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {Size = UDim2.new(0, 20, 0, 20)}):Play()
        task.wait(0.25)
        TweenService:Create(UnreadBadge, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, 18, 0, 18)}):Play()
    else
        UnreadBadge.Visible = false
    end
end

local function UpdateButtonHighlight()
    TBHighlighter.Visible = CurrentChatVisible
    if CurrentChatVisible then
        TweenService:Create(TopBarButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(30, 30, 40)}):Play()
    else
        TweenService:Create(TopBarButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(18, 18, 21)}):Play()
    end
end

local function SetAllTextTransparency(value)
    for _, child in ipairs(MessageScroll:GetChildren()) do
        if child:IsA("Frame") then
            for _, label in ipairs(child:GetChildren()) do
                if label:IsA("TextLabel") then
                    label.TextTransparency = value
                end
            end
        end
    end
end

local function FadeChatWindow(fadeOut)
    if not CurrentChatVisible then return end
    local bgT   = fadeOut and 1 or 0.15
    local topT  = fadeOut and 1 or 0.1
    local inpT  = fadeOut and 1 or 0.1
    local txtT  = fadeOut and 1 or 0

    TweenService:Create(ChatFrame,      TweenInfo.new(BACKGROUND_FADE_TIME), {BackgroundTransparency = bgT}):Play()
    TweenService:Create(TopBar,         TweenInfo.new(BACKGROUND_FADE_TIME), {BackgroundTransparency = topT}):Play()
    TweenService:Create(InputContainer, TweenInfo.new(BACKGROUND_FADE_TIME), {BackgroundTransparency = inpT}):Play()

    for _, child in ipairs(MessageScroll:GetChildren()) do
        if child:IsA("Frame") then
            for _, label in ipairs(child:GetChildren()) do
                if label:IsA("TextLabel") then
                    TweenService:Create(label, TweenInfo.new(BACKGROUND_FADE_TIME), {TextTransparency = txtT}):Play()
                end
            end
        end
    end

    IsChatWindowFaded = fadeOut
end

local function ResetFadeTimer()
    LastInteractionTime = tick()
    if IsChatWindowFaded and CurrentChatVisible then
        FadeChatWindow(false)
    end
end

local function SetChatActive(active, instant, skipFocus)
    if fadeOutTween then fadeOutTween:Cancel(); fadeOutTween = nil end
    if fadeInTween  then fadeInTween:Cancel();  fadeInTween  = nil end

    CurrentChatVisible = active
    isFading = false

    UpdateButtonHighlight()

    if active then
        ChatFrame.Visible = true
        UnreadMessages = 0
        UpdateUnreadBadge()
        IsChatWindowFaded = false
        ResetFadeTimer()
        ActionButtonsContainer.Visible = dragToggleActive

        if not instant then
            isFading = true
            fadeInTween = TweenService:Create(ChatFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.15})
            fadeInTween.Completed:Connect(function() isFading = false end)
            fadeInTween:Play()
            TweenService:Create(TopBar,         TweenInfo.new(0.18), {BackgroundTransparency = 0.1}):Play()
            TweenService:Create(InputContainer, TweenInfo.new(0.18), {BackgroundTransparency = 0.1}):Play()
            for _, child in ipairs(MessageScroll:GetChildren()) do
                if child:IsA("Frame") then
                    for _, label in ipairs(child:GetChildren()) do
                        if label:IsA("TextLabel") then
                            TweenService:Create(label, TweenInfo.new(0.18), {TextTransparency = 0}):Play()
                        end
                    end
                end
            end
        else
            ChatFrame.BackgroundTransparency = 0.15
            TopBar.BackgroundTransparency = 0.1
            InputContainer.BackgroundTransparency = 0.1
            SetAllTextTransparency(0)
        end

        if not skipFocus then ChatInputBox:CaptureFocus() end
    else
        if not dragToggleActive then ActionButtonsContainer.Visible = false end

        if not instant then
            isFading = true
            fadeOutTween = TweenService:Create(ChatFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
            TweenService:Create(TopBar,         TweenInfo.new(0.25), {BackgroundTransparency = 1}):Play()
            TweenService:Create(InputContainer, TweenInfo.new(0.25), {BackgroundTransparency = 1}):Play()
            for _, child in ipairs(MessageScroll:GetChildren()) do
                if child:IsA("Frame") then
                    for _, label in ipairs(child:GetChildren()) do
                        if label:IsA("TextLabel") then
                            TweenService:Create(label, TweenInfo.new(0.25), {TextTransparency = 1}):Play()
                        end
                    end
                end
            end
            fadeOutTween.Completed:Connect(function()
                isFading = false
                if not CurrentChatVisible then ChatFrame.Visible = false end
            end)
            fadeOutTween:Play()
        else
            ChatFrame.BackgroundTransparency = 1
            TopBar.BackgroundTransparency = 1
            InputContainer.BackgroundTransparency = 1
            SetAllTextTransparency(1)
            ChatFrame.Visible = false
            isFading = false
        end

        ChatInputBox:ReleaseFocus()
    end

    SetCore("ChatActive", active)
end

local function ToggleChatVisibility()
    SetChatActive(not CurrentChatVisible, false)
end

local function InitSession()
    local ok, response = Request(API_URL .. "/api/v1/chat/init", "POST", {
        userId = tostring(Player.UserId),
        username = Player.Name,
        displayName = Player.DisplayName,
        jobId = JobId,
        placeId = tostring(PlaceId)
    })
    return ok and response and response.success
end

local function GetNewMessages()
    local url = API_URL .. "/api/v1/chat/messages?jobId=" .. JobId .. "&chatType=general&limit=50"
    if LastMessageTimestamp > 0 then
        url = url .. "&after=" .. LastMessageTimestamp
    end
    local ok, response = Request(url, "GET")
    if ok and response and response.success then
        return response.messages
    end
    return {}
end

local function SendMessage(message)
    local ok, response = Request(API_URL .. "/api/v1/chat/send", "POST", {
        userId = tostring(Player.UserId),
        username = Player.Name,
        displayName = Player.DisplayName,
        jobId = JobId,
        message = message,
        chatType = "general"
    })
    if ok and response then
        return response.success, response.message, response.messageData
    end
    return false, "Falha ao enviar", nil
end

local function SendToRoblox(message)
    JustSentToRoblox = true
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            TextChatService.TextChannels.RBXGeneral:SendAsync(message)
        else
            ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(message, "All")
        end
    end)
    task.wait(0.5)
    JustSentToRoblox = false
end

local function CleanupOldMessages()
    local messages = {}
    for _, child in ipairs(MessageScroll:GetChildren()) do
        if child:IsA("Frame") and child:GetAttribute("MessageTimestamp") then
            table.insert(messages, child)
        end
    end
    if #messages > MAX_MESSAGES then
        table.sort(messages, function(a, b) return a:GetAttribute("MessageTimestamp") < b:GetAttribute("MessageTimestamp") end)
        for i = 1, #messages - MAX_MESSAGES do
            messages[i]:Destroy()
        end
    end
end

local function GetUserColor(username)
    if not shared.ReChatSettings.UserColors[username] then
        local hash = 0
        for i = 1, #username do hash = hash + string.byte(username, i) * i end
        local hue = (hash % 360) / 360
        local function hsvToRgb(h, s, v)
            local c = v * s
            local x = c * (1 - math.abs((h * 6) % 2 - 1))
            local m = v - c
            local r, g, b = 0, 0, 0
            if h < 1/6 then r,g,b=c,x,0 elseif h < 2/6 then r,g,b=x,c,0
            elseif h < 3/6 then r,g,b=0,c,x elseif h < 4/6 then r,g,b=0,x,c
            elseif h < 5/6 then r,g,b=x,0,c else r,g,b=c,0,x end
            return math.floor((r+m)*255), math.floor((g+m)*255), math.floor((b+m)*255)
        end
        local r, g, b = hsvToRgb(hue, 0.65, 0.9)
        shared.ReChatSettings.UserColors[username] = string.format("rgb(%d,%d,%d)", r, g, b)
    end
    return shared.ReChatSettings.UserColors[username]
end

local function CreateMessageLabel(username, displayName, message, isSystem, isRobloxChat)
    local timestamp = tick()

    local Container = Instance.new("Frame")
    Container.Size = UDim2.new(1, -10, 0, 0)
    Container.AutomaticSize = Enum.AutomaticSize.Y
    Container.BackgroundTransparency = 1
    Container.BorderSizePixel = 0
    Container.LayoutOrder = #MessageScroll:GetChildren()
    Container.ZIndex = 6
    Container:SetAttribute("MessageTimestamp", timestamp)
    Container.Parent = MessageScroll

    local MessageLabel = Instance.new("TextLabel")
    MessageLabel.Size = UDim2.new(1, 0, 0, 0)
    MessageLabel.AutomaticSize = Enum.AutomaticSize.Y
    MessageLabel.BackgroundTransparency = 1
    MessageLabel.BorderSizePixel = 0
    MessageLabel.TextXAlignment = Enum.TextXAlignment.Left
    MessageLabel.TextYAlignment = Enum.TextYAlignment.Top
    MessageLabel.Font = Enum.Font.Gotham
    MessageLabel.TextSize = 14
    MessageLabel.TextWrapped = true
    MessageLabel.RichText = true
    MessageLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
    MessageLabel.TextTransparency = IsChatWindowFaded and 1 or 0
    MessageLabel.ZIndex = 7
    MessageLabel.Parent = Container

    if isSystem then
        MessageLabel.Text = string.format("<font color='rgb(255,200,60)'><b>[Sistema]</b></font> <font color='rgb(180,180,200)'>%s</font>", message)
    elseif isRobloxChat then
        local userColor = GetUserColor(username)
        MessageLabel.Text = string.format("<font color='rgb(150,150,170)'>[Roblox]</font> <font color='%s'><b>%s:</b></font> <font color='rgb(210,210,220)'>%s</font>", userColor, displayName or username, message)
    else
        local userColor = GetUserColor(username)
        MessageLabel.Text = string.format("<font color='%s'><b>%s:</b></font> <font color='rgb(220,220,230)'>%s</font>", userColor, displayName or username, message)
    end

    CleanupOldMessages()
    task.wait(0.01)
    MessageScroll.CanvasPosition = Vector2.new(0, MessageScroll.AbsoluteCanvasSize.Y)

    return Container
end

local function AddSystemMessage(text)
    CreateMessageLabel("", "", text, true, false)
end

local function AddChatMessage(username, displayName, message, isRobloxChat)
    CreateMessageLabel(username, displayName, message, false, isRobloxChat or false)

    if CurrentChatVisible and IsChatWindowFaded then
        FadeChatWindow(false)
        ResetFadeTimer()
    end

    local character = Players:FindFirstChild(username)
    if character and character:IsA("Player") and not isRobloxChat then
        local char = character.Character
        if char and char:FindFirstChild("Head") then
            task.spawn(function()
                pcall(function()
                    game:GetService("Chat"):Chat(char.Head, message, Enum.ChatColor.White)
                end)
            end)
        end
    end
end

local function HandleIncomingMessage(msg)
    if not msg or not msg.id then return end
    if MessageCache[msg.id] then return end
    MessageCache[msg.id] = true
    LastMessageTimestamp = math.max(LastMessageTimestamp, msg.timestamp)

    if msg.userId ~= tostring(Player.UserId) then
        AddChatMessage(msg.username, msg.displayName, msg.message)
        if not CurrentChatVisible then
            UnreadMessages = UnreadMessages + 1
            UpdateUnreadBadge()
        end
    end
end

CloseButton.MouseButton1Click:Connect(function()
    local ConfirmationFrame = Instance.new("Frame")
    ConfirmationFrame.Name = "ConfirmationPopup"
    ConfirmationFrame.Size = UDim2.new(0, 280, 0, 140)
    ConfirmationFrame.Position = UDim2.new(0.5, -140, 0.5, -70)
    ConfirmationFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
    ConfirmationFrame.BorderSizePixel = 0
    ConfirmationFrame.ZIndex = 20
    ConfirmationFrame.Parent = ScreenGui

    local CFConfCorner = Instance.new("UICorner")
    CFConfCorner.CornerRadius = UDim.new(0, 14)
    CFConfCorner.Parent = ConfirmationFrame

    local CFConfStroke = Instance.new("UIStroke")
    CFConfStroke.Color = Color3.fromRGB(200, 50, 50)
    CFConfStroke.Thickness = 1.5
    CFConfStroke.Parent = ConfirmationFrame

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, -20, 0, 36)
    TitleLabel.Position = UDim2.new(0, 10, 0, 8)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = "Fechar ReChat?"
    TitleLabel.TextColor3 = Color3.fromRGB(247, 247, 248)
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextSize = 16
    TitleLabel.ZIndex = 21
    TitleLabel.Parent = ConfirmationFrame

    local SubLabel = Instance.new("TextLabel")
    SubLabel.Size = UDim2.new(1, -20, 0, 28)
    SubLabel.Position = UDim2.new(0, 10, 0, 44)
    SubLabel.BackgroundTransparency = 1
    SubLabel.Text = "Tem certeza que deseja encerrar o chat?"
    SubLabel.TextColor3 = Color3.fromRGB(160, 160, 180)
    SubLabel.Font = Enum.Font.Gotham
    SubLabel.TextSize = 12
    SubLabel.TextWrapped = true
    SubLabel.ZIndex = 21
    SubLabel.Parent = ConfirmationFrame

    local YesButton = Instance.new("TextButton")
    YesButton.Size = UDim2.new(0, 118, 0, 32)
    YesButton.Position = UDim2.new(0, 10, 1, -42)
    YesButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    YesButton.BorderSizePixel = 0
    YesButton.Text = "Sim, fechar"
    YesButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    YesButton.Font = Enum.Font.GothamBold
    YesButton.TextSize = 13
    YesButton.ZIndex = 21
    YesButton.Parent = ConfirmationFrame

    local YCorner = Instance.new("UICorner")
    YCorner.CornerRadius = UDim.new(0, 8)
    YCorner.Parent = YesButton

    local NoButton = Instance.new("TextButton")
    NoButton.Size = UDim2.new(0, 118, 0, 32)
    NoButton.Position = UDim2.new(1, -128, 1, -42)
    NoButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    NoButton.BorderSizePixel = 0
    NoButton.Text = "Cancelar"
    NoButton.TextColor3 = Color3.fromRGB(200, 200, 210)
    NoButton.Font = Enum.Font.GothamBold
    NoButton.TextSize = 13
    NoButton.ZIndex = 21
    NoButton.Parent = ConfirmationFrame

    local NCorner = Instance.new("UICorner")
    NCorner.CornerRadius = UDim.new(0, 8)
    NCorner.Parent = NoButton

    YesButton.MouseButton1Click:Connect(function()
        PollingActive = false
        shared["alsllalslallalalalalallalallalalalla-chatenable"] = false
        if PollingThread then pcall(function() coroutine.close(PollingThread) end) end
        if FadeThread    then pcall(function() coroutine.close(FadeThread) end) end
        RestoreExperienceChat()
        if ScreenGui then ScreenGui:Destroy() end
        if TopBarGui then TopBarGui:Destroy() end
    end)

    NoButton.MouseButton1Click:Connect(function()
        ConfirmationFrame:Destroy()
    end)
end)

TopBarButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        holdTimer = 0
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            holdTimer = holdTimer + dt
            if holdTimer >= HOLD_DURATION then
                conn:Disconnect()
                ActionButtonsContainer.Visible = true
            end
        end)
        local endConn
        endConn = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                conn:Disconnect()
                endConn:Disconnect()
                if holdTimer < HOLD_DURATION then
                    ActionButtonsContainer.Visible = false
                    ToggleChatVisibility()
                end
            end
        end)
    end
end)

ChatFrame.MouseEnter:Connect(function() ResetFadeTimer() end)
MessageScroll.MouseEnter:Connect(function() ResetFadeTimer() end)
HoverDetector.MouseEnter:Connect(function() ResetFadeTimer() end)
HoverDetector.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then ResetFadeTimer() end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.Slash then
        if not CurrentChatVisible then
            SetChatActive(true, false)
            if not hasShownTutorial then
                ShowNotification("ReChat", "Segure '/' ou o botão do chat para mais opções!", 8)
                hasShownTutorial = true
            end
        else
            ChatInputBox:CaptureFocus()
        end
        ResetFadeTimer()
    elseif input.KeyCode == Enum.KeyCode.Escape then
        if CurrentChatVisible then SetChatActive(false, false) end
        if not dragToggleActive then ActionButtonsContainer.Visible = false end
    end
end)

ChatInputBox.FocusLost:Connect(function(enterPressed)
    ChatInputFocused = false
    if enterPressed and ChatInputBox.Text ~= "" then
        local message = ChatInputBox.Text
        ChatInputBox.Text = ""

        if SendToRobloxChat then
            SendToRoblox(message)
            AddChatMessage(Player.Name, Player.DisplayName, message, true)
        else
            local ok, responseMsg, messageData = SendMessage(message)
            if ok and messageData then
                MessageCache[messageData.id] = true
                AddChatMessage(messageData.username, messageData.displayName, messageData.message)
                if messageData.timestamp then
                    LastMessageTimestamp = math.max(LastMessageTimestamp, messageData.timestamp)
                end
            elseif ok and not messageData then
                local fakeId = tostring(tick())
                MessageCache[fakeId] = true
                AddChatMessage(Player.Name, Player.DisplayName, message)
            else
                AddSystemMessage(responseMsg or "Falha ao enviar mensagem")
            end
        end

        ResetFadeTimer()
    end
end)

ChatInputBox.Focused:Connect(function()
    ChatInputFocused = true
    ResetFadeTimer()
    if not CurrentChatVisible then SetChatActive(true, false) end
end)

local function InitializeChat()
    AddSystemMessage("ReChat Blox — Conectando...")

    if not InitSession() then
        AddSystemMessage("Falha ao inicializar sessão!")
        return
    end

    AddSystemMessage("Conectado ao ReChat Blox!")
    AddSystemMessage("Pressione '/' ou clique no botão para abrir")
    AddSystemMessage("<b>Script por <font color='rgb(255,20,147)'>@rhyan57</font> e <font color='rgb(255,20,147)'>@loldog</font></b>")
    AddSystemMessage("Discord: <font color='rgb(119,133,204)'>https://discord.gg/Pfmqq79q9Q</font>")

    for _, player in ipairs(Players:GetPlayers()) do
        if player.UserId == 3274233701 then
            AddSystemMessage("<font color='rgb(255,165,0)'>Administrador </font><font color='rgb(255,20,147)'>@rhyan57</font><font color='rgb(255,165,0)'> entrou no chat.</font>")
            break
        end
    end

    local function OnChatted(player, message)
        if JustSentToRoblox and player == Player then return end
        if not IgnoreRobloxChat then
            AddChatMessage(player.Name, player.DisplayName, message, true)
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        player.Chatted:Connect(function(msg) OnChatted(player, msg) end)
    end

    Players.PlayerAdded:Connect(function(player)
        player.Chatted:Connect(function(msg) OnChatted(player, msg) end)
        if player.UserId == 3274233701 then
            AddSystemMessage("<font color='rgb(255,165,0)'>Administrador </font><font color='rgb(255,20,147)'>@rhyan57</font><font color='rgb(255,165,0)'> entrou no chat.</font>")
        end
    end)

    task.wait(2)
    ShowNotification("ReChat Pronto", "Segure o botão no topbar para opções extras!", 4)
end

local function StartPolling()
    PollingThread = coroutine.create(function()
        while PollingActive do
            if not ScreenGui or not ScreenGui.Parent then break end
            local newMessages = GetNewMessages()
            for _, msg in ipairs(newMessages) do
                HandleIncomingMessage(msg)
            end
            local startTime = tick()
            while tick() - startTime < POLLING_INTERVAL and PollingActive do
                task.wait(0.1)
                if not PollingActive then break end
            end
        end
    end)
    coroutine.resume(PollingThread)
end

local function StartFadeTimer()
    FadeThread = coroutine.create(function()
        while PollingActive do
            if not ScreenGui or not ScreenGui.Parent then break end
            if CurrentChatVisible and not ChatInputFocused then
                local timeSince = tick() - LastInteractionTime
                if timeSince >= CHAT_FADE_TIME and not IsChatWindowFaded then
                    FadeChatWindow(true)
                end
            end
            local startTime = tick()
            while tick() - startTime < 1 and PollingActive do
                task.wait(0.1)
                if not PollingActive then break end
            end
        end
    end)
    coroutine.resume(FadeThread)
end

task.spawn(function()
    InitializeChat()
    UpdateButtonHighlight()
    UpdateChatModeButton()
    UpdateIgnoreRobloxButton()
    UpdateDragButton()
    StartPolling()
    StartFadeTimer()
end)
