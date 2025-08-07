local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")
local env = require("env")

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
            -- Get a database connection for cleanup
            local db_resource, _ = env.get("wippy.session:target_db")
            local db, err = sql.get(db_resource)
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Begin transaction for cleanup
            local tx, err = db:begin()
            if err then
                db:release()
                error("Failed to begin transaction: " .. err)
            end

            -- Delete test data in proper order (respecting foreign key constraints)
            -- tx:execute("DELETE FROM token_usage WHERE session_id = $1", { test_data.session_id }) -- there is no session_id in token_usage
            tx:execute("DELETE FROM messages WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM session_contexts WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM sessions WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM contexts WHERE context_id IN ($1, $1)",
                { test_data.context_id, test_data.context_id2 })

            -- Commit transaction
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
                "test-model",
                "test-agent"
            )

            expect(err).to_be_nil()
            expect(session).not_to_be_nil()
            expect(session.session_id).to_equal(test_data.session_id)
            expect(session.user_id).to_equal(test_data.user_id)
            expect(session.primary_context_id).to_equal(test_data.context_id)
            expect(session.title).to_equal("Test Session")
            expect(session.kind).to_equal("test")
            expect(session.current_model).to_equal("test-model")
            expect(session.current_agent).to_equal("test-agent")
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
        end)

        it("should list sessions by user ID", function()
            local sessions, err = session_repo.list_by_user(test_data.user_id)

            expect(err).to_be_nil()
            expect(sessions).not_to_be_nil()
            expect(#sessions >= 1).to_be_true()

            -- Find our test session
            local found = false
            for _, session in ipairs(sessions) do
                if session.session_id == test_data.session_id then
                    found = true
                    break
                end
            end

            expect(found).to_be_true()
        end)

        it("should update session title", function()
            local result, err = session_repo.update_title(
                test_data.session_id,
                "Updated Session Title"
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
            local now = os.time() - 3600 -- 1 hour ago
            local result, err = session_repo.update_last_message_date(
                test_data.session_id,
                now
            )

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.session_id).to_equal(test_data.session_id)
            expect(result.last_message_date).to_equal(time.unix(now, 0):format(time.RFC3339))
            expect(result.updated).to_be_true()

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            expect(session.last_message_date).to_equal(time.unix(now, 0):format(time.RFC3339))
        end)

        it("should update session metadata", function()
            local updates = {
                title = "Meta Updated Title",
                current_model = "new-model",
                current_agent = "new-agent",
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
            expect(result.current_model).to_equal(updates.current_model)
            expect(result.current_agent).to_equal(updates.current_agent)
            expect(result.last_message_date).to_equal(time.unix(updates.last_message_date, 0):format(time.RFC3339))
            expect(result.updated).to_be_true()

            -- Verify the update
            local session, err = session_repo.get(test_data.session_id)
            expect(session.title).to_equal(updates.title)
            expect(session.current_model).to_equal(updates.current_model)
            expect(session.current_agent).to_equal(updates.current_agent)
            expect(session.last_message_date).to_equal(time.unix(updates.last_message_date, 0):format(time.RFC3339))
        end)

        it("should handle validation errors", function()
            -- Invalid session creation
            local session, err = session_repo.create(nil, test_data.user_id, test_data.context_id)
            expect(session).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            session, err = session_repo.create(uuid.v7(), "", test_data.context_id)
            expect(session).to_be_nil()
            expect(err:match("User ID is required")).not_to_be_nil()

            session, err = session_repo.create(uuid.v7(), test_data.user_id, "")
            expect(session).to_be_nil()
            expect(err:match("Primary context ID is required")).not_to_be_nil()

            -- Get with invalid ID
            session, err = session_repo.get("")
            expect(session).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            -- List with invalid user ID
            local sessions, err = session_repo.list_by_user("")
            expect(sessions).to_be_nil()
            expect(err:match("User ID is required")).not_to_be_nil()

            -- Update title with invalid session ID
            local result, err = session_repo.update_title("", "title")
            expect(result).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            -- Update non-existent session
            result, err = session_repo.update_title(uuid.v7(), "title")
            expect(result).to_be_nil()
            expect(err:match("Session not found")).not_to_be_nil()
        end)

        it("should delete a session", function()
            -- First create a session that we can delete
            local temp_session_id = uuid.v7()
            local session, err = session_repo.create(
                temp_session_id,
                test_data.user_id,
                test_data.context_id,
                "Temporary Session"
            )

            expect(err).to_be_nil()

            -- Now delete it
            local result, err = session_repo.delete(temp_session_id)

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify the deletion
            session, err = session_repo.get(temp_session_id)
            expect(session).to_be_nil()
            expect(err:match("not found")).not_to_be_nil()

            -- Try to delete a non-existent session
            result, err = session_repo.delete(uuid.v7())
            expect(result).to_be_nil()
            expect(err:match("Session not found")).not_to_be_nil()
        end)

        it("should only update the target session without affecting others", function()
            -- Create three test sessions with different IDs but same user
            local user_id = test_data.user_id
            local session_ids = {
                id1 = uuid.v7(),
                id2 = uuid.v7(),
                id3 = uuid.v7()
            }

            -- Initial titles for all sessions
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
                    "isolation_test",
                    "test-model",
                    "test-agent"
                )
                expect(err).to_be_nil()
                expect(session).not_to_be_nil()
                expect(session.title).to_equal(initial_titles[id_key])
            end

            -- Verify all three sessions exist with correct initial titles
            local all_sessions, err = session_repo.list_by_user(user_id)
            expect(err).to_be_nil()

            -- Count how many of our test sessions exist and verify titles
            local found_sessions = {}
            for _, session in ipairs(all_sessions) do
                for id_key, id in pairs(session_ids) do
                    if session.session_id == id then
                        found_sessions[id_key] = session
                        expect(session.title).to_equal(initial_titles[id_key])
                    end
                end
            end

            -- Make sure we found all our test sessions
            expect(found_sessions.id1).not_to_be_nil()
            expect(found_sessions.id2).not_to_be_nil()
            expect(found_sessions.id3).not_to_be_nil()

            -- Update just the second session's title
            local updated_title = "UPDATED Second Session"
            local result, err = session_repo.update_title(session_ids.id2, updated_title)
            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.updated).to_be_true()

            -- Verify only the second session's title was updated
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
                current_model = "new-model-first",
                current_agent = "new-agent-first",
                public_meta = { key = "value" }
            }

            result, err = session_repo.update_session_meta(session_ids.id1, metadata_updates)
            expect(err).to_be_nil()
            expect(result).not_to_be_nil()

            -- Now get all sessions and verify that only the first session was updated with metadata
            -- and only the second session has the title previously updated
            local final_sessions = {}

            for id_key, id in pairs(session_ids) do
                local session, err = session_repo.get(id)
                expect(err).to_be_nil()
                final_sessions[id_key] = session
            end

            -- First session should have updated metadata
            expect(final_sessions.id1.title).to_equal(metadata_updates.title)
            expect(final_sessions.id1.current_model).to_equal(metadata_updates.current_model)
            expect(final_sessions.id1.current_agent).to_equal(metadata_updates.current_agent)
            expect(final_sessions.id1.public_meta.key).to_equal(metadata_updates.public_meta.key)

            -- Second session should have only updated title
            expect(final_sessions.id2.title).to_equal(updated_title)
            expect(final_sessions.id2.current_model).to_equal("test-model")
            expect(final_sessions.id2.current_agent).to_equal("test-agent")
            expect(final_sessions.id2.public_meta.key).to_be_nil()

            -- Third session should be unchanged
            expect(final_sessions.id3.title).to_equal(initial_titles.id3)
            expect(final_sessions.id3.current_model).to_equal("test-model")
            expect(final_sessions.id3.current_agent).to_equal("test-agent")
            expect(final_sessions.id3.public_meta.key).to_be_nil()

            -- Delete the second session
            result, err = session_repo.delete(session_ids.id2)
            expect(err).to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify the second session is gone but others remain
            local session, err = session_repo.get(session_ids.id2)
            expect(session).to_be_nil()
            expect(err:match("not found")).not_to_be_nil()

            -- First and third sessions should still exist
            session, err = session_repo.get(session_ids.id1)
            expect(err).to_be_nil()
            expect(session).not_to_be_nil()

            session, err = session_repo.get(session_ids.id3)
            expect(err).to_be_nil()
            expect(session).not_to_be_nil()

            -- Clean up remaining test sessions
            session_repo.delete(session_ids.id1)
            session_repo.delete(session_ids.id3)
        end)
    end)
end

return test.run_cases(define_tests)
