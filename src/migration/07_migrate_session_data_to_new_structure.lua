return require("migration").define(function()
    migration("Migrate session data to new config/meta structure", function()
        database("postgres", function()
            up(function(db)
                -- Migrate existing data to new structure (kind stays in column)
                local success, err = db:execute([[
                    UPDATE sessions SET
                        config = jsonb_build_object(
                            'agent_id', COALESCE(current_agent, ''),
                            'model', COALESCE(current_model, ''),
                            'token_checkpoint_threshold', 50000,
                            'max_message_limit', 1000,
                            'enable_agent_cache', true,
                            'delegation_description_suffix', ''
                        )::text,
                        meta = '{}'
                    WHERE config = '{}' OR meta = '{}'
                ]])

                if err then
                    error("Failed to migrate session data: " .. err)
                end
            end)

            down(function(db)
                -- Reset config and meta to empty JSON
                local success, err = db:execute([[
                    UPDATE sessions SET
                        config = '{}',
                        meta = '{}'
                ]])

                if err then
                    error("Failed to reset session data: " .. err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- For SQLite, we need to construct JSON manually (kind stays in column)
                local success, err = db:execute([[
                    UPDATE sessions SET
                        config = '{"agent_id":"' || COALESCE(current_agent, '') ||
                                 '","model":"' || COALESCE(current_model, '') ||
                                 '","token_checkpoint_threshold":50000' ||
                                 ',"max_message_limit":1000' ||
                                 ',"enable_agent_cache":true' ||
                                 ',"delegation_description_suffix":""}',
                        meta = '{}'
                    WHERE config = '{}' OR meta = '{}'
                ]])

                if err then
                    error("Failed to migrate session data: " .. err)
                end
            end)

            down(function(db)
                -- Reset config and meta to empty JSON
                local success, err = db:execute([[
                    UPDATE sessions SET
                        config = '{}',
                        meta = '{}'
                ]])

                if err then
                    error("Failed to reset session data: " .. err)
                end
            end)
        end)
    end)
end)
