local http = require("http")
local json = require("json")
local artifact_repo = require("artifact_repo")
local session_repo = require("session_repo")
local security = require("security")

type ArtifactMetadataResponse = {
    uuid: string,
    type: string,
    title: string,
    created_at: string,
    updated_at: string,
    content_version: number,
    content_type: string?,
    description: string?,
    icon: string?,
    status: string?,
    page_id: string?,
    is_view_reference: boolean?,
    params: {[string]: any}?,
}

local function handler()
    -- Get response object
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Security check - ensure user is authenticated
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    -- Get user ID from the authenticated actor
    local user_id = actor:id()

    -- Get artifact ID from URL path
    local artifact_id = req:param("id")
    if not artifact_id or artifact_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing artifact ID in path"
        })
        return
    end

    -- Fetch the artifact from the repository
    local artifact, err = artifact_repo.get(artifact_id)
    if err then
        -- Handle not found error
        if err:match("not found") then
            res:set_status(http.STATUS.NOT_FOUND)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Artifact not found: " .. artifact_id
            })
            return
        end

        -- Handle other errors
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to retrieve artifact: " .. err
        })
        return
    end

    -- Get the session to check ownership
    if artifact.session_id and artifact.session_id ~= "" then
        local session, session_err = session_repo.get(artifact.session_id)
        if session_err then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Failed to verify artifact ownership: " .. session_err
            })
            return
        end

        -- Verify the session belongs to the authenticated user
        if session.user_id ~= user_id then
            res:set_status(http.STATUS.FORBIDDEN)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Access denied: You don't have permission to access this artifact"
            })
            return
        end
    end

    if artifact.user_id ~= user_id then
        res:set_status(http.STATUS.FORBIDDEN)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Access denied: You don't have permission to access this artifact"
        })
        return
    end

    -- Convert to a client-friendly format
    local response = {
        uuid = artifact.artifact_id,
        type = artifact.kind,
        title = artifact.title,
        created_at = artifact.created_at,
        updated_at = artifact.updated_at,
        content_version = 1
    }

    -- Include metadata if available
    if artifact.meta then
        response.content_type = artifact.meta.content_type
        response.description = artifact.meta.description
        response.icon = artifact.meta.icon
        response.status = artifact.meta.status

        -- Add page reference specific data if this is a view_ref artifact
        if artifact.kind == "view_ref" then
            response.page_id = artifact.meta.page_id
            response.is_view_reference = true
            response.type = artifact.meta.display_type or "standalone"

            -- Also get the params if this is a view_ref
            if artifact.content and artifact.content ~= "" then
                local params, decode_err = json.decode(artifact.content :: string)
                if not decode_err then
                    response.params = params
                end
            end
        end
    end

    -- Return JSON metadata response
    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}
