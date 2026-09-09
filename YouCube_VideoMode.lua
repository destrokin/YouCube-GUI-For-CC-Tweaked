-- =========================================================
--                 YOUCUBE TOUCH PLAYER
-- CC:Tweaked / Minecraft 1.21.1
--
-- Uses installed YouCube client.
-- Backend server forced to:
--   ws://10.0.0.46:5000
--
-- Requires YouCube installed with:
--   pastebin run swsmNAf7
--
-- Features:
--   * Advanced Monitor search GUI
--   * Advanced Computer terminal GUI when no monitor is attached
--   * QWERTY keyboard
--   * Number row
--   * URL symbols
--   * Paste support
--   * Physical keyboard typing
--   * YouTube URL or search term
--   * Speaker audio through YouCube
--   * [X] close button during playback
-- =========================================================

local YOUCUBE_SERVER = "ws://73.232.111.5:5000"
local PLAYLIST_ENDPOINT = "http://73.232.111.5:5000/playlist"

-- Force YouCube to use your backend.
settings.set("youcube.server", YOUCUBE_SERVER)
settings.save()

local monitor = peripheral.find("monitor")

-- The Advanced Computer terminal is ALWAYS the control GUI.
-- The monitor, when present, is used ONLY for actual video playback.
local controller = term.current()
local display = controller
local USING_MONITOR = monitor ~= nil

local GUI_SCALE = 0.5

if controller.setCursorBlink then
    controller.setCursorBlink(false)
end

local width, height = controller.getSize()

local DEFAULT_PALETTE = {}

for _, color in ipairs({
    colors.white,
    colors.orange,
    colors.magenta,
    colors.lightBlue,
    colors.yellow,
    colors.lime,
    colors.pink,
    colors.gray,
    colors.lightGray,
    colors.cyan,
    colors.purple,
    colors.blue,
    colors.brown,
    colors.green,
    colors.red,
    colors.black
}) do
    local r, g, b = term.nativePaletteColor(color)

    DEFAULT_PALETTE[color] = {
        r = r,
        g = g,
        b = b
    }
end

local function restoreControllerPalette()
    if not display.setPaletteColor then
        return
    end

    for color, rgb in pairs(DEFAULT_PALETTE) do
        display.setPaletteColor(
            color,
            rgb.r,
            rgb.g,
            rgb.b
        )
    end
end

local C = {
    bg = colors.black,
    panel = colors.gray,
    panel2 = colors.lightGray,
    text = colors.white,
    dim = colors.lightGray,
    title = colors.red,
    key = colors.gray,
    keyText = colors.white,
    action = colors.green,
    actionText = colors.black,
    danger = colors.red
}

local query = ""
local uppercase = false
local status = "Server: 73.232.111.5:5000"

-- Audio-only mode is a search-screen toggle.
-- Loop state is intentionally separate and can be changed while a song plays.
local audioOnlyMode = false
local audioLoopEnabled = false

-- Audio-only queue. Entries are { url = "...", title = "..." }.
-- Playlist items after the current song are copied here before playback.
local audioQueue = {}

-- Audio Only owns at most ONE WebSocket at a time.
local activeAudioSocket = nil

-- Prevent the normal Audio Only player from redrawing over queue/input screens.
local audioOverlayLocked = false

local serverOnline = false
local serverStatusText = "CHECKING..."
local serverCheckTimer = nil
local serverCheckPending = false
local SERVER_CHECK_INTERVAL = 3

-- =========================================================
-- DRAW HELPERS
-- =========================================================

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function fillRect(x1, y1, x2, y2, bg)
    x1 = clamp(x1, 1, width)
    x2 = clamp(x2, 1, width)
    y1 = clamp(y1, 1, height)
    y2 = clamp(y2, 1, height)

    if x2 < x1 or y2 < y1 then
        return
    end

    display.setBackgroundColor(bg or C.bg)

    local line = string.rep(" ", x2 - x1 + 1)

    for y = y1, y2 do
        display.setCursorPos(x1, y)
        display.write(line)
    end
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > height or x > width then
        return
    end

    x = math.max(1, x)

    display.setCursorPos(x, y)
    display.setTextColor(fg or C.text)
    display.setBackgroundColor(bg or C.bg)

    local room = width - x + 1

    if room > 0 then
        display.write(tostring(text):sub(1, room))
    end
end

