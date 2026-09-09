-- =========================================================
--           YOUCUBE AUDIO ONLY AUTO PLAYER
-- CC:Tweaked / Minecraft 1.21.1
--
-- Uses installed YouCube client.
-- Backend server forced to:
--   ws://IPV4 or IPV6:5000
--
-- Requires YouCube installed with:
--   pastebin run swsmNAf7
--
-- Features:
--   * Advanced Monitor search GUI
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
local display = monitor or term.current()
local USING_MONITOR = monitor ~= nil

local GUI_SCALE = 0.5

if USING_MONITOR and display.setTextScale then
    if display.setTextScale then display.setTextScale(GUI_SCALE) end
end

if display.setCursorBlink then
    display.setCursorBlink(false)
end

local width, height = display.getSize()

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

local function restoreMonitorPalette()
    if not display.setPaletteColor then return end

    for color, rgb in pairs(DEFAULT_PALETTE) do
        display.setPaletteColor(color, rgb.r, rgb.g, rgb.b)
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
local audioLoopEnabled = true
local audioVolume = 1.0
local VOLUME_STEP = 0.10
local VOLUME_MIN = 0.0
local VOLUME_MAX = 1.0

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
    local original = display.getTextScale and display.getTextScale() or GUI_SCALE
    local chosen = 0.5

    for scale = 0.5, 5.0, 0.5 do
        display.setTextScale(scale)
        local w, h = display.getSize()

        if w <= 164 and h <= 120 then
            chosen = scale
            break
        end
    end

    display.setTextScale(original)
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
    local buttonY = math.min(height - 5, actionY + 2)

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
    local audioButton = {
        x1 = math.floor((width - audioW) / 2) + 1,
        y1 = math.min(height - 2, buttonY + 3),
        x2 = math.floor((width - audioW) / 2) + audioW,
        y2 = math.min(height - 1, buttonY + 4)
    }

    return keysOut, play, clearButton, audioButton
end

-- =========================================================
-- SEARCH SCREEN
-- =========================================================

