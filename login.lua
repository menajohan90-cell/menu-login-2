-- ====================================================================
-- KEY SYSTEM GUI + FIRESTORE (CLIENTE PARA EJECUTORES)
-- ====================================================================

if not game:IsLoaded() then game.Loaded:Wait() end

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- Configuración Base de Datos Firestore
local PROJECT_ID = "zealous-actor-ddzcr"
local DATABASE_ID = "ai-studio-keyauthadminpane-1df40a98-4f08-45d8-ada6-3f43b7fefe13"
local API_KEY = "AIzaSyB3WhoQMDOE95h6iuQ7WGdYNlLaBcebyXU"

-- Contenedor UI seguro para ejecutores
local function GetGuiContainer()
    local container = nil
    pcall(function()
        local test = Instance.new("Folder")
        test.Parent = CoreGui
        test:Destroy()
        container = CoreGui
    end)
    if not container then
        container = LocalPlayer:WaitForChild("PlayerGui")
    end
    return container
end

local GuiContainer = GetGuiContainer()

-- Destruir UI previa si existe
if GuiContainer:FindFirstChild("KeyAuthClientUI") then 
    GuiContainer.KeyAuthClientUI:Destroy() 
end

-- Adaptador Universal HTTP para Ejecutores
local req = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)

local function HttpRequest(options)
    if req then
        local res = req(options)
        local status = res.StatusCode or res.Status or (res.Success and 200 or 400)
        return {
            Success = (status >= 200 and status < 300),
            StatusCode = status,
            Body = res.Body or res.ResponseBody or ""
        }
    elseif options.Method == "GET" then
        local success, body = pcall(function() return game:HttpGet(options.Url) end)
        return {
            Success = success,
            StatusCode = success and 200 or 404,
            Body = body or ""
        }
    end
    return { Success = false, StatusCode = 500, Body = "" }
end

local function GetDocUrl(collection, docId, queryParams)
    local base = string.format("https://firestore.googleapis.com/v1/projects/%s/databases/%s/documents/%s/%s", PROJECT_ID, DATABASE_ID, collection, docId)
    if queryParams then
        return string.format("%s?key=%s&%s", base, API_KEY, queryParams)
    else
        return string.format("%s?key=%s", base, API_KEY)
    end
end

-- Obtener HWID del dispositivo
local function GetHWID()
    local hwid = "UnknownDevice"
    pcall(function()
        if gethwid then
            hwid = gethwid()
        elseif RbxAnalyticsService then
            hwid = RbxAnalyticsService:GetClientId()
        end
    end)
    return hwid
end

-- Hacer que la ventana se pueda arrastrar (PC / Móvil)
local function MakeDraggable(frame, handle)
    handle = handle or frame
    local dragging, dragInput, dragStart, startPos

    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    handle.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- Comprobar Mantenimiento Global
local function CheckMaintenance()
    local url = GetDocUrl("settings", "global")
    local res = HttpRequest({ Url = url, Method = "GET" })
    if res.Success and res.StatusCode == 200 then
        local success, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if success and data and data.fields and data.fields.maintenance then
            return data.fields.maintenance.booleanValue == true
        end
    end
    return false
end

-- Validar Licencia contra Firestore
local function ValidateKey(key, playerName)
    local hwid = GetHWID()
    local keyUrl = GetDocUrl("keys", key)
    local keyRes = HttpRequest({ Url = keyUrl, Method = "GET" })

    if not keyRes.Success or keyRes.StatusCode ~= 200 then
        return false, "Key no existe por el Sistema o no validada."
    end

    local success, data = pcall(function() return HttpService:JSONDecode(keyRes.Body) end)
    if not success or not data or not data.fields then
        return false, "Key no existe por el Sistema o no validada."
    end

    local status = data.fields.status and data.fields.status.stringValue or "active"
    if status == "deleted" then
        return false, "Licencia eliminada por El Sistema."
    end
    if status == "revoked" then
        return false, "La key está revocada o inactiva."
    end

    if status == "used" then
        local assignedUser = data.fields.robloxUser and data.fields.robloxUser.stringValue or ""
        local assignedHwid = data.fields.hwid and data.fields.hwid.stringValue or ""

        if assignedUser ~= "" and assignedUser ~= playerName then
            return false, "La key ya está siendo usada por otro usuario."
        end
        if assignedHwid ~= "" and assignedHwid ~= hwid then
            return false, "Error de HWID: Key ligada a otro dispositivo."
        end
    end

    local rem = 0
    if data.fields.remainingSeconds then
        rem = tonumber(data.fields.remainingSeconds.integerValue or data.fields.remainingSeconds.doubleValue or data.fields.remainingSeconds.stringValue) or 0
    end

    if rem <= 0 then
        return false, "El tiempo de la licencia se ha agotado."
    end

    -- Actualizar estado a 'used', guardar usuario y HWID en Firestore
    local updateUrl = GetDocUrl("keys", key, "updateMask.fieldPaths=status&updateMask.fieldPaths=robloxUser&updateMask.fieldPaths=hwid")
    local payload = HttpService:JSONEncode({
        fields = {
            status = { stringValue = "used" },
            robloxUser = { stringValue = playerName },
            hwid = { stringValue = hwid }
        }
    })

    HttpRequest({
        Url = updateUrl,
        Method = "PATCH",
        Headers = { ["Content-Type"] = "application/json" },
        Body = payload
    })

    return true, "Acceso concedido.", key, rem
