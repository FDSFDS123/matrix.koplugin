local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox") -- NEW IMPORT
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("gettext")
local Menu = require("ui/widget/menu")

-- Use standard socket.http since the daemon runs locally unencrypted
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")

-- Emoji mapping table: maps Unicode characters & standard reactions to text shortcodes[cite: 1]
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

-- Convert raw emojis in any text string into safely displayable :shortcodes:[cite: 1]
local function sanitizeEmojiText(str)
    if not str or str == "" then return "" end
    for emoji, shortcode in pairs(EMOJI_MAP) do
        str = str:gsub(emoji, shortcode)
    end
    return str
end

local Matrix = Widget:extend{
    name = "matrix",
    is_doc_only = false,

    -- Point directly to the Rust E2EE Daemon
    daemon_url = "http://127.0.0.1:8080",
}

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

function Matrix:addToMainMenu(menu_items)
    local plugin = self

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

    -- Clarified that this handles invites too (via daemon's /rooms/join)
    table.insert(channel_sub_items, {
        text = _("+ Join Room / Accept Invite"),
        callback = function()
            plugin:promptAddChannel()
        end,
    })

    menu_items.matrix_plugin = {
        text = _("Matrix"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Test Daemon Connection"),
                callback = function()
                    plugin:testDaemonConnection()
                end,
            },
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
                        text = _("Login with Access Token"), -- <-- NEW OPTION
                        callback = function()
                            plugin:promptTokenLogin()
                        end,
                    },
                }
            },
            {
                text = _("Auto-Sync Rooms & Contacts"),
                callback = function()
                    plugin:autoSyncRooms()
                end,
            },
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
            -- New menu item for leaving rooms
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
                if room.room_id == room_id and room.name then
                    return room.name
                end
            end
        end
    end

    return room_id
end

-- Fetch messages from the Daemon and filter by the active channel
function Matrix:fetchRoomMessages()
    local response_body = {}
    local active_ch = self:getActiveChannel()
    local room_id = active_ch.room_id

    if not room_id or room_id == "" then
        return nil, _("Missing Room ID for active channel.")
    end

    local url = self.daemon_url .. "/messages"

    socketutil:set_timeout(5, 5)
    local res, code, headers, status = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()

    if not res or not code then
        return nil, string.format("Network Request Failed:\n%s", tostring(status or "Timeout"))
    end

    local raw_data = table.concat(response_body)

    if code ~= 200 then
        return nil, string.format("Daemon HTTP %s Error:\n%s", tostring(code), raw_data)
    end

    local ok, parsed = pcall(rapidjson.decode, raw_data)
    if not ok or type(parsed) ~= "table" then
        return nil, string.format("Failed to parse JSON response:\n%s", raw_data)
    end

    -- The daemon returns a flat list of messages for all rooms. Filter for the active one.
    local filtered_messages = {}
    for _, msg in ipairs(parsed) do
        if msg.room_id == room_id then
            table.insert(filtered_messages, msg)
        end
    end

    return filtered_messages, nil
end

local function formatTimestamp(timestamp_ms)
    if not timestamp_ms then return "" end
    local sec = math.floor(timestamp_ms / 1000)
    return os.date("%H:%M", sec)
end