local function drawSearch()
    width, height = display.getSize()

    -- YouCube changes the monitor palette while rendering video.
    -- Restore the normal ComputerCraft palette before drawing the GUI.
    restoreMonitorPalette()

    display.setBackgroundColor(C.bg)
    display.setTextColor(C.text)
    display.clear()

    centerText(
        1,
        "Y O U C U B E",
        C.title,
        C.bg
    )

    centerText(
        2,
        "YouTube Player",
        C.dim,
        C.bg
    )

    local boxX1 = 3
    local boxX2 = math.max(boxX1 + 10, width - 2)
    local boxY = 4

    fillRect(
        boxX1,
        boxY,
        boxX2,
        boxY + 1,
        colors.white
    )

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

    local keysOut, play, clearButton, audioButton = keyboardLayout()

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

            label =
                uppercase
                and "UPPER"
                or "lower"

        elseif key.kind == "space" then
            bg = C.panel2
            fg = colors.black

        elseif key.kind == "back" then
            bg = C.danger
            fg = colors.white
        end

        drawButton(
            key.x1,
            key.y1,
            key.x2,
            key.y2,
            label,
            bg,
            fg
        )
    end

    drawButton(
        play.x1,
        play.y1,
        play.x2,
        play.y2,
        "PLAY",
        query ~= "" and C.action or C.panel,
        query ~= "" and C.actionText or C.dim
    )

    drawButton(
        clearButton.x1,
        clearButton.y1,
        clearButton.x2,
        clearButton.y2,
        "CLEAR SEARCH",
        colors.orange,
        colors.black
    )

    local audioLabel =
        audioOnlyMode
        and "[X] AUDIO ONLY"
        or "[ ] AUDIO ONLY"

    drawButton(
        audioButton.x1,
        audioButton.y1,
        audioButton.x2,
        audioButton.y2,
        audioLabel,
        audioOnlyMode and colors.lime or colors.gray,
        audioOnlyMode and colors.black or colors.white
    )

    local serverColor =
        serverOnline
        and colors.lime
        or (
            serverStatusText == "CHECKING..."
            and colors.yellow
            or colors.red
        )

    local indicator =
        "SERVER: "
        .. serverStatusText

    writeAt(
        1,
        height,
        indicator,
        serverColor,
        C.bg
    )

    local statusRoom =
        math.max(
            1,
            width - #indicator - 2
        )

    if statusRoom > 4 then
        writeAt(
            width - math.min(#status, statusRoom) + 1,
            height,
            status:sub(
                math.max(
                    1,
                    #status - statusRoom + 1
                )
            ),
            C.dim,
            C.bg
        )
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
    local margin = math.max(1, math.floor(width * 0.04))
    local left = margin
    local right = width - margin + 1
    local gap = 1
    local available = math.max(23, width - 4)
    local buttonW = math.max(7, math.floor((available - 2) / 3))
    buttonW = math.min(buttonW, 18)
    local total = buttonW * 3 + 2
    local sx = math.max(1, math.floor((width - total) / 2) + 1)
    local buttonY = math.max(8, height - 4)

    return {
        panelX1 = left,
        panelX2 = right,
        voldown = {x1=sx,y1=buttonY,x2=sx+buttonW-1,y2=buttonY+1},
        change = {x1=sx+buttonW+1,y1=buttonY,x2=sx+buttonW*2,y2=buttonY+1},
        volup = {x1=sx+buttonW*2+2,y1=buttonY,x2=sx+buttonW*3+1,y2=buttonY+1}
    }
end

local function drawAudioOnlyScreen(state)
    width, height = display.getSize()
    restoreMonitorPalette()

    if display.setCursorBlink then display.setCursorBlink(false) end
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    local layout = audioGuiLayout()

    fillRect(1,1,width,math.min(3,height),colors.blue)
    centerText(1,"Y O U C U B E   A U D I O",colors.white,colors.blue)
    if height >= 2 then
        centerText(2,USING_MONITOR and "Monitor Player" or "Computer Player",colors.lightBlue,colors.blue)
    end

    local cardTop = math.min(4, math.max(3, height - 8))
    local cardBottom = math.min(height - 3, math.max(cardTop + 4, layout.change.y1 - 2))

    fillRect(layout.panelX1,cardTop,layout.panelX2,cardBottom,colors.gray)

    local innerX = math.min(layout.panelX2, layout.panelX1 + 1)
    local innerWidth = math.max(1, layout.panelX2 - innerX)

    writeAt(innerX,cardTop,"CURRENT SONG",colors.lightGray,colors.gray)

    if cardTop + 1 <= cardBottom then
        writeAt(innerX,cardTop+1,fitText(state.title or "Loading...",innerWidth),colors.white,colors.gray)
    end

    if cardTop + 2 <= cardBottom then
        local elapsed = formatTime(state.elapsed or 0)
        local duration = state.duration and formatTime(state.duration) or "--:--"
        writeAt(innerX,cardTop+2,fitText(elapsed.." / "..duration,innerWidth),colors.white,colors.gray)
    end

    if cardTop + 3 <= cardBottom then
        writeAt(
            innerX,cardTop+3,
            fitText("Volume: "..tostring(math.floor(audioVolume*100+0.5)).."%  Speakers: "..tostring(state.speakerCount or 0),innerWidth),
            colors.lightGray,colors.gray
        )
    end

    if cardTop + 4 <= cardBottom then
        local barX1 = innerX
        local barX2 = math.max(barX1,layout.panelX2-1)
        local barWidth = math.max(1,barX2-barX1+1)
        fillRect(barX1,cardTop+4,barX2,cardTop+4,colors.lightGray)

        if state.duration and state.duration > 0 then
            local progress = math.max(0,math.min(1,(state.elapsed or 0)/state.duration))
            local filled = math.floor(barWidth*progress)
            if filled > 0 then
                fillRect(barX1,cardTop+4,barX1+filled-1,cardTop+4,colors.lime)
            end
        end
    end

    drawButton(layout.voldown.x1,layout.voldown.y1,layout.voldown.x2,layout.voldown.y2,"VOL -",colors.gray,colors.white)
    drawButton(layout.change.x1,layout.change.y1,layout.change.x2,layout.change.y2,width < 35 and "CHANGE" or "CHANGE SONG",colors.orange,colors.black)
    drawButton(layout.volup.x1,layout.volup.y1,layout.volup.x2,layout.volup.y2,"VOL +",colors.gray,colors.white)

    centerText(height,fitText(state.status or "Playing",math.max(1,width-2)),colors.lightGray,colors.black)

    return layout
end

local function queueDisplayTitle(entry, index)
    local title = entry and entry.title
    if not title or title == "" then
        title = entry and entry.url or "Unknown song"
    end
    return tostring(index) .. ". " .. tostring(title)
end

local function drawQueueScreen(scroll)
    width, height = display.getSize()
    restoreMonitorPalette()

    display.setCursorBlink(false)
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    fillRect(1, 1, width, 3, colors.blue)
    centerText(1, "U P   N E X T", colors.white, colors.blue)
    centerText(2, tostring(#audioQueue) .. " upcoming", colors.lightBlue, colors.blue)

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

    local add = {x1=sx, y1=by, x2=sx+addW-1, y2=by+1}
    local back = {x1=add.x2+3, y1=by, x2=add.x2+2+backW, y2=by+1}

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
        up = {x1=width-4, y1=listTop, x2=width-2, y2=listTop}
        down = {x1=width-4, y1=listBottom, x2=width-2, y2=listBottom}
        drawButton(up.x1, up.y1, up.x2, up.y2, "^", colors.lightBlue, colors.black)
        drawButton(down.x1, down.y1, down.x2, down.y2, "v", colors.lightBlue, colors.black)
    end

    return {
        add = add,
        back = back,
        up = up,
        down = down,
        visible = visible
    }
end

local function drawQueueInputScreen(value, message)
    width, height = display.getSize()
    restoreMonitorPalette()

    display.setCursorBlink(false)
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    fillRect(1, 1, width, 3, colors.blue)
    centerText(1, "A D D   T O   Q U E U E", colors.white, colors.blue)
    centerText(2, "Song link or playlist link", colors.lightBlue, colors.blue)

    local boxX1 = 3
    local boxX2 = width - 2
    local boxY1 = 6
    local boxY2 = 8
    fillRect(boxX1, boxY1, boxX2, boxY2, colors.gray)

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
        shown = shown:sub(#shown - maxLen + 1)
    end

    writeAt(
        boxX1 + 1,
        boxY1 + 1,
        fitText(shown, maxLen),
        colors.white,
        colors.gray
    )

    if message and message ~= "" then
        centerText(10, fitText(message, math.max(1, width - 4)), colors.yellow, colors.black)
    end

    centerText(
        height - 5,
        "Paste/type link, ENTER to add",
        colors.lightGray,
        colors.black
    )
    centerText(
        height - 4,
        "BACKSPACE edits",
        colors.lightGray,
        colors.black
    )

    local cancelW = math.min(14, math.max(10, math.floor(width / 3)))
    local cancel = {
        x1 = math.floor((width - cancelW) / 2) + 1,
        y1 = height - 2,
        x2 = math.floor((width - cancelW) / 2) + cancelW,
        y2 = height - 1
    }

    drawButton(
        cancel.x1, cancel.y1, cancel.x2, cancel.y2,
        "CANCEL",
        colors.red, colors.white
    )

    return cancel
end

local function promptQueueLink()
    audioOverlayLocked = true

    local value = ""
    local message = ""

    restoreMonitorPalette()
    display.setCursorBlink(false)

    local cancel = drawQueueInputScreen(value, message)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "char" then
            value = value .. p1
            cancel = drawQueueInputScreen(value, message)

        elseif event == "paste" then
            value = value .. tostring(p1 or "")
            cancel = drawQueueInputScreen(value, message)

        elseif event == "key" then
            if p1 == keys.backspace then
                if #value > 0 then
                    value = value:sub(1, #value - 1)
                end

                cancel = drawQueueInputScreen(value, message)

            elseif p1 == keys.enter then
                local cleaned = value:match("^%s*(.-)%s*$") or ""

                if cleaned == "" then
                    message = "Enter a song or playlist link."
                    cancel = drawQueueInputScreen(value, message)
                else
                    audioOverlayLocked = false
                    return cleaned
                end
            end

        elseif event == "monitor_touch" then
            if inRect(p2, p3, cancel) then
                audioOverlayLocked = false
                display.setCursorBlink(false)
                return nil
            end

        elseif event == "monitor_resize" then
            width, height = display.getSize()
            cancel = drawQueueInputScreen(value, message)

        elseif event == "terminate" then
            audioOverlayLocked = false
            display.setCursorBlink(false)
            return nil

        else
            -- Ignore all background audio/WebSocket/timer events.
            -- The input screen stays completely static until the user
            -- types, pastes, resizes, presses Enter, or taps Cancel.
        end
    end
end

local function appendLinkToAudioQueue(link)
    link = tostring(link or ""):match("^%s*(.-)%s*$") or ""
    if link == "" then
        return false, "No link entered."
    end

    if isPlaylistUrl(link) then
        local data, err = resolvePlaylist(link)
        if not data then
            return false, tostring(err)
        end

        local added = 0
        for _, entry in ipairs(data.entries or {}) do
            if entry.url then
                table.insert(audioQueue, {
                    url = entry.url,
                    title = entry.title or entry.url
                })
                added = added + 1
            end
        end

        return true, "Added " .. tostring(added) .. " songs."
    end

    table.insert(audioQueue, {
        url = link,
        title = link
    })

    return true, "Song added to queue."
end

local function showAudioQueue()
    audioOverlayLocked = true

    local scroll = 1
    local message = nil
    local layout = nil

    restoreMonitorPalette()
    display.setCursorBlink(false)

    local function redraw()
        layout = drawQueueScreen(scroll)

        if message then
            centerText(
                height - 5,
                fitText(message, math.max(1, width - 4)),
                colors.yellow,
                colors.black
            )
        end
    end

    -- Draw once when opening.
    redraw()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "monitor_touch" then
            local x, y = p2, p3

            if inRect(x, y, layout.back) then
                audioOverlayLocked = false
                display.setCursorBlink(false)
                return

            elseif inRect(x, y, layout.add) then
                local link = promptQueueLink()

                if link then
                    local ok, msg = appendLinkToAudioQueue(link)
                    message = msg

                    if ok and #audioQueue > 0 then
                        scroll = math.max(
                            1,
                            #audioQueue - layout.visible + 1
                        )
                    end
                end

                -- Re-lock queue ownership after returning from input screen.
                audioOverlayLocked = true
                display.setCursorBlink(false)
                redraw()

            elseif layout.up and inRect(x, y, layout.up) then
                local newScroll = math.max(1, scroll - 1)

                if newScroll ~= scroll then
                    scroll = newScroll
                    redraw()
                end

            elseif layout.down and inRect(x, y, layout.down) then
                local maxScroll =
                    math.max(
                        1,
                        #audioQueue - layout.visible + 1
                    )

                local newScroll =
                    math.min(maxScroll, scroll + 1)

                if newScroll ~= scroll then
                    scroll = newScroll
                    redraw()
                end
            end

        elseif event == "mouse_scroll" then
            local maxScroll =
                math.max(
                    1,
                    #audioQueue - layout.visible + 1
                )

            local newScroll = scroll

            if p1 > 0 then
                newScroll = math.min(maxScroll, scroll + 1)
            else
                newScroll = math.max(1, scroll - 1)
            end

            if newScroll ~= scroll then
                scroll = newScroll
                redraw()
            end

        elseif event == "monitor_resize" then
            width, height = display.getSize()
            redraw()

        elseif event == "terminate" then
            audioOverlayLocked = false
            display.setCursorBlink(false)
            return

        else
            -- IMPORTANT:
            -- Ignore background YouCube/audio events completely.
            -- Do NOT redraw for speaker_audio_empty, websocket_message,
            -- timers, or other playback events.
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



local function ensureYouCubeInstalled()
    local program = resolveYouCube()

    if program then
        return true
    end

    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    centerText(
        math.max(1, math.floor(height / 2) - 2),
        "YouCube is not installed.",
        colors.yellow,
        colors.black
    )

    centerText(
        math.max(1, math.floor(height / 2)),
        "Installing YouCube...",
        colors.lightBlue,
        colors.black
    )

    -- Use the same installer command the user already uses manually:
    -- pastebin run swsmNAf7
    local ok, result =
        pcall(
            shell.run,
            "pastebin",
            "run",
            "swsmNAf7"
        )

    if not ok then
        status =
            "YouCube install failed: "
            .. tostring(result)

        return false
    end

    -- Verify that installation actually produced a runnable YouCube program.
    program = resolveYouCube()

    if not program then
        status =
            "YouCube installer finished, but YouCube was not found."

        return false
    end

    status = "YouCube installed successfully."
    return true
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

local function scaleSamplesForVolume(samples)
    if audioVolume >= 0.999 then return samples end

    local scaled = {}
    for i = 1, #samples do
        local v = samples[i] * audioVolume
        if v > 127 then v = 127 elseif v < -128 then v = -128 end
        scaled[i] = v >= 0 and math.floor(v + 0.5) or math.ceil(v - 0.5)
    end
    return scaled
end

local function playDecodedOnAllSpeakers(speakers, samples, shouldStop)
    local outputSamples = scaleSamplesForVolume(samples)
    for _, item in ipairs(speakers) do
        while true do
            if shouldStop and shouldStop() then
                return false
            end

            local ok =
                item.device.playAudio(outputSamples)

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



local STATE_FILE = "audio_player_state.txt"

local function loadPlayerState()
    if not fs.exists(STATE_FILE) then
        return {
            url = nil,
            loop = true,
            volume = 1.0
        }
    end

    local h = fs.open(STATE_FILE, "r")
    if not h then
        return {url=nil, loop=true, volume=1.0}
    end

    local raw = h.readAll()
    h.close()

    local ok, data =
        pcall(textutils.unserialize, raw)

    if ok and type(data) == "table" then
        return {
            url = data.url,
            loop = true,
            volume = tonumber(data.volume) or 1.0
        }
    end

    return {url=nil, loop=true, volume=1.0}
end

local function savePlayerState(url)
    local h = fs.open(STATE_FILE, "w")
    if not h then
        return
    end

    h.write(
        textutils.serialize({
            url = url,
            loop = true,
            volume = audioVolume
        })
    )
    h.close()
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
        return requestedAction == "change"
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

        -- This is now confirmed playable media, so it becomes the song
        -- automatically restored next time this program starts.
        savePlayerState(mediaUrl)

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

            if event == "monitor_touch" then
                local x = p2
                local y = p3

                if inRect(x, y, layout.voldown) then
                    audioVolume = math.max(VOLUME_MIN, audioVolume - VOLUME_STEP)
                    savePlayerState(mediaUrl)
                    state.status = "Volume " .. tostring(math.floor(audioVolume * 100 + 0.5)) .. "%"
                    layout = drawAudioOnlyScreen(state)

                elseif inRect(x, y, layout.change) then
                    requestedAction = "change"
                    state.status = "Opening song input..."
                    drawAudioOnlyScreen(state)
                    return

                elseif inRect(x, y, layout.volup) then
                    audioVolume = math.min(VOLUME_MAX, audioVolume + VOLUME_STEP)
                    savePlayerState(mediaUrl)
                    state.status = "Volume " .. tostring(math.floor(audioVolume * 100 + 0.5)) .. "%"
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

            elseif event == "monitor_resize" or event == "term_resize" then
                width, height = display.getSize()
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
    restoreMonitorPalette()
    display.setCursorBlink(false)
    display.setBackgroundColor(C.bg)
    display.setTextColor(C.text)
    display.clear()

    width, height = display.getSize()

    if requestedAction == "change" then
        status = "Change song."
        return "change"
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



-- =========================================================
-- STANDALONE CHANGE SONG SCREEN
-- =========================================================

local function drawSongInputScreen(text, upper, message)
    width, height = display.getSize()
    restoreMonitorPalette()

    display.setCursorBlink(false)
    display.setBackgroundColor(C.bg)
    display.setTextColor(C.text)
    display.clear()

    centerText(1, "C H A N G E   S O N G", colors.orange, C.bg)
    centerText(2, "Paste or type a YouTube link", C.dim, C.bg)

    local boxX1 = 3
    local boxX2 = math.max(boxX1 + 10, width - 2)
    local boxY = 4

    fillRect(boxX1, boxY, boxX2, boxY + 1, colors.white)

    local room = math.max(1, boxX2 - boxX1 - 1)
    local shown = tostring(text or "")

    if #shown > room then
        shown = shown:sub(#shown - room + 1)
    end

    writeAt(boxX1 + 1, boxY, shown, colors.black, colors.white)

    local keysOut, play, clearButton =
        keyboardLayout()

    -- On the Advanced Computer, keep the normal full-size keyboard exactly
    -- as it was. Only move PLAY and CLEAR to the very bottom of the GUI so
    -- they cannot overlap CAPS, SPACE, or BACK.
    if not USING_MONITOR then
        local actionY = math.max(1, height - 1)
        local mid = math.floor(width / 2)

        play = {
            x1 = 2,
            y1 = actionY,
            x2 = math.max(2, mid - 1),
            y2 = actionY
        }

        clearButton = {
            x1 = math.min(width - 1, mid + 2),
            y1 = actionY,
            x2 = width - 1,
            y2 = actionY
        }
    end

    for _, key in ipairs(keysOut) do
        local label = key.label
        local bg = C.key
        local fg = C.keyText

        if key.kind == "char"
           and label:match("%a") then

            label =
                upper
                and label:upper()
                or label:lower()

        elseif key.kind == "caps" then
            bg = colors.orange
            fg = colors.black
            label = upper and "UPPER" or "lower"

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
        text ~= "" and colors.green or colors.gray,
        text ~= "" and colors.black or colors.lightGray
    )

    drawButton(
        clearButton.x1,clearButton.y1,
        clearButton.x2,clearButton.y2,
        "CLEAR",
        colors.orange,
        colors.black
    )

    if message and message ~= "" and USING_MONITOR then
        centerText(
            height,
            fitText(message, math.max(1, width - 2)),
            colors.lightGray,
            C.bg
        )
    end

    return keysOut, play, clearButton
end

local function promptForSong()
    local text = ""
    local upper = false
    local message = "Enter a new song link."

    while true do
        local keysOut, play, clearButton =
            drawSongInputScreen(text, upper, message)

        local event,p1,p2,p3 =
            os.pullEvent()

        if event == "mouse_click" and not USING_MONITOR then
            event = "monitor_touch"
        end

        if event == "paste" then
            text = text .. tostring(p1 or "")

        elseif event == "char" then
            text = text .. p1

        elseif event == "key" then
            if p1 == keys.backspace and #text > 0 then
                text = text:sub(1, #text - 1)

            elseif p1 == keys.enter and text ~= "" then
                local target, err = normalizeMediaTarget(text)
                if target then
                    return target
                end
                message = err
            end

        elseif event == "monitor_touch" then
            local x,y = p2,p3

            if inRect(x,y,clearButton) then
                text = ""
                message = "Cleared."

            elseif inRect(x,y,play) then
                if text ~= "" then
                    local target, err = normalizeMediaTarget(text)
                    if target then
                        return target
                    end
                    message = err
                end

            else
                for _, key in ipairs(keysOut) do
                    if inRect(x,y,key) then
                        if key.kind == "char" then
                            local ch = key.label

                            if ch:match("%a") then
                                ch =
                                    upper
                                    and ch:upper()
                                    or ch:lower()
                            end

                            text = text .. ch

                        elseif key.kind == "caps" then
                            upper = not upper

                        elseif key.kind == "space" then
                            text = text .. " "

                        elseif key.kind == "colon" then
                            text = text .. ":"

                        elseif key.kind == "question" then
                            text = text .. "?"

                        elseif key.kind == "equals" then
                            text = text .. "="

                        elseif key.kind == "back" then
                            if #text > 0 then
                                text = text:sub(1, #text - 1)
                            end
                        end

                        break
                    end
                end
            end
        end
    end
end

-- =========================================================
-- STARTUP
-- =========================================================

if not ensureYouCubeInstalled() then
    restoreMonitorPalette()
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()

    centerText(
        math.max(1, math.floor(height / 2) - 1),
        "Unable to install YouCube.",
        colors.red,
        colors.black
    )

    centerText(
        math.max(1, math.floor(height / 2) + 1),
        fitText(status or "Unknown install error.", math.max(1, width - 4)),
        colors.lightGray,
        colors.black
    )

    return
end

local saved = loadPlayerState()
audioLoopEnabled = true
audioVolume = math.max(VOLUME_MIN, math.min(VOLUME_MAX, tonumber(saved.volume) or 1.0))

local currentUrl = saved.url

if not currentUrl or currentUrl == "" then
    currentUrl = promptForSong()
end

while true do
    local action =
        playAudioOnly(
            currentUrl,
            {
                title = currentUrl,
                index = 1,
                count = 1
            }
        )

    if action == "change" then
        currentUrl = promptForSong()

    elseif action == "error" then
        -- Keep the last known song intact. Give the user a way to replace it.
        currentUrl = promptForSong()

    else
        -- If a song naturally ends and Loop is OFF, remain on the player by
        -- immediately opening the song selector rather than exiting the app.
        if not audioLoopEnabled then
            currentUrl = promptForSong()
        end
    end
end
