local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local _ = require("gettext")
local BookOrbit = WidgetContainer:extend {
    title = _("BookOrbit"),
    description = _("KoReader plugin for syncing books and reading statistics to BookOrbit web-ui")
}

function BookOrbit:init()
    self.ui.menu:registerToMainMenu(self)

    self.settings = LuaSettings:open(
        ("%s/%s"):format(DataStorage:getSettingsDir(), "bookorbit_settings.lua")
    )
end

function BookOrbit:addToMainMenu(menu_items)
    menu_items.bookorbit = {
        text = "BookOrbit",
        sorting_hint = "setting",

        sub_item_table = {
            {
                text = _("Server Address"),
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        title = _("Custom statistics sync server address"),
                        input = self.settings:readSetting("custom_server", "https://"),
                        callback = function(input)
                            self:setCustomServer(input)
                        end,
                    }
                end
            }
        }
    }
end

function BookOrbit:setCustomServer(server)
    logger.dbg("BookOrbit: Setting custom server to:", server)
    self.settings:saveSetting("custom_server", server)
    self.settings:flush()

    self.settings.custom_server = server
end

function BookOrbit:getCustomServerAddress()
    self.settings:readSetting("custom_server", "https://")
end

return BookOrbit
