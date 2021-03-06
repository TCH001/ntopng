--
-- (C) 2019-20 - ntop.org
--
local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path

require "lua_utils"

local page_utils = require("page_utils")
local template = require "template_utils"
local json = require "dkjson"
local plugins_utils = require("plugins_utils")
local notification_configs = require("notification_configs")

sendHTTPContentTypeHeader('text/html')

if not haveAdminPrivileges() then
    return
end

page_utils.set_active_menu_entry(page_utils.menu_entries.endpoint_notifications)

-- append the menu above the page
dofile(dirs.installdir .. "/scripts/lua/inc/menu.lua")
page_utils.print_page_title(i18n("endpoint_notifications.endpoint_list"))

-- Prepare the response
local context = {
    notifications = {
        endpoints = notification_configs.get_types(),
    },
    template_utils = template,
    page_utils = page_utils,
    json = json,
    info = ntop.getInfo()
}

-- print config_list.html template
print(template.gen("pages/endpoint_notifications_list.template", context))

-- append the menu below the page
dofile(dirs.installdir .. "/scripts/lua/inc/footer.lua")
