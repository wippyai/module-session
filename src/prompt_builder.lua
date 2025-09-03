local json = require("json")
local consts = require("consts")

local prompt_builder = {
    _prompt = require("prompt"),
    _upload_repo = require("upload_repo")
}

function prompt_builder.build(messages, contexts, session_meta, options)
    if not messages then
        return nil, "Messages are required"
    end

    options = options or {}
    local include_contexts = options.include_contexts ~= false
    local include_files = options.include_files ~= false
    local cache_markers = options.cache_markers ~= false

    local builder = prompt_builder._prompt.new()

    if include_contexts and contexts and #contexts > 0 then
        local memory_text = "Session context memory:\n\n"
        for _, context in ipairs(contexts) do
            memory_text = memory_text .. "## " .. context.type .. "\n" .. context.text .. "\n\n"
        end
        builder:add_system(memory_text)

        if cache_markers then
            builder:add_cache_marker("context_memories")
        end
    end

    for i, msg in ipairs(messages) do
        local metadata = msg.metadata or {}

        if msg.type == consts.MSG_TYPE.SYSTEM then
            builder:add_system(msg.data)
        elseif msg.type == consts.MSG_TYPE.USER then
            builder:add_user(msg.data)

            if include_files and metadata.file_uuids and #metadata.file_uuids > 0 then
                local file_info = {}
                for _, file_uuid in ipairs(metadata.file_uuids) do
                    local upload, err = prompt_builder._upload_repo.get(file_uuid)
                    if not err and upload then
                        table.insert(file_info, {
                            filename = upload.metadata and upload.metadata.filename or "Unknown filename",
                            size = upload.size or 0,
                            type = upload.mime_type or "Unknown type",
                            uuid = file_uuid
                        })
                    end
                end

                if #file_info > 0 then
                    local files_text = "User attached the following files:\n"
                    for _, file in ipairs(file_info) do
                        files_text = files_text .. string.format(
                            "- %s (Type: %s, Size: %d bytes, ID: %s)\n",
                            file.filename, file.type, file.size, file.uuid
                        )
                    end
                    builder:add_developer(files_text)
                end
            end

            if cache_markers and metadata.last_checkpoint then
                builder:add_cache_marker("checkpoint_" .. msg.message_id)
            end
        elseif msg.type == consts.MSG_TYPE.ASSISTANT then
            -- Always use add_assistant and let prompt library handle thinking blocks internally
            builder:add_assistant(msg.data, metadata)
        elseif msg.type == consts.MSG_TYPE.DEVELOPER then
            builder:add_developer(msg.data, metadata)
        elseif
            msg.type == consts.MSG_TYPE.FUNCTION
            or msg.type == consts.MSG_TYPE.PRIVATE_FUNCTION
            or msg.type == consts.MSG_TYPE.DELEGATION
        then
            if metadata.function_name and metadata.status then
                local args = msg.data
                if type(args) == "string" then
                    local parsed, parse_err = json.decode(args)
                    if not parse_err then
                        args = parsed
                    end
                end

                local llm_call_id = metadata.call_id or msg.message_id
                builder:add_function_call(metadata.function_name, args, llm_call_id)

                if metadata.status == consts.FUNC_STATUS.PENDING then
                    builder:add_function_result(metadata.function_name, "incomplete", llm_call_id)
                elseif metadata.status == consts.FUNC_STATUS.SUCCESS or
                    metadata.status == consts.FUNC_STATUS.ERROR then
                    local result_content = metadata.result
                    if type(result_content) == "table" then
                        result_content = json.encode(result_content)
                    elseif result_content == nil then
                        result_content = "nil"
                    else
                        result_content = tostring(result_content)
                    end
                    builder:add_function_result(metadata.function_name, result_content, llm_call_id)
                end
            end
        elseif msg.type == consts.MSG_TYPE.ARTIFACT then
            if msg.data and msg.data ~= "" then
                builder:add_developer("Artifact: " .. msg.data, metadata)
            end
        end
    end

    return builder, nil
end

function prompt_builder.from_session(session, options)
    if not session then
        return nil, "Session reader is required"
    end

    local messages, err = session:messages():from_checkpoint():all()
    if err then
        return nil, "Failed to load messages: " .. err
    end

    local contexts, err = session:contexts():all()
    if err then
        return nil, "Failed to load contexts: " .. err
    end

    local session_meta = session:state()

    return prompt_builder.build(messages, contexts, session_meta, options)
end

return prompt_builder
