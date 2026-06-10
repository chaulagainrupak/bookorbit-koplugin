local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local UIManager        = require("ui/uimanager")
local InfoMessage      = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local SpinWidget       = require("ui/widget/spinwidget")
local ConfirmBox       = require("ui/widget/confirmbox")
local NetworkMgr       = require("ui/network/manager")
local Notification     = require("ui/widget/notification")
local _                = require("gettext")
local T                = require("ffi/util").template
local logger           = require("logger")

local S                = require("settings")
local Sync             = require("sync")


local BookOrbit         = WidgetContainer:extend {
    name        = "bookorbit",
    is_doc_only = false,
}

-- per-session counters (reset on book open / after sync)
local _pages_since_sync = 0
local _session_start    = os.time()
local _tick_in_flight   = false   -- prevents stacking auto-sync triggers
local _last_tick_time   = 0       -- unix time of last auto-sync dispatch


function BookOrbit:init()
    self.ui.menu:registerToMainMenu(self)

    if NetworkMgr.subscribeToNetworkConnected then
        local ui = self.ui
        NetworkMgr:subscribeToNetworkConnected(function()
            Sync.onNetworkUp(ui)
        end)
    end
end

function BookOrbit:onReaderReady()
    _pages_since_sync = 0
    _session_start    = os.time()
    _tick_in_flight   = false
    _last_tick_time   = 0
    S.setSessionStartTime(_session_start)
end

function BookOrbit:onCloseDocument()
    Sync.onBookClose(self.ui)
    _pages_since_sync = 0
    _session_start    = os.time()
end

function BookOrbit:onSuspend()
    Sync.onSuspend(self.ui)
end

function BookOrbit:onPageUpdate()
    _pages_since_sync = _pages_since_sync + 1
    local now  = os.time()
    local mins = (now - _session_start) / 60

    -- don't stack auto-syncs: skip if one is already in flight or fired < 30s ago
    if _tick_in_flight then return end
    if (now - _last_tick_time) < 30 then return end

    local page_due = S.getPageThreshold() > 0 and _pages_since_sync >= S.getPageThreshold()
    local min_due  = S.getMinuteThreshold() > 0 and mins >= S.getMinuteThreshold()
    if not (page_due or min_due) then return end

    _tick_in_flight = true
    _last_tick_time = now
    logger.info("BookOrbit: auto-sync trigger (pages=" .. _pages_since_sync
        .. " mins=" .. string.format("%.1f", mins) .. ")")

    -- Build a live session record for the current book so the stats payload
    -- has real page_sessions even before KOReader flushes to SQLite.
    local live_session = nil
    if self.ui and self.ui.document then
        local page = 0
        if self.ui.paging and self.ui.paging.current_page then
            page = self.ui.paging.current_page
        elseif self.ui.rolling and self.ui.rolling.current_page then
            page = self.ui.rolling.current_page
        end
        live_session = {
            start_time  = _session_start,
            duration    = now - _session_start,
            page        = page,
            total_pages = (self.ui.document.getPageCount
                and self.ui.document:getPageCount()) or 0,
        }
    end

    Sync.tick(self.ui, function(results)
        _tick_in_flight   = false
        _pages_since_sync = 0
        _session_start    = os.time()
        S.setSessionStartTime(_session_start)
    end, live_session)
end

