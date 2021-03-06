--
-- (C) 2019-20 - ntop.org
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path
require "lua_utils"
local alert_consts = require("alert_consts")
local user_scripts = require("user_scripts")

local syslog_module = {
  -- Script category
  category = user_scripts.script_categories.security,

  key = "host_log",

  -- See below
  hooks = {},

  gui = {
    i18n_title = "host_log_collector.title",
    i18n_description = "host_log_collector.description",
  },
}

-- #################################################################
  
local syslog_facility = {
   [0] = "kernel messages",
   [1] = "user-level messages",
   [2] = "mail system",
   [3] = "system daemons",
   [4] = "**security/authorization messages",
   [5] = "messages generated internally by syslog",
   [6] = "line printer subsystem",
   [7] = "network news subsystem",
   [8] = "UUCP subsystem",
   [9] = "clock daemon",
   [10] = "security/authorization messages",
   [11] = "FTP daemon",
   [12] = "NTP subsystem",
   [13] = "log audit",
   [14] = "log alert",
   [15] = "clock daemon",
}

local syslog_level = {
   [0] = "EMERGENCY",
   [1] = "ALERT",
   [2] = "CRITICAL",
   [3] = "ERROR",
   [4] = "WARNING",
   [5] = "NOTICE",
   [6] = "INFORMATIONAL",
   [7] = "DEBUG",
}

-- #################################################################

-- The function below is called once (#pragma once)
function syslog_module.setup()
   return true
end

-- #################################################################

-- The function below is called for each received alert
function syslog_module.hooks.handleEvent(message, host, priority)
   -- Priority = Facility * 8 + Level
   local facility = math.floor(priority / 8)
   local level = priority - (facility * 8)

   local facility_name = syslog_facility[facility] or ""
   local level_name = syslog_level[level] or ""

   -- traceError(TRACE_NORMAL, TRACE_CONSOLE, "[host="..host.."][facility="..facility_name.."][level="..level_name.."][message="..message.."]")

end 

-- #################################################################

-- The function below is called once (#pragma once)
function syslog_module.teardown()
   return true
end

-- #################################################################

return syslog_module
