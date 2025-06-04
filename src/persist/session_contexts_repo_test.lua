local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local session_contexts_repo = require("session_contexts_repo")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")

local function define_tests()
    describe("Session Contexts Repository", function()
        -- Test data
        local test_data = {
            user_id = uuid.v7(),
            context_id = uuid.v7(),
            session_id = uuid.v7(),
            context1_id = uuid.v7(),
            context2_id = uuid.v7()
        }
        local actor = security.actor()
        if actor then
            test_data.user_id = actor:id()
        end

        -- Setup test environment before all tests
        before_all(function()
            -- Create a test context
            local context, err = context_repo.create(
                test_data.context_id,
                "primary",
                "Test context data"
            )

            if err then
                error("Failed to create test context: " .. err)
            end

            -- Create a test session
            local session, err = session_repo.create(
                test_data.session_id,
                test_data.user_id,
                test_data.context_id,
                "Test Session",
                "test",
                "test-model",
                "test-agent"
            )

            if err then
                error("Failed to create test session: " .. err)
            end
        end)

        -- Clean up test data after all tests
        after_all(function()
            -- Get a database connection for cleanup
            local db, err = sql.get("app:db")
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
            tx:execute("DELETE FROM session_contexts WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM sessions WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM contexts WHERE context_id = $1", { test_data.context_id })

            -- Commit transaction
            local success, err = tx:commit()
            if err then
                tx:rollback()
                db:release()
                error("Failed to commit cleanup transaction: " .. err)
            end

            db:release()
        end)

        it("should create a session context", function()
            local context, err = session_contexts_repo.create(
                test_data.context1_id,
                test_data.session_id,
                "note",
                "This is a test note"
            )

            expect(err).to_be_nil()
            expect(context).not_to_be_nil()
            expect(context.id).to_equal(test_data.context1_id)
            expect(context.session_id).to_equal(test_data.session_id)
            expect(context.type).to_equal("note")
            expect(context.text).to_equal("This is a test note")
            expect(context.time).not_to_be_nil()
        end)

        it("should get a session context by ID", function()
            local context, err = session_contexts_repo.get(test_data.context1_id)

            expect(err).to_be_nil()
            expect(context).not_to_be_nil()
            expect(context.id).to_equal(test_data.context1_id)
            expect(context.session_id).to_equal(test_data.session_id)
            expect(context.type).to_equal("note")
            expect(context.text).to_equal("This is a test note")
        end)

        it("should create another session context with custom time", function()
            local custom_time = os.time() - 3600 -- 1 hour ago
            local context, err = session_contexts_repo.create(
                test_data.context2_id,
                test_data.session_id,
                "bookmark",
                "This is a bookmark",
                custom_time
            )

            expect(err).to_be_nil()
            expect(context).not_to_be_nil()
            expect(context.id).to_equal(test_data.context2_id)
            expect(context.session_id).to_equal(test_data.session_id)
            expect(context.type).to_equal("bookmark")
            expect(context.text).to_equal("This is a bookmark")
            expect(context.time).to_equal(time.unix(custom_time, 0):format(time.RFC3339))
        end)

        it("should list session contexts by session ID in ID order", function()
            local contexts, err = session_contexts_repo.list_by_session(test_data.session_id)

            expect(err).to_be_nil()
            expect(contexts).not_to_be_nil()
            expect(#contexts).to_equal(2)

            -- Contexts should be ordered by ID (which is UUID v7, so time-ordered)
            expect(contexts[1].id).to_equal(test_data.context1_id)
            expect(contexts[2].id).to_equal(test_data.context2_id)
        end)

        it("should list session contexts by type", function()
            local contexts, err = session_contexts_repo.list_by_type(test_data.session_id, "note")

            expect(err).to_be_nil()
            expect(contexts).not_to_be_nil()
            expect(#contexts).to_equal(1)
            expect(contexts[1].type).to_equal("note")

            contexts, err = session_contexts_repo.list_by_type(test_data.session_id, "bookmark")
            expect(err).to_be_nil()
            expect(contexts).not_to_be_nil()
            expect(#contexts).to_equal(1)
            expect(contexts[1].type).to_equal("bookmark")
        end)

        it("should update session context text", function()
            local result, err = session_contexts_repo.update_text(
                test_data.context1_id,
                "Updated note text"
            )

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.id).to_equal(test_data.context1_id)
            expect(result.text).to_equal("Updated note text")
            expect(result.updated).to_be_true()

            -- Verify the update
            local context, err = session_contexts_repo.get(test_data.context1_id)
            expect(context.text).to_equal("Updated note text")
        end)

        it("should count session contexts", function()
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)

            expect(err).to_be_nil()
            expect(count).to_equal(2)
        end)

        it("should delete a session context", function()
            local result, err = session_contexts_repo.delete(test_data.context1_id)

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify the deletion
            local context, err = session_contexts_repo.get(test_data.context1_id)
            expect(context).to_be_nil()
            expect(err:match("not found")).not_to_be_nil()

            -- Count should now be 1
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)
            expect(err).to_be_nil()
            expect(count).to_equal(1)
        end)

        it("should delete all contexts for a session", function()
            -- Create another context to delete
            local extra_context_id = uuid.v7()
            local context, err = session_contexts_repo.create(
                extra_context_id,
                test_data.session_id,
                "tag",
                "This is a tag"
            )
            expect(err).to_be_nil()

            -- Now there should be 2 contexts
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)
            expect(err).to_be_nil()
            expect(count).to_equal(2)

            -- Delete all contexts for the session
            local result, err = session_contexts_repo.delete_by_session(test_data.session_id)

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.deleted).to_be_true()
            expect(result.count).to_equal(2)

            -- Verify the deletion
            count, err = session_contexts_repo.count_by_session(test_data.session_id)
            expect(err).to_be_nil()
            expect(count).to_equal(0)
        end)

        it("should handle validation errors", function()
            -- Invalid context creation
            local context, err = session_contexts_repo.create(nil, test_data.session_id, "note", "text")
            expect(context).to_be_nil()
            expect(err:match("ID is required")).not_to_be_nil()

            context, err = session_contexts_repo.create(uuid.v7(), "", "note", "text")
            expect(context).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            context, err = session_contexts_repo.create(uuid.v7(), test_data.session_id, "", "text")
            expect(context).to_be_nil()
            expect(err:match("Context type is required")).not_to_be_nil()

            context, err = session_contexts_repo.create(uuid.v7(), test_data.session_id, "note", nil)
            expect(context).to_be_nil()
            expect(err:match("Text is required")).not_to_be_nil()

            -- Get with invalid ID
            context, err = session_contexts_repo.get("")
            expect(context).to_be_nil()
            expect(err:match("ID is required")).not_to_be_nil()

            -- List with invalid session ID
            local contexts, err = session_contexts_repo.list_by_session("")
            expect(contexts).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            -- Update with invalid ID
            local result, err = session_contexts_repo.update_text("", "text")
            expect(result).to_be_nil()
            expect(err:match("ID is required")).not_to_be_nil()

            -- Delete with invalid ID
            result, err = session_contexts_repo.delete("")
            expect(result).to_be_nil()
            expect(err:match("ID is required")).not_to_be_nil()
        end)
    end)
end

return test.run_cases(define_tests)