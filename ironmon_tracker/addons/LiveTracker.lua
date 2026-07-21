-- LiveTracker addon
--
-- Read-only companion-app integration: watches battle/run state and writes a small
-- JSON snapshot for the Node bridge to forward to the web app's /api/runs/live/*
-- endpoints. Never mutates tracker/battle state.
--
-- Kept in its own folder (not ironmon_tracker/extras) so it stays a clean diff
-- on top of upstream tracker updates.
--
-- Event delivery model (v6): the addon never assumes the bridge has read any given
-- write. It keeps a rolling buffer of recent events, each tagged with a strictly
-- increasing `seq`, and rewrites the whole buffer every flush. The bridge dedupes by
-- `seq` and only forwards events it hasn't seen. This removes the earlier race where
-- clearing the buffer right after a write (faster than the bridge polls) dropped
-- events -- which is what made session_start/resets and many events go missing.
--
-- New attempt = new LiveTracker instance. The tracker recreates Program (and thus
-- this addon) on every QuickLoad/reset (see Main.lua self.run() recursion), so a
-- fresh `sessionToken` per instance is the reliable "a new attempt started" signal,
-- independent of gameinfo.getromhash() quirks. A mid-instance ROM-hash change (manual
-- reload without a script restart) also rotates the token, as a backup.
--
-- Anti-spoiler rule: wild_encounter only ever sends what the tracker itself has
-- legitimately revealed through play (species/level shown on screen, abilities/moves
-- seen in battle so far, amount seen). It never reads PokemonData.POKEMON directly,
-- since that table holds this seed's full randomized stats/types/learnsets for every
-- species. The lead snapshot is exempt: it's the player's own party leader, exactly
-- like the tracker's own on-screen card already shows.

print("[LiveTracker] file loaded - v12 (battle_start waits for trainer id to be fetched)")

