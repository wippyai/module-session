local sql = require("sql")
local time = require("time")

local function run()
    local max_attempts = 40
    local sleep_ms = 100

    for attempt = 1, max_attempts do
        local db, err = sql.get("app:db")
        if not err then
            local result, query_err = db:query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='contexts'"
            )
            db:release()

            if not query_err and result and #result > 0 then
                return true
            end
        end

        time.sleep(sleep_ms .. "ms")
    end

    error("bootloader did not complete within " .. (max_attempts * sleep_ms) .. "ms")
end

return { run = run }
