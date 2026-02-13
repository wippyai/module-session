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

            expect(err).to_be_nil()
            expect(session).not_to_be_nil()
            expect(session.session_id).to_equal(test_data.session_id)
            expect(session.user_id).to_equal(test_data.user_id)
            expect(session.primary_context_id).to_equal(test_data.context_id)
            expect(session.title).to_equal("Test Session")
            expect(session.kind).to_equal("test")
            test.is_table(session.meta)
            expect(session.meta.model).to_equal("test-model")
            test.is_table(session.config)
            expect(session.config.max_tokens).to_equal(1000)
            expect(session.start_date).not_to_be_nil()
            expect(session.last_message_date).not_to_be_nil()
        end)

        it("should get a session by ID", function()
            local session, err = session_repo.get(test_data.session_id)

            expect(err).to_be_nil()
            expect(session).not_to_be_nil()
            expect(session.session_id).to_equal(test_data.session_id)
            expect(session.user_id).to_equal(test_data.user_id)
            expect(session.primary_context_id).to_equal(test_data.context_id)
            expect(session.title).to_equal("Test Session")
            expect(session.kind).to_equal("test")
            test.is_table(session.meta)
            expect(session.meta.model).to_equal("test-model")
            test.is_table(session.config)
            expect(session.config.max_tokens).to_equal(1000)
        end)

        it("should get a session by ID with user filter", function()
            local session, err = session_repo.get(test_data.session_id, test_data.user_id)
            expect(err).to_be_nil()
            expect(session).not_to_be_nil()
            expect(session.session_id).to_equal(test_data.session_id)

            -- Different user should not find the session
            session, err = session_repo.get(test_data.session_id, uuid.v7())
            expect(session).to_be_nil()
            test.contains(tostring(err), "not found")
        end)

        it("should list sessions by user ID", function()
            local sessions, err = session_repo.list_by_user(test_data.user_id)

            expect(err).to_be_nil()
            expect(sessions).not_to_be_nil()
            expect(#sessions >= 1).to_be_true()

            local found = false
            for _, session in ipairs(sessions) do
                if session.session_id == test_data.session_id then
                    found = true
                    break
                end
            end

            expect(found).to_be_true()
        end)

        it("should update session title via update_session_meta", function()
            local result, err = session_repo.update_session_meta(
                test_data.session_id,
                { title = "Updated Session Title" }
            )

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.session_id).to_equal(test_data.session_id)
            expect(result.title).to_equal("Updated Session Title")
            expect(result.updated).to_be_true()

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            expect(session.title).to_equal("Updated Session Title")
        end)

        it("should update last message date", function()
            local timestamp = os.time() - 3600
            local result, err = session_repo.update_session_meta(
                test_data.session_id,
                { last_message_date = timestamp }
            )

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.session_id).to_equal(test_data.session_id)
            expect(result.last_message_date).to_equal(time.unix(timestamp, 0):format(time.RFC3339))
            expect(result.updated).to_be_true()

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            expect(session.last_message_date).to_equal(time.unix(timestamp, 0):format(time.RFC3339))
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

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.session_id).to_equal(test_data.session_id)
            expect(result.title).to_equal(updates.title)
            expect(result.status).to_equal(updates.status)
            expect(result.kind).to_equal(updates.kind)
            expect(result.updated).to_be_true()

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            expect(session.title).to_equal(updates.title)
            expect(session.kind).to_equal(updates.kind)
            test.is_table(session.meta)
            expect(session.meta.model).to_equal("new-model")
            expect(session.meta.temperature).to_equal(0.7)
            test.is_table(session.config)
            expect(session.config.max_tokens).to_equal(2000)
            test.is_table(session.public_meta)
            expect(session.public_meta.theme).to_equal("dark")
        end)

        it("should count sessions by user", function()
            local count, err = session_repo.count_by_user(test_data.user_id)

            expect(err).to_be_nil()
            expect(count >= 1).to_be_true()
        end)

        it("should handle validation errors", function()
            -- Invalid session creation
            local session, err = session_repo.create(nil, test_data.user_id, test_data.context_id)
            expect(session).to_be_nil()
            test.contains(tostring(err), "Session ID is required")

            session, err = session_repo.create(uuid.v7(), "", test_data.context_id)
            expect(session).to_be_nil()
            test.contains(tostring(err), "User ID is required")

            session, err = session_repo.create(uuid.v7(), test_data.user_id, "")
            expect(session).to_be_nil()
            test.contains(tostring(err), "Primary context ID is required")

            -- Get with invalid ID
            session, err = session_repo.get("")
            expect(session).to_be_nil()
            test.contains(tostring(err), "Session ID is required")

            -- List with invalid user ID
            local sessions, err = session_repo.list_by_user("")
            expect(sessions).to_be_nil()
            test.contains(tostring(err), "User ID is required")

            -- Update with invalid session ID
            local result, err = session_repo.update_session_meta("", { title = "x" })
            expect(result).to_be_nil()
            test.contains(tostring(err), "Session ID is required")

            -- Update non-existent session
            result, err = session_repo.update_session_meta(uuid.v7(), { title = "x" })
            expect(result).to_be_nil()
            test.contains(tostring(err), "Session not found")

            -- Count with invalid user ID
            local count, err_count = session_repo.count_by_user("")
            expect(count).to_be_nil()
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

            expect(err).to_be_nil()

            -- Delete it
            local result, err = session_repo.delete(temp_session_id)

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify the deletion
            session, err = session_repo.get(temp_session_id)
            expect(session).to_be_nil()
            test.contains(tostring(err), "not found")

            -- Delete non-existent session
            result, err = session_repo.delete(uuid.v7())
            expect(result).to_be_nil()
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
                expect(err).to_be_nil()
                expect(session).not_to_be_nil()
                expect(session.title).to_equal(initial_titles[id_key])
            end

            -- Verify all three sessions exist
            local all_sessions, err = session_repo.list_by_user(user_id)
            expect(err).to_be_nil()

            local found_sessions = {}
            for _, session in ipairs(all_sessions) do
                for id_key, id in pairs(session_ids) do
                    if session.session_id == id then
                        found_sessions[id_key] = session
                        expect(session.title).to_equal(initial_titles[id_key])
                    end
                end
            end

            expect(found_sessions.id1).not_to_be_nil()
            expect(found_sessions.id2).not_to_be_nil()
            expect(found_sessions.id3).not_to_be_nil()

            -- Update just the second session's title
            local updated_title = "UPDATED Second Session"
            local result, err = session_repo.update_session_meta(
                session_ids.id2,
                { title = updated_title }
            )
            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.updated).to_be_true()

            -- Verify only the second session's title changed
            local updated_sessions, err = session_repo.list_by_user(user_id)
            expect(err).to_be_nil()

            for _, session in ipairs(updated_sessions) do
                if session.session_id == session_ids.id1 then
                    expect(session.title).to_equal(initial_titles.id1)
                elseif session.session_id == session_ids.id2 then
                    expect(session.title).to_equal(updated_title)
                elseif session.session_id == session_ids.id3 then
                    expect(session.title).to_equal(initial_titles.id3)
                end
            end

            -- Update metadata of just the first session
            local metadata_updates = {
                title = "META First Session",
                public_meta = { key = "value" }
            }

            result, err = session_repo.update_session_meta(session_ids.id1, metadata_updates)
            expect(err).to_be_nil()
            expect(result).not_to_be_nil()

            -- Verify isolation: only first session has updated metadata
            local final_sessions = {}
            for id_key, id in pairs(session_ids) do
                local session, err = session_repo.get(id)
                expect(err).to_be_nil()
                final_sessions[id_key] = session
            end

            expect(final_sessions.id1.title).to_equal(metadata_updates.title)
            expect(final_sessions.id1.public_meta.key).to_equal("value")

            expect(final_sessions.id2.title).to_equal(updated_title)
            expect(final_sessions.id2.public_meta.key).to_be_nil()

            expect(final_sessions.id3.title).to_equal(initial_titles.id3)
            expect(final_sessions.id3.public_meta.key).to_be_nil()

            -- Delete the second session
            result, err = session_repo.delete(session_ids.id2)
            expect(err).to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify deletion isolation
            local session, err = session_repo.get(session_ids.id2)
            expect(session).to_be_nil()
            test.contains(tostring(err), "not found")

            session, err = session_repo.get(session_ids.id1)
            expect(err).to_be_nil()
            expect(session).not_to_be_nil()

            session, err = session_repo.get(session_ids.id3)
            expect(err).to_be_nil()
            expect(session).not_to_be_nil()

            -- Clean up
            session_repo.delete(session_ids.id1)
            session_repo.delete(session_ids.id3)
        end)
    end)
end

return test.run_cases(define_tests)
