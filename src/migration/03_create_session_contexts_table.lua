return require("migration").define(function()
    migration("Create session_contexts table", function()
        database("postgres", function()
            up(function(db)
                -- Create session_contexts table
                local success, err = db:execute([[
                    CREATE TABLE session_contexts (
                        id TEXT PRIMARY KEY, -- UUID
                        session_id TEXT NOT NULL,
                        type TEXT NOT NULL,
                        text TEXT NOT NULL,
                        time timestamp NOT NULL default now(),
                        FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_session_contexts_session ON session_contexts(session_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_session_contexts_type ON session_contexts(type)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_session_contexts_session")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_session_contexts_type")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS session_contexts")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create session_contexts table
                local success, err = db:execute([[
                    CREATE TABLE session_contexts (
                        id TEXT PRIMARY KEY, -- UUID
                        session_id TEXT NOT NULL,
                        type TEXT NOT NULL,
                        text TEXT NOT NULL,
                        time INTEGER NOT NULL,
                        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_session_contexts_session ON session_contexts(session_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_session_contexts_type ON session_contexts(type)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_session_contexts_session")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_session_contexts_type")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS session_contexts")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)