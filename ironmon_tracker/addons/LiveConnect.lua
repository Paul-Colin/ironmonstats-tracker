-- LiveConnect addon
--
-- Connexion directe tracker -> application IronMonStats (Laravel), sans process
-- externe a lancer a cote (remplace le bridge Node). Les requetes HTTP partent via
-- curl demarre en arriere-plan (fenetre cachee, jamais bloquant pour l'emulateur) ;
-- la reponse est ecrite dans un fichier de savedData relu aux ticks suivants.
--
-- Pourquoi pas le HTTP natif de BizHawk (comm.http*) : il est synchrone (bloque la
-- frame) et CRASH de maniere non rattrapable si BizHawk n'est pas lance avec des
-- arguments CLI dedies -- l'upstream l'a desactive pour ces raisons (cf. Network.lua).
-- curl est present sur Windows 10+ et deja utilise par TrackerUpdater.lua.
--
-- Lot A1 : configuration (URL + token colles dans l'ecran LiveConnectScreen, persistes
-- dans savedData/LiveConnect.ini) + test de connexion asynchrone sur /api/ping.
-- Lot A2 : envoi du flux live sans bridge. LiveTracker reste le producteur (buffer
-- roulant d'events tagges `seq` + snapshot d'etat) ; LiveConnect consomme son
-- getSnapshot() en memoire et reprend la logique du bridge :
--   * seed inconnu  -> POST /api/runs/live/start (nouvelle tentative), puis rien
--     d'autre tant que le start n'est pas acquitte (l'ordre compte) ;
--   * events frais (seq > curseur, hors session_start) -> POST /api/runs/live/events,
--     curseur avance uniquement sur acquittement (at-least-once, le serveur est
--     idempotent sur starter/dresseurs) ;
--   * snapshot d'etat -> POST /api/runs/live/lead, throttle, independant des events.
-- Le seed acquitte est persiste (liveconnect_state.json) : recharger le script sur le
-- MEME seed reprend la run en cours au lieu d'en creer une nouvelle (le serveur
-- rattache les events a la run in_progress) -- ce que le bridge ne savait pas faire.
--
-- Lot A3 : parite complete avec le bridge (plus aucun process externe).
--   * seed log (.nds.log) : POST /runs/live/seed-log apres le start, RE-ESSAYE tant
--     que le serveur n'a pas confirme le lien (linked) ou signale qu'il n'y a plus de
--     run live (no_run). Decouple du start : un seed log se lie meme si l'app etait
--     down au demarrage de la tentative -- ce que la livraison one-shot ne faisait pas.
--   * a la mort (run_ended false->true) : POST /runs/import du .pastlog + attempts
--     (le serveur "reclame" la run in_progress au lieu de dupliquer) puis, en plus du
--     bridge, POST /runs/statistics du fichier .statistics (stats agregees du tracker).
--   Chaque envoi de mort est one-shot par seed, avec retry si echec.

LiveConnect = {
	Options = {
		Enabled = false,
		AppUrl = "",
		Token = "",
	},
	-- "idle" | "testing" | "ok" | "error"
	PingState = "idle",
	-- Nom d'utilisateur renvoye par /api/ping au dernier test reussi.
	ConnectedUser = nil,
	LastError = nil,
}

local FILE_SETTINGS = "savedData" .. Paths.SLASH .. "LiveConnect.ini"
local FILE_STATE = "savedData" .. Paths.SLASH .. "liveconnect_state.json"
local PING_TIMEOUT_SECONDS = 15
local REQUEST_TIMEOUT_SECONDS = 25
local LEAD_MIN_INTERVAL_SECONDS = 2

-- Nom de jeu du tracker (GameInfo.NAME) -> slug attendu par l'API (meme table que
-- le bridge). Un jeu absent d'ici n'est simplement pas envoye.
local GAME_SLUGS = {
	["pokemon heartgold"] = "hgss",
	["pokemon soulsilver"] = "hgss",
	["pokemon platinum"] = "platinum",
	["pokemon diamond"] = "platinum",
	["pokemon pearl"] = "platinum",
	["pokemon black"] = "bw",
	["pokemon white"] = "bw",
	["pokemon black 2"] = "bw2",
	["pokemon white 2"] = "bw2",
}

local iniParser = dofile(Paths.FOLDERS.DATA_FOLDER .. Paths.SLASH .. "Inifile.lua")

local programRef = nil
local liveTrackerRef = nil
local pendingPing = nil -- { startedAt = os.time() } quand un test est en cours
local lastStatusText = nil

