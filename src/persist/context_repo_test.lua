local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local context_repo = require("context_repo")
local time = require("time")
local consts = require("consts")

local function define_tests()
    describe("Context Repository", function()
        -- Test data
        local test_data = {
            context_id = uuid.v7(),
            context_id2 = uuid.v7()
        }

        -- Clean up test data after all tests
        after_all(function()
            -- Get a database connection for cleanup
            local db_resource, _ = consts.get_db_resource()
            local db, err = sql.get(db_resource)
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Delete test contexts
            db:execute("DELETE FROM contexts WHERE context_id IN ($1, $2)",
                { test_data.context_id, test_data.context_id2 })

            db:release()
        end)

        it("should create a new context", function()
            local context, err = context_repo.create(
                test_data.context_id,
                "test_type",
                "This is test context data"
            )

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.context_id, test_data.context_id)
            test.eq(context.type, "test_type")
        end)

        it("should get a context by ID", function()
            local context, err = context_repo.get(test_data.context_id)

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.context_id, test_data.context_id)
            test.eq(context.type, "test_type")
            test.eq(context.data, "This is test context data")
        end)

        it("should create another context of same type", function()
            local context, err = context_repo.create(
                test_data.context_id2,
                "test_type",
                "Another test context data"
            )

            test.is_nil(err)
            test.not_nil(context)
            test.eq(context.context_id, test_data.context_id2)
        end)

        it("should get contexts by type", function()
            local contexts, err = context_repo.get_by_type("test_type")

            test.is_nil(err)
            test.not_nil(contexts)
            test.is_true(#contexts >= 2)

            -- Find our test contexts in the results
            local found_id1 = false
            local found_id2 = false

            for _, context in ipairs(contexts) do
                if context.context_id == test_data.context_id then
                    found_id1 = true
                end
                if context.context_id == test_data.context_id2 then
                    found_id2 = true
                end
            end

            test.is_true(found_id1)
            test.is_true(found_id2)
        end)

        it("should get contexts by type with limit and offset", function()
            -- First, get with limit 1
            local contexts, err = context_repo.get_by_type("test_type", 1)

            test.is_nil(err)
            test.not_nil(contexts)
            test.eq(#contexts, 1)

            -- Then, get with offset 1 to get the second record
            contexts, err = context_repo.get_by_type("test_type", 1, 1)

            test.is_nil(err)
            test.not_nil(contexts)
            test.eq(#contexts, 1)

            -- The two contexts should be different
            local first_context_id = nil
            local second_context_id = nil

            -- Get first context
            contexts, err = context_repo.get_by_type("test_type", 1)
            assert(contexts)
            first_context_id = contexts[1].context_id

            -- Get second context
            contexts, err = context_repo.get_by_type("test_type", 1, 1)
            assert(contexts)
            second_context_id = contexts[1].context_id

            test.neq(first_context_id, second_context_id)
        end)

        it("should update context data", function()
            local updated, err = context_repo.update(
                test_data.context_id,
                "Updated context data"
            )

            test.is_nil(err)
            test.not_nil(updated)
            test.eq(updated.context_id, test_data.context_id)
            test.is_true(updated.updated)

            -- Verify the update by getting the context
            local context, err = context_repo.get(test_data.context_id)
            test.eq(context.data, "Updated context data")
        end)

        it("should delete a context", function()
            local result, err = context_repo.delete(test_data.context_id2)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deletion by trying to get the context
            local context, err = context_repo.get(test_data.context_id2)
            test.is_nil(context)
            test.not_nil(err)
            test.contains(tostring(err), "not found")
        end)

        it("should handle validation errors", function()
            -- Missing context_id
            local context, err = context_repo.create(nil, "test_type", "data")
            test.is_nil(context)
            test.contains(tostring(err), "Context ID is required")

            -- Missing type
            context, err = context_repo.create(uuid.v7(), "", "data")
            test.is_nil(context)
            test.contains(tostring(err), "Context type is required")

            -- Get with invalid ID
            context, err = context_repo.get("")
            test.is_nil(context)
            test.contains(tostring(err), "Context ID is required")

            -- Update with invalid ID
            local result, err = context_repo.update("", "data")
            test.is_nil(result)
            test.contains(tostring(err), "Context ID is required")

            -- Update non-existent context
            result, err = context_repo.update(uuid.v7(), "data")
            test.is_nil(result)
            test.contains(tostring(err), "Context not found")

            -- Delete with invalid ID
            result, err = context_repo.delete("")
            test.is_nil(result)
            test.contains(tostring(err), "Context ID is required")

            -- Delete non-existent context
            result, err = context_repo.delete(uuid.v7())
            test.is_nil(result)
            test.contains(tostring(err), "Context not found")
        end)

        it("should only delete the target context without affecting others", function()
            -- Create three test contexts with different IDs but same type
            local test_ids = {
                id1 = uuid.v7(),
                id2 = uuid.v7(),
                id3 = uuid.v7()
            }

            -- Create the contexts
            for i, id in pairs(test_ids) do
                local context, err = context_repo.create(
                    id,
                    "delete_test_type",
                    "Test data for context " .. i
                )
                test.is_nil(err)
                test.not_nil(context)
            end

            -- Verify all three contexts exist
            local all_contexts, err = context_repo.get_by_type("delete_test_type")
            test.is_nil(err)
            test.is_true(#all_contexts >= 3)

            -- Count how many of our test contexts exist
            local context_count = 0
            for _, context in ipairs(all_contexts) do
                for _, id in pairs(test_ids) do
                    if context.context_id == id then
                        context_count = context_count + 1
                    end
                end
            end
            test.eq(context_count, 3)

            -- Delete just the second context
            local result, err = context_repo.delete(test_ids.id2)
            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deleted context no longer exists
            local deleted_context, err = context_repo.get(test_ids.id2)
            test.is_nil(deleted_context)
            test.contains(tostring(err), "Context not found")

            -- Verify the other contexts still exist
            local context1, err = context_repo.get(test_ids.id1)
            test.is_nil(err)
            test.not_nil(context1)
            test.eq(context1.context_id, test_ids.id1)

            local context3, err = context_repo.get(test_ids.id3)
            test.is_nil(err)
            test.not_nil(context3)
            test.eq(context3.context_id, test_ids.id3)

            -- Clean up the remaining test contexts
            context_repo.delete(test_ids.id1)
            context_repo.delete(test_ids.id3)
        end)
    end)
end

return test.run_cases(define_tests)
