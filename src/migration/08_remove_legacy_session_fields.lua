return require("migration").define(function()
    migration("Remove legacy agent/model session fields", function()
        database("postgres", function()
            up(function(db)
                -- Remove legacy fields that have been migrated to config (keep kind)
                local success, err = db:execute([[
                    ALTER TABLE sessions
                    DROP COLUMN IF EXISTS current_model,
                    DROP COLUMN IF EXISTS current_agent
                ]])

                if err then
                    error("Failed to remove legacy fields: " .. err)
                end
            end)

            down(function(db)
                -- Restore legacy fields (except kind which stays)
                local success, err = db:execute([[
                    ALTER TABLE sessions
                    ADD COLUMN current_model TEXT DEFAULT '',
                    ADD COLUMN current_agent TEXT DEFAULT ''
                ]])

                if err then
                    error("Failed to restore legacy fields: " .. err)
                end

                -- Restore data from config back to legacy fields
                success, err = db:execute([[
                    UPDATE sessions SET
                        current_model = COALESCE((config::jsonb->>'current_model'), ''),
                        current_agent = COALESCE((config::jsonb->>'current_agent'), '')
                    WHERE config != '{}'
                ]])

                if err then
                    error("Failed to restore legacy data: " .. err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- SQLite doesn't support DROP COLUMN easily, would need table recreation
                -- Create new table without legacy columns (but keep kind)
                local success, err = db:execute([[
                    CREATE TABLE sessions_new (
                        session_id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        primary_context_id TEXT NOT NULL,
                        status TEXT DEFAULT 'idle',
                        title TEXT DEFAULT '',
                        kind TEXT DEFAULT 'default',
                        public_meta TEXT DEFAULT '[]',
                        config TEXT DEFAULT '{}',
                        meta TEXT DEFAULT '{}',
                        start_date INTEGER NOT NULL,
                        last_message_date INTEGER,
                        FOREIGN KEY (user_id) REFERENCES users(user_id),
                        FOREIGN KEY (primary_context_id) REFERENCES contexts(context_id)
                    )
                ]])

                if err then
                    error("Failed to create new sessions table: " .. err)
                end

                -- Copy data from old table to new table (excluding current_model, current_agent)
                success, err = db:execute([[
                    INSERT INTO sessions_new (
                        session_id, user_id, primary_context_id, status, title, kind,
                        public_meta, config, meta, start_date, last_message_date
                    )
                    SELECT
                        session_id, user_id, primary_context_id, status, title, kind,
                        public_meta, config, meta, start_date, last_message_date
                    FROM sessions
                ]])

                if err then
                    error("Failed to copy session data: " .. err)
                end

                -- Drop old table
                success, err = db:execute("DROP TABLE sessions")
                if err then
                    error("Failed to drop old sessions table: " .. err)
                end

                -- Rename new table
                success, err = db:execute("ALTER TABLE sessions_new RENAME TO sessions")
                if err then
                    error("Failed to rename sessions table: " .. err)
                end

                -- Recreate indexes
                success, err = db:execute("CREATE INDEX idx_sessions_user ON sessions(user_id)")
                if err then
                    error("Failed to create user index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_sessions_date ON sessions(start_date)")
                if err then
                    error("Failed to create date index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_sessions_primary_context ON sessions(primary_context_id)")
                if err then
                    error("Failed to create context index: " .. err)
                end
            end)

            down(function(db)
                -- Recreate table with legacy fields
                local success, err = db:execute([[
                    CREATE TABLE sessions_legacy (
                        session_id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        primary_context_id TEXT NOT NULL,
                        status TEXT DEFAULT 'idle',
                        title TEXT DEFAULT '',
                        kind TEXT DEFAULT 'default',
                        current_model TEXT DEFAULT '',
                        current_agent TEXT DEFAULT '',
                        public_meta TEXT DEFAULT '[]',
                        config TEXT DEFAULT '{}',
                        meta TEXT DEFAULT '{}',
                        start_date INTEGER NOT NULL,
                        last_message_date INTEGER,
                        FOREIGN KEY (user_id) REFERENCES users(user_id),
                        FOREIGN KEY (primary_context_id) REFERENCES contexts(context_id)
                    )
                ]])

                if err then
                    error("Failed to create legacy sessions table: " .. err)
                end

                -- Copy data and restore legacy fields from config
                success, err = db:execute([[
                    INSERT INTO sessions_legacy (
                        session_id, user_id, primary_context_id, status, title, kind,
                        current_model, current_agent, public_meta,
                        config, meta, start_date, last_message_date
                    )
                    SELECT
                        session_id, user_id, primary_context_id, status, title, kind,
                        COALESCE(json_extract(config, '$.current_model'), '') as current_model,
                        COALESCE(json_extract(config, '$.current_agent'), '') as current_agent,
                        public_meta, config, meta, start_date, last_message_date
                    FROM sessions
                ]])

                if err then
                    error("Failed to restore legacy session data: " .. err)
                end

                -- Drop current table and rename
                success, err = db:execute("DROP TABLE sessions")
                if err then
                    error("Failed to drop sessions table: " .. err)
                end

                success, err = db:execute("ALTER TABLE sessions_legacy RENAME TO sessions")
                if err then
                    error("Failed to rename sessions table: " .. err)
                end

                -- Recreate indexes
                success, err = db:execute("CREATE INDEX idx_sessions_user ON sessions(user_id)")
                if err then
                    error("Failed to create user index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_sessions_date ON sessions(start_date)")
                if err then
                    error("Failed to create date index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_sessions_primary_context ON sessions(primary_context_id)")
                if err then
                    error("Failed to create context index: " .. err)
                end
            end)
        end)
    end)
end)
