--[[
    sync.lua – BookOrbit sync logic

    All sync paths (full, delta, tick) go through ONE function: _doSync(ui, since).

    POST /api/stats payload per book:
        id_book, md5, document, title, authors, pages, last_open,
        notes, highlights, total_read_secs, total_read_mins, total_read_pages,
        page_sessions: [ { page, start_time, duration, total_pages } ]

    PUT /api/progress payload per book:
        document, progress, percentage, device
--]]

local API         = require("api")
local S           = require("settings")
local DB          = require("db")
local logger      = require("logger")
local ReadHistory = require("readhistory")
local DocSettings = require("docsettings")
local json        = require("rapidjson")

local Sync        = {}


local function getBooksFromHistory(since)
    local books = {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        local file      = item.file
        local last_open = item.time or 0
        if file and (since == 0 or last_open >= since) then
            local ok, ds = pcall(DocSettings.open, DocSettings, file)
            if ok and ds then
                local stats       = ds:readSetting("stats") or {}
                local data        = ds:readSetting("summary") or {}
                local total_secs  = stats.total_time_in_sec or 0
                books[#books + 1] = {
                    id_book         = nil,
                    md5             = "",
                    file            = file,
                    title           = data.title or stats.title or "",
                    authors         = data.authors or stats.authors or "",
                    page            = ds:readSetting("last_page") or 0,
                    pages           = ds:readSetting("doc_pages") or 0,
                    last_open       = last_open,
                    total_read_secs = total_secs,
                    total_read_mins = math.floor(total_secs / 60),
                    highlights      = stats.highlights or 0,
                    notes           = stats.notes or 0,
                    page_sessions   = json.array(),
                }
            end
        end
    end
    return books
end


local function getBooks(since)
    if DB.isAvailable() then
        local books = DB.getSessionsSince(since)
        if books and #books > 0 then
            return books
        end
        -- DB is available but no page_stat_data rows in window yet
        -- that's fine, mergeOpenDoc will inject the open doc with fresh
        -- totals looked up by title
        if since > 0 then
            return {}
        end
    end
    logger.warn("BookOrbit: stats DB unavailable, falling back to ReadHistory")
    return getBooksFromHistory(since)
end


local function mergeOpenDoc(ui, books)
    if not ui or not ui.document then return books end
    local doc   = ui.document
    local props = doc:getProps() or {}
    local file  = doc.file or ""
    local title = props.title or ""
    local page  = 0
    if ui.paging and ui.paging.current_page then
        page = ui.paging.current_page
    elseif ui.rolling and ui.rolling.current_page then
        page = ui.rolling.current_page
    end

    -- 1. already in list?
    for _, b in ipairs(books) do
        if b.file == file or (title ~= "" and b.title == title) then
            b.page = page
            b.file = file
            return books
        end
    end

    -- 2. not in list — look up from DB by title
    local db_book = (DB.isAvailable() and title ~= "")
        and DB.getBookByTitle(title, props.authors or "")
        or nil

    if db_book then
        db_book.file = file
        db_book.page = page
        -- pages from live doc is more reliable than DB for an open file
        if doc.getPageCount then
            local pc = doc:getPageCount()
            if pc and pc > 0 then db_book.pages = pc end
        end
        table.insert(books, 1, db_book)
    else
        -- 3. DB miss — minimal stub so progress PUT still fires
        table.insert(books, 1, {
            id_book          = nil,
            md5              = "",
            file             = file,
            title            = title,
            authors          = props.authors or "",
            page             = page,
            pages            = (doc.getPageCount and doc:getPageCount()) or 0,
            last_open        = os.time(),
            total_read_secs  = 0,
            total_read_mins  = 0,
            total_read_pages = 0,
            highlights       = 0,
            notes            = 0,
            page_sessions    = json.array(),
        })
    end
    return books
end


local function syncProgress(books)
    local sent, failed = 0, 0
    for _, book in ipairs(books) do
        local doc_key = (book.md5 and book.md5 ~= "") and book.md5
            or (book.file and book.file ~= "") and book.file
        if doc_key and book.pages and book.pages > 0 then
            local ok, _, err = API.put("/api/progress", {
                document   = doc_key,
                progress   = tostring(book.page or 0),
                percentage = (book.page or 0) / book.pages,
                device     = "KOReader",
            })
            if ok then
                sent = sent + 1
            else
                failed = failed + 1
                logger.warn("BookOrbit: progress failed for " .. doc_key
                    .. ": " .. tostring(err))
            end
        end
    end
    return {
        ok    = failed == 0,
        label = "progress",
        count = sent,
        err   = failed > 0 and (failed .. " failed") or nil,
    }
end

local function syncStats(books, since)
    local payloads = {}
    for _, book in ipairs(books) do
        local doc_key = (book.md5 and book.md5 ~= "") and book.md5
            or (book.file and book.file ~= "") and book.file
        if doc_key then
            payloads[#payloads + 1] = {
                id_book          = book.id_book,
                md5              = book.md5 or "",
                document         = doc_key,
                title            = book.title or "",
                authors          = book.authors or "",
                pages            = book.pages or 0,
                last_open        = book.last_open or os.time(),
                notes            = book.notes or 0,
                highlights       = book.highlights or 0,
                total_read_secs  = book.total_read_secs or 0,
                total_read_mins  = book.total_read_mins or 0,
                total_read_pages = book.total_read_pages or 0,
                page_sessions    = book.page_sessions or json.array(),
            }
        end
    end

    if #payloads == 0 then
        return { ok = true, label = "stats", count = 0 }
    end

    local ok, _, err = API.post("/api/stats", {
        since     = since,
        timestamp = os.time(),
        books     = payloads,
    })
    return {
        ok    = ok,
        label = "stats",
        count = ok and #payloads or 0,
        err   = err,
    }
end


local function _doSync(ui, since)
    local books = getBooks(since)
    books       = mergeOpenDoc(ui, books)
    if #books == 0 then
        return { { ok = true, label = "up to date", count = 0 } }
    end
    local results = { syncProgress(books), syncStats(books, since) }
    S.setLastSync(os.time())
    return results
end


function Sync.full(ui)
    logger.info("BookOrbit: full sync (since=0)")
    return _doSync(ui, 0)
end

function Sync.delta(ui)
    local since = S.getLastSync()
    logger.info("BookOrbit: delta sync since " .. since)
    return _doSync(ui, since)
end

Sync.tick = Sync.delta

function Sync.onBookClose(ui)
    if not S.getSyncOnClose() then return end
    if not S.isConfigured() then return end
    logger.info("BookOrbit: sync on book close")
    Sync.delta(ui)
end

function Sync.onSuspend(ui)
    if not S.getSyncOnSuspend() then return end
    if not S.isConfigured() then return end
    logger.info("BookOrbit: sync on suspend")
    Sync.delta(ui)
end

function Sync.onNetworkUp(ui)
    if not S.isConfigured() then return end
    local elapsed = os.time() - S.getLastSync()
    if elapsed < 30 * 60 then return end
    logger.info("BookOrbit: sync on network up")
    Sync.delta(ui)
end

function Sync.onReadingTick(ui, pages, mins)
    if not S.isConfigured() then return end
    local page_due = S.getPageThreshold() > 0 and pages >= S.getPageThreshold()
    local min_due  = S.getMinuteThreshold() > 0 and mins >= S.getMinuteThreshold()
    if page_due or min_due then
        logger.info("BookOrbit: auto-sync trigger (pages=" .. pages
            .. " mins=" .. string.format("%.1f", mins) .. ")")
        Sync.tick(ui)
    end
end

return Sync
