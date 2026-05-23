--[[
    db.lua – BookOrbit local SQLite reader
    Uses KOReader's built-in SQ3 (ffi sqlite3 wrapper)
    same as statistics.koplugin does
--]]

local logger      = require("logger")
local DataStorage = require("datastorage")
local SQ3         = require("lua-ljsqlite3/init")
local json        = require("rapidjson")

local DB          = {}

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function getConn()
    local ok, conn = pcall(SQ3.open, dbPath())
    if not ok or not conn then
        logger.warn("BookOrbit: cannot open stats DB: " .. tostring(conn))
        return nil
    end
    return conn
end

-- rapidjson serialises an empty Lua table as {} (object).
-- Tagging it with the array metatable forces [].
local function empty_array()
    return json.array() -- rapidjson exposes this helper
end

function DB.isAvailable()
    local conn = getConn()
    if not conn then return false end
    conn:close()
    return true
end

function DB.getSessionsSince(since)
    local conn = getConn()
    if not conn then return nil end

    local cutoff       = math.max(0, since - 5)

    local rows_by_book = {}
    local book_meta    = {}

    local stmt         = conn:prepare(string.format([[
        SELECT
            b.id, b.md5, b.title, b.authors, b.pages,
            b.notes, b.highlights, b.total_read_time, b.total_read_pages,
            b.last_open,
            p.page, p.start_time, p.duration, p.total_pages
        FROM   page_stat_data p
        JOIN   book b ON b.id = p.id_book
        WHERE  p.start_time > %d
        ORDER  BY b.id, p.start_time ASC
    ]], cutoff))

    for row in stmt:rows() do
        local id_book = tonumber(row[1])


        if not book_meta[id_book] then
            book_meta[id_book] = {
                id               = id_book,
                md5              = row[2] or "",
                title            = row[3] or "",
                authors          = row[4] or "",
                pages            = tonumber(row[5]) or 0,
                notes            = tonumber(row[6]) or 0,
                highlights       = tonumber(row[7]) or 0,
                total_read_secs  = tonumber(row[8]) or 0,
                total_read_mins  = math.floor((tonumber(row[8]) or 0) / 60),
                total_read_pages = tonumber(row[9]) or 0,
                last_open        = tonumber(row[10]) or 0,
            }
            rows_by_book[id_book] = {}
        end
        rows_by_book[id_book][#rows_by_book[id_book] + 1] = {
            page        = tonumber(row[11]) or 0,
            start_time  = tonumber(row[12]) or 0,
            duration    = tonumber(row[13]) or 0,
            total_pages = tonumber(row[14]) or 0,
        }
    end
    stmt:close()
    conn:close()

    local books = {}
    for id_book, meta in pairs(book_meta) do
        local sessions     = rows_by_book[id_book]
        -- tag empty tables so rapidjson serialises [] not {}
        meta.page_sessions = (#sessions > 0) and sessions or empty_array()
        books[#books + 1]  = meta
    end
    return books
end

function DB.getBookByTitle(title, authors)
    local conn = getConn()
    if not conn then return nil end

    -- escape single quotes
    local t = (title or ""):gsub("'", "''")
    local a = (authors or ""):gsub("'", "''")

    local where = string.format("title = '%s'", t)
    if a ~= "" then
        where = where .. string.format(" AND authors = '%s'", a)
    end

    local stmt = conn:prepare(string.format([[
        SELECT id, md5, title, authors, pages,
               notes, highlights, total_read_time, total_read_pages, last_open
        FROM   book
        WHERE  %s
        LIMIT  1
    ]], where))

    local book = nil
    for row in stmt:rows() do
        book = {
            id               = tonumber(row[1]),
            md5              = row[2] or "",
            title            = row[3] or "",
            authors          = row[4] or "",
            pages            = tonumber(row[5]) or 0,
            notes            = tonumber(row[6]) or 0,
            highlights       = tonumber(row[7]) or 0,
            total_read_secs  = tonumber(row[8]) or 0,
            total_read_mins  = math.floor((tonumber(row[8]) or 0) / 60),
            total_read_pages = tonumber(row[9]) or 0,
            last_open        = tonumber(row[10]) or 0,
            page_sessions    = empty_array(),
        }
    end
    stmt:close()
    conn:close()
    return book
end

return DB
