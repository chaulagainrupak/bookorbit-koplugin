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

http.TIMEOUT = 15 -- don't hang forever

local function headers()
    return {
        ["X-Auth-User"]  = S.getUsername(),
        ["X-Auth-Key"]   = S.getAuthKey(),
        ["Content-Type"] = "application/json",
        ["Accept"]       = "application/json",
    }
end

local function request(method, path, body_tbl)
    local url = S.getServerURL() .. path
    local body = body_tbl and json.encode(body_tbl) or ""
    local hdrs = headers()
    hdrs["Content-Length"] = tostring(#body)

    local chunks = {}

    local res, code, response_headers, status = http.request({
        url     = url,
        method  = method,
        source  = ltn12.source.string(body),
        headers = hdrs,
        sink    = ltn12.sink.table(chunks),
    })

    if not res then
        logger.warn("BookOrbit NETWORK ERROR: " .. tostring(code))
        return false, nil, "Network error: " .. tostring(code)
    end

    local raw = table.concat(chunks)

    local resp = nil
    if raw ~= "" then
        local ok, decoded = pcall(json.decode, raw)
        if ok then
            resp = decoded
        else
            logger.warn("BookOrbit: response is not valid JSON")
        end
    end

    if code < 200 or code >= 300 then
        return false, resp, "HTTP " .. tostring(code) .. ": " .. tostring(raw)
    end

    return true, resp, nil
end


function API.get(path) return request("GET", path, nil) end

function API.post(path, body) return request("POST", path, body) end

function API.put(path, body) return request("PUT", path, body) end

return API
