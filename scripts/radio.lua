-- radio.lua
-- De "uitzend"-computer. Doet verder NIKS met playlists, jingles of
-- schema's samenstellen - dat gebeurt allemaal op de server-computer.
-- Deze computer luistert via rednet naar commando's van de server:
--   {cmd="schedule", data=...}  -> nieuw dagschema laden
--   {cmd="start"}               -> (weer) beginnen met uitzenden
--   {cmd="stop"}                -> uitzending pauzeren
--   {cmd="skip"}                -> huidig slot overslaan
--   {cmd="pause"}               -> pauzeren voor live praten (microfoon)
-- en stuurt zelf status-broadcasts ("nu op de zender: ...") zodat de
-- server dat op zijn eigen scherm kan tonen.
--
-- Vereist: een simpleradio:speaker of simpleradio:insulator peripheral,
-- en een modem (wired of wireless) voor de verbinding met de server.
-- Een monitor is optioneel, voor een lokaal "nu op de zender"-scherm.

local dfpwm = require("cc.audio.dfpwm")

local PROTOCOL = "wired_radio"

-- GitHub-synchronisatie: voor automatisch bijwerken naar de nieuwste
-- versie van dit script terwijl de radio draait.
local GITHUB_OWNER = "JOUW-GEBRUIKERSNAAM" -- <-- aanpassen!
local GITHUB_REPO = "JOUW-REPO-NAAM"        -- <-- aanpassen!
local GITHUB_BRANCH = "main"
local GITHUB_RAW = "https://raw.githubusercontent.com/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO .. "/" .. GITHUB_BRANCH
local SCHEDULE_FILE = "schedule.txt"
local CHUNK_SIZE = 16 * 1024
local SAMPLES_PER_PACKET = 960 -- vereist door de Simple Radio socket
local YIELD_EVERY = 2 -- yield elke 2 pakketjes - vaker nu er meer rekenwerk per sample gebeurt (AGC+limiter+filter)

-- ============ Bestanden ============

local function loadTable(path)
    if not fs.exists(path) then return {} end
    local f = fs.open(path, "r")
    local data = f.readAll()
    f.close()
    local ok, t = pcall(textutils.unserialize, data)
    if ok and type(t) == "table" then return t end
    return {}
end

local function saveTable(path, t)
    local f = fs.open(path, "w")
    f.write(textutils.serialize(t))
    f.close()
end

local function loadSchedule()
    local schedule = loadTable(SCHEDULE_FILE)
    if #schedule == 0 then return nil end
    return schedule
end

-- ============ Peripherals ============

local function findSocket()
    return peripheral.find("simpleradio:speaker") or peripheral.find("simpleradio:insulator")
end

local function requireSocket()
    local socket = findSocket()
    if not socket then
        print("Geen simpleradio:speaker of simpleradio:insulator gevonden.")
        print("Zet er een naast deze computer, of verbind via een wired modem.")
    end
    return socket
end

local function findMonitor()
    return peripheral.find("monitor")
end

local function openRednet()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            rednet.open(name)
            return true
        end
    end
    return false
end

-- ============ Monitor display ============

local function setupMonitor(monitor)
    if not monitor then return end
    -- probeer de grootste leesbare tekstschaal die het "nu op de zender"
    -- scherm nog volledig laat passen (titel, naam, artiest, bak/tempo,
    -- slot, voortgang, en de "straks"-regel onderin)
    local MIN_REQUIRED_ROWS = 10
    local scalesToTry = { 2, 1.5, 1, 0.75, 0.5 }
    for _, scale in ipairs(scalesToTry) do
        local ok = pcall(function() monitor.setTextScale(scale) end)
        if ok then
            local _, h = monitor.getSize()
            if h >= MIN_REQUIRED_ROWS then
                return
            end
        end
    end
end

local function monitorHasColor(monitor)
    return monitor.isColor and monitor.isColor()
end

