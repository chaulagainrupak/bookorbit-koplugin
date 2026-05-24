--[[
    settings.lua

    Persists BookOrbit config to <koreader>/settings/bookorbit_settings.lua

    Auth model (KOSync-compatible):
        X-Auth-User: <username>
        X-Auth-Key:  md5(<password>)   ← computed on save, plain text never stored
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local md5         = require("ffi/sha2").md5

local PATH        = DataStorage:getSettingsDir() .. "/bookorbit_settings.lua"

local S           = {}

local function store() return LuaSettings:open(PATH) end
local function get(k, d)
    local v = store():readSetting(k); return v ~= nil and v or d
end
local function set(k, v)
    local s = store(); s:saveSetting(k, v); s:flush()
end

function S.getServerURL() return get("server_url", "") end

function S.getUsername() return get("username", "") end

function S.getAuthKey() return get("auth_key", "") end -- md5(password)

function S.getLastSync() return get("last_sync", 0) end

function S.getSyncOnClose() return get("sync_on_close", true) end

function S.getSyncOnSuspend() return get("sync_on_suspend", true) end

function S.getPageThreshold() return get("page_threshold", 0) end     -- 0 = off

function S.getMinuteThreshold() return get("minute_threshold", 0) end -- 0 = off

function S.getSessionStartTime() return get("session_start_time", os.time()) end

function S.setServerURL(url)
    if url ~= "" and url:sub(-1) == "/" then url = url:sub(1, -2) end
    set("server_url", url)
end

function S.setCredentials(username, password)
    set("username", username)
    set("auth_key", md5(password))
end

function S.setLastSync(ts) set("last_sync", ts) end

function S.setSyncOnClose(v) set("sync_on_close", v) end

function S.setSyncOnSuspend(v) set("sync_on_suspend", v) end

function S.setPageThreshold(v) set("page_threshold", v) end

function S.setMinuteThreshold(v) set("minute_threshold", v) end

function S.setSessionStartTime(ts) set("session_start_time", ts) end

function S.isConfigured()
    return S.getServerURL() ~= "" and S.getUsername() ~= "" and S.getAuthKey() ~= ""
end

return S
