local http = require("http")
local security = require("security")
local session_writer = require("session_writer")

type RenameSessionResponse = {
    success: boolean,
    error: string?,
}

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(http.CONTENT.JSON)

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    local data, err = req:body_json()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid JSON request"
        })
        return
    end

    if not data or type(data) ~= "table" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Request body is required"
        })
        return
    end

    local session_id = data.session_id
    if not session_id or type(session_id) ~= "string" or session_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "session_id is required"
        })
        return
    end

    local title = data.title
    if not title or type(title) ~= "string" or title == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "title is required"
        })
        return
    end

    local writer, err = session_writer.new(session_id)
    if err then
        local status = http.STATUS.INTERNAL_ERROR
        if err == "Session not found" or err:find("Failed to get session") then
            status = http.STATUS.NOT_FOUND
        elseif err:find("Permission denied") then
            status = http.STATUS.FORBIDDEN
        elseif err:find("No security actor") then
            status = http.STATUS.UNAUTHORIZED
        end
        res:set_status(status)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    local _, err = writer:update_title(title)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = err
        })
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({ success = true })
end

return {
    handler = handler
}
