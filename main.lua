local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local Menu = require("ui/widget/menu")
-- Built-in networking and JSON dependencies
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")
-- Emoji mapping table: maps Unicode characters & standard reactions to text shortcodes
local EMOJI_MAP = {
    ["👍"] = ":thumbsup:",
    ["❤️"] = ":heart:",
    ["😂"] = ":joy:",
    ["😆"] = ":laughing:",
    ["🔥"] = ":fire:",
    ["🎉"] = ":tada:",
    ["👀"] = ":eyes:",
    ["🙏"] = ":folded_hands:",
    ["😭"] = ":sob:",
    ["✅"] = ":check:",
    ["❌"] = ":x:",
}

-- Convert raw emojis in any text string into safely displayable :shortcodes:
local function sanitizeEmojiText(str)
    if not str or str == "" then return "" end
    
    -- Replace mapped unicode characters
    for emoji, shortcode in pairs(EMOJI_MAP) do
        str = str:gsub(emoji, shortcode)
    end
    
    return str
end
local Matrix = Widget:extend{
    name = "matrix",
    is_doc_only = false,

    -- Global Default Server & Fallback Credentials
    homeserver = "HOMESERVER",
    access_token = "*****ACCESSTOKENNEEDED*****",
}

function Matrix:init()
    -- Load saved channels configuration from settings/matrix.lua
    self.settings_file = DataStorage:getSettingsDir() .. "/matrix.lua"
    self.settings = LuaSettings:open(self.settings_file)

    self.channels = self.settings:readSetting("channels") or {
        {
            name = "Default Room",
            room_id = "!DEFAULT:matrix.org",
        }
    }
    self.active_channel_idx = self.settings:readSetting("active_channel_idx") or 1

    self.ui.menu:registerToMainMenu(self)
end

function Matrix:savePluginSettings()
    self.settings:saveSetting("channels", self.channels)
    self.settings:saveSetting("active_channel_idx", self.active_channel_idx)
    self.settings:flush()
end

function Matrix:getActiveChannel()
    return self.channels[self.active_channel_idx] or self.channels[1]
end

-- Build KOReader Menu
function Matrix:addToMainMenu(menu_items)
    local plugin = self

    -- Dynamically generate the list of channels
    local channel_sub_items = {}
    for idx, ch in ipairs(plugin.channels) do
        local prefix = (idx == plugin.active_channel_idx) and "✓ " or "   "
        table.insert(channel_sub_items, {
            text = prefix .. ch.name,
            callback = function()
                plugin.active_channel_idx = idx
                plugin:savePluginSettings()
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Switched to channel: %s"), ch.name),
                    timeout = 2,
                })
            end,
        })
    end

    -- Option to add a new channel
    table.insert(channel_sub_items, {
        text = _("+ Add New Room"),
        callback = function()
            plugin:promptAddChannel()
        end,
    })

    menu_items.matrix_plugin = {
        text = _("Matrix"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Active Room: ") .. plugin:getActiveChannel().name,
                enabled = false,
            },
            {
                text = _("Fetch Messages"),
                callback = function()
                    plugin:fetchAndShowMessages()
                end,
            },
            {
                text = _("Send Message"),
                callback = function()
                    plugin:promptSendMessage()
                end,
            },
            {
                text = _("Select Active Channel"),
                sub_item_table = channel_sub_items,
            },
            {
                text = _("Rename Current Room"),
                callback = function()
                    plugin:promptRenameActiveChannel()
                end,
            },
        },
    }
end

-- Query room display name from Matrix server with fallback chain
function Matrix:fetchRoomName(room_id)
    if not room_id or room_id == "" then return nil end

    local encoded_room = room_id:gsub("!", "%%21"):gsub("#", "%%23"):gsub(":", "%%3A")
    local token = self.access_token

    -- Step 1: Try fetching explicit m.room.name
    local url_name = string.format("%s/_matrix/client/v3/rooms/%s/state/m.room.name", 
        self.homeserver, encoded_room)
    local body_name = {}

    socketutil:set_timeout(5, 5)
    local res1, code1 = https.request{
        url = url_name,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. token },
        sink = ltn12.sink.table(body_name),
    }
    socketutil:reset_timeout()

    if res1 and code1 == 200 then
        local ok, parsed = pcall(rapidjson.decode, table.concat(body_name))
        if ok and parsed and parsed.name and parsed.name ~= "" then
            return parsed.name
        end
    end

    -- Step 2: Fallback to m.room.canonical_alias if no explicit name is set
    local url_alias = string.format("%s/_matrix/client/v3/rooms/%s/state/m.room.canonical_alias", 
        self.homeserver, encoded_room)
    local body_alias = {}

    socketutil:set_timeout(5, 5)
    local res2, code2 = https.request{
        url = url_alias,
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. token },
        sink = ltn12.sink.table(body_alias),
    }
    socketutil:reset_timeout()

    if res2 and code2 == 200 then
        local ok, parsed = pcall(rapidjson.decode, table.concat(body_alias))
        if ok and parsed and parsed.alias and parsed.alias ~= "" then
            return parsed.alias
        end
    end

    -- Step 3: Final fallback to raw room_id
    return room_id
