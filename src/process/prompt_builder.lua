local prompt = require("prompt")
local json = require("json")
local upload_repo = require("upload_repo")
local time = require("time")

local FUNC_STATUS = {
    PENDING = "pending",
    SUCCESS = "success",
    ERROR = "error"
}

-- PromptBuilder component
local prompt_builder = {}
prompt_builder.__index = prompt_builder

-- Constructor
function prompt_builder.new(session_state)
    local self = setmetatable({}, prompt_builder)

    -- Store dependencies
    self.state = session_state
    return self
end

-- Build a prompt from conversation history
function prompt_builder:build_prompt(message_limit, memories)
    -- Default to 50 messages if not specified
    message_limit = message_limit or 250

    -- Load messages from state
    local messages, err = self.state:load_messages(message_limit)
    if err then
        return nil, "Failed to load messages: " .. err
    end

    -- Create a prompt builder
    local builder = prompt.new()

    -- Add memories as system messages at the start of the prompt
    if memories and #memories > 0 then
        local memory_text = "Session memory context:\n\n"
        for _, memory in ipairs(memories) do
            memory_text = memory_text .. "## " .. memory.type .. "\n" .. memory.text .. "\n\n"
        end
        builder:add_system(memory_text)
        builder:add_cache_marker("memories")
    end

    -- current date
    builder:add_system("## Current date: " .. time.now():format("02 Jan 2006") .. "\n")

    -- Process messages to add to prompt
    for i, msg in ipairs(messages) do
        local meta = msg.metadata or {}

        -- Special handling for delegation messages
        if msg.type == "delegation" then
            -- Convert delegation to tool call and result for LLM's benefit
            if meta.from_agent and meta.to_agent then
                local delegate_args = {
                    from = meta.from_agent,
                    to = meta.to_agent,
                    message = meta.message or "Continuing with specialized agent"
                }

                builder:add_function_call(
                    meta.function_name,
                    delegate_args,
                    msg.message_id
                )
                builder:add_function_result(
                    meta.function_name,
                    "Successfully redirected to " .. meta.to_agent .. ". You are currently " .. meta.to_agent,
                    msg.message_id
                )
            end
        else
            -- Normal handling for other message types
            if msg.type == "system" then
                builder:add_system(msg.data)
            elseif msg.type == "user" then
                builder:add_user(msg.data)

                if meta.file_uuids and #meta.file_uuids > 0 then
                    local file_info = {}
                    for _, file_uuid in ipairs(meta.file_uuids) do
                        local upload, err = upload_repo.get(file_uuid)
                        if not err and upload then
                            table.insert(file_info, {
                                filename = upload.metadata and upload.metadata.filename or "Unknown filename",
                                size = upload.size or 0,
                                type = upload.mime_type or "Unknown type",
                                uuid = file_uuid
                            })
                        end
                    end

                    -- Create developer message with file information if files were found
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
            elseif msg.type == "assistant" then
                -- we are passing provider specific meta, typically provided by provider in a first place
                builder:add_assistant(msg.data, msg.metadata.meta)
            elseif msg.type == "developer" then
                builder:add_developer(msg.data)
            elseif msg.type == "function" then
                -- For function messages that contain both call and result
                if meta.function_name and meta.status then
                    local args = msg.data
                    if type(args) == "string" then
                        local parsed, parse_err = json.decode(args)
                        if not parse_err then
                            args = parsed
                        end
                    end

                    builder:add_function_call(meta.function_name, args, msg.message_id)

                    if meta.status == FUNC_STATUS.PENDING then
                        builder:add_function_result(meta.function_name, "incomplete", msg.message_id)
                    elseif meta.status == FUNC_STATUS.SUCCESS or
                        meta.status == FUNC_STATUS.ERROR then
                        builder:add_function_result(meta.function_name, meta.result, msg.message_id)
                    end
                end
            end
        end
    end

    return builder
end

return prompt_builder
