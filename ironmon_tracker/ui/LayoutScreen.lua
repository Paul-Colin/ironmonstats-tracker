-- Ecran de reglages du layout (fond, marges, bordures, widgets).
-- Modele : LiveConnectScreen. Accessible depuis Extras > Layout.
-- Chaque clic applique le reglage tout de suite (LayoutPrototype.setOption).
local function LayoutScreen(initialSettings, initialTracker, initialProgram)
    local Frame = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/Frame.lua")
    local Box = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/Box.lua")
    local Component = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/Component.lua")
    local TextLabel = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/TextLabel.lua")
    local TextField = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/TextField.lua")
    local TextStyle = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/TextStyle.lua")
    local Layout = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/Layout.lua")
    local MouseClickEventListener = dofile(Paths.FOLDERS.UI_BASE_CLASSES .. "/MouseClickEventListener.lua")
    local program = initialProgram
    local constants = {
        MAIN_FRAME_HEIGHT = 381,
        BOTTOM_FRAME_HEIGHT = 24,
        TEXT_HEADER_HEIGHT = 18,
        SETTINGS_FRAME_HEIGHT = 325,
        ROW_HEIGHT = 16,
        VALUE_ROW_HEIGHT = 13,
        LABEL_WIDTH = 66,
        SMALL_BUTTON_HEIGHT = 14,
        MARGIN_STEP = 20,
        MARGIN_MAX = 900,
        VALUE_MAX_CHARS = 26,
        OPACITY_STEP = 10,
        OPACITY_MIN = 20
    }
    -- Couleurs proposees pour les bordures / l'accent des widgets (cycle au clic).
    local BORDER_COLORS = {
        {name = "Blanc", hex = "FFFFFF"},
        {name = "Noir", hex = "14182A"},
        {name = "Or", hex = "E0C060"},
        {name = "Rouge", hex = "EE3A3A"},
        {name = "Bleu", hex = "2A75BB"}
    }
    local ACCENT_COLORS = {
        {name = "Appli", hex = ""}, -- couleur choisie dans les preferences IronMonStats
        {name = "Rouge", hex = "EE3A3A"},
        {name = "Or", hex = "E8B923"},
        {name = "Bleu", hex = "2A75BB"},
        {name = "Vert", hex = "34C759"},
        {name = "Violet", hex = "8B5CF6"}
    }
    local ui = {}
    local eventListeners = {}
    local self = {}

    local function textStyle()
        return TextStyle(
            Graphics.FONT.DEFAULT_FONT_SIZE,
            Graphics.FONT.DEFAULT_FONT_FAMILY,
            "Top box text color",
            "Top box background color"
        )
    end

    local function redraw()
        self.refresh()
        program.drawCurrentScreens()
    end

    local function setOption(key, value)
        LayoutPrototype.setOption(key, value)
        redraw()
    end

    local function onGoBackClick()
        program.setCurrentScreens({program.UI_SCREENS.EXTRAS_SCREEN})
        program.drawCurrentScreens()
    end

    local function colorName(list, hex)
        for _, color in ipairs(list) do
            if color.hex == hex then
                return color.name
            end
        end
        return "#" .. tostring(hex)
    end

    local function nextColor(list, hex)
        for index, color in ipairs(list) do
            if color.hex == hex then
                return list[index % #list + 1].hex
            end
        end
        return list[1].hex
    end

    local function backgroundName()
        local name = tostring(LayoutPrototype.Options.Background or ""):match("([^/\\]+)$") or "(aucune)"
        if #name > constants.VALUE_MAX_CHARS then
            name = name:sub(1, constants.VALUE_MAX_CHARS - 3) .. "..."
        end
        return name
    end

    local function onChooseBackgroundClick()
        local soundOn = client.GetSoundOn()
        client.SetSoundOn(false)
        local folder = Paths.CURRENT_DIRECTORY .. Paths.SLASH .. "ironmon_tracker" .. Paths.SLASH .. "images" .. Paths.SLASH .. "layout" .. Paths.SLASH
        local path = forms.openfile("", folder, "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp")
        client.SetSoundOn(soundOn)
        if path ~= nil and path ~= "" then
            setOption("Background", path)
        end
    end

    local function changeMargin(key, delta)
        local value = (LayoutPrototype.Options[key] or 0) + delta
        value = math.max(0, math.min(constants.MARGIN_MAX, value))
        setOption(key, value)
    end

    local function changeOpacity(delta)
        local value = (LayoutPrototype.Options.TrackerOpacity or 100) + delta
        setOption("TrackerOpacity", math.max(constants.OPACITY_MIN, math.min(100, value)))
    end

    function self.refresh()
        local options = LayoutPrototype.Options
        ui.controls.enabledButton.setText(options.Enabled and "Désactiver" or "Activer")
        ui.controls.statusText.setText(options.Enabled and "Actif" or "Inactif")
        ui.controls.statusText.setTextColorKey(options.Enabled and "Positive text color" or "Intermediate text color")
        ui.controls.backgroundValue.setText(backgroundName())
        ui.controls.MarginLeft.setText(tostring(options.MarginLeft))
        ui.controls.MarginRight.setText(tostring(options.MarginRight))
        ui.controls.MarginTop.setText(tostring(options.MarginTop))
        ui.controls.MarginBottom.setText(tostring(options.MarginBottom))
        ui.controls.borderButton.setText(options.Border and "Oui" or "Non")
        ui.controls.borderColorButton.setText(colorName(BORDER_COLORS, options.BorderColor))
        ui.controls.opacityValue.setText(tostring(options.TrackerOpacity or 100) .. "%")
        ui.controls.widgetsButton.setText(options.Widgets and "Oui" or "Non")
        ui.controls.themeButton.setText(({glass = "Verre", dark = "Sombre", light = "Clair"})[options.Theme] or "Verre")
        ui.controls.alignButton.setText(options.GameAlign == "left" and "Gauche" or "Centre")
        ui.controls.accentButton.setText(colorName(ACCENT_COLORS, options.Accent))
        for key, toggle in pairs(ui.controls.widgetToggles) do
            local placement = LayoutPrototype.widgetPlacement(key)
            toggle.setText(({left = "Gauche", right = "Droite", bottom = "Bas"})[placement] or "Non")
        end
    end

    local function createRow()
        return Frame(
            Box({x = 0, y = 0}, {width = 0, height = constants.ROW_HEIGHT}),
            Layout(Graphics.ALIGNMENT_TYPE.HORIZONTAL, 3),
            ui.frames.settingsFrame
        )
    end

    local function createLabel(parentFrame, text, width)
        return TextLabel(
            Component(parentFrame, Box({x = 0, y = 0}, {width = width, height = 0}, nil, nil, false)),
            TextField(text, {x = 0, y = 1}, textStyle())
        )
    end

    local function createButton(parentFrame, text, width, onClick, ...)
        local button =
            TextLabel(
            Component(
                parentFrame,
                Box(
                    {x = 0, y = 0},
                    {width = width, height = constants.SMALL_BUTTON_HEIGHT},
                    "Top box background color",
                    "Top box border color",
                    true,
                    "Top box background color"
                )
            ),
            TextField(text, {x = 3, y = 1}, textStyle())
        )
        table.insert(eventListeners, MouseClickEventListener(button, onClick, ...))
        return button
    end

    -- « Libellé   [-] valeur [+] »
    local function createMarginRow(labelText, key)
        local row = createRow()
        createLabel(row, labelText, constants.LABEL_WIDTH)
        createButton(row, "-", 12, function() changeMargin(key, -constants.MARGIN_STEP) end)
        ui.controls[key] = createLabel(row, "0", 24)
        createButton(row, "+", 12, function() changeMargin(key, constants.MARGIN_STEP) end)
    end

    -- « Libellé   [bouton] »
    local function createButtonRow(labelText, buttonWidth, onClick)
        local row = createRow()
        createLabel(row, labelText, constants.LABEL_WIDTH)
        return createButton(row, "", buttonWidth, onClick), row
    end

    local function createSettingsFrame()
        ui.frames.settingsFrame =
            Frame(
            Box(
                {x = Graphics.SIZES.SCREEN_WIDTH, y = 0},
                {
                    width = Graphics.SIZES.MAIN_SCREEN_WIDTH - 2 * Graphics.SIZES.BORDER_MARGIN,
                    height = constants.SETTINGS_FRAME_HEIGHT
                },
                "Top box background color",
                "Top box border color"
            ),
            Layout(Graphics.ALIGNMENT_TYPE.VERTICAL, 1, {x = Graphics.SIZES.BORDER_MARGIN, y = 5}),
            ui.frames.mainFrame
        )

        local stateRow = createRow()
        ui.controls.statusText = createLabel(stateRow, "Inactif", constants.LABEL_WIDTH)
        ui.controls.enabledButton =
            createButton(
            stateRow,
            "Activer",
            52,
            function()
                setOption("Enabled", not LayoutPrototype.Options.Enabled)
            end
        )

        local backgroundRow = createRow()
        createLabel(backgroundRow, "Image de fond", constants.LABEL_WIDTH)
        createButton(backgroundRow, "Choisir", 36, onChooseBackgroundClick)
        ui.controls.backgroundValue =
            TextLabel(
            Component(
                ui.frames.settingsFrame,
                Box({x = 0, y = 0}, {width = 0, height = constants.VALUE_ROW_HEIGHT}, nil, nil, false)
            ),
            TextField("", {x = 4, y = 0}, textStyle())
        )

        createMarginRow("Marge gauche", "MarginLeft")
        createMarginRow("Marge droite", "MarginRight")
        createMarginRow("Marge haut", "MarginTop")
        createMarginRow("Marge bas", "MarginBottom")

        -- « Bordures [Oui] [Couleur] » sur une seule ligne.
        local borderRow
        ui.controls.borderButton, borderRow =
            createButtonRow(
            "Bordures",
            26,
            function()
                setOption("Border", not LayoutPrototype.Options.Border)
            end
        )
        ui.controls.borderColorButton =
            createButton(
            borderRow,
            "",
            34,
            function()
                setOption("BorderColor", nextColor(BORDER_COLORS, LayoutPrototype.Options.BorderColor))
            end
        )
        -- Opacite des fonds du tracker : « [-] 100% [+] » (fond flou de l'image dessous).
        local opacityRow = createRow()
        createLabel(opacityRow, "Opacité trk.", constants.LABEL_WIDTH)
        createButton(opacityRow, "-", 12, function() changeOpacity(-constants.OPACITY_STEP) end)
        ui.controls.opacityValue = createLabel(opacityRow, "100%", 24)
        createButton(opacityRow, "+", 12, function() changeOpacity(constants.OPACITY_STEP) end)
        ui.controls.widgetsButton =
            createButtonRow(
            "Widgets",
            26,
            function()
                setOption("Widgets", not LayoutPrototype.Options.Widgets)
            end
        )
        ui.controls.themeButton =
            createButtonRow(
            "Thème widgets",
            40,
            function()
                local nextTheme = {glass = "light", light = "dark", dark = "glass"}
                setOption("Theme", nextTheme[LayoutPrototype.Options.Theme] or "glass")
            end
        )
        ui.controls.alignButton =
            createButtonRow(
            "Position jeu",
            40,
            function()
                setOption("GameAlign", LayoutPrototype.Options.GameAlign == "left" and "center" or "left")
            end
        )
        ui.controls.accentButton =
            createButtonRow(
            "Couleur widg.",
            40,
            function()
                setOption("Accent", nextColor(ACCENT_COLORS, LayoutPrototype.Options.Accent))
            end
        )
        -- Un bouton par widget d'IronMonStats : Gauche -> Droite (colonne) -> Bas
        -- (sous le tracker) -> Non.
        ui.controls.widgetToggles = {}
        for _, choice in ipairs(LayoutPrototype.WIDGET_CHOICES) do
            ui.controls.widgetToggles[choice.key] =
                createButtonRow(
                choice.label,
                40,
                function()
                    LayoutPrototype.cycleWidget(choice.key)
                    redraw()
                end
            )
        end
    end

    local function initUI()
        ui.controls = {}
        ui.frames = {}
        ui.frames.mainFrame =
            Frame(
            Box(
                {x = Graphics.SIZES.SCREEN_WIDTH, y = 0},
                {width = Graphics.SIZES.MAIN_SCREEN_WIDTH, height = constants.MAIN_FRAME_HEIGHT},
                "Main background color",
                nil
            ),
            Layout(Graphics.ALIGNMENT_TYPE.VERTICAL, 0, {x = Graphics.SIZES.BORDER_MARGIN, y = Graphics.SIZES.BORDER_MARGIN}),
            nil
        )
        TextLabel(
            Component(
                ui.frames.mainFrame,
                Box(
                    {x = 5, y = 5},
                    {
                        width = Graphics.SIZES.MAIN_SCREEN_WIDTH - 2 * Graphics.SIZES.BORDER_MARGIN,
                        height = constants.TEXT_HEADER_HEIGHT
                    },
                    "Top box background color",
                    "Top box border color",
                    false
                )
            ),
            TextField(
                "Layout",
                {x = 50, y = 1},
                TextStyle(13, Graphics.FONT.DEFAULT_FONT_FAMILY, "Top box text color", "Top box background color")
            )
        )
        createSettingsFrame()
        ui.frames.goBackFrame =
            Frame(
            Box(
                {x = Graphics.SIZES.SCREEN_WIDTH, y = 0},
                {
                    width = Graphics.SIZES.MAIN_SCREEN_WIDTH - 2 * Graphics.SIZES.BORDER_MARGIN,
                    height = constants.BOTTOM_FRAME_HEIGHT
                },
                "Top box background color",
                "Top box border color"
            ),
            Layout(Graphics.ALIGNMENT_TYPE.HORIZONTAL, 60, {x = 100, y = Graphics.SIZES.BORDER_MARGIN}),
            ui.frames.mainFrame
        )
        local goBackButton =
            TextLabel(
            Component(
                ui.frames.goBackFrame,
                Box(
                    {x = 0, y = 0},
                    {width = 40, height = 14},
                    "Top box background color",
                    "Top box border color",
                    true,
                    "Top box background color"
                )
            ),
            TextField("Retour", {x = 3, y = 1}, textStyle())
        )
        table.insert(eventListeners, MouseClickEventListener(goBackButton, onGoBackClick))
    end

    function self.initialize()
        self.refresh()
        program.drawCurrentScreens()
    end

    function self.runEventListeners()
        for _, eventListener in pairs(eventListeners) do
            eventListener.listen()
        end
    end

    function self.show()
        self.refresh()
        ui.frames.mainFrame.show()
    end

    initUI()
    return self
end

return LayoutScreen
