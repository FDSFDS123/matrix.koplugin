local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local Menu = require("ui/widget/menu")

-- Use standard socket.http since the daemon runs locally unencrypted
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")

local Matrix = Widget:extend{
    name = "matrix",
    is_doc_only = false,

    -- Point directly to the Rust E2EE Daemon
    daemon_url = "http://127.0.0.1:8080",
}

local function url_encode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "+")
    end
    return str
end

function Matrix:init()
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

-- Open active channel picker menu with dynamic flashing checkmarks
function Matrix:showChannelSelectMenu()
    local plugin = self

    local function build_items()
        local items = {}
        for idx, ch in ipairs(plugin.channels) do
            local is_active = (idx == plugin.active_channel_idx)
            local prefix = is_active and "✓ " or "   "

            table.insert(items, {
                text = prefix .. ch.name,
                bold = is_active,
                callback = function()
                    if plugin.active_channel_idx ~= idx then
                        plugin.active_channel_idx = idx
                        plugin:savePluginSettings()

                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Switched to channel: %s"), ch.name),
                            timeout = 1.5,
                        })

                        -- Redraw menu in place with updated checkmark
                        if plugin.channel_menu then
                            plugin.channel_menu.item_table = build_items()
                            plugin.channel_menu:updateItems()
                        end
                    end
                end,
            })
        end

        table.insert(items, {
            text = _("+ Join Room / Accept Invite"),
            callback = function()
                if plugin.channel_menu then
                    UIManager:close(plugin.channel_menu)
                end
                plugin:promptAddChannel()
            end,
        })

        return items
    end

    plugin.channel_menu = Menu:new{
        title = _("Select Active Channel"),
        item_table = build_items(),
        is_popmenu = false,
        on_close = function()
            plugin.channel_menu = nil
        end,
    }

    UIManager:show(plugin.channel_menu)
end

function Matrix:addToMainMenu(menu_items)
    local plugin = self

    menu_items.matrix_plugin = {
        text = _("Matrix"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Authentication"),
                sub_item_table = {
                    {
                        text = _("Login with Username & Password"),
                        callback = function()
                            plugin:promptLogin()
                        end,
                    },
                    {
                        text = _("Get SSO Login Link"),
                        callback = function()
                            plugin:promptSSO()
                        end,
                    },
                    {
                        text = _("Login with Access Token"),
                        callback = function()
                            plugin:promptTokenLogin()
                        end,
                    },
                },
            },
            {
                text = _("Auto-Sync Rooms & Contacts"),
                callback = function()
                    plugin:autoSyncRooms()
                end,
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
                callback = function()
                    plugin:showChannelSelectMenu()
                end,
            },
            {
                text = _("Rename Current Room"),
                callback = function()
                    plugin:promptRenameActiveChannel()
                end,
            },
            {
                text = _("Leave Current Room"),
                callback = function()
                    plugin:promptLeaveActiveChannel()
                end,
            },
            {
                text = _("Check Invitations"),
                callback = function()
                    plugin:fetchAndShowInvites()
                end,
            },
        },
    }
end

-- Query room display name from the Daemon's /rooms endpoint
function Matrix:fetchRoomName(room_id)
    if not room_id or room_id == "" then return nil end

    local url = self.daemon_url .. "/rooms"
    local body = {}

    socketutil:set_timeout(5, 5)
    local res, code = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(body),
    }
    socketutil:reset_timeout()

    if res and code == 200 then
        local ok, parsed = pcall(rapidjson.decode, table.concat(body))
        if ok and parsed then
            for _, room in ipairs(parsed) do
                if room.room_id == room_id then
                    local raw_name = room.name
                    if type(raw_name) == "string" and not raw_name:match("^[%s%*%_]*$") then
                        return raw_name
                    end
                end
            end
        end
    end

    return room_id
end

