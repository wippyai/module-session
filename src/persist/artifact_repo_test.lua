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

-- Insert an artifact directly via SQL (bypasses security.actor() requirement)
local function insert_artifact(db, artifact_id, session_id, user_id, kind, title, content, meta)
    local meta_json = nil
    if meta then
        local encoded, err = json.encode(meta)
        if not err then
            meta_json = encoded
        end
    end

    local now = time.now():format(time.RFC3339)
    db:execute(
        "INSERT INTO artifacts (artifact_id, session_id, user_id, kind, title, content, meta, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        { artifact_id, session_id, user_id, kind, title, content or "", meta_json, now, now }
    )
end

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
                "test"
            )

            if err then
                error("Failed to create test session: " .. err)
            end

            -- Insert test artifacts directly via SQL
            local db_resource, _ = consts.get_db_resource()
            local db, err = sql.get(db_resource)
            if err then
                error("Failed to connect to database: " .. err)
            end

            insert_artifact(db, test_data.artifact_id, test_data.session_id,
                test_data.user_id, "static", "Test Artifact", "This is test artifact content", nil)

            local metadata = {
                content_type = "text/markdown",
                size = 1024,
                tags = {"test", "example"}
            }
            insert_artifact(db, test_data.artifact_id2, test_data.session_id,
                test_data.user_id, "dynamic", "Metadata Artifact", "Artifact with metadata", metadata)

            db:release()
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

            tx:execute("DELETE FROM artifacts WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM messages WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM session_contexts WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM sessions WHERE session_id = $1", { test_data.session_id })
            tx:execute("DELETE FROM contexts WHERE context_id = $1", { test_data.context_id })

            local success, err = tx:commit()
            if err then
                tx:rollback()
                db:release()
                error("Failed to commit cleanup transaction: " .. err)
            end

            db:release()
        end)

        it("should require authenticated user for create", function()
            -- Without security context, create should return auth error
            local has_actor = security.actor() ~= nil
            if not has_actor then
                local artifact, err = artifact_repo.create(
                    uuid.v7(),
                    test_data.session_id,
                    "static",
                    "title",
                    "content"
                )
                test.is_nil(artifact)
                test.contains(tostring(err), "No authenticated user found")
            end
        end)

        it("should get an artifact by ID", function()
            local artifact, err = artifact_repo.get(test_data.artifact_id)

            test.is_nil(err)
            test.not_nil(artifact)
            test.eq(artifact.artifact_id, test_data.artifact_id)
            test.eq(artifact.session_id, test_data.session_id)
            test.eq(artifact.kind, "static")
            test.eq(artifact.title, "Test Artifact")
            test.eq(artifact.content, "This is test artifact content")
        end)

        it("should parse metadata JSON when retrieving", function()
            local artifact, err = artifact_repo.get(test_data.artifact_id2)

            test.is_nil(err)
            test.not_nil(artifact)
            test.not_nil(artifact.meta)
            test.eq(artifact.meta.content_type, "text/markdown")
            test.eq(artifact.meta.size, 1024)
            test.eq(#artifact.meta.tags, 2)
            test.eq(artifact.meta.tags[1], "test")
        end)

        it("should list artifacts by session ID", function()
            local artifacts, err = artifact_repo.list_by_session(test_data.session_id)

            test.is_nil(err)
            test.not_nil(artifacts)
            test.eq(#artifacts, 2)
        end)

        it("should list artifacts by kind", function()
            local artifacts, err = artifact_repo.list_by_kind(test_data.session_id, "static")

            test.is_nil(err)
            test.not_nil(artifacts)
            test.eq(#artifacts, 1)
            assert(artifacts)
            test.eq(artifacts[1].kind, "static")

            artifacts, err = artifact_repo.list_by_kind(test_data.session_id, "dynamic")
            test.is_nil(err)
            test.not_nil(artifacts)
            assert(artifacts)
            test.eq(#artifacts, 1)
            test.eq(artifacts[1].kind, "dynamic")
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

            test.is_nil(err)
            test.not_nil(update_result)
            test.is_true(update_result.updated)

            -- Verify updates
            local artifact, err = artifact_repo.get(test_data.artifact_id)
            test.is_nil(err)
            test.eq(artifact.title, "Updated Artifact")
            test.eq(artifact.meta.content_type, "text/html")
            test.eq(artifact.meta.size, 2048)
            test.eq(#artifact.meta.tags, 2)
            test.eq(artifact.meta.tags[1], "updated")
        end)

        it("should update artifact content", function()
            local content = "This is updated content"
            local update_result, err = artifact_repo.update_content(test_data.artifact_id, content)

            test.is_nil(err)
            test.not_nil(update_result)
            test.is_true(update_result.updated)

            -- Verify content update
            local artifact_content, err = artifact_repo.get_content(test_data.artifact_id)
            test.is_nil(err)
            test.eq(artifact_content, content)
        end)

        it("should count artifacts in a session", function()
            local count, err = artifact_repo.count_by_session(test_data.session_id)

            test.is_nil(err)
            test.eq(count, 2)
        end)

        it("should count artifacts by kind", function()
            local count, err = artifact_repo.count_by_kind(test_data.session_id, "static")

            test.is_nil(err)
            test.eq(count, 1)

            count, err = artifact_repo.count_by_kind(test_data.session_id, "dynamic")
            test.is_nil(err)
            test.eq(count, 1)

            count, err = artifact_repo.count_by_kind(test_data.session_id, "nonexistent")
            test.is_nil(err)
            test.eq(count, 0)
        end)

        it("should delete an artifact", function()
            -- Verify we can get the artifact
            local artifact, err = artifact_repo.get(test_data.artifact_id)
            test.is_nil(err)
            test.not_nil(artifact)

            -- Delete it
            local result, err = artifact_repo.delete(test_data.artifact_id)

            test.is_nil(err)
            test.not_nil(result)
            test.is_true(result.deleted)

            -- Verify the deletion
            artifact, err = artifact_repo.get(test_data.artifact_id)
            test.is_nil(artifact)
            test.contains(tostring(err), "not found")

            -- Count should now be 1
            local count, err = artifact_repo.count_by_session(test_data.session_id)
            test.is_nil(err)
            test.eq(count, 1)
        end)

        it("should handle validation errors", function()
            -- Get with invalid ID
            local artifact, err = artifact_repo.get("")
            test.is_nil(artifact)
            test.contains(tostring(err), "Artifact ID is required")

            -- List by invalid session ID
            local artifacts, err = artifact_repo.list_by_session("")
            test.is_nil(artifacts)
            test.contains(tostring(err), "Session ID is required")

            -- Delete with invalid ID
            local result, err = artifact_repo.delete("")
            test.is_nil(result)
            test.contains(tostring(err), "Artifact ID is required")

            -- Delete non-existent artifact
            result, err = artifact_repo.delete(uuid.v7())
            test.is_nil(result)
            test.contains(tostring(err), "Artifact not found")

            -- Update with invalid ID
            result, err = artifact_repo.update("", { title = "x" })
            test.is_nil(result)
            test.contains(tostring(err), "Artifact ID is required")

            -- Update content with invalid ID
            result, err = artifact_repo.update_content("", "content")
            test.is_nil(result)
            test.contains(tostring(err), "Artifact ID is required")
        end)
    end)
end

return test.run_cases(define_tests)
