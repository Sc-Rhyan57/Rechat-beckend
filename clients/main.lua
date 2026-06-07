local cloneref = cloneref or clonereference or function(instance)
    return instance
end

local protectgui = protectgui or (syn and syn.protect_gui) or function() end

local gethui = gethui or function()
    return cloneref(game:GetService("CoreGui"))
end

if shared["alsllalslallalalalalallalallalalalla-chatenable"] then
    return
end

shared["alsllalslallalalalalallalallalalalla-chatenable"] = true

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

local success = pcall(function()
    ScreenGui.Parent = gethui()
    protectgui(ScreenGui)
end)

if not success or not ScreenGui.Parent then
    ScreenGui.Parent = PlayerGui
end

local TopBarButton = Instance.new("ImageButton")
TopBarButton.Name = "ChatTopBarButton"
TopBarButton.Size = UDim2.new(0, 40, 0, 40)
TopBarButton.AnchorPoint = Vector2.new(0.5, 0)
TopBarButton.Position = UDim2.new(0.5, 0, 0, 5)
TopBarButton.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
TopBarButton.BackgroundTransparency = 0.3
TopBarButton.BorderSizePixel = 0
TopBarButton.Image = "rbxassetid://132620481944192"
TopBarButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
TopBarButton.ScaleType = Enum.ScaleType.Fit
TopBarButton.ZIndex = 10
TopBarButton.Parent = ScreenGui

local ImagePadding = Instance.new("UIPadding")
ImagePadding.PaddingTop = UDim.new(0, 8)
ImagePadding.PaddingBottom = UDim.new(0, 8)
ImagePadding.PaddingLeft = UDim.new(0, 8)
ImagePadding.PaddingRight = UDim.new(0, 8)
ImagePadding.Parent = TopBarButton

local ButtonCorner = Instance.new("UICorner")
ButtonCorner.CornerRadius = UDim.new(0.5, 0)
ButtonCorner.Parent = TopBarButton

local ButtonStroke = Instance.new("UIStroke")
ButtonStroke.Color = Color3.fromRGB(255, 60, 60)
ButtonStroke.Thickness = 2
ButtonStroke.Transparency = 0.3
ButtonStroke.Parent = TopBarButton

local UnreadBadge = Instance.new("Frame")
UnreadBadge.Name = "UnreadBadge"
UnreadBadge.Size = UDim2.new(0, 20, 0, 20)
UnreadBadge.Position = UDim2.new(1, -5, 0, -5)
UnreadBadge.AnchorPoint = Vector2.new(1, 0)
UnreadBadge.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
UnreadBadge.BorderSizePixel = 0
UnreadBadge.Visible = false
UnreadBadge.ZIndex = 11
UnreadBadge.Parent = TopBarButton

local BadgeCorner = Instance.new("UICorner")
BadgeCorner.CornerRadius = UDim.new(1, 0)
BadgeCorner.Parent = UnreadBadge

local UnreadLabel = Instance.new("TextLabel")
UnreadLabel.Size = UDim2.new(1, 0, 1, 0)
UnreadLabel.BackgroundTransparency = 1
UnreadLabel.Font = Enum.Font.GothamBold
UnreadLabel.Text = "0"
UnreadLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
UnreadLabel.TextSize = 12
UnreadLabel.TextScaled = true
UnreadLabel.ZIndex = 12
UnreadLabel.Parent = UnreadBadge

local ActionButtonsContainer = Instance.new("Frame")
ActionButtonsContainer.Name = "ActionButtons"
ActionButtonsContainer.Size = UDim2.new(0, 156, 0, 40)
ActionButtonsContainer.Position = UDim2.new(0.5, -78, 0, 50)
ActionButtonsContainer.BackgroundTransparency = 1
ActionButtonsContainer.Visible = false
ActionButtonsContainer.ZIndex = 10
ActionButtonsContainer.Parent = ScreenGui

local DragButton = Instance.new("ImageButton")
DragButton.Name = "DragButton"
DragButton.Size = UDim2.new(0, 36, 0, 36)
DragButton.Position = UDim2.new(0, 0, 0, 0)
DragButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
DragButton.BackgroundTransparency = 0.3
DragButton.BorderSizePixel = 0
DragButton.Image = "rbxassetid://7733992358"
DragButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
DragButton.ZIndex = 11
DragButton.Parent = ActionButtonsContainer

local DragCorner = Instance.new("UICorner")
DragCorner.CornerRadius = UDim.new(0.5, 0)
DragCorner.Parent = DragButton

