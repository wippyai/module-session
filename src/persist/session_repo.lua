local sql = require("sql")
local json = require("json")
local time = require("time")
local env = require("env")

-- Constants
local session_repo = {}

-- Get a database connection
local function get_db()
    local DB_RESOURCE, _ = env.get("wippy.session:env-target_db")

    local db, err = sql.get(DB_RESOURCE)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

-- Create a new session
function session_repo.create(session_id, user_id, primary_context_id, title, kind, current_model, current_agent)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    if not primary_context_id or primary_context_id == "" then
        return nil, "Primary context ID is required"
    end

    -- Default values for optional parameters
    title = title or ""
    kind = kind or "default"
    current_model = current_model or ""
    current_agent = current_agent or ""

    local db, err = get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the INSERT query
    local query = sql.builder.insert("sessions")

        :set_map({
            session_id = session_id,
            user_id = user_id,
            primary_context_id = primary_context_id,
            title = title,
            kind = kind,
            current_model = current_model,
            current_agent = current_agent,
            start_date = now,
            last_message_date = now
        })

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to create session: " .. err
    end

    return {
        session_id = session_id,
        user_id = user_id,
        primary_context_id = primary_context_id,
        title = title,
        kind = kind,
        current_model = current_model,
        current_agent = current_agent,
        public_meta = {}, -- Return empty table for public_meta
        start_date = now,
        last_message_date = now
    }
end

-- Get a session by ID
function session_repo.get(session_id)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the SELECT query
    local query = sql.builder.select(
            "session_id", "user_id", "status", "primary_context_id",
            "title", "kind", "current_model", "current_agent",
            "public_meta", "start_date", "last_message_date"
        )
        :from("sessions")
        :where("session_id = ?", session_id)
        :limit(1)

    -- Execute the query
    local executor = query:run_with(db)
    local sessions, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to get session: " .. err
    end

    if #sessions == 0 then
        return nil, "Session not found"
    end

    -- Parse public_meta from JSON string to table
    local session = sessions[1]
    if session.public_meta and session.public_meta ~= "" then
        local decoded, err = json.decode(session.public_meta)
        if not err then
            session.public_meta = decoded
        else
            -- Fallback to empty table if JSON parsing fails
            session.public_meta = {}
        end
    else
        session.public_meta = {}
    end

    return session
end

-- List sessions by user ID
function session_repo.list_by_user(user_id, limit, offset)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the SELECT query
    local query = sql.builder.select(
            "session_id", "user_id", "status", "primary_context_id",
            "title", "kind", "current_model", "current_agent",
            "public_meta", "start_date", "last_message_date"
        )
        :from("sessions")
        :where("user_id = ?", user_id)
        :order_by("last_message_date DESC")

    -- Add limit and offset if provided
    if limit and limit > 0 then
        query = query:limit(limit)
        if offset and offset > 0 then
            query = query:offset(offset)
        end
    end

    -- Execute the query
    local executor = query:run_with(db)
    local sessions, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list sessions: " .. err
    end

    -- Parse public_meta for each session
    for i, session in ipairs(sessions) do
        if session.public_meta and session.public_meta ~= "" then
            local decoded, err = json.decode(session.public_meta)
            if not err then
                session.public_meta = decoded
            else
                -- Fallback to empty table if JSON parsing fails
                session.public_meta = {}
            end
        else
            session.public_meta = {}
        end
    end

    return sessions
end

-- Update session title
function session_repo.update_title(session_id, title)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    if not title then
        title = "" -- Default to empty string if title is nil
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Check if session exists
    local check_query = sql.builder.select("session_id")
        :from("sessions")
        :where("session_id = ?", session_id)

    local check_executor = check_query:run_with(db)
    local sessions, err = check_executor:query()

    if err then
        db:release()
        return nil, "Failed to check if session exists: " .. err
    end

    if #sessions == 0 then
        db:release()
        return nil, "Session not found"
    end

    -- Update session title
    local update_query = sql.builder.update("sessions")

        :set("title", title)
        :where("session_id = ?", session_id)

    local update_executor = update_query:run_with(db)
    local result, err = update_executor:exec()

    db:release()

    if err then
        return nil, "Failed to update session title: " .. err
    end

    return {
        session_id = session_id,
        title = title,
        updated = true
    }
end

-- Update session public metadata
function session_repo.update_public_meta(session_id, public_meta)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    -- Default to empty table if public_meta is nil
    public_meta = public_meta or {}

    -- Encode the table as JSON
    local encoded_meta, err = json.encode(public_meta)
    if err then
        return nil, "Failed to encode public_meta to JSON: " .. err
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Check if session exists
    local check_query = sql.builder.select("session_id")
        :from("sessions")
        :where("session_id = ?", session_id)

    local check_executor = check_query:run_with(db)
    local sessions, err = check_executor:query()

    if err then
        db:release()
        return nil, "Failed to check if session exists: " .. err
    end

    if #sessions == 0 then
        db:release()
        return nil, "Session not found"
    end

    -- Update session public metadata
    local update_query = sql.builder.update("sessions")

        :set("public_meta", encoded_meta)
        :where("session_id = ?", session_id)

    local update_executor = update_query:run_with(db)
    local result, err = update_executor:exec()

    db:release()

    if err then
        return nil, "Failed to update session public metadata: " .. err
    end

    return {
        session_id = session_id,
        public_meta = public_meta, -- Return the original table
        updated = true
    }
