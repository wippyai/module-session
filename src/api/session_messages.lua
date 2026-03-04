local http = require("http")
local security = require("security")
local session_repo = require("session_repo")
local message_repo = require("message_repo")
local time = require("time")
local json = require("json")

type SessionMessagesResponse = {
    success: boolean,
    count: number?,
    session_id: string?,
    messages: {any}?,
    pagination: {
        has_more: boolean,
        next_cursor: string?,
        prev_cursor: string?,
    }?,
    error: string?,
}

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Security check - ensure user is authenticated
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    -- Get session ID from query parameter
    local session_id = req:query("session_id")
    if not session_id or session_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Session ID is required"
        })
        return
    end

    -- Get user ID from the authenticated actor
    local user_id = actor:id()

    -- Verify session belongs to the authenticated user
    local session, err = session_repo.get(session_id, user_id)
    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    if session.user_id ~= user_id then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "Access denied"
        })
        return
    end

    -- Get query parameters for pagination
    local limit = tonumber(req:query("limit")) or 50
    local cursor = req:query("cursor") or ""
    local direction = req:query("direction") or "before" -- Default to "before" (older messages)

    -- Enforce limit constraints
    if limit > 100 then
        limit = 100
    elseif limit < 1 then
        limit = 1
    end

    -- Get messages for this session with cursor-based pagination
    local result, err = message_repo.list_by_session(session_id, limit, cursor, direction)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    local messages = result.messages

    -- Process message data
    for i, message in ipairs(messages) do
        -- If metadata exists but isn't directly accessible
        if message.metadata_json and message.metadata_json ~= "" then
            local decoded, err = json.decode(message.metadata_json :: string)
            if not err then
                message.metadata = decoded
            else
                message.metadata = {}
            end
        elseif not message.metadata then
            message.metadata = {}
        end

        -- Extract file_uuids from metadata to top level for easier access
        if message.metadata.file_uuids then
            message.file_uuids = message.metadata.file_uuids
        end

        if message.date and type(message.date) == "number" then
            message.date = time.unix(message.date :: number, 0):format_rfc3339()
        end
    end

    -- Return JSON response
    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        count = #messages,
        session_id = session_id,
        messages = messages,
        pagination = {
            has_more = result.has_more,
            next_cursor = result.next_cursor,
            prev_cursor = result.prev_cursor
        }
    })
end

return {
    handler = handler
}