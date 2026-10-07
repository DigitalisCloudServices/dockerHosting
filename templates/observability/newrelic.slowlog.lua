-- Fluent Bit Lua filter for the MariaDB slow query log.
-- Managed by dockerHosting - do not edit by hand.
--
-- Receives one multi-line slow-log entry per record (key "log", assembled by the
-- mariadb-slowlog multiline parser) and returns a structured record whose only
-- statement text is the normalised one: every string, number, hex or binary
-- literal is replaced by ?, so no personal data leaves the host. The raw "log"
-- field is not copied. The normalisation follows the rules of VelaAir's
-- telemetry_sql_processor.normalise_sql_for_digest (quoted strings, numbers, IN
-- lists, whitespace, 500 characters) and extends them to what a server-side log
-- contains and a driver placeholder never does: backslash escapes inside
-- strings, x'..' / b'..' / 0x.. literals, comments, and repeated VALUES tuples.
--
-- Plain Lua 5.1 (the LuaJIT in Fluent Bit); no libraries, no bit operations.

local MAX_STATEMENT = 500

-- Index just past the quoted literal that opens at position i. Honours both
-- escape conventions MariaDB accepts: a backslash escape and a doubled quote.
-- An unterminated literal swallows the rest of the text, the safe direction.
local function skip_quoted(sql, i, quote)
    local j = i + 1
    local stop = "[\\" .. quote .. "]"
    while true do
        local p = sql:find(stop, j)
        if not p then
            return #sql + 1
        end
        if sql:sub(p, p) == "\\" then
            j = p + 2
        elseif sql:sub(p + 1, p + 1) == quote then
            j = p + 2
        else
            return p + 1
        end
    end
end

-- Values-free text of an SQL statement, capped at MAX_STATEMENT characters.
function slowlog_normalise(sql)
    local out, n = {}, 0
    local i, len = 1, #sql
    while i <= len do
        local c = sql:sub(i, i)
        local nxt = sql:sub(i + 1, i + 1)
        if c == "'" or c == '"' then
            i = skip_quoted(sql, i, c)
            n = n + 1
            out[n] = "?"
        elseif c == "`" then
            -- Quoted identifier: kept, it is schema, not data.
            local j = sql:find("`", i + 1, true) or len
            n = n + 1
            out[n] = sql:sub(i, j)
            i = j + 1
        elseif c == "/" and nxt == "*" then
            local _, j = sql:find("*/", i + 2, true)
            i = (j or len) + 1
            n = n + 1
            out[n] = " "
        elseif c == "#" or (c == "-" and nxt == "-" and sql:sub(i + 2, i + 2):find("^%s*$")) then
            i = sql:find("\n", i, true) or (len + 1)
            n = n + 1
            out[n] = " "
        elseif c:find("[%a_]") then
            local _, e = sql:find("^[%w_$]+", i)
            local word = sql:sub(i, e)
            if #word == 1 and word:find("[xXbB]") and nxt == "'" then
                -- x'4a6f' / b'0101' literal: the prefix letter goes with it.
                i = skip_quoted(sql, e + 1, "'")
                n = n + 1
                out[n] = "?"
            else
                n = n + 1
                out[n] = word
                i = e + 1
            end
        elseif c:find("%d") or (c == "-" and nxt:find("%d") and not sql:sub(i - 1, i - 1):find("[%w_%)]")) then
            local s = i
            if c == "-" then
                s = i + 1
            end
            local e
            if sql:find("^0[xX]%x+", s) then
                _, e = sql:find("^0[xX]%x+", s)
            else
                _, e = sql:find("^%d+", s)
                local _, e2 = sql:find("^%.%d+", e + 1)
                e = e2 or e
                local _, e3 = sql:find("^[eE][+-]?%d+", e + 1)
                e = e3 or e
            end
            i = e + 1
            n = n + 1
            out[n] = "?"
        else
            n = n + 1
            out[n] = c
            i = i + 1
        end
    end
    local text = table.concat(out)
    text = text:gsub("%f[%w_][Ii][Nn]%s*%(%s*%?[%s,%?]*%)", "IN (?)")
    text = text:gsub("%s+", " ")
    text = text:gsub("^ ", ""):gsub(" $", "")
    -- (?, ?), (?, ?) -> (?, ?): a multi-row insert keeps one digest at any size.
    repeat
        local k
        text, k = text:gsub("(%([%?, ]*%))%s*,%s*%1", "%1")
    until k == 0
    return text:sub(1, MAX_STATEMENT)
end

-- Short grouping key for a normalised statement: two 32-bit multiplicative
-- hashes side by side. Not cryptographic and not the Python sha256 digest, which
-- Lua cannot compute without a library; it only has to group identical shapes.
function slowlog_digest(text)
    local h1, h2 = 5381, 52711
    for i = 1, #text do
        local b = text:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 131 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

-- Lines the server writes around entries that must not reach the statement:
-- the restart banner, which the multiline parser appends to the entry before it.
local function is_banner(line)
    return line:find("^Tcp port:") ~= nil
        or line:find("^Time%s+Id%s+Command") ~= nil
        or line:find(", Version: .* started with:$") ~= nil
end

-- Fluent Bit entry point: (tag, timestamp, record) -> code, timestamp, record.
-- -1 drops the record, 1 replaces it and sets the timestamp.
function slowlog_clean(tag, timestamp, record)
    local log = record["log"]
    if type(log) ~= "string" then
        return -1, timestamp, record
    end
    local query_time = log:match("# Query_time:%s*([%d%.]+)")
    if not query_time then
        return -1, timestamp, record
    end

    local lines, ts = {}, timestamp
    for line in (log .. "\n"):gmatch("(.-)\n") do
        local set_ts = line:match("^SET timestamp=(%d+);%s*$")
        if set_ts then
            ts = tonumber(set_ts)
        elseif not (line:find("^#") or line:find("^[Uu][Ss][Ee]%s+[^;]+;%s*$") or is_banner(line)) then
            -- anything else is statement text; header comments, `use db;` and the banner are not
            lines[#lines + 1] = line
        end
    end

    local statement = slowlog_normalise(table.concat(lines, "\n"))
    local out = {
        logtype = "mariadb-slow-query",
        message = statement,
        statement = statement,
        digest = slowlog_digest(statement),
        query_time = tonumber(query_time),
        lock_time = tonumber(log:match("Lock_time:%s*([%d%.]+)")),
        rows_sent = tonumber(log:match("Rows_sent:%s*(%d+)")),
        rows_examined = tonumber(log:match("Rows_examined:%s*(%d+)")),
        user = log:match("# User@Host:%s*([^%[\n]+)"),
        schema = log:match("Schema: ([^%s]*)  QC_hit"),
    }
    return 1, ts, out
end
