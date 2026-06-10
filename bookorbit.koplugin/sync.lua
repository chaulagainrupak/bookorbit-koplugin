--[[
    sync.lua – BookOrbit sync logic

    All sync paths (full, delta, tick) go through ONE function: _doSync(ui, since).

    POST /api/v1/koreader/stats payload:
        since, timestamp, device, books: [
            { id_book, md5, document, title, authors, pages, last_open,
              notes, highlights, total_read_secs, total_read_mins, total_read_pages,
              page_sessions: [ { page, start_time, duration, total_pages } ] }
        ]

    PUT /api/v1/koreader/syncs/progress payload per book:
        document, progress, percentage, device
--]]

local API         = require("api")
local S           = require("settings")
local DB          = require("db")
local logger      = require("logger")
local ReadHistory = require("readhistory")
local DocSettings = require("docsettings")
local UIManager   = require("ui/uimanager")
local json        = require("rapidjson")

local Sync        = {}
local _syncing    = false


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
    logger.info("BookOrbit: DB available = " .. tostring(DB.isAvailable()))

    if DB.isAvailable() then
        local books = DB.getSessionsSince(since)

        logger.info("BookOrbit: DB returned "
            .. tostring(books and #books or -1) .. " books")

        if books and #books > 0 then
            return books
        end

        if since > 0 then
            return {}
        end
    end

    logger.warn("BookOrbit: FALLING BACK TO READHISTORY")
    return getBooksFromHistory(since)
end


local function mergeOpenDoc(ui, books, live_session)
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

    local function inject(b)
        b.page = page
        b.file = file
        -- splice live session in if DB hasn't flushed it yet
        if live_session then
            local sessions = b.page_sessions
            -- avoid duplicate: don't add if DB already has a session at same start_time
            local already = false
            for _, s in ipairs(sessions) do
                if s.start_time == live_session.start_time then
                    already = true; break
                end
            end
            if not already then
                sessions[#sessions + 1] = live_session
            end
            b.total_read_secs = b.total_read_secs + live_session.duration
            b.total_read_mins = math.floor(b.total_read_secs / 60)
        end
    end

    for _, b in ipairs(books) do
        if b.file == file or (title ~= "" and b.title == title) then
            inject(b)
            return books
        end
    end

    local db_book = (DB.isAvailable() and title ~= "")
        and DB.getBookByTitle(title, props.authors or "")
        or nil

    if db_book then
        db_book.file = file
        db_book.page = page
        if doc.getPageCount then
            local pc = doc:getPageCount()
            if pc and pc > 0 then db_book.pages = pc end
        end
        if live_session then
            db_book.page_sessions[#db_book.page_sessions + 1] = live_session
            db_book.total_read_secs = db_book.total_read_secs + live_session.duration
            db_book.total_read_mins = math.floor(db_book.total_read_secs / 60)
        end
        table.insert(books, 1, db_book)
    else
        local sessions = json.array()
        if live_session then sessions[1] = live_session end
        table.insert(books, 1, {
            id_book          = nil,
            md5              = "",
            file             = file,
            title            = title,
            authors          = props.authors or "",
            page             = page,
            pages            = (doc.getPageCount and doc:getPageCount()) or 0,
            last_open        = os.time(),
            total_read_secs  = live_session and live_session.duration or 0,
            total_read_mins  = live_session and math.floor(live_session.duration / 60) or 0,
            total_read_pages = 0,
            highlights       = 0,
            notes            = 0,
            page_sessions    = sessions,
        })
    end
    return books
end


--[[
    _doSyncAsync(books, since, on_done)

    Processes books one per UIManager tick so the UI stays responsive.
    on_done(results) is called when all books are finished.

    Two passes:
      1. progress PUT  (one per book)
      2. stats   POST  (one per book)

    Each HTTP call is wrapped in scheduleIn(0, ...) so KOReader can
    repaint / handle input between them.
--]]
local function _doSyncAsync(books, since, on_done)
    local progress_results = { ok = true, label = "progress", count = 0, failed = 0 }
    local stats_results    = { ok = true, label = "stats",    count = 0, failed = 0 }

    local n = #books

    local function finish()
        local results = {}

        if progress_results.count > 0 or progress_results.failed > 0 then
            results[#results + 1] = {
                ok    = progress_results.ok,
                label = "progress",
                count = progress_results.count,
                err   = progress_results.failed > 0
                    and (progress_results.failed .. " failed") or nil,
            }
        end

        results[#results + 1] = {
            ok    = stats_results.ok,
            label = "stats",
            count = stats_results.count,
            err   = stats_results.failed > 0
                and (stats_results.failed .. " failed") or nil,
        }

        S.setLastSync(os.time())
        _syncing = false
        on_done(results)
    end

    -- pass 2: all stats in ONE batched POST, yielded one tick so UI can breathe first
    local function doStatsPass()
        UIManager:scheduleIn(0, function()
            local payload = {}
            local skipped = 0

            for _, book in ipairs(books) do
                local doc_key = (book.md5 and book.md5 ~= "") and book.md5
                    or (book.file and book.file ~= "") and book.file

                if not doc_key then
                    skipped = skipped + 1
                    logger.warn("BookOrbit: skipping book with no md5 or file: "
                        .. tostring(book.title))
                else
                    payload[#payload + 1] = {
                        document         = book.md5 or doc_key,
                        md5              = book.md5 or "",
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

            if skipped > 0 then
                logger.warn("BookOrbit: skipped " .. skipped .. " book(s) with no document key")
            end

            if #payload > 0 then
                local ok, _, err = API.post("/api/v1/koreader/stats", {
                    since     = since,
                    timestamp = os.time(),
                    device    = S.getUsername(),
                    books     = payload,
                })
                if ok then
                    stats_results.count = #payload
                    logger.info("BookOrbit: stats batch sent (" .. #payload .. " books)")
                else
                    stats_results.ok     = false
                    stats_results.failed = #payload
                    logger.warn("BookOrbit: stats batch FAILED: " .. tostring(err))
                end
            end

            finish()
        end)
    end

    -- pass 1: progress PUT per book (one per tick — KOSync compat, no batch endpoint)
    local function doProgressPass(i)
        if i > n then
            doStatsPass()
            return
        end

        UIManager:scheduleIn(0, function()
            local book    = books[i]
            local doc_key = (book.md5 and book.md5 ~= "") and book.md5
                or (book.file and book.file ~= "") and book.file

            if doc_key and book.pages and book.pages > 0 then
                local ok, _, err = API.put("/api/v1/koreader/syncs/progress", {
                    document   = doc_key,
                    progress   = tostring(book.page or 0),
                    percentage = (book.page or 0) / book.pages,
                    device     = "KOReader",
                })
                if ok then
                    progress_results.count = progress_results.count + 1
                else
                    progress_results.failed = progress_results.failed + 1
                    progress_results.ok     = false
                    logger.warn("BookOrbit: progress failed for " .. tostring(doc_key)
                        .. ": " .. tostring(err))
                end
            end

            doProgressPass(i + 1)
        end)
    end

    doProgressPass(1)
end


local function _doSync(ui, since, on_done, live_session)
    if _syncing then
        logger.info("BookOrbit: sync already in progress, skipping")
        if on_done then
            on_done({ { ok = true, label = "skipped (busy)", count = 0 } })
        end
        return
    end
    _syncing    = true
    local books = getBooks(since) or {}
    books       = mergeOpenDoc(ui, books, live_session) or {}
    if #books == 0 then
        logger.info("BookOrbit: nothing to sync")
        S.setLastSync(os.time())
        _syncing = false
        if on_done then
            on_done({ { ok = true, label = "up to date", count = 0 } })
        end
        return
    end
    logger.info("BookOrbit: syncing " .. #books .. " book(s)")
    _doSyncAsync(books, since, on_done or function() end)
end


function Sync.full(ui, on_done)
    logger.info("BookOrbit: full sync (since=0)")
    _doSync(ui, 0, on_done)
end

function Sync.delta(ui, on_done, live_session)
    local since = S.getLastSync()
    logger.info("BookOrbit: delta sync since " .. since)
    _doSync(ui, since, on_done, live_session)
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

return Sync