-- Etat du flux live (lot A2/A3).
local ackedSeed = nil -- seed dont le /live/start a ete acquitte (persiste)
local eventCursor = 0 -- dernier seq acquitte par /live/events
local lastLeadSentAt = 0
local deathSentForSeed = nil -- seed dont la mort (.pastlog) a ete envoyee (persiste)
local seedLogLinkedForSeed = nil -- seed dont le seed log est confirme lie (persiste)
local inflight = {} -- kind ("start"|"seedlog"|"events"|"lead"|"import"|"stats") -> { startedAt, meta }
local lastLoggedError = nil -- anti-spam console

-- Les fichiers lus/ecrits par le Lua du tracker sont relatifs au dossier du script,
-- mais un process enfant (curl) herite du cwd d'EmuHawk qui peut etre ailleurs :
-- toujours donner des chemins absolus a curl.
local function absolutePath(relativePath)
	if Paths.CURRENT_DIRECTORY ~= nil and Paths.CURRENT_DIRECTORY ~= "" then
		return Paths.CURRENT_DIRECTORY .. Paths.SLASH .. relativePath
	end
	return relativePath
end

local function requestFile(kind)
	return "savedData" .. Paths.SLASH .. "liveconnect_req_" .. kind .. ".json"
end

local function responseFile(kind)
	return "savedData" .. Paths.SLASH .. "liveconnect_res_" .. kind .. ".json"
end

local function logOnce(message)
	if message ~= lastLoggedError then
		lastLoggedError = message
		print("[LiveConnect] " .. message)
	end
end

--- Demarre un process en arriere-plan sans fenetre et sans attendre sa fin, via
--- System.Diagnostics.Process (luanet). Pas de repli sur os.execute : ce dernier
--- passe par cmd.exe, qui doit ouvrir une console pour un process hote sans
--- console (EmuHawk) -- invoque plusieurs fois par seconde par LiveConnect.update(),
--- ca s'est traduit chez un utilisateur par des dizaines de fenetres ouvertes/
--- fermees par seconde et un PC au bord du gel. Si luanet echoue, on logue le
--- detail de l'erreur (diagnostic) et on renonce a la requete plutot que spammer.
local function startBackgroundProcess(fileName, arguments)
	local ok, err = pcall(function()
		if luanet == nil then
			error("luanet unavailable")
		end
		pcall(function() luanet.load_assembly("System") end)
		local ProcessStartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
		local Process = luanet.import_type("System.Diagnostics.Process")
		if ProcessStartInfo == nil or Process == nil then
			error("System.Diagnostics unavailable")
		end
		local startInfo = ProcessStartInfo()
		startInfo.FileName = fileName
		startInfo.Arguments = arguments
		startInfo.UseShellExecute = false
		startInfo.CreateNoWindow = true
		Process.Start(startInfo)
	end)
	if ok then
		return true
	end
	logOnce("lancement process arriere-plan impossible : " .. tostring(err))
	return false
end

local function normalizedAppUrl()
	local url = LiveConnect.Options.AppUrl or ""
	return (url:gsub("/+$", ""))
end

function LiveConnect.isConfigured()
	return normalizedAppUrl() ~= "" and (LiveConnect.Options.Token or "") ~= ""
end

--- Envoie un POST JSON asynchrone vers l'API. La reponse sera ramassee par
--- pollInflightRequests() ; au plus une requete en vol par `kind`.
---@return boolean started
local function sendRequest(kind, apiPath, payload, meta)
	if inflight[kind] ~= nil then
		return false
	end
	local reqPath = absolutePath(requestFile(kind))
	local resPath = absolutePath(responseFile(kind))
	os.remove(resPath)
	local written = NetworkUtils.encodeToJsonFile(reqPath, payload)
	if written ~= true then
		logOnce("impossible d'encoder le payload " .. kind)
		return false
	end
	local arguments = string.format(
		'-s -m 15 --ssl-no-revoke -X POST -H "Authorization: Bearer %s" -H "Accept: application/json" -H "Content-Type: application/json" --data-binary "@%s" -o "%s" "%s%s"',
		LiveConnect.Options.Token,
		reqPath,
		resPath,
		normalizedAppUrl(),
		apiPath
	)
	if not startBackgroundProcess("curl", arguments) then
		return false
	end
	inflight[kind] = { startedAt = os.time(), meta = meta or {} }
	return true
end

local function saveLiveState()
	NetworkUtils.encodeToJsonFile(absolutePath(FILE_STATE), {
		seed = ackedSeed,
		deathSeed = deathSentForSeed,
		seedLogSeed = seedLogLinkedForSeed,
	})