end

-- Fetch recent messages from the active Matrix room
function Matrix:fetchRoomMessages(limit)
    limit = limit or 20
    local response_body = {}
    local active_ch = self:getActiveChannel()
    
    local token = active_ch.access_token or self.access_token
    local room_id = active_ch.room_id

    if not token or token == "" or token == "YOUR_ACCESS_TOKEN" then
        return nil, _("Missing Access Token in plugin settings.")
    end
    if not room_id or room_id == "" then
        return nil, _("Missing Room ID for active channel.")
    end

    local encoded_room = room_id:gsub("!", "%%21"):gsub("#", "%%23"):gsub(":", "%%3A")
    local url = string.format("%s/_matrix/client/v3/rooms/%s/messages?limit=%d", 
        self.homeserver, encoded_room, limit)

    socketutil:set_timeout(5, 5)

    local res, code, headers, status = https.request{
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
        },
        sink = ltn12.sink.table(response_body),
    }

    socketutil:reset_timeout()

    if not res or not code then
        return nil, string.format("Network Request Failed:\n%s", tostring(status or "Timeout"))
    end

    local raw_data = table.concat(response_body)

    if code ~= 200 then
        return nil, string.format("Matrix Server HTTP %s Error:\n%s", tostring(code), raw_data)
    end

    local ok, parsed = pcall(rapidjson.decode, raw_data)
    if not ok or not parsed or not parsed.chunk then
        return nil, string.format("Failed to parse JSON response:\n%s", raw_data)
    end

    return parsed.chunk, nil
end
-- Helper function to convert ISO 8601 / Unix timestamps into readable times
local function formatTimestamp(origin_server_ts)
    if not origin_server_ts then return "" end
    -- Matrix timestamps are in milliseconds; convert to seconds for os.date
    local sec = math.floor(origin_server_ts / 1000)
    return os.date("%H:%M", sec)
end
-- Helper: Send an m.reaction event to Matrix
function Matrix:sendReaction(event_id, emoji)
    local active_ch = self:getActiveChannel()
    local token = active_ch.access_token or self.access_token
    local room_id = active_ch.room_id

    local txn_id = string.format("react_%d_%d", os.time(), math.random(100, 999))
    local encoded_room = room_id:gsub("!", "%%21"):gsub("#", "%%23"):gsub(":", "%%3A")
    local url = string.format("%s/_matrix/client/v3/rooms/%s/send/m.reaction/%s", 
        self.homeserver, encoded_room, txn_id)

    local payload = rapidjson.encode({
        ["m.relates_to"] = {
            rel_type = "m.annotation",
            event_id = event_id,
            key = emoji,
        }
    })

    socketutil:set_timeout(5, 5)
    local response_body = {}
    local res, code = https.request{
        url = url,
        method = "PUT",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()

    if res and code == 200 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Reacted with %s"), emoji),
            timeout = 1.5,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to send reaction."),
            timeout = 2,
        })
    end
