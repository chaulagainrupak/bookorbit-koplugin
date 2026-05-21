local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local md5 = require("ffi/sha2").md5
local CustomUtils = require("utils")

local InfoMessage = require("ui/widget/infomessage")

local T = require("ffi/util").template


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
            },
            {
                text_func = function()
                    return self.settings:readSetting("userkey") and _("Logout") or _("Login")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self.settings:readSetting("userkey") then
                        self:logout(touchmenu_instance)
                    else
                        self:login(touchmenu_instance)
                    end
                end,
                separator = true,
            }
        }
    }
end

function BookOrbit:setCustomServer(server)
    logger.dbg("BookOrbit: Setting custom server to:", server)
    self.settings:saveSetting("custom_server", server)
    self.settings:flush()
end

function BookOrbit:setLoginDetails(username, password)
    logger.dbg("BookOrbit: Setting username to:", username)
    self.settings:saveSetting("username", username)
    logger.dbg("BookOrbit: Setting password to:", md5(password))
    self.settings:saveSetting("password", md5(password))

    self.settings:flush()
end

function BookOrbit:getCustomServerAddress()
    return self.settings:readSetting("custom_server", "https://")
end

function BookOrbit:login(touchmenu_instance)
    if NetworkMgr:willRerunWhenOnline(function() self:login(touchmenu_instance) end) then
        return
    end

    local saved_user = tostring(self.settings:readSetting("username") or "")
    local saved_pass = tostring(self.settings:readSetting("password") or "")

    self._login_dialog = MultiInputDialog:new {
        title = _("BookOrbit Login"),
        fields = {
            {
                description = _("Username"),
                text = saved_user,
                hint = _("Enter username"),
            },
            {
                description = _("Password"),
                text = saved_pass,
                hint = _("Enter password"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self._login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    callback = function()
                        local fields = self._login_dialog:getFields()
                        local username = fields[1]
                        local password = fields[2]
                        local ok, err = CustomUtils.ValidateUser(username, password)
                        if not ok then
                            UIManager:show(InfoMessage:new {
                                text = T(_("Cannot login: %1"), err),
                                timeout = 2,
                            })
                        else
                            UIManager:scheduleIn(0.5, self:setLoginDetails(username or "", password or ""))
                            UIManager:show(InfoMessage:new {
                                text = _("Logging in. Please wait…"),
                                timeout = 1,
                            })
                            self:setLoginDetails(username or "", password or "")
                        end
                    end
                }
            }
        }
    }

    UIManager:show(self._login_dialog)
    self._login_dialog:onShowKeyboard()
end

return BookOrbit
