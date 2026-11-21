local function LogInfo(
    initialPokemonList,
    initialTrainers,
    initialTMs,
    initialStarterNumber,
    initialMiscInfo,
    initialStarters,
    initialPivotData)
    local self = {}
    local pokemonList = initialPokemonList
    local trainers = initialTrainers
    local TMs = initialTMs
    local starters = initialStarters
    local miscInfo = initialMiscInfo
    local pivotData = initialPivotData
    local starterNumber = 1

    function self.setStarterNumberFromPlayerPokemonID(id)
        starterNumber = 1
        if starters[id] then
            starterNumber = starters[id]
        end
    end

    function self.getStarterNumber()
        return starterNumber
    end

    function self.getPokemon()
        return pokemonList
    end

    function self.getTrainers()
        return trainers
    end

    function self.getTMs()
        return TMs
    end

    function self.getMappings()
    end

    function self.getMiscInfo()
        return miscInfo
    end

    function self.getPivotData()
        return pivotData
    end

    return self
end

local function RandomizerLogParser(initialProgram)
    local self = {
        ENCOUNTER_TYPE_TO_PERCENTS = {
            ["Old Rod"] = {60, 30, 5, 4, 1},
            ["Headbutt"] = {50, 15, 15, 10, 5, 5},
            ["Bug Catching"] = {20, 20, 10, 10, 10, 10, 5, 5, 5, 5}
        },
        --indexed by version group, see GameInfo.lua
        ROUTE_NAME_TO_CORRECT_SET = {
             [1] = {
                ["Lake Verity"] = {
                    ["Grass/Cave"] = "341"
                },
                ["Route 204"] = {
                    ["Grass/Cave"] = "379",
                    ["Old Rod"] = "382"
                }
            },
            [2] = {
                ["Lac Vérité"] = {
                    ["Grass/Cave"] = "345"
                },
                ["Route 204"] = {
                    ["Grass/Cave"] = "383",
                    ["Old Rod"] = "386"
                }
            },
            [3] = {
                ["Ruines d'Alpha"] = {
                    ["Grass/Cave"] = "68"
                },
                ["Antre Noir"] = {
                    ["Grass/Cave"] = "365"
                }
            },
            [4] = {
                ["Wellspring Cave"] = {
                    ["Grass/Cave"] = "181",
                    ["Shaking Spots"] = "182"
                }
            }
        },
        EXCLUDED_ROUTE_PIVOTS = {
            [1] = {
                ["Route 218"] = {
                    ["Grass/Cave"] = true
                }
            },
            [2] = {
                ["Route 218"] = {
                    ["Grass/Cave"] = true
                }
            },
        },
        DUPLICATE_ROUTE_TO_NEW_PIVOT_TYPE = {
            ["142"] = "Ext. Grass",
            ["148"] = "Int. Grass"
        },
        --indexed by game's version group. 4 is black/white. Target names must match
        --LOCATION_DATA.encounterAreaOrder / the "locations" map-name table for that
        --version group (both use "Empoigne exterieur"/"Empoigne interieur", the
        --French names this fork translated "Pinwheel Exterior/Interior" to) — a
        --stale English target here means the pivot never matches its UI label,
        --which leaves currentEncounterArea nil and crashes PivotsScreen.
        ROUTE_NUMBER_TO_CORRECT_NAME = {
            [4] = {
                ["18"] = "Empoigne exterieur",
                ["19"] = "Empoigne exterieur",
                ["20"] = "Empoigne exterieur",
                ["21"] = "Empoigne interieur",
                ["22"] = "Empoigne interieur",
                ["23"] = "Empoigne interieur",
            }
        },
        --indexed by version group: raw English area names as they may appear in a
        --randomizer log generated from an English ROM, mapped to this fork's French
        --label — for areas whose LOCATION_DATA name was translated to French but
        --whose raw log text (drawn from the ROM's own map name text bank) is only
        --French when the ROM itself is French. Checked as a fallback after
        --ROUTE_NUMBER_TO_CORRECT_NAME, so a genuine French-ROM log (already matching
        --directly) is unaffected.
        AREA_NAME_ENGLISH_TO_LOCAL = {
            [4] = {
                ["Dreamyard"] = "Vestiges du Rêve",
                ["Wellspring Cave"] = "Veine Souterraine"
            }
        }
    }

    local moveIDMappings = {}
    local pokemonIDMappings = {}
    local abilityIDMappings = {}
    local itemIDMappings = {}

    local program = initialProgram
    local pokemonList = {}
    local trainers = {}
    local TMs = {}
    local starters = {}
    local pivotData = {}
    local totalLines

    local function parseRandomizedEvolutions(lines, lineStart)
        local currentLineIndex = lineStart
        while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
            local currentLine = lines[currentLineIndex]
            local lineSplit = MiscUtils.split(currentLine, "->", true)
            local pokemonName, evolutionList = lineSplit[1], lineSplit[2]
            pokemonName = pokemonName:lower()
            local evolutions = {}
            --mr. mime is annoying, take out space after period then re-add it so the split works
            evolutionList = evolutionList:gsub("%. ", ".")
            for _, evolutionData in pairs(MiscUtils.split(evolutionList, " ", true)) do
                local evolutionName = evolutionData:gsub(",", ""):gsub("%.", ". ")
                evolutionName = evolutionName:lower()
                if pokemonIDMappings[evolutionName] then
                    local evolutionID = pokemonIDMappings[evolutionName]
                    table.insert(evolutions, evolutionID)
                end
            end
            local pokemonID = pokemonIDMappings[pokemonName]
            pokemonList[pokemonID].evolutions = evolutions
            currentLineIndex = currentLineIndex + 1
        end
        return true
    end

    local function readPokemonIntoTeam(pokemonInfo, trainerTeam, trainerID)
        local nameAndItem, level = pokemonInfo:match("(.*) Lv(%d+)")
        local nameItemSplit = MiscUtils.split(nameAndItem, "@", true)
        local heldItem = nil
        if nameItemSplit[2] ~= nil then
            local heldItemName = nameItemSplit[2]
            heldItemName = heldItemName:gsub("’", "'")
            if itemIDMappings[heldItemName] then
                heldItem = itemIDMappings[heldItemName]
            end
        end
        local pokemonName = nameItemSplit[1]
        pokemonName = pokemonName:lower()
        local pokemonID = pokemonIDMappings[pokemonName]
        local pokemon = {
            ["pokemonID"] = pokemonID,
            ["level"] = tonumber(level),
            ["heldItem"] = tonumber(heldItem)
        }
        table.insert(trainerTeam, pokemon)
    end

    local function parseTrainers(lines, lineStart)
        local currentLineIndex = lineStart
        while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
            local currentLine = lines[currentLineIndex]
            local trainerTeam = {}
            local trainer, teamList = currentLine:match("(.*)%).*%- (.*)")
            local trainerID = tonumber(trainer:match("#(%d+)"))
            local teamInfo = MiscUtils.split(teamList, ",", true)
            for _, pokemonInfo in pairs(teamInfo) do
                readPokemonIntoTeam(pokemonInfo, trainerTeam, trainerID)
            end
            if trainerID ~= nil then
                trainers[trainerID] = trainerTeam
            end
            currentLineIndex = currentLineIndex + 1
        end
        return true
    end

    local function parsePokemonLevelupMoves(lines, lineStart)
        local currentLineIndex = lineStart
        while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
            local currentLine = lines[currentLineIndex]
            local lineSplit = MiscUtils.split(currentLine, "->", true)
            local pokemonName = lineSplit[1]:match("%d+%s(.+)")
            pokemonName = pokemonName:lower()
            local pokemonID = pokemonIDMappings[pokemonName]
            pokemonList[pokemonID].moves = {}
            --next 7 lines are not necessary, they're the base stats (which we grab elsewhere)
            currentLineIndex = currentLineIndex + 7
            while #MiscUtils.split(lines[currentLineIndex], ":", true) == 2 and lines[currentLineIndex] ~= "Egg Moves:" and
                currentLineIndex <= totalLines do
                currentLine = lines[currentLineIndex]
                local moveInfo = MiscUtils.split(currentLine, ":", true)
                local level = moveInfo[1]:match("%d+")
                local name = moveInfo[2]
                local id = moveIDMappings[name]
                table.insert(
                    pokemonList[pokemonID].moves,
                    {
                        ["move"] = id,
                        ["level"] = tonumber(level)
                    }
                )
                currentLineIndex = currentLineIndex + 1
            end
            while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
                currentLineIndex = currentLineIndex + 1
            end
            currentLineIndex = currentLineIndex + 1
        end
        return true
    end

    local function parseTMMoves(lines, lineStart)
        local currentLineIndex = lineStart
        while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
            local currentLine = lines[currentLineIndex]
            local moveName = currentLine:match("[%a%d]+ (.*)")
            local moveID = moveIDMappings[moveName]
            table.insert(TMs, moveID)
            currentLineIndex = currentLineIndex + 1
        end
        return true
    end

    local function parseTMCompatibility(lines, lineStart)
        local currentLineIndex = lineStart
        while lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines do
            local currentLine = lines[currentLineIndex]
            local lineSplit = MiscUtils.split(currentLine, "|", true)
            local pokemonName = lineSplit[1]:match("%d+%s(.+)")
            local pokemonID = pokemonIDMappings[pokemonName:lower()]
            table.remove(lineSplit, 1)
            pokemonList[pokemonID].pokemonTMsLearnable = {}
            for index, TMInfo in pairs(lineSplit) do
                pokemonList[pokemonID].pokemonTMsLearnable[index] = (TMInfo ~= "-")
            end
            currentLineIndex = currentLineIndex + 1
        end
        return true
    end

    local function parseMiscInfo(lines)
        return {
            version = lines[1]:match("Randomizer Version: (.*)"),
            seed = lines[2]:match("Random Seed: (%d+)"),
            settingsString = lines[3]:match("Settings String: (.*)")
        }
    end

    local function parsePokemon(lines, lineStart)
        pokemonList = {}
        local currentLineIndex = lineStart + 1
        while (lines[currentLineIndex] ~= nil and lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines) do
            local currentLine = lines[currentLineIndex]
            local pokemonData = MiscUtils.split(currentLine, "|", true)
            local pokemonID = tonumber(pokemonData[1])
            if pokemonID ~= nil then
                local pokemonName = pokemonData[2]
                pokemonName = pokemonName:lower()
                pokemonIDMappings[pokemonName] = pokemonID
                pokemonList[pokemonID] = {}
                local pokemon = pokemonList[pokemonID]
                pokemon.stats = {
                    HP = tonumber(pokemonData[4]),
                    ATK = tonumber(pokemonData[5]),
                    DEF = tonumber(pokemonData[6]),
                    SPA = tonumber(pokemonData[7]),
                    SPD = tonumber(pokemonData[8]),
                    SPE = tonumber(pokemonData[9])
                }
                pokemon.pokemonID = pokemonID
                program.addAdditionalDataToPokemon(pokemon)
                local abilityNames = {pokemonData[10], pokemonData[11], pokemonData[12]}
                pokemon.abilities = {}
                for _, abilityName in pairs(abilityNames) do
                    table.insert(pokemon.abilities, abilityIDMappings[abilityName] or 0)
                end
            end
            currentLineIndex = currentLineIndex + 1
        end
        if pokemonList[647] ~= nil then
            pokemonIDMappings["keldeo-r"] = 647
        end
        return true
    end

    local function parseMoveInfo(lines, lineStart)
        if lineStart ~= nil then
            moveIDMappings = {}
            --header below section name that we don't care about
            local currentLineIndex = lineStart + 1
            while (lines[currentLineIndex] ~= nil and lines[currentLineIndex] ~= "" and currentLineIndex <= totalLines) do
                local lineInfo = MiscUtils.split(lines[currentLineIndex], "|", true)
                local id, moveName = tonumber(lineInfo[1]), lineInfo[2]
                moveIDMappings[moveName] = id
                currentLineIndex = currentLineIndex + 1
            end
        end
    end

    local function checkGameName(lines, lineStart)
        local name = lines[lineStart]:match("Randomization of (Pokemon [%a%d ]+).* completed.")
        name = MiscUtils.trimWhitespace(name)
        local gameName = program.getGameInfo().NAME
        return gameName == name
    end

    local function parseStarterInfo(lines, lineStart)
        starters = {}
        for i = 0, 2, 1 do
            local starterLine = lines[lineStart + i]
            local number, name = starterLine:match("Set starter (%d+) to (.*)")
            name = name:lower()
            number = tonumber(number)
            starters[pokemonIDMappings[name]] = number
        end
    end

    local function readStandardEncounter(lines, line, startIndex, data)
        local slotPercents = {20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1}
        local pokemonName, level = lines[line]:match("(.*) Lv(%d+)")
        level = tonumber(level)
        pokemonName = pokemonName:lower()
        local id = pokemonIDMappings[pokemonName]
        local percent = slotPercents[line - startIndex + 1]
        local entry = data[id]
        if data[id] == nil then
            data[id] = {minLevel = level, maxLevel = level, ["percent"] = percent}
        else
            data[id] = {
                minLevel = math.min(entry.minLevel, level),
                maxLevel = math.max(entry.maxLevel, level),
                ["percent"] = entry.percent + percent
            }
        end
    end

    local function readNonstandardEncounter(lines, line, startIndex, data, encounterType)
        local slotPercents = self.ENCOUNTER_TYPE_TO_PERCENTS[encounterType]
        local pokemonName, ignore, minLevel, maxLevel = lines[line]:match("(.*) Lv(.-)(%d+)%-?(%d+)")
        if maxLevel == nil then
            maxLevel = minLevel
        end
        minLevel = tonumber(minLevel)
        maxLevel = tonumber(maxLevel)
        pokemonName = pokemonName:lower()
        local id = pokemonIDMappings[pokemonName]
        local percent = slotPercents[line - startIndex + 1]
        if percent == nil then
            return
        end
        local entry = data[id]
        if entry == nil then
            data[id] = {["minLevel"] = minLevel, ["maxLevel"] = maxLevel, ["percent"] = percent}
        else
            entry.minLevel = math.min(entry.minLevel, minLevel)
            entry.maxLevel = math.max(entry.maxLevel, maxLevel)
            entry.percent = entry.percent + percent
        end
    end

    local function readEncounters(lines, lineStart, pivotType)
        local data = {}
        local currentLineIndex = lineStart
        local startIndex = lineStart
        while (lines[currentLineIndex] ~= nil and lines[currentLineIndex] ~= "") do
            if pivotType == "Old Rod" or pivotType == "Headbutt" then
                readNonstandardEncounter(lines, currentLineIndex, startIndex, data, pivotType)
            else
                readStandardEncounter(lines, currentLineIndex, startIndex, data)
            end
            currentLineIndex = currentLineIndex + 1
        end
        return data
    end

    local function readBugCatchingEntry(lines, line, pivotData)
        local routeInfo = lines[line]
        --ignore pre nat dex, patch makes it post nat dex
        if lines[line]:find("Pre-National") then
            return
        end
        local days = {
            "Tuesday",
            "Thursday",
            "Saturday"
        }
				
        if not pivotData["Capture d'insectes"] then
            pivotData["Capture d'insectes"] = {}
        end
        line = line + 1
        local startIndex = line
        for _, day in pairs(days) do
            if routeInfo:find(day) then
                local data = {}
                while (lines[line] ~= nil and lines[line] ~= "") do
                    readNonstandardEncounter(lines, line, startIndex, data, "Bug Catching")
                    line = line + 1
                end
                pivotData["Capture d'insectes"][day] = data
            end
        end
    end

    --returns true if the route is valid, i.e. not an unwanted duplicate
    local function checkRouteDuplicate(areaName, setNumber, pivotType)
        local versionGroup = program.getGameInfo().VERSION_GROUP
        if not self.ROUTE_NAME_TO_CORRECT_SET[versionGroup] then
            return true
        end
        local routes = self.ROUTE_NAME_TO_CORRECT_SET[versionGroup]
        if not routes[areaName] then
            return true
        end
        local encounterToCorrectSet = routes[areaName]
        if not encounterToCorrectSet[pivotType] then
            return true
        end
        return encounterToCorrectSet[pivotType] == setNumber
    end

    local function formatPivotType(areaName, setNumber, pivotType)
        if self.DUPLICATE_ROUTE_TO_NEW_PIVOT_TYPE[setNumber] then
            return self.DUPLICATE_ROUTE_TO_NEW_PIVOT_TYPE[setNumber]
        end
        pivotType = pivotType:gsub("Doubles Grass", "Dark Grass")
        if not areaName:find("Cave") then
            return pivotType:gsub("/Cave", "")
        else
            return pivotType:gsub("Grass/", "")
        end
    end

    local function doAdditionalNameChecks(areaName, areaNumber)
        local versionGroup = program.getGameInfo().VERSION_GROUP
        if self.ROUTE_NUMBER_TO_CORRECT_NAME[versionGroup] ~= nil then
            areaName = self.ROUTE_NUMBER_TO_CORRECT_NAME[versionGroup][areaNumber] or areaName
        end
        local englishToLocal = self.AREA_NAME_ENGLISH_TO_LOCAL[versionGroup]
        if englishToLocal ~= nil and englishToLocal[areaName] ~= nil then
            areaName = englishToLocal[areaName]
        end
        return areaName
    end

    local function isPivotTypeExcluded(areaName, pivotType)
        local versionGroup = program.getGameInfo().VERSION_GROUP
        if not self.EXCLUDED_ROUTE_PIVOTS[versionGroup] then
            return false
        end
        if not self.EXCLUDED_ROUTE_PIVOTS[versionGroup][areaName] then
            return false
        end
        return self.EXCLUDED_ROUTE_PIVOTS[versionGroup][areaName][pivotType] or false
    end

    local function parseRouteData(lines, lineStart)
        local validRoutes = program.getGameInfo().LOCATION_DATA.encounterAreaOrder
        local timesSeenSprout = 0
        local pivotTypes = program.getGameInfo().PIVOT_TYPES
        local currentLineIndex = lineStart
        while (lines[currentLineIndex] ~= nil and lines[currentLineIndex]:sub(1, 2) ~= "--" and
            currentLineIndex <= totalLines) do
            local routeInfo = lines[currentLineIndex]
            for pivotType, _ in pairs(pivotTypes) do
                if routeInfo:find(pivotType) then
                    if pivotType == "Bug Catching" then
                        readBugCatchingEntry(lines, currentLineIndex, pivotData)
                    else
                        local number, areaName = routeInfo:match("Set #(%d+) %- (.+) " .. pivotType)
                        --very dumb but idk what else to do
                        if areaName == "Tour CHETIFLOR" then
                            timesSeenSprout = timesSeenSprout + 1
                            areaName = areaName .. " " .. timesSeenSprout .. "F"
                        end
                        local validRoute = checkRouteDuplicate(areaName, number, pivotType)
                        local validPivot = not isPivotTypeExcluded(areaName, pivotType)
                        pivotType = formatPivotType(areaName, number, pivotType)
                        areaName = doAdditionalNameChecks(areaName, number)
                        if MiscUtils.tableContains(validRoutes, areaName) and validRoute and validPivot then
                            if not pivotData[areaName] then
                                pivotData[areaName] = {}
                            end
                            if pivotType ~= "Headbutt" then
                                pivotData[areaName][pivotType] = readEncounters(lines, currentLineIndex + 1, pivotType)
                            else
                                local suffixes = { "(C)", "(R)" }
                                for index, suffix in pairs(suffixes) do
                                    local lineOffset = (index - 1) * 6
                                    pivotData[areaName]["Headbutt" .. suffix] =
                                        readEncounters(lines, currentLineIndex + 1 + lineOffset, pivotType)
                                end
                            end
						end
                    end
                end
            end
            currentLineIndex = currentLineIndex + 1
        end
        return pivotData
    end

    self.LogParserConstants = {
        SECTION_HEADER_TO_PARSE_FUNCTION = {
            ["--Pokemon Base Stats & Types--"] = parsePokemon,
            ["--Pokemon Movesets--"] = parsePokemonLevelupMoves,
            ["--Randomized Evolutions--"] = parseRandomizedEvolutions,
            ["--TM Moves--"] = parseTMMoves,
            ["--TM Compatibility--"] = parseTMCompatibility,
            ["--Trainers Pokemon--"] = parseTrainers,
            ["--Move Data--"] = parseMoveInfo,
            ["------------------------------------------------------------------"] = checkGameName,
            ["--Random Starters--"] = parseStarterInfo,
            ["--Custom Starters--"] = parseStarterInfo,
            ["--Wild Pokemon--"] = parseRouteData
        },
        PREFERRED_PARSE_ORDER = {
            --game name
            "------------------------------------------------------------------",
            "--Move Data--",
            "--Pokemon Base Stats & Types--",
            "--Pokemon Movesets--",
            "--Randomized Evolutions--",
            "--Wild Pokemon--",
            "--TM Moves--",
            "--TM Compatibility--",
            "--Trainers Pokemon--",
            "--Random Starters--",
            "--Custom Starters--"
        }
    }

    -- A log is always in the language of the ROM that was randomized, which may not
    -- match this fork's own (French) data tables — e.g. an English Black/White ROM
    -- randomized and opened in the French tracker. Merging in EnglishNames.lua (id ->
    -- English name, generated from the EN upstream tracker, same ids as this fork's
    -- own tables) as a fallback lets name-based log parsing (TM moves, held items,
    -- abilities…) work regardless of ROM language. Never overwrites an existing
    -- (French) mapping, so a genuine French log is unaffected. `existsAtID(id)` checks
    -- the id is real in this fork's own table before trusting it — callers pass the
    -- right lookup for their table's indexing convention (see below).
    local function addEnglishFallback(mappings, englishNames, existsAtID)
        for id, name in pairs(englishNames or {}) do
            if existsAtID(id) and mappings[name] == nil then
                mappings[name] = id
            end
        end
    end

    -- Pokemon names aren't merged here: parsePokemon() rebuilds pokemonIDMappings
    -- from the log's own "--Pokemon Base Stats & Types--" section every time (always
    -- present for a Kaizo/IronMon randomization), so it already matches whatever
    -- language the log is in without needing a static fallback.
    local function resetPokemon()
        for id, pokemon in pairs(PokemonData.POKEMON) do
            pokemonIDMappings[pokemon.name:lower()] = id
            pokemonList[id] = {}
        end
    end

    local function setUpMappings()
        for _, abilityInfo in pairs(AbilityData.ABILITIES) do
            abilityIDMappings[abilityInfo.name] = abilityInfo.id
        end
        -- AbilityData.ABILITIES / MoveData.MOVES are indexed by id + 1 (a plain Lua
        -- array whose first entry is the game's id-0 placeholder) — see e.g.
        -- AbilityData.ABILITIES[abilityId + 1] elsewhere in the codebase.
        addEnglishFallback(abilityIDMappings, EnglishNames.ABILITIES, function(id) return AbilityData.ABILITIES[id + 1] ~= nil end)
        for _, moveInfo in pairs(MoveData.MOVES) do
            moveIDMappings[moveInfo.name] = tonumber(moveInfo.id)
        end
        addEnglishFallback(moveIDMappings, EnglishNames.MOVES, function(id) return MoveData.MOVES[id + 1] ~= nil end)
        for id, itemInfo in pairs(ItemData.ITEMS) do
            itemIDMappings[itemInfo.name] = id
        end
        -- ItemData.ITEMS (unlike Pokemon/Move/Ability) is defined with explicit [id]
        -- brackets, so it's indexed directly by id — no +1. It's also swapped to
        -- GEN_4_ITEMS/GEN_5_ITEMS per game by GameConfigurator, so pick the matching
        -- English id space (see ItemData.lua — the two share id numbers for different
        -- items, e.g. gen4 id 200 isn't gen5 id 200).
        local englishItems = program.getGameInfo().GEN == 5 and EnglishNames.ITEMS_GEN5 or EnglishNames.ITEMS_GEN4
        addEnglishFallback(itemIDMappings, englishItems, function(id) return ItemData.ITEMS[id] ~= nil end)
    end

    function self.parse(inputFile)
        if FormsUtils.fileExists(inputFile) then
            resetPokemon()
            trainers = {}
            TMs = {}
            pivotData = {}
            local lines = MiscUtils.readLinesFromFile(inputFile, true)
            totalLines = #lines
            local sectionHeaderStarts = {}
            local totalFound = 0
            for index, line in pairs(lines) do
                if self.LogParserConstants.SECTION_HEADER_TO_PARSE_FUNCTION[line] and not sectionHeaderStarts[line] then
                    sectionHeaderStarts[line] = index + 1
                    totalFound = totalFound + 1
                    if totalFound == #self.LogParserConstants.PREFERRED_PARSE_ORDER - 1 then
                        break
                    end
                end
            end
            for _, sectionName in pairs(self.LogParserConstants.PREFERRED_PARSE_ORDER) do
                local lineStart = sectionHeaderStarts[sectionName]
                if lineStart ~= nil then
                    local parseFunction = self.LogParserConstants.SECTION_HEADER_TO_PARSE_FUNCTION[sectionName]
                    local success = parseFunction(lines, lineStart)
                    if success == false then
                        forms.destroyall()
                        FormsUtils.popupDialog(
                            "Game does not match. Only load logs with the same game as the one you're playing.",
                            250,
                            120,
                            FormsUtils.POPUP_DIALOG_TYPES.WARNING,
                            true
                        )
                        return nil
                    end
                end
            end
            local miscInfo = parseMiscInfo(lines)
            return LogInfo(pokemonList, trainers, TMs, 1, miscInfo, starters, pivotData)
        end
    end

    setUpMappings()

    return self
end

return RandomizerLogParser
