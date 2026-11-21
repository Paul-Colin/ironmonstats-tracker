-- PROTOTYPE « Layout » : fond d'ecran net, bordures, marges et widgets HTML dans la
-- fenetre BizHawk.
--
-- Principe (valide sur BizHawk 2.11.1) :
--   * BizHawk offre a Lua deux surfaces. « emucore » (celle du tracker) est en pixels
--     DS puis agrandie avec le jeu. « client » est en pixels FENETRE, dessinee apres
--     l'agrandissement : tout ce qu'on y met est net, quelle que soit la taille.
--   * La surface client passe AU-DESSUS du jeu et du tracker (BizHawk n'a pas de couche
--     Lua sous le jeu). Le fond y est donc dessine en bandes autour de deux « trous » :
--     les ecrans de jeu et la zone du tracker. Les bordures sont dessinees au meme endroit.
--   * client.SetClientExtraPadding reserve des marges en pixels fenetre autour du jeu.
--     La souris du tracker n'est pas affectee.
--   * Les widgets sont une vraie page web affichee par un WebView2 (moteur Edge) a fond
--     transparent, ajoute comme controle enfant de la fenetre BizHawk via luanet :
--       - si LiveConnect est configure : les widgets d'IronMonStats (/overlay : IV,
--         dresseurs cles, documents du lieu, carte dresseur, liens vers la run). Le
--         token part en en-tete Authorization vers /overlay/connect, qui ouvre une
--         session limitee a l'overlay (pas une connexion au site) ;
--       - sinon : ironmon_tracker/layout/widgets.html, alimentee par Lua via
--         ExecuteScriptAsync("IMS.update({...})").
--     Si WebView2 est indisponible, on retombe sur un panneau texte dessine en Lua.
--   * Les dessins persistent d'une frame a l'autre : on ne redessine que sur changement
--     (taille de fenetre, zone du tracker, reglages) + un rafraichissement de securite.
--
-- Desactive par defaut. Reglages : Extras > Layout dans le tracker, ou savedData/Layout.ini.
-- Limites du prototype : disposition NDS « Natural/Vertical » sans ecart uniquement ;
-- widgets en trois zones fixes (gauche, droite, sous le tracker).