end

-- Update last message date
function session_repo.update_last_message_date(session_id, date)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    -- Default to current time if date not provided
    date = date or os.time()
    date = time.unix(date, 0):format(time.RFC3339)

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Check if session exists
    local check_query = sql.builder.select("session_id")
        :from("sessions")
        :where("session_id = ?", session_id)

    local check_executor = check_query:run_with(db)
    local sessions, err = check_executor:query()

    if err then
        db:release()
        return nil, "Failed to check if session exists: " .. err
    end

    if #sessions == 0 then
        db:release()
        return nil, "Session not found"
    end

    -- Use sql.builder.expr to handle the timestamp properly
    local update_query = sql.builder.update("sessions")

        :set("last_message_date", date)
        :where("session_id = ?", session_id)

    local update_executor = update_query:run_with(db)
    local result, err = update_executor:exec()

    db:release()

    if err then
        return nil, "Failed to update last message date: " .. err
    end

    return {
        session_id = session_id,
        last_message_date = date,
        updated = true
    }
end

-- Update session metadata (model, agent, public_meta, and last_message_date) in a single transaction
function session_repo.update_session_meta(session_id, updates)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    if not updates or type(updates) ~= "table" then
        return nil, "Updates table is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Check if session exists
    local check_query = sql.builder.select("session_id")
        :from("sessions")
        :where("session_id = ?", session_id)

    local check_executor = check_query:run_with(db)
    local sessions, err = check_executor:query()

    if err then
        db:release()
        return nil, "Failed to check if session exists: " .. err
    end

    if #sessions == 0 then
        db:release()
        return nil, "Session not found"
    end

    -- Build update query
    local update_query = sql.builder.update("sessions")
    local result = { session_id = session_id, updated = true }

    -- Add fields to update
    if updates.current_model ~= nil then
        update_query = update_query:set("current_model", updates.current_model)
        result.current_model = updates.current_model
    end

    if updates.current_agent ~= nil then
        update_query = update_query:set("current_agent", updates.current_agent)
        result.current_agent = updates.current_agent
    end

    if updates.title ~= nil then
        update_query = update_query:set("title", updates.title)
        result.title = updates.title
    end

    if updates.public_meta ~= nil then
        -- Encode public_meta table to JSON
        local encoded_meta, err = json.encode(updates.public_meta)
        if err then
            db:release()
            return nil, "Failed to encode public_meta to JSON: " .. err
        end

        update_query = update_query:set("public_meta", encoded_meta)
        result.public_meta = updates.public_meta -- Keep original table in result
    end

    -- Always update last_message_date if requested or if any other field is updated
    if updates.last_message_date ~= nil or updates.current_model ~= nil or
        updates.current_agent ~= nil or updates.title ~= nil or updates.public_meta ~= nil then
        local date
        if updates.last_message_date == nil then
            date = time.now():format(time.RFC3339)
        else
            date = time.unix(updates.last_message_date, 0):format(time.RFC3339)
        end

        update_query = update_query:set("last_message_date", date)
        result.last_message_date = date
    end

    -- If nothing to update, return early
    if not result.current_model and not result.current_agent and
        not result.title and not result.public_meta and not result.last_message_date then
        db:release()
        return result
    end

    -- Add WHERE clause for session_id
    update_query = update_query:where("session_id = ?", session_id)

    -- Execute the query
    local update_executor = update_query:run_with(db)
    local update_result, err = update_executor:exec()

    db:release()

    if err then
        return nil, "Failed to update session metadata: " .. err
    end

    return result
end

-- Delete a session and all its relationships
function session_repo.delete(session_id)
    if not session_id or session_id == "" then
        return nil, "Session ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Begin transaction
    local tx, err = db:begin()
    if err then
        db:release()
        return nil, "Failed to begin transaction: " .. err
    end

    -- Delete artifacts first
    local artifacts_delete_query = sql.builder.delete("artifacts")
        :where("session_id = ?", session_id)

    local artifacts_delete_executor = artifacts_delete_query:run_with(tx)
    local result, err = artifacts_delete_executor:exec()

    if err then
        tx:rollback()
        db:release()
        return nil, "Failed to delete session artifacts: " .. err
    end

    if err then
        tx:rollback()
        db:release()
        return nil, "Failed to delete session contexts: " .. err
    end

    -- Delete messages
    local msg_delete_query = sql.builder.delete("messages")
        :where("session_id = ?", session_id)

    local msg_delete_executor = msg_delete_query:run_with(tx)
    result, err = msg_delete_executor:exec()

    if err then
        tx:rollback()
        db:release()
        return nil, "Failed to delete session messages: " .. err
    end

    -- Delete the session
    local session_delete_query = sql.builder.delete("sessions")
        :where("session_id = ?", session_id)

    local session_delete_executor = session_delete_query:run_with(tx)
    result, err = session_delete_executor:exec()

    if err then
        tx:rollback()
        db:release()
        return nil, "Failed to delete session: " .. err
    end

    -- Check if session was found
    if result.rows_affected == 0 then
        tx:rollback()
        db:release()
        return nil, "Session not found"
    end

    -- Commit transaction
    local success, err = tx:commit()
    if err then
        tx:rollback()
        db:release()
        return nil, "Failed to commit transaction: " .. err
    end

    db:release()

    return { deleted = true }
end

return session_repo
