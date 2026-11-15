local _, ns = ...

local Json = {}
ns.Json = Json

-- Lua tables cannot tell an empty array from an empty object, and nil cannot
-- sit in a table. Arrays are tagged with this metatable; null is a sentinel.
local arrayMeta = { __jsonArray = true }
Json.null = setmetatable({}, { __tostring = function() return "null" end })

function Json.array(t)
    return setmetatable(t or {}, arrayMeta)
end

local function isArray(t)
    if getmetatable(t) == arrayMeta then
        return true
    end
    local n = #t
    if n == 0 then
        return false
    end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    return count == n
end

local escapes = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return "null"
    end
    if n % 1 == 0 and n > -1e15 and n < 1e15 then
        return string.format("%.0f", n)
    end
    return string.format("%.14g", n)
end

local encodeValue

local function encodeTable(t, out)
    if t == Json.null then
        out[#out + 1] = "null"
        return
    end
    if isArray(t) then
        out[#out + 1] = "["
        for i = 1, #t do
            if i > 1 then
                out[#out + 1] = ","
            end
            encodeValue(t[i], out)
        end
        out[#out + 1] = "]"
        return
    end
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    out[#out + 1] = "{"
    for i, key in ipairs(keys) do
        if i > 1 then
            out[#out + 1] = ","
        end
        local value = t[key]
        if value == nil then
            value = t[tonumber(key)]
        end
        out[#out + 1] = encodeString(key)
        out[#out + 1] = ":"
        encodeValue(value, out)
    end
    out[#out + 1] = "}"
end

encodeValue = function(v, out)
    local kind = type(v)
    if kind == "nil" then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif kind == "number" then
        out[#out + 1] = encodeNumber(v)
    elseif kind == "string" then
        out[#out + 1] = encodeString(v)
    elseif kind == "table" then
        encodeTable(v, out)
    else
        error("cannot encode " .. kind)
    end
end

function Json.encode(v)
    local out = {}
    encodeValue(v, out)
    return table.concat(out)
end

local function decodeError(str, pos, msg)
    error(string.format("JSON %s at position %d", msg, pos), 0)
end

local function skip(str, pos)
    return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function utf8(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40
    )
end

local unescapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local decodeValue

local function decodeString(str, pos)
    local parts = {}
    local i = pos + 1
    while true do
        local stop = str:find('["\\]', i)
        if not stop then
            decodeError(str, pos, "unterminated string")
        end
        parts[#parts + 1] = str:sub(i, stop - 1)
        if str:sub(stop, stop) == '"' then
            return table.concat(parts), stop + 1
        end
        local esc = str:sub(stop + 1, stop + 1)
        if esc == "u" then
            local hex = str:sub(stop + 2, stop + 5)
            local code = tonumber(hex, 16)
            if not code then
                decodeError(str, stop, "bad unicode escape")
            end
            local nextPos = stop + 6
            if code >= 0xD800 and code <= 0xDBFF and str:sub(nextPos, nextPos + 1) == "\\u" then
                local low = tonumber(str:sub(nextPos + 2, nextPos + 5), 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    nextPos = nextPos + 6
                end
            end
            parts[#parts + 1] = utf8(code)
            i = nextPos
        else
            local char = unescapes[esc]
            if not char then
                decodeError(str, stop, "bad escape")
            end
            parts[#parts + 1] = char
            i = stop + 2
        end
    end
end

local function decodeArray(str, pos)
    local result = Json.array({})
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "]" then
        return result, pos + 1
    end
    while true do
        local value
        value, pos = decodeValue(str, pos)
        result[#result + 1] = value
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "]" then
            return result, pos + 1
        elseif c ~= "," then
            decodeError(str, pos, "expected ',' or ']'")
        end
        pos = skip(str, pos + 1)
    end
end

local function decodeObject(str, pos)
    local result = {}
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "}" then
        return result, pos + 1
    end
    while true do
        if str:sub(pos, pos) ~= '"' then
            decodeError(str, pos, "expected string key")
        end
        local key
        key, pos = decodeString(str, pos)
        pos = skip(str, pos)
        if str:sub(pos, pos) ~= ":" then
            decodeError(str, pos, "expected ':'")
        end
        pos = skip(str, pos + 1)
        result[key], pos = decodeValue(str, pos)
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "}" then
            return result, pos + 1
        elseif c ~= "," then
            decodeError(str, pos, "expected ',' or '}'")
        end
        pos = skip(str, pos + 1)
    end
end

decodeValue = function(str, pos)
    pos = skip(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        return decodeObject(str, pos)
    elseif c == "[" then
        return decodeArray(str, pos)
    elseif c == '"' then
        return decodeString(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return Json.null, pos + 4
    end
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if num and num ~= "" then
        local value = tonumber(num)
        if value then
            return value, pos + #num
        end
    end
    decodeError(str, pos, "unexpected character")
end

function Json.decode(str)
    local value, pos = decodeValue(str, 1)
    pos = skip(str, pos)
    if pos <= #str then
        decodeError(str, pos, "trailing data")
    end
    return value
end
