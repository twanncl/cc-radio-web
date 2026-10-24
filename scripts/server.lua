-- server.lua
-- De "studio"-computer. Hier beheer je de playlist, pratende stukjes,
-- jingles en dagschema's, en bekijk je trending muziek op YouTube.
-- Het daadwerkelijke afspelen gebeurt op de aparte "radio"-computer -
-- deze computer stuurt dagschema's en commando's daarnaartoe via
-- rednet, en ontvangt status-updates terug ("nu op de zender: ...").
--
-- Vereist: een modem (wired of wireless) om met de radio-computer te
-- praten. Een monitor is optioneel - je kan er het menu op aantikken
-- in plaats van typen, en hij toont wat er nu op de zender staat.
-- Let op: vrije tekst (namen, URLs) typ je nog steeds gewoon op het
-- toetsenbord: een monitor kan geen tekst laten typen, alleen tikken.

local PROTOCOL = "wired_radio"

-- GitHub-synchronisatie: nieuwe nummers/stukjes/jingles die via de
-- Vercel-webpagina (of rechtstreeks in de repo) zijn toegevoegd,
-- worden hiervandaan opgehaald en toegevoegd aan je lokale bibliotheek.
local GITHUB_OWNER = "JOUW-GEBRUIKERSNAAM" -- <-- aanpassen!
local GITHUB_REPO = "JOUW-REPO-NAAM"        -- <-- aanpassen!
local GITHUB_BRANCH = "main"
local GITHUB_RAW = "https://raw.githubusercontent.com/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO .. "/" .. GITHUB_BRANCH

local PLAYLIST_FILE = "playlist.txt"
local VOICETRACK_FILE = "voicetracks.txt"
local JINGLE_FILE = "jingles.txt"
local HISTORY_FILE = "history.txt"
local SCHEDULE_FILE = "schedule.txt"
local VOICE_REPEAT_WINDOW = 2
local JINGLE_REPEAT_WINDOW = 2
local ARTIST_WINDOW = 4
local MAX_CONSECUTIVE_SLOW = 2
local DEFAULT_SCHEDULE_SLOTS = 24

local CATEGORY_WEIGHTS = { A = 40, B = 25, C = 10, Recents = 15, Golds = 10 }
local CATEGORY_ORDER = { "A", "B", "C", "Recents", "Golds" }

local CLOCK_PATTERN = {
    "JINGLE", "A", "B", "A", "JINGLE", "Recents", "TALK",
    "A", "JINGLE", "C", "B", "JINGLE", "TALK", "Golds",
}

local CLASHING_STYLES = {
    rock       = { dance = true, electronic = true },
    dance      = { rock = true },
    electronic = { rock = true },
}

local HOLIDAY_DATE_RANGES = {
    { tag = "sinterklaas",   sm = 11, sd = 15, em = 12, ed = 5 },
    { tag = "kerst",         sm = 12, sd = 6,  em = 12, ed = 26 },
    { tag = "oud-en-nieuw",  sm = 12, sd = 27, em = 1,  ed = 1 },
    { tag = "valentijnsdag", sm = 2,  sd = 14, em = 2,  ed = 14 },
    { tag = "koningsdag",    sm = 4,  sd = 27, em = 4,  ed = 27 },
    { tag = "halloween",     sm = 10, sd = 25, em = 10, ed = 31 },
}

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

local function loadPlaylist()
    local list = loadTable(PLAYLIST_FILE)
    for _, track in ipairs(list) do
        track.artist = track.artist or track.name
        track.category = track.category or "B"
        track.tempo = track.tempo or "medium"
        track.style = track.style or ""
        track.skipBytes = track.skipBytes or 0
        if track.holiday == true then
            track.holiday = "kerst"
        elseif track.holiday == nil or track.holiday == false then
            track.holiday = ""
        end
    end
    return list
end

local function savePlaylist(list) saveTable(PLAYLIST_FILE, list) end
local function loadVoiceTracks() return loadTable(VOICETRACK_FILE) end
local function saveVoiceTracks(list) saveTable(VOICETRACK_FILE, list) end
local function loadJingles() return loadTable(JINGLE_FILE) end
local function saveJingles(list) saveTable(JINGLE_FILE, list) end

-- ============ GitHub-synchronisatie ============

local function fetchGithubJSON(path)
    local resp = http.get(GITHUB_RAW .. "/" .. path)
    if not resp then return nil end
    local body = resp.readAll()
    resp.close()
    local ok, data = pcall(textutils.unserialiseJSON, body)
    if ok and type(data) == "table" then return data end
    return nil
end

