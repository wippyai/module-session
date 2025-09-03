return require("migration").define(function()
    migration("Add config and meta fields to sessions table", function()
        database("postgres", function()
            up(function(db)
                -- Add new config and meta fields
                local success, err = db:execute([[
                    ALTER TABLE sessions
                    ADD COLUMN config TEXT DEFAULT '{}',
                    ADD COLUMN meta TEXT DEFAULT '{}'
                ]])

                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Remove the new fields
                local success, err = db:execute([[
                    ALTER TABLE sessions
                    DROP COLUMN IF EXISTS config,
                    DROP COLUMN IF EXISTS meta
                ]])

                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Add new config and meta fields
                local success, err = db:execute([[
                    ALTER TABLE sessions
                    ADD COLUMN config TEXT DEFAULT '{}'
                ]])

                if err then
                    error(err)
                end

                success, err = db:execute([[
                    ALTER TABLE sessions
                    ADD COLUMN meta TEXT DEFAULT '{}'
                ]])

                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- SQLite doesn't support DROP COLUMN easily, would need table recreation
                -- For now, just mark as deprecated in down migration
                local success, err = db:execute("SELECT 1")
                if err then
                    error("Cannot easily drop columns in SQLite: " .. err)
                end
            end)
        end)
    end)
end)