function Matrix:fetchRoomMessages()
    local active_ch = self:getActiveChannel()
    if not active_ch or not active_ch.room_id then
        return nil, "No active channel selected"
    end

    local encoded_room_id = url_encode(active_ch.room_id)
    local url = string.format("%s/messages?room_id=%s", self.daemon_url, encoded_room_id)

    socketutil:set_timeout(5, 5)
    local response_body = {}
    local res, code = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()

    if res and code == 200 then
        local raw_json = table.concat(response_body)
        local ok, parsed = pcall(rapidjson.decode, raw_json)
        
        if ok and type(parsed) == "table" then
            if #parsed > 0 then
                return parsed, nil
            elseif parsed.messages and type(parsed.messages) == "table" then
                return parsed.messages, nil
            end
        end
        return {}, nil
    else
        return nil, string.format("HTTP %s", tostring(code or "Error"))
    end
end

local function formatTimestamp(timestamp_ms)
    if not timestamp_ms then return "" end
    local sec = math.floor(timestamp_ms / 1000)
    return os.date("%H:%M", sec)
end

-- Helper: Send an m.reaction event through the Daemon
function Matrix:sendReaction(event_id, emoji)
    local active_ch = self:getActiveChannel()
    local room_id = active_ch and active_ch.room_id

    if not room_id or room_id == "" then
        UIManager:show(InfoMessage:new{ text = _("Error: Missing active Room ID."), timeout = 3 })
        return
    end

    if not event_id or event_id == "" then
        UIManager:show(InfoMessage:new{ text = _("Error: Cannot react to message without event_id."), timeout = 3 })
        return
    end

    if not emoji or emoji == "" then
        return
    end

    local url = self.daemon_url .. "/react"

    local payload = rapidjson.encode({
        room_id = room_id,
        event_id = event_id,
        key = emoji,
    })

    socketutil:set_timeout(5, 5)
    local response_body = {}
    local res, code = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()

    if res and code == 200 then
        local raw_response = table.concat(response_body)
        local ok, parsed = pcall(rapidjson.decode, raw_response)
        
        if ok and parsed and parsed.status == "success" then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Reacted with %s"), emoji),
                timeout = 1.5,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Reaction sent successfully."),
                timeout = 1.5,
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = string.format(_("Failed to react (HTTP %s)"), tostring(code or "Error")),
            timeout = 3,
        })
    end
end