-- Haalt data/playlist.json, data/voicetracks.json en data/jingles.json
-- op van GitHub en voegt alleen de nummers toe die je nog niet hebt
-- (op naam+artiest, of url voor stukjes/jingles) - overschrijft nooit
-- iets dat je lokaal al hebt aangepast.
local function syncFromGithub(list, voiceList, jingleList)
    print("Synchroniseren met GitHub...")

    local remotePlaylist = fetchGithubJSON("data/playlist.json")
    local addedSongs = 0
    if remotePlaylist then
        local existing = {}
        for _, t in ipairs(list) do existing[(t.name or "") .. "|" .. (t.artist or "")] = true end
        for _, t in ipairs(remotePlaylist) do
            local key = (t.name or "") .. "|" .. (t.artist or "")
            if t.name and t.artist and t.url and not existing[key] then
                table.insert(list, {
                    name = t.name, artist = t.artist, url = t.url,
                    category = t.category or "C", tempo = t.tempo or "medium",
                    style = t.style or "", holiday = (t.holiday or ""):lower(),
                    skipBytes = tonumber(t.skipBytes) or 0,
                })
                existing[key] = true
                addedSongs = addedSongs + 1
            end
        end
        if addedSongs > 0 then savePlaylist(list) end
    end

    local remoteVoice = fetchGithubJSON("data/voicetracks.json")
    local addedVoice = 0
    if remoteVoice then
        local existing = {}
        for _, vt in ipairs(voiceList) do existing[vt.url] = true end
        for _, vt in ipairs(remoteVoice) do
            if vt.name and vt.url and not existing[vt.url] then
                table.insert(voiceList, { name = vt.name, url = vt.url })
                existing[vt.url] = true
                addedVoice = addedVoice + 1
            end
        end
        if addedVoice > 0 then saveVoiceTracks(voiceList) end
    end

    local remoteJingles = fetchGithubJSON("data/jingles.json")
    local addedJingles = 0
    if remoteJingles then
        local existing = {}
        for _, j in ipairs(jingleList) do existing[j.url] = true end
        for _, j in ipairs(remoteJingles) do
            if j.name and j.url and not existing[j.url] then
                table.insert(jingleList, { name = j.name, url = j.url })
                existing[j.url] = true
                addedJingles = addedJingles + 1
            end
        end
        if addedJingles > 0 then saveJingles(jingleList) end
    end

    if not (remotePlaylist or remoteVoice or remoteJingles) then
        print("Kon GitHub niet bereiken - controleer internet en de GITHUB_OWNER/GITHUB_REPO instelling.")
        return
    end

    print(string.format("Sync klaar: %d nieuw nummer, %d nieuw stukje, %d nieuwe jingle toegevoegd.",
        addedSongs, addedVoice, addedJingles))
end
local function loadHistory() return loadTable(HISTORY_FILE) end
local function saveHistory(h) saveTable(HISTORY_FILE, h) end

-- ============ Rotatielogica ============

local function weightedRandomCategory(availableCategories)
    local total = 0
    for cat in pairs(availableCategories) do
        total = total + (CATEGORY_WEIGHTS[cat] or 1)
    end
    if total == 0 then return nil end
    local roll = math.random(1, total)
    local running = 0
    for _, cat in ipairs(CATEGORY_ORDER) do
        if availableCategories[cat] then
            running = running + (CATEGORY_WEIGHTS[cat] or 1)
            if roll <= running then return cat end
        end
    end
    return nil
end

local function tracksByCategory(list)
    local byCat = {}
    for _, track in ipairs(list) do
        byCat[track.category] = byCat[track.category] or {}
        table.insert(byCat[track.category], track)
    end
    return byCat
end

local function passesRules(candidate, recentArtists, recentTempos, lastStyle, hour, history, rules)
    if rules.artist then
        for _, a in ipairs(recentArtists) do
            if a == candidate.artist then return false end
        end
    end

    if rules.tempo and candidate.tempo == "slow" then
        local consecutiveSlow = 0
        for i = #recentTempos, 1, -1 do
            if recentTempos[i] == "slow" then
                consecutiveSlow = consecutiveSlow + 1
            else
                break
            end
        end
        if consecutiveSlow >= MAX_CONSECUTIVE_SLOW then return false end
    end

    if rules.style and lastStyle and lastStyle ~= "" and candidate.style ~= "" then
        local clash = CLASHING_STYLES[lastStyle]
        if clash and clash[candidate.style] then return false end
    end

    if rules.timeslot then
        local h = history[candidate.url]
        if h and h.hour == hour then return false end
    end

    return true
end

