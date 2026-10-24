-- startup.lua (voor de RADIO-computer)
-- Hernoem dit bestand naar "startup" (of "startup.lua") op de
-- radio-computer. Bij elke boot checkt dit of er een nieuwere versie
-- van radio.lua op GitHub staat, haalt die op als dat zo is, en start
-- 'm dan op. radio.lua bevat zelf al de crash-herstel-lus.

local GITHUB_OWNER = "JOUW-GEBRUIKERSNAAM"   -- <-- aanpassen!
local GITHUB_REPO = "JOUW-REPO-NAAM"          -- <-- aanpassen!
local GITHUB_BRANCH = "main"
local GITHUB_RAW = "https://raw.githubusercontent.com/" .. GITHUB_OWNER .. "/" .. GITHUB_REPO .. "/" .. GITHUB_BRANCH

local function fetchText(url)
    local resp = http.get(url)
    if not resp then return nil end
    local body = resp.readAll()
    resp.close()
    return body
end

local function updateFileIfChanged(remotePath, localPath)
    local content = fetchText(GITHUB_RAW .. "/" .. remotePath)
    if not content or content == "" then
        return false, "kon " .. remotePath .. " niet ophalen"
    end

    local existing = nil
    if fs.exists(localPath) then
        local f = fs.open(localPath, "r")
        existing = f.readAll()
        f.close()
    end

    if content ~= existing then
        local f = fs.open(localPath, "w")
        f.write(content)
        f.close()
        return true
    end
    return false
end

print("Controleren op updates vanaf GitHub...")
local ok, updated = pcall(updateFileIfChanged, "scripts/radio.lua", "radio.lua")
if ok and updated then
    print("radio.lua bijgewerkt naar de nieuwste versie.")
elseif not ok then
    print("Kon niet updaten (geen internet/GitHub bereikbaar?), start met lokale versie.")
end

shell.run("radio")