local ChatModeButton = Instance.new("ImageButton")
ChatModeButton.Name = "ChatModeButton"
ChatModeButton.Size = UDim2.new(0, 36, 0, 36)
ChatModeButton.Position = UDim2.new(0, 42, 0, 0)
ChatModeButton.BackgroundColor3 = Color3.fromRGB(85, 170, 255)
ChatModeButton.BackgroundTransparency = 0.3
ChatModeButton.BorderSizePixel = 0
ChatModeButton.Image = "rbxassetid://132620481944192"
ChatModeButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
ChatModeButton.ZIndex = 11
ChatModeButton.Parent = ActionButtonsContainer

local ChatModeCorner = Instance.new("UICorner")
ChatModeCorner.CornerRadius = UDim.new(0.5, 0)
ChatModeCorner.Parent = ChatModeButton

local ChatModePadding = Instance.new("UIPadding")
ChatModePadding.PaddingTop = UDim.new(0, 6)
ChatModePadding.PaddingBottom = UDim.new(0, 6)
ChatModePadding.PaddingLeft = UDim.new(0, 6)
ChatModePadding.PaddingRight = UDim.new(0, 6)
ChatModePadding.Parent = ChatModeButton

local IgnoreRobloxButton = Instance.new("ImageButton")
IgnoreRobloxButton.Name = "IgnoreRobloxButton"
IgnoreRobloxButton.Size = UDim2.new(0, 36, 0, 36)
IgnoreRobloxButton.Position = UDim2.new(0, 84, 0, 0)
IgnoreRobloxButton.BackgroundColor3 = Color3.fromRGB(170, 85, 255)
IgnoreRobloxButton.BackgroundTransparency = 0.3
IgnoreRobloxButton.BorderSizePixel = 0
IgnoreRobloxButton.Image = "rbxassetid://7733911816"
IgnoreRobloxButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
IgnoreRobloxButton.ZIndex = 11
IgnoreRobloxButton.Parent = ActionButtonsContainer

local IgnoreRobloxCorner = Instance.new("UICorner")
IgnoreRobloxCorner.CornerRadius = UDim.new(0.5, 0)
IgnoreRobloxCorner.Parent = IgnoreRobloxButton

local IgnoreRobloxPadding = Instance.new("UIPadding")
IgnoreRobloxPadding.PaddingTop = UDim.new(0, 6)
IgnoreRobloxPadding.PaddingBottom = UDim.new(0, 6)
IgnoreRobloxPadding.PaddingLeft = UDim.new(0, 6)
IgnoreRobloxPadding.PaddingRight = UDim.new(0, 6)
IgnoreRobloxPadding.Parent = IgnoreRobloxButton

local CloseButton = Instance.new("ImageButton")
CloseButton.Name = "CloseButton"
CloseButton.Size = UDim2.new(0, 36, 0, 36)
CloseButton.Position = UDim2.new(0, 126, 0, 0)
CloseButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
CloseButton.BackgroundTransparency = 0.3
CloseButton.BorderSizePixel = 0
CloseButton.Image = "rbxassetid://7733717447"
CloseButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
CloseButton.ZIndex = 11
CloseButton.Parent = ActionButtonsContainer

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0.5, 0)
CloseCorner.Parent = CloseButton

task.spawn(function()
    task.wait(0.5)
    if TopBarButton.Image == "" or not TopBarButton.Image:find("rbxassetid") then
        TopBarButton.Image = ""
        local EmojiLabel = Instance.new("TextLabel")
        EmojiLabel.Size = UDim2.new(1, 0, 1, 0)
        EmojiLabel.BackgroundTransparency = 1
        EmojiLabel.Text = "💬"
        EmojiLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        EmojiLabel.TextSize = 24
        EmojiLabel.Font = Enum.Font.SourceSansBold
        EmojiLabel.ZIndex = 11
        EmojiLabel.Parent = TopBarButton
    end
end)

local ChatFrame = Instance.new("Frame")
ChatFrame.Name = "ChatFrame"
ChatFrame.Size = UDim2.new(0, 400, 0, 250)
ChatFrame.Position = shared.ReChatSettings.ChatPosition
ChatFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
ChatFrame.BackgroundTransparency = 1
ChatFrame.BorderSizePixel = 0
ChatFrame.Visible = false
ChatFrame.Active = true
ChatFrame.ZIndex = 5
ChatFrame.Parent = ScreenGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 12)
Corner.Parent = ChatFrame