end

-- ====================================================================
-- ESTA FUNCIÓN SE EJECUTA CUANDO LA KEY ES VÁLIDA
-- AQUÍ PON TU SCRIPT / HUB PRINCIPAL
-- ====================================================================
local function OnSuccess(key, remainingSeconds)
    print("¡Key Correcta! Tiempo restante:", remainingSeconds, "segundos.")
    
    -- Coloca tu código o carga tu Script Hub aquí:
    -- loadstring(game:HttpGet("TU_SCRIPT_AQUI"))()
end

-- ====================================================================
-- CREACIÓN DE INTERFAZ GRÁFICA (LOGIN KEY GUI)
-- ====================================================================
local mainGui = Instance.new("ScreenGui")
mainGui.Name = "KeyAuthClientUI"
mainGui.ResetOnSpawn = false
mainGui.Parent = GuiContainer

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 320, 0, 160)
mainFrame.Position = UDim2.new(0.5, -160, 0.4, -80)
mainFrame.BackgroundColor3 = Color3.fromRGB(15, 23, 42)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = mainGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

-- Comprobación de Mantenimiento Global
if CheckMaintenance() then
    local msgLabel = Instance.new("TextLabel")
    msgLabel.Size = UDim2.new(0.9, 0, 0.8, 0)
    msgLabel.Position = UDim2.new(0.05, 0, 0.1, 0)
    msgLabel.Text = "scrip actualizandose espere y vuelva a probar en algunso minutos"
    msgLabel.TextColor3 = Color3.fromRGB(248, 113, 113)
    msgLabel.Font = Enum.Font.GothamBold
    msgLabel.TextSize = 13
    msgLabel.TextWrapped = true
    msgLabel.BackgroundTransparency = 1
    msgLabel.Parent = mainFrame
    return
end

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 38)
titleLabel.Text = "🔑 Ingresa tu Licencia"
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 13
titleLabel.TextColor3 = Color3.fromRGB(248, 250, 252)
titleLabel.BackgroundTransparency = 1
titleLabel.Parent = mainFrame

MakeDraggable(mainFrame, titleLabel)

local keyBox = Instance.new("TextBox")
keyBox.Size = UDim2.new(0.86, 0, 0, 38)
keyBox.Position = UDim2.new(0.07, 0, 0.28, 0)
keyBox.PlaceholderText = "Pegar Key aquí..."
keyBox.Text = ""
keyBox.Font = Enum.Font.Gotham
keyBox.TextSize = 12
keyBox.TextColor3 = Color3.fromRGB(255, 255, 255)
keyBox.BackgroundColor3 = Color3.fromRGB(30, 41, 59)
keyBox.BorderSizePixel = 0
keyBox.Parent = mainFrame

local keyBoxCorner = Instance.new("UICorner")
keyBoxCorner.CornerRadius = UDim.new(0, 6)
keyBoxCorner.Parent = keyBox

local validateBtn = Instance.new("TextButton")
validateBtn.Size = UDim2.new(0.86, 0, 0, 38)
validateBtn.Position = UDim2.new(0.07, 0, 0.62, 0)
validateBtn.BackgroundColor3 = Color3.fromRGB(37, 99, 235)
validateBtn.Font = Enum.Font.GothamBold
validateBtn.TextSize = 12
validateBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
validateBtn.Text = "Validar"
validateBtn.BorderSizePixel = 0
validateBtn.Parent = mainFrame

local validateCorner = Instance.new("UICorner")
validateCorner.CornerRadius = UDim.new(0, 6)
validateCorner.Parent = validateBtn

-- Evento de clic en Validar
validateBtn.MouseButton1Click:Connect(function()
    if keyBox.Text == "" then return end

    validateBtn.Text = "Verificando..."
    validateBtn.Active = false

    task.spawn(function()
        local valid, msg, key, remSeconds = ValidateKey(keyBox.Text, LocalPlayer.Name)

        if valid then
            mainGui:Destroy()
            OnSuccess(key, remSeconds)
        else
            validateBtn.Text = msg
            validateBtn.BackgroundColor3 = Color3.fromRGB(220, 38, 38)

            task.wait(2.5)
            if validateBtn and validateBtn.Parent then
                validateBtn.Text = "Validar"
                validateBtn.BackgroundColor3 = Color3.fromRGB(37, 99, 235)
                validateBtn.Active = true
            end
        end
    end)
end)
