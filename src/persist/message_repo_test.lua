local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local json = require("json")
local message_repo = require("message_repo")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")
local consts = require("consts")

local function define_tests()
    describe("Message Repository", function()
        -- Test data
        local test_data = {
            user_id = uuid.v7(),
            context_id = uuid.v7(),
            session_id = uuid.v7(),
            message_id = uuid.v7(),
            message_id2 = uuid.v7()
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
            tx:execute("DELETE FROM messages WHERE session_id = $1", { test_data.session_id })
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

        it("should create a message with string data", function()
            local message, err = message_repo.create(
                test_data.message_id,
                test_data.session_id,
                "user",
                "This is a test message"
            )

            test.is_nil(err)
            test.not_nil(message)
            test.eq(message.message_id, test_data.message_id)
            test.eq(message.session_id, test_data.session_id)
            test.eq(message.type, "user")
            test.not_nil(message.date)
        end)

        it("should create a message with binary data and metadata", function()
            local metadata = {
                model = "test-model",
                tokens = {
                    prompt = 10,
                    completion = 5
                }
            }

            local message, err = message_repo.create(
                test_data.message_id2,
                test_data.session_id,
                "assistant",
                "This is a response message",
                metadata
            )

            test.is_nil(err)
            test.not_nil(message)
            test.eq(message.message_id, test_data.message_id2)
            test.eq(message.session_id, test_data.session_id)
            test.eq(message.type, "assistant")
        end)

        it("should get a message by ID", function()
            local message, err = message_repo.get(test_data.message_id)

            test.is_nil(err)
            test.not_nil(message)
            test.eq(message.message_id, test_data.message_id)
            test.eq(message.session_id, test_data.session_id)
            test.eq(message.type, "user")
            test.eq(message.data, "This is a test message")
        end)

        it("should parse metadata JSON when retrieving", function()
            local message, err = message_repo.get(test_data.message_id2)

            test.is_nil(err)
            test.not_nil(message)
            test.not_nil(message.metadata)
            test.eq(message.metadata.model, "test-model")
            test.eq(message.metadata.tokens.prompt, 10)
            test.eq(message.metadata.tokens.completion, 5)
        end)

        it("should list messages by session ID", function()
            local messages, err = message_repo.list_by_session(test_data.session_id)

            test.is_nil(err)
            test.not_nil(messages.messages)
            test.eq(#messages.messages, 2)
        end)

        it("should list messages by session ID with cursor pagination", function()
            -- Create additional messages to test pagination
            local message_ids = {}
            for i = 1, 5 do
                local message_id = uuid.v7()
                table.insert(message_ids, message_id)

                local result, err = message_repo.create(
                    message_id,
                    test_data.session_id,
                    "test_pagination",
                    "Message " .. i
                )
                test.is_nil(err)
                test.not_nil(result)
            end

            -- Test default pagination (no cursor)
            local result, err = message_repo.list_by_session(test_data.session_id)

            test.is_nil(err)
            test.not_nil(result)
            test.not_nil(result.messages)
            test.ok(#result.messages > 3)

            -- Extract cursor from first result
            assert(result.messages)
            local cursor = result.messages[3].message_id

            -- Test "before" pagination (older messages)
            local before_result, err = message_repo.list_by_session(test_data.session_id, 2, cursor, "before")
            test.is_nil(err)
            test.not_nil(before_result)
            test.not_nil(before_result.messages)
            test.eq(#before_result.messages, 2)
            test.not_nil(before_result.next_cursor)

            -- Test "after" pagination (newer messages)
            local after_result, err = message_repo.list_by_session(test_data.session_id, 2, cursor, "after")
            test.is_nil(err)
            test.not_nil(after_result)
            test.not_nil(after_result.messages)

            -- Test pagination with limit
            local limit_result, err = message_repo.list_by_session(test_data.session_id, 3)
            test.is_nil(err)
            test.not_nil(limit_result)
            test.eq(#limit_result.messages, 3)

            -- Clean up the test messages
            for _, message_id in ipairs(message_ids) do
                message_repo.delete(message_id)
            end
        end)

        it("should list messages by type", function()
            local messages, err = message_repo.list_by_type(test_data.session_id, "user")

            test.is_nil(err)
            test.not_nil(messages)
            assert(messages)
            test.eq(#messages, 1)
            test.eq(messages[1].type, "user")

            messages, err = message_repo.list_by_type(test_data.session_id, "assistant")
            test.is_nil(err)
            test.not_nil(messages)
            assert(messages)
            test.eq(#messages, 1)
            test.eq(messages[1].type, "assistant")
        end)

        it("should get the latest message", function()
            local message, err = message_repo.get_latest(test_data.session_id)
            test.is_nil(err)
            test.not_nil(message)
            -- The most recent message should be the assistant message (the second one created)
            test.eq(message.message_id, test_data.message_id2)
            test.eq(message.type, "assistant")
        end)

        it("should count messages in a session", function()
            local count, err = message_repo.count_by_session(test_data.session_id)

            test.is_nil(err)
            test.eq(count, 2)
        end)

        it("should count messages by type", function()
            local count, err = message_repo.count_by_type(test_data.session_id, "user")

            test.is_nil(err)
            test.eq(count, 1)

            count, err = message_repo.count_by_type(test_data.session_id, "assistant")
            test.is_nil(err)
            test.eq(count, 1)

            count, err = message_repo.count_by_type(test_data.session_id, "system")
            test.is_nil(err)
            test.eq(count, 0)
        end)

        it("should merge metadata when updating with existing metadata", function()
            -- message_id2 already has metadata: {model = "test-model", tokens = {prompt = 10, completion = 5}}
            local result, err = message_repo.update_metadata(test_data.message_id2, {
                status = "completed",
                score = 42
            })

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.updated)

            -- Verify the metadata was merged, not replaced
            local message, err = message_repo.get(test_data.message_id2)
            test.is_nil(err)
            test.not_nil(message)
            test.not_nil(message.metadata)

            -- Original fields should still be present
            test.eq(message.metadata.model, "test-model")
            test.not_nil(message.metadata.tokens)
            test.eq(message.metadata.tokens.prompt, 10)
            test.eq(message.metadata.tokens.completion, 5)

            -- New fields should be added
            test.eq(message.metadata.status, "completed")
            test.eq(message.metadata.score, 42)
        end)

        it("should overwrite existing keys when merging metadata", function()
            -- message_id2 now has merged metadata from previous test
            local result, err = message_repo.update_metadata(test_data.message_id2, {
                model = "updated-model"
            })

            test.is_nil(err)
            test.not_nil(result)

            local message, err = message_repo.get(test_data.message_id2)
            test.is_nil(err)

            -- Overwritten key
            test.eq(message.metadata.model, "updated-model")
            -- Other keys preserved
            test.eq(message.metadata.status, "completed")
            test.not_nil(message.metadata.tokens)
        end)

        it("should set metadata on message without existing metadata", function()
            -- message_id has no metadata (created as plain user message)
            local result, err = message_repo.update_metadata(test_data.message_id, {
                custom_key = "custom_value"
            })

            test.is_nil(err)
            test.not_nil(result)

            local message, err = message_repo.get(test_data.message_id)
            test.is_nil(err)
            test.not_nil(message.metadata)
            test.eq(message.metadata.custom_key, "custom_value")
        end)

        it("should handle update_metadata validation errors", function()
            -- Missing message_id
            local result, err = message_repo.update_metadata("", { key = "value" })
            test.is_nil(result)
            test.contains(tostring(err), "Message ID is required")

            -- Missing metadata
            result, err = message_repo.update_metadata(test_data.message_id2, nil)
            test.is_nil(result)
            test.contains(tostring(err), "Metadata is required")

            -- Non-existent message
            result, err = message_repo.update_metadata(uuid.v7(), { key = "value" })
            test.is_nil(result)
            test.contains(tostring(err), "not found")
        end)

        it("should delete a message", function()
            -- First verify we can get the message
            local message, err = message_repo.get(test_data.message_id)
            test.is_nil(err)
            test.not_nil(message)

            -- Now delete it
            local result, err = message_repo.delete(test_data.message_id)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deletion
            message, err = message_repo.get(test_data.message_id)
            test.is_nil(message)
            test.contains(tostring(err), "not found")

            -- Count should now be 1
            local count, err = message_repo.count_by_session(test_data.session_id)
            test.is_nil(err)
            test.eq(count, 1)
        end)

        it("should handle validation errors", function()
            -- Missing message_id
            local message, err = message_repo.create(nil, test_data.session_id, "user", "data")
            test.is_nil(message)
            test.contains(tostring(err), "Message ID is required")

            -- Missing session_id
            message, err = message_repo.create(uuid.v7(), "", "user", "data")
            test.is_nil(message)
            test.contains(tostring(err), "Session ID is required")

            -- Missing type
            message, err = message_repo.create(uuid.v7(), test_data.session_id, "", "data")
            test.is_nil(message)
            test.contains(tostring(err), "Message type is required")

            -- Missing data
            message, err = message_repo.create(uuid.v7(), test_data.session_id, "user", nil)
            test.is_nil(message)
            test.contains(tostring(err), "Message data is required")

            -- Non-existent session
            message, err = message_repo.create(uuid.v7(), uuid.v7(), "user", "data")
            test.is_nil(message)
            test.not_nil(err)

            -- Get with invalid ID
            message, err = message_repo.get("")
            test.is_nil(message)
            test.contains(tostring(err), "Message ID is required")

            -- List by invalid session ID
            local messages, err = message_repo.list_by_session("")
            test.is_nil(messages)
            test.contains(tostring(err), "Session ID is required")

            -- Delete with invalid ID
            local result, err = message_repo.delete("")
            test.is_nil(result)
            test.contains(tostring(err), "Message ID is required")
        end)
    end)
end

return test.run_cases(define_tests)