end
-- Fetch recent room events, aggregate reactions using shortcodes, and display in a KOReader Menu
function Matrix:fetchAndShowMessages()
    local ButtonDialog = require("ui/widget/buttondialog")
    local Menu = require("ui/widget/menu")

    local active_ch = self:getActiveChannel()
    local loading = InfoMessage:new{ 
        text = string.format(_("Fetching messages for %s..."), active_ch.name) 
    }
    UIManager:show(loading)

    local chunk, err = self:fetchRoomMessages(40)
    UIManager:close(loading)

    if err then
        UIManager:show(InfoMessage:new{ text = _("Error fetching messages:\n") .. err })
        return
    end

    -- 1. Pass One: Aggregate reactions by parent message event_id
    local reactions_map = {} -- { [event_id] = { [emoji_key] = count } }
    for _, event in ipairs(chunk or {}) do
        if event.type == "m.reaction" and event.content and event.content["m.relates_to"] then
            local relates = event.content["m.relates_to"]
            local parent_id = relates.event_id
            local key = relates.key

            if parent_id and key then
                reactions_map[parent_id] = reactions_map[parent_id] or {}
                reactions_map[parent_id][key] = (reactions_map[parent_id][key] or 0) + 1
            end
        end
    end

    -- 2. Pass Two: Build paged menu items with sanitized shortcodes
    local menu_items = {}
    for i = #(chunk or {}), 1, -1 do
        local event = chunk[i]
        if event.type == "m.room.message" and event.content and event.content.body then
            local event_id = event.event_id
            local sender = event.sender or "Unknown"
            local short_sender = sender:match("@([^:]+)") or sender
            
            -- Sanitize incoming message body emojis into shortcodes
            local clean_body = sanitizeEmojiText(event.content.body)
            local time_str = formatTimestamp(event.origin_server_ts)

            -- Format reaction line using shortcodes (e.g., ":thumbsup: 2   :heart: 1")
            local rx_str = ""
            if event_id and reactions_map[event_id] then
                local rx_list = {}
                for emoji_key, count in pairs(reactions_map[event_id]) do
                    local display_key = sanitizeEmojiText(emoji_key)
                    table.insert(rx_list, string.format("%s %d", display_key, count))
                end
                if #rx_list > 0 then
                    rx_str = "\n" .. table.concat(rx_list, "   ")
                end
            end

            local item_text = string.format("%s  •  %s\n%s%s", short_sender, time_str, clean_body, rx_str)

            -- Inside Matrix:fetchAndShowMessages() where individual menu items are built:
            table.insert(menu_items, {
                text = item_text,
                callback = function()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local dialog
                    dialog = ButtonDialog:new{
                        title = string.format(_("Message from %s"), short_sender),
                        text = string.format("%s\n\n%s", clean_body, rx_str ~= "" and ("Reactions: " .. rx_str) or ""),
                        buttons = {
                            {
                                {
                                    text = _("Reply"),
                                    callback = function()
                                        UIManager:close(dialog)
                            
                            -- Open keyboard input dialog for the reply
                                        local input_dialog
                                        input_dialog = InputDialog:new{
                                            title = string.format(_("Reply to %s"), short_sender),
                                            input = "",
                                            save_callback = function(reply_text)
                                                UIManager:close(input_dialog)

                                                if not reply_text or reply_text:match("^%s*$") then
                                                    return
                                                end

                                                local loading = InfoMessage:new{ text = _("Sending reply...") }
                                                UIManager:show(loading)

                                                -- Use the original message body for the reply fallback (guard if missing)
                                                local original_body = (event and event.content and event.content.body) and event.content.body or ""
                                                -- Trim whitespace from fallback so it doesn't produce ">  " etc.
                                                original_body = original_body:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
                                                -- Create plain-text fallback as a blockquote without angle brackets
                                                local ok, err = self:sendRoomMessage(reply_text, event_id, original_body)
                                                UIManager:close(loading)

                                                if not ok then
                                                    UIManager:show(InfoMessage:new{
                                                        text = _("Failed to send reply:\n") .. err,
                                                    })
                                                else
                                                    UIManager:show(InfoMessage:new{
                                                        text = _("Reply sent successfully!"),
                                                        timeout = 2,
                                                    })
                                                end
                                            end,
                                        }
                                        UIManager:show(input_dialog)
                                        input_dialog:onShowKeyboard()
                                    end,
                                },
                            },
                            {
                                {
                                    text = "👍 :thumbsup:",
                                    callback = function()
                                        UIManager:close(dialog)
                                        self:sendReaction(event_id, "👍")
                                    end,
                                },
                                {
                                    text = "❤️ :heart:",
                                    callback = function()
                                        UIManager:close(dialog)
                                        self:sendReaction(event_id, "❤️")
                                    end,
                                },
                            },
                            {
                                {
                                    text = _("Close"),
                                    callback = function()
                                        UIManager:close(dialog)
                                    end,
                                }
                            }
                        },
                    }
                    UIManager:show(dialog)
                end,
            })
        end
    end

    if #menu_items == 0 then
        table.insert(menu_items, {
            text = _("No recent text messages found in this room."),
            enabled = false,
        })
    end

    local message_menu = Menu:new{
        title = string.format(_("Matrix: %s"), active_ch.name),
        item_table = menu_items,
        is_popmenu = false,
    }

    UIManager:show(message_menu)