local function LiveTracker(battleHandler, gameInfo, tracker, program)
	local self = {}

	local OUTPUT_FILE = "savedData" .. Paths.SLASH .. "live_events.json"
	local MAX_BUFFERED_EVENTS = 200

	-- Unique per LiveTracker instance: os.time + this closure's table address. The
	-- address guarantees uniqueness even if two attempts start within the same second.
	local function newToken()
		return tostring(os.time()) .. "-" .. (tostring({}):match("0x%x+") or tostring(math.random(1, 1e9)))
	end

	local sessionToken = newToken()
	local eventSeq = 0
	local recentEvents = {} -- rolling buffer, never cleared on flush (see model above)
	local sessionStarted = false

	local wasInBattle = false
	-- True from the moment isInBattle() flips true until battle_start is actually
	-- pushed (see detectBattleTransitions): _enemyTrainerID/isWildBattle() aren't
	-- reliable yet at that exact frame -- BattleHandlerBase only refreshes them once
	-- its own battle-data fetch completes (_battleDataFetched), a few tenths of a
	-- second into the battle. Reading them immediately at the transition captures
	-- the PREVIOUS battle's trainer id instead of the new one.
	local pendingBattleStart = false
	local knownDefeatedTrainers = {}
	local lastRomHash = nil
	local hasWarnedPoll = false
	local hasWarnedFlush = false
	local currentState = nil -- live (overwrite) snapshot: card + location + heals + items
	local starterLogged = false
	local seedLogCache = nil -- this attempt's .nds.log content, scanned once (see getSeedLog)
	local lastSeedLogScanAt = 0 -- os.time() of the last dir/ls scan attempt, throttles getSeedLog
	local seedLogScanAttempts = 0 -- gives up after MAX_SEED_LOG_SCAN_ATTEMPTS (see getSeedLog)
	local knownBag = nil -- {itemId = qty} baseline for detecting pickups/uses
	local currentBag = {} -- last full bag scan, for the live "Sac" display
	local lastBadgeCount = nil -- baseline for badge_obtained
	local lastBadges = nil -- raw { firstSet, secondSet } for the live state snapshot

	-- Per-side (player/enemy) baselines used to diff PP (move used), HP (fainted) and
	-- status across polls. Re-baselined whenever the active battler's PID changes
	-- (switch-in / new encounter), so a freshly sent-out mon's full PP/HP/clear status
	-- is never read as a change versus the previous mon's values.
	local sides = {
		player = { pid = nil, pp = {}, fainted = false, status = 0 },
		enemy = { pid = nil, pp = {}, fainted = false, status = 0 },
	}
	local wildEncounterLoggedForBattle = false

	-- Tracks the team leader across the whole attempt: a pivot is "a different
	-- individual became leader", an evolution is "the same individual changed species",
	-- and a level increase on the same individual is a level_up.
	local lastLead = { pid = nil, pokemonID = nil, level = nil }

	local function pushEvent(eventType, payload)
		eventSeq = eventSeq + 1
		table.insert(recentEvents, {
			seq = eventSeq,
			type = eventType,
			payload = payload or {},
			occurred_at = os.time(),
		})
		while #recentEvents > MAX_BUFFERED_EVENTS do
			table.remove(recentEvents, 1)
		end
	end

	-- battleHandler._enemyTrainerID is a plain table field (no public getter exists
	-- for it), read directly here; this is the one place coupled to BattleHandler's
	-- internals and may need updating if that field is ever renamed upstream.
	local function getEnemyTrainerID()
		return battleHandler._enemyTrainerID
	end

	local function resetSide(side)
		side.pid = nil
		side.pp = {}
		side.fainted = false
		side.status = 0
	end

	-- Gen 4 party status byte (bitfield) -> a stable key. nil = no status.
	local function decodeStatus(value)
		if value == nil or value == 0 then
			return nil
		end
		if bit.band(value, 0x07) > 0 then return "sleep" end
		if bit.band(value, 0x80) > 0 then return "toxic" end
		if bit.band(value, 0x40) > 0 then return "paralysis" end
		if bit.band(value, 0x20) > 0 then return "freeze" end
		if bit.band(value, 0x10) > 0 then return "burn" end
		if bit.band(value, 0x08) > 0 then return "poison" end
		return nil
	end

	-- Begins a fresh attempt: new token (so the bridge creates a new run), reset seq
	-- and buffer, wipe all per-attempt dedup/baseline state, and queue session_start.
	local function beginAttempt()
		sessionToken = newToken()
		eventSeq = 0
		recentEvents = {}
		wasInBattle = false
		pendingBattleStart = false
		knownDefeatedTrainers = {}
		wildEncounterLoggedForBattle = false
		resetSide(sides.player)
		resetSide(sides.enemy)
		lastLead.pid = nil
		lastLead.pokemonID = nil
		lastLead.level = nil
		currentState = nil
		starterLogged = false
		seedLogCache = nil
		lastSeedLogScanAt = 0
		seedLogScanAttempts = 0
		knownBag = nil
		currentBag = {}
		lastBadgeCount = nil
		lastBadges = nil
		pushEvent("session_start", {})
	end

	-- A fresh instance already has a distinct token; this only needs to catch a ROM
	-- swap WITHIN the same instance (manual reload without a script restart). On the
	-- very first poll it just records the baseline hash (the instance token already
	-- represents this attempt).
	local function detectRomHashChange()
		local hash = gameinfo.getromhash()
		if lastRomHash == nil then
			lastRomHash = hash
			return
		end
		if hash ~= lastRomHash then
			lastRomHash = hash
			beginAttempt()
		end
	end

	-- battle_start is deferred until battleHandler confirms its own battle-data fetch
	-- completed (inBattleAndFetched): _enemyTrainerID/isWildBattle() read anything
	-- earlier than that would still hold the PREVIOUS battle's values (see
	-- BattleHandlerBase._onBattleFetchFrameCounter -- that fetch itself only runs
	-- every 60 frames, refreshing _enemyTrainerID for the first time sometime after
	-- battle transition, not at it). This is what caused killer attribution to
	-- occasionally report the trainer BEFORE the one that actually won/lost.
	local function detectBattleTransitions()
		local inBattle = battleHandler:isInBattle()
		if inBattle and not wasInBattle then
			pendingBattleStart = true
			resetSide(sides.player)
			resetSide(sides.enemy)
			wildEncounterLoggedForBattle = false
		elseif not inBattle and wasInBattle then
			-- Battle ended before the data fetch ever completed (a very short fight) --
			-- nothing reliable was ever read, so there's nothing honest to push.
			pendingBattleStart = false
			pushEvent("battle_end", {})
		end
		if pendingBattleStart and battleHandler:inBattleAndFetched() then
			local isWild = battleHandler:isWildBattle()
			pushEvent("battle_start", {
				wild = isWild,
				trainer_id = (not isWild) and getEnemyTrainerID() or nil,
			})
			pendingBattleStart = false
		end
		wasInBattle = inBattle
	end

	-- Only ever exposes what the tracker has already legitimately revealed for this
	-- species (amount seen, abilities/moves observed in battle). Fires once per wild
	-- encounter, right after the enemy mon's data is first readable.
	-- The tracker stores revealed abilities as a { [abilityId] = true } map (numeric
	-- keys, no [1]). The JSON encoder rejects such tables ("mixed or invalid key types"),
	-- and since events live in a rolling buffer, one such event would freeze the whole
	-- live feed permanently. Flatten it to a plain list of ability ids before sending.
	local function abilityIdList(map)
		local out = {}
		for abilityId in pairs(map or {}) do
			out[#out + 1] = abilityId
		end
		return out
	end

	local function detectWildEncounter(enemy)
		if wildEncounterLoggedForBattle or not battleHandler:isWildBattle() or enemy == nil then
			return
		end
		wildEncounterLoggedForBattle = true
		pushEvent("wild_encounter", {
			pokemon_id = enemy.pokemonID,
			level = enemy.level,
			amount_seen = tracker.getAmountSeen(enemy.pokemonID),
			known_abilities = abilityIdList(tracker.getAbilities(enemy.pokemonID)),
			known_moves = tracker.getMoves(enemy.pokemonID),
		})
	end

	-- Per-side diffs for moves used (PP drop, same technique as BattleHandlerBase's
	-- checkEnemyPP) and status gained. Re-baselines both on PID change so a switch-in's
	-- full PP / clear status is never read as a change.
	local function detectSideChanges(sideKey, side, active)
		if active == nil then
			return
		end
		if side.pid ~= active.pid then
			side.pid = active.pid
			side.pp = { active.movePPs[1], active.movePPs[2], active.movePPs[3], active.movePPs[4] }
			side.status = active.status or 0
			return
		end
		for i = 1, 4 do
			local current = active.movePPs[i]
			local previous = side.pp[i]
			if current ~= nil and previous ~= nil and current < previous then
				pushEvent("move_used", {
					is_enemy = (sideKey == "enemy"),
					pokemon_id = active.pokemonID,
					move_id = active.moveIDs[i],
				})
			end
			side.pp[i] = current
		end
		-- Status: only on a clear -> afflicted transition. enemy afflicted = the player
		-- inflicted it (status_inflicted); player afflicted = status_received.
		local current = active.status or 0
		if current ~= side.status then
			local key = decodeStatus(current)
			if key ~= nil and decodeStatus(side.status) == nil then
				pushEvent(sideKey == "enemy" and "status_inflicted" or "status_received", {
					pokemon_id = active.pokemonID,
					status = key,
				})
			end
			side.status = current
		end
	end

	-- Enemy HP reaching 0 = a kill (the player's own faints are already covered by the
	-- normal .pastlog death flow).
	local function detectPokemonDefeated(side, active)
		if active == nil or active.curHP == nil then
			return
		end
		if active.curHP <= 0 then
			if not side.fainted then
				side.fainted = true
				pushEvent("pokemon_defeated", { pokemon_id = active.pokemonID })
			end
		else
			side.fainted = false
		end
	end

	-- program.getPlayerPokemon() reflects the current party leader continuously, both
	-- in and out of battle (Program.lua's readMemory() keeps it fresh every ~0.5s).
	local function detectLeadChange()
		local lead = program.getPlayerPokemon()
		if lead == nil or lead.pokemonID == nil or lead.pokemonID == 0 then
			return
		end
		if lastLead.pid == nil then
			-- First valid lead of this attempt = the starter. Tagged distinctly from a
			-- later pivot so the UI can badge it "Starter".
			pushEvent(starterLogged and "pivot" or "starter", {
				location = program.getCurrentLocation(),
				pokemon_id = lead.pokemonID,
				level = lead.level,
			})
			starterLogged = true
			lastLead.pid = lead.pid
			lastLead.pokemonID = lead.pokemonID
			lastLead.level = lead.level
			return
		end
		if lead.pid ~= lastLead.pid then
			pushEvent("pivot", {
				location = program.getCurrentLocation(),
				pokemon_id = lead.pokemonID,
				level = lead.level,
			})
			lastLead.pid = lead.pid
			lastLead.pokemonID = lead.pokemonID
			lastLead.level = lead.level
		elseif lead.pokemonID ~= lastLead.pokemonID then
			pushEvent("evolution", {
				location = program.getCurrentLocation(),
				from_pokemon_id = lastLead.pokemonID,
				to_pokemon_id = lead.pokemonID,
				level = lead.level,
			})
			lastLead.pokemonID = lead.pokemonID
			lastLead.level = lead.level
		elseif lead.level ~= nil and lastLead.level ~= nil and lead.level > lastLead.level then
			-- Same individual, higher level.
			pushEvent("level_up", {
				pokemon_id = lead.pokemonID,
				from_level = lastLead.level,
				to_level = lead.level,
			})
			lastLead.level = lead.level
		end
	end

	-- Badge total (Johto + Kanto) increasing = a badge obtained. getBadges() returns
	-- { firstSet = {…}, secondSet = {…} } of 0/1 flags; readBadgeMemory refreshes it.
	local function detectBadges()
		local ok, badges = pcall(program.getBadges)
		if not ok or type(badges) ~= "table" then
			return
		end
		lastBadges = badges
		local count = 0
		for _, set in pairs(badges) do
			if type(set) == "table" then
				for _, v in pairs(set) do
					if (v or 0) > 0 then
						count = count + 1
					end
				end
			end
		end
		if lastBadgeCount == nil then
			lastBadgeCount = count
			return
		end
		if count > lastBadgeCount then
			pushEvent("badge_obtained", { count = count })
		end
		lastBadgeCount = count
	end

	-- The card for the current party leader: only dynamic, individual-specific data
	-- the game already computes for display. Species name/move/ability details are
	-- resolved server-side from static tables.
	local function buildCard()
		local lead = nil
		if battleHandler:inBattleAndFetched() then
			lead = battleHandler:getActivePokemonInBattle(program.SELECTED_PLAYERS.PLAYER)
		end
		if lead == nil then
			lead = program.getPlayerPokemon()
		end
		if lead == nil or lead.pokemonID == nil or lead.pokemonID == 0 then
			return nil
		end
		local statMarksOk, statMarks = pcall(tracker.getStatPredictions, lead.pokemonID)
		return {
			pokemon_id = lead.pokemonID,
			level = lead.level,
			cur_hp = lead.curHP,
			stats = lead.stats,
			ability_id = lead.ability,
			nature = lead.nature,
			moves = {
				{ id = lead.moveIDs[1], pp = lead.movePPs[1] },
				{ id = lead.moveIDs[2], pp = lead.movePPs[2] },
				{ id = lead.moveIDs[3], pp = lead.movePPs[3] },
				{ id = lead.moveIDs[4], pp = lead.movePPs[4] },
			},
			stat_marks = statMarksOk and statMarks or {},
		}
	end

	-- Flattens a {itemId = quantity} map (from the tracker's bag scan) into a list of
	-- {id, qty}; names are resolved server-side from the items table.
	local function itemList(getter)
		local out = {}
		local ok, items = pcall(getter)
		if ok and type(items) == "table" then
			for id, qty in pairs(items) do
				if (qty or 0) > 0 then
					table.insert(out, { id = id, qty = qty })
				end
			end
		end
		return out
	end

	-- The whole live (overwrite, not historised) snapshot: leader card + run context
	-- (location, total healing/status available, the heal/status item lists). All of
	-- this is the player's own already-visible state, no spoiler concern.
	-- Turns the {itemId = qty} bag map into a {id, qty} list for transport.
	local function bagList()
		local out = {}
		for id, qty in pairs(currentBag) do
			if (qty or 0) > 0 then
				table.insert(out, { id = id, qty = qty })
			end
		end
		return out
	end

	local function buildStateSnapshot()
		local healingOk, healing = pcall(program.getHealingTotals)
		local statusOk, statusTotal = pcall(program.getStatusTotals)
		local tmOk, tmMoves = pcall(program.getTMHMMoves)
		currentState = {
			lead = buildCard(),
			location = program.getCurrentLocation(),
			heals = (healingOk and healing) or nil, -- { healing = "X%"|"X PV", numHeals = N }
			status_total = (statusOk and statusTotal) or 0,
			heal_items = itemList(program.getHealingItems),
			status_items = itemList(program.getStatusItems),
			bag = bagList(),
			-- 100 move ids (TM01..HM08) read live from the game, so the app can show each
			-- TM's randomised move + colour its icon by type. Read-only, never the seed log.
			tm_moves = (tmOk and tmMoves) or nil,
			badges = lastBadges, -- { firstSet = {0/1 x8}, secondSet = {0/1 x8}|nil }, refreshed by detectBadges()
		}
	end

	local function detectBattleProgress()
		if not battleHandler:inBattleAndFetched() then
			return
		end
		local player = battleHandler:getActivePokemonInBattle(program.SELECTED_PLAYERS.PLAYER)
		local enemy = battleHandler:getActivePokemonInBattle(program.SELECTED_PLAYERS.ENEMY)

		detectWildEncounter(enemy)
		detectSideChanges("player", sides.player, player)
		detectSideChanges("enemy", sides.enemy, enemy)
		detectPokemonDefeated(sides.enemy, enemy)
	end

	-- Diffs the full bag between polls: a quantity going up is a pickup (item_received),
	-- going down is a use (item_used). The first scan of an attempt is just a baseline
	-- (starting items aren't "received"). Covers the non-rare pockets the tracker
	-- scans (main items + berries), which is exactly what we want stats on.
	local function detectItemChanges()
		-- Don't scan before a starter exists (title screen): the bag memory isn't
		-- meaningful yet and could baseline on garbage / report the starting bag as
		-- "received". Once the lead is valid, the first scan is the baseline.
		local lead = program.getPlayerPokemon()
		if lead == nil or lead.pokemonID == nil or lead.pokemonID == 0 then
			return
		end
		local ok, bag = pcall(program.getAllBagItems)
		if not ok or type(bag) ~= "table" then
			return
		end
		currentBag = bag
		if knownBag == nil then
			knownBag = bag
			return
		end
		for id, qty in pairs(bag) do
			local prev = knownBag[id] or 0
			if qty > prev then
				pushEvent("item_received", { item_id = id, qty = qty - prev })
			elseif qty < prev then
				pushEvent("item_used", { item_id = id, qty = prev - qty })
			end
		end
		-- Items that vanished entirely (last one used) won't appear in the loop above.
		for id, prev in pairs(knownBag) do
			if (bag[id] or 0) == 0 and prev > 0 then
				pushEvent("item_used", { item_id = id, qty = prev })
			end
		end
		knownBag = bag
	end

	local function detectDefeatedTrainers()
		for trainerID, _ in pairs(battleHandler:getDefeatedTrainers() or {}) do
			-- trainer id 0 = a wild battle (enemyTrainerID is 0 for wilds): the tracker
			-- adds it to the defeated list too, but it's not a real trainer -- skip it,
			-- otherwise every wild fight produces a bogus "trainer #0 defeated".
			if trainerID ~= 0 and not knownDefeatedTrainers[trainerID] then
				knownDefeatedTrainers[trainerID] = true
				pushEvent("trainer_defeated", { trainer_id = trainerID })
			end
		end
	end

	local function buildSnapshot()
		return {
			game = gameInfo.NAME,
			-- seed = the run's identity (changes only on a real reset / new ROM). The
			-- consumer keys the run off this, so reloading the script on the SAME seed
			-- continues the same run instead of spawning a new one.
			seed = gameinfo.getromhash(),
			-- session = this addon instance; only used to know the seq counter
			-- restarted (so the consumer re-reads the buffer from 0 after a reload).
			session = sessionToken,
			events = recentEvents,
			state = currentState,
			-- run_ended flips true once the tracker has logged the death/win (the
			-- .pastlog is already written by then, see Program.onRunEnded), so a
			-- false->true transition is LiveConnect's cue to send the .pastlog.
			run_ended = tracker.hasRunEnded(),
		}
	end

	-- Always rewrites the file with the full rolling buffer + current lead, never
	-- clearing events: the bridge is responsible for deduping by `seq`. This is what
	-- makes delivery resilient to the addon flushing faster than the bridge reads.
	local function flush()
		NetworkUtils.encodeToJsonFile(OUTPUT_FILE, buildSnapshot())
	end

	-- In-memory version of the flush payload, for LiveConnect (direct tracker->app
	-- transport, no intermediate file/bridge). Returns nil rather than throwing.
	function self.getSnapshot()
		local ok, snapshot = pcall(buildSnapshot)
		if ok then
			return snapshot
		end
		return nil
	end

	-- End-of-run file readers for LiveConnect (A3). These are the same files the Node
	-- bridge used to watch; the addon reads them directly since it knows the game name
	-- (gameInfo.NAME) and ROM name. All return nil on any failure -- LiveConnect treats
	-- a missing file as "nothing to send" and retries next tick.

	-- The randomizer .nds.log sits next to the ROM (tracker root) and matches the
	-- CURRENT seed only, so LiveConnect sends it at attempt start.
	--
	-- We find it by scanning the tracker root for the NEWEST *.nds.log, exactly like
	-- the old Node bridge did -- name-agnostic on purpose: the ROM's filename comes
	-- from the QuickLoad settings name (<settings>_Auto_Randomized), NOT from
	-- gameinfo.getromname() (which returns the ROM's internal title, e.g. "POKEMON PL")
	-- -- so building the log name from getromname() was wrong and always missed.
	-- Scanned once per attempt then cached (beginAttempt clears it): the .nds.log is
	-- written by the randomizer before the ROM loads, so it exists by first read.
	--
	-- Throttled to one scan attempt every SEED_LOG_SCAN_INTERVAL_SECONDS, capped at
	-- MAX_SEED_LOG_SCAN_ATTEMPTS per attempt: os.execute spawns a shell (dir/ls), which
	-- briefly flashes a console window since EmuHawk has none of its own. LiveConnect
	-- calls this every tick until the seed log is found AND confirmed linked server-side
	-- -- if no .nds.log ever shows up (randomizer not used yet, or the file lives
	-- elsewhere), that's an indefinite retry for the rest of the attempt without a cap.
	-- Giving up after a few tries is safe: LiveConnect still attaches the seed log to the
	-- death/import payload as a fallback if it's found by then (see LiveConnect.lua).
	local SEED_LOG_SCAN_INTERVAL_SECONDS = 10
	local MAX_SEED_LOG_SCAN_ATTEMPTS = 6 -- ~1 minute of retries at the interval above
	function self.getSeedLog()
		if seedLogCache ~= nil then
			return seedLogCache
		end
		if seedLogScanAttempts >= MAX_SEED_LOG_SCAN_ATTEMPTS then
			return nil
		end
		if os.time() - lastSeedLogScanAt < SEED_LOG_SCAN_INTERVAL_SECONDS then
			return nil
		end
		seedLogScanAttempts = seedLogScanAttempts + 1
		lastSeedLogScanAt = os.time()
		local ok, content = pcall(function()
			-- List *.nds.log newest-first into a temp file, then read the first
			-- non-backup entry. os.execute runs in the tracker root (same cwd where
			-- every relative read here works).
			local scanFile = "savedData" .. Paths.SLASH .. "liveconnect_logscan.txt"
			local cmd
			if Paths.SLASH == "\\" then
				cmd = 'dir /b /o-d "*.nds.log" > "' .. scanFile .. '" 2>nul'
			else
				cmd = 'ls -t *.nds.log > "' .. scanFile .. '" 2>/dev/null'
			end
			os.execute(cmd)
			local lines = MiscUtils.readLinesFromFile(scanFile)
			if lines == nil then
				return nil
			end
			for _, name in ipairs(lines) do
				name = name:gsub("%s+$", "")
				-- Skip the *_backup.nds.log copy the tracker keeps of the PREVIOUS seed.
				if name ~= "" and not name:find("_backup%.nds%.log$") then
					local result = MiscUtils.readStringFromFile(name)
					if result ~= nil and result ~= "" then
						print(string.format("[LiveTracker] seed log: jeu=%s, fichier=%s, taille=%d",
							tostring(gameInfo.NAME), name, #result))
						return result
					end
				end
			end
			return nil
		end)
		if ok and content ~= nil and content ~= "" then
			seedLogCache = content -- freeze for the rest of the attempt
			return content
		end
		return nil
	end

	-- The .pastlog (run history) is written by the tracker before run_ended flips true.
	function self.getPastlog()
		local ok, content = pcall(function()
			return MiscUtils.readStringFromFile("savedData" .. Paths.SLASH .. gameInfo.NAME .. ".pastlog")
		end)
		return ok and content or nil
	end

	-- The .statistics (aggregated tracker stats) file, sent on death alongside the
	-- .pastlog. Absent until the tracker has written stats at least once.
	function self.getStatistics()
		local ok, content = pcall(function()
			return MiscUtils.readStringFromFile("savedData" .. Paths.SLASH .. gameInfo.NAME .. ".statistics")
		end)
		return ok and content or nil
	end

	-- Attempt count incl. resets, straight from the tracker (no file parsing).
	function self.getAttempts()
		local ok, attempts = pcall(function()
			if QuickLoader ~= nil and QuickLoader.getAttempts ~= nil then
				return QuickLoader.getAttempts()
			end
			return nil
		end)
		if ok and type(attempts) == "number" then
			return attempts
		end
		return nil
	end

	-- Detection runs on its own short cadence (see Program.lua), separate from the
	-- disk flush, so a short wild battle can't start and end entirely between samples.
	-- (Polling faster than this wouldn't help battle-transition timing: the tracker's
	-- own core loop only refreshes _inBattle every 30 frames -- Program.lua's
	-- readMemory FrameCounter -- so this addon can never observe a finer-grained
	-- transition than that regardless of its own poll rate.)
	local function pollOnce()
		if not sessionStarted then
			sessionStarted = true
			beginAttempt()
		end
		detectRomHashChange()
		-- Once the run is over (death/win), stop sampling so the post-battle whiteout
		-- flicker doesn't log noise; anything already queued still gets flushed.
		if not tracker.hasRunEnded() then
			detectBattleTransitions()
			detectDefeatedTrainers()
			detectBattleProgress()
			detectLeadChange()
			detectBadges()
			detectItemChanges()
			buildStateSnapshot()
		end
	end

	-- Called on FrameCounters; must never throw past this boundary, an addon crashing
	-- would otherwise take down the whole tracker.
	function self.poll()
		local success, err = pcall(pollOnce)
		if not success and not hasWarnedPoll then
			hasWarnedPoll = true
			print("[LiveTracker] poll disabled after an error: " .. tostring(err))
		end
	end

	function self.flush()
		local success, err = pcall(flush)
		if not success and not hasWarnedFlush then
			hasWarnedFlush = true
			print("[LiveTracker] flush disabled after an error: " .. tostring(err))
		end
	end

	return self
end

return LiveTracker
