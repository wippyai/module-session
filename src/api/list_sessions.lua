local http = require("http")
local security = require("security")
local session_repo = require("session_repo")

type ListSessionsResponse = {
    success: boolean,
    count: number?,
    sessions: {any}?,
    error: string?,
}

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

    local user_id = actor:id()

    local limit = tonumber(req:query("limit")) or 20
    local offset = tonumber(req:query("offset")) or 0

    if limit > 100 then
        limit = 100
    elseif limit < 1 then
        limit = 1
    end

    local total_count, err = session_repo.count_by_user(user_id)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    local sessions, err = session_repo.list_by_user(user_id, limit, offset)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    for i, session in ipairs(sessions) do
        session.current_agent = ""
        session.current_model = ""

        if session.config and type(session.config) == "table" then
            session.current_agent = session.config.agent_id or ""
            session.current_model = session.config.model or ""
        end
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        count = total_count,
        sessions = sessions
    })
end

return {
    handler = handler
}