function BookOrbit:_runSync(full, silent)
    if not S.isConfigured() then
        self:_notify(_(
            "BookOrbit is not configured. Please set your server URL, username, and password first."
        ), true)
        return
    end

    if not full and S.getLastSync() == 0 then
        self:_notify(_(
            "Initial sync is required before delta syncing. Please run Full sync once to upload your reading history."
        ), true)
        return
    end

    local history = require("readhistory")
    if #(history.hist or {}) == 0 and not self.ui.document then
        self:_notify(_(
            "No reading activity found yet. Open a book and read a few pages before syncing."
        ))
        return
    end

    NetworkMgr:runWhenOnline(function()
        if not silent then
            UIManager:show(Notification:new { text = _("BookOrbit: syncing in background…") })
        end

        local self_ref = self
        local function on_done(results)
            _pages_since_sync = 0
            _session_start    = os.time()
            S.setSessionStartTime(_session_start)

            if silent then return end
            if #results == 0 then return end

            local all_ok = true
            for _, r in ipairs(results) do
                if not r.ok then all_ok = false; break end
            end

            local lines = {}
            for _, r in ipairs(results) do
                lines[#lines + 1] = (r.ok and "✓ " or "✗ ")
                    .. r.label .. " (" .. (r.count or 0) .. ")"
                    .. (r.err and "\n   " .. r.err or "")
            end

            if all_ok then
                self_ref:_notify(_("Sync complete.\n\n") .. table.concat(lines, "\n"))
            else
                self_ref:_notify(_("Sync finished with errors.\n\n") .. table.concat(lines, "\n"), true)
            end
        end

        if full then
            Sync.full(self.ui, on_done)
        else
            Sync.delta(self.ui, on_done)
        end
    end)
end

function BookOrbit:_notify(text, warn)
    UIManager:show(InfoMessage:new {
        text = text,
        icon = warn and "notice-warning" or nil,
    })
end

function BookOrbit:openConfig()
    local dlg
    dlg = MultiInputDialog:new {
        title   = _("BookOrbit – Configure"),
        fields  = {
            {
                description = _("Server URL   (e.g. http://192.168.1.50:5000)"),
                text        = S.getServerURL(),
                hint        = _("http://server:port"),
            },
            {
                description = _("Username"),
                text        = S.getUsername(),
                hint        = _("your username"),
            },
            {
                description = _("Password   (stored as md5 – leave blank to keep current)"),
                text        = "",
                hint        = _("password"),
                text_type   = "password",
            },
        },
        buttons = { {
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text     = _("Save"),
                callback = function()
                    local f = dlg:getFields()
                    local url, user, pass = f[1], f[2], f[3]

                    S.setServerURL(url)
                    if pass ~= "" then S.setCredentials(user, pass) end
                    UIManager:close(dlg)

                    if S.getLastSync() == 0 and S.isConfigured() then
                        UIManager:show(ConfirmBox:new {
                            text        = _("Credentials saved.\n\nSend all reading data to BookOrbit now?"),
                            ok_text     = _("Sync now"),
                            ok_callback = function() self:_runSync(true, false) end,
                        })
                    else
                        self:_notify(_("Saved."))
                    end
                end,
            },
        } },
    }
    UIManager:show(dlg)
end

function BookOrbit:addToMainMenu(menu_items)
    menu_items.bookorbit = {
        text           = _("BookOrbit"),
        sorting_hint   = "setting",
        sub_item_table = {

            {
                text     = _("Sync now (delta)"),
                callback = function() self:_runSync(false, false) end,
            },
            {
                text     = _("Full sync — resend all reading history"),
                callback = function()
                    UIManager:show(ConfirmBox:new {
                        text        = _("This will resend all reading records to BookOrbit to rebuild your server history. This may take a while and could temporarily slow down your device. After confirmation the sync will continue in background"),
                        ok_text     = _("Run full sync"),
                        ok_callback = function() self:_runSync(true, false) end,
                    })
                end,
            },

            { text = _("Configure…"), callback = function() self:openConfig() end },

            {
                text           = _("Sync when closing a book"),
                checked_func   = function() return S.getSyncOnClose() end,
                callback       = function() S.setSyncOnClose(not S.getSyncOnClose()) end,
                keep_menu_open = true,
            },
            {
                text           = _("Sync when the device suspends"),
                checked_func   = function() return S.getSyncOnSuspend() end,
                callback       = function() S.setSyncOnSuspend(not S.getSyncOnSuspend()) end,
                keep_menu_open = true,
            },
            {
                text           = T(_("Auto-sync every %1 pages (0 = off)"), S.getPageThreshold()),
                callback       = function()
                    UIManager:show(SpinWidget:new {
                        value         = S.getPageThreshold(),
                        value_min     = 0,
                        value_max     = 500,
                        value_step    = 1,
                        default_value = 5,
                        title_text    = _("Pages between auto-sync"),
                        info_text     = _("Set to 0 to disable automatic page-based sync."),
                        callback      = function(spin) S.setPageThreshold(spin.value) end,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text           = T(_("Auto-sync every %1 minutes (0 = off)"), S.getMinuteThreshold()),
                callback       = function()
                    UIManager:show(SpinWidget:new {
                        value         = S.getMinuteThreshold(),
                        value_min     = 0,
                        value_max     = 240,
                        value_step    = 1,
                        default_value = 5,
                        title_text    = _("Minutes between auto-sync"),
                        info_text     = _("Set to 0 to disable automatic time-based sync."),
                        callback      = function(spin) S.setMinuteThreshold(spin.value) end,
                    })
                end,
                keep_menu_open = true,
            },

            {
                text     = _("Reset sync history"),
                callback = function()
                    UIManager:show(ConfirmBox:new {
                        text        = _("Clear last-sync timestamp?\nNext sync will re-send everything."),
                        ok_text     = _("Reset"),
                        ok_callback = function()
                            S.setLastSync(0)
                            self:_notify(_("History cleared."))
                        end,
                    })
                end,
            },
        },
    }
end

return BookOrbit
