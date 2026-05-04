local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local session_contexts_repo = require("session_contexts_repo")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")
local consts = require("consts")
local wait_for_boot = require("wait_for_boot")

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
            wait_for_boot.run()

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
                "test"
            )

            if err then
                error("Failed to create test session: " .. err)
            end
        end)

        -- Clean up test data after all tests
        after_all(function()
            -- Get a database connection for cleanup
            local db_resource, _ = consts.get_db_resource()
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

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.id, test_data.context1_id)
            test.eq(context.session_id, test_data.session_id)
            test.eq(context.type, "note")
            test.eq(context.text, "This is a test note")
            test.not_nil(context.time)
        end)

        it("should get a session context by ID", function()
            local context, err = session_contexts_repo.get(test_data.context1_id)

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.id, test_data.context1_id)
            test.eq(context.session_id, test_data.session_id)
            test.eq(context.type, "note")
            test.eq(context.text, "This is a test note")
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

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.id, test_data.context2_id)
            test.eq(context.session_id, test_data.session_id)
            test.eq(context.type, "bookmark")
            test.eq(context.text, "This is a bookmark")
            test.eq(context.time, time.unix(custom_time, 0):format(time.RFC3339))
        end)

        it("should list session contexts by session ID in ID order", function()
            local contexts, err = session_contexts_repo.list_by_session(test_data.session_id)

            test.is_nil(err)
            test.not_nil(contexts)
            test.eq(#contexts, 2)

            -- Contexts should be ordered by ID (which is UUID v7, so time-ordered)
            assert(contexts)
            test.eq(contexts[1].id, test_data.context1_id)
            test.eq(contexts[2].id, test_data.context2_id)
        end)

        it("should list session contexts by type", function()
            local contexts, err = session_contexts_repo.list_by_type(test_data.session_id, "note")

            test.is_nil(err)
            test.not_nil(contexts)
            assert(contexts)
            test.eq(#contexts, 1)
            test.eq(contexts[1].type, "note")

            contexts, err = session_contexts_repo.list_by_type(test_data.session_id, "bookmark")
            test.is_nil(err)
            test.not_nil(contexts)
            assert(contexts)
            test.eq(#contexts, 1)
            test.eq(contexts[1].type, "bookmark")
        end)

        it("should update session context text", function()
            local result, err = session_contexts_repo.update_text(
                test_data.context1_id,
                "Updated note text"
            )

            test.is_nil(err)
            test.not_nil(result)
            test.eq(result.id, test_data.context1_id)
            test.eq(result.text, "Updated note text")
            test.is_true(result.updated)

            -- Verify the update
            local context, err = session_contexts_repo.get(test_data.context1_id)
            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.text, "Updated note text")
        end)

        it("should count session contexts", function()
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)

            test.is_nil(err)
            test.eq(count, 2)
        end)

        it("should delete a session context", function()
            local result, err = session_contexts_repo.delete(test_data.context1_id)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deletion
            local context, err = session_contexts_repo.get(test_data.context1_id)
            test.is_nil(context)
            test.contains(tostring(err), "not found")

            -- Count should now be 1
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)
            test.is_nil(err)
            test.eq(count, 1)
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
            test.is_nil(err)

            -- Now there should be 2 contexts
            local count, err = session_contexts_repo.count_by_session(test_data.session_id)
            test.is_nil(err)
            test.eq(count, 2)

            -- Delete all contexts for the session
            local result, err = session_contexts_repo.delete_by_session(test_data.session_id)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)
            test.eq(result.count, 2)

            -- Verify the deletion
            count, err = session_contexts_repo.count_by_session(test_data.session_id)
            test.is_nil(err)
            test.eq(count, 0)
        end)

        it("should handle validation errors", function()
            -- Invalid context creation
            local context, err = session_contexts_repo.create(nil, test_data.session_id, "note", "text")
            test.is_nil(context)
            test.contains(tostring(err), "ID is required")

            context, err = session_contexts_repo.create(uuid.v7(), "", "note", "text")
            test.is_nil(context)
            test.contains(tostring(err), "Session ID is required")

            context, err = session_contexts_repo.create(uuid.v7(), test_data.session_id, "", "text")
            test.is_nil(context)
            test.contains(tostring(err), "Context type is required")

            context, err = session_contexts_repo.create(uuid.v7(), test_data.session_id, "note", nil)
            test.is_nil(context)
            test.contains(tostring(err), "Text is required")

            -- Get with invalid ID
            context, err = session_contexts_repo.get("")
            test.is_nil(context)
            test.contains(tostring(err), "ID is required")

            -- List with invalid session ID
            local contexts, err = session_contexts_repo.list_by_session("")
            test.is_nil(contexts)
            test.contains(tostring(err), "Session ID is required")

            -- Update with invalid ID
            local result, err = session_contexts_repo.update_text("", "text")
            test.is_nil(result)
            test.contains(tostring(err), "ID is required")

            -- Delete with invalid ID
            result, err = session_contexts_repo.delete("")
            test.is_nil(result)
            test.contains(tostring(err), "ID is required")
        end)
    end)
end

return test.run_cases(define_tests)
