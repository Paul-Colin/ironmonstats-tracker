-- Ecran de configuration LiveConnect (connexion a l'app IronMonStats).
-- Modele : StreamerbotConfigScreen. Accessible depuis Extras > IronMonStats.
-- L'URL et le token se collent via une popup WinForms (forms.textbox), le token
-- etant genere depuis la page Profil de l'application web.
local function LiveConnectScreen(initialSettings, initialTracker, initialProgram)
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
        MAIN_FRAME_HEIGHT = 212,
        BOTTOM_FRAME_HEIGHT = 24,
        TEXT_HEADER_HEIGHT = 18,
        SETTINGS_FRAME_HEIGHT = 156,
        ROW_HEIGHT = 16,
        VALUE_ROW_HEIGHT = 13,
        SET_BUTTON_WIDTH = 34,
        SMALL_BUTTON_HEIGHT = 14,
        VALUE_MAX_CHARS = 24
    }
    local ui = {}
    local eventListeners = {}
    local self = {}

    local function onGoBackClick()
        program.setCurrentScreens({ program.UI_SCREENS.EXTRAS_SCREEN })
        program.drawCurrentScreens()
    end

    -- Tronque une valeur pour l'affichage dans le panneau (150px de large).
    local function shorten(value)
        if value == nil or value == "" then
            return "(non défini)"
        end
        value = tostring(value)
        if #value > constants.VALUE_MAX_CHARS then
            return value:sub(1, constants.VALUE_MAX_CHARS - 3) .. "..."
        end
        return value
    end

    local function maskedToken()
        local token = LiveConnect.Options.Token or ""
        if token == "" then
            return "(non défini)"
        end
        return "Défini (****" .. token:sub(-4) .. ")"
    end

    -- Popup WinForms avec un champ texte (collable au clavier/souris) + bouton OK.
    local function promptForText(title, currentValue, onSet)
        local width, height = 380, 74
        forms.destroyall()
        local form = forms.newform(width, height, title, function() end)
        local textBox = forms.textbox(form, currentValue or "", 290, 0, nil, 5, 8)
        forms.button(
            form,
            "OK",
            function()
                onSet(forms.gettext(textBox))
                forms.destroy(form)
                self.refresh()
                program.drawCurrentScreens()
            end,
            300,
            6,
            48,
            22
        )
        local center = FormsUtils.getCenter(width, height)
        forms.setlocation(form, center.xPos, center.yPos)
        forms.setproperty(textBox, "TabStop", true)
    end

    local function onSetUrlClick()
        promptForText("URL de l'application (ex: https://mon-app.fr)", LiveConnect.Options.AppUrl, LiveConnect.setAppUrl)
    end

    local function onSetTokenClick()
        promptForText("Token d'accès (page Profil de l'application)", "", LiveConnect.setToken)
    end

    local function onTestClick()
        LiveConnect.requestPing()
        self.refresh()
        program.drawCurrentScreens()
    end

    local function onToggleEnabledClick()
        LiveConnect.toggleEnabled()
        self.refresh()
        program.drawCurrentScreens()
    end

    function self.refresh()
        local statusText, colorKey = LiveConnect.getStatus()
        ui.controls.statusText.setText(statusText)
        ui.controls.statusText.setTextColorKey(colorKey)
        ui.controls.urlValue.setText(shorten(LiveConnect.Options.AppUrl))
        ui.controls.tokenValue.setText(maskedToken())
        if LiveConnect.Options.Enabled then
            ui.controls.enabledButton.setText("Couper l'envoi")
        else
            ui.controls.enabledButton.setText("Activer l'envoi")
        end
    end

    -- Une ligne "libellé + bouton Définir" suivie d'une ligne valeur.
    local function createSettingRow(labelText, onSetClick)
        local rowFrame =
            Frame(
            Box({x = 0, y = 0}, {width = 0, height = constants.ROW_HEIGHT}),
            Layout(Graphics.ALIGNMENT_TYPE.HORIZONTAL),
            ui.frames.settingsFrame
        )
        TextLabel(
            Component(rowFrame, Box({x = 0, y = 0}, {width = 92, height = 0}, nil, nil, false)),
            TextField(
                labelText,
                {x = 0, y = 1},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        local setButton =
            TextLabel(
            Component(
                rowFrame,
                Box(
                    {x = 0, y = 0},
                    {width = constants.SET_BUTTON_WIDTH, height = constants.SMALL_BUTTON_HEIGHT},
                    "Top box background color",
                    "Top box border color",
                    true,
                    "Top box background color"
                )
            ),
            TextField(
                "Définir",
                {x = 3, y = 1},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        table.insert(eventListeners, MouseClickEventListener(setButton, onSetClick))
        local valueLabel =
            TextLabel(
            Component(
                ui.frames.settingsFrame,
                Box({x = 0, y = 0}, {width = 0, height = constants.VALUE_ROW_HEIGHT}, nil, nil, false)
            ),
            TextField(
                "",
                {x = 4, y = 0},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        return valueLabel
    end

    local function createActionButton(parentFrame, text, width, onClick)
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
            TextField(
                text,
                {x = 4, y = 1},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        table.insert(eventListeners, MouseClickEventListener(button, onClick))
        return button
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
            Layout(Graphics.ALIGNMENT_TYPE.VERTICAL, 2, {x = Graphics.SIZES.BORDER_MARGIN, y = 7}),
            ui.frames.mainFrame
        )
        TextLabel(
            Component(
                ui.frames.settingsFrame,
                Box({x = 0, y = 0}, {width = 86, height = constants.TEXT_HEADER_HEIGHT - 6})
            ),
            TextField(
                "État de la connexion:",
                {x = -1, y = -1},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        ui.controls.statusText =
            TextLabel(
            Component(
                ui.frames.settingsFrame,
                Box(
                    {x = 0, y = 0},
                    {
                        width = Graphics.SIZES.MAIN_SCREEN_WIDTH - 2 * Graphics.SIZES.BORDER_MARGIN,
                        height = constants.TEXT_HEADER_HEIGHT - 2
                    },
                    nil,
                    nil,
                    false
                )
            ),
            TextField(
                "Non configuré",
                {x = 3, y = 0},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
        )
        ui.controls.urlValue = createSettingRow("URL de l'app", onSetUrlClick)
        ui.controls.tokenValue = createSettingRow("Token d'accès", onSetTokenClick)
        local actionsFrame =
            Frame(
            Box({x = 0, y = 0}, {width = 0, height = constants.ROW_HEIGHT + 4}),
            Layout(Graphics.ALIGNMENT_TYPE.HORIZONTAL, 6, {x = 0, y = 4}),
            ui.frames.settingsFrame
        )
        createActionButton(actionsFrame, "Tester", 40, onTestClick)
        ui.controls.enabledButton = createActionButton(actionsFrame, "Activer l'envoi", 78, onToggleEnabledClick)
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
                "IronMonStats",
                {x = 14, y = 1},
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
            TextField(
                "Retour",
                {x = 3, y = 1},
                TextStyle(
                    Graphics.FONT.DEFAULT_FONT_SIZE,
                    Graphics.FONT.DEFAULT_FONT_FAMILY,
                    "Top box text color",
                    "Top box background color"
                )
            )
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

return LiveConnectScreen