end
-- Send a text message (optionally as a reply to another message)
function Matrix:sendRoomMessage(text, reply_to_event_id, reply_to_body)
    if not text or text:match("^%s*$") then
        return nil, _("Message cannot be empty.")
    end

    local response_body = {}
    local active_ch = self:getActiveChannel()
    local token = active_ch.access_token or self.access_token
    local room_id = active_ch.room_id

    local txn_id = string.format("koreader_%d", os.time())
    local encoded_room = room_id:gsub("!", "%%21"):gsub("#", "%%23"):gsub(":", "%%3A")
    local url = string.format("%s/_matrix/client/v3/rooms/%s/send/m.room.message/%s", 
        self.homeserver, encoded_room, txn_id)

    -- Build base message payload
    local payload_data = {
        msgtype = "m.text",
        body = text,
    }

    -- If replying, add Matrix reply metadata & plain-text fallback block
    if reply_to_event_id and reply_to_body then
        -- Clean reply body of newlines for the plain text fallback header
        local clean_fallback = reply_to_body:gsub("[\r\n]+", " ")
        clean_fallback = clean_fallback:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
        if #clean_fallback > 60 then clean_fallback = clean_fallback:sub(1, 57) .. "..." end

        payload_data.body = text

        payload_data["m.relates_to"] = {
            ["m.in_reply_to"] = {
                event_id = reply_to_event_id
            }
        }
    end

    local payload = rapidjson.encode(payload_data)

    socketutil:set_timeout(5, 5)

    local res, code, headers, status = https.request{
        url = url,
        method = "PUT",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body),
    }

    socketutil:reset_timeout()

    if not res or not code then
        return nil, string.format("Network Error:\n%s", tostring(status or "Timeout"))
    end

    if code ~= 200 then
        local raw_data = table.concat(response_body)
        return nil, string.format("Matrix Server HTTP %s Error:\n%s", tostring(code), raw_data)
    end

    return true, nil
end

-- Open input dialog for sending message
function Matrix:promptSendMessage()
    local active_ch = self:getActiveChannel()
    local input_dialog
    input_dialog = InputDialog:new{
        title = string.format(_("Send to %s"), active_ch.name),
        input = "",
        save_callback = function(text)
            UIManager:close(input_dialog)

            if not text or text:match("^%s*$") then
                UIManager:show(InfoMessage:new{
                    text = _("Cannot send empty message."),
                })
                return
            end

            local loading = InfoMessage:new{ text = _("Sending message...") }
            UIManager:show(loading)

            local ok, err = self:sendRoomMessage(text)
            UIManager:close(loading)

            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("Failed to send message:\n") .. err,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Message sent successfully!"),
                    timeout = 2,
                })
            end
        end,
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Prompt user for Room ID, fetch server name, then allow editing before saving
function Matrix:promptAddChannel()
    local id_dialog
    id_dialog = InputDialog:new{
        title = _("Enter Room ID (e.g. !abc:matrix.org)"),
        input = "",
        save_callback = function(room_id)
            UIManager:close(id_dialog)
            if not room_id or room_id:match("^%s*$") then return end

            local loading = InfoMessage:new{ text = _("Fetching room name from server...") }
            UIManager:show(loading)

            local server_name = self:fetchRoomName(room_id)
            UIManager:close(loading)

            local name_dialog
            name_dialog = InputDialog:new{
                title = _("Confirm or Edit Room Name"),
                input = server_name,
                save_callback = function(final_name)
                    UIManager:close(name_dialog)
                    
                    if not final_name or final_name:match("^%s*$") then
                        final_name = server_name
                    end

                    table.insert(self.channels, {
                        name = final_name,
                        room_id = room_id,
                    })
                    self.active_channel_idx = #self.channels
                    self:savePluginSettings()

                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Added & Switched to %s"), final_name),
                        timeout = 2,
                    })
                end,
            }
            UIManager:show(name_dialog)
            name_dialog:onShowKeyboard()
        end,
    }
    UIManager:show(id_dialog)
    id_dialog:onShowKeyboard()
end

-- Rename the active channel
function Matrix:promptRenameActiveChannel()
    local active_ch = self:getActiveChannel()
    local rename_dialog
    rename_dialog = InputDialog:new{
        title = _("Rename Current Room"),
        input = active_ch.name,
        save_callback = function(new_name)
            UIManager:close(rename_dialog)
            if not new_name or new_name:match("^%s*$") then return end

            active_ch.name = new_name
            self:savePluginSettings()

            UIManager:show(InfoMessage:new{
                text = string.format(_("Renamed to: %s"), new_name),
                timeout = 2,
            })
        end,
    }
    UIManager:show(rename_dialog)
    rename_dialog:onShowKeyboard()
end

return Matrix
