-- 左上角小型等宽 HUD：深度、辐射读数、暂停与配色按钮（urhox-libs/UI）

local UI = require("urhox-libs/UI")

local HUD = {}

local COL_TEXT = { 186, 214, 222, 235 }
local COL_DIM = { 120, 150, 160, 200 }
local COL_WARN = { 255, 170, 90, 240 }

---@type Label
local depthLabel_
---@type Label
local radLabel_
---@type Button
local pauseBtn_
---@type Button
local palBtn_
local root_

local function smallButton(text, onClick)
    return UI.Button {
        text = text,
        fontFamily = "mono",
        fontSize = 10,
        height = 20,
        paddingLeft = 7,
        paddingRight = 7,
        borderRadius = 2,
        borderWidth = 1,
        borderColor = { 140, 210, 230, 70 },
        backgroundColor = { 14, 22, 28, 170 },
        hoverBackgroundColor = { 30, 48, 58, 200 },
        pressedBackgroundColor = { 50, 80, 96, 220 },
        textColor = COL_TEXT,
        onClick = onClick,
    }
end

---@param cb table { onPause = fun(), onPalette = fun() }
function HUD.Init(cb)
    UI.Init({
        theme = "default-dark",
        fonts = { { family = "mono", weights = { normal = "Fonts/Anonymous Pro.ttf", bold = "Fonts/Anonymous Pro.ttf" } } },
        scale = UI.Scale.DEFAULT,
    })
    depthLabel_ = UI.Label { text = "DEPTH  ----.- m", fontFamily = "mono", fontSize = 11, fontColor = COL_TEXT }
    radLabel_ = UI.Label { text = "RAD     -.-- mSv/h", fontFamily = "mono", fontSize = 11, fontColor = COL_TEXT }
    pauseBtn_ = smallButton("|| PAUSE", function(self) cb.onPause() end)
    palBtn_ = smallButton("PAL AMBER", function(self) cb.onPalette() end)
    local box = UI.Panel {
        position = "absolute",
        left = 10,
        top = 10,
        paddingLeft = 8,
        paddingRight = 8,
        paddingTop = 6,
        paddingBottom = 7,
        gap = 2,
        backgroundColor = { 5, 9, 12, 150 },
        borderRadius = 3,
        borderWidth = 1,
        borderColor = { 120, 200, 220, 45 },
        children = {
            depthLabel_,
            radLabel_,
            UI.Panel { flexDirection = "row", gap = 5, marginTop = 4, children = { pauseBtn_, palBtn_ } },
        },
    }
    root_ = UI.Panel { width = "100%", height = "100%", pointerEvents = "box-none", children = { box } }
    UI.SetRoot(root_)
end

function HUD.IsOverUI(x, y)
    local s = UI.GetScale()
    return UI.FindWidgetAt(x / s, y / s) ~= nil
end

---@param depth number 米
---@param rad number mSv/h
function HUD.Update(depth, rad, paused, paletteName)
    if not depthLabel_ then
        return
    end
    depthLabel_:SetText(string.format("DEPTH %9.1f m", depth))
    radLabel_:SetText(string.format("RAD   %9.2f mSv/h", rad))
    radLabel_:SetFontColor(rad > 25.0 and COL_WARN or COL_TEXT)
    pauseBtn_:SetText(paused and "> RESUME" or "|| PAUSE")
    palBtn_:SetText("PAL " .. paletteName)
end

function HUD.Shutdown()
    UI.Shutdown()
end

return HUD