local function centerText(monitor, y, text, color)
    local w = select(1, monitor.getSize())
    if #text > w then text = text:sub(1, w) end
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    if color and monitorHasColor(monitor) then monitor.setTextColor(color) end
    monitor.setCursorPos(x, y)
    monitor.write(text)
    if color and monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
end

local function formatClock(totalSeconds)
    totalSeconds = math.max(0, math.floor(totalSeconds))
    local m = math.floor(totalSeconds / 60)
    local s = totalSeconds % 60
    return string.format("%d:%02d", m, s)
end

local PROGRESS_ROW = 9

local function drawIdle(monitor, message)
    if not monitor then return end
    monitor.clear()
    local _, h = monitor.getSize()
    centerText(monitor, math.floor(h / 2), message or "-- RADIO STANDBY --", colors.gray)
end

local function drawNowPlaying(monitor, track, hour, nextSlot)
    if not monitor then return end
    monitor.clear()
    local _, h = monitor.getSize()

    centerText(monitor, 1, "== NU OP DE ZENDER ==", colors.yellow)
    centerText(monitor, 3, track.name, colors.white)
    centerText(monitor, 4, track.artist, colors.lightGray)
    centerText(monitor, 6, "Bak: " .. track.category .. "   Tempo: " .. track.tempo, colors.cyan)
    if hour then
        centerText(monitor, 7, string.format("Slot: %02d:00", hour), colors.cyan)
    end
    -- rij PROGRESS_ROW (9) wordt live bijgewerkt door playTrack
    if nextSlot then
        local label
        if nextSlot.type == "talk" then
            label = "Straks: de dj praat (" .. nextSlot.track.name .. ")"
        elseif nextSlot.type == "jingle" then
            label = "Straks: station ID (" .. nextSlot.track.name .. ")"
        else
            label = "Straks: " .. nextSlot.track.name .. " - " .. nextSlot.track.artist
        end
        centerText(monitor, h - 1, label, colors.gray)
    end
end

local function drawTalking(monitor, track, nextSlot)
    if not monitor then return end
    monitor.clear()
    local _, h = monitor.getSize()

    centerText(monitor, 1, "== AAN HET WOORD ==", colors.yellow)
    centerText(monitor, 3, "De dj praat...", colors.white)
    centerText(monitor, 4, track.name, colors.lightGray)
    if nextSlot then
        local label
        if nextSlot.type == "talk" then
            label = "Straks: de dj praat (" .. nextSlot.track.name .. ")"
        elseif nextSlot.type == "jingle" then
            label = "Straks: station ID (" .. nextSlot.track.name .. ")"
        else
            label = "Straks: " .. nextSlot.track.name .. " - " .. nextSlot.track.artist
        end
        centerText(monitor, h - 1, label, colors.gray)
    end
end

local function drawJingle(monitor, track, nextSlot)
    if not monitor then return end
    monitor.clear()
    local _, h = monitor.getSize()

    centerText(monitor, 1, "== STATION ID ==", colors.yellow)
    centerText(monitor, 3, track.name, colors.white)
    if nextSlot then
        local label = nextSlot.type == "talk"
            and ("Straks: de dj praat (" .. nextSlot.track.name .. ")")
            or (nextSlot.type == "jingle"
                and ("Straks: station ID (" .. nextSlot.track.name .. ")")
                or ("Straks: " .. nextSlot.track.name .. " - " .. nextSlot.track.artist))
        centerText(monitor, h - 1, label, colors.gray)
    end
end

-- ============ Afspelen ============

