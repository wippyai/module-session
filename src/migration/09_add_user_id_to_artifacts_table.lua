return require("migration").define(function()
    migration("Add user_id to artifacts table and make session_id optional", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute("DELETE FROM artifacts")
                if err then
                    error(err)
                end

                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ADD COLUMN user_id TEXT NOT NULL
                ]])
                if err then
                    error(err)
                end

                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ADD CONSTRAINT fk_artifacts_user
                    FOREIGN KEY (user_id) REFERENCES app_users(user_id) ON DELETE SET NULL
                ]])
                if err then
                    error(err)
                end

                -- Drop existing foreign key constraint for session_id
                _, err = db:execute([[
                    ALTER TABLE artifacts
                    DROP CONSTRAINT artifacts_session_id_fkey
                ]])
                if err then
                    error(err)
                end

                -- Make session_id optional by dropping NOT NULL constraint
                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ALTER COLUMN session_id DROP NOT NULL
                ]])
                if err then
                    error(err)
                end

                -- Re-add foreign key constraint for session_id (now optional)
                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ADD CONSTRAINT fk_artifacts_session
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ]])
                if err then
                    error(err)
                end

                -- Create index for user_id
                _, err = db:execute("CREATE INDEX idx_artifacts_user ON artifacts(user_id)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop user_id index
                local _, err = db:execute("DROP INDEX IF EXISTS idx_artifacts_user")
                if err then
                    error(err)
                end

                -- Drop foreign key constraints
                _, err = db:execute("ALTER TABLE artifacts DROP CONSTRAINT IF EXISTS fk_artifacts_user")
                if err then
                    error(err)
                end

                _, err = db:execute("ALTER TABLE artifacts DROP CONSTRAINT IF EXISTS fk_artifacts_session")
                if err then
                    error(err)
                end

                -- Make session_id NOT NULL again
                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ALTER COLUMN session_id SET NOT NULL
                ]])
                if err then
                    error(err)
                end

                -- Re-add original foreign key constraint for session_id
                _, err = db:execute([[
                    ALTER TABLE artifacts
                    ADD CONSTRAINT artifacts_session_id_fkey
                    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
                ]])
                if err then
                    error(err)
                end

                -- Drop user_id column
                success, err = db:execute("ALTER TABLE artifacts DROP COLUMN user_id")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- SQLite doesn't support modifying table structure easily,
                -- so we need to recreate the table

                -- Drop old table
                _, err = db:execute("DROP TABLE artifacts")
                if err then
                    error(err)
                end

                -- Create new table with updated structure
                _, err = db:execute([[
                    CREATE TABLE artifacts (
                        artifact_id TEXT PRIMARY KEY,
                        session_id TEXT,
                        user_id TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        title TEXT,
                        meta TEXT,
                        content BLOB,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        FOREIGN KEY (session_id) REFERENCES sessions(session_id),
                        FOREIGN KEY (user_id) REFERENCES app_users(user_id) ON DELETE SET NULL
                    )
                ]])
                if err then
                    error(err)
                end

                -- Create indexes
                _, err = db:execute("CREATE INDEX idx_artifacts_session ON artifacts(session_id)")
                if err then
                    error(err)
                end

                _, err = db:execute("CREATE INDEX idx_artifacts_kind ON artifacts(kind)")
                if err then
                    error(err)
                end

                _, err = db:execute("CREATE INDEX idx_artifacts_user ON artifacts(user_id)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- SQLite doesn't support dropping columns directly,
                -- so we'd need to recreate the table without the column.
                error("SQLite doesn't support dropping columns. Manual table recreation required.")
            end)
        end)
    end)
end)