local TopBar = Instance.new("Frame")
TopBar.Name = "TopBar"
TopBar.Size = UDim2.new(1, 0, 0, 35)
TopBar.Position = UDim2.new(0, 0, 0, 0)
TopBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
TopBar.BackgroundTransparency = 1
TopBar.BorderSizePixel = 0
TopBar.ZIndex = 6
TopBar.Parent = ChatFrame

local TopBarCorner = Instance.new("UICorner")
TopBarCorner.CornerRadius = UDim.new(0, 12)
TopBarCorner.Parent = TopBar

local ChannelLabel = Instance.new("TextLabel")
ChannelLabel.Size = UDim2.new(1, -20, 1, 0)
ChannelLabel.Position = UDim2.new(0, 10, 0, 0)
ChannelLabel.BackgroundTransparency = 1
ChannelLabel.Text = "General"
ChannelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ChannelLabel.TextXAlignment = Enum.TextXAlignment.Left
ChannelLabel.Font = Enum.Font.SourceSansBold
ChannelLabel.TextSize = 16
ChannelLabel.ZIndex = 7
ChannelLabel.Parent = TopBar

local MessageScroll = Instance.new("ScrollingFrame")
MessageScroll.Name = "MessageScroll"
MessageScroll.Size = UDim2.new(1, -10, 1, -85)
MessageScroll.Position = UDim2.new(0, 5, 0, 40)
MessageScroll.BackgroundTransparency = 1
MessageScroll.BorderSizePixel = 0
MessageScroll.ScrollBarThickness = 4
MessageScroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
MessageScroll.ScrollBarImageTransparency = 0.5
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
InputContainer.Size = UDim2.new(1, -10, 0, 40)
InputContainer.Position = UDim2.new(0, 5, 1, -45)
InputContainer.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
InputContainer.BackgroundTransparency = 1
InputContainer.BorderSizePixel = 0
InputContainer.ZIndex = 6
InputContainer.Parent = ChatFrame

local InputCorner = Instance.new("UICorner")
InputCorner.CornerRadius = UDim.new(0, 8)
InputCorner.Parent = InputContainer

local HoverDetector = Instance.new("Frame")
HoverDetector.Name = "HoverDetector"
HoverDetector.Size = UDim2.new(1, 0, 1, 0)
HoverDetector.Position = UDim2.new(0, 0, 0, 0)
HoverDetector.BackgroundTransparency = 1
HoverDetector.BorderSizePixel = 0
HoverDetector.ZIndex = 7
HoverDetector.Active = true
HoverDetector.Parent = InputContainer

local ChatInputBox = Instance.new("TextBox")
ChatInputBox.Name = "ChatInputBox"
ChatInputBox.Size = UDim2.new(1, -10, 1, -6)
ChatInputBox.Position = UDim2.new(0, 5, 0, 3)
ChatInputBox.BackgroundTransparency = 1
ChatInputBox.Text = ""
ChatInputBox.PlaceholderText = "Type a message..."
ChatInputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
ChatInputBox.PlaceholderColor3 = Color3.fromRGB(178, 178, 178)
ChatInputBox.Font = Enum.Font.SourceSans
ChatInputBox.TextSize = 16
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
    if dragToggleActive then
        DragButton.BackgroundColor3 = Color3.fromRGB(60, 255, 60)
    else
        DragButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    end
end

local function UpdateChatModeButton()
    if SendToRobloxChat then
        ChatModeButton.Image = "rbxassetid://137202017384658"
        ChatModeButton.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        ChatModeButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
        local padding = ChatModeButton:FindFirstChild("UIPadding")
        if padding then
            padding.PaddingTop = UDim.new(0, 8)
            padding.PaddingBottom = UDim.new(0, 8)
            padding.PaddingLeft = UDim.new(0, 8)
            padding.PaddingRight = UDim.new(0, 8)
        end
    else
        ChatModeButton.Image = "rbxassetid://132620481944192"
        ChatModeButton.BackgroundColor3 = Color3.fromRGB(85, 170, 255)
        ChatModeButton.ImageColor3 = Color3.fromRGB(255, 255, 255)
        local padding = ChatModeButton:FindFirstChild("UIPadding")
        if padding then
            padding.PaddingTop = UDim.new(0, 6)
            padding.PaddingBottom = UDim.new(0, 6)
            padding.PaddingLeft = UDim.new(0, 6)
            padding.PaddingRight = UDim.new(0, 6)
        end
    end