LayoutPrototype = {
	Options = {
		Enabled = false,
		Background = "ironmon_tracker/images/layout/background.jpg",
		MarginLeft = 320,
		MarginTop = 0,
		MarginRight = 0,
		MarginBottom = 0,
		Widgets = true,
		-- Widgets d'IronMonStats par zone, dans l'ordre de WIDGET_CHOICES :
		-- colonne de gauche, et zone sous le tracker (a droite).
		WidgetsLeft = "run,iv,bag,trainers",
		WidgetsRight = "documents", -- colonne a droite du tracker
		WidgetsBottom = "card", -- sous le tracker, jusqu'au bord droit (format paysage)
		-- "left" : quand la fenetre est maximisee, le jeu est colle a la colonne de
		-- gauche (au lieu d'etre centre) pour regrouper toute la place libre a droite.
		GameAlign = "left",
		-- Page affichee a la place des widgets d'IronMonStats (n'importe quelle URL).
		-- Vide = widgets de l'appli si LiveConnect est configure, sinon page locale.
		WidgetUrl = "",
		-- "glass" (translucide, facon carte dresseur) | "light" | "dark" (tokens de l'appli)
		Theme = "glass",
		Accent = "", -- couleur des widgets (hex RRGGBB) ; vide = celle des preferences de l'appli
		Border = true,
		BorderColor = "FFFFFF",
		BorderWidth = 3,
		-- Opacite des fonds du tracker, en % (100 = opaque). En dessous, ses fonds
		-- laissent voir l'image de fond, floutee facon verre depoli.
		TrackerOpacity = 100,
	},
	-- Reference vers Program (ecran de reglages, tests).
	Program = nil,
}

--- Widgets proposes par IronMonStats (cle de l'appli -> libelle dans l'ecran de reglages).
LayoutPrototype.WIDGET_CHOICES = {
	{ key = "run", label = "Lien run" },
	{ key = "iv", label = "Estimation IV" },
	{ key = "bag", label = "Sac" },
	{ key = "trainers", label = "Dresseurs clés" },
	{ key = "documents", label = "Documents" },
	{ key = "card", label = "Carte dresseur" },
}

local FILE_SETTINGS = "savedData" .. Paths.SLASH .. "Layout.ini"
local CACHE_FOLDER = "savedData" .. Paths.SLASH .. "layout_cache"
local WEB_DATA_FOLDER = "savedData" .. Paths.SLASH .. "layout_webview"
local WEB_LIB_FOLDER = "ironmon_tracker" .. Paths.SLASH .. "lib" .. Paths.SLASH .. "webview2"
local WIDGETS_PAGE = "ironmon_tracker" .. Paths.SLASH .. "layout" .. Paths.SLASH .. "widgets.html"
local WEB_CONTROL_NAME = "IronMonLayoutWidgets"
local GAME_WIDTH, GAME_HEIGHT = 256, 384
local MIN_WIDGET_WIDTH = 220
local FORCE_REDRAW_EVERY_UPDATES = 12 -- update() tourne toutes les 10 frames -> ~2 s
local RESIZE_SETTLE_UPDATES = 3 -- attend que la fenetre soit stable avant de regenerer le fond
local FALLBACK_COLOR = 0xFF14182A
local FONT = "Segoe UI"
local ASSEMBLY_DRAWING = "System.Drawing, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a"
local ASSEMBLY_FORMS = "System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
local ASSEMBLY_SYSTEM = "System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"

local iniParser = dofile(Paths.FOLDERS.DATA_FOLDER .. Paths.SLASH .. "Inifile.lua")

local programRef = nil
local settingsRef = nil
local active = false
local gamePadding = { left = 0, top = 0, right = 199, bottom = 0 }
local inTrackerPass = false
local passBounds = nil -- boite englobante des cadres dessines par le tracker pendant la passe
local trackerBounds = { left = GAME_WIDTH, top = 0, right = GAME_WIDTH + 199, bottom = 165 }
local seedLabel = nil -- { text, x, y, size, family } du « Seed N° » du tracker
local passSeedLabel = nil
local appliedSignature = nil
local updatesSinceRedraw = 0
local background = nil -- { path, width, height } de l'image source, ou false si indisponible
local scaledCache = {} -- "LxH" -> chemin du fond pre-redimensionne (ou false si echec)
local stableSize = { key = nil, updates = 0 }
local loggedErrors = {}
-- Zones de widgets (un WebView2 chacune) :
--   « left »   = marge gauche ; « right » = colonne a droite du tracker (toute la
--   hauteur) ; « bottom » = sous le tracker, entre le jeu et la colonne de droite.
local ZONE_ORDER = { "left", "right", "bottom" }
local zones = { left = { name = "left" }, right = { name = "right" }, bottom = { name = "bottom" } }
local ZONE_OPTION = { left = "WidgetsLeft", right = "WidgetsRight", bottom = "WidgetsBottom" }
local webFailed = false
local ZONE_GAP = 14 -- espace entre une zone et le tracker / les bords
local ZONE_INSET = 4 -- la zone du bas deborde un peu a gauche pour s'aligner sur la bordure
-- Plein ecran 1080p : la colonne de droite ne fait qu'environ 270 px de large.
local ZONE_MIN_WIDTH, ZONE_MIN_HEIGHT = MIN_WIDGET_WIDTH, 200
-- Delai max pour que le moteur WebView2 demarre (sinon : runtime absent -> repli).
local WEB_ENGINE_TIMEOUT_SECONDS = 20
-- Marge droite ajoutee pour coller le jeu a gauche (fenetre maximisee) ; par taille de fenetre.
local alignment = { key = nil, extra = 0, settledAt = nil }
-- Ou se trouvent le tracker et son numero de seed (pixels fenetre), mis a jour par redraw.
local layoutGeometry = nil
-- Tracker translucide : le tracker dessine sur la surface emucore, SOUS la surface
-- client du fond. On pose donc sous ses cadres un morceau du fond (flou, a la
-- resolution DS) puis on rend ses aplats de fond translucides.
local TRACKER_OPACITY_MIN = 20
local GLASS_BLUR = 5 -- facteur de reduction du flou (en pixels DS)
local glass = { key = nil, path = nil, x = 0, width = 0, height = 0 }
-- Pendant une passe translucide : { alpha, backgrounds, shadows, content }. `content` =
-- textes et images deja dessines dans la passe : un fond pose par-dessus (ecran
-- d'accueil, infobulle...) reste opaque, sinon on lirait le texte du dessous a travers.
local glassPass = nil

-- Les fonctions gui/client d'origine sont gardees dans un global : si le tracker est
-- recharge sans que le script s'arrete, on ne re-enveloppe pas des enveloppes.
local original = rawget(_G, "__LayoutPrototypeOriginals")
if original == nil then
	original = {
		drawRectangle = gui.drawRectangle,
		drawText = gui.drawText,
		setGamePadding = client.SetGameExtraPadding,
	}
	rawset(_G, "__LayoutPrototypeOriginals", original)
end
if original.drawImage == nil then -- ajoutees avec le tracker translucide
	original.drawImage = gui.drawImage
	original.drawImageRegion = gui.drawImageRegion
end

local function logOnce(message)
	-- NLua termine ses messages d'erreur par un identifiant qui change a chaque fois.
	message = tostring(message):gsub(":%s*%-?%d+%s*$", "")
	if not loggedErrors[message] then
		loggedErrors[message] = true
		print("[Layout] " .. message)
	end
end

local function isAbsolute(path)
	return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\]") ~= nil
end

local function absolutePath(path)
	if isAbsolute(path) then
		return path
	end
	if Paths.CURRENT_DIRECTORY ~= nil and Paths.CURRENT_DIRECTORY ~= "" then
		return Paths.CURRENT_DIRECTORY .. Paths.SLASH .. path
	end
	return path
end

local function fileExists(path)
	local file = io.open(path, "rb")
	if file then
		file:close()
		return true
	end
	return false
end

local function toNumber(value, default)
	local number = tonumber(value)
	if number == nil then
		return default
	end
	return math.max(0, math.floor(number))
end

local function toBoolean(value, default)
	if value == nil then
		return default
	end
	return value == true or value == "true"
end

local function toHexColor(value, default)
	local hex = tostring(value or ""):gsub("#", ""):upper()
	if hex:match("^%x%x%x%x%x%x$") then
		return hex
	end
	return default
end

local function colorFromHex(hex, alpha)
	return (alpha or 0xFF) * 0x1000000 + tonumber(toHexColor(hex, "FFFFFF"), 16)
end

---------------------------------------------------------------------------
-- Reglages
---------------------------------------------------------------------------

function LayoutPrototype.saveSettings()
	pcall(function()
		local section = {}
		for key, value in pairs(LayoutPrototype.Options) do
			section[key] = value
		end
		-- Le lecteur INI du tracker convertit en nombre toute valeur numerique ou
		-- commencant par « FF » : le « # » garde les couleurs sous forme de texte.
		section.Accent = "#" .. LayoutPrototype.Options.Accent
		section.BorderColor = "#" .. LayoutPrototype.Options.BorderColor
		iniParser.save(absolutePath(FILE_SETTINGS), { layout = section })
	end)
end

function LayoutPrototype.loadSettings()
	local options = LayoutPrototype.Options
	if not fileExists(absolutePath(FILE_SETTINGS)) then
		LayoutPrototype.saveSettings() -- ecrit les valeurs par defaut pour qu'on puisse les editer
		return
	end
	local parsed = nil
	pcall(function()
		parsed = iniParser.parse(absolutePath(FILE_SETTINGS))
	end)
	local section = (parsed or {}).layout or {}
	options.Enabled = toBoolean(section.Enabled, false)
	if section.Widgets == nil and section.Widget ~= nil then
		section.Widgets = section.Widget -- ancien nom de la cle
	end
	options.Widgets = toBoolean(section.Widgets, true)
	local function knownWidgets(value)
		local known = {}
		for _, choice in ipairs(LayoutPrototype.WIDGET_CHOICES) do
			known[choice.key] = true
		end
		local list = {}
		for key in tostring(value):gmatch("[%a]+") do
			if known[key] then
				list[#list + 1] = key
			end
		end
		return table.concat(list, ",")
	end
	-- Les reglages d'avant les 3 zones (WidgetList, ou WidgetsRight = « sous le
	-- tracker ») ne correspondent plus : on repart des valeurs par defaut.
	if section.WidgetsBottom ~= nil then
		options.WidgetsLeft = knownWidgets(section.WidgetsLeft or "")
		options.WidgetsRight = knownWidgets(section.WidgetsRight or "")
		options.WidgetsBottom = knownWidgets(section.WidgetsBottom)
	end
	options.GameAlign = (tostring(section.GameAlign) == "center") and "center" or "left"
	options.Border = toBoolean(section.Border, true)
	if section.Background ~= nil and tostring(section.Background) ~= "" then
		options.Background = tostring(section.Background)
	end
	if section.WidgetUrl ~= nil then
		options.WidgetUrl = tostring(section.WidgetUrl)
	end
	-- Le lecteur INI coupe au DERNIER « = » : une URL avec parametres (?a=b) arrive
	-- donc repartie entre la cle et la valeur. On la recolle.
	for key, value in pairs(section) do
		local urlStart = tostring(key):match("^WidgetUrl=(.*)$")
		if urlStart ~= nil then
			options.WidgetUrl = urlStart .. "=" .. tostring(value)
		end
	end
	local theme = tostring(section.Theme)
	options.Theme = (theme == "dark" or theme == "light") and theme or "glass"
	options.Accent = toHexColor(section.Accent, "")
	options.BorderColor = toHexColor(section.BorderColor, options.BorderColor)
	options.BorderWidth = math.min(12, toNumber(section.BorderWidth, options.BorderWidth))
	options.MarginLeft = toNumber(section.MarginLeft, options.MarginLeft)
	options.MarginTop = toNumber(section.MarginTop, options.MarginTop)
	options.MarginRight = toNumber(section.MarginRight, options.MarginRight)
	options.MarginBottom = toNumber(section.MarginBottom, options.MarginBottom)
	options.TrackerOpacity = math.max(TRACKER_OPACITY_MIN, math.min(100, toNumber(section.TrackerOpacity, 100)))
end

---------------------------------------------------------------------------
-- Image de fond
---------------------------------------------------------------------------

local drawingTypes = nil

--- Types .NET necessaires au fond (constates sur BizHawk 2.11.1) : le nom d'assembly
--- court echoue, il faut le nom complet ; et NLua ne resout pas seul les constructeurs
--- a arguments entiers (Bitmap(l, h), Rectangle(x, y, l, h)) -> signature explicite.
local function importDrawing()
	if drawingTypes ~= nil then
		return drawingTypes
	end
	luanet.load_assembly(ASSEMBLY_DRAWING)
	local Bitmap = luanet.import_type("System.Drawing.Bitmap")
	local Rectangle = luanet.import_type("System.Drawing.Rectangle")
	local int = "System.Int32"
	drawingTypes = {
		Bitmap = Bitmap,
		newBitmap = luanet.get_constructor_bysig(Bitmap, int, int),
		newRectangle = luanet.get_constructor_bysig(Rectangle, int, int, int, int),
		Graphics = luanet.import_type("System.Drawing.Graphics"),
		GraphicsUnit = luanet.import_type("System.Drawing.GraphicsUnit"),
		InterpolationMode = luanet.import_type("System.Drawing.Drawing2D.InterpolationMode"),
		ImageFormat = luanet.import_type("System.Drawing.Imaging.ImageFormat"),
		Directory = luanet.import_type("System.IO.Directory"),
		Color = luanet.import_type("System.Drawing.Color"),
	}
	return drawingTypes
end

--- Dimensions de l'image source (via .NET ; sans luanet, on renonce au fond image).
local function loadBackground()
	local path = absolutePath(LayoutPrototype.Options.Background)
	if not fileExists(path) then
		logOnce("image de fond introuvable : " .. path)
		return false
	end
	local info = nil
	local ok, err = pcall(function()
		local drawing = importDrawing()
		local image = drawing.Bitmap(path)
		info = { path = path, width = image.Width, height = image.Height }
		image:Dispose()
	end)
	if not ok or info == nil or info.width <= 0 or info.height <= 0 then
		logOnce("lecture de l'image de fond impossible : " .. tostring(err))
		return false
	end
	return info
end

--- Cadrage « cover » : zone de l'image source qui remplit une fenetre width x height.
local function coverCrop(width, height)
	local scale = math.max(width / background.width, height / background.height)
	local cropWidth, cropHeight = width / scale, height / scale
	return (background.width - cropWidth) / 2, (background.height - cropHeight) / 2, cropWidth, cropHeight, scale
end

--- Fabrique (une fois par taille de fenetre) le fond a la taille exacte de la fenetre :
--- le dessin se fait ensuite au pixel pres, sans interpolation ni raccord visible.
local function buildScaledBackground(width, height)
	local key = background.path .. "|" .. width .. "x" .. height
	if scaledCache[key] ~= nil then
		return scaledCache[key]
	end
	scaledCache[key] = false
	local sourceName = background.path:match("([^/\\]+)$"):gsub("[^%w]", "_")
	local target = absolutePath(CACHE_FOLDER .. Paths.SLASH .. sourceName .. "_" .. width .. "x" .. height .. ".png")
	if fileExists(target) then
		scaledCache[key] = target
		return target
	end
	local ok, err = pcall(function()
		local drawing = importDrawing()
		drawing.Directory.CreateDirectory(absolutePath(CACHE_FOLDER))
		local cropX, cropY, cropWidth, cropHeight = coverCrop(width, height)
		local source = drawing.Bitmap(background.path)
		local destination = drawing.newBitmap(width, height)
		local graphics = drawing.Graphics.FromImage(destination)
		graphics.InterpolationMode = drawing.InterpolationMode.HighQualityBicubic
		graphics:DrawImage(
			source,
			drawing.newRectangle(0, 0, width, height),
			drawing.newRectangle(math.floor(cropX), math.floor(cropY), math.floor(cropWidth), math.floor(cropHeight)),
			drawing.GraphicsUnit.Pixel
		)
		graphics:Dispose()
		destination:Save(target, drawing.ImageFormat.Png)
		destination:Dispose()
		source:Dispose()
	end)
	if ok and fileExists(target) then
		scaledCache[key] = target
	else
		logOnce("fond pre-redimensionne indisponible (repli sur mise a l'echelle directe) : " .. tostring(err))
	end
	return scaledCache[key]
end

---------------------------------------------------------------------------
-- Geometrie
---------------------------------------------------------------------------

--- Rectangles couvrant toute la fenetre SAUF les trous (decoupage en grille).
local function complement(width, height, holes)
	local function clamp(value, low, high)
		return math.max(low, math.min(high, value))
	end
	local function sortedUnique(values)
		table.sort(values)
		local result = {}
		for _, value in ipairs(values) do
			if result[#result] ~= value then
				result[#result + 1] = value
			end
		end
		return result
	end
	local xs, ys = { 0, width }, { 0, height }
	for _, hole in ipairs(holes) do
		xs[#xs + 1] = clamp(hole.x, 0, width)
		xs[#xs + 1] = clamp(hole.x + hole.w, 0, width)
		ys[#ys + 1] = clamp(hole.y, 0, height)
		ys[#ys + 1] = clamp(hole.y + hole.h, 0, height)
	end
	xs, ys = sortedUnique(xs), sortedUnique(ys)
	local rects = {}
	for row = 1, #ys - 1 do
		local top, bottom = ys[row], ys[row + 1]
		local runStart = nil
		for column = 1, #xs - 1 do
			local left, right = xs[column], xs[column + 1]
			local centerX, centerY = (left + right) / 2, (top + bottom) / 2
			local inHole = false
			for _, hole in ipairs(holes) do
				if centerX > hole.x and centerX < hole.x + hole.w and centerY > hole.y and centerY < hole.y + hole.h then
					inHole = true
					break
				end
			end
			if not inHole then
				runStart = runStart or left
			elseif runStart then
				rects[#rects + 1] = { x = runStart, y = top, w = left - runStart, h = bottom - top }
				runStart = nil
			end
		end
		if runStart then
			rects[#rects + 1] = { x = runStart, y = top, w = width - runStart, h = bottom - top }
		end
	end
	return rects
end

--- Correspondance pixels DS (surface emucore, marge incluse) -> pixels fenetre.
--- client.transformPoint raisonne dans l'espace tactile : (0,0) = coin haut-gauche de
--- l'ecran du BAS. On mesure loin (x8) pour limiter l'erreur d'arrondi sur l'echelle.
local function computeMapping()
	local near = client.transformPoint(0, 0)
	local far = client.transformPoint(GAME_WIDTH * 8, 192 * 8)
	local scaleX = (far.x - near.x) / (GAME_WIDTH * 8)
	local scaleY = (far.y - near.y) / (192 * 8)
	if scaleX <= 0 or scaleY <= 0 then
		return nil
	end
	return {
		scaleX = scaleX,
		scaleY = scaleY,
		originX = near.x - gamePadding.left * scaleX,
		originY = near.y - (192 + gamePadding.top) * scaleY,
	}
end

local function toWindowRect(mapping, x, y, width, height)
	local left = math.floor(mapping.originX + x * mapping.scaleX + 0.5)
	local top = math.floor(mapping.originY + y * mapping.scaleY + 0.5)
	local right = math.floor(mapping.originX + (x + width) * mapping.scaleX + 0.5)
	local bottom = math.floor(mapping.originY + (y + height) * mapping.scaleY + 0.5)
	return { x = left, y = top, w = right - left, h = bottom - top }
end

--- Graphics:DrawImage(image, destination, source, Pixel), lie par signature (un appel
--- direct echoue des le 2e appel avec NLua).
local function drawImageRect(drawing, graphics, image, destination, source)
	local draw = luanet.get_method_bysig(
		graphics, "DrawImage", "System.Drawing.Image", "System.Drawing.Rectangle", "System.Drawing.Rectangle", "System.Drawing.GraphicsUnit"
	)
	draw(image, destination, source, drawing.GraphicsUnit.Pixel)
end

--- Fabrique (une fois par taille de fenetre / disposition) le morceau du fond qui passe
--- sous le tracker : la portion de fenetre couverte par sa marge, floutee et ramenee a
--- la resolution DS. Opaque, il efface aussi l'ancien dessin du tracker a chaque passe.
local function buildTrackerPatch(mapping, scaledPath, windowWidth, windowHeight)
	local x, width = gamePadding.left + GAME_WIDTH, gamePadding.right
	local height = gamePadding.top + GAME_HEIGHT + gamePadding.bottom
	if width <= 0 or height <= 0 then
		return nil
	end
	local window = toWindowRect(mapping, x, 0, width, height)
	-- Un peu plus large que la marge : le flou ne s'estompe pas sur les bords.
	local margin = GLASS_BLUR * 2
	local left = math.max(0, window.x - math.floor(margin * mapping.scaleX))
	local top = math.max(0, window.y - math.floor(margin * mapping.scaleY))
	local right = math.min(windowWidth, window.x + window.w + math.floor(margin * mapping.scaleX))
	local bottom = math.min(windowHeight, window.y + window.h + math.floor(margin * mapping.scaleY))
	if right - left <= 0 or bottom - top <= 0 then
		return nil
	end
	local key = table.concat({ scaledPath, left, top, right, bottom, window.x, window.y, width, height }, "|")
	if glass.key == key then
		return glass.path
	end
	glass.key, glass.path = key, nil
	local baseName = scaledPath:match("([^/\\]+)%.png$") or "fond"
	local target = absolutePath(
		CACHE_FOLDER .. Paths.SLASH .. baseName .. "_verre_" .. table.concat({ window.x, window.y, window.w, window.h, width, height }, "_") .. ".png"
	)
	local ok, err = true, nil
	if not fileExists(target) then
		ok, err = pcall(function()
			local drawing = importDrawing()
			local source = drawing.Bitmap(scaledPath)
			-- Zone etendue, en pixels DS, par rapport au coin de la marge du tracker.
			local areaX = (left - window.x) / mapping.scaleX
			local areaY = (top - window.y) / mapping.scaleY
			local areaW = (right - left) / mapping.scaleX
			local areaH = (bottom - top) / mapping.scaleY
			local small = drawing.newBitmap(math.max(2, math.floor(areaW / GLASS_BLUR)), math.max(2, math.floor(areaH / GLASS_BLUR)))
			local graphics = drawing.Graphics.FromImage(small)
			graphics.InterpolationMode = drawing.InterpolationMode.HighQualityBilinear
			drawImageRect(drawing, graphics, source, drawing.newRectangle(0, 0, small.Width, small.Height),
				drawing.newRectangle(left, top, right - left, bottom - top))
			graphics:Dispose()
			local patch = drawing.newBitmap(width, height)
			local destination = drawing.newRectangle(
				math.floor(areaX), math.floor(areaY), math.ceil(areaW) + 1, math.ceil(areaH) + 1
			)
			local smallRect = drawing.newRectangle(0, 0, small.Width, small.Height)
			-- Sous-couche au plus proche (tout opaque), puis le meme agrandi en lissage.
			graphics = drawing.Graphics.FromImage(patch)
			graphics.InterpolationMode = drawing.InterpolationMode.NearestNeighbor
			drawImageRect(drawing, graphics, small, destination, smallRect)
			graphics:Dispose()
			graphics = drawing.Graphics.FromImage(patch)
			graphics.InterpolationMode = drawing.InterpolationMode.HighQualityBicubic
			drawImageRect(drawing, graphics, small, destination, smallRect)
			graphics:Dispose()
			drawing.Directory.CreateDirectory(absolutePath(CACHE_FOLDER))
			patch:Save(target, drawing.ImageFormat.Png)
			patch:Dispose()
			small:Dispose()
			source:Dispose()
		end)
	end
	if ok and fileExists(target) then
		glass.path, glass.x, glass.width, glass.height = target, x, width, height
	else
		logOnce("fond du tracker translucide indisponible : " .. tostring(err))
	end
	return glass.path
end

---------------------------------------------------------------------------
-- Etat pousse aux widgets
---------------------------------------------------------------------------

local function fileUrl(path)
	local url = absolutePath(path):gsub("\\", "/")
	url = url:gsub("[^%w%-%._~/:]", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
	return "file:///" .. url
end

local function pokemonSpriteUrl(pokemonID)
	local setIndex = 1
	pcall(function()
		setIndex = tonumber(settingsRef.appearance.ICON_SET_INDEX) or 1
	end)
	local set = IconSets.SETS[setIndex] or IconSets.SETS[1]
	if set.FOLDER_NAME == "hgsssprites" then
		set = IconSets.SETS[4] or IconSets.SETS[1] -- planches animees : pas affichables telles quelles
	end
	local path = Paths.FOLDERS.POKEMON_ICONS_FOLDER .. "/" .. set.FOLDER_NAME .. "/" .. tostring(pokemonID) .. set.FILE_EXTENSION
	if not fileExists(absolutePath(path)) then
		return ""
	end
	return fileUrl(path)
end

local function buildWidgetState()
	local options = LayoutPrototype.Options
	local state = { theme = options.Theme, accent = options.Accent }
	pcall(function()
		state.attempts = QuickLoader.getAttempts()
	end)
	pcall(function()
		local text, colorKey = LiveConnect.getStatus()
		local kinds = {
			["Positive text color"] = "ok",
			["Negative text color"] = "ko",
			["Intermediate text color"] = "warn",
		}
		state.status = { text = tostring(text), kind = kinds[colorKey] or "" }
	end)
	pcall(function()
		local lead = programRef.getPlayerPokemon()
		if lead == nil or lead.pokemonID == nil or lead.pokemonID == 0 then
			return
		end
		local data = PokemonData.POKEMON[lead.pokemonID + 1] or {}
		local stats = lead.stats or {}
		local types = {}
		for _, typeName in ipairs(lead.type or data.type or {}) do
			if typeName ~= nil and typeName ~= PokemonData.POKEMON_TYPES.EMPTY then
				local typePath = Paths.FOLDERS.TYPE_IMAGES_FOLDER .. "/" .. tostring(typeName) .. ".png"
				if fileExists(absolutePath(typePath)) then
					types[#types + 1] = fileUrl(typePath)
				end
			end
		end
		state.lead = {
			name = tostring(lead.name or data.name or "?"),
			level = lead.level or 0,
			hp = lead.curHP or 0,
			maxHp = stats.HP or 0,
			atk = stats.ATK, def = stats.DEF, spa = stats.SPA, spd = stats.SPD, spe = stats.SPE,
			bst = tonumber(data.bst) or data.bst,
			sprite = pokemonSpriteUrl(lead.pokemonID),
			types = types,
		}
	end)
	return state
end

local function jsonString(value)
	local out = {}
	local ok = pcall(function()
		for _, code in utf8.codes(value) do
			if code == 34 or code == 92 then
				out[#out + 1] = "\\" .. string.char(code)
			elseif code < 32 or code > 126 then
				if code > 0xFFFF then
					code = code - 0x10000
					out[#out + 1] = string.format("\\u%04x\\u%04x", 0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF))
				else
					out[#out + 1] = string.format("\\u%04x", code)
				end
			else
				out[#out + 1] = string.char(code)
			end
		end
	end)
	if not ok then -- chaine non UTF-8 : on ne garde que l'ASCII imprimable
		return '"' .. value:gsub('[^%w%s%p]', "?"):gsub('[%c"\\]', " ") .. '"'
	end
	return '"' .. table.concat(out) .. '"'
end

local function jsonEncode(value)
	local kind = type(value)
	if kind == "table" then
		local parts = {}
		if #value > 0 or next(value) == nil then
			for _, item in ipairs(value) do
				parts[#parts + 1] = jsonEncode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = tostring(key)
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			parts[#parts + 1] = jsonString(key) .. ":" .. jsonEncode(value[key])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif kind == "string" then
		return jsonString(value)
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		if math.type(value) == "integer" or value == math.floor(value) then
			return string.format("%d", value)
		end
		return tostring(value)
	elseif kind == "boolean" then
		return value and "true" or "false"
	end
	return "null"
end

---------------------------------------------------------------------------
-- Widgets HTML (WebView2 incruste dans la fenetre BizHawk)
---------------------------------------------------------------------------

local function findMainForm()
	luanet.load_assembly(ASSEMBLY_FORMS)
	local Application = luanet.import_type("System.Windows.Forms.Application")
	local enumerator = Application.OpenForms:GetEnumerator()
	while enumerator:MoveNext() do
		local form = enumerator.Current
		if tostring(form:GetType().Name) == "MainForm" then
			return form
		end
	end
	return nil
end

--- Le controle sur lequel BizHawk affiche le jeu (ni le menu, ni la barre d'etat).
local function findDisplayControl(form)
	local enumerator = form.Controls:GetEnumerator()
	while enumerator:MoveNext() do
		local control = enumerator.Current
		local typeName = tostring(control:GetType().Name)
		if not typeName:find("Strip") and tostring(control.Name):sub(1, #WEB_CONTROL_NAME) ~= WEB_CONTROL_NAME then
			return control
		end
	end
	return nil
end

--- Retire les controles WebView2 du layout (tous, ou ceux d'une zone).
local function removeWebControls(form, controlName)
	local stale = {}
	local enumerator = form.Controls:GetEnumerator()
	while enumerator:MoveNext() do
		local control = enumerator.Current
		local name = tostring(control.Name)
		if (controlName == nil and name:sub(1, #WEB_CONTROL_NAME) == WEB_CONTROL_NAME) or name == controlName then
			stale[#stale + 1] = control
		end
	end
	for _, control in ipairs(stale) do
		form.Controls:Remove(control)
		control:Dispose()
	end
end

local function zoneControlName(zone)
	return WEB_CONTROL_NAME .. "_" .. zone.name
end

local function destroyZone(zone)
	pcall(function()
		local form = zone.form or findMainForm()
		if form ~= nil then
			removeWebControls(form, zoneControlName(zone))
		end
	end)
	for key in pairs(zone) do
		if key ~= "name" then
			zone[key] = nil
		end
	end
end

local function destroyWebView()
	for _, name in ipairs(ZONE_ORDER) do
		destroyZone(zones[name])
	end
	pcall(function()
		local form = findMainForm()
		if form ~= nil then
			removeWebControls(form) -- restes d'un precedent chargement du tracker
		end
	end)
end

local function anyZoneShown()
	for _, name in ipairs(ZONE_ORDER) do
		if zones[name].control ~= nil then
			return true
		end
	end
	return false
end

--- Ou les widgets vont chercher leur contenu :
---   « custom » : WidgetUrl renseignee dans Layout.ini (n'importe quelle page) ;
---   « app »    : les widgets d'IronMonStats (/overlay), si LiveConnect est configure ;
---   « local »  : la page fournie avec le tracker, alimentee par Lua (repli hors ligne).
local function widgetSource()
	local options = LayoutPrototype.Options
	if options.WidgetUrl ~= nil and options.WidgetUrl ~= "" then
		return "custom"
	end
	local configured = false
	pcall(function()
		configured = LiveConnect.isConfigured()
	end)
	return configured and "app" or "local"
end

--- Widgets d'IronMonStats affiches dans une zone (liste « a,b,c »).
local function zoneWidgets(zone)
	return LayoutPrototype.Options[ZONE_OPTION[zone.name]] or ""
end

local function largeEnough(rect)
	if rect.w < ZONE_MIN_WIDTH or rect.h < ZONE_MIN_HEIGHT then
		return nil
	end
	return rect
end

--- Rectangle d'une zone, en coordonnees de la fenetre BizHawk (ou nil : pas de place).
---   left   : toute la marge gauche ;
---   bottom : sous le tracker (et son numero de seed), sur toute la largeur restante
---            jusqu'au bord droit (format paysage, ex. la carte dresseur) ;
---   right  : a droite du tracker, du haut jusqu'a la zone du bas (ou jusqu'en bas
---            de la fenetre si la zone du bas est vide).
local function zoneRect(zone, display)
	local options = LayoutPrototype.Options
	if zone.name == "left" then
		if options.MarginLeft < MIN_WIDGET_WIDTH then
			return nil
		end
		return {
			x = display.Left,
			y = display.Top + options.MarginTop,
			w = options.MarginLeft,
			h = math.max(1, display.Height - options.MarginTop),
		}
	end
	if layoutGeometry == nil or layoutGeometry.tracker == nil then
		return nil
	end
	local rect
	local tracker = layoutGeometry.tracker
	local bottomTop = math.max(tracker.y + tracker.h, layoutGeometry.seedBottom or 0) + ZONE_GAP
	if zone.name == "right" then
		if layoutGeometry.canvasRight == nil then
			return nil
		end
		local x = layoutGeometry.canvasRight + ZONE_GAP
		local bottom = options.WidgetsBottom ~= "" and (bottomTop - ZONE_GAP) or (display.Height - ZONE_GAP)
		rect = largeEnough({ x = x, y = ZONE_GAP, w = display.Width - x - ZONE_GAP, h = bottom - ZONE_GAP })
	else
		local left = tracker.x - ZONE_INSET
		rect = largeEnough({
			x = left,
			y = bottomTop,
			w = display.Width - ZONE_GAP - left,
			h = display.Height - bottomTop - ZONE_GAP,
		})
	end
	if rect == nil then
		return nil
	end
	return { x = display.Left + rect.x, y = display.Top + rect.y, w = rect.w, h = rect.h }
end

local function zoneWanted(zone, mode)
	local options = LayoutPrototype.Options
	if not options.Widgets then
		return false
	end
	if mode ~= "app" then
		return zone.name == "left" -- page locale / URL perso : une seule colonne
	end
	return zoneWidgets(zone) ~= ""
end

local function appUrl()
	return (tostring(LiveConnect.Options.AppUrl or ""):gsub("/+$", ""))
end

local function urlEncode(value)
	return (tostring(value):gsub("[^%w%-%._~,]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- Ouvre (ou rouvre) la session overlay d'une zone : le token part dans un en-tete
--- Authorization, jamais dans l'URL. L'appli repond par une redirection vers /overlay.
local function connectZone(zone)
	local options = LayoutPrototype.Options
	local url = appUrl() .. "/overlay/connect?widgets=" .. urlEncode(zoneWidgets(zone))
		.. "&zone=" .. zone.name
		.. "&theme=" .. urlEncode(options.Theme)
		.. (options.Accent ~= "" and ("&accent=" .. urlEncode(options.Accent)) or "")
	local headers = "Authorization: Bearer " .. tostring(LiveConnect.Options.Token) .. "\r\nAccept: text/html"
	zone.navigate(zone.createRequest(url, "GET", nil, headers))
	zone.lastConnectAt = os.time()
end

--- Prepare les appels repetables vers WebView2. Constate sur BizHawk 2.11.1 : un
--- appel .NET « normal » (objet:Methode(args)) echoue des le 2e appel (cache de
--- methode de NLua) ; une methode liee par signature se rappelle sans probleme, a
--- condition que luanet connaisse l'assembly des types de la signature.
local coreAssemblyLoaded = false

local function bindAppNavigation(zone)
	local core = zone.control.CoreWebView2
	if not coreAssemblyLoaded then
		-- Deja chargee par la DLL WinForms ; on la fait connaitre a luanet par son
		-- nom complet (un chemin de fichier ne marche pas).
		local coreName = luanet.import_type("System.Reflection.AssemblyName").GetAssemblyName(
			absolutePath(WEB_LIB_FOLDER .. Paths.SLASH .. "Microsoft.Web.WebView2.Core.dll")
		).FullName
		luanet.load_assembly(coreName)
		coreAssemblyLoaded = true
	end
	zone.createRequest = luanet.get_method_bysig(
		core.Environment, "CreateWebResourceRequest", "System.String", "System.String", "System.IO.Stream", "System.String"
	)
	zone.navigate = luanet.get_method_bysig(
		core, "NavigateWithWebResourceRequest", "Microsoft.Web.WebView2.Core.CoreWebView2WebResourceRequest"
	)
end

--- N'ouvre dans le navigateur que des liens web (http/https).
local function openInBrowser(url)
	if not url:match("^https?://[^%s]+$") then
		return
	end
	if LayoutPrototype.openUrlOverride ~= nil then
		LayoutPrototype.openUrlOverride(url) -- tests : intercepte sans lancer le navigateur
		return
	end
	pcall(function()
		luanet.load_assembly(ASSEMBLY_SYSTEM)
		local ProcessStartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
		local Process = luanet.import_type("System.Diagnostics.Process")
		local startInfo = ProcessStartInfo()
		startInfo.FileName = url
		startInfo.UseShellExecute = true
		Process.Start(startInfo)
	end)
end

--- La page parle au tracker via son titre (page /overlay d'IronMonStats),
--- qui contient ses derniers messages : « ims 12|open|url 13|release| ». On les
--- traite tous, dans l'ordre, une seule fois chacun (un clic sur un lien envoie
--- « open » puis « release » entre deux lectures : avec un seul message, le second
--- ecrasait le premier et le lien ne s'ouvrait pas).
---   open|url   ouvre un lien dans le navigateur ;
---   release|   rend le clavier au jeu (apres un clic, ou une touche pressee hors du
---              champ de recherche). Le tracker ne reprend jamais le clavier de
---              lui-meme : il le volerait au champ de recherche du sac pendant la frappe ;
---   reconnect| renouvelle la session overlay.
local function handlePageSignal(zone, display)
	local title = tostring(zone.control.CoreWebView2.DocumentTitle or "")
	if title:sub(1, 4) ~= "ims " then
		return
	end
	local messages, highest = {}, 0
	for sequence, action, payload in title:sub(5):gmatch("(%d+)|(%a+)|(%S*)") do
		sequence = tonumber(sequence)
		messages[#messages + 1] = { sequence = sequence, action = action, payload = payload }
		highest = math.max(highest, sequence)
	end
	-- Page rechargee (reconnexion, changement de widgets) : la numerotation repart a 1.
	if highest < (zone.lastSignal or 0) then
		zone.lastSignal = 0
	end
	for _, message in ipairs(messages) do
		if message.sequence > (zone.lastSignal or 0) then
			zone.lastSignal = message.sequence
			if message.action == "open" then
				openInBrowser(message.payload)
			elseif message.action == "release" and display ~= nil then
				display:Focus()
			elseif message.action == "reconnect" and zone.mode == "app" and os.time() - (zone.lastConnectAt or 0) >= 30 then
				connectZone(zone)
			end
		end
	end
end

--- Navigateur incruste en mode « widget » : pas de barre d'etat (l'URL d'un lien
--- survole s'affichait en bas a gauche), pas de menu clic droit, pas de zoom, et pas
--- de raccourcis navigateur (F5 rechargerait la page au lieu de sauvegarder l'etat).
local function configureBrowser(control)
	local settings = control.CoreWebView2.Settings
	for name, value in pairs({
		IsStatusBarEnabled = false,
		AreDefaultContextMenusEnabled = false,
		IsZoomControlEnabled = false,
		AreBrowserAcceleratorKeysEnabled = false,
	}) do
		local ok, err = pcall(function()
			settings[name] = value
		end)
		if not ok then
			logOnce("reglage WebView2 " .. name .. " impossible : " .. tostring(err))
		end
	end
end

local function createZone(zone, form, rect, mode)
	local library = absolutePath(WEB_LIB_FOLDER .. Paths.SLASH .. "Microsoft.Web.WebView2.WinForms.dll")
	if not fileExists(library) then
		error("bibliotheque WebView2 absente (" .. WEB_LIB_FOLDER .. ")")
	end
	luanet.load_assembly(ASSEMBLY_SYSTEM)
	luanet.load_assembly(ASSEMBLY_DRAWING)
	removeWebControls(form, zoneControlName(zone))
	local Assembly = luanet.import_type("System.Reflection.Assembly")
	local Activator = luanet.import_type("System.Activator")
	local Uri = luanet.import_type("System.Uri")
	local Color = luanet.import_type("System.Drawing.Color")
	local assembly = Assembly.LoadFrom(library)
	local control = Activator.CreateInstance(assembly:GetType("Microsoft.Web.WebView2.WinForms.WebView2"))
	local properties =
		Activator.CreateInstance(assembly:GetType("Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties"))
	-- Meme profil pour toutes les zones : elles partagent les cookies (session overlay).
	properties.UserDataFolder = absolutePath(WEB_DATA_FOLDER)
	control.CreationProperties = properties
	control.Name = zoneControlName(zone)
	control.TabStop = false
	control.DefaultBackgroundColor = Color.Transparent
	-- Taille finale des la creation : une page chargee dans un controle minuscule
	-- puis agrandi peut garder une position de defilement decalee.
	control.Left, control.Top, control.Width, control.Height = rect.x, rect.y, rect.w, rect.h
	form.Controls:Add(control)
	control:BringToFront()
	if mode == "custom" then
		control.Source = Uri(LayoutPrototype.Options.WidgetUrl)
	elseif mode == "app" then
		control.Source = Uri("about:blank") -- demarre le moteur ; connexion une fois pret
	else
		control.Source = Uri(fileUrl(WIDGETS_PAGE))
	end
	-- Lie par signature : voir bindAppNavigation.
	zone.execute = luanet.get_method_bysig(control, "ExecuteScriptAsync", "System.String")
	zone.control, zone.form, zone.mode = control, form, mode
	zone.bounds = table.concat({ rect.x, rect.y, rect.w, rect.h }, ",")
end

local function updateZone(zone, form, display, mode, state)
	if not zoneWanted(zone, mode) or display == nil or (zone.control ~= nil and zone.mode ~= mode) then
		if zone.control ~= nil then
			destroyZone(zone)
		end
		if not zoneWanted(zone, mode) or display == nil then
			return
		end
	end
	local rect = zoneRect(zone, display)
	if rect == nil then
		-- Pas de place pour l'instant (ecran du tracker plus haut, fenetre reduite) :
		-- on masque sans detruire, pour ne pas recharger la page a chaque fois.
		if zone.control ~= nil and zone.control.Visible then
			zone.control.Visible = false
		end
		return
	end
	if zone.control == nil then
		local created, err = pcall(createZone, zone, form, rect, mode)
		if not created then
			-- Hors Windows (Mono), ou WebView2 inutilisable : on n'insiste pas a chaque tick.
			error("WebView2 indisponible : " .. tostring(err))
		end
		zone.createdAt = os.time()
	end
	if zone.control.CoreWebView2 == nil and os.time() - (zone.createdAt or os.time()) > WEB_ENGINE_TIMEOUT_SECONDS then
		-- Controle cree mais moteur jamais pret : runtime Edge WebView2 absent.
		error("WebView2 indisponible : le moteur ne demarre pas (installer « Microsoft Edge WebView2 Runtime »)")
	end
	if not zone.control.Visible then
		zone.control.Visible = true
	end
	local bounds = table.concat({ rect.x, rect.y, rect.w, rect.h }, ",")
	if bounds ~= zone.bounds then
		-- D'un seul coup (pas de tailles intermediaires) ; constructeur lie par signature.
		zone.control.Bounds = importDrawing().newRectangle(rect.x, rect.y, rect.w, rect.h)
		zone.control:BringToFront()
		zone.bounds = bounds
	end
	if zone.control.CoreWebView2 == nil then
		return -- moteur encore en cours d'initialisation
	end
	if not zone.ready then
		zone.ready = true
		zone.lastState = nil
		-- La page locale n'a rien a cliquer : desactivee, elle n'intercepte ni la
		-- souris ni le clavier. Les widgets de l'appli, eux, ont liens et carrousel.
		zone.control.Enabled = zone.mode ~= "local"
		configureBrowser(zone.control)
		if zone.mode == "app" then
			bindAppNavigation(zone)
			connectZone(zone)
		end
	end
	if zone.mode == "local" then
		local encoded = jsonEncode(state)
		if encoded ~= zone.lastState or updatesSinceRedraw == 0 then
			zone.execute("window.IMS&&IMS.update(" .. encoded .. ")")
			zone.lastState = encoded
		end
		return
	end
	handlePageSignal(zone, display)
end

--- Cree / place / alimente les zones de widgets.
local function updateWebView(state)
	if webFailed then
		return
	end
	local ok, err = pcall(function()
		local form = findMainForm()
		if form == nil then
			error("fenetre BizHawk introuvable")
		end
		local display = findDisplayControl(form)
		local mode = widgetSource()
		for _, name in ipairs(ZONE_ORDER) do
			updateZone(zones[name], form, display, mode, state)
		end
	end)
	if not ok then
		local message = tostring(err)
		if message:find("WebView2 absente") or message:find("WebView2 indisponible") or message:find("introuvable") then
			webFailed = true
			destroyWebView()
			logOnce("widgets HTML indisponibles (repli sur le panneau texte) : " .. message)
		else
			logOnce("mise a jour des widgets HTML impossible : " .. message)
		end
	end
end

---------------------------------------------------------------------------
-- Panneau texte de repli (si WebView2 est indisponible)
---------------------------------------------------------------------------

local function drawFallbackWidget(state)
	local options = LayoutPrototype.Options
	local panelWidth = options.MarginLeft - 32
	if not options.Widgets or panelWidth < 180 then
		return
	end
	local lines = {
		{ text = "IronMonStats", size = 20, style = "bold", color = 0xFFFFFFFF },
		{ text = (state.status or {}).text or "", size = 13, color = 0xFFB8C4E0 },
	}
	if state.lead then
		lines[#lines + 1] = { text = state.lead.name .. "   Niv. " .. state.lead.level, size = 17, style = "bold", color = 0xFFF2CE5A }
		lines[#lines + 1] = { text = "PV " .. state.lead.hp .. " / " .. state.lead.maxHp, size = 14, color = 0xFFFFFFFF }
	end
	if state.attempts then
		lines[#lines + 1] = { text = "Tentative N° " .. tostring(state.attempts), size = 13, color = 0xFFD8DEEE }
	end
	local panelHeight = 24
	for _, line in ipairs(lines) do
		panelHeight = panelHeight + line.size + 9
	end
	local x, y = 16, 16 + options.MarginTop
	original.drawRectangle(x, y, panelWidth, panelHeight, 0xFFE0C060, 0xD8101828, "client")
	local cursorY = y + 12
	for _, line in ipairs(lines) do
		original.drawText(x + 14, cursorY, line.text, line.color, nil, line.size, FONT, line.style, nil, nil, "client")
		cursorY = cursorY + line.size + 9
	end
end

---------------------------------------------------------------------------
-- Dessin
---------------------------------------------------------------------------

local function isSupportedScreenLayout()
	return client.bufferwidth() == GAME_WIDTH and client.bufferheight() == GAME_HEIGHT
end

local function drawBorder(hole)
	local options = LayoutPrototype.Options
	if not options.Border or options.BorderWidth <= 0 then
		return
	end
	local color = colorFromHex(options.BorderColor)
	for inset = 1, options.BorderWidth do
		original.drawRectangle(hole.x - inset, hole.y - inset, hole.w + 2 * inset - 1, hole.h + 2 * inset - 1, color, nil, "client")
	end
	-- Lisere sombre exterieur : la bordure reste lisible sur un fond clair.
	local outer = options.BorderWidth + 1
	original.drawRectangle(hole.x - outer, hole.y - outer, hole.w + 2 * outer - 1, hole.h + 2 * outer - 1, 0x70000000, nil, "client")
end

--- Zone du tracker a laisser visible : ses vrais cadres (+ sa marge habituelle),
--- pas les aplats de fond noirs qui debordent autour. Le numero de seed, lui, est
--- redessine net directement sur le fond (voir drawSeedLabel).
local function trackerHoleBounds()
	local bounds = trackerBounds
	local framed = bounds.framed
	if framed == nil then
		return bounds
	end
	local margin = Graphics.SIZES.BORDER_MARGIN or 5
	return {
		left = math.max(bounds.left, framed.left - margin),
		top = math.max(bounds.top, framed.top - margin),
		right = math.min(bounds.right, framed.right + margin),
		bottom = math.min(bounds.bottom, framed.bottom + margin),
	}
end

--- Le « Seed N° » du tracker, redessine en pixels fenetre (net) sur le fond, avec
--- une ombre pour rester lisible sur une image claire.
--- Renvoie le bas du texte (pixels fenetre), pour placer la zone de widgets dessous.
local function drawSeedLabel(mapping)
	if seedLabel == nil then
		return nil
	end
	local x = math.floor(mapping.originX + seedLabel.x * mapping.scaleX + 0.5)
	local y = math.floor(mapping.originY + seedLabel.y * mapping.scaleY + 0.5)
	local size = math.max(10, math.floor((seedLabel.size or 9) * mapping.scaleY + 0.5))
	local family = seedLabel.family or FONT
	original.drawText(x + 2, y + 2, seedLabel.text, 0xC0000000, nil, size, family, nil, nil, nil, "client")
	original.drawText(x, y, seedLabel.text, 0xFFFFFFFF, nil, size, family, nil, nil, nil, "client")
	return y + math.floor(size * 1.6)
end

local function redraw(state)
	local width, height = client.screenwidth(), client.screenheight()
	local mapping = computeMapping()
	gui.clearGraphics("client")
	if mapping == nil or width <= 0 or height <= 0 then
		return
	end
	local canvasHeight = gamePadding.top + GAME_HEIGHT + gamePadding.bottom
	local bounds = trackerHoleBounds()
	local holes = {
		toWindowRect(mapping, gamePadding.left, gamePadding.top, GAME_WIDTH, GAME_HEIGHT),
	}
	if bounds.right > bounds.left and bounds.bottom > bounds.top then
		holes[2] = toWindowRect(
			mapping, bounds.left, bounds.top, bounds.right - bounds.left, math.min(bounds.bottom, canvasHeight) - bounds.top
		)
	end
	local rects = complement(width, height, holes)

	local scaledPath = nil
	if background then
		-- Pendant un redimensionnement, on dessine en mise a l'echelle directe ; une fois
		-- la taille stable, on bascule sur le fond pre-redimensionne (pixel pour pixel).
		local key = width .. "x" .. height
		if stableSize.key ~= key then
			stableSize.key, stableSize.updates = key, 0
		end
		if scaledCache[background.path .. "|" .. key] or stableSize.updates >= RESIZE_SETTLE_UPDATES then
			scaledPath = buildScaledBackground(width, height)
		end
	end

	for _, rect in ipairs(rects) do
		if rect.w > 0 and rect.h > 0 then
			if scaledPath then
				gui.drawImageRegion(scaledPath, rect.x, rect.y, rect.w, rect.h, rect.x, rect.y, rect.w, rect.h, "client")
			elseif background then
				local cropX, cropY, _, _, scale = coverCrop(width, height)
				gui.drawImageRegion(
					background.path,
					math.floor(cropX + rect.x / scale), math.floor(cropY + rect.y / scale),
					math.max(1, math.floor(rect.w / scale)), math.max(1, math.floor(rect.h / scale)),
					rect.x, rect.y, rect.w, rect.h, "client"
				)
			else
				original.drawRectangle(rect.x, rect.y, rect.w, rect.h, FALLBACK_COLOR, FALLBACK_COLOR, "client")
			end
		end
	end
	for _, hole in ipairs(holes) do
		drawBorder(hole)
	end
	if scaledPath and LayoutPrototype.Options.TrackerOpacity < 100 then
		local previous = glass.path
		if buildTrackerPatch(mapping, scaledPath, width, height) ~= previous and glass.path ~= nil and programRef then
			pcall(programRef.drawCurrentScreens) -- le tracker repasse par-dessus le nouveau fond
		end
	end
	local seedBottom = drawSeedLabel(mapping)
	layoutGeometry = {
		tracker = holes[2],
		seedBottom = seedBottom,
		-- Bord droit de la zone de dessin du tracker (jeu + marge du tracker).
		canvasRight = math.floor(mapping.originX + (gamePadding.left + GAME_WIDTH + gamePadding.right) * mapping.scaleX + 0.5),
	}
	if not anyZoneShown() then
		drawFallbackWidget(state)
	end
end

local function currentSignature(state)
	local near = client.transformPoint(0, 0)
	local options = LayoutPrototype.Options
	local hole = trackerHoleBounds()
	local parts = {
		client.screenwidth(), client.screenheight(), near.x, near.y,
		gamePadding.left, gamePadding.top, gamePadding.right, gamePadding.bottom,
		hole.left, hole.top, hole.right, hole.bottom,
		tostring(options.Border), options.BorderColor, options.BorderWidth,
		background and background.path or "-",
		seedLabel and (seedLabel.text .. "@" .. seedLabel.x .. "," .. seedLabel.y) or "-",
	}
	if not anyZoneShown() then
		parts[#parts + 1] = jsonEncode(state) -- le panneau de repli est dessine avec le fond
	end
	return table.concat(parts, ";")
end

---------------------------------------------------------------------------
-- Accroches cote tracker
---------------------------------------------------------------------------

--- Note la zone ou le tracker dessine ses cadres (a droite du jeu), pour y ajuster le
--- trou du fond : ecran principal, options, log viewer... Le texte hors cadre (numero
--- de seed) n'est volontairement pas compte : il est repris par les widgets.
local function extendBounds(bounds, left, top, right, bottom)
	bounds.left = math.min(bounds.left, left)
	bounds.top = math.min(bounds.top, top)
	bounds.right = math.max(bounds.right, right)
	bounds.bottom = math.max(bounds.bottom, bottom)
end

--- `framed` = cadre avec une bordure distincte de son fond (les vraies boites du
--- tracker), par opposition aux aplats de fond qui debordent autour d'elles.
local function trackRectangle(x, y, width, height, framed)
	if type(x) ~= "number" or type(y) ~= "number" then
		return
	end
	if x < gamePadding.left + GAME_WIDTH then
		return
	end
	local right, bottom = x + (tonumber(width) or 0) + 1, y + (tonumber(height) or 0) + 1
	if inTrackerPass and passBounds == nil then
		passBounds = { left = x, top = y, right = right, bottom = bottom }
	end
	local bounds = inTrackerPass and passBounds or trackerBounds
	extendBounds(bounds, x, y, right, bottom)
	if framed then
		if bounds.framed == nil then
			bounds.framed = { left = x, top = y, right = right, bottom = bottom }
		else
			extendBounds(bounds.framed, x, y, right, bottom)
		end
	end
end

local function isOpaque(color)
	return type(color) == "number" and color // 0x1000000 == 0xFF
end

local function isGlassBackground(color)
	return isOpaque(color) and glassPass.backgrounds[math.floor(color) % 0x1000000] == true
end

--- Note un texte / une image / un aplat colore dessine pendant la passe translucide.
local function noteContent(x, y, width, height)
	if glassPass ~= nil and type(x) == "number" and type(y) == "number" then
		local content = glassPass.content
		content[#content + 1] = { left = x, top = y, right = x + (tonumber(width) or 16), bottom = y + (tonumber(height) or 16) }
	end
end

--- Un fond pose sur du contenu deja dessine (au moins la moitie d'un texte ou d'une
--- image sous lui) : c'est une fenetre par-dessus le tracker, pas un de ses cadres.
local function coversContent(x, y, width, height)
	local right, bottom = x + (tonumber(width) or 0), y + (tonumber(height) or 0)
	for _, item in ipairs(glassPass.content) do
		local overlapW = math.min(right, item.right) - math.max(x, item.left)
		local overlapH = math.min(bottom, item.bottom) - math.max(y, item.top)
		if overlapW > 0 and overlapH > 0
			and overlapW * overlapH * 2 >= (item.right - item.left) * (item.bottom - item.top) then
			return true
		end
	end
	return false
end

--- Couleur opaque d'un des fonds du tracker -> meme couleur translucide (sinon inchangee).
local function glassColor(color)
	if isGlassBackground(color) then
		return glassPass.alpha * 0x1000000 + math.floor(color) % 0x1000000
	end
	return color
end

--- Debut d'une passe translucide : pose le fond floute sous le tracker et note ses
--- couleurs de fond (et de leurs ombres) a rendre translucides pendant la passe.
local function startGlassPass()
	local opacity = LayoutPrototype.Options.TrackerOpacity
	if opacity >= 100 or glass.path == nil or not background then
		return
	end
	if glass.x ~= gamePadding.left + GAME_WIDTH or glass.width ~= gamePadding.right
		or glass.height ~= gamePadding.top + GAME_HEIGHT + gamePadding.bottom then
		return -- marge changee : morceau de fond a refaire (au prochain redraw)
	end
	local scheme = settingsRef and settingsRef.colorScheme or {}
	local backgrounds, shadows = {}, {}
	for _, key in ipairs({ "Main background color", "Top box background color", "Bottom box background color" }) do
		if type(scheme[key]) == "number" then
			backgrounds[math.floor(scheme[key]) % 0x1000000] = true
			for _, veryDark in ipairs({ false, true }) do
				local ok, shadow = pcall(DrawingUtils.calcShadowColor, key, veryDark)
				if ok and type(shadow) == "number" then
					shadows[math.floor(shadow) % 0x1000000] = true
				end
			end
		end
	end
	original.drawImage(glass.path, glass.x, 0, glass.width, glass.height, true, "emucore")
	glassPass = { alpha = math.floor(opacity * 255 / 100 + 0.5), backgrounds = backgrounds, shadows = shadows, content = {} }
end

local function installHooks()
	gui.drawRectangle = function(x, y, width, height, line, fill, ...)
		-- Le tracker passe 0x00000000 quand un cadre n'a pas de bordure : seule une
		-- bordure visible (alpha non nul) et distincte du fond compte comme un cadre.
		local framed = type(line) == "number" and line ~= fill and (line // 0x1000000) % 0x100 ~= 0
		trackRectangle(x, y, width, height, framed)
		if glassPass ~= nil and inTrackerPass and type(x) == "number" and type(y) == "number" then
			if isGlassBackground(fill) or (fill == nil and isGlassBackground(line)) then
				if not coversContent(x, y, width, height) then
					line, fill = glassColor(line), glassColor(fill)
				end
			elseif line == 0 and isOpaque(fill) and glassPass.shadows[math.floor(fill) % 0x1000000] then
				-- Ombre portee d'un cadre (aplat sans bordure, teinte assombrie du fond) :
				-- sous un cadre translucide, elle le noircirait. On la saute.
				return
			elseif isOpaque(fill) then
				noteContent(x, y, (tonumber(width) or 0) + 1, (tonumber(height) or 0) + 1) -- barre, jauge...
			end
		end
		return original.drawRectangle(x, y, width, height, line, fill, ...)
	end
	gui.drawImage = function(path, x, y, width, height, ...)
		if inTrackerPass then
			noteContent(x, y, width, height)
		end
		return original.drawImage(path, x, y, width, height, ...)
	end
	gui.drawImageRegion = function(path, sourceX, sourceY, sourceWidth, sourceHeight, x, y, width, height, ...)
		if inTrackerPass then
			noteContent(x, y, width or sourceWidth, height or sourceHeight)
		end
		return original.drawImageRegion(path, sourceX, sourceY, sourceWidth, sourceHeight, x, y, width, height, ...)
	end
	gui.drawText = function(x, y, message, foreColor, backColor, fontSize, fontFamily, ...)
		-- Le numero de seed est dessine par le tracker hors de tout cadre, sur du noir :
		-- on le note et on le redessine net sur le fond (drawSeedLabel) a la place.
		if type(message) == "string" and message:sub(1, 6) == "Seed N" and type(x) == "number" then
			local label = { text = message, x = x, y = y, size = fontSize, family = fontFamily }
			if inTrackerPass then
				passSeedLabel = label
			else
				seedLabel = label
			end
			return
		end
		if glassPass ~= nil and inTrackerPass and message ~= nil then
			local size = tonumber(fontSize) or 9
			noteContent(x, y, #tostring(message) * size * 0.55, size + 3)
		end
		return original.drawText(x, y, message, foreColor, backColor, fontSize, fontFamily, ...)
	end
	client.SetGameExtraPadding = function(left, top, right, bottom)
		gamePadding = { left = left or 0, top = top or 0, right = right or 0, bottom = bottom or 0 }
		return original.setGamePadding(left, top, right, bottom)
	end
end

local function removeHooks()
	gui.drawRectangle = original.drawRectangle
	gui.drawText = original.drawText
	gui.drawImage = original.drawImage
	gui.drawImageRegion = original.drawImageRegion
	client.SetGameExtraPadding = original.setGamePadding
	glassPass = nil
end

--- Appele par Program.drawCurrentScreens avant/apres le dessin des ecrans du tracker.
function LayoutPrototype.beginTrackerDraw()
	if active then
		inTrackerPass = true
		passBounds = nil
		passSeedLabel = nil
		glassPass = nil
		local ok, err = pcall(startGlassPass)
		if not ok then
			glassPass = nil
			logOnce("tracker translucide : " .. tostring(err))
		end
	end
end

function LayoutPrototype.endTrackerDraw()
	if active and inTrackerPass then
		inTrackerPass = false
		glassPass = nil
		if passBounds ~= nil then
			trackerBounds = passBounds
		end
		-- Pas de « Seed N° » dans cette passe (options, log viewer...) : on l'efface.
		seedLabel = passSeedLabel
	end
end

local function applyMargins()
	local options = LayoutPrototype.Options
	client.SetClientExtraPadding(options.MarginLeft, options.MarginTop, options.MarginRight + alignment.extra, options.MarginBottom)
end

local function isWindowMaximized()
	local maximized = false
	pcall(function()
		local form = findMainForm()
		-- NLua rend les enums .NET sous la forme « Maximized: <hash> ».
		maximized = form ~= nil and tostring(form.WindowState):match("^Maximized") ~= nil
	end)
	return maximized
end

--- Colle le jeu a la colonne de gauche quand la fenetre est maximisee. BizHawk centre
--- l'image dans la place restante : on ajoute a droite deux fois l'ecart mesure a
--- gauche, ce qui regroupe toute la place libre a droite (pour les widgets).
--- Fenetre non maximisee : BizHawk la dimensionne d'apres les marges, il n'y a pas
--- d'ecart a combler (et ajouter de la marge l'agrandirait).
local function alignGame()
	local options = LayoutPrototype.Options
	local wanted = options.GameAlign == "left" and isWindowMaximized()
	local key = wanted and (client.screenwidth() .. "x" .. client.screenheight()) or nil
	if key ~= alignment.key then
		alignment.key = key
		if alignment.extra ~= 0 then
			alignment.extra = 0
			applyMargins()
			return -- nouvelle mesure au prochain tick, une fois la mise en page refaite
		end
	end
	if not wanted then
		return
	end
	local mapping = computeMapping()
	if mapping == nil then
		return
	end
	local gap = math.floor(mapping.originX - options.MarginLeft + 0.5)
	if gap > 1 then
		alignment.extra = alignment.extra + 2 * gap
		applyMargins()
	end
end

--- Oublie l'alignement (marges changees) : il sera recalcule au prochain tick.
local function resetAlignment()
	alignment.key, alignment.extra = nil, 0
end

--- Tick periodique (FrameCounter dans Program.lua). Ne doit jamais jeter.
function LayoutPrototype.update()
	if not active then
		return
	end
	local ok, err = pcall(function()
		if not isSupportedScreenLayout() then
			logOnce("disposition d'ecrans non geree par le prototype (Natural/Vertical sans ecart uniquement)")
			if appliedSignature ~= "unsupported" then
				appliedSignature = "unsupported"
				gui.clearGraphics("client")
				destroyWebView()
			end
			return
		end
		updatesSinceRedraw = updatesSinceRedraw + 1
		stableSize.updates = stableSize.updates + 1
		alignGame()
		local state = buildWidgetState()
		local settled = stableSize.updates == RESIZE_SETTLE_UPDATES
		local forced = updatesSinceRedraw >= FORCE_REDRAW_EVERY_UPDATES
		if forced then
			updatesSinceRedraw = 0
		end
		updateWebView(state)
		local signature = currentSignature(state)
		if signature ~= appliedSignature or settled or forced then
			redraw(state)
			appliedSignature = signature
		end
	end)
	if not ok then
		logOnce("erreur de dessin : " .. tostring(err))
	end
end

---------------------------------------------------------------------------
-- Activation / reglages a chaud
---------------------------------------------------------------------------

local function activate()
	if active then
		return
	end
	local ok, err = pcall(function()
		installHooks()
		background = loadBackground()
		applyMargins()
		active = true
		appliedSignature = nil
		print("[Layout] prototype actif (Extras > Layout, ou savedData/Layout.ini)")
	end)
	if not ok then
		removeHooks()
		print("[Layout] activation impossible : " .. tostring(err))
	end
end

local function deactivate()
	if not active then
		return
	end
	active = false
	pcall(function()
		removeHooks()
		destroyWebView()
		resetAlignment()
		gui.clearGraphics("client")
		client.SetClientExtraPadding(0, 0, 0, 0)
	end)
end

function LayoutPrototype.isActive()
	return active
end

function LayoutPrototype.widgetsAreHtml()
	return anyZoneShown()
end

--- Etat interne d'une zone (« left » / « right »), pour les tests et le debogage.
function LayoutPrototype.debugZone(name)
	return zones[name]
end

--- Zones actuellement affichees (« left,right »), pour les tests.
function LayoutPrototype.shownZones()
	local shown = {}
	for _, name in ipairs(ZONE_ORDER) do
		if zones[name].control ~= nil then
			shown[#shown + 1] = name .. "=" .. tostring(zones[name].bounds)
		end
	end
	return table.concat(shown, " ")
end

--- Change un reglage, le sauvegarde et l'applique tout de suite.
function LayoutPrototype.setOption(key, value)
	local options = LayoutPrototype.Options
	if options[key] == nil then
		return
	end
	options[key] = value
	LayoutPrototype.saveSettings()
	if key == "Enabled" then
		if value then
			activate()
		else
			deactivate()
		end
		return
	end
	if not active then
		return
	end
	pcall(function()
		if key == "Background" then
			background = loadBackground()
		elseif key:match("^Margin") or key == "GameAlign" then
			resetAlignment()
			applyMargins()
		elseif key == "WidgetUrl" or (key == "Widgets" and value) then
			destroyWebView()
			webFailed = false
		elseif ZONE_OPTION.left == key or ZONE_OPTION.right == key or ZONE_OPTION.bottom == key
			or key == "Theme" or key == "Accent" then
			-- L'appli recoit widgets/theme/couleur dans l'URL : on rouvre les zones concernees.
			for _, name in ipairs(ZONE_ORDER) do
				local zone = zones[name]
				local affected = key == "Theme" or key == "Accent" or ZONE_OPTION[name] == key
				if affected and zone.mode == "app" and zone.navigate and zoneWidgets(zone) ~= "" then
					connectZone(zone)
				end
				zone.lastState = nil
			end
		end
		appliedSignature = nil
	end)
end

--- Zone d'un widget d'IronMonStats : "left", "right", "bottom" ou nil (masque).
function LayoutPrototype.widgetPlacement(key)
	local options = LayoutPrototype.Options
	for _, name in ipairs(ZONE_ORDER) do
		if ("," .. options[ZONE_OPTION[name]] .. ","):find("," .. key .. ",", 1, true) ~= nil then
			return name
		end
	end
	return nil
end

--- Fait passer un widget de gauche -> droite -> bas -> masque -> gauche.
function LayoutPrototype.cycleWidget(key)
	local nextPlacement = ({ left = "right", right = "bottom", bottom = "none" })[LayoutPrototype.widgetPlacement(key) or "none"] or "left"
	local function listFor(placement)
		local list = {}
		for _, choice in ipairs(LayoutPrototype.WIDGET_CHOICES) do
			local current = choice.key == key and nextPlacement or LayoutPrototype.widgetPlacement(choice.key)
			if current == placement then
				list[#list + 1] = choice.key
			end
		end
		return table.concat(list, ",")
	end
	for _, name in ipairs(ZONE_ORDER) do
		local list = listFor(name)
		if list ~= LayoutPrototype.Options[ZONE_OPTION[name]] then
			LayoutPrototype.setOption(ZONE_OPTION[name], list)
		end
	end
end

function LayoutPrototype.initialize(program, settings)
	programRef = program
	settingsRef = settings
	LayoutPrototype.Program = program
	LayoutPrototype.loadSettings()
	if LayoutPrototype.Options.Enabled then
		activate()
	end
end

--- Remet BizHawk dans son etat normal a la fermeture du tracker.
function LayoutPrototype.shutdown()
	deactivate()
end

return LayoutPrototype