local function selectTrackForSlot(byCat, hour, recentArtists, recentTempos, lastStyle, history, preferredCategory)
    local ruleSets = {
        { artist = true, tempo = true, style = true, timeslot = true },
        { artist = true, tempo = true, style = true, timeslot = false },
        { artist = true, tempo = true, style = false, timeslot = false },
        { artist = true, tempo = false, style = false, timeslot = false },
        { artist = false, tempo = false, style = false, timeslot = false },
    }

    for _, rules in ipairs(ruleSets) do
        if preferredCategory and byCat[preferredCategory] then
            local preferred = {}
            for _, t in ipairs(byCat[preferredCategory]) do
                if passesRules(t, recentArtists, recentTempos, lastStyle, hour, history, rules) then
                    table.insert(preferred, t)
                end
            end
            if #preferred > 0 then
                return preferred[math.random(1, #preferred)]
            end
        end

        local available = {}
        for cat, tracks in pairs(byCat) do
            for _, t in ipairs(tracks) do
                if passesRules(t, recentArtists, recentTempos, lastStyle, hour, history, rules) then
                    available[cat] = available[cat] or {}
                    table.insert(available[cat], t)
                end
            end
        end

        local hasAny = false
        for _ in pairs(available) do hasAny = true break end
        if hasAny then
            local cat = weightedRandomCategory(available)
            local pool = available[cat]
            return pool[math.random(1, #pool)]
        end
    end

    return nil
end

local function shallowCopy(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

local function pickVoiceTrack(voiceList, recentVoiceUrls)
    if #voiceList == 0 then return nil end
    local candidates = {}
    for _, vt in ipairs(voiceList) do
        local isRecent = false
        for _, url in ipairs(recentVoiceUrls) do
            if url == vt.url then isRecent = true break end
        end
        if not isRecent then table.insert(candidates, vt) end
    end
    if #candidates == 0 then candidates = voiceList end
    return candidates[math.random(1, #candidates)]
end

local function generateSchedule(list, voiceList, jingleList, slotCount)
    if #list == 0 then
        print("Playlist is leeg, kan geen dagschema maken.")
        return nil
    end

    local byCat = tracksByCategory(list)
    local history = loadHistory()
    local schedule = {}
    local recentArtists = {}
    local recentTempos = {}
    local recentVoiceUrls = {}
    local recentJingleUrls = {}
    local lastStyle = nil

    for i = 1, slotCount do
        local hour = math.floor((i - 1) / slotCount * 24)
        local clockIndex = ((i - 1) % #CLOCK_PATTERN) + 1
        local preferredCategory = CLOCK_PATTERN[clockIndex]

        if preferredCategory == "TALK" then
            local voiceTrack = pickVoiceTrack(voiceList, recentVoiceUrls)
            if voiceTrack then
                table.insert(schedule, { hour = hour, type = "talk", track = shallowCopy(voiceTrack) })
                table.insert(recentVoiceUrls, voiceTrack.url)
                if #recentVoiceUrls > VOICE_REPEAT_WINDOW then table.remove(recentVoiceUrls, 1) end
            end
        elseif preferredCategory == "JINGLE" then
            local jingle = pickVoiceTrack(jingleList, recentJingleUrls)
            if jingle then
                table.insert(schedule, { hour = hour, type = "jingle", track = shallowCopy(jingle) })
                table.insert(recentJingleUrls, jingle.url)
                if #recentJingleUrls > JINGLE_REPEAT_WINDOW then table.remove(recentJingleUrls, 1) end
            end
        else
            local track = selectTrackForSlot(byCat, hour, recentArtists, recentTempos, lastStyle, history, preferredCategory)
            if not track then break end

            table.insert(schedule, { hour = hour, type = "song", track = shallowCopy(track) })

            table.insert(recentArtists, track.artist)
            if #recentArtists > ARTIST_WINDOW then table.remove(recentArtists, 1) end

            table.insert(recentTempos, track.tempo)
            if #recentTempos > MAX_CONSECUTIVE_SLOW + 1 then table.remove(recentTempos, 1) end

            lastStyle = track.style
            history[track.url] = { day = os.day(), hour = hour }
        end
    end

    saveHistory(history)
    saveTable(SCHEDULE_FILE, schedule)
    return schedule
end

-- ============ Feestdag-detectie ============

local function inHolidayRange(month, day, sm, sd, em, ed)
    local cur = month * 100 + day
    local startV = sm * 100 + sd
    local endV = em * 100 + ed
    if startV <= endV then
        return cur >= startV and cur <= endV
    else
        return cur >= startV or cur <= endV
    end
end

local function detectActiveHoliday(list)
    local used = {}
    for _, t in ipairs(list) do
        if t.holiday ~= "" then used[t.holiday] = true end
    end
    local month = tonumber(os.date("%m"))
    local day = tonumber(os.date("%d"))
    for _, h in ipairs(HOLIDAY_DATE_RANGES) do
        if used[h.tag] and inHolidayRange(month, day, h.sm, h.sd, h.em, h.ed) then
            return h.tag
        end
    end
    return nil
end

-- ============ Monitor (tikbaar menu + statusregel) ============

local function findMonitor()
    return peripheral.find("monitor")
end

local MAIN_MENU_ITEMS = {
    "Nummer toevoegen",
    "Dagschema maken + versturen",
    "Feestdag-schema maken + versturen",
    "Radio bedienen",
    "Bibliotheek beheren",
    "Trending muziek (YouTube)",
    "Sync met GitHub",
    "Afsluiten",
}

local RADIO_CONTROL_MENU_ITEMS = {
    "Radio starten",
    "Radio stoppen",
    "Skip huidig nummer",
    "Pauzeer voor praten",
    "Terug",
}

local LIBRARY_MENU_ITEMS = {
    "Nummer verwijderen",
    "Nummer bewerken",
    "Playlist tonen",
    "Pratend stukje toevoegen",
    "Pratend stukje verwijderen",
    "Pratende stukjes tonen",
    "Jingle toevoegen",
    "Jingle verwijderen",
    "Jingles tonen",
    "Terug",
}

local function setupMonitor(monitor)
    if not monitor then return end
    -- probeer de grootste leesbare tekstschaal die het langste menu
    -- (van de drie) nog volledig laat passen; lukt dat niet, val terug
    -- op de kleinste schaal en laat de rest oplossen via scrollen
    local maxItems = math.max(#MAIN_MENU_ITEMS, #RADIO_CONTROL_MENU_ITEMS, #LIBRARY_MENU_ITEMS)
    local scalesToTry = { 2, 1.5, 1, 0.75, 0.5 }
    for _, scale in ipairs(scalesToTry) do
        local ok = pcall(function() monitor.setTextScale(scale) end)
        if ok then
            local _, h = monitor.getSize()
            if h >= (maxItems + 2) then
                return -- dit past helemaal, klaar
            end
        end
    end
    -- niks paste volledig - kleinste schaal (0.5) staat nu ingesteld
end

local function monitorHasColor(monitor)
    return monitor.isColor and monitor.isColor()
end

-- ============ Schermtoetsenbord ============

local KEYBOARD_ROWS = {
    { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
    { "a", "s", "d", "f", "g", "h", "j", "k", "l" },
    { "z", "x", "c", "v", "b", "n", "m", ".", "-" },
}

-- Tekent het schermtoetsenbord en geeft een tabel [y][x] = actie terug.
-- Actie is een los teken, of "SHIFT"/"SPACE"/"BACK"/"ENTER"/"CANCEL".
local function drawOnScreenKeyboard(monitor, promptText, currentText, shiftOn)
    if not monitor then return {} end
    monitor.clear()
    local w, h = monitor.getSize()

    monitor.setCursorPos(1, 1)
    if monitorHasColor(monitor) then monitor.setTextColor(colors.yellow) end
    local p = promptText
    if #p > w then p = p:sub(1, w) end
    monitor.write(p)
    if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end

    monitor.setCursorPos(1, 2)
    local shown = currentText .. "_"
    if #shown > w then shown = shown:sub(#shown - w + 1) end
    monitor.write(shown)

    local keyMap = {}
    local startRow = 4
    for r, row in ipairs(KEYBOARD_ROWS) do
        local y = startRow + r - 1
        if y <= h then
            local x = 1
            for _, key in ipairs(row) do
                local ch = shiftOn and key:upper() or key
                if x <= w then
                    monitor.setCursorPos(x, y)
                    monitor.write(ch)
                    keyMap[y] = keyMap[y] or {}
                    keyMap[y][x] = ch
                end
                x = x + 2
            end
        end
    end

    local specialRow = startRow + #KEYBOARD_ROWS
    if specialRow <= h then
        local specials = {
            { label = "[SHIFT]", key = "SHIFT" },
            { label = "[SPATIE]", key = "SPACE" },
            { label = "[<-]", key = "BACK" },
            { label = "[OK]", key = "ENTER" },
            { label = "[X]", key = "CANCEL" },
        }
        local x = 1
        for _, s in ipairs(specials) do
            if x + #s.label - 1 <= w then
                monitor.setCursorPos(x, specialRow)
                if monitorHasColor(monitor) then monitor.setTextColor(colors.orange) end
                monitor.write(s.label)
                if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
                keyMap[specialRow] = keyMap[specialRow] or {}
                for xi = x, x + #s.label - 1 do
                    keyMap[specialRow][xi] = s.key
                end
                x = x + #s.label + 1
            end
        end
    end

    return keyMap
end

-- Vraagt vrije tekst: typen op het toetsenbord van de computer werkt
-- altijd; is er een monitor, dan kan je ook op het schermtoetsenbord
-- tikken. Geeft nil terug als je op het scherm op "X" (annuleren) tikt.
local function askText(monitor, prompt)
    write(prompt .. ": ")
    local typed = ""
    local done = false
    local cancelled = false

    local function fromKeyboardTerm()
        typed = read()
        done = true
    end

    if monitor then
        local shiftOn = false
        local keyMap = drawOnScreenKeyboard(monitor, prompt, typed, shiftOn)

        local function fromTouch()
            while not done do
                local event, side, x, y = os.pullEvent("monitor_touch")
                local action = keyMap[y] and keyMap[y][x]
                if action == "SHIFT" then
                    shiftOn = not shiftOn
                elseif action == "SPACE" then
                    typed = typed .. " "
                elseif action == "BACK" then
                    typed = typed:sub(1, -2)
                elseif action == "ENTER" then
                    done = true
                elseif action == "CANCEL" then
                    cancelled = true
                    done = true
                elseif action then
                    typed = typed .. action
                end
                if not done then
                    keyMap = drawOnScreenKeyboard(monitor, prompt, typed, shiftOn)
                end
            end
        end

        parallel.waitForAny(fromKeyboardTerm, fromTouch)
    else
        fromKeyboardTerm()
    end

    if cancelled then return nil end
    return typed
end

-- Laat kiezen uit een lijst opties: typen van een nummer werkt altijd;
-- is er een monitor, dan kan je de optie ook aantikken.
local function askChoice(monitor, promptText, options)
    print(promptText)
    for i, opt in ipairs(options) do
        print(i .. ") " .. opt)
    end
    local choice = nil

    local function fromKeyboardTerm()
        write("> ")
        local n = tonumber(read())
        choice = options[n] or options[1]
    end

    if monitor then
        monitor.clear()
        local w = select(1, monitor.getSize())
        monitor.setCursorPos(1, 1)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.yellow) end
        local p = promptText
        if #p > w then p = p:sub(1, w) end
        monitor.write(p)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
        for i, opt in ipairs(options) do
            monitor.setCursorPos(1, 1 + i)
            local text = i .. ") " .. opt
            if #text > w then text = text:sub(1, w) end
            monitor.write(text)
        end

        local function fromTouch()
            while true do
                local event, side, x, y = os.pullEvent("monitor_touch")
                local idx = y - 1
                if idx >= 1 and idx <= #options then
                    choice = options[idx]
                    return
                end
            end
        end
        parallel.waitForAny(fromKeyboardTerm, fromTouch)
    else
        fromKeyboardTerm()
    end

    return choice
end
-- ============ Playlist/voice/jingle beheer ============

local CATEGORY_LABELS = { "A", "B", "C", "Recents", "Golds" }
local TEMPO_LABELS = { "fast", "medium", "slow" }

local function addTrack(list, monitor)
    local name = askText(monitor, "Naam nummer")
    local artist = askText(monitor, "Artiest")
    local url = askText(monitor, "Directe .dfpwm URL")
    local category = askChoice(monitor, "Categorie:", CATEGORY_LABELS)
    local tempo = askChoice(monitor, "Tempo:", TEMPO_LABELS)
    local style = askText(monitor, "Stijl (bv. rock, dance, pop, ballad, leeg mag ook)") or ""
    local holiday = (askText(monitor, "Feestdag? (leeg = geen, anders bv. kerst, halloween)") or ""):lower()

    if not (name and artist and url) then
        print("Geannuleerd.")
        return
    end

    table.insert(list, {
        name = name, artist = artist, url = url,
        category = category, tempo = tempo, style = style, holiday = holiday,
    })
    savePlaylist(list)
    print("Toegevoegd: '" .. name .. "' (" .. artist .. ") - bak " .. category .. (holiday ~= "" and (" [" .. holiday:upper() .. "]") or ""))
end

local function editTrack(list, monitor)
    if #list == 0 then print("Playlist is leeg.") return end
    local labels = {}
    for i, t in ipairs(list) do labels[i] = t.name .. " - " .. t.artist end
    local chosen = askChoice(monitor, "Welk nummer wil je bewerken?", labels)
    local n = nil
    for i, label in ipairs(labels) do
        if label == chosen then n = i break end
    end
    if not n then print("Ongeldige keuze.") return end
    local t = list[n]

    print("Laat een veld leeg om het ongewijzigd te laten.")
    local name = askText(monitor, "Naam [" .. t.name .. "]")
    if name and name ~= "" then t.name = name end

    local artist = askText(monitor, "Artiest [" .. t.artist .. "]")
    if artist and artist ~= "" then t.artist = artist end

    local url = askText(monitor, "URL [" .. t.url .. "]")
    if url and url ~= "" then t.url = url end

    savePlaylist(list)
    print("Bijgewerkt: '" .. t.name .. "'.")
end

local function removeTrack(list, monitor)
    if #list == 0 then print("Playlist is leeg.") return end
    local labels = {}
    for i, t in ipairs(list) do labels[i] = t.name .. " - " .. t.artist end
    local chosen = askChoice(monitor, "Welk nummer verwijderen?", labels)
    local n = nil
    for i, label in ipairs(labels) do
        if label == chosen then n = i break end
    end
    if n then
        print("Verwijderd: '" .. list[n].name .. "'.")
        table.remove(list, n)
        savePlaylist(list)
    else
        print("Ongeldige keuze.")
    end
end

local function listTracks(list)
    if #list == 0 then print("Playlist is leeg.") return end
    for i, t in ipairs(list) do
        print(string.format("%d) [%s] %s - %s (%s, %s)%s",
            i, t.category, t.name, t.artist, t.tempo, t.style ~= "" and t.style or "-",
            t.holiday ~= "" and (" [" .. t.holiday:upper() .. "]") or ""))
    end
end

local function addVoiceTrack(voiceList, monitor)
    local name = askText(monitor, "Naam pratend stukje")
    local url = askText(monitor, "Directe .dfpwm URL")
    if not (name and url) then print("Geannuleerd.") return end
    table.insert(voiceList, { name = name, url = url })
    saveVoiceTracks(voiceList)
    print("Toegevoegd: '" .. name .. "'.")
end

local function removeVoiceTrack(voiceList, monitor)
    if #voiceList == 0 then print("Nog geen pratende stukjes.") return end
    local labels = {}
    for i, vt in ipairs(voiceList) do labels[i] = vt.name end
    local chosen = askChoice(monitor, "Welk stukje verwijderen?", labels)
    local n = nil
    for i, label in ipairs(labels) do
        if label == chosen then n = i break end
    end
    if n then
        print("Verwijderd: '" .. voiceList[n].name .. "'.")
        table.remove(voiceList, n)
        saveVoiceTracks(voiceList)
    else
        print("Ongeldige keuze.")
    end
end

local function listVoiceTracks(voiceList)
    if #voiceList == 0 then print("Nog geen pratende stukjes.") return end
    for i, vt in ipairs(voiceList) do
        print(i .. ") " .. vt.name)
    end
end

local function addJingle(jingleList, monitor)
    local name = askText(monitor, "Naam jingle/station-ID")
    local url = askText(monitor, "Directe .dfpwm URL")
    if not (name and url) then print("Geannuleerd.") return end
    table.insert(jingleList, { name = name, url = url })
    saveJingles(jingleList)
    print("Toegevoegd: '" .. name .. "'.")
end

local function removeJingle(jingleList, monitor)
    if #jingleList == 0 then print("Nog geen jingles.") return end
    local labels = {}
    for i, j in ipairs(jingleList) do labels[i] = j.name end
    local chosen = askChoice(monitor, "Welke jingle verwijderen?", labels)
    local n = nil
    for i, label in ipairs(labels) do
        if label == chosen then n = i break end
    end
    if n then
        print("Verwijderd: '" .. jingleList[n].name .. "'.")
        table.remove(jingleList, n)
        saveJingles(jingleList)
    else
        print("Ongeldige keuze.")
    end
end

local function listJingles(jingleList)
    if #jingleList == 0 then print("Nog geen jingles.") return end
    for i, j in ipairs(jingleList) do
        print(i .. ") " .. j.name)
    end
end

-- ============ Dagschema's bouwen ============

local function printScheduleSummary(schedule)
    for _, slot in ipairs(schedule) do
        if slot.type == "talk" then
            print(string.format("%02d:00 - [TALK] %s", slot.hour, slot.track.name))
        elseif slot.type == "jingle" then
            print(string.format("%02d:00 - [JINGLE] %s", slot.hour, slot.track.name))
        else
            print(string.format("%02d:00 - %s - %s [%s]",
                slot.hour, slot.track.name, slot.track.artist, slot.track.category))
        end
    end
end

local function buildSchedule(list, voiceList, jingleList)
    saveHistory({})
    print("Klok: " .. table.concat(CLOCK_PATTERN, " - "))
    local schedule = generateSchedule(list, voiceList, jingleList, DEFAULT_SCHEDULE_SLOTS)
    if schedule then
        print("Dagschema klaar met " .. #schedule .. " slots:")
        printScheduleSummary(schedule)
    end
    return schedule
end

local function buildHolidaySchedule(list, voiceList, jingleList, holidayName)
    local holidayList = {}
    for _, t in ipairs(list) do
        if t.holiday ~= "" and t.holiday == holidayName then table.insert(holidayList, t) end
    end
    if #holidayList == 0 then
        print("Geen nummers gevonden voor '" .. holidayName .. "'.")
        return nil
    end
    saveHistory({})
    print(holidayName:upper() .. "-klok: " .. table.concat(CLOCK_PATTERN, " - "))
    local schedule = generateSchedule(holidayList, voiceList, jingleList, DEFAULT_SCHEDULE_SLOTS)
    if schedule then
        print(holidayName:upper() .. "-dagschema klaar met " .. #schedule .. " slots:")
        printScheduleSummary(schedule)
    end
    return schedule
end

local function chooseHolidayAndBuild(list, voiceList, jingleList, monitor)
    local seen = {}
    local names = {}
    for _, t in ipairs(list) do
        if t.holiday ~= "" and not seen[t.holiday] then
            seen[t.holiday] = true
            table.insert(names, t.holiday)
        end
    end
    if #names == 0 then
        print("Nog geen feestdag-nummers. Voeg er eerst toe via optie 1")
        print("en vul bij 'Feestdag?' bijvoorbeeld kerst, halloween of koningsdag in.")
        return nil
    end
    local holidayName = askChoice(monitor, "Welke feestdag wil je genereren?", names)
    return buildHolidaySchedule(list, voiceList, jingleList, holidayName)
end

local function generateBestSchedule(list, voiceList, jingleList)
    local activeHoliday = detectActiveHoliday(list)
    if activeHoliday then
        print("Vandaag valt binnen de " .. activeHoliday:upper() .. "-periode - automatisch " .. activeHoliday .. "-schema.")
        return buildHolidaySchedule(list, voiceList, jingleList, activeHoliday)
    else
        return buildSchedule(list, voiceList, jingleList)
    end
end

-- ============ YouTube trending (Data API v3) ============

local YOUTUBE_APIKEY_FILE = "youtube_apikey.txt"

local function loadYoutubeApiKey()
    if not fs.exists(YOUTUBE_APIKEY_FILE) then return nil end
    local f = fs.open(YOUTUBE_APIKEY_FILE, "r")
    local key = f.readAll()
    f.close()
    key = key:gsub("%s+", "")
    return key ~= "" and key or nil
end

local function saveYoutubeApiKey(key)
    local f = fs.open(YOUTUBE_APIKEY_FILE, "w")
    f.write(key)
    f.close()
end

local function getOrAskYoutubeApiKey()
    local key = loadYoutubeApiKey()
    if key then return key end
    print("Nog geen YouTube API-key opgeslagen.")
    print("Haal er gratis een op via console.cloud.google.com")
    print("(YouTube Data API v3 inschakelen, dan een API-key aanmaken).")
    write("Plak je API-key: ")
    key = read()
    if key == "" then return nil end
    saveYoutubeApiKey(key)
    return key
end

local function fetchTrendingMusic(regionCode)
    local apiKey = getOrAskYoutubeApiKey()
    if not apiKey then
        print("Geen API-key ingevoerd, kan niks ophalen.")
        return nil
    end

    local url = "https://www.googleapis.com/youtube/v3/videos?part=snippet&chart=mostPopular"
        .. "&videoCategoryId=10&regionCode=" .. regionCode .. "&maxResults=15&key=" .. apiKey

    local response, err = http.get(url)
    if not response then
        print("Kon YouTube niet bereiken: " .. tostring(err))
        print("(controleer of googleapis.com is toegestaan in de http-regels van de server)")
        return nil
    end

    local body = response.readAll()
    response.close()

    local ok, data = pcall(textutils.unserialiseJSON, body)
    if not ok or not data then
        print("Kon het antwoord van YouTube niet lezen.")
        return nil
    end
    if data.error then
        print("YouTube gaf een foutmelding: " .. tostring(data.error.message))
        return nil
    end

    local results = {}
    for _, item in ipairs(data.items or {}) do
        table.insert(results, { title = item.snippet.title, channel = item.snippet.channelTitle })
    end
    return results
end

local function showTrendingMusic(monitor)
    local region = askText(monitor, "Regiocode (bv. NL, US, GB), leeg = NL") or ""
    if region == "" then region = "NL" end

    print("Ophalen...")
    if monitor then
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Trending muziek ophalen...")
    end

    local results = fetchTrendingMusic(region:upper())

    if not results or #results == 0 then
        if not results then
            print("Kon geen trending muziek ophalen (zie foutmelding hierboven).")
        else
            print("Geen resultaten gevonden.")
        end
        if monitor then
            monitor.clear()
            monitor.setCursorPos(1, 1)
            if monitorHasColor(monitor) then monitor.setTextColor(colors.red) end
            monitor.write("Kon niets ophalen.")
            if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
            monitor.setCursorPos(1, 3)
            monitor.write("Kijk op het terminalscherm voor de foutmelding.")
            monitor.setCursorPos(1, 5)
            if monitorHasColor(monitor) then monitor.setTextColor(colors.orange) end
            monitor.write("[Tik of druk op een toets om terug te gaan]")
            if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
            parallel.waitForAny(
                function() os.pullEvent("key") end,
                function() os.pullEvent("monitor_touch") end
            )
        end
        return
    end

    print("== Trending muziek (" .. region:upper() .. ") ==")
    for i, r in ipairs(results) do
        print(i .. ") " .. r.title .. " - " .. r.channel)
    end
    print("")
    print("Dit is alleen een lijstje - zoek en converteer het nummer nog")
    print("steeds zelf (music.madefor.cc -> catbox.moe) en voeg het toe via optie 1.")

    if monitor then
        local w, h = monitor.getSize()
        monitor.clear()
        monitor.setCursorPos(1, 1)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.yellow) end
        monitor.write(("Trending (%s)"):format(region:upper()))
        if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end

        local maxRows = h - 2 -- laatste rij is voor de "terug"-knop
        for i, r in ipairs(results) do
            if i > maxRows then break end
            local text = i .. ") " .. r.title .. " - " .. r.channel
            if #text > w then text = text:sub(1, w) end
            monitor.setCursorPos(1, 1 + i)
            monitor.write(text)
        end

        monitor.setCursorPos(1, h)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.orange) end
        monitor.write("[Tik of druk op een toets om terug te gaan]")
        if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end

        parallel.waitForAny(
            function() os.pullEvent("key") end,
            function() os.pullEvent("monitor_touch") end
        )
    end
end

-- ============ Rednet (verbinding met de radio-computer) ============

local function openRednet()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            rednet.open(name)
            return true
        end
    end
    return false
end

local radioId = nil

local function sendToRadio(msg)
    if not radioId then
        radioId = rednet.lookup(PROTOCOL, "radio")
    end
    if not radioId then
        print("Radio-computer niet gevonden via rednet.")
        print("Draait 'radio.lua' daar, en heeft die computer een modem?")
        return false
    end
    rednet.send(radioId, msg, PROTOCOL)
    return true
end


-- Tekent het menu vanaf item 'scrollOffset+1', en geeft een tabel
-- terug die per monitor-rij aangeeft wat een tik daar betekent
-- ({type="select", index=N} of {type="scroll", dir=-1/1}).
local function drawMenuOnMonitor(monitor, scrollOffset, title, items)
    if not monitor then return {} end
    scrollOffset = scrollOffset or 0
    monitor.clear()

    local w, h = monitor.getSize()
    monitor.setCursorPos(1, 1)
    if monitorHasColor(monitor) then monitor.setTextColor(colors.yellow) end
    local t = title
    if #t > w then t = t:sub(1, w) end
    monitor.write(t)
    if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end

    -- rij 1 = titel, laatste rij = statusregel, de rest is voor items
    local itemRows = math.max(1, h - 2)
    local hasMoreAbove = scrollOffset > 0
    local hasMoreBelow = (scrollOffset + itemRows) < #items
    if hasMoreAbove then itemRows = itemRows - 1 end
    if hasMoreBelow then itemRows = itemRows - 1 end
    if itemRows < 1 then itemRows = 1 end
    hasMoreBelow = (scrollOffset + itemRows) < #items

    local rowMap = {}
    local row = 2

    if hasMoreAbove then
        monitor.setCursorPos(1, row)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.orange) end
        monitor.write("^ Omhoog (tik hier)")
        if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
        rowMap[row] = { type = "scroll", dir = -itemRows }
        row = row + 1
    end

    for i = 1, itemRows do
        local itemIndex = scrollOffset + i
        if itemIndex > #items then break end
        local text = itemIndex .. ") " .. items[itemIndex]
        if #text > w then text = text:sub(1, w) end
        monitor.setCursorPos(1, row)
        monitor.write(text)
        rowMap[row] = { type = "select", index = itemIndex }
        row = row + 1
    end

    if hasMoreBelow then
        monitor.setCursorPos(1, row)
        if monitorHasColor(monitor) then monitor.setTextColor(colors.orange) end
        monitor.write("v Omlaag (tik hier)")
        if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
        rowMap[row] = { type = "scroll", dir = itemRows }
    end

    return rowMap
end

local function drawStatusLine(monitor, text)
    if not monitor then return end
    local w, h = monitor.getSize()
    monitor.setCursorPos(1, h)
    monitor.write(string.rep(" ", w))
    monitor.setCursorPos(1, h)
    if monitorHasColor(monitor) then monitor.setTextColor(colors.lime) end
    monitor.write(text:sub(1, w))
    if monitorHasColor(monitor) then monitor.setTextColor(colors.white) end
end

-- Wacht op ofwel getypte tekst op het toetsenbord, ofwel een tik op
-- de monitor - wat het eerst komt wint. Tikken op "omhoog"/"omlaag"
-- scrollt het menu; tikken op een item kiest het.
local function getMenuChoice(monitor, title, items)
    local choice = nil
    local scrollOffset = 0
    local rowMap = drawMenuOnMonitor(monitor, scrollOffset, title, items)

    local function fromKeyboard()
        write("> ")
        choice = read()
    end

    if monitor then
        local function fromTouch()
            while true do
                local event, side, x, y = os.pullEvent("monitor_touch")
                local action = rowMap[y]
                if action then
                    if action.type == "select" then
                        choice = tostring(action.index)
                        return
                    elseif action.type == "scroll" then
                        scrollOffset = math.max(0, scrollOffset + action.dir)
                        rowMap = drawMenuOnMonitor(monitor, scrollOffset, title, items)
                    end
                end
            end
        end
        parallel.waitForAny(fromKeyboard, fromTouch)
    else
        fromKeyboard()
    end

    return choice
end

local function printMenuConsole(title, items)
    print("")
    print("== " .. title .. " ==")
    for i, label in ipairs(items) do
        print(i .. ") " .. label)
    end
end

-- ============ Hoofdprogramma ============

local function main()
    math.randomseed(os.epoch("utc"))
    local list = loadPlaylist()
    local voiceList = loadVoiceTracks()
    local jingleList = loadJingles()
    local monitor = findMonitor()
    setupMonitor(monitor)

    if not openRednet() then
        print("Geen modem gevonden - kan niet met de radio-computer verbinden.")
        print("Zet er een naast deze computer (wired of wireless).")
    end
    rednet.host(PROTOCOL, "server")

    syncFromGithub(list, voiceList, jingleList)

    drawMenuOnMonitor(monitor, 0, "SERVER MENU", MAIN_MENU_ITEMS)
    drawStatusLine(monitor, "Wachten op status van de radio...")

    local AUTO_SYNC_INTERVAL_SEC = 120 -- elke 2 minuten opnieuw checken op GitHub

    local function autoSyncLoop()
        while true do
            os.sleep(AUTO_SYNC_INTERVAL_SEC)
            syncFromGithub(list, voiceList, jingleList)
        end
    end

    -- checkt periodiek of er een nieuwere server.lua op GitHub staat;
    -- zo ja, dan herstart de computer (startup.lua haalt 'm dan op)
    local function autoUpdateLoop()
        while true do
            os.sleep(AUTO_SYNC_INTERVAL_SEC)
            local resp = http.get(GITHUB_RAW .. "/scripts/server.lua")
            if resp then
                local remote = resp.readAll()
                resp.close()
                local f = fs.open("server.lua", "r")
                local current = f.readAll()
                f.close()
                if remote ~= current and remote ~= "" then
                    print("Nieuwe versie van server.lua gevonden op GitHub - herstarten...")
                    os.sleep(2)
                    os.reboot()
                end
            end
        end
    end

    local function statusListener()
        while true do
            local senderId, msg = rednet.receive(PROTOCOL)
            if type(msg) == "table" then
                if msg.cmd == "status" and msg.slot then
                    local slot = msg.slot
                    local text
                    if slot.type == "talk" then
                        text = "DJ praat: " .. slot.track.name
                    elseif slot.type == "jingle" then
                        text = "Station ID: " .. slot.track.name
                    else
                        text = "Nu op de zender: " .. slot.track.name .. " - " .. slot.track.artist
                    end
                    drawStatusLine(monitor, text)
                elseif msg.cmd == "request_schedule" then
                    print("De radio vraagt om een nieuw dagschema...")
                    local schedule = generateBestSchedule(list, voiceList, jingleList)
                    if schedule then
                        sendToRadio({ cmd = "schedule", data = schedule })
                        sendToRadio({ cmd = "start" })
                        print("Nieuw dagschema verstuurd naar de radio.")
                    end
                end
            end
        end
    end

    local function radioControlMenu()
        while true do
            drawMenuOnMonitor(monitor, 0, "RADIO BEDIENEN", RADIO_CONTROL_MENU_ITEMS)
            printMenuConsole("Radio bedienen", RADIO_CONTROL_MENU_ITEMS)
            local choice = getMenuChoice(monitor, "RADIO BEDIENEN", RADIO_CONTROL_MENU_ITEMS)

            if choice == "1" then
                if sendToRadio({ cmd = "start" }) then print("Startcommando verstuurd.") end
            elseif choice == "2" then
                if sendToRadio({ cmd = "stop" }) then print("Stopcommando verstuurd.") end
            elseif choice == "3" then
                if sendToRadio({ cmd = "skip" }) then print("Skipcommando verstuurd.") end
            elseif choice == "4" then
                if sendToRadio({ cmd = "pause" }) then print("Pauzecommando verstuurd.") end
            elseif choice == "5" then
                return
            else
                print("Onbekende optie.")
            end
        end
    end

    local function libraryMenu()
        while true do
            drawMenuOnMonitor(monitor, 0, "BIBLIOTHEEK", LIBRARY_MENU_ITEMS)
            printMenuConsole("Bibliotheek beheren", LIBRARY_MENU_ITEMS)
            local choice = getMenuChoice(monitor, "BIBLIOTHEEK", LIBRARY_MENU_ITEMS)

            if choice == "1" then
                removeTrack(list, monitor)
            elseif choice == "2" then
                editTrack(list, monitor)
            elseif choice == "3" then
                listTracks(list)
            elseif choice == "4" then
                addVoiceTrack(voiceList, monitor)
            elseif choice == "5" then
                removeVoiceTrack(voiceList, monitor)
            elseif choice == "6" then
                listVoiceTracks(voiceList)
            elseif choice == "7" then
                addJingle(jingleList, monitor)
            elseif choice == "8" then
                removeJingle(jingleList, monitor)
            elseif choice == "9" then
                listJingles(jingleList)
            elseif choice == "10" then
                return
            else
                print("Onbekende optie.")
            end
        end
    end

    local function menuLoop()
        while true do
            drawMenuOnMonitor(monitor, 0, "SERVER MENU", MAIN_MENU_ITEMS)
            printMenuConsole("Server (studio)", MAIN_MENU_ITEMS)
            local choice = getMenuChoice(monitor, "SERVER MENU", MAIN_MENU_ITEMS)

            if choice == "1" then
                addTrack(list, monitor)
            elseif choice == "2" then
                local schedule = generateBestSchedule(list, voiceList, jingleList)
                if schedule and sendToRadio({ cmd = "schedule", data = schedule }) then
                    sendToRadio({ cmd = "start" })
                    print("Verstuurd naar de radio, uitzending gestart.")
                end
            elseif choice == "3" then
                local schedule = chooseHolidayAndBuild(list, voiceList, jingleList, monitor)
                if schedule and sendToRadio({ cmd = "schedule", data = schedule }) then
                    sendToRadio({ cmd = "start" })
                    print("Feestdagschema verstuurd naar de radio, uitzending gestart.")
                end
            elseif choice == "4" then
                radioControlMenu()
            elseif choice == "5" then
                libraryMenu()
            elseif choice == "6" then
                showTrendingMusic(monitor)
            elseif choice == "7" then
                syncFromGithub(list, voiceList, jingleList)
            elseif choice == "8" then
                print("Tot ziens!")
                return
            else
                print("Onbekende optie.")
            end
        end
    end

    parallel.waitForAny(menuLoop, statusListener, autoSyncLoop, autoUpdateLoop)
end

main()