end

local function UpdateIgnoreRobloxButton()
    if IgnoreRobloxChat then
        IgnoreRobloxButton.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
    else
        IgnoreRobloxButton.BackgroundColor3 = Color3.fromRGB(170, 85, 255)
    end
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
    if IgnoreRobloxChat then
        ShowNotification("ReChat", "Ignoring Roblox chat messages", 2)
    else
        ShowNotification("ReChat", "Showing Roblox chat messages", 2)
    end
end)

DragButton.MouseButton1Click:Connect(function()
    dragToggleActive = not dragToggleActive
    shared.ReChatSettings.DragEnabled = dragToggleActive
    UpdateDragButton()
    if dragToggleActive then
        ShowNotification("ReChat", "Drag mode enabled! Click and drag the chat window", 3)
    else
        ShowNotification("ReChat", "Drag mode disabled", 2)
    end
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
        TweenService:Create(UnreadBadge, TweenInfo.new(0.3, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {Size = UDim2.new(0, 22, 0, 22)}):Play()
        task.wait(0.3)
        TweenService:Create(UnreadBadge, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, 20, 0, 20)}):Play()
    else
        UnreadBadge.Visible = false
    end
end

local function UpdateButtonStroke()
    if CurrentChatVisible then
        TweenService:Create(ButtonStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Color3.fromRGB(60, 255, 60), Transparency = 0.3}):Play()
    else
        TweenService:Create(ButtonStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Color = Color3.fromRGB(255, 60, 60), Transparency = 0.3}):Play()
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
    local targetTransparency = fadeOut and 1 or 0.3
    local topBarTarget       = fadeOut and 1 or 0.2
    local inputTarget        = fadeOut and 1 or 0.2
    local textTarget         = fadeOut and 1 or 0

    TweenService:Create(ChatFrame, TweenInfo.new(BACKGROUND_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = targetTransparency}):Play()
    TweenService:Create(TopBar, TweenInfo.new(BACKGROUND_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = topBarTarget}):Play()
    TweenService:Create(InputContainer, TweenInfo.new(BACKGROUND_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = inputTarget}):Play()

    for _, child in ipairs(MessageScroll:GetChildren()) do
        if child:IsA("Frame") then
            for _, label in ipairs(child:GetChildren()) do
                if label:IsA("TextLabel") then
                    TweenService:Create(label, TweenInfo.new(BACKGROUND_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = textTarget}):Play()
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

    UpdateButtonStroke()

    if active then
        ChatFrame.Visible = true
        UnreadMessages = 0
        UpdateUnreadBadge()
        IsChatWindowFaded = false
        ResetFadeTimer()

        if dragToggleActive then
            ActionButtonsContainer.Visible = true
        end

        if not instant then
            isFading = true
            fadeInTween = TweenService:Create(ChatFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.3})
            fadeInTween.Completed:Connect(function() isFading = false end)
            fadeInTween:Play()
            TweenService:Create(TopBar, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.2}):Play()
            TweenService:Create(InputContainer, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0.2}):Play()
            for _, child in ipairs(MessageScroll:GetChildren()) do
                if child:IsA("Frame") then
                    for _, label in ipairs(child:GetChildren()) do
                        if label:IsA("TextLabel") then
                            TweenService:Create(label, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
                        end
                    end
                end
            end
        else
            ChatFrame.BackgroundTransparency = 0.3
            TopBar.BackgroundTransparency = 0.2
            InputContainer.BackgroundTransparency = 0.2
            SetAllTextTransparency(0)
        end

        if not skipFocus then
            ChatInputBox:CaptureFocus()
        end
    else
        if not dragToggleActive then
            ActionButtonsContainer.Visible = false
        end

        if not instant then
            isFading = true
            fadeOutTween = TweenService:Create(ChatFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
            TweenService:Create(TopBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1}):Play()
            TweenService:Create(InputContainer, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1}):Play()
            for _, child in ipairs(MessageScroll:GetChildren()) do
                if child:IsA("Frame") then
                    for _, label in ipairs(child:GetChildren()) do
                        if label:IsA("TextLabel") then
                            TweenService:Create(label, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = 1}):Play()
                        end
                    end
                end
            end
            fadeOutTween.Completed:Connect(function()
                isFading = false
                if not CurrentChatVisible then
                    ChatFrame.Visible = false
                end
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
    return false, "Failed to send message", nil
end

local function SendToRoblox(message)
    JustSentToRoblox = true
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            local textChannel = TextChatService.TextChannels.RBXGeneral
            textChannel:SendAsync(message)
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
        table.sort(messages, function(a, b)
            return a:GetAttribute("MessageTimestamp") < b:GetAttribute("MessageTimestamp")
        end)
        local toRemove = #messages - MAX_MESSAGES
        for i = 1, toRemove do
            messages[i]:Destroy()
        end
    end
end

local function GetUserColor(username)
    if not shared.ReChatSettings.UserColors[username] then
        local hash = 0
        for i = 1, #username do
            hash = hash + string.byte(username, i) * i
        end
        local hue = (hash % 360) / 360
        local function hsvToRgb(h, s, v)
            local c = v * s
            local x = c * (1 - math.abs((h * 6) % 2 - 1))
            local m = v - c
            local r, g, b = 0, 0, 0
            if h < 1/6 then r, g, b = c, x, 0
            elseif h < 2/6 then r, g, b = x, c, 0
            elseif h < 3/6 then r, g, b = 0, c, x
            elseif h < 4/6 then r, g, b = 0, x, c
            elseif h < 5/6 then r, g, b = x, 0, c
            else r, g, b = c, 0, x end
            return math.floor((r + m) * 255), math.floor((g + m) * 255), math.floor((b + m) * 255)
        end
        local r, g, b = hsvToRgb(hue, 0.7, 0.9)
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
    MessageLabel.Font = Enum.Font.SourceSansBold
    MessageLabel.TextSize = 15
    MessageLabel.TextWrapped = true
    MessageLabel.RichText = true
    MessageLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    MessageLabel.TextTransparency = IsChatWindowFaded and 1 or 0
    MessageLabel.ZIndex = 7
    MessageLabel.Parent = Container

    if isSystem then
        MessageLabel.Text = string.format("<font color='rgb(255,215,0)'>[SYSTEM]</font> %s", message)
    elseif isRobloxChat then
        local userColor = GetUserColor(username)
        MessageLabel.Text = string.format("<font color='rgb(200,200,200)'>[ROBLOX]</font> <font color='%s'>%s:</font> %s", userColor, displayName or username, message)
    else
        local userColor = GetUserColor(username)
        MessageLabel.Text = string.format("<font color='%s'>%s:</font> %s", userColor, displayName or username, message)
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
    ConfirmationFrame.Size = UDim2.new(0, 300, 0, 150)
    ConfirmationFrame.Position = UDim2.new(0.5, -150, 0.5, -75)
    ConfirmationFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    ConfirmationFrame.BorderSizePixel = 0
    ConfirmationFrame.ZIndex = 20
    ConfirmationFrame.Parent = ScreenGui

    local ConfirmCorner = Instance.new("UICorner")
    ConfirmCorner.CornerRadius = UDim.new(0, 12)
    ConfirmCorner.Parent = ConfirmationFrame

    local ConfirmStroke = Instance.new("UIStroke")
    ConfirmStroke.Color = Color3.fromRGB(255, 60, 60)
    ConfirmStroke.Thickness = 2
    ConfirmStroke.Parent = ConfirmationFrame

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, -20, 0, 40)
    TitleLabel.Position = UDim2.new(0, 10, 0, 10)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = "Close ReChat?"
    TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextSize = 18
    TitleLabel.ZIndex = 21
    TitleLabel.Parent = ConfirmationFrame

    local MessageLabel2 = Instance.new("TextLabel")
    MessageLabel2.Size = UDim2.new(1, -20, 0, 30)
    MessageLabel2.Position = UDim2.new(0, 10, 0, 50)
    MessageLabel2.BackgroundTransparency = 1
    MessageLabel2.Text = "Are you sure you want to close the chat?"
    MessageLabel2.TextColor3 = Color3.fromRGB(200, 200, 200)
    MessageLabel2.Font = Enum.Font.Gotham
    MessageLabel2.TextSize = 14
    MessageLabel2.TextWrapped = true
    MessageLabel2.ZIndex = 21
    MessageLabel2.Parent = ConfirmationFrame

    local YesButton = Instance.new("TextButton")
    YesButton.Size = UDim2.new(0, 130, 0, 35)
    YesButton.Position = UDim2.new(0, 10, 1, -45)
    YesButton.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
    YesButton.BorderSizePixel = 0
    YesButton.Text = "Yes, Close"
    YesButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    YesButton.Font = Enum.Font.GothamBold
    YesButton.TextSize = 14
    YesButton.ZIndex = 21
    YesButton.Parent = ConfirmationFrame

    local YesCorner = Instance.new("UICorner")
    YesCorner.CornerRadius = UDim.new(0, 8)
    YesCorner.Parent = YesButton

    local NoButton = Instance.new("TextButton")
    NoButton.Size = UDim2.new(0, 130, 0, 35)
    NoButton.Position = UDim2.new(1, -140, 1, -45)
    NoButton.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    NoButton.BorderSizePixel = 0
    NoButton.Text = "Cancel"
    NoButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    NoButton.Font = Enum.Font.GothamBold
    NoButton.TextSize = 14
    NoButton.ZIndex = 21
    NoButton.Parent = ConfirmationFrame

    local NoCorner = Instance.new("UICorner")
    NoCorner.CornerRadius = UDim.new(0, 8)
    NoCorner.Parent = NoButton

    YesButton.MouseButton1Click:Connect(function()
        PollingActive = false
        shared["alsllalslallalalalalallalallalalalla-chatenable"] = false
        if PollingThread then pcall(function() coroutine.close(PollingThread) end) end
        if FadeThread    then pcall(function() coroutine.close(FadeThread) end) end
        if ScreenGui then ScreenGui:Destroy() end
    end)

    NoButton.MouseButton1Click:Connect(function()
        ConfirmationFrame:Destroy()
    end)