end

local function loadLiveState()
	local data = NetworkUtils.decodeJsonFile(absolutePath(FILE_STATE))
	if type(data) == "table" then
		if type(data.seed) == "string" and data.seed ~= "" then
			ackedSeed = data.seed
		end
		if type(data.deathSeed) == "string" and data.deathSeed ~= "" then
			deathSentForSeed = data.deathSeed
		end
		if type(data.seedLogSeed) == "string" and data.seedLogSeed ~= "" then
			seedLogLinkedForSeed = data.seedLogSeed
		end
	end
end

--- Lance un test de connexion asynchrone (GET /api/ping). Le resultat est ramasse
--- par LiveConnect.update() quelques frames plus tard.
function LiveConnect.requestPing()
	if not LiveConnect.isConfigured() then
		LiveConnect.PingState = "error"
		LiveConnect.LastError = "URL et token requis"
		return
	end
	local resPath = absolutePath(responseFile("ping"))
	os.remove(resPath)
	local arguments = string.format(
		'-s -m 10 --ssl-no-revoke -H "Authorization: Bearer %s" -H "Accept: application/json" -o "%s" "%s/api/ping"',
		LiveConnect.Options.Token,
		resPath,
		normalizedAppUrl()
	)
	if startBackgroundProcess("curl", arguments) then
		LiveConnect.PingState = "testing"
		LiveConnect.LastError = nil
		pendingPing = { startedAt = os.time() }
	else
		LiveConnect.PingState = "error"
		LiveConnect.LastError = "impossible de lancer curl"
	end
end

--- Ramasse la reponse d'un ping en attente.
local function pollPendingPing()
	if pendingPing == nil then
		return
	end
	local data = NetworkUtils.decodeJsonFile(absolutePath(responseFile("ping")))
	if type(data) == "table" and data.user ~= nil then
		LiveConnect.PingState = "ok"
		LiveConnect.ConnectedUser = tostring(data.user)
		LiveConnect.LastError = nil
		pendingPing = nil
	elseif type(data) == "table" and data.message ~= nil then
		LiveConnect.PingState = "error"
		LiveConnect.LastError = "acces refuse (token invalide/revoque ?)"
		pendingPing = nil
	elseif os.time() - pendingPing.startedAt > PING_TIMEOUT_SECONDS then
		LiveConnect.PingState = "error"
		LiveConnect.LastError = "pas de reponse (URL ? app lancee ?)"
		pendingPing = nil
	end
end

--- Ramasse les reponses des requetes live en vol. Le curseur/l'etat n'avancent que
--- sur un acquittement explicite (ok == true) ; un echec libere simplement le slot,
--- le prochain tick recomposera et renverra les memes donnees (at-least-once).
local function pollInflightRequests()
	for kind, request in pairs(inflight) do
		local data = NetworkUtils.decodeJsonFile(absolutePath(responseFile(kind)))
		local finished = false
		if type(data) == "table" and data.ok == true then
			finished = true
			if kind == "start" then
				ackedSeed = request.meta.seed
				eventCursor = 0
				saveLiveState()
				print("[LiveConnect] nouvelle tentative envoyee (" .. tostring(request.meta.gameSlug) .. ").")
			elseif kind == "seedlog" then
				-- linked = lie ; no_run = plus de run live (mort) : dans les deux cas on
				-- arrete d'insister pour ce seed.
				if data.linked == true or data.no_run == true then
					seedLogLinkedForSeed = request.meta.seed
					saveLiveState()
					if data.linked == true then
						print("[LiveConnect] seed log envoye et lie a la run.")
					end
				end
			elseif kind == "events" then
				if request.meta.maxSeq ~= nil and request.meta.maxSeq > eventCursor then
					eventCursor = request.meta.maxSeq
				end
			elseif kind == "import" then
				deathSentForSeed = request.meta.seed
				-- Le seed log a pu etre rattache par l'import (filet de securite).
				if data.seed_logged == true then
					seedLogLinkedForSeed = request.meta.seed
				end
				saveLiveState()
				print("[LiveConnect] run terminee envoyee (.pastlog).")
			end
			lastLoggedError = nil
		elseif type(data) == "table" and data.message ~= nil then
			finished = true
			logOnce("refus " .. kind .. " : " .. tostring(data.message))
		elseif os.time() - request.startedAt > REQUEST_TIMEOUT_SECONDS then
			finished = true
			logOnce("pas de reponse pour " .. kind .. " (on retentera)")
		end
		if finished then
			inflight[kind] = nil
		end
	end
