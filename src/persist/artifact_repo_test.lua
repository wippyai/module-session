local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local json = require("json")
local artifact_repo = require("artifact_repo")
local session_repo = require("session_repo")
local context_repo = require("context_repo")
local time = require("time")
local security = require("security")
local consts = require("consts")

local function define_tests()
    describe("Artifact Repository", function()
        -- Test data
        local test_data = {
            user_id = uuid.v7(),
            context_id = uuid.v7(),
            session_id = uuid.v7(),
            artifact_id = uuid.v7(),
            artifact_id2 = uuid.v7()
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
            tx:execute("DELETE FROM artifacts WHERE session_id = $1", { test_data.session_id })
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

        it("should create an artifact with string data", function()
            local artifact, err = artifact_repo.create(
                test_data.artifact_id,
                test_data.session_id,
                "static",
                "Test Artifact",
                "This is test artifact content"
            )

            expect(err).to_be_nil()
            expect(artifact).not_to_be_nil()
            expect(artifact.artifact_id).to_equal(test_data.artifact_id)
            expect(artifact.session_id).to_equal(test_data.session_id)
            expect(artifact.kind).to_equal("static")
            expect(artifact.title).to_equal("Test Artifact")
            expect(artifact.created_at).not_to_be_nil()
            expect(artifact.updated_at).not_to_be_nil()
        end)

        it("should create an artifact with metadata", function()
            local metadata = {
                content_type = "text/markdown",
                size = 1024,
                tags = {"test", "example"}
            }

            local artifact, err = artifact_repo.create(
                test_data.artifact_id2,
                test_data.session_id,
                "dynamic",
                "Metadata Artifact",
                "Artifact with metadata",
                metadata
            )

            expect(err).to_be_nil()
            expect(artifact).not_to_be_nil()
            expect(artifact.artifact_id).to_equal(test_data.artifact_id2)
            expect(artifact.session_id).to_equal(test_data.session_id)
            expect(artifact.kind).to_equal("dynamic")
            expect(artifact.title).to_equal("Metadata Artifact")
        end)

        it("should get an artifact by ID", function()
            local artifact, err = artifact_repo.get(test_data.artifact_id)

            expect(err).to_be_nil()
            expect(artifact).not_to_be_nil()
            expect(artifact.artifact_id).to_equal(test_data.artifact_id)
            expect(artifact.session_id).to_equal(test_data.session_id)
            expect(artifact.kind).to_equal("static")
            expect(artifact.title).to_equal("Test Artifact")
            expect(artifact.content).to_equal("This is test artifact content")
        end)

        it("should parse metadata JSON when retrieving", function()
            local artifact, err = artifact_repo.get(test_data.artifact_id2)

            expect(err).to_be_nil()
            expect(artifact).not_to_be_nil()
            expect(artifact.meta).not_to_be_nil()
            expect(artifact.meta.content_type).to_equal("text/markdown")
            expect(artifact.meta.size).to_equal(1024)
            expect(#artifact.meta.tags).to_equal(2)
            expect(artifact.meta.tags[1]).to_equal("test")
        end)

        it("should list artifacts by session ID", function()
            local artifacts, err = artifact_repo.list_by_session(test_data.session_id)

            expect(err).to_be_nil()
            expect(artifacts).not_to_be_nil()
            expect(#artifacts).to_equal(2)
        end)

        it("should list artifacts by kind", function()
            local artifacts, err = artifact_repo.list_by_kind(test_data.session_id, "static")

            expect(err).to_be_nil()
            expect(artifacts).not_to_be_nil()
            expect(#artifacts).to_equal(1)
            expect(artifacts[1].kind).to_equal("static")

            artifacts, err = artifact_repo.list_by_kind(test_data.session_id, "dynamic")
            expect(err).to_be_nil()
            expect(artifacts).not_to_be_nil()
            expect(#artifacts).to_equal(1)
            expect(artifacts[1].kind).to_equal("dynamic")
        end)

        it("should update artifact metadata", function()
            local updates = {
                title = "Updated Artifact",
                meta = {
                    content_type = "text/html",
                    size = 2048,
                    tags = {"updated", "example"}
                }
            }

            local update_result, err = artifact_repo.update(test_data.artifact_id, updates)

            expect(err).to_be_nil()
            expect(update_result).not_to_be_nil()
            expect(update_result.updated).to_be_true()

            -- Verify updates
            local artifact, err = artifact_repo.get(test_data.artifact_id)
            expect(err).to_be_nil()
            expect(artifact.title).to_equal("Updated Artifact")
            expect(artifact.meta.content_type).to_equal("text/html")
            expect(artifact.meta.size).to_equal(2048)
            expect(#artifact.meta.tags).to_equal(2)
            expect(artifact.meta.tags[1]).to_equal("updated")
        end)

        it("should update artifact content", function()
            local content = "This is updated content"
            local update_result, err = artifact_repo.update_content(test_data.artifact_id, content)

            expect(err).to_be_nil()
            expect(update_result).not_to_be_nil()
            expect(update_result.updated).to_be_true()

            -- Verify content update
            local artifact_content, err = artifact_repo.get_content(test_data.artifact_id)
            expect(err).to_be_nil()
            expect(artifact_content).to_equal(content)
        end)

        it("should count artifacts in a session", function()
            local count, err = artifact_repo.count_by_session(test_data.session_id)

            expect(err).to_be_nil()
            expect(count).to_equal(2)
        end)

        it("should count artifacts by kind", function()
            local count, err = artifact_repo.count_by_kind(test_data.session_id, "static")

            expect(err).to_be_nil()
            expect(count).to_equal(1)

            count, err = artifact_repo.count_by_kind(test_data.session_id, "dynamic")
            expect(err).to_be_nil()
            expect(count).to_equal(1)

            count, err = artifact_repo.count_by_kind(test_data.session_id, "nonexistent")
            expect(err).to_be_nil()
            expect(count).to_equal(0)
        end)

        it("should delete an artifact", function()
            -- First verify we can get the artifact
            local artifact, err = artifact_repo.get(test_data.artifact_id)
            expect(err).to_be_nil()
            expect(artifact).not_to_be_nil()

            -- Now delete it
            local result, err = artifact_repo.delete(test_data.artifact_id)

            expect(err).to_be_nil()
            expect(result).not_to_be_nil()
            expect(result.deleted).to_be_true()

            -- Verify the deletion
            artifact, err = artifact_repo.get(test_data.artifact_id)
            expect(artifact).to_be_nil()
            expect(err:match("not found")).not_to_be_nil()

            -- Count should now be 1
            local count, err = artifact_repo.count_by_session(test_data.session_id)
            expect(err).to_be_nil()
            expect(count).to_equal(1)
        end)

        it("should handle validation errors", function()
            -- Missing artifact_id
            local artifact, err = artifact_repo.create(nil, test_data.session_id, "static", "title", "content")
            expect(artifact).to_be_nil()
            expect(err:match("Artifact ID is required")).not_to_be_nil()

            -- Missing kind
            artifact, err = artifact_repo.create(uuid.v7(), test_data.session_id, "", "title", "content")
            expect(artifact).to_be_nil()
            expect(err:match("Artifact kind is required")).not_to_be_nil()

            -- Non-existent session
            artifact, err = artifact_repo.create(uuid.v7(), uuid.v7(), "static", "title", "content")
            expect(artifact).to_be_nil()
            expect(err:match("Session not found")).not_to_be_nil()

            -- Get with invalid ID
            artifact, err = artifact_repo.get("")
            expect(artifact).to_be_nil()
            expect(err:match("Artifact ID is required")).not_to_be_nil()

            -- List by invalid session ID
            local artifacts, err = artifact_repo.list_by_session("")
            expect(artifacts).to_be_nil()
            expect(err:match("Session ID is required")).not_to_be_nil()

            -- Delete with invalid ID
            local result, err = artifact_repo.delete("")
            expect(result).to_be_nil()
            expect(err:match("Artifact ID is required")).not_to_be_nil()
        end)
    end)
end

return test.run_cases(define_tests)