end)

TopBarButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        holdTimer = 0
        local connection
        connection = RunService.Heartbeat:Connect(function(dt)
            holdTimer = holdTimer + dt
            if holdTimer >= HOLD_DURATION then
                connection:Disconnect()
                ActionButtonsContainer.Visible = true
                if not hasShownTutorial then
                    hasShownTutorial = true
                end
            end
        end)
        local endConnection
        endConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                connection:Disconnect()
                endConnection:Disconnect()
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
                ShowNotification("ReChat Tip", "Hold '/' or the chat button for extra actions! \n aperte e segure para ver opções extra de configuração.", 10)
                hasShownTutorial = true
            end
        else
            ChatInputBox:CaptureFocus()
        end
        ResetFadeTimer()
    elseif input.KeyCode == Enum.KeyCode.Escape then
        if CurrentChatVisible then
            SetChatActive(false, false)
        end
        if not dragToggleActive then
            ActionButtonsContainer.Visible = false
        end
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
                AddSystemMessage(responseMsg or "Failed to send message")
            end
        end

        ResetFadeTimer()
    end
end)

ChatInputBox.Focused:Connect(function()
    ChatInputFocused = true
    ResetFadeTimer()
    if not CurrentChatVisible then
        SetChatActive(true, false)
    end
end)

