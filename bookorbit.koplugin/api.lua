--[[
    api.lua

    Thin HTTP wrapper.  Every request sends KOSync-protocol auth headers:
        X-Auth-User: <username>
        X-Auth-Key:  <md5(password)>

    Returns: ok (bool), decoded_body (table|nil), err (string|nil)
--]]

local http   = require("socket.http")
local ltn12  = require("ltn12")
local json   = require("rapidjson")
local logger = require("logger")
local S      = require("settings")

local API    = {}

local function headers()
    return {
        ["X-Auth-User"]  = S.getUsername(),
        ["X-Auth-Key"]   = S.getAuthKey(),
        ["Content-Type"] = "application/json",
        ["Accept"]       = "application/json",
    }
end

local function request(method, path, body_tbl)
    local url                  = S.getServerURL() .. path
    local body                 = body_tbl and json.encode(body_tbl) or ""
    local hdrs                 = headers()
    hdrs["Content-Length"]     = tostring(#body)

    local chunks               = {}
    local res, code, _, status = http.request({
        url     = url,
        method  = method,
        headers = hdrs,
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(chunks),
    })

    -- res is nil on connection failure, the status line string on success
    if not res then
        return false, nil, "Network error: " .. tostring(code)
    end

    local raw  = table.concat(chunks)
    local resp = nil
    if raw ~= "" then
        local dok, dec = pcall(json.decode, raw)
        if dok then resp = dec end
    end

    if code < 200 or code >= 300 then
        local msg = "HTTP " .. code
        if resp then msg = msg .. ": " .. (resp.error or resp.message or raw) end
        return false, resp, msg
    end

    return true, resp, nil
end


function API.get(path) return request("GET", path, nil) end

function API.post(path, body) return request("POST", path, body) end

function API.put(path, body) return request("PUT", path, body) end

return API