end

--- Coeur du lot A2 : compare le snapshot LiveTracker a l'etat acquitte et envoie ce
--- qui manque, dans le bon ordre (start d'abord, puis events/lead en parallele).
local function pushLiveData()
	if not LiveConnect.Options.Enabled or not LiveConnect.isConfigured() or liveTrackerRef == nil then
		return
	end
	local snapshot = liveTrackerRef.getSnapshot()
	if snapshot == nil or snapshot.seed == nil or snapshot.seed == "" then
		return
	end
	local gameSlug = GAME_SLUGS[tostring(snapshot.game or ""):lower()]
	if gameSlug == nil then
		return -- jeu non supporte par l'app
	end

	-- Nouveau seed = nouvelle tentative : on declare le start (creation de la run) et on
	-- attend son acquittement avant d'envoyer quoi que ce soit d'autre pour ce seed. Le
	-- seed log est envoye separement ci-dessous (endpoint dedie, re-essayable) une fois
	-- la run creee -- plus fiable que de le coller au start (one-shot, perdu si l'app
	-- etait down au demarrage de la tentative).
	if snapshot.seed ~= ackedSeed then
		sendRequest("start", "/api/runs/live/start", { game = gameSlug }, { seed = snapshot.seed, gameSlug = gameSlug })
		return
	end

	-- Seed log (.nds.log) : lie a la run in_progress, re-essaye tant que non confirme.
	-- On s'arrete des que le serveur confirme (linked) ou dit qu'il n'y a plus de run
	-- live (no_run) -- inutile d'insister apres la mort.
	if seedLogLinkedForSeed ~= ackedSeed then
		local seedLog = liveTrackerRef.getSeedLog()
		if seedLog ~= nil and seedLog ~= "" then
			sendRequest("seedlog", "/api/runs/live/seed-log", {
				game = gameSlug,
				seed_log = seedLog,
			}, { seed = ackedSeed })
		end
	end

	-- Events frais : tout seq au-dela du curseur, sauf session_start (implicite dans
	-- le start ci-dessus). S'il n'y a rien a envoyer, on avance quand meme le curseur
	-- au-dela des session_start pour ne pas les re-examiner a chaque tick.
	local fresh = {}
	local maxSeq = eventCursor
	for _, event in ipairs(snapshot.events or {}) do
		if event.seq ~= nil and event.seq > maxSeq then
			maxSeq = event.seq
		end
		if event.seq ~= nil and event.seq > eventCursor and event.type ~= "session_start" then
			table.insert(fresh, event)
		end
	end
	if #fresh > 0 then
		sendRequest("events", "/api/runs/live/events", { game = gameSlug, events = fresh }, { maxSeq = maxSeq })
	else
		eventCursor = maxSeq
	end

	-- Snapshot d'etat (lead) : independant des events, throttle, on ecrase cote
	-- serveur donc seule la derniere version compte.
	if snapshot.state ~= nil and os.time() - lastLeadSentAt >= LEAD_MIN_INTERVAL_SECONDS then
		if sendRequest("lead", "/api/runs/live/lead", { game = gameSlug, state = snapshot.state }) then
			lastLeadSentAt = os.time()
		end
	end

	-- Mort/victoire : run_ended vient de passer a true et on n'a pas encore envoye la
	-- mort pour ce seed. Le .pastlog est deja ecrit a ce stade (cf. Program.onRunEnded)
	-- -> POST /runs/import (le serveur reclame la run in_progress) + POST /runs/
	-- statistics du .statistics. One-shot par seed, retente tant que non acquitte.
	if snapshot.run_ended and deathSentForSeed ~= ackedSeed then
		local pastlog = liveTrackerRef.getPastlog()
		if pastlog ~= nil and pastlog ~= "" then
			local payload = {
				game = gameSlug,
				content = pastlog,
				attempts = liveTrackerRef.getAttempts(),
				-- Cumulative playtime for this game (.pt), sent once on death for the
				-- trainer card. nil (file absent) simply omits the key -> the API treats
				-- play_seconds as optional. Absolute total, the server overwrites.
				play_seconds = liveTrackerRef.getPlaytime(),
			}
			-- Filet de securite : si le seed log n'a pas ete confirme lie pendant la run
			-- (endpoint dedie), on le joint ici. L'import "reclame" la run live comme
			-- newRun, donc le rattache. Sinon on ne renvoie pas 1.5 Mo pour rien.
			if seedLogLinkedForSeed ~= ackedSeed then
				payload.seed_log = liveTrackerRef.getSeedLog()
			end
			sendRequest("import", "/api/runs/import", payload, { seed = ackedSeed })
		end
		local statistics = liveTrackerRef.getStatistics()
		if statistics ~= nil and statistics ~= "" then
			sendRequest("stats", "/api/runs/statistics", { game = gameSlug, content = statistics })
		end
	end
end

--- Pousse la liste complete des favoris (Pokemon) pour un jeu. Appele directement par
--- TitleScreen.lua a chaque changement (action utilisateur explicite), independamment
--- de pushLiveData/du seed : les favoris se modifient depuis l'ecran titre, hors run.
function LiveConnect.sendFavorites(gameName, favoritesList)
	if not LiveConnect.Options.Enabled or not LiveConnect.isConfigured() then
		return
	end
	local gameSlug = GAME_SLUGS[tostring(gameName or ""):lower()]
	if gameSlug == nil then
		return -- jeu non supporte par l'app
	end
	sendRequest("favorites", "/api/favorites", { game = gameSlug, favorites = favoritesList })
end

---@return string statusText, string colorKey
function LiveConnect.getStatus()
	if LiveConnect.PingState == "testing" then
		return "Test en cours...", "Intermediate text color"
	end
	if LiveConnect.PingState == "ok" then
		local who = LiveConnect.ConnectedUser or "?"
		if not LiveConnect.Options.Enabled then
			return "OK (" .. who .. ") - envoi coupé", "Intermediate text color"
		end
		return "Connecté : " .. who, "Positive text color"
	end
	if LiveConnect.PingState == "error" then
		return "Erreur : " .. (LiveConnect.LastError or "inconnue"), "Negative text color"
	end
	if not LiveConnect.isConfigured() then
		return "Non configuré", "Negative text color"
	end
	if not LiveConnect.Options.Enabled then
		return "Désactivé", "Intermediate text color"
	end
	return "Non testé", "Intermediate text color"
end

function LiveConnect.setAppUrl(url)
	LiveConnect.Options.AppUrl = (url or ""):gsub("%s+", "")
	LiveConnect.PingState = "idle"
	LiveConnect.saveSettings()
end

function LiveConnect.setToken(token)
	LiveConnect.Options.Token = (token or ""):gsub("%s+", "")
	LiveConnect.PingState = "idle"
	LiveConnect.saveSettings()
end

function LiveConnect.toggleEnabled()
	LiveConnect.Options.Enabled = not LiveConnect.Options.Enabled
	LiveConnect.saveSettings()
end

function LiveConnect.loadSettings()
	if not FormsUtils.fileExists(absolutePath(FILE_SETTINGS)) then
		return
	end
	local parsed = nil
	pcall(function()
		parsed = iniParser.parse(absolutePath(FILE_SETTINGS))
	end)
	local section = (parsed or {}).liveconnect or {}
	LiveConnect.Options.AppUrl = tostring(section.AppUrl or "")
	LiveConnect.Options.Token = tostring(section.Token or "")
	LiveConnect.Options.Enabled = (section.Enabled == true or section.Enabled == "true")
end

function LiveConnect.saveSettings()
	pcall(function()
		iniParser.save(absolutePath(FILE_SETTINGS), {
			liveconnect = {
				Enabled = LiveConnect.Options.Enabled,
				AppUrl = LiveConnect.Options.AppUrl,
				Token = LiveConnect.Options.Token,
			},
		})
	end)
end

--- Tick periodique (FrameCounter dans Program.lua, ~2x/seconde). Ne doit jamais
--- jeter : un addon qui crash emporterait le tracker.
function LiveConnect.update()
	pcall(function()
		pollPendingPing()
		pollInflightRequests()
		pushLiveData()
		-- Ne redessine que si le statut affiche a change (l'ecran de config peut etre
		-- ouvert pendant qu'un ping se resout).
		local statusText = LiveConnect.getStatus()
		if statusText ~= lastStatusText then
			lastStatusText = statusText
			if programRef ~= nil then
				programRef.drawCurrentScreens()
			end
		end
	end)
end

--- Branche le producteur de donnees live (appele par Program.lua une fois le
--- LiveTracker de la partie en cours construit).
function LiveConnect.attachLiveTracker(liveTracker)
	liveTrackerRef = liveTracker
end

function LiveConnect.initialize(program)
	programRef = program
	NetworkUtils.setupJsonLibrary()
	LiveConnect.loadSettings()
	loadLiveState()
	lastStatusText = LiveConnect.getStatus()
end

return LiveConnect