local function InitializeChat()
    AddSystemMessage("ReChat Blox - Connecting...")

    if not InitSession() then
        AddSystemMessage("Failed to initialize session!")
        return
    end

    AddSystemMessage("Connected to ReChat Blox!")
    AddSystemMessage("Press '/' or click button to open chat")
    AddSystemMessage("<b>Script made by <font color='rgb(255,20,147)'>@rhyan57</font> and <font color='rgb(255,20,147)'>@loldog</font></b>")
    AddSystemMessage("Join our Discord server if you need support! \n <font color='rgb(119,133,204)'>https://discord.gg/Pfmqq79q9Q</font>")

    for _, player in ipairs(Players:GetPlayers()) do
        if player.UserId == 3274233701 then
            AddSystemMessage("<font color='rgb(255,165,0)'>An administrator from the chat, </font><font color='rgb(255,20,147)'>@rhyan57</font><font color='rgb(255,165,0)'>, has joined the chat.</font>")
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
            AddSystemMessage("<font color='rgb(255,165,0)'>An administrator from the chat, </font><font color='rgb(255,20,147)'>@rhyan57</font><font color='rgb(255,165,0)'>, has joined the chat.</font>")
        end
    end)

    task.wait(2)
    ShowNotification("ReChat Ready", "Hold the chat button or '/' for extra actions!", 4)
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
                local timeSinceInteraction = tick() - LastInteractionTime
                if timeSinceInteraction >= CHAT_FADE_TIME and not IsChatWindowFaded then
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
    UpdateButtonStroke()
    UpdateChatModeButton()
    UpdateIgnoreRobloxButton()
    UpdateDragButton()
    StartPolling()
    StartFadeTimer()
end)