function Matrix:fetchAndShowMessages()
    local ButtonDialog = require("ui/widget/buttondialog")
    local active_ch = self:getActiveChannel()
    
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

    local menu_items = {}
    -- Display newest messages at the top
    for i = #messages, 1, -1 do
        local msg = messages[i]
        local short_sender = msg.sender:match("@([^:]+)") or msg.sender
        local clean_body = sanitizeEmojiText(msg.body)
        local time_str = formatTimestamp(msg.timestamp_ms)

        local item_text = string.format("%s  •  %s\n%s", short_sender, time_str, clean_body)

        table.insert(menu_items, {
            text = item_text,
            callback = function()
                local dialog
                dialog = ButtonDialog:new{
                    title = string.format(_("Message from %s"), short_sender),
                    text = clean_body,
                    buttons = {
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

    if #menu_items == 0 then
        table.insert(menu_items, {
            text = _("No recent messages found in this room."),
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

-- Send a text message via the Daemon's /send endpoint
function Matrix:sendRoomMessage(text)
    if not text or text:match("^%s*$") then
        return nil, _("Message cannot be empty.")
    end

    local response_body = {}
    local active_ch = self:getActiveChannel()
    local room_id = active_ch.room_id

    local url = self.daemon_url .. "/send"

    local payload = rapidjson.encode({
        room_id = room_id,
        message = text,
    })

    socketutil:set_timeout(5, 5)
    local res, code, headers, status = http.request{
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

    if not res or not code then
        return nil, string.format("Network Error:\n%s", tostring(status or "Timeout"))
    end

    if code ~= 200 then
        local raw_data = table.concat(response_body)
        return nil, string.format("Daemon HTTP %s Error:\n%s", tostring(code), raw_data)
    end

    return true, nil
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

            -- Automatically join the room via the daemon
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
-- Leave the currently active room
function Matrix:promptLeaveActiveChannel()
    local active_ch = self:getActiveChannel()
    
    -- Prevent the user from leaving their last configured room
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
                -- Remove the channel from the local Lua settings
                table.remove(self.channels, self.active_channel_idx)
                -- Safely revert to the first channel in the list
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
-- Standard Username and Password Login
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
                is_password = true, -- Masks text on supported KOReader versions
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

-- Fallback: Fetch SSO URL for browser login (Google/GitHub/Apple)
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
        local url = table.concat(response_body) -- <-- THIS LINE WAS MISSING
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
-- Fetch and display pending room invitations with options to accept
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

    local ok, invites = pcall(rapidjson.decode, table.concat(response_body))
    if not ok or type(invites) ~= "table" or #invites == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pending invitations found."), timeout = 3 })
        return
    end

    -- Create an interactive menu or dialog for the first pending invite found
    local invite = invites[1]
    local room_name = invite.name or invite.room_id

    local dialog
    dialog = ButtonDialog:new{
        title = _("Pending Room Invitation"),
        text = string.format(_("You are invited to:\n%s\n(%s)"), room_name, invite.room_id),
        buttons = {
            {
                {
                    text = _("Accept Invite"),
                    callback = function()
                        UIManager:close(dialog)
                        local load_join = InfoMessage:new{ text = _("Accepting invite...") }
                        UIManager:show(load_join)

                        local payload = rapidjson.encode({ room_id = invite.room_id })
                        local join_body = {}
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
                        UIManager:close(load_join)

                        if j_res and j_code == 200 then
                            -- Automatically add it to local channels list
                            table.insert(self.channels, {
                                name = room_name,
                                room_id = invite.room_id,
                            })
                            self.active_channel_idx = #self.channels
                            self:savePluginSettings()

                            UIManager:show(InfoMessage:new{
                                text = _("Invite accepted! Switched to room."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to accept invitation."),
                                timeout = 3,
                            })
                        end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            }
        },
    }
    UIManager:show(dialog)
end
-- Fetch all rooms from daemon and automatically populate missing entries into KOReader settings
function Matrix:autoSyncRooms()
    local loading = InfoMessage:new{ text = _("Fetching all rooms and contacts...") }
    UIManager:show(loading)

    local response_body = {}
    socketutil:set_timeout(5, 5)
    local res, code = http.request{
        url = self.daemon_url .. "/rooms/all",
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

    -- Loop through daemon rooms and append any that aren't already saved locally
    for _, server_room in ipairs(fetched_rooms) do
        local room_id = server_room.room_id
        local room_name = server_room.name or room_id

        local exists = false
        for _, local_ch in ipairs(self.channels) do
            if local_ch.room_id == room_id then
                exists = true
                -- Update name if it changed on the server
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
    -- Ensure settings are flushed to storage immediately
    if G_settings then
        G_settings:save()
    end

    -- If no active channel is currently set and we added rooms, default to the first one
    if (not self.active_channel_idx or self.active_channel_idx == 0) and #self.channels > 0 then
        self.active_channel_idx = 1
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Sync complete! Added %d new rooms/contacts."), added_count),
        timeout = 3,
    })
end

-- Test if the local Rust daemon is up and running
function Matrix:testDaemonConnection()
    local loading = InfoMessage:new{ text = _("Checking daemon status...") }
    UIManager:show(loading)

    local response_body = {}
    socketutil:set_timeout(3, 3)
    local res, code = http.request{
        url = self.daemon_url .. "/health",
        method = "GET",
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    UIManager:close(loading)

    if res and code == 200 then
        UIManager:show(InfoMessage:new{
            text = _("Success! Matrix daemon is running and online."),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Connection failed. Is the Rust daemon running?"),
            timeout = 4,
        })
    end
end
-- Login using an existing Matrix User ID and Access Token
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
