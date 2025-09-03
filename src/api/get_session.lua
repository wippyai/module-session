local http = require("http")
local security = require("security")
local session_repo = require("session_repo")
local message_repo = require("message_repo")
local json = require("json")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    local session_id = req:query("session_id")
    if not session_id or session_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Session ID is required"
        })
        return
    end

    local user_id = actor:id()

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

    local latest_message, _ = message_repo.get_latest(session_id)
    local message_count, _ = message_repo.count_by_session(session_id)

    session.current_agent = ""
    session.current_model = ""

    if session.config and type(session.config) == "table" then
        session.current_agent = session.config.agent_id or ""
        session.current_model = session.config.model or ""
    end

    local response = {
        success = true,
        session = session
    }

    if latest_message then
        response.latest_message = latest_message
    end

    if message_count then
        response.message_count = message_count
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}