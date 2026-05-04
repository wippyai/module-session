local sql = require("sql")
local time = require("time")
local encryption_key_bootloader = require("encryption_key_bootloader")
local migration_bootloader = require("migration_bootloader")

local bootloaders_started = false

local function call_bootloader(module, options)
    if type(module) == "function" then
        return module(options)
    end
    if type(module) == "table" and type(module.run) == "function" then
        return module.run(options)
    end
    error("bootloader import is not callable")
end

local function run_setup_bootloaders()
    if bootloaders_started then
        return
    end
    bootloaders_started = true

    local key_result = call_bootloader(encryption_key_bootloader, {})
    if type(key_result) ~= "table" or key_result.status == "error" then
        error("encryption key bootloader failed: " .. tostring(key_result and key_result.message or key_result))
    end

    local migration_result = call_bootloader(migration_bootloader, {})
    if type(migration_result) ~= "table" or migration_result.status == "error" then
        error("migration bootloader failed: " .. tostring(migration_result and migration_result.message or migration_result))
    end
end

local function run()
    run_setup_bootloaders()

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
