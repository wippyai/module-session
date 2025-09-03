local test = require("test")
local start_tokens = require("start_tokens")
local time = require("time")
local crypto = require("crypto")
local base64 = require("base64")
local json = require("json")

local function define_tests()
    describe("Start Tokens", function()
        it("should create and unpack valid token", function()
            local params = {
                agent = "test_agent",
                model = "claude-3-7-sonnet",
                kind = "test_session"
            }

            local token, err = start_tokens.pack(params)
            expect(err).to_be_nil()
            expect(token).to_be_type("string")

            local result, err = start_tokens.unpack(token)
            expect(err).to_be_nil()
            expect(result).to_be_type("table")

            expect(result.agent).to_equal(params.agent)
            expect(result.model).to_equal(params.model)
            expect(result.kind).to_equal(params.kind)
            expect(result.issued_at).to_be_type("number")
        end)

        it("should create token with minimal params", function()
            local params = {
                agent = "minimal_agent",
                model = "gpt-4o"
            }

            local token, err = start_tokens.pack(params)
            expect(err).to_be_nil()

            local result, err = start_tokens.unpack(token)
            expect(err).to_be_nil()
            expect(result.agent).to_equal(params.agent)
            expect(result.model).to_equal(params.model)
            expect(result.kind).to_equal("")
        end)

        it("should error on missing required params", function()
            local token1, err1 = start_tokens.pack({model = "test-model"})
            expect(token1).to_be_nil()
            expect(err1).not_to_be_nil()
            expect(err1).to_match("Agent name is required")

            local token3, err3 = start_tokens.pack("not a table")
            expect(token3).to_be_nil()
            expect(err3).not_to_be_nil()
            expect(err3).to_match("Parameters must be provided as a table")
        end)

        it("should error on invalid token format", function()
            local result1, err1 = start_tokens.unpack(nil)
            expect(result1).to_be_nil()
            expect(err1).not_to_be_nil()
            expect(err1).to_match("No token provided")

            local result2, err2 = start_tokens.unpack("not a valid token")
            expect(result2).to_be_nil()
            expect(err2).not_to_be_nil()
            expect(err2).to_match("Invalid token format")

            local result3, err3 = start_tokens.unpack(base64.encode("just some random data"))
            expect(result3).to_be_nil()
            expect(err3).not_to_be_nil()
        end)

        it("should detect expired tokens", function()
            mock("os.time", function() return 1640995200 end)

            local params = {
                agent = "expired_agent",
                model = "expired_model",
                kind = "expired_session"
            }

            local token, _ = start_tokens.pack(params)

            mock("os.time", function() return 1640995200 + 90000 end)

            local result, err = start_tokens.unpack(token)
            expect(result).to_be_nil()
            expect(err).not_to_be_nil()
            expect(err).to_match("Token expired")
        end)
    end)
end

return test.run_cases(define_tests)