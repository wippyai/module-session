local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")
local consts = require("consts")

local function define_tests()
    describe("Session Repository", function()
        -- Test data
        local test_data = {
            user_id = uuid.v7(),
            context_id = uuid.v7(),
            context_id2 = uuid.v7(),
            session_id = uuid.v7()
        }
        local actor = security.actor()
        if actor then
            test_data.user_id = actor:id()
        end

        -- Setup test context before all tests
        before_all(function()
            -- Create primary context for sessions
            local context, err = context_repo.create(
                test_data.context_id,
                "primary",
                "Primary context data"
            )

            if err then
                error("Failed to create primary test context: " .. err)
            end

            -- Create secondary context for testing relationships
            context, err = context_repo.create(
                test_data.context_id2,
                "secondary",
                "Secondary context data"
            )

            if err then
                error("Failed to create secondary test context: " .. err)
            end
        end)

        -- Clean up test data after all tests
        after_all(function()
            local db_resource, _ = consts.get_db_resource()
            local db, err = sql.get(db_resource)
            if err then
                error("Failed to connect to database: " .. err)
            end

            local tx, err = db:begin()
            if err then
                db:release()
                error("Failed to begin transaction: " .. err)
            end

            tx:execute("DELETE FROM messages WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM session_contexts WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM sessions WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM contexts WHERE context_id IN ($1, $2)",
                { test_data.context_id, test_data.context_id2 })

            local success, err = tx:commit()
            if err then
                tx:rollback()
                db:release()
                error("Failed to commit cleanup transaction: " .. err)
            end

            db:release()
        end)

        it("should create a new session", function()
            local session, err = session_repo.create(
                test_data.session_id,
                test_data.user_id,
                test_data.context_id,
                "Test Session",
                "test",
                { model = "test-model" },
                { max_tokens = 1000 }
            )

            test.is_nil(err)
            test.not_nil(session)
            test.eq(session.session_id, test_data.session_id)
            test.eq(session.user_id, test_data.user_id)
            test.eq(session.primary_context_id, test_data.context_id)
            test.eq(session.title, "Test Session")
            test.eq(session.kind, "test")
            test.is_table(session.meta)
            test.eq(session.meta.model, "test-model")
            test.is_table(session.config)
            test.eq(session.config.max_tokens, 1000)
            test.not_nil(session.start_date)
            test.not_nil(session.last_message_date)
        end)

        it("should get a session by ID", function()
            local session, err = session_repo.get(test_data.session_id)

            test.is_nil(err)
            test.not_nil(session)
            test.eq(session.session_id, test_data.session_id)
            test.eq(session.user_id, test_data.user_id)
            test.eq(session.primary_context_id, test_data.context_id)
            test.eq(session.title, "Test Session")
            test.eq(session.kind, "test")
            test.is_table(session.meta)
            test.eq(session.meta.model, "test-model")
            test.is_table(session.config)
            test.eq(session.config.max_tokens, 1000)
        end)

        it("should get a session by ID with user filter", function()
            local session, err = session_repo.get(test_data.session_id, test_data.user_id)
            test.is_nil(err)
            test.not_nil(session)
            test.eq(session.session_id, test_data.session_id)

            -- Different user should not find the session
            session, err = session_repo.get(test_data.session_id, uuid.v7())
            test.is_nil(session)
            test.contains(tostring(err), "not found")
        end)

        it("should list sessions by user ID", function()
            local sessions, err = session_repo.list_by_user(test_data.user_id)

            test.is_nil(err)
            test.not_nil(sessions)
            test.is_true(#sessions >= 1)

            local found = false
            for _, session in ipairs(sessions) do
                if session.session_id == test_data.session_id then
                    found = true
                    break
                end
            end

            test.is_true(found)
        end)

        it("should update session title via update_session_meta", function()
            local result, err = session_repo.update_session_meta(
                test_data.session_id,
                { title = "Updated Session Title" }
            )

            test.is_nil(err)
            test.not_nil(result)
            test.eq(result.session_id, test_data.session_id)
            test.eq(result.title, "Updated Session Title")
            test.is_true(result.updated)

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            test.eq(session.title, "Updated Session Title")
        end)

        it("should update last message date", function()
            local timestamp = os.time() - 3600
            local result, err = session_repo.update_session_meta(
                test_data.session_id,
                { last_message_date = timestamp }
            )

            test.is_nil(err)
            test.not_nil(result)
            test.eq(result.session_id, test_data.session_id)
            test.eq(result.last_message_date, time.unix(timestamp, 0):format(time.RFC3339))
            test.is_true(result.updated)

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            test.eq(session.last_message_date, time.unix(timestamp, 0):format(time.RFC3339))
        end)

        it("should update multiple session fields at once", function()
            local updates = {
                title = "Multi Updated Title",
                status = "active",
                kind = "updated_kind",
                meta = { model = "new-model", temperature = 0.7 },
                config = { max_tokens = 2000 },
                public_meta = { theme = "dark" },
                last_message_date = os.time()
            }

            local result, err = session_repo.update_session_meta(
                test_data.session_id,
                updates
            )

            test.is_nil(err)
            test.not_nil(result)
            test.eq(result.session_id, test_data.session_id)
            test.eq(result.title, updates.title)
            test.eq(result.status, updates.status)
            test.eq(result.kind, updates.kind)
            test.is_true(result.updated)

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            test.eq(session.title, updates.title)
            test.eq(session.kind, updates.kind)
            test.is_table(session.meta)
            test.eq(session.meta.model, "new-model")
            test.eq(session.meta.temperature, 0.7)
            test.is_table(session.config)
            test.eq(session.config.max_tokens, 2000)
            test.is_table(session.public_meta)
            test.eq(session.public_meta.theme, "dark")
        end)

        it("should count sessions by user", function()
            local count, err = session_repo.count_by_user(test_data.user_id)

            test.is_nil(err)
            test.is_true(count >= 1)
        end)

        it("should handle validation errors", function()
            -- Invalid session creation
            local session, err = session_repo.create(nil, test_data.user_id, test_data.context_id)
            test.is_nil(session)
            test.contains(tostring(err), "Session ID is required")

            session, err = session_repo.create(uuid.v7(), "", test_data.context_id)
            test.is_nil(session)
            test.contains(tostring(err), "User ID is required")

            session, err = session_repo.create(uuid.v7(), test_data.user_id, "")
            test.is_nil(session)
            test.contains(tostring(err), "Primary context ID is required")

            -- Get with invalid ID
            session, err = session_repo.get("")
            test.is_nil(session)
            test.contains(tostring(err), "Session ID is required")

            -- List with invalid user ID
            local sessions, err = session_repo.list_by_user("")
            test.is_nil(sessions)
            test.contains(tostring(err), "User ID is required")

            -- Update with invalid session ID
            local result, err = session_repo.update_session_meta("", { title = "x" })
            test.is_nil(result)
            test.contains(tostring(err), "Session ID is required")

            -- Update non-existent session
            result, err = session_repo.update_session_meta(uuid.v7(), { title = "x" })
            test.is_nil(result)
            test.contains(tostring(err), "Session not found")

            -- Count with invalid user ID
            local count, err_count = session_repo.count_by_user("")
            test.is_nil(count)
            test.contains(tostring(err_count), "User ID is required")
        end)

        it("should delete a session", function()
            -- Create a session to delete
            local temp_session_id = uuid.v7()
            local session, err = session_repo.create(
                temp_session_id,
                test_data.user_id,
                test_data.context_id,
                "Temporary Session"
            )

            test.is_nil(err)

            -- Delete it
            local result, err = session_repo.delete(temp_session_id)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deletion
            session, err = session_repo.get(temp_session_id)
            test.is_nil(session)
            test.contains(tostring(err), "not found")

            -- Delete non-existent session
            result, err = session_repo.delete(uuid.v7())
            test.is_nil(result)
            test.contains(tostring(err), "Session not found")
        end)

        it("should only update the target session without affecting others", function()
            local user_id = test_data.user_id
            local session_ids = {
                id1 = uuid.v7(),
                id2 = uuid.v7(),
                id3 = uuid.v7()
            }

            local initial_titles = {
                id1 = "First Test Session",
                id2 = "Second Test Session",
                id3 = "Third Test Session"
            }

            -- Create the sessions
            for id_key, id in pairs(session_ids) do
                local session, err = session_repo.create(
                    id,
                    user_id,
                    test_data.context_id,
                    initial_titles[id_key],
                    "isolation_test"
                )
                test.is_nil(err)
                test.not_nil(session)
                test.eq(session.title, initial_titles[id_key])
            end

            -- Verify all three sessions exist
            local all_sessions, err = session_repo.list_by_user(user_id)
            test.is_nil(err)

            local found_sessions = {}
            for _, session in ipairs(all_sessions) do
                for id_key, id in pairs(session_ids) do
                    if session.session_id == id then
                        found_sessions[id_key] = session
                        test.eq(session.title, initial_titles[id_key])
                    end
                end
            end

            test.not_nil(found_sessions.id1)
            test.not_nil(found_sessions.id2)
            test.not_nil(found_sessions.id3)

            -- Update just the second session's title
            local updated_title = "UPDATED Second Session"
            local result, err = session_repo.update_session_meta(
                session_ids.id2,
                { title = updated_title }
            )
            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.updated)

            -- Verify only the second session's title changed
            local updated_sessions, err = session_repo.list_by_user(user_id)
            test.is_nil(err)

            for _, session in ipairs(updated_sessions) do
                if session.session_id == session_ids.id1 then
                    test.eq(session.title, initial_titles.id1)
                elseif session.session_id == session_ids.id2 then
                    test.eq(session.title, updated_title)
                elseif session.session_id == session_ids.id3 then
                    test.eq(session.title, initial_titles.id3)
                end
            end

            -- Update metadata of just the first session
            local metadata_updates = {
                title = "META First Session",
                public_meta = { key = "value" }
            }

            result, err = session_repo.update_session_meta(session_ids.id1, metadata_updates)
            test.is_nil(err)
            test.not_nil(result)

            -- Verify isolation: only first session has updated metadata
            local final_sessions = {}
            for id_key, id in pairs(session_ids) do
                local session, err = session_repo.get(id)
                test.is_nil(err)
                final_sessions[id_key] = session
            end

            test.eq(final_sessions.id1.title, metadata_updates.title)
            test.eq(final_sessions.id1.public_meta.key, "value")

            test.eq(final_sessions.id2.title, updated_title)
            test.is_nil(final_sessions.id2.public_meta.key)

            test.eq(final_sessions.id3.title, initial_titles.id3)
            test.is_nil(final_sessions.id3.public_meta.key)

            -- Delete the second session
            result, err = session_repo.delete(session_ids.id2)
            test.is_nil(err)
            test.is_true(result.deleted)

            -- Verify deletion isolation
            local session, err = session_repo.get(session_ids.id2)
            test.is_nil(session)
            test.contains(tostring(err), "not found")

            session, err = session_repo.get(session_ids.id1)
            test.is_nil(err)
            test.not_nil(session)

            session, err = session_repo.get(session_ids.id3)
            test.is_nil(err)
            test.not_nil(session)

            -- Clean up
            session_repo.delete(session_ids.id1)
            session_repo.delete(session_ids.id3)
        end)
    end)
end

return test.run_cases(define_tests)