local function playTrackInner(url, socket, volume, monitor, skipBytes)
    volume = volume or 0.95 -- limiter hieronder vangt pieken op, dus dit mag dichter bij vol staan
    skipBytes = skipBytes or 0

    print("Verbinden: " .. url)
    -- skipBytes komt van de website, die stilte aan het begin analyseert
    -- met volledige rekenkracht (geen CC-tick-limiet). Via een HTTP
    -- Range-header beginnen we meteen op de juiste plek, zonder dat de
    -- computer zelf iets hoeft te decoderen/weggooien.
    local requestHeaders = nil
    if skipBytes > 0 then
        requestHeaders = { Range = "bytes=" .. skipBytes .. "-" }
    end
    local response, err = http.get(url, requestHeaders, true) -- binary mode
    if not response then
        print("Kon track niet ophalen: " .. tostring(err))
        return "done"
    end

    local knownDurationSec = nil
    local ok, headers = pcall(function() return response.getResponseHeaders() end)
    if ok and headers then
        local len = headers["Content-Length"] or headers["content-length"]
        if len then
            knownDurationSec = tonumber(len) / 6000 -- bytes / 6000 = seconden (dfpwm @ 48kHz, 1 bit/sample)
        end
    end

    local decoder = dfpwm.make_decoder()
    local leftover = {}
    local result = "done"
    local packetCount = 0
    local totalSamples = 0
    local startTime = os.epoch("utc")
    local lastSample = 0 -- voor de gladstrijk-filter, blijft bestaan over pakketjes heen
    local SMOOTH_ALPHA = 0.65 -- lager = meer gladgestreken (dof), hoger = scherper (rauwer)

    -- AGC/leveler: houdt het volume consistent ongeacht hoe zacht of
    -- luid het bronbestand gemasterd is (dit doen echte radiostations
    -- ook - een "leveler" vóór de limiter in de processing-keten).
    local envelope = 8000 -- lopend gemiddeld piekniveau, begint neutraal
    local AGC_TARGET = 22000
    local AGC_SPEED = 0.0005 -- hoe snel het volume zich aanpast (laag = traag/rustig)
    local AGC_MIN_GAIN = 0.6
    local AGC_MAX_GAIN = 2.2

    local LOOKAHEAD_MS = 3000 -- iets meer buffer-marge voorkomt micro-onderbrekingen

    local function stream()
        while true do
            local chunk = response.read(CHUNK_SIZE)
            if not chunk then break end

            local samples = decoder(chunk)

            local buf = leftover
            local base = #buf
            local LIMIT = 30000 -- boven dit niveau verzachten we de piek i.p.v. hard af te kappen
            for i = 1, #samples do
                local v = samples[i] * 256

                -- 1) AGC: volg het gemiddelde niveau en trek het naar het doel
                local absV = v < 0 and -v or v
                envelope = envelope + AGC_SPEED * (absV - envelope)
                if envelope > 200 then
                    local gain = AGC_TARGET / envelope
                    if gain < AGC_MIN_GAIN then gain = AGC_MIN_GAIN end
                    if gain > AGC_MAX_GAIN then gain = AGC_MAX_GAIN end
                    v = v * gain
                end

                -- 2) limiter: vangt pieken op die de AGC nog doorlaat
                if v > LIMIT then
                    v = LIMIT + (v - LIMIT) * 0.15
                elseif v < -LIMIT then
                    v = -LIMIT + (v + LIMIT) * 0.15
                end

                -- 3) gladstrijk-filter: verzacht de DFPWM-korreligheid
                lastSample = lastSample + SMOOTH_ALPHA * (v - lastSample)
                buf[base + i] = lastSample
            end
            leftover = {}

            local total = #buf
            local sent = 0
            while total - sent >= SAMPLES_PER_PACKET do
                local batch = {}
                for i = 1, SAMPLES_PER_PACKET do
                    batch[i] = buf[sent + i]
                end
                socket.route(batch, volume)
                sent = sent + SAMPLES_PER_PACKET
                totalSamples = totalSamples + SAMPLES_PER_PACKET

                local audioSentMs = (totalSamples / 48000) * 1000
                local elapsedMs = os.epoch("utc") - startTime
                local aheadMs = audioSentMs - elapsedMs
                if aheadMs > LOOKAHEAD_MS then
                    os.sleep((aheadMs - LOOKAHEAD_MS) / 1000)
                else
                    packetCount = packetCount + 1
                    if packetCount % YIELD_EVERY == 0 then
                        os.sleep(0)
                    end
                end
            end

            for i = sent + 1, total do
                leftover[#leftover + 1] = buf[i]
            end
        end

        if #leftover > 0 then
            local batch = {}
            for i = 1, SAMPLES_PER_PACKET do
                batch[i] = leftover[i] or 0
            end
            socket.route(batch, volume)
            totalSamples = totalSamples + SAMPLES_PER_PACKET
        end

        local expectedMs = (totalSamples / 48000) * 1000
        local elapsedMs = os.epoch("utc") - startTime
        local remainingMs = expectedMs - elapsedMs
        if remainingMs > 0 then
            os.sleep(remainingMs / 1000)
        end
    end

    local function listenForSkip()
        while true do
            local event, key = os.pullEvent("key")
            if key == keys.s or key == keys.q then
                result = "skipped"
                return
            elseif key == keys.p then
                result = "paused"
                return
            end
        end
    end

    local function updateProgress()
        if not monitor then return end
        while true do
            local elapsedSec = (os.epoch("utc") - startTime) / 1000
            local line
            if knownDurationSec then
                local remainingSec = math.max(0, knownDurationSec - elapsedSec)
                local finishEpochSec = math.floor(os.epoch("utc") / 1000) + math.ceil(remainingSec)
                local finishClock = os.date("%H:%M:%S", finishEpochSec)
                line = formatClock(elapsedSec) .. " / " .. formatClock(knownDurationSec)
                    .. "  (klaar om " .. finishClock .. ")"
            else
                line = "Verstreken: " .. formatClock(elapsedSec)
            end
            centerText(monitor, PROGRESS_ROW, line, colors.lime)
            os.sleep(1)
        end
    end

    parallel.waitForAny(stream, listenForSkip, updateProgress)
    response.close()
    return result
end

local function playTrack(url, socket, volume, monitor, skipBytes)
    local ok, result = pcall(playTrackInner, url, socket, volume, monitor, skipBytes)
    if not ok then
        print("Kon dit nummer niet afspelen (" .. tostring(result) .. "), ga door.")
        return "done"
    end
    return result
end

-- ============ Hoofdprogramma ============

local function main()
    local socket = requireSocket()
    if not socket then return end
    local monitor = findMonitor()
    setupMonitor(monitor)
    drawIdle(monitor)

    if not openRednet() then
        print("Geen modem gevonden - kan niet met de server verbinden.")
        print("Zet er een naast deze computer (wired of wireless).")
        return
    end
    rednet.host(PROTOCOL, "radio")
    print("Verbonden en zichtbaar voor de server als 'radio'.")

    local function requestScheduleFromServer()
        local serverId = rednet.lookup(PROTOCOL, "server")
        if not serverId then
            print("Server niet gevonden via rednet, kan geen nieuw schema aanvragen.")
            return false
        end
        rednet.send(serverId, { cmd = "request_schedule" }, PROTOCOL)
        return true
    end

    local schedule = loadSchedule()
    local stopped = false

    local function rednetListener()
        while true do
            local senderId, msg = rednet.receive(PROTOCOL)
            if type(msg) == "table" then
                if msg.cmd == "schedule" then
                    schedule = msg.data
                    saveTable(SCHEDULE_FILE, schedule)
                    print("Nieuw dagschema ontvangen van de server (" .. #schedule .. " slots).")
                elseif msg.cmd == "start" then
                    stopped = false
                    print("Server: start uitzending.")
                elseif msg.cmd == "stop" then
                    stopped = true
                    print("Server: stop uitzending.")
                elseif msg.cmd == "skip" then
                    os.queueEvent("key", keys.s)
                elseif msg.cmd == "pause" then
                    os.queueEvent("key", keys.p)
                end
            end
        end
    end

    local function playbackLoop()
        requestScheduleFromServer() -- meteen bij opstarten een vers schema aanvragen

        while true do
            while stopped do
                drawIdle(monitor, "-- UITZENDING GEPAUZEERD --")
                os.sleep(1)
            end

            if not schedule or #schedule == 0 then
                drawIdle(monitor, "-- WACHTEN OP SCHEMA --")
                print("Wachten op een dagschema van de server...")
                local waited = 0
                while (not schedule or #schedule == 0) and not stopped do
                    os.sleep(1)
                    waited = waited + 1
                    if waited % 15 == 0 then
                        requestScheduleFromServer() -- elke 15s opnieuw proberen
                    end
                end
            else
                for i, slot in ipairs(schedule) do
                    if stopped then break end
                    local nextSlot = schedule[i + 1]

                    if slot.type == "talk" then
                        print(string.format("%02d:00 - [TALK] %s", slot.hour, slot.track.name))
                        drawTalking(monitor, slot.track, nextSlot)
                    elseif slot.type == "jingle" then
                        print(string.format("%02d:00 - [JINGLE] %s", slot.hour, slot.track.name))
                        drawJingle(monitor, slot.track, nextSlot)
                    else
                        print(string.format("%02d:00 - Nu op de zender: %s - %s [%s]",
                            slot.hour, slot.track.name, slot.track.artist, slot.track.category))
                        drawNowPlaying(monitor, slot.track, slot.hour, nextSlot)
                    end

                    pcall(rednet.broadcast, { cmd = "status", slot = slot }, PROTOCOL)

                    local result = playTrack(slot.track.url, socket, nil, monitor, slot.track.skipBytes)
                    if result == "paused" then
                        print("Gepauzeerd voor live praten (microfoon). Druk op een toets om door te gaan.")
                        drawIdle(monitor, "-- LIVE MICROFOON --")
                        os.pullEvent("key")
                        print("Uitzending hervat.")
                    end
                end

                if not stopped then
                    print("Dagschema afgerond. Nieuw schema aanvragen bij de server...")
                    schedule = nil
                    requestScheduleFromServer()
                end
            end
        end
    end

    local AUTO_UPDATE_INTERVAL_SEC = 120 -- elke 2 minuten checken op een nieuwere versie

    local function autoUpdateLoop()
        while true do
            os.sleep(AUTO_UPDATE_INTERVAL_SEC)
            local resp = http.get(GITHUB_RAW .. "/scripts/radio.lua")
            if resp then
                local remote = resp.readAll()
                resp.close()
                local f = fs.open("radio.lua", "r")
                local current = f.readAll()
                f.close()
                if remote ~= current and remote ~= "" then
                    print("Nieuwe versie van radio.lua gevonden op GitHub - herstarten...")
                    os.sleep(2)
                    os.reboot()
                end
            end
        end
    end

    parallel.waitForAny(playbackLoop, rednetListener, autoUpdateLoop)
end

-- ============ Automatisch herstarten ============
-- Draait main() in een lus die zichzelf herstart na een onverwachte
-- crash (bijv. een netwerkhapering), met een venstertje van 5 seconden
-- waarin je dat kan annuleren door op een toets te drukken. Bewust
-- stoppen met Ctrl+T wordt gerespecteerd en herstart NIET automatisch.

while true do
    local ok, err = pcall(main)

    if ok then
        print("Radio is gestopt (programma klaar).")
        break
    end

    if tostring(err) == "Terminated" then
        print("Gestopt met Ctrl+T. Automatisch herstarten is nu uit.")
        print("Typ 'radio' om het opnieuw te starten.")
        break
    end

    print("Radio is gecrasht: " .. tostring(err))
    print("Automatisch herstarten over 5 seconden - druk op een toets om te annuleren...")

    local timer = os.startTimer(5)
    local cancelled = false
    while true do
        local event, p1 = os.pullEvent()
        if event == "timer" and p1 == timer then
            break
        elseif event == "key" then
            cancelled = true
            break
        end
    end

    if cancelled then
        print("Herstart geannuleerd. Typ 'radio' om opnieuw te proberen.")
        break
    end
end
