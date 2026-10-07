-- Runs the real slow-log Fluent Bit Lua filter outside Fluent Bit.
--   luajit slowlog_run.lua <filter.lua> normalise      SQL on stdin -> normalised text
--   luajit slowlog_run.lua <filter.lua> file <log>     log file -> one block per record
--   luajit slowlog_run.lua <filter.lua> nolog          a record with no "log" key
-- "file" cuts the log into records the way the mariadb-slowlog multiline parser
-- does: a record starts at a "# User@Host:" line and takes every line up to the
-- next one; a line before the first start is a record of its own.
dofile(arg[1])
local mode = arg[2]

if mode == "normalise" then
    print(slowlog_normalise(io.read("*a")))
elseif mode == "nolog" then
    print(slowlog_clean("t", 5, { other = "x" }))
else
    local records, current = {}, nil
    for line in io.lines(arg[3]) do
        if line:find("^# User@Host:") then
            current = { line }
            records[#records + 1] = current
        elseif current then
            current[#current + 1] = line
        else
            records[#records + 1] = { line }
        end
    end
    for _, lines in ipairs(records) do
        local code, ts, out = slowlog_clean("t", 0, { log = table.concat(lines, "\n") })
        if code == -1 then
            print("DROPPED")
        else
            print("ts=" .. ts)
            local keys = {}
            for k in pairs(out) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do print(k .. "=" .. tostring(out[k])) end
        end
        print("---")
    end
end
