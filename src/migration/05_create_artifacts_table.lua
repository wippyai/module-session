return require("migration").define(function()
    migration("Create artifacts table", function()
        database("postgres", function()
            up(function(db)
                -- Create artifacts table
                local success, err = db:execute([[
                    CREATE TABLE artifacts (
                        artifact_id TEXT PRIMARY KEY, -- UUID
                        session_id TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        title TEXT,
                        meta TEXT, -- JSON metadata
                        content bytea,
                        created_at timestamp NOT NULL DEFAULT now(),
                        updated_at timestamp NOT NULL DEFAULT now(),
                        FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_artifacts_session ON artifacts(session_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_artifacts_kind ON artifacts(kind)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_artifacts_session")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_artifacts_kind")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS artifacts")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create artifacts table
                local success, err = db:execute([[
                    CREATE TABLE artifacts (
                        artifact_id TEXT PRIMARY KEY, -- UUID
                        session_id TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        title TEXT,
                        meta TEXT, -- JSON metadata
                        content BLOB,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_artifacts_session ON artifacts(session_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_artifacts_kind ON artifacts(kind)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_artifacts_session")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_artifacts_kind")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS artifacts")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)