-- Fetch recent room events, aggregate reactions, and display in a KOReader Menu
function Matrix:fetchAndShowMessages()
    local ButtonDialog = require("ui/widget/buttondialog")

    local active_ch = self:getActiveChannel()
    if not active_ch or not active_ch.room_id then
        UIManager:show(InfoMessage:new{ text = _("No active channel selected.") })
        return
    end
    
    local loading = InfoMessage:new{ 
        text = string.format(_("Fetching messages for %s..."), active_ch.name) 
    }
    UIManager:show(loading)

    local messages, err = self:fetchRoomMessages()
    UIManager:close(loading)

    if err then
        UIManager:show(InfoMessage:new{ text = _("Error fetching messages:\n") .. err })
        return
    end

    if not messages or #messages == 0 then
        UIManager:show(InfoMessage:new{ text = _("No recent messages found in this room.") })
        return
    end

    -- Pass 1: Build reaction map
    local reactions_map = {}
    for _, event in ipairs(messages) do
        if event.type == "m.reaction" or event.type == "reaction" then
            local parent_id = event.relates_to_event_id 
                or event.target_event_id 
                or (event.content and event.content["m.relates_to"] and event.content["m.relates_to"].event_id)
            local key = event.key 
                or (event.content and event.content["m.relates_to"] and event.content["m.relates_to"].key)

            if parent_id and key then
                reactions_map[parent_id] = reactions_map[parent_id] or {}
                reactions_map[parent_id][key] = (reactions_map[parent_id][key] or 0) + 1
            end
        end
    end

    -- Pass 2: Build menu items for non-reaction messages
    local menu_items = {}
    for i = #messages, 1, -1 do
        local msg = messages[i]
        
        if msg.type ~= "m.reaction" and msg.type ~= "reaction" then
            local event_id = msg.event_id or msg.id
            local sender = msg.sender or "Unknown"
            local short_sender = sender:match("@([^:]+)") or sender
            local body_text = msg.body or ""
            local time_str = formatTimestamp(msg.timestamp_ms or msg.origin_server_ts)

            local rx_str = ""
            if event_id and reactions_map[event_id] then
                local rx_list = {}
                for emoji_key, count in pairs(reactions_map[event_id]) do
                    table.insert(rx_list, string.format("%s %d", emoji_key, count))
                end
                if #rx_list > 0 then
                    rx_str = "\n" .. table.concat(rx_list, "   ")
                end
            end

            local item_text = string.format("%s  •  %s\n%s%s", short_sender, time_str, body_text, rx_str)

            table.insert(menu_items, {
                text = item_text,
                callback = function()
                    local dialog
                    dialog = ButtonDialog:new{
                        title = string.format(_("Message from %s"), short_sender),
                        text = string.format("%s\n\n%s", body_text, rx_str ~= "" and ("Reactions: " .. rx_str) or ""),
                        buttons = {
                            {
                                {
                                    text = _("Reply"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        local input_dialog
                                        input_dialog = InputDialog:new{
                                            title = string.format(_("Reply to %s"), short_sender),
                                            input = "",
                                            save_callback = function(reply_text)
                                                UIManager:close(input_dialog)
                                                if not reply_text or reply_text:match("^%s*$") then return end
                                                
                                                local load_reply = InfoMessage:new{ text = _("Sending reply...") }
                                                UIManager:show(load_reply)
                                                
                                                local ok, send_err = self:sendRoomMessage(reply_text, event_id)
                                                UIManager:close(load_reply)
                                                
                                                if ok then
                                                    UIManager:show(InfoMessage:new{ text = _("Reply sent!"), timeout = 1.5 })
                                                else
                                                    UIManager:show(InfoMessage:new{ text = _("Failed to send reply:\n") .. (send_err or "") })
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
                                    text = "👍",
                                    callback = function()
                                        UIManager:close(dialog)
                                        self:sendReaction(event_id, "👍")
                                    end,
                                },
                                {
                                    text = "❤️",
                                    callback = function()
                                        UIManager:close(dialog)
                                        self:sendReaction(event_id, "❤️")
                                    end,
                                },
                            },
                            {
                                {
                                    text = _("Close"),
                                    callback = function() UIManager:close(dialog) end,
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
            text = _("No text messages found in this room."),
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

-- Send a message or reply to a Matrix room via Daemon
function Matrix:sendRoomMessage(message_text, reply_to_event_id)
    local active_ch = self:getActiveChannel()
    if not active_ch or not active_ch.room_id then
        return false, "No active channel"
    end

    local is_reply = reply_to_event_id and reply_to_event_id ~= ""
    local url = self.daemon_url .. (is_reply and "/reply" or "/send")

    local payload_data
    if is_reply then
        payload_data = {
            room_id = active_ch.room_id,
            body = message_text,
            msgtype = "m.text",
            ["m.relates_to"] = {
                ["m.in_reply_to"] = {
                    event_id = reply_to_event_id
                }
            }
        }
    else
        payload_data = {
            room_id = active_ch.room_id,
            message = message_text,
            msgtype = "m.text"
        }
    end

    local payload = rapidjson.encode(payload_data)

    socketutil:set_timeout(5, 5)
    local response_body = {}
    local res, code = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()

    if res and code == 200 then
        local raw_json = table.concat(response_body)
        local ok, parsed = pcall(rapidjson.decode, raw_json)
        if ok and parsed and (parsed.status == "sent" or parsed.status == "success") then
            return true, nil
        end
        return true, nil
    else
        return false, string.format("HTTP %s", tostring(code or "Error"))
    end
end

function Matrix:promptSendMessage()
    local active_ch = self:getActiveChannel()
    local input_dialog
    input_dialog = InputDialog:new{
        title = string.format(_("Send to %s"), active_ch.name),
        input = "",
        save_callback = function(text)
            UIManager:close(input_dialog)

            if not text or text:match("^%s*$") then
                UIManager:show(InfoMessage:new{ text = _("Cannot send empty message.") })
                return
            end

            local loading = InfoMessage:new{ text = _("Sending message...") }
            UIManager:show(loading)

            local ok, err = self:sendRoomMessage(text)
            UIManager:close(loading)

            if not ok then
                UIManager:show(InfoMessage:new{ text = _("Failed to send message:\n") .. err })
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

function Matrix:promptAddChannel()
    local id_dialog
    id_dialog = InputDialog:new{
        title = _("Enter Room ID (e.g. !abc:matrix.org)"),
        input = "",
        save_callback = function(room_id)
            UIManager:close(id_dialog)
            if not room_id or room_id:match("^%s*$") then return end

            local loading = InfoMessage:new{ text = _("Fetching room name...") }
            UIManager:show(loading)

            local join_body = {}
            local join_payload = rapidjson.encode({ room_id = room_id })
            http.request{
                url = self.daemon_url .. "/rooms/join",
                method = "POST",
                headers = {
                    ["Content-Type"] = "application/json",
                    ["Content-Length"] = tostring(#join_payload),
                },
                source = ltn12.source.string(join_payload),
                sink = ltn12.sink.table(join_body),
            }

            local server_name = self:fetchRoomName(room_id)
            UIManager:close(loading)

            local name_dialog
            name_dialog = InputDialog:new{
                title = _("Confirm or Edit Room Name"),
                input = server_name,
                save_callback = function(final_name)
                    UIManager:close(name_dialog)
                    if not final_name or final_name:match("^%s*$") then final_name = server_name end

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

function Matrix:promptLeaveActiveChannel()
    local active_ch = self:getActiveChannel()
    
    if #self.channels <= 1 then
        UIManager:show(InfoMessage:new{ 
            text = _("Cannot leave the only remaining room in your list."),
            timeout = 3
        })
        return
    end

    local confirm = ConfirmBox:new{
        text = string.format(_("Are you sure you want to leave and remove '%s'?"), active_ch.name),
        ok_callback = function()
            local loading = InfoMessage:new{ text = _("Leaving room...") }
            UIManager:show(loading)

            local payload = rapidjson.encode({ room_id = active_ch.room_id })
            local response_body = {}
            
            socketutil:set_timeout(5, 5)
            local res, code = http.request{
                url = self.daemon_url .. "/rooms/leave",
                method = "POST",
                headers = {
                    ["Content-Type"] = "application/json",
                    ["Content-Length"] = tostring(#payload),
                },
                source = ltn12.source.string(payload),
                sink = ltn12.sink.table(response_body),
            }
            socketutil:reset_timeout()
            
            UIManager:close(loading)

            if res and code == 200 then
                table.remove(self.channels, self.active_channel_idx)
                self.active_channel_idx = 1
                self:savePluginSettings()

                UIManager:show(InfoMessage:new{
                    text = _("Left room successfully."),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Failed to leave room. HTTP Code: ") .. tostring(code),
                    timeout = 3,
                })
            end
        end,
    }
    UIManager:show(confirm)
end

function Matrix:promptLogin()
    local user_dialog
    user_dialog = InputDialog:new{
        title = _("Matrix Username\n(e.g., @user:matrix.org)"),
        input = "",
        save_callback = function(username)
            UIManager:close(user_dialog)
            if not username or username:match("^%s*$") then return end

            local pass_dialog
            pass_dialog = InputDialog:new{
                title = _("Matrix Password"),
                input = "",
                is_password = true,
                save_callback = function(password)
                    UIManager:close(pass_dialog)
                    if not password or password:match("^%s*$") then return end

                    local loading = InfoMessage:new{ text = _("Authenticating with Daemon...") }
                    UIManager:show(loading)

                    local payload = rapidjson.encode({
                        username = username,
                        password = password
                    })
                    local response_body = {}
                    
                    socketutil:set_timeout(15, 15)
                    local res, code = http.request{
                        url = self.daemon_url .. "/auth/login",
                        method = "POST",
                        headers = {
                            ["Content-Type"] = "application/json",
                            ["Content-Length"] = tostring(#payload),
                        },
                        source = ltn12.source.string(payload),
                        sink = ltn12.sink.table(response_body),
                    }
                    socketutil:reset_timeout()
                    UIManager:close(loading)

                    if res and code == 200 then
                        UIManager:show(InfoMessage:new{
                            text = _("Login successful! Daemon is now syncing."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Login failed.\nHTTP Code: %s"), tostring(code)),
                            timeout = 4,
                        })
                    end
                end,
            }
            UIManager:show(pass_dialog)
            pass_dialog:onShowKeyboard()
        end,
    }
    UIManager:show(user_dialog)
    user_dialog:onShowKeyboard()
end

function Matrix:promptSSO()
    local loading = InfoMessage:new{ text = _("Fetching SSO Link...") }
    UIManager:show(loading)

    local response_body = {}
    socketutil:set_timeout(5, 5)
    local res, code = http.request{
        url = self.daemon_url .. "/auth/sso/url",
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    UIManager:close(loading)

    if res and code == 200 then
        local url = table.concat(response_body)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Please open this SSO link in a browser:\n\n%s"), url),
        })
    else
        UIManager:show(InfoMessage:new{ 
            text = _("Failed to retrieve SSO link from daemon."), 
            timeout = 3 
        })
    end
end

function Matrix:fetchAndShowInvites()
    local ButtonDialog = require("ui/widget/buttondialog")
    local loading = InfoMessage:new{ text = _("Checking for invitations...") }
    UIManager:show(loading)

    local response_body = {}
    socketutil:set_timeout(5, 5)
    local res, code = http.request{
        url = self.daemon_url .. "/invites",
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    UIManager:close(loading)

    if not res or code ~= 200 then
        UIManager:show(InfoMessage:new{ text = _("Failed to fetch invitations."), timeout = 3 })
        return
    end

    local raw_json = table.concat(response_body)
    local ok, invites = pcall(rapidjson.decode, raw_json)
    
    if not ok or type(invites) ~= "table" or #invites == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pending invitations found."), timeout = 3 })
        return
    end

    -- Use 'index' instead of '_' to avoid overwriting the gettext _() function
    local invite_items = {}
    for index, invite in ipairs(invites) do
        local r_id = invite.room_id or ""
        local r_name = (type(invite.name) == "string" and invite.name ~= "") and invite.name or r_id

        table.insert(invite_items, {
            text = r_name .. "\n" .. r_id,
            callback = function()
                local dialog
                dialog = ButtonDialog:new{
                    title = _("Accept Invitation?"),
                    text = _("You are invited to join:") .. "\n\n" .. r_name .. "\n\n(" .. r_id .. ")",
                    buttons = {
                        {
                            {
                                text = _("Accept Invite"),
                                callback = function()
                                    UIManager:close(dialog)
                                    local load_join = InfoMessage:new{ text = _("Accepting invite...") }
                                    UIManager:show(load_join)

                                    local payload = rapidjson.encode({ room_id = r_id })
                                    local join_body = {}
                                    
                                    socketutil:set_timeout(5, 5)
                                    local j_res, j_code = http.request{
                                        url = self.daemon_url .. "/rooms/join",
                                        method = "POST",
                                        headers = {
                                            ["Content-Type"] = "application/json",
                                            ["Content-Length"] = tostring(#payload),
                                        },
                                        source = ltn12.source.string(payload),
                                        sink = ltn12.sink.table(join_body),
                                    }
                                    socketutil:reset_timeout()
                                    UIManager:close(load_join)

                                    if j_res and j_code == 200 then
                                        table.insert(self.channels, {
                                            name = r_name,
                                            room_id = r_id,
                                        })
                                        self.active_channel_idx = #self.channels
                                        self:savePluginSettings()

                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Joined %s! Switched to channel."), r_name),
                                            timeout = 3,
                                        })
                                    else
                                        UIManager:show(InfoMessage:new{
                                            text = string.format(_("Failed to accept (HTTP %s)"), tostring(j_code or "Error")),
                                            timeout = 3,
                                        })
                                    end
                                end,
                            },
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                        }
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end

    local invite_menu = Menu:new{
        title = _("Pending Invitations"),
        item_table = invite_items,
        is_popmenu = false,
    }
    UIManager:show(invite_menu)
end
function Matrix:autoSyncRooms()
    local loading = InfoMessage:new{ text = _("Fetching all rooms and contacts...") }
    UIManager:show(loading)

    local response_body = {}
    socketutil:set_timeout(5, 5)
    local res, code = http.request{
        url = self.daemon_url .. "/rooms",
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    UIManager:close(loading)

    if not res or code ~= 200 then
        UIManager:show(InfoMessage:new{ text = _("Failed to sync rooms from daemon."), timeout = 3 })
        return
    end

    local ok, fetched_rooms = pcall(rapidjson.decode, table.concat(response_body))
    if not ok or type(fetched_rooms) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Failed to parse rooms response."), timeout = 3 })
        return
    end

    local added_count = 0

    for _, server_room in ipairs(fetched_rooms) do
        local room_id = server_room.room_id
        local raw_name = server_room.name
        local room_name = nil

        if type(raw_name) == "string" and not raw_name:match("^[%s%*%_]*$") then
            room_name = raw_name
        else
            room_name = room_id
        end

        local exists = false
        for _, local_ch in ipairs(self.channels) do
            if local_ch.room_id == room_id then
                exists = true
                local_ch.name = room_name
                break
            end
        end

        if not exists then
            table.insert(self.channels, {
                name = room_name,
                room_id = room_id,
            })
            added_count = added_count + 1
        end
    end

    self:savePluginSettings()
    if G_settings then
        G_settings:save()
    end

    if (not self.active_channel_idx or self.active_channel_idx == 0) and #self.channels > 0 then
        self.active_channel_idx = 1
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Sync complete! Added %d new rooms/contacts."), added_count),
        timeout = 3,
    })
end

function Matrix:promptTokenLogin()
    local user_dialog
    user_dialog = InputDialog:new{
        title = _("Matrix User ID\n(e.g., @user:mozilla.org)"),
        input = "",
        save_callback = function(user_id)
            UIManager:close(user_dialog)
            if not user_id or user_id:match("^%s*$") then return end

            local token_dialog
            token_dialog = InputDialog:new{
                title = _("Matrix Access Token"),
                input = "",
                is_password = true,
                save_callback = function(access_token)
                    UIManager:close(token_dialog)
                    if not access_token or access_token:match("^%s*$") then return end

                    local loading = InfoMessage:new{ text = _("Restoring session via token...") }
                    UIManager:show(loading)

                    local payload = rapidjson.encode({
                        user_id = user_id,
                        access_token = access_token
                    })
                    local response_body = {}
                    
                    socketutil:set_timeout(10, 10)
                    local res, code = http.request{
                        url = self.daemon_url .. "/auth/token",
                        method = "POST",
                        headers = {
                            ["Content-Type"] = "application/json",
                            ["Content-Length"] = tostring(#payload),
                        },
                        source = ltn12.source.string(payload),
                        sink = ltn12.sink.table(response_body),
                    }
                    socketutil:reset_timeout()
                    UIManager:close(loading)

                    if res and code == 200 then
                        UIManager:show(InfoMessage:new{
                            text = _("Session restored successfully! Daemon is now syncing."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("Token login failed.\nHTTP Code: %s"), tostring(code)),
                            timeout = 4,
                        })
                    end
                end,
            }
            UIManager:show(token_dialog)
            token_dialog:onShowKeyboard()
        end,
    }
    UIManager:show(user_dialog)
    user_dialog:onShowKeyboard()
end

return Matrix
