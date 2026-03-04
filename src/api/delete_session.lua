local http = require("http")
local security = require("security")
local session_repo = require("session_repo")

type DeleteSessionResponse = {
    success: boolean,
    message: string?,
    session_id: string?,
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

    -- Get user ID from the authenticated actor
    local user_id = actor:id()

    -- Get session ID from query parameter
    local session_id = req:query("session_id")
    if not session_id or session_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "session_id parameter is required"
        })
        return
    end

    -- Get the session first to verify ownership
    local session, err = session_repo.get(session_id, user_id)
    if err then
        if err == "Session not found" then
            res:set_status(http.STATUS.NOT_FOUND)
            res:write_json({
                success = false,
                error = "Session not found"
            })
        else
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({
                success = false,
                error = err
            })
        end
        return
    end

    -- Verify the session belongs to the authenticated user
    if session.user_id ~= user_id then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "You don't have permission to delete this session"
        })
        return
    end

    -- Delete the session
    local result, err = session_repo.delete(session_id)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    -- Return success response
    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        message = "Session deleted successfully",
        session_id = session_id
    })
end

return {
    handler = handler
}