local function centerText(y, text, fg, bg)
    local x = math.floor((width - #text) / 2) + 1
    writeAt(x, y, text, fg, bg)
end

local function drawButton(x1, y1, x2, y2, label, bg, fg)
    fillRect(x1, y1, x2, y2, bg or C.key)

    local lx = x1 + math.floor(((x2 - x1 + 1) - #label) / 2)
    local ly = y1 + math.floor((y2 - y1) / 2)

    writeAt(
        lx,
        ly,
        label,
        fg or C.keyText,
        bg or C.key
    )
end

local function inRect(x, y, r)
    return x >= r.x1 and x <= r.x2
       and y >= r.y1 and y <= r.y2
end


local function scheduleServerCheck(delay)
    if serverCheckTimer then
        pcall(os.cancelTimer, serverCheckTimer)
    end

    serverCheckTimer =
        os.startTimer(
            delay or SERVER_CHECK_INTERVAL
        )
end

local function beginServerCheck()
    if serverCheckPending then
        return
    end

    serverCheckPending = true
    serverStatusText = "CHECKING..."

    -- Never open a WebSocket just to test server health.
    -- That consumed CC:Tweaked's limited WebSocket slots.
    local ok, responseOrErr, failureResponse =
        pcall(
            http.get,
            PLAYLIST_ENDPOINT
        )

    local response = nil

    if ok then
        response =
            responseOrErr
            or failureResponse
    end

    if response then
        serverOnline = true
        serverStatusText = "ONLINE"

        pcall(function()
            response.close()
        end)
    else
        serverOnline = false
        serverStatusText = "OFFLINE"
    end

    serverCheckPending = false
    scheduleServerCheck()
end

local function finishServerCheck(success, socket)
    -- Compatibility no-op. Health checking no longer uses WebSockets.
    if socket then
        pcall(function()
            socket.close()
        end)
    end
end

local function choosePlaybackScale()
    if not monitor or not monitor.setTextScale then
        return GUI_SCALE
    end

    local original =
        monitor.getTextScale
        and monitor.getTextScale()
        or GUI_SCALE

    local chosen = 0.5

    for scale = 0.5, 5.0, 0.5 do
        monitor.setTextScale(scale)
        local w, h = monitor.getSize()

        if w <= 164 and h <= 120 then
            chosen = scale
            break
        end
    end

    monitor.setTextScale(original)
    return chosen
end

local function stopAllSpeakers()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then
            local speaker = peripheral.wrap(name)

            if speaker and speaker.stop then
                pcall(speaker.stop)
            end
        end
    end
end

-- =========================================================
-- KEYBOARD
-- =========================================================

local ROWS = {
    {"1","2","3","4","5","6","7","8","9","0"},
    {"Q","W","E","R","T","Y","U","I","O","P"},
    {"A","S","D","F","G","H","J","K","L"},
    {"Z","X","C","V","B","N","M",".","/","-"}
}

local function keyboardLayout()
    local keysOut = {}

    local keyW = width >= 48 and 4 or 3
    local gap = 1
    local firstY = 7

    for rowIndex, row in ipairs(ROWS) do
        local rowWidth =
            (#row * keyW)
            + ((#row - 1) * gap)

        local sx =
            math.max(
                1,
                math.floor((width - rowWidth) / 2) + 1
            )

        local y = firstY + (rowIndex - 1) * 2

        for i, label in ipairs(row) do
            local x =
                sx + (i - 1) * (keyW + gap)

            table.insert(keysOut, {
                kind = "char",
                label = label,
                x1 = x,
                y1 = y,
                x2 = x + keyW - 1,
                y2 = y
            })
        end
    end

    local actionY = firstY + 8

    local actionDefs = {
        {kind="caps",     label="CAPS",  w=7},
        {kind="space",    label="SPACE", w=9},
        {kind="colon",    label=":",     w=4},
        {kind="question", label="?",     w=4},
        {kind="equals",   label="=",     w=4},
        {kind="back",     label="BACK",  w=7}
    }

    local total = 0

    for _, a in ipairs(actionDefs) do
        total = total + a.w
    end

    total = total + (#actionDefs - 1)

    local sx =
        math.max(
            1,
            math.floor((width - total) / 2) + 1
        )

    local x = sx

    for _, a in ipairs(actionDefs) do
        a.x1 = x
        a.y1 = actionY
        a.x2 = x + a.w - 1
        a.y2 = actionY

        table.insert(keysOut, a)

        x = a.x2 + 2
    end

    local playW = math.min(16, math.max(10, math.floor(width / 3)))
    local clearW = playW
    local gapButtons = 2
    local totalButtons = playW + clearW + gapButtons
    local bx = math.max(1, math.floor((width - totalButtons) / 2) + 1)
    local buttonY

    if USING_MONITOR then
        buttonY = math.min(height - 5, actionY + 2)
    else
        -- Advanced Computer terminal: keep the full keyboard, but reserve the
        -- bottom rows for actions so they do not overlap CAPS/SPACE/BACK.
        buttonY = math.max(actionY + 2, height - 4)
    end

    local play = {
        x1 = bx,
        y1 = buttonY,
        x2 = bx + playW - 1,
        y2 = buttonY + 1
    }

    local clearButton = {
        x1 = play.x2 + gapButtons + 1,
        y1 = buttonY,
        x2 = play.x2 + gapButtons + clearW,
        y2 = buttonY + 1
    }

    local audioW = math.min(24, math.max(16, width - 8))
    local audioY1
    local audioY2

    if USING_MONITOR then
        audioY1 = math.min(height - 2, buttonY + 3)
        audioY2 = math.min(height - 1, buttonY + 4)
    else
        audioY1 = height
        audioY2 = height
    end

    local audioButton = {
        x1 = math.floor((width - audioW) / 2) + 1,
        y1 = audioY1,
        x2 = math.floor((width - audioW) / 2) + audioW,
        y2 = audioY2
    }

    return keysOut, play, clearButton, audioButton
end

-- =========================================================
-- SEARCH SCREEN
-- =========================================================

local function controllerKeyboardLayout()
    local keysOut = {}

    local rows = {
        {"1","2","3","4","5","6","7","8","9","0"},
        {"Q","W","E","R","T","Y","U","I","O","P"},
        {"A","S","D","F","G","H","J","K","L"},
        {"Z","X","C","V","B","N","M",".","/","-"},
        {"[","]","\\","+","=","_","<",">",":","?"}
    }

    local keyW = 2
    local firstY = 6

    for rowIndex, row in ipairs(rows) do
        local rowWidth = #row * keyW
        local sx = math.max(1, math.floor((width - rowWidth) / 2) + 1)
        local y = firstY + rowIndex - 1

        for i, label in ipairs(row) do
            local x = sx + (i - 1) * keyW

            keysOut[#keysOut + 1] = {
                kind = "char",
                label = label,
                x1 = x,
                y1 = y,
                x2 = math.min(width, x + keyW - 1),
                y2 = y
            }
        end
    end

    local utilityY = firstY + #rows + 1

    local caps = {
        kind = "caps",
        label = "CAPS",
        x1 = 2,
        y1 = utilityY,
        x2 = math.min(width, 7),
        y2 = utilityY
    }

    local back = {
        kind = "back",
        label = "BACK",
        x1 = math.max(1, width - 6),
        y1 = utilityY,
        x2 = width - 1,
        y2 = utilityY
    }

    local space = {
        kind = "space",
        label = "SPACE",
        x1 = caps.x2 + 2,
        y1 = utilityY,
        x2 = back.x1 - 2,
        y2 = utilityY
    }

    keysOut[#keysOut + 1] = caps
    keysOut[#keysOut + 1] = space
    keysOut[#keysOut + 1] = back

    local actionY = math.min(height - 1, utilityY + 2)
    local mid = math.floor(width / 2)

    local play = {
        x1 = 2,
        y1 = actionY,
        x2 = math.max(2, mid - 1),
        y2 = actionY
    }

    local clearSearch = {
        x1 = math.min(width - 1, mid + 2),
        y1 = actionY,
        x2 = width - 1,
        y2 = actionY
    }

    -- Audio Only toggle sits on its own row below PLAY / CLEAR SEARCH.
    local audioY = math.min(height, actionY + 2)
    local audioW = math.min(width - 2, 22)
    local audioX = math.max(1, math.floor((width - audioW) / 2) + 1)

    local audioButton = {
        x1 = audioX,
        y1 = audioY,
        x2 = math.min(width, audioX + audioW - 1),
        y2 = audioY
    }

    return keysOut, play, clearSearch, audioButton
end

local function drawSearchOn(target, targetWidth, targetHeight, isMonitorGui)
    local oldDisplay = display
    local oldWidth = width
    local oldHeight = height

    display = target
    width = targetWidth
    height = targetHeight

    restoreControllerPalette()

    display.setBackgroundColor(C.bg)
    display.setTextColor(C.text)
    display.clear()

    centerText(1, "Y O U C U B E", C.title, C.bg)
    centerText(
        2,
        isMonitorGui and "Video Controller - Monitor" or "Video Controller",
        C.dim,
        C.bg
    )

    local boxX1 = 2
    local boxX2 = math.max(boxX1 + 8, width - 1)
    local boxY = 3

    fillRect(boxX1, boxY, boxX2, boxY + 1, colors.white)

    local shown = query
    local room = math.max(1, boxX2 - boxX1 - 1)

    if #shown > room then
        shown = shown:sub(#shown - room + 1)
    end

    writeAt(
        boxX1 + 1,
        boxY,
        shown,
        colors.black,
        colors.white
    )

    local keysOut, play, clearSearch, audioButton =
        controllerKeyboardLayout()

    for _, key in ipairs(keysOut) do
        local label = key.label
        local bg = C.key
        local fg = C.keyText

        if key.kind == "char"
           and label:match("%a") then

            label =
                uppercase
                and label:upper()
                or label:lower()

        elseif key.kind == "caps" then
            bg = colors.orange
            fg = colors.black
            label = uppercase and "UPPER" or "lower"

        elseif key.kind == "space" then
            bg = C.panel2
            fg = colors.black

        elseif key.kind == "back" then
            bg = C.danger
            fg = colors.white
        end

        drawButton(
            key.x1,key.y1,key.x2,key.y2,
            label,bg,fg
        )
    end

    drawButton(
        play.x1,play.y1,play.x2,play.y2,
        "PLAY",
        query ~= "" and colors.green or colors.gray,
        query ~= "" and colors.black or colors.lightGray
    )

    drawButton(
        clearSearch.x1,clearSearch.y1,
        clearSearch.x2,clearSearch.y2,
        width < 30 and "CLEAR" or "CLEAR SEARCH",
        colors.red,
        colors.white
    )

    drawButton(
        audioButton.x1,audioButton.y1,
        audioButton.x2,audioButton.y2,
        audioOnlyMode and "AUDIO ONLY: ON" or "AUDIO ONLY: OFF",
        audioOnlyMode and colors.lime or colors.gray,
        audioOnlyMode and colors.black or colors.white
    )

    local serverLabel = "SERVER: " .. serverStatusText
    local shownServer = tostring(serverLabel or "")

    if #shownServer > width then
        shownServer = shownServer:sub(1, width)
    end

    writeAt(
        1,
        height,
        shownServer,
        serverOnline and colors.lime or colors.red,
        C.bg
    )

    display = oldDisplay
    width = oldWidth
    height = oldHeight
end

local function drawSearch()
    local cw, ch = controller.getSize()
    drawSearchOn(controller, cw, ch, false)
end

local function drawMonitorSearch()
    if not monitor then
        return
    end

    -- Keep monitor GUI readable and consistent.
    if monitor.setTextScale then
        monitor.setTextScale(GUI_SCALE)
    end

    local mw, mh = monitor.getSize()
    drawSearchOn(monitor, mw, mh, true)
end

local function redrawAllControls()
    drawSearch()

    if monitor then
        drawMonitorSearch()
    end
end

-- =========================================================
-- YOUCUBE
-- =========================================================

local function resolveYouCube()
    local program =
        shell.resolveProgram("youcube")

    if program then
        return program
    end

    if fs.exists("youcube.lua") then
        return "youcube.lua"
    end

    if fs.exists("youcube") then
        return "youcube"
    end

    return nil
end


local function urlEncode(text)
    return tostring(text):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function isPlaylistUrl(text)
    local lower = tostring(text):lower()

    return lower:find("list=", 1, true) ~= nil
        or lower:find("/playlist", 1, true) ~= nil
end

local function resolvePlaylist(url)
    status = "Resolving playlist..."
    drawSearch()

    local requestUrl =
        PLAYLIST_ENDPOINT
        .. "?url="
        .. urlEncode(url)

    local response, err = http.get(
        requestUrl,
        nil,
        true
    )

    if not response then
        return nil,
            "Playlist error: "
            .. tostring(err or "server offline")
    end

    local body = response.readAll()
    response.close()

    local ok, data =
        pcall(
            textutils.unserialiseJSON,
            body
        )

    if not ok or type(data) ~= "table" then
        return nil, "Invalid playlist response"
    end

    if data.error then
        return nil, tostring(data.error)
    end

    if type(data.entries) ~= "table"
       or #data.entries == 0 then

        return nil, "No playable playlist entries"
    end

    return data
end

local function drawCloseBar()
    fillRect(
        1,
        1,
        width,
        1,
        colors.black
    )

    writeAt(
        1,
        1,
        "YouCube",
        colors.lightGray,
        colors.black
    )

    drawButton(
        math.max(1, width - 4),
        1,
        width,
        1,
        "[X]",
        colors.red,
        colors.white
    )
end


local function formatTime(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local minutes = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d", minutes, secs)
end

local function fitText(text, maxLen)
    text = tostring(text or "")
    if maxLen <= 0 then
        return ""
    end

    if #text <= maxLen then
        return text
    end

    if maxLen <= 3 then
        return text:sub(1, maxLen)
    end

    return text:sub(1, maxLen - 3) .. "..."
end

local function countSpeakers()
    local count = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then
            count = count + 1
        end
    end
    return count
end

local function audioGuiLayout()
    local margin = math.max(2, math.floor(width * 0.05))
    local left = margin
    local right = width - margin + 1

    local gap = 1
    local available = math.max(32, width - 6)
    local buttonW = math.floor((available - (gap * 3)) / 4)
    buttonW = math.max(7, math.min(14, buttonW))

    local total = (buttonW * 4) + (gap * 3)
    local sx = math.max(1, math.floor((width - total) / 2) + 1)

    local buttonY = math.max(8, height - 5)

    return {
        panelX1 = left,
        panelX2 = right,

        cancel = {
            x1 = sx,
            y1 = buttonY,
            x2 = sx + buttonW - 1,
            y2 = buttonY + 1
        },

        skip = {
            x1 = sx + buttonW + gap,
            y1 = buttonY,
            x2 = sx + (buttonW * 2) + gap - 1,
            y2 = buttonY + 1
        },

        upnext = {
            x1 = sx + (buttonW * 2) + (gap * 2),
            y1 = buttonY,
            x2 = sx + (buttonW * 3) + (gap * 2) - 1,
            y2 = buttonY + 1
        },

        loop = {
            x1 = sx + (buttonW * 3) + (gap * 3),
            y1 = buttonY,
            x2 = sx + (buttonW * 4) + (gap * 3) - 1,
            y2 = buttonY + 1
        }
    }
end

local function drawAudioOnlyScreenOn(target, targetWidth, targetHeight, state)
    local oldDisplay = display
    local oldWidth = width
    local oldHeight = height

    display = target
    width = targetWidth
    height = targetHeight

    restoreControllerPalette()

    if display.setCursorBlink then
        display.setCursorBlink(false)
    end

    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    local layout = audioGuiLayout()

    fillRect(1, 1, width, 3, colors.blue)
    centerText(1, "A U D I O   O N L Y", colors.white, colors.blue)
    centerText(
        2,
        "YouCube Music Player",
        colors.lightBlue,
        colors.blue
    )

    local cardTop = 5
    local cardBottom = math.max(cardTop + 7, layout.skip.y1 - 2)

    fillRect(
        layout.panelX1,
        cardTop,
        layout.panelX2,
        cardBottom,
        colors.gray
    )

    local innerX = layout.panelX1 + 2
    local innerWidth = math.max(1, layout.panelX2 - innerX - 1)

    writeAt(
        innerX,
        cardTop + 1,
        "CURRENT SONG",
        colors.lightGray,
        colors.gray
    )

    writeAt(
        innerX,
        cardTop + 2,
        fitText(state.title or "Loading...", innerWidth),
        colors.white,
        colors.gray
    )

    writeAt(
        innerX,
        cardTop + 4,
        "Duration:",
        colors.lightGray,
        colors.gray
    )

    writeAt(
        innerX + 10,
        cardTop + 4,
        state.duration and formatTime(state.duration) or "--:--",
        colors.white,
        colors.gray
    )

    writeAt(
        innerX,
        cardTop + 5,
        "Current Time:",
        colors.lightGray,
        colors.gray
    )

    writeAt(
        innerX + 14,
        cardTop + 5,
        formatTime(state.elapsed or 0),
        colors.white,
        colors.gray
    )

    writeAt(
        innerX,
        cardTop + 6,
        "Speakers:",
        colors.lightGray,
        colors.gray
    )

    writeAt(
        innerX + 10,
        cardTop + 6,
        tostring(state.speakerCount or 0) .. " connected",
        colors.white,
        colors.gray
    )

    local barY = math.min(cardBottom - 1, cardTop + 8)
    local barX1 = innerX
    local barX2 = math.max(barX1, layout.panelX2 - 2)
    local barWidth = math.max(1, barX2 - barX1 + 1)

    fillRect(barX1, barY, barX2, barY, colors.lightGray)

    if state.duration and state.duration > 0 then
        local progress =
            math.max(
                0,
                math.min(1, (state.elapsed or 0) / state.duration)
            )

        local filled = math.floor(barWidth * progress)

        if filled > 0 then
            fillRect(
                barX1,
                barY,
                barX1 + filled - 1,
                barY,
                colors.lime
            )
        end
    end

    drawButton(
        layout.cancel.x1,
        layout.cancel.y1,
        layout.cancel.x2,
        layout.cancel.y2,
        "CANCEL",
        colors.red,
        colors.white
    )

    drawButton(
        layout.skip.x1,
        layout.skip.y1,
        layout.skip.x2,
        layout.skip.y2,
        state.skipReady and "SKIP" or "LOADING",
        state.skipReady and colors.orange or colors.gray,
        state.skipReady and colors.black or colors.lightGray
    )

    drawButton(
        layout.upnext.x1,
        layout.upnext.y1,
        layout.upnext.x2,
        layout.upnext.y2,
        "UP NEXT",
        colors.lightBlue,
        colors.black
    )

    drawButton(
        layout.loop.x1,
        layout.loop.y1,
        layout.loop.x2,
        layout.loop.y2,
        audioLoopEnabled and "LOOP: ON" or "LOOP: OFF",
        audioLoopEnabled and colors.lime or colors.red,
        audioLoopEnabled and colors.black or colors.white
    )

    centerText(
        height,
        state.status or "Playing on all connected speakers",
        colors.lightGray,
        colors.black
    )

    display = oldDisplay
    width = oldWidth
    height = oldHeight

    return layout
end

local function drawAudioOnlyScreen(state)
    local cw, ch = controller.getSize()
    local controllerLayout =
        drawAudioOnlyScreenOn(controller, cw, ch, state)

    local monitorLayout = nil

    if monitor then
        if monitor.setTextScale then
            monitor.setTextScale(GUI_SCALE)
        end

        local mw, mh = monitor.getSize()
        monitorLayout =
            drawAudioOnlyScreenOn(monitor, mw, mh, state)
    end

    return {
        controller = controllerLayout,
        monitor = monitorLayout
    }
end

local function queueDisplayTitle(entry, index)
    local title = entry and entry.title
    if not title or title == "" then
        title = entry and entry.url or "Unknown song"
    end
    return tostring(index) .. ". " .. tostring(title)
end

local function drawQueueScreenOn(target, targetWidth, targetHeight, scroll)
    local oldDisplay = display
    local oldWidth = width
    local oldHeight = height

    display = target
    width = targetWidth
    height = targetHeight

    restoreControllerPalette()

    if display.setCursorBlink then
        display.setCursorBlink(false)
    end

    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    fillRect(1, 1, width, 3, colors.blue)
    centerText(1, "U P   N E X T", colors.white, colors.blue)
    centerText(
        2,
        tostring(#audioQueue) .. " upcoming",
        colors.lightBlue,
        colors.blue
    )

    local listTop = 5
    local listBottom = math.max(listTop, height - 6)
    local visible = math.max(1, listBottom - listTop + 1)

    fillRect(2, listTop, width - 1, listBottom, colors.gray)

    if #audioQueue == 0 then
        centerText(
            math.floor((listTop + listBottom) / 2),
            "No upcoming songs",
            colors.lightGray,
            colors.gray
        )
    else
        for row = 1, visible do
            local idx = scroll + row - 1
            local entry = audioQueue[idx]

            if entry then
                local label = queueDisplayTitle(entry, idx)

                writeAt(
                    4,
                    listTop + row - 1,
                    fitText(label, math.max(1, width - 7)),
                    colors.white,
                    colors.gray
                )
            end
        end
    end

    local addW = math.min(18, math.max(12, math.floor(width * 0.35)))
    local backW = math.min(14, math.max(10, math.floor(width * 0.25)))
    local total = addW + backW + 2
    local sx = math.max(1, math.floor((width - total) / 2) + 1)
    local by = height - 3

    local add = {
        x1=sx, y1=by,
        x2=sx+addW-1, y2=by+1
    }

    local back = {
        x1=add.x2+3, y1=by,
        x2=add.x2+2+backW, y2=by+1
    }

    drawButton(
        add.x1, add.y1, add.x2, add.y2,
        "ADD TO QUEUE",
        colors.lime, colors.black
    )

    drawButton(
        back.x1, back.y1, back.x2, back.y2,
        "BACK",
        colors.lightGray, colors.black
    )

    local up = nil
    local down = nil

    if #audioQueue > visible then
        up = {
            x1=width-4, y1=listTop,
            x2=width-2, y2=listTop
        }

        down = {
            x1=width-4, y1=listBottom,
            x2=width-2, y2=listBottom
        }

        drawButton(
            up.x1, up.y1, up.x2, up.y2,
            "^", colors.lightBlue, colors.black
        )

        drawButton(
            down.x1, down.y1, down.x2, down.y2,
            "v", colors.lightBlue, colors.black
        )
    end

    display = oldDisplay
    width = oldWidth
    height = oldHeight

    return {
        add = add,
        back = back,
        up = up,
        down = down,
        visible = visible
    }
end

local function drawQueueScreen(scroll)
    local cw, ch = controller.getSize()

    local controllerLayout =
        drawQueueScreenOn(
            controller,
            cw,
            ch,
            scroll
        )

    local monitorLayout = nil

    if monitor then
        if monitor.setTextScale then
            monitor.setTextScale(GUI_SCALE)
        end

        local mw, mh = monitor.getSize()

        monitorLayout =
            drawQueueScreenOn(
                monitor,
                mw,
                mh,
                scroll
            )
    end

    return {
        controller = controllerLayout,
        monitor = monitorLayout
    }
end

local function drawQueueInputScreenOn(
    target,
    targetWidth,
    targetHeight,
    value,
    message
)
    local oldDisplay = display
    local oldWidth = width
    local oldHeight = height

    display = target
    width = targetWidth
    height = targetHeight

    restoreControllerPalette()

    if display.setCursorBlink then
        display.setCursorBlink(false)
    end

    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    fillRect(1, 1, width, 3, colors.blue)
    centerText(
        1,
        "A D D   T O   Q U E U E",
        colors.white,
        colors.blue
    )

    centerText(
        2,
        "Song link or playlist link",
        colors.lightBlue,
        colors.blue
    )

    local boxX1 = 3
    local boxX2 = width - 2
    local boxY1 = 6
    local boxY2 = math.min(height - 6, 8)

    fillRect(
        boxX1,
        boxY1,
        boxX2,
        boxY2,
        colors.gray
    )

    writeAt(
        boxX1 + 1,
        boxY1,
        "LINK:",
        colors.lightGray,
        colors.gray
    )

    local shown = tostring(value or "")
    local maxLen = math.max(1, boxX2 - boxX1 - 2)

    if #shown > maxLen then
        shown =
            shown:sub(
                #shown - maxLen + 1
            )
    end

    if boxY1 + 1 <= boxY2 then
        writeAt(
            boxX1 + 1,
            boxY1 + 1,
            fitText(shown, maxLen),
            colors.white,
            colors.gray
        )
    end

    if message and message ~= "" and height >= 10 then
        centerText(
            math.min(10, height - 5),
            fitText(message, math.max(1, width - 4)),
            colors.yellow,
            colors.black
        )
    end

    local cancelW =
        math.min(
            14,
            math.max(
                10,
                math.floor(width / 3)
            )
        )

    local cancel = {
        x1 = math.floor((width - cancelW) / 2) + 1,
        y1 = math.max(1, height - 2),
        x2 = math.floor((width - cancelW) / 2) + cancelW,
        y2 = math.max(1, height - 1)
    }

    drawButton(
        cancel.x1,
        cancel.y1,
        cancel.x2,
        cancel.y2,
        "CANCEL",
        colors.red,
        colors.white
    )

    display = oldDisplay
    width = oldWidth
    height = oldHeight

    return cancel
end

local function drawQueueInputScreen(value, message)
    local cw, ch = controller.getSize()

    local controllerCancel =
        drawQueueInputScreenOn(
            controller,
            cw,
            ch,
            value,
            message
        )

    local monitorCancel = nil

    if monitor then
        if monitor.setTextScale then
            monitor.setTextScale(GUI_SCALE)
        end

        local mw, mh = monitor.getSize()

        monitorCancel =
            drawQueueInputScreenOn(
                monitor,
                mw,
                mh,
                value,
                message
            )
    end

    return {
        controller = controllerCancel,
        monitor = monitorCancel
    }
end

local function promptQueueLink()
    audioOverlayLocked = true

    local value = ""
    local message = ""

    local cancel =
        drawQueueInputScreen(
            value,
            message
        )

    while true do
        local event, p1, p2, p3 =
            os.pullEvent()

        if event == "char" then
            value = value .. p1
            cancel =
                drawQueueInputScreen(
                    value,
                    message
                )

        elseif event == "paste" then
            value =
                value
                .. tostring(p1 or "")

            cancel =
                drawQueueInputScreen(
                    value,
                    message
                )

        elseif event == "key" then
            if p1 == keys.backspace then
                if #value > 0 then
                    value =
                        value:sub(
                            1,
                            #value - 1
                        )
                end

                cancel =
                    drawQueueInputScreen(
                        value,
                        message
                    )

            elseif p1 == keys.enter then
                local cleaned =
                    value:match(
                        "^%s*(.-)%s*$"
                    )
                    or ""

                if cleaned == "" then
                    message =
                        "Enter a song or playlist link."

                    cancel =
                        drawQueueInputScreen(
                            value,
                            message
                        )
                else
                    audioOverlayLocked = false
                    return cleaned
                end
            end

        elseif event == "mouse_click" then
            if cancel.controller
               and inRect(
                    p2,
                    p3,
                    cancel.controller
               ) then

                audioOverlayLocked = false

                if controller.setCursorBlink then
                    controller.setCursorBlink(false)
                end

                return nil
            end

        elseif event == "monitor_touch" then
            if cancel.monitor
               and inRect(
                    p2,
                    p3,
                    cancel.monitor
               ) then

                audioOverlayLocked = false

                if monitor
                   and monitor.setCursorBlink then

                    monitor.setCursorBlink(false)
                end

                return nil
            end

        elseif event == "term_resize"
           or event == "monitor_resize" then

            cancel =
                drawQueueInputScreen(
                    value,
                    message
                )

        elseif event == "terminate" then
            audioOverlayLocked = false
            return nil
        end
    end
end

local function appendLinkToAudioQueue(link)
    link =
        tostring(link or "")
        :match("^%s*(.-)%s*$")
        or ""

    if link == "" then
        return false, "No link entered."
    end

    if isPlaylistUrl(link) then
        local data, err =
            resolvePlaylist(link)

        if not data then
            return false, tostring(err)
        end

        local added = 0

        for _, entry in ipairs(data.entries or {}) do
            if entry.url then
                table.insert(
                    audioQueue,
                    {
                        url = entry.url,
                        title =
                            entry.title
                            or entry.url
                    }
                )

                added = added + 1
            end
        end

        return true,
            "Added "
            .. tostring(added)
            .. " songs."
    end

    table.insert(
        audioQueue,
        {
            url = link,
            title = link
        }
    )

    return true, "Song added to queue."
end

local function showAudioQueue()
    audioOverlayLocked = true

    local scroll = 1
    local message = nil
    local layout = nil

    local function redraw()
        layout =
            drawQueueScreen(scroll)

        if message then
            local function drawMessageOn(target)
                local oldDisplay = display
                local oldWidth = width
                local oldHeight = height

                display = target
                width, height =
                    target.getSize()

                centerText(
                    math.max(
                        1,
                        height - 5
                    ),
                    fitText(
                        message,
                        math.max(
                            1,
                            width - 4
                        )
                    ),
                    colors.yellow,
                    colors.black
                )

                display = oldDisplay
                width = oldWidth
                height = oldHeight
            end

            drawMessageOn(controller)

            if monitor then
                drawMessageOn(monitor)
            end
        end
    end

    redraw()

    while true do
        local event, p1, p2, p3 =
            os.pullEvent()

        local activeLayout = nil
        local x = nil
        local y = nil

        if event == "mouse_click" then
            activeLayout =
                layout.controller
            x = p2
            y = p3

        elseif event == "monitor_touch"
           and layout.monitor then

            activeLayout =
                layout.monitor
            x = p2
            y = p3
        end

        if activeLayout then
            if inRect(
                x,
                y,
                activeLayout.back
            ) then

                audioOverlayLocked = false
                return

            elseif inRect(
                x,
                y,
                activeLayout.add
            ) then

                local link =
                    promptQueueLink()

                if link then
                    local ok, msg =
                        appendLinkToAudioQueue(
                            link
                        )

                    message = msg

                    if ok
                       and #audioQueue > 0 then

                        scroll =
                            math.max(
                                1,
                                #audioQueue
                                - activeLayout.visible
                                + 1
                            )
                    end
                end

                audioOverlayLocked = true
                redraw()

            elseif activeLayout.up
               and inRect(
                    x,
                    y,
                    activeLayout.up
               ) then

                local newScroll =
                    math.max(
                        1,
                        scroll - 1
                    )

                if newScroll ~= scroll then
                    scroll = newScroll
                    redraw()
                end

            elseif activeLayout.down
               and inRect(
                    x,
                    y,
                    activeLayout.down
               ) then

                local maxScroll =
                    math.max(
                        1,
                        #audioQueue
                        - activeLayout.visible
                        + 1
                    )

                local newScroll =
                    math.min(
                        maxScroll,
                        scroll + 1
                    )

                if newScroll ~= scroll then
                    scroll = newScroll
                    redraw()
                end
            end

        elseif event == "mouse_scroll" then
            local baseLayout =
                layout.controller

            local maxScroll =
                math.max(
                    1,
                    #audioQueue
                    - baseLayout.visible
                    + 1
                )

            local newScroll =
                scroll

            if p1 > 0 then
                newScroll =
                    math.min(
                        maxScroll,
                        scroll + 1
                    )
            else
                newScroll =
                    math.max(
                        1,
                        scroll - 1
                    )
            end

            if newScroll ~= scroll then
                scroll = newScroll
                redraw()
            end

        elseif event == "term_resize"
           or event == "monitor_resize" then

            redraw()

        elseif event == "terminate" then
            audioOverlayLocked = false
            return
        end
    end
end


local function flushOldPlaybackEvents()
    -- parallel.waitForAny() used by older versions could terminate the stock
    -- YouCube client while it still had queued playback/websocket events.
    -- Those stale events can be consumed by the next YouCube instance and make
    -- it end almost immediately.
    --
    -- Queue a marker at the END of the current event queue and drain everything
    -- that existed before it. This happens only immediately before starting a
    -- new media session.
    local marker =
        "__ycp_new_session_"
        .. tostring(os.epoch("utc"))
        .. "_"
        .. tostring(math.random(1, 1000000))

    os.queueEvent(marker)

    while true do
        local event = {os.pullEventRaw()}

        if event[1] == marker then
            break
        end
    end
end


local function loadYouCubeApiLibrary()
    -- Try normal require first.
    if require then
        local ok, lib = pcall(require, "youcubeapi")
        if ok and lib then
            return lib
        end
    end

    -- Locate the library beside the installed YouCube program.
    local program = resolveYouCube()
    local candidates = {}

    if program then
        local dir = fs.getDir(program)

        candidates[#candidates + 1] =
            fs.combine(dir, "lib/youcubeapi.lua")

        candidates[#candidates + 1] =
            fs.combine(dir, "youcubeapi.lua")
    end

    candidates[#candidates + 1] = "lib/youcubeapi.lua"
    candidates[#candidates + 1] = "/lib/youcubeapi.lua"
    candidates[#candidates + 1] = "youcubeapi.lua"

    for _, path in ipairs(candidates) do
        if fs.exists(path) and not fs.isDir(path) then
            local ok, lib = pcall(dofile, path)
            if ok and lib then
                return lib
            end
        end
    end

    return nil
end

local function getAllSpeakers()
    local speakers = {}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then
            local speaker = peripheral.wrap(name)

            if speaker and speaker.playAudio then
                speakers[#speakers + 1] = {
                    name = name,
                    device = speaker
                }
            end
        end
    end

    return speakers
end

local function playDecodedOnAllSpeakers(speakers, samples, shouldStop)
    for _, item in ipairs(speakers) do
        while true do
            if shouldStop and shouldStop() then
                return false
            end

            local ok =
                item.device.playAudio(samples)

            if ok then
                break
            end

            local event, side = os.pullEvent("speaker_audio_empty")

            if shouldStop and shouldStop() then
                return false
            end
        end
    end

    return true
end


local function isInternalErrorText(text)
    local lower = tostring(text or ""):lower()

    return lower:find("too many websockets", 1, true) ~= nil
        or lower:find("nativewebsocket", 1, true) ~= nil
        or lower:find("audio connection failed", 1, true) ~= nil
        or lower:find("audio request failed", 1, true) ~= nil
        or lower:find("audio server error", 1, true) ~= nil
        or lower:find("traceback", 1, true) ~= nil
end

local function normalizeMediaTarget(value)
    local mediaUrl =
        tostring(value or ""):match("^%s*(.-)%s*$") or ""

    if mediaUrl == "" then
        return nil, "Empty media target."
    end

    if isInternalErrorText(mediaUrl) then
        return nil, "Internal WebSocket error was blocked from becoming a media URL."
    end

    return mediaUrl
end

local function playAudioOnlyOnce(search, playlistInfo)
    local mediaUrl, mediaTargetError =
        normalizeMediaTarget(search)

    if not mediaUrl then
        status = mediaTargetError
        return "error"
    end

    local youcubeapi = loadYouCubeApiLibrary()

    if not youcubeapi then
        status = "YouCube API library not found. Reinstall YouCube."
        return "error"
    end

    local okDfpwm, dfpwm =
        pcall(require, "cc.audio.dfpwm")

    if not okDfpwm or not dfpwm then
        status = "This CC version does not support DFPWM audio."
        return "error"
    end

    local speakers = getAllSpeakers()

    if #speakers == 0 then
        status = "Audio Only: no speakers connected."
        return "error"
    end

    stopAllSpeakers()

    local state = {
        title =
            playlistInfo
            and playlistInfo.title
            or "Loading...",

        duration = nil,
        elapsed = 0,
        speakerCount = #speakers,
        status = "Connecting to audio server...",
        skipReady = false
    }

    local layout = drawAudioOnlyScreen(state)
    local requestedAction = nil
    local playbackStarted = false
    local startedAt = nil
    local streamError = nil
    local streamEnded = false
    local lastBufferDuration = 0

    -- Close any socket left by THIS version before opening a new one.
    if activeAudioSocket then
        pcall(function()
            activeAudioSocket.close()
        end)
        activeAudioSocket = nil
        sleep(0)
    end

    -- IMPORTANT:
    -- Open the native websocket BEFORE starting the parallel GUI loop.
    -- This prevents a Cancel/Skip coroutine from terminating a half-open
    -- http.websocket() call and leaking a native websocket slot.
    local socket, openErr =
        http.websocket(YOUCUBE_SERVER)

    if not socket then
        status =
            "Audio connection failed: "
            .. tostring(openErr or "unknown error")

        return "error"
    end

    activeAudioSocket = socket
    local ws = socket

    local function closeSocket()
        if ws then
            pcall(function()
                ws.close()
            end)

            if activeAudioSocket == ws then
                activeAudioSocket = nil
            end

            ws = nil

            -- Give CC:Tweaked a scheduler turn to release the native handle.
            sleep(0)
        end
    end

    local function shouldStop()
        return requestedAction == "cancel"
            or requestedAction == "skip"
    end

    local api =
        youcubeapi.API.new(socket)

    local okRequest, requestErr =
        pcall(function()
            api:request_media(mediaUrl)
        end)

    if not okRequest then
        closeSocket()

        status =
            "Audio request failed: "
            .. tostring(requestErr)

        return "error"
    end

    local function streamAudio()
        local media = nil

        while not shouldStop() do
            local okReceive, data =
                pcall(function()
                    return api:receive()
                end)

            if not okReceive then
                streamError =
                    "Audio server error: "
                    .. tostring(data)
                return
            end

            if not data then
                streamError = "Audio server closed the connection."
                return
            end

            if data.action == "status" then
                state.status =
                    fitText(
                        tostring(data.message or "Loading..."),
                        math.max(10, width - 4)
                    )

                if not audioOverlayLocked then
                    layout = drawAudioOnlyScreen(state)
                end

            elseif data.action == "error" then
                streamError =
                    tostring(
                        data.message
                        or "Server returned an audio error."
                    )
                return

            elseif data.action == "media" then
                media = data
                break
            end
        end

        if shouldStop() then
            return
        end

        if not media or not media.id then
            streamError = "Server did not return playable media."
            return
        end

        state.title =
            media.title
            or state.title
            or "Unknown Song"

        state.duration =
            tonumber(media.duration)

        state.status = "Buffering audio..."

        if not audioOverlayLocked then
            layout = drawAudioOnlyScreen(state)
        end

        local decoder =
            dfpwm.make_decoder()

        local chunkIndex = 0

        while not shouldStop() do
            local okChunk, chunk =
                pcall(function()
                    return api:get_chunk(
                        chunkIndex,
                        media.id
                    )
                end)

            if not okChunk then
                streamError =
                    "Audio stream failed: "
                    .. tostring(chunk)
                return
            end

            if chunk == nil or chunk == "" then
                streamEnded = true
                break
            end

            local samples =
                decoder(chunk)

            if not playbackStarted then
                playbackStarted = true
                state.skipReady = true
                startedAt = os.epoch("utc") / 1000
                state.elapsed = 0

                state.status =
                    "Playing on "
                    .. tostring(#speakers)
                    .. (
                        #speakers == 1
                        and " speaker"
                        or " speakers"
                    )

                if not audioOverlayLocked then
                    layout = drawAudioOnlyScreen(state)
                end
            end

            lastBufferDuration =
                #samples / 48000

            local accepted =
                playDecodedOnAllSpeakers(
                    speakers,
                    samples,
                    shouldStop
                )

            if not accepted then
                break
            end

            chunkIndex = chunkIndex + 1
        end

        if streamEnded
           and not shouldStop()
           and lastBufferDuration > 0 then

            sleep(lastBufferDuration)
        end
    end

    local function controlGui()
        local refreshTimer =
            os.startTimer(0.25)

        while true do
            local event, p1, p2, p3 =
                os.pullEventRaw()

            if event == "mouse_click" and not USING_MONITOR then
                event = "monitor_touch"
            end

            if event == "mouse_click" then
                local x = p2
                local y = p3
                local activeLayout = layout.controller

                if inRect(x, y, activeLayout.cancel) then
                    requestedAction = "cancel"
                    state.status = "Returning to search..."
                    drawAudioOnlyScreen(state)
                    return

                elseif inRect(x, y, activeLayout.skip) then
                    if not state.skipReady then
                        state.status =
                            "Skip available when playback starts."

                        layout =
                            drawAudioOnlyScreen(state)

                    else
                        requestedAction = "skip"
                        state.skipReady = false
                        state.status = "Skipping song..."
                        drawAudioOnlyScreen(state)
                        return
                    end

                elseif inRect(x, y, activeLayout.upnext) then
                    audioOverlayLocked = true
                    showAudioQueue()
                    audioOverlayLocked = false
                    display.setCursorBlink(false)

                    refreshTimer =
                        os.startTimer(0.25)

                    if startedAt then
                        state.elapsed =
                            math.max(
                                0,
                                (os.epoch("utc") / 1000)
                                - startedAt
                            )

                        if state.duration then
                            state.elapsed =
                                math.min(
                                    state.elapsed,
                                    state.duration
                                )
                        end
                    end

                    layout =
                        drawAudioOnlyScreen(state)

                elseif inRect(x, y, activeLayout.loop) then
                    audioLoopEnabled =
                        not audioLoopEnabled

                    state.status =
                        audioLoopEnabled
                        and "Loop enabled for current song."
                        or "Loop disabled."

                    layout =
                        drawAudioOnlyScreen(state)
                end

            elseif event == "monitor_touch" and monitor and layout.monitor then
                local x = p2
                local y = p3
                local activeLayout = layout.monitor

                if inRect(x, y, activeLayout.cancel) then
                    requestedAction = "cancel"
                    state.status = "Returning to search..."
                    layout = drawAudioOnlyScreen(state)
                    return

                elseif inRect(x, y, activeLayout.skip) then
                    if not state.skipReady then
                        state.status =
                            "Skip available when playback starts."
                        layout = drawAudioOnlyScreen(state)
                    else
                        requestedAction = "skip"
                        state.skipReady = false
                        state.status = "Skipping song..."
                        layout = drawAudioOnlyScreen(state)
                        return
                    end

                elseif inRect(x, y, activeLayout.upnext) then
                    audioOverlayLocked = true
                    showAudioQueue()
                    audioOverlayLocked = false

                    if controller.setCursorBlink then
                        controller.setCursorBlink(false)
                    end

                    if monitor.setCursorBlink then
                        monitor.setCursorBlink(false)
                    end

                    refreshTimer = os.startTimer(0.25)

                    if startedAt then
                        state.elapsed =
                            math.max(
                                0,
                                (os.epoch("utc") / 1000) - startedAt
                            )

                        if state.duration then
                            state.elapsed =
                                math.min(
                                    state.elapsed,
                                    state.duration
                                )
                        end
                    end

                    layout = drawAudioOnlyScreen(state)

                elseif inRect(x, y, activeLayout.loop) then
                    audioLoopEnabled = not audioLoopEnabled

                    state.status =
                        audioLoopEnabled
                        and "Loop enabled for current song."
                        or "Loop disabled."

                    layout = drawAudioOnlyScreen(state)
                end

            elseif event == "timer"
               and p1 == refreshTimer then

                if startedAt then
                    state.elapsed =
                        math.max(
                            0,
                            (os.epoch("utc") / 1000)
                            - startedAt
                        )

                    if state.duration then
                        state.elapsed =
                            math.min(
                                state.elapsed,
                                state.duration
                            )
                    end
                end

                if not audioOverlayLocked then
                    layout =
                        drawAudioOnlyScreen(state)
                end

                refreshTimer =
                    os.startTimer(0.25)

            elseif event == "term_resize"
               or event == "monitor_resize" then

                layout = drawAudioOnlyScreen(state)

            elseif event == "terminate" then
                requestedAction = "cancel"
                return
            end
        end
    end

    parallel.waitForAny(
        streamAudio,
        controlGui
    )

    -- ALWAYS close the one active socket before returning or advancing queue.
    closeSocket()
    stopAllSpeakers()

    audioOverlayLocked = false
    restoreControllerPalette()
    display.setCursorBlink(false)
    display.setBackgroundColor(C.bg)
    display.setTextColor(C.text)
    display.clear()

    width, height = display.getSize()

    if requestedAction == "cancel" then
        status = "Returned to search."
        return "cancel"
    end

    if requestedAction == "skip" then
        status = "Song skipped."
        return "skip"
    end

    if streamError then
        status = streamError
        return "error"
    end

    if not playbackStarted then
        status = "Audio ended before playback started."
        return "error"
    end

    if streamEnded then
        status = "Song finished."
        return "ended"
    end

    status = "Audio playback stopped unexpectedly."
    return "error"
end

local function playAudioOnly(search, playlistInfo)
    while true do
        local action =
            playAudioOnlyOnce(
                search,
                playlistInfo
            )

        if action ~= "ended" then
            return action
        end

        if not audioLoopEnabled then
            return action
        end

        status = "Looping current song..."
    end
end

local function playYouCube(search, playlistInfo)
    if not monitor then
        status = "Connect an Advanced Monitor to play video."
        drawSearch()
        return "error"
    end

    -- While video mode owns the monitor, replace the computer keyboard with
    -- a dedicated status/control screen.
    local terminalVideoState = "downloading"
    local terminalControlsReady = false
    local videoQueueOpen = false
    local videoQueueInputOpen = false
    local videoStartedAt = nil
    local videoElapsed = 0
    local videoDuration = nil

    local videoEntries =
        playlistInfo
        and playlistInfo.entriesRef
        or nil

    local videoIndex =
        playlistInfo
        and tonumber(playlistInfo.index)
        or 1

    local videoLoopEnabled = false

    local function terminalVideoLayout()
        local tw, th = controller.getSize()

        local gap = 1
        local available = math.max(32, tw - 6)
        local buttonW = math.floor((available - (gap * 3)) / 4)
        buttonW = math.max(7, math.min(14, buttonW))

        local total = (buttonW * 4) + (gap * 3)
        local sx = math.max(1, math.floor((tw - total) / 2) + 1)
        local buttonY = math.max(8, th - 5)

        return {
            close = {
                x1=sx,
                y1=buttonY,
                x2=sx+buttonW-1,
                y2=buttonY+1
            },

            next = {
                x1=sx+buttonW+gap,
                y1=buttonY,
                x2=sx+(buttonW*2)+gap-1,
                y2=buttonY+1
            },

            queue = {
                x1=sx+(buttonW*2)+(gap*2),
                y1=buttonY,
                x2=sx+(buttonW*3)+(gap*2)-1,
                y2=buttonY+1
            },

            loop = {
                x1=sx+(buttonW*3)+(gap*3),
                y1=buttonY,
                x2=sx+(buttonW*4)+(gap*3)-1,
                y2=buttonY+1
            }
        }
    end

    local function drawTerminalVideoGui()
        local oldDisplay = display
        local oldWidth = width
        local oldHeight = height

        display = controller
        width, height = controller.getSize()

        restoreControllerPalette()

        if controller.setCursorBlink then
            controller.setCursorBlink(false)
        end

        controller.setBackgroundColor(colors.black)
        controller.setTextColor(colors.white)
        controller.clear()

        local layout = terminalVideoLayout()

        fillRect(1,1,width,3,colors.blue)
        centerText(1,"Y O U C U B E   V I D E O",colors.white,colors.blue)
        centerText(2,"Video Player",colors.lightBlue,colors.blue)

        local cardTop = 5
        local cardBottom = math.max(cardTop + 7, layout.next.y1 - 2)

        fillRect(
            math.max(2, math.floor(width * 0.05)),
            cardTop,
            math.min(width - 1, width - math.max(2, math.floor(width * 0.05)) + 1),
            cardBottom,
            colors.gray
        )

        local panelX1 = math.max(2, math.floor(width * 0.05))
        local panelX2 = math.min(width - 1, width - panelX1 + 1)
        local innerX = panelX1 + 2
        local innerWidth = math.max(1, panelX2 - innerX - 1)

        writeAt(
            innerX,
            cardTop + 1,
            "CURRENT VIDEO",
            colors.lightGray,
            colors.gray
        )

        writeAt(
            innerX,
            cardTop + 2,
            fitText(
                (playlistInfo and playlistInfo.title)
                or search
                or "Loading...",
                innerWidth
            ),
            colors.white,
            colors.gray
        )

        writeAt(
            innerX,
            cardTop + 4,
            "Duration:",
            colors.lightGray,
            colors.gray
        )

        writeAt(
            innerX + 10,
            cardTop + 4,
            videoDuration and formatTime(videoDuration) or "--:--",
            colors.white,
            colors.gray
        )

        writeAt(
            innerX,
            cardTop + 5,
            "Current Time:",
            colors.lightGray,
            colors.gray
        )

        writeAt(
            innerX + 14,
            cardTop + 5,
            formatTime(videoElapsed or 0),
            colors.white,
            colors.gray
        )

        if playlistInfo then
            writeAt(
                innerX,
                cardTop + 6,
                "Queue:",
                colors.lightGray,
                colors.gray
            )

            writeAt(
                innerX + 7,
                cardTop + 6,
                tostring(videoIndex)
                .. " / "
                .. tostring(
                    videoEntries
                    and #videoEntries
                    or playlistInfo.count
                    or 1
                ),
                colors.white,
                colors.gray
            )
        end

        local barY = math.min(cardBottom - 1, cardTop + 8)
        local barX1 = innerX
        local barX2 = math.max(barX1, panelX2 - 2)
        local barWidth = math.max(1, barX2 - barX1 + 1)

        fillRect(
            barX1,
            barY,
            barX2,
            barY,
            colors.lightGray
        )

        if videoDuration
           and videoDuration > 0 then

            local progress =
                math.max(
                    0,
                    math.min(
                        1,
                        (videoElapsed or 0)
                        / videoDuration
                    )
                )

            local filled =
                math.floor(barWidth * progress)

            if filled > 0 then
                fillRect(
                    barX1,
                    barY,
                    barX1 + filled - 1,
                    barY,
                    colors.lime
                )
            end
        end

        drawButton(
            layout.close.x1,layout.close.y1,
            layout.close.x2,layout.close.y2,
            "CLOSE",
            colors.red,
            colors.white
        )

        drawButton(
            layout.next.x1,layout.next.y1,
            layout.next.x2,layout.next.y2,
            terminalControlsReady and "NEXT" or "LOADING",
            terminalControlsReady and colors.orange or colors.gray,
            terminalControlsReady and colors.black or colors.lightGray
        )

        drawButton(
            layout.queue.x1,layout.queue.y1,
            layout.queue.x2,layout.queue.y2,
            "UP NEXT",
            colors.lightBlue,
            colors.black
        )

        drawButton(
            layout.loop.x1,layout.loop.y1,
            layout.loop.x2,layout.loop.y2,
            videoLoopEnabled and "LOOP: ON" or "LOOP: OFF",
            videoLoopEnabled and colors.lime or colors.red,
            videoLoopEnabled and colors.black or colors.white
        )

        centerText(
            height,
            terminalVideoState == "downloading"
                and "Video downloading..."
                or "Video playing",
            colors.lightGray,
            colors.black
        )

        display = oldDisplay
        width = oldWidth
        height = oldHeight

        return layout
    end

    local function drawVideoQueueTerminal(message, scroll)
        local oldDisplay, oldWidth, oldHeight = display, width, height
        display = controller
        width, height = controller.getSize()

        restoreControllerPalette()
        controller.setBackgroundColor(C.bg)
        controller.setTextColor(C.text)
        controller.clear()

        fillRect(1,1,width,2,colors.blue)
        centerText(1,"VIDEO QUEUE",colors.white,colors.blue)

        local upcoming = videoEntries and math.max(0,#videoEntries-videoIndex) or 0
        centerText(2,tostring(upcoming).." upcoming",colors.lightBlue,colors.blue)

        local listTop = 4
        local listBottom = math.max(listTop,height-6)
        local visible = math.max(1,listBottom-listTop+1)

        fillRect(2,listTop,width-1,listBottom,colors.gray)

        local queueStart = videoIndex + 1
        local firstIndex = queueStart + (scroll - 1)

        if upcoming == 0 then
            centerText(
                math.floor((listTop+listBottom)/2),
                "No upcoming videos",
                colors.lightGray,
                colors.gray
            )
        else
            local row = listTop
            local idx = firstIndex

            while row <= listBottom and videoEntries and idx <= #videoEntries do
                local e = videoEntries[idx]
                local label =
                    tostring(idx-videoIndex)
                    .. ". "
                    .. tostring((e and (e.title or e.url)) or "Unknown video")

                writeAt(
                    3,
                    row,
                    fitText(label,math.max(1,width-7)),
                    colors.white,
                    colors.gray
                )

                row = row + 1
                idx = idx + 1
            end
        end

        local up = nil
        local down = nil

        if upcoming > visible then
            up = {
                x1=width-4,y1=listTop,
                x2=width-2,y2=listTop
            }

            down = {
                x1=width-4,y1=listBottom,
                x2=width-2,y2=listBottom
            }

            drawButton(
                up.x1,up.y1,up.x2,up.y2,
                "^",colors.lightBlue,colors.black
            )

            drawButton(
                down.x1,down.y1,down.x2,down.y2,
                "v",colors.lightBlue,colors.black
            )
        end

        local mid = math.floor(width/2)
        local add = {x1=2,y1=height-2,x2=mid-1,y2=height-1}
        local back = {x1=mid+2,y1=height-2,x2=width-1,y2=height-1}

        drawButton(add.x1,add.y1,add.x2,add.y2,"ADD",colors.lime,colors.black)
        drawButton(back.x1,back.y1,back.x2,back.y2,"BACK",colors.lightGray,colors.black)

        if message and message ~= "" then
            centerText(
                math.max(3,height-4),
                fitText(message,math.max(1,width-2)),
                colors.yellow,
                C.bg
            )
        end

        display, width, height = oldDisplay, oldWidth, oldHeight

        return {
            add=add,
            back=back,
            up=up,
            down=down,
            visible=visible,
            upcoming=upcoming
        }
    end

    local function drawVideoQueueInputTerminal(value, message)
        local oldDisplay = display
        local oldWidth = width
        local oldHeight = height

        display = controller
        width, height = controller.getSize()

        restoreControllerPalette()

        if controller.setCursorBlink then
            controller.setCursorBlink(false)
        end

        controller.setBackgroundColor(C.bg)
        controller.setTextColor(C.text)
        controller.clear()

        fillRect(1,1,width,3,colors.blue)
        centerText(1,"ADD TO VIDEO QUEUE",colors.white,colors.blue)
        centerText(2,"Paste or type a video/playlist link",colors.lightBlue,colors.blue)

        local boxX1 = 2
        local boxX2 = math.max(boxX1 + 8, width - 1)
        local boxY1 = 5
        local boxY2 = math.min(height - 6, 7)

        fillRect(boxX1,boxY1,boxX2,boxY2,colors.gray)

        writeAt(
            boxX1 + 1,
            boxY1,
            "LINK:",
            colors.lightGray,
            colors.gray
        )

        local shown = tostring(value or "")
        local room = math.max(1, boxX2 - boxX1 - 2)

        if #shown > room then
            shown = shown:sub(#shown - room + 1)
        end

        if boxY1 + 1 <= boxY2 then
            writeAt(
                boxX1 + 1,
                boxY1 + 1,
                fitText(shown, room),
                colors.white,
                colors.gray
            )
        end

        if message and message ~= "" then
            centerText(
                math.max(9, height - 6),
                fitText(message, math.max(1, width - 2)),
                colors.yellow,
                C.bg
            )
        end

        local gap = 2
        local buttonW = math.max(8, math.min(14, math.floor((width - 6) / 2)))
        local total = buttonW * 2 + gap
        local sx = math.max(1, math.floor((width - total) / 2) + 1)
        local by = math.max(10, height - 3)

        local add = {
            x1=sx,
            y1=by,
            x2=sx+buttonW-1,
            y2=by+1
        }

        local cancel = {
            x1=add.x2+gap+1,
            y1=by,
            x2=add.x2+gap+buttonW,
            y2=by+1
        }

        drawButton(
            add.x1,add.y1,add.x2,add.y2,
            "ADD",
            value ~= "" and colors.lime or colors.gray,
            value ~= "" and colors.black or colors.lightGray
        )

        drawButton(
            cancel.x1,cancel.y1,cancel.x2,cancel.y2,
            "CANCEL",
            colors.red,
            colors.white
        )

        display = oldDisplay
        width = oldWidth
        height = oldHeight

        return add, cancel
    end

    local function promptVideoQueueLink()
        videoQueueInputOpen = true

        local value = ""
        local message = ""
        local addButton, cancelButton =
            drawVideoQueueInputTerminal(value, message)

        while videoQueueInputOpen do
            local event,p1,p2,p3 =
                os.pullEventRaw()

            if event == "char" then
                value = value .. p1

                addButton, cancelButton =
                    drawVideoQueueInputTerminal(
                        value,
                        message
                    )

            elseif event == "paste" then
                value =
                    value
                    .. tostring(p1 or "")

                addButton, cancelButton =
                    drawVideoQueueInputTerminal(
                        value,
                        message
                    )

            elseif event == "key" then
                if p1 == keys.backspace then
                    if #value > 0 then
                        value =
                            value:sub(
                                1,
                                #value - 1
                            )
                    end

                    addButton, cancelButton =
                        drawVideoQueueInputTerminal(
                            value,
                            message
                        )

                elseif p1 == keys.enter then
                    local cleaned =
                        value:match("^%s*(.-)%s*$")
                        or ""

                    if cleaned ~= "" then
                        videoQueueInputOpen = false
                        return cleaned
                    else
                        message =
                            "Enter a video or playlist link."

                        addButton, cancelButton =
                            drawVideoQueueInputTerminal(
                                value,
                                message
                            )
                    end
                end

            elseif event == "mouse_click" then
                if inRect(p2,p3,cancelButton) then
                    videoQueueInputOpen = false
                    return nil

                elseif inRect(p2,p3,addButton) then
                    local cleaned =
                        value:match("^%s*(.-)%s*$")
                        or ""

                    if cleaned ~= "" then
                        videoQueueInputOpen = false
                        return cleaned
                    else
                        message =
                            "Enter a video or playlist link."

                        addButton, cancelButton =
                            drawVideoQueueInputTerminal(
                                value,
                                message
                            )
                    end
                end

            elseif event == "term_resize" then
                addButton, cancelButton =
                    drawVideoQueueInputTerminal(
                        value,
                        message
                    )

            elseif event == "terminate" then
                videoQueueInputOpen = false
                return nil
            end
        end

        return nil
    end

    local function appendToVideoQueue(link)
        if not videoEntries then
            return false,"Queue is unavailable."
        end

        if isPlaylistUrl(link) then
            local data, err = resolvePlaylist(link)
            if not data then return false,tostring(err) end

            local added = 0
            for _,entry in ipairs(data.entries or {}) do
                local cleanUrl = canonicalYouTubeVideoUrl(entry)
                if cleanUrl then
                    videoEntries[#videoEntries+1] = {
                        url = cleanUrl,
                        title = entry.title or entry.name or cleanUrl
                    }
                    added = added + 1
                end
            end

            return true,"Added "..tostring(added).." videos."
        end

        videoEntries[#videoEntries+1] = {url=link,title=link}
        return true,"Video added."
    end

    local function showVideoQueueTerminal()
        videoQueueOpen = true
        local message = nil
        local scroll = 1
        local queueOpen = true
        local layout = nil
        local refreshTimer = os.startTimer(0.25)

        local function redrawQueue()
            layout = drawVideoQueueTerminal(message,scroll)
        end

        redrawQueue()

        while queueOpen do
            local event,p1,p2,p3 =
                os.pullEventRaw()

            if event == "mouse_click" then
                if inRect(p2,p3,layout.back) then
                    queueOpen = false

                elseif inRect(p2,p3,layout.add) then
                    local link = promptVideoQueueLink()

                    if link then
                        local _,msg = appendToVideoQueue(link)
                        message = msg
                    end

                    redrawQueue()

                elseif layout.up
                   and inRect(p2,p3,layout.up) then

                    scroll = math.max(1,scroll-1)
                    redrawQueue()

                elseif layout.down
                   and inRect(p2,p3,layout.down) then

                    local maxScroll =
                        math.max(
                            1,
                            layout.upcoming
                            - layout.visible
                            + 1
                        )

                    scroll = math.min(maxScroll,scroll+1)
                    redrawQueue()
                end

            elseif event == "mouse_scroll" then
                local maxScroll =
                    math.max(
                        1,
                        layout.upcoming
                        - layout.visible
                        + 1
                    )

                if p1 > 0 then
                    scroll = math.min(maxScroll,scroll+1)
                else
                    scroll = math.max(1,scroll-1)
                end

                redrawQueue()

            elseif event == "timer"
               and p1 == refreshTimer then

                -- Keep playback time alive while queue is open.
                if videoStartedAt then
                    videoElapsed =
                        math.max(
                            0,
                            (os.epoch("utc")/1000)
                            - videoStartedAt
                        )

                    if videoDuration then
                        videoElapsed =
                            math.min(
                                videoElapsed,
                                videoDuration
                            )
                    end
                end

                refreshTimer = os.startTimer(0.25)

            elseif event == "term_resize" then
                redrawQueue()

            elseif event == "terminate" then
                queueOpen = false
            end
        end

        -- Queue is no longer on screen. This MUST be cleared or the main
        -- playback timer will keep suppressing terminal redraws forever.
        videoQueueOpen = false
        videoQueueInputOpen = false

        -- Repaint the live player immediately when leaving queue.
    

    drawTerminalVideoGui()
    end

    drawTerminalVideoGui()

    settings.set("youcube.server", YOUCUBE_SERVER)
    settings.save()

    local program = resolveYouCube()

    if not program then
        status = "Install YouCube: pastebin run swsmNAf7"
        return "error"
    end

    local oldTerm = controller
    local oldScale = GUI_SCALE

    if monitor.getTextScale then
        oldScale = monitor.getTextScale()
    end

    local playbackScale =
        choosePlaybackScale
        and choosePlaybackScale()
        or GUI_SCALE

    if monitor.setTextScale then
        monitor.setTextScale(playbackScale)
    end
    monitor.setCursorBlink(false)

    width, height = monitor.getSize()

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    local closeX1 = math.max(1, width - 4)
    local action = "ended"
    local playerDone = false
local nextButton = {
        x1=8,y1=1,x2=13,y2=1
    }

    local doneEvent =
        "__ycp_video_done_"
        .. tostring(os.epoch("utc"))
        .. "_"
        .. tostring(math.random(1, 1000000))

    local function drawOverlay()
        -- drawButton()/writeAt()/fillRect() all use the global `display`.
        -- During normal GUI operation that points at the Advanced Computer.
        -- For video playback, explicitly switch them to the monitor so the
        -- overlay graphics and touch hitboxes are on the SAME surface.
        local oldDisplay = display
        local oldWidth = width
        local oldHeight = height

        display = monitor
        width, height = monitor.getSize()

        if playlistInfo then
drawButton(
                nextButton.x1,nextButton.y1,
                nextButton.x2,nextButton.y2,
                "NEXT",
                colors.gray,
                colors.white
            )

            local counter =
                tostring(playlistInfo.index)
                .. "/"
                .. tostring(playlistInfo.count)

            writeAt(
                math.max(
                    15,
                    math.floor(width / 2)
                    - math.floor(#counter / 2)
                ),
                1,
                counter,
                colors.white,
                colors.black
            )
        end

        drawButton(
            math.max(1, width - 4),
            1,
            width,
            1,
            "[X]",
            colors.red,
            colors.white
        )

        display = oldDisplay
        width = oldWidth
        height = oldHeight
    end

    -- =====================================================
    -- VIDEO WEBSOCKET OWNERSHIP
    -- =====================================================
    -- The stock YouCube client opens its own WebSocket(s). If we simply
    -- terminate the child program, CC:Tweaked may keep those native socket
    -- handles alive until GC, eventually causing "Too many websockets".
    --
    -- We run ONLY the child YouCube program with a private `http` table whose
    -- websocket() function records every handle it creates. Cleanup closes
    -- ONLY those handles. Other programs/computers are never touched.
    local ownedVideoSockets = {}
    local ownedVideoSocketSet = {}

    local function registerOwnedVideoSocket(socket)
        if socket
           and not ownedVideoSocketSet[socket] then

            ownedVideoSocketSet[socket] = true
            ownedVideoSockets[#ownedVideoSockets + 1] = socket
        end

        return socket
    end

    local function closeOwnedVideoSockets()
        for i = #ownedVideoSockets, 1, -1 do
            local socket = ownedVideoSockets[i]

            if socket then
                pcall(function()
                    socket.close()
                end)
            end

            ownedVideoSocketSet[socket] = nil
            ownedVideoSockets[i] = nil
        end

        -- Give CC:Tweaked's scheduler a chance to release the native handles.
        sleep(0)
    end

    local function runTrackedYouCube(programPath, ...)
        local realWebsocket = http.websocket

        local function trackedWebsocket(...)
            local socket, err =
                realWebsocket(...)

            if socket then
                registerOwnedVideoSocket(socket)
            end

            return socket, err
        end

        -- Keep YouCube in the normal CraftOS/shell environment. We replace
        -- only http.websocket for the duration of this synchronous child run,
        -- then restore the exact original function afterward.
        http.websocket = trackedWebsocket

        local args = {...}

        local ok, result =
            pcall(function()
                return shell.run(
                    programPath,
                    table.unpack(args)
                )
            end)

        http.websocket = realWebsocket

        if not ok then
            error(result, 0)
        end

        return result
    end

    local function fetchVideoDuration(targetUrl)
        local okLib, youcubeapi =
            pcall(loadYouCubeApiLibrary)

        if not okLib or not youcubeapi then
            return nil
        end

        local socket = nil

        local okSocket, socketOrErr =
            pcall(
                http.websocket,
                YOUCUBE_SERVER
            )

        if not okSocket or not socketOrErr then
            return nil
        end

        socket = socketOrErr
        registerOwnedVideoSocket(socket)

        local okApi, api =
            pcall(
                youcubeapi.API.new,
                socket
            )

        if not okApi or not api then
            pcall(function()
                socket.close()
            end)

            ownedVideoSocketSet[socket] = nil
            return nil
        end

        local result = nil

        local okRequest =
            pcall(function()
                api:request_media(targetUrl)
            end)

        if okRequest then
            while true do
                local okReceive, data =
                    pcall(function()
                        return api:receive()
                    end)

                if not okReceive or not data then
                    break
                end

                if data.action == "media" then
                    result =
                        tonumber(data.duration)
                    break

                elseif data.action == "error" then
                    break
                end
            end
        end

        pcall(function()
            socket.close()
        end)

        ownedVideoSocketSet[socket] = nil

        for i = #ownedVideoSockets, 1, -1 do
            if ownedVideoSockets[i] == socket then
                table.remove(ownedVideoSockets, i)
                break
            end
        end

        return result
    end

    local function runPlayer()
        if not videoDuration then
            local duration =
                fetchVideoDuration(search)

            if duration then
                videoDuration = duration
            end
        end
        term.redirect(monitor)

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()
        monitor.setCursorPos(1,1)

        local ok, result =
            pcall(
                runTrackedYouCube,
                program,
                search
            )

        local err =
            (not ok)
            and result
            or nil

        pcall(function()
            term.redirect(oldTerm)
        end)

        -- Always close every WebSocket opened by THIS playback instance before
        -- allowing the playlist/menu to continue.
        closeOwnedVideoSockets()

        if not ok and action == "ended" then
            status =
                "YouCube error: "
                .. tostring(err)

            action = "error"
        elseif action == "ended" then
            status = "Playback ended."
        end

        playerDone = true
        os.queueEvent(doneEvent)
    end

    local function controlWatcher()
        drawOverlay()

        local overlayTimer =
            os.startTimer(0.05)

        local videoClockTimer =
            os.startTimer(0.25)

        while not playerDone do
            -- pullEventRaw lets our watcher survive the terminate event that
            -- is deliberately sent to the stock YouCube process for [X].
            local event,p1,p2,p3 =
                os.pullEventRaw()

            if event == "mouse_click" and not USING_MONITOR then
                event = "monitor_touch"
            end

            if event == "youcube:vid_playing"
               or event == "youcube:playing" then

                local data = type(p1) == "table" and p1 or {}

                if not terminalControlsReady then
                    terminalControlsReady = true
                    terminalVideoState = "playing"
                    videoStartedAt = os.epoch("utc") / 1000
                    videoElapsed = 0
                end

                if data.duration then
                    videoDuration = tonumber(data.duration) or videoDuration
                end

                drawTerminalVideoGui()

            elseif event == doneEvent then
                break

            elseif event == "mouse_click" then
                local x = p2
                local y = p3

                do
                    local controls = terminalVideoLayout()

                    if inRect(x,y,controls.queue) then
                        local elapsedBeforeQueue = videoElapsed or 0
                        showVideoQueueTerminal()

                        -- Defensive reset in case the queue exits through a
                        -- resize/terminate/cancel path.
                        videoQueueOpen = false
                        videoQueueInputOpen = false

                        if terminalControlsReady then
                            -- Re-anchor elapsed time so time spent in the queue
                            -- is included, then create a NEW refresh timer.
                            local now = os.epoch("utc") / 1000
                            videoElapsed =
                                math.max(
                                    elapsedBeforeQueue,
                                    now - (videoStartedAt or now)
                                )

                            videoStartedAt =
                                now - videoElapsed
                        end

                        overlayTimer =
                            os.startTimer(0.05)

                        drawTerminalVideoGui()

                    elseif inRect(x,y,controls.loop) then
                        videoLoopEnabled = not videoLoopEnabled
                        drawTerminalVideoGui()

                    elseif inRect(x,y,controls.close) then
                        -- Terminate the ACTUAL stock YouCube player.
                        -- Do not merely stop speakers or fake player completion.
                        action = "stop"
                        os.queueEvent("terminate")

                    elseif playlistInfo
                       and terminalControlsReady
                       and inRect(x,y,controls.next) then

                        action = "next"

                        local skipKey =
                            settings.get("youcube.keys.skip")
                            or keys.d

                        -- Use YouCube's own Skip control so it ends the current
                        -- item immediately and closes its playback resources.
                        os.queueEvent(
                            "key",
                            skipKey,
                            false
                        )
                    end
                end

            elseif event == "monitor_touch" then
                local x = p2
                local y = p3

                -- Repaint immediately because the video renderer may have
                -- overwritten the overlay on the previous frame.
                drawOverlay()

                if y == 1
                   and x >= closeX1
                   and action == "ended" then

                    action = "stop"

                    -- Ask the stock client to terminate itself. Do NOT return
                    -- from this watcher until runPlayer actually exits.
                    os.queueEvent("terminate")

                elseif playlistInfo
                   and y == 1
                   and action == "ended" then
                    if false then


                    elseif inRect(
                        x,y,nextButton
                    ) then
                        action = "next"

                        local skipKey =
                            settings.get("youcube.keys.skip")
                            or keys.d

                        -- Let YouCube handle Skip normally so it can close its
                        -- WebSocket before the next playlist item starts.
                        os.queueEvent(
                            "key",
                            skipKey,
                            false
                        )
                    end
                end

            elseif event == "timer"
               and p1 == overlayTimer then

                if videoStartedAt then
                    videoElapsed = math.max(0,(os.epoch("utc")/1000)-videoStartedAt)
                    if videoDuration then
                        videoElapsed = math.min(videoElapsed,videoDuration)
                    end
                end

                drawOverlay()

                if not videoQueueOpen
                   and not videoQueueInputOpen then

                    drawTerminalVideoGui()
                end

                overlayTimer =
                    os.startTimer(0.05)

            elseif event == "timer"
               and p1 == videoClockTimer then

                -- Independent clock heartbeat. Even if another UI screen
                -- consumed the fast overlay timer, this keeps Current Time
                -- moving and recreates the fast redraw timer.
                if videoStartedAt then
                    videoElapsed =
                        math.max(
                            0,
                            (os.epoch("utc") / 1000)
                            - videoStartedAt
                        )

                    if videoDuration then
                        videoElapsed =
                            math.min(
                                videoElapsed,
                                videoDuration
                            )
                    end
                end

                if not videoQueueOpen
                   and not videoQueueInputOpen then
                    drawTerminalVideoGui()
                end

                overlayTimer =
                    os.startTimer(0.05)

                videoClockTimer =
                    os.startTimer(0.25)

            elseif event == "monitor_resize" then
                width,height =
                    monitor.getSize()

                closeX1 =
                    math.max(1,width-4)

                drawOverlay()

            elseif event == "terminate" then
                -- If this was not our own [X] request, treat it as a stop.
                if action == "ended" then
                    action = "stop"
                    os.queueEvent("terminate")
                end
            end
        end
    end

    -- CRITICAL SOCKET-LEAK FIX:
    -- Do not use waitForAny here. NEXT/PREV/X must wait until the stock
    -- YouCube client has actually exited, otherwise its WebSocket remains open.
    parallel.waitForAll(
        runPlayer,
        controlWatcher
    )

    stopAllSpeakers()

    -- Idempotent safety cleanup: closes only sockets recorded for this
    -- playYouCube() invocation.
    closeOwnedVideoSockets()

    pcall(function()
        term.redirect(oldTerm)
    end)

    restoreControllerPalette()

    if monitor.setTextScale then
        monitor.setTextScale(oldScale)
    end
    monitor.setCursorBlink(false)

    monitor.setBackgroundColor(C.bg)
    monitor.setTextColor(C.text)
    monitor.clear()

    width,height =
        monitor.getSize()

    -- Give CC:Tweaked one scheduler turn to release the closed native socket
    -- before another playlist item opens a new one.
    sleep(0)

    if action == "ended" and videoLoopEnabled then
        return "loop"
    end

    return action
end

local function canonicalYouTubeVideoUrl(entry)
    if not entry then
        return nil
    end

    -- Prefer an explicit video id from the playlist resolver.
    local id =
        entry.id
        or entry.video_id
        or entry.videoId

    if id and tostring(id) ~= "" then
        return "https://www.youtube.com/watch?v=" .. tostring(id)
    end

    local url = tostring(entry.url or "")

    if url == "" then
        return nil
    end

    -- youtube.com/watch?v=VIDEO_ID
    local watchId =
        url:match("[?&]v=([%w_-]+)")

    if watchId then
        return "https://www.youtube.com/watch?v=" .. watchId
    end

    -- youtu.be/VIDEO_ID
    local shortId =
        url:match("youtu%.be/([%w_-]+)")

    if shortId then
        return "https://www.youtube.com/watch?v=" .. shortId
    end

    -- youtube.com/shorts/VIDEO_ID
    local shortsId =
        url:match("/shorts/([%w_-]+)")

    if shortsId then
        return "https://www.youtube.com/watch?v=" .. shortsId
    end

    -- Fallback for resolver URLs which may just be a raw YouTube video id.
    if url:match("^[%w_-]+$") then
        return "https://www.youtube.com/watch?v=" .. url
    end

    -- Last resort: remove playlist-specific query parameters.
    -- This keeps the direct video URL but prevents the installed YouCube client
    -- from seeing the Mix/playlist context again.
    url = url:gsub("([?&])list=[^&]*", "%1")
    url = url:gsub("([?&])index=[^&]*", "%1")
    url = url:gsub("([?&])start_radio=[^&]*", "%1")
    url = url:gsub("([?&])pp=[^&]*", "%1")

    -- Clean malformed query separators left by removals.
    url = url:gsub("%?&", "?")
    url = url:gsub("&&+", "&")
    url = url:gsub("[?&]$", "")

    return url
end

local function playPlaylist(data)
    local sourceEntries = (data and data.entries) or {}
    local entries = {}

    -- Build a BRAND NEW playlist made only of standalone video URLs.
    -- Never pass YouTube Mix/playlist context into the installed YouCube client.
    for _, entry in ipairs(sourceEntries) do
        local cleanUrl =
            canonicalYouTubeVideoUrl(entry)

        if cleanUrl then
            entries[#entries + 1] = {
                url = cleanUrl,
                title =
                    entry.title
                    or entry.name
                    or cleanUrl
            }
        end
    end

    if #entries == 0 then
        status = "Playlist has no playable entries."
        return
    end

    if audioOnlyMode then
        audioQueue = {}

        for i = 2, #entries do
            audioQueue[#audioQueue + 1] = {
                url = entries[i].url,
                title = entries[i].title
            }
        end

        local current = {
            url = entries[1].url,
            title = entries[1].title
        }

        while current do
            local action =
                playAudioOnly(
                    current.url,
                    {
                        index = 1,
                        count = #audioQueue + 1,
                        title = current.title
                    }
                )

            if action == "cancel" then
                audioQueue = {}
                status = "Returned to search."
                return

            elseif action == "error" then
                audioQueue = {}
                return
            end

            if #audioQueue > 0 then
                current =
                    table.remove(
                        audioQueue,
                        1
                    )
            else
                current = nil
            end
        end

        audioQueue = {}
        status = "Queue finished."
        return
    end

    local index = 1

    while index >= 1
       and index <= #entries do

        local entry = entries[index]

        status =
            "Playlist "
            .. tostring(index)
            .. "/"
            .. tostring(#entries)

        local action =
            playYouCube(
                entry.url,
                {
                    index = index,
                    count = #entries,
                    title = entry.title,
                    entriesRef = entries
                }
            )

        if action == "stop" then
            status = "Playlist stopped."
            return
        elseif action == "loop" then
            -- replay current index

        else
            index = index + 1
        end
    end

    status = "Playlist finished."
end

local function playSearch(search)
    local submitted, submitError =
        normalizeMediaTarget(search)

    if not submitted then
        status = submitError
        return
    end

    -- Every submitted search/link starts a fresh playback session.
    audioOverlayLocked = false

    if isPlaylistUrl(submitted) then
        local data, err =
            resolvePlaylist(submitted)

        if data and data.entries and #data.entries > 0 then
            playPlaylist(data)
        else
            status = tostring(err or "Playlist has no playable entries.")
        end

        return
    end

    if audioOnlyMode then
        -- A new single link starts with an empty queue.
        audioQueue = {}

        local current = {
            url = submitted,
            title = submitted
        }

        while current and current.url do
            local action =
                playAudioOnly(
                    current.url,
                    {
                        index = 1,
                        count = #audioQueue + 1,
                        title = current.title
                    }
                )

            if action == "cancel" then
                status = "Returned to search."
                return
            elseif action == "error" then
                -- Preserve the real playback error instead of consuming the
                -- rest of the queue and replacing it with "Queue finished."
                return
            end

            if #audioQueue > 0 then
                current = table.remove(audioQueue, 1)
            else
                current = nil
            end
        end

        status = "Queue finished."
    else
        local entries = {
            {url=submitted,title=submitted}
        }

        local index = 1

        while index >= 1 and index <= #entries do
            local entry = entries[index]

            local action =
                playYouCube(
                    entry.url,
                    {
                        index=index,
                        count=#entries,
                        title=entry.title,
                        entriesRef=entries
                    }
                )

            if action == "stop" then
                break
            elseif action == "prev" then
                index = math.max(1,index-1)
            else
                index = index + 1
            end
        end
    end
end

-- =========================================================
-- INPUT
-- =========================================================

local function handleTouchForSurface(x, y, surface)
    local oldDisplay = display
    local oldWidth = width
    local oldHeight = height

    display = surface
    width, height = surface.getSize()

    local keysOut, play, clearSearch, audioButton =
        controllerKeyboardLayout()

    if inRect(x, y, clearSearch) then
        query = ""
        status = "Search cleared."

    elseif inRect(x, y, audioButton) then
        audioOnlyMode = not audioOnlyMode

        if audioOnlyMode then
            status = "Audio Only Mode enabled."
        else
            status = "Video Mode enabled."
        end

    elseif inRect(x, y, play) then
        if query ~= "" then
            local search = query

            display = oldDisplay
            width = oldWidth
            height = oldHeight

            playSearch(search)
            redrawAllControls()
            return
        end

    else
        for _, key in ipairs(keysOut) do
            if inRect(x, y, key) then
                if key.kind == "char" then
                    local ch = key.label

                    if ch:match("%a") then
                        ch =
                            uppercase
                            and ch:upper()
                            or ch:lower()
                    end

                    query = query .. ch

                elseif key.kind == "caps" then
                    uppercase = not uppercase

                elseif key.kind == "space" then
                    query = query .. " "

                elseif key.kind == "back" then
                    if #query > 0 then
                        query = query:sub(1, #query - 1)
                    end
                end

                break
            end
        end
    end

    display = oldDisplay
    width = oldWidth
    height = oldHeight
end

-- =========================================================
-- STARTUP
-- =========================================================

beginServerCheck()
redrawAllControls()

while true do
    local event, p1, p2, p3 =
        os.pullEvent()

    if event == "mouse_click" then
        handleTouchForSurface(p2, p3, controller)
        redrawAllControls()

    elseif event == "monitor_touch" then
        -- Ignore monitor GUI touches only while YouCube playback has redirected
        -- control to the monitor; its own playback overlay handles those.
        if monitor and p1 == peripheral.getName(monitor) then
            handleTouchForSurface(p2, p3, monitor)
            redrawAllControls()
        end

    elseif event == "paste" then
        query =
            query
            .. tostring(p1 or "")

        redrawAllControls()

    elseif event == "char" then
        query = query .. p1
        redrawAllControls()

    elseif event == "key" then
        if p1 == keys.backspace
           and #query > 0 then

            query = query:sub(1, #query - 1)
            redrawAllControls()

        elseif p1 == keys.enter
           and query ~= "" then

            local search = query
            playSearch(search)
            redrawAllControls()
        end

    elseif event == "timer"
       and p1 == serverCheckTimer then

        beginServerCheck()
        redrawAllControls()

    elseif event == "term_resize" then
        redrawAllControls()

    elseif event == "monitor_resize" then
        redrawAllControls()
    end
end
