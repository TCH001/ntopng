--
-- (C) 2019-20 - ntop.org
--
-- The functions below are called with a LuaC "flow" context set.
-- See user_scripts.load() documentation for information
-- on adding custom scripts.
--
-- NOTE: this script is loaded once and cached into the vm and then invoked
-- multiple times. The setup() function is only called with the first load.
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path

require "lua_utils"
require "flow_utils"
local alert_utils = require "alert_utils"
local user_scripts = require("user_scripts")
local alert_consts = require("alert_consts")
local flow_consts = require("flow_consts")
local json = require("dkjson")
local alerts_api = require("alerts_api")
local ids_utils = nil

if ntop.isPro() then
  package.path = dirs.installdir .. "/pro/scripts/lua/modules/?.lua;" .. package.path
end

local do_benchmark = true          -- Compute benchmarks and store their results
local do_print_benchmark = false   -- Print benchmarks results to standard output
local do_trace = false             -- Trace lua calls
local calculate_stats = false
local flows_config = nil
local score_enabled = nil

local available_modules = nil

-- Keeps information about the current predominant alerted status
local alerted_status
local alert_type_params
local alerted_status_score
local hosts_disabled_status
local confset_id
local alerted_user_script
local cur_user_script

-- Save them as they are overridden
local c_flow_set_status = flow.setStatus
local c_flow_clear_status = flow.clearStatus

local stats = {
   num_invocations = 0, 	-- Total number of invocations of this module
   num_complete_scripts = 0,	-- Number of invoked scripts on flows with THW completed
   num_partial_scripts = 0,	-- Number of invoked scripts on flows with THW not-completed
   num_try_alerts = 0,  	-- Number of calls to triggerFlowAlert
   num_skipped_to_time = 0,     -- Number of calls skipped due to no time left
   partial_scripts = {},	-- List of scripts invoked on flow with THW not-completed
}

local max_score = flow_consts.max_score

-- #################################################################

local function trace_f(trace_msg)
   local fmt = string.format("[ifid: %i] %s\n", interface.getId(), trace_msg or '')
   print(fmt)
end

-- #################################################################

local function addL4Callaback(l4_hooks, l4_proto, hook_name, script_key, callback)
   local l4_scripts = l4_hooks[l4_proto]

   if not l4_scripts then
      l4_scripts = {}
      l4_hooks[l4_proto] = l4_scripts
   end

   l4_scripts[hook_name] = l4_scripts[hook_name] or {}
   l4_scripts[hook_name][script_key] = callback
end

local function skip_disabled_flow_scripts(user_script)
   -- NOTE: this filter can only be applied here because there is no
   -- concept of entity_value for a flow.
   return(user_scripts.getTargetHookConfig(flows_config, user_script).enabled)
end

-- #################################################################

local function prioritizeL4Callabacks(l4_hooks)
   -- Set the priority to the `prio` indicated in the module, or to zero,
   -- if no `prio` is indicated
   local mod_prios = {}
   for mod_key, mod in pairs(available_modules.modules) do
      mod_prios[mod_key] = tonumber(mod.prio) or 0
   end

   -- Sort available modules by descending `prio`
   -- That is from lower (negative) to higher (positive) priorities
   -- E.g., a prio -20 is executed after a prio 0 which, in turn, is executed
   -- after a prio 20
   local mods_by_prio = {}
   for mod_key, mod_prio in pairsByValues(mod_prios, rev) do
      mods_by_prio[#mods_by_prio + 1] = mod_key
   end

   -- Updates l4_hooks and convert modules to ordered lua arrays
   for l4_proto, hooks in pairs(l4_hooks) do
      -- e.g.:
      -- 1 (l4_proto) -> protocolDetected (hooks table)
      -- 1 (l4_proto) -> periodicUpdate (hooks table)
      for hook_name, modules in pairs(hooks) do
	 -- e.g.:
	 -- protocolDetected (hook_name) -> invalid_dns_query
	 -- protocolDetected (hook_name) -> web_mining
	 local sorted_modules = {}
	 for _, mod_key in ipairs(mods_by_prio) do
	    if modules[mod_key] then
	       sorted_modules[#sorted_modules + 1] = {mod_key = mod_key, mod_fn = modules[mod_key]}
	    end
	 end

	 -- Update the hooks with sorted hooks
	 hooks[hook_name] = sorted_modules
      end
   end

   -- Sets l4_hooks with the sorted hooks
   available_modules.l4_hooks = l4_hooks
end

-- #################################################################

-- The function below is called once (#pragma once)
function setup()
   if do_trace then
      trace_f(string.format("flow.lua:setup() called"))
   end

   local ifid = interface.getId()
   local view_ifid
   if interface.isViewed() then
      view_ifid = interface.viewedBy()
   end

   local configsets = user_scripts.getConfigsets()

   -- In case of viewed interfaces, the configuration retrieved is the one belonging to the
   -- view.
   flows_config, confset_id = user_scripts.getTargetConfig(configsets, "flow", (view_ifid or ifid)..'')
   alerted_user_script = nil

   -- Load the disabled hosts status. As hosts stay in the view, the correct disabled status needs to look there
   hosts_disabled_status = alerts_api.getAllHostsDisabledStatusBitmaps(view_ifid or ifid)

   -- To execute flows, the viewed interface id is used instead, as flows reside in the viewed interface, not in the view
   available_modules = user_scripts.load(ifid, user_scripts.script_types.flow, "flow", {
      do_benchmark = true,
      scripts_filter = skip_disabled_flow_scripts,
   })

   -- Reorganize the modules to optimize lookup by L4 protocol
   -- E.g. l4_hooks = {tcp -> {periodicUpdate -> {check_tcp_retr}}, other -> {protocolDetected -> {mud, score}}}

   -- Prepare the l4 hooks
   local l4_hooks = {}

   for hook_name, hooks in pairs(available_modules.hooks) do
      -- available_modules.l4_hooks
      for script_key, callback in pairs(hooks) do
         local script = available_modules.modules[script_key]

         if script.l4_proto then
            local l4_proto = l4_proto_to_id(script.l4_proto)

            if not l4_proto then
               traceError(TRACE_ERROR, TRACE_CONSOLE, string.format("Unknown l4_proto '%s' in module '%s', skipping", script.l4_proto, script_key))
            else
               addL4Callaback(l4_hooks, l4_proto, hook_name, script_key, callback)
            end
         else
            -- No l4 filter is active for the specified module
            -- Attach the protocol to all the L4 protocols
            for _, l4_proto in pairs(l4_keys) do
               local l4_proto = l4_proto[3]

               if l4_proto > 0 then
                  addL4Callaback(l4_hooks, l4_proto, hook_name, script_key, callback)
               end
            end
         end
      end
   end

   prioritizeL4Callabacks(l4_hooks)

   if(ntop.isEnterpriseM()) then
      ids_utils = require("ids_utils")
   end
end

-- #################################################################

-- The function below is called once (#pragma once) right before
-- the lua virtual machine is destroyed
function teardown()
   if do_trace then
      trace_f("flow.lua:teardown() called")
   end

   if available_modules then
      user_scripts.teardown(available_modules, do_benchmark, do_print_benchmark)
   end

   if calculate_stats then
      tprint(stats)
   end
end

-- #################################################################

-- @brief Store more information into the flow status. Such information
-- does not depend the specific flow status being triggered
-- @param l4_proto the flow L4 protocol ID
-- @param flow_status the status table to augument
local function augumentFlowStatusInfo(l4_proto, flow_status)
   flow_status["ntopng.key"] = flow.getKey()
   flow_status["hash_entry_id"] = flow.getHashEntryId()

   if l4_proto == 1 --[[ ICMP ]] then
      -- NOTE: this information is parsed by getFlowStatusInfo()
      flow_status["icmp"] = flow.getICMPStatusInfo()
   end
end

-- #################################################################

local function triggerFlowAlert(now, l4_proto)
   local cli_key = flow.getClientKey()
   local srv_key = flow.getServerKey()
   local cli_disabled_status = hosts_disabled_status[cli_key] or 0
   local srv_disabled_status = hosts_disabled_status[srv_key] or 0
   local status_key = alerted_status.status_key

   -- Ensure that this status was not disabled by the user on the client/server
   if (cli_disabled_status ~= 0 and ntop.bitmapIsSet(cli_disabled_status, status_key)) or
       (srv_disabled_status ~= 0 and ntop.bitmapIsSet(srv_disabled_status, status_key)) then

      if do_trace then
	  trace_f(string.format("Not triggering flow alert for status %u [cli_bitmap: %s/%d][srv_bitmap: %s/%d]",
				status_key, cli_key, cli_disabled_status, srv_key, srv_disabled_status))
      end

      return(false)
   end

   if do_trace then
      trace_f(string.format("flow.triggerAlert(type=%s, severity=%s)",
			 alert_consts.alertTypeRaw(alerted_status.alert_type.alert_key),
			 alert_consts.alertSeverityRaw(alerted_status.alert_severity.severity_id)))
   end

   alert_type_params = alert_type_params or {}

   if type(alert_type_params) == "table" then
      -- NOTE: porting this to C is not feasable as the lua table can contain
      -- arbitrary data
      augumentFlowStatusInfo(l4_proto, alert_type_params)
      alerts_api.addAlertGenerationInfo(alert_type_params, alerted_user_script, confset_id)

      alert_type_params = json.encode(alert_type_params)
   end

   local triggered = flow.triggerAlert(status_key,
      alerted_status.alert_type.alert_key,
      alerted_status.alert_severity.severity_id,
      now, alert_type_params)

   return(triggered)
end

-- #################################################################

local function in_time()
   -- Calling os.time() costs per call ~0.033 usecs so nothing expensive to be called every time
   --
   -- This is the code used to profile
   --
   -- local num_calls = 1000000
   -- local start_ticks = ntop.getticks()
   -- for i = 0, num_calls do
   --    local a = os.time()
   -- end
   -- local end_ticks = ntop.getticks()
   -- traceError(TRACE_ERROR, TRACE_CONSOLE, string.format("usecs [ticks]: %.8f", (end_ticks - start_ticks) / ntop.gettickspersec() / num_calls * 1000 * 1000))


   local res
   local time_left = ntop.getDeadline() - os.time()

   if time_left >= 4 then
      -- There's enough time to run every script
      res = true
   elseif time_left > 1 then
      -- Start skipping unidirectional flows as the deadline is approaching
      res = flow.getPacketsRcvd() > 0
   else
      -- No time left
      res = false
   end

   if not res and calculate_stats then
      stats.num_skipped_to_time = stats.num_skipped_to_time + 1
   end

   return res
end

-- #################################################################

-- Function for the actual module execution. Iterates over available (and enabled)
-- modules, calling them one after one.
-- @param l4_proto the L4 protocol of the flow
-- @param master_id the L7 master protocol of the flow
-- @param app_id the L7 app protocol of the flow
-- @param mod_fn the callback to call
-- @return true if some module was called, false otherwise
local function call_modules(l4_proto, master_id, app_id, mod_fn, update_ctr)
   if calculate_stats then
      stats.num_invocations = stats.num_invocations + 1
   end

   if not available_modules then
      return true
   end

   if not in_time() then
      return false -- No time left to execute scripts
   end

   local all_modules = available_modules.modules
   local hooks = available_modules.l4_hooks[l4_proto]

   -- Reset predominant status information
   alerted_status = nil
   alert_type_params = nil
   alerted_status_score = -1

   if hooks then
      hooks = hooks[mod_fn]
   end

   if not hooks then
      if do_trace then
	 trace_f(string.format("No flow.lua modules, skipping %s(%d) for %s", mod_fn, l4_proto, shortFlowLabel(flow.getInfo())))
      end

      return true
   end

   if do_trace then
      trace_f(string.format("%s()[START]: bitmap=0x%x predominant=%d", mod_fn, flow.getStatus(), flow.getPredominantStatus()))
   end

   local now = os.time()
   local twh_in_progress = l4_proto == 6 --[[TCP]] and not flow.isTwhOK()

   for _, mod in ipairs(hooks) do
      local mod_key = mod.mod_key
      local hook_fn = mod.mod_fn
      local script = all_modules[mod_key]

      if mod_fn == "periodicUpdate" then
	 -- Check if the script should be invoked
	 if (update_ctr % script.periodic_update_divisor) ~= 0 then
	    if do_trace then
	       trace_f(string.format("%s() [check: %s]: skipping periodicUpdate [ctr: %s, divisor: %s, frequency: %s]",
				  mod_fn, mod_key, update_ctr, script.periodic_update_divisor, script.periodic_update_seconds))
	    end

	    goto continue
	 end
      end

      -- Check if the script requires the flow to have successfully completed the three-way handshake
      if script.three_way_handshake_ok and twh_in_progress then
	 -- Check if the script wants the three way handshake completed
	 if do_trace then
	    trace_f(string.format("%s() [check: %s]: skipping flow with incomplete three way handshake", mod_fn, mod_key))
	 end

	 goto continue
      end

      local script_l7 = script.l7_proto_id

      if script_l7 and master_id ~= script_l7 and app_id ~= script_l7 then
	 if do_trace then
	    trace_f(string.format("%s() [check: %s]: skipping flow with proto=%s/%s [wants: %s]", mod_fn, mod_key, master_id, app_id, script_l7))
	 end

	 goto continue
      end

      if calculate_stats then
	 if twh_in_progress then
	    stats.num_partial_scripts = stats.num_partial_scripts + 1
	    stats.partial_scripts[mod_key] = 1
	 else
	    stats.num_complete_scripts = stats.num_complete_scripts + 1
	 end
      end

      if do_trace then
	 local info = flow.getInfo()

	 if do_trace then
	    trace_f(string.format("%s() [check: %s]: %s", mod_fn, mod_key, shortFlowLabel(info)))
	 end
      end

      local conf = user_scripts.getTargetHookConfig(flows_config, script)

      cur_user_script = script
      hook_fn(now, conf.script_conf or {})

      ::continue::
   end

   if do_trace then
      trace_f(string.format("%s()[END]: bitmap=0x%x predominant=%d score=%d flow.score=%d", 
         mod_fn, flow.getStatus(), flow.getPredominantStatus(), 
         alerted_status_score, flow.getAlertedStatusScore())
)
   end

   -- Only trigger the alert if its score is greater than the currently
   -- triggered alert score
   if alerted_status and (alerted_status_score > flow.getAlertedStatusScore()) then
      triggerFlowAlert(now, l4_proto)

      if calculate_stats then
	 stats.num_try_alerts = stats.num_try_alerts + 1
      end
   end

   return true
end

-- #################################################################

-- @brief This provides an API that flow user_scripts can call in order to
-- set a flow status bit. The status_info of the predominant status is
-- saved for later use.
function flow.triggerStatus(status_info, flow_score, cli_score, srv_score)
   local flow_status_type = status_info.status_type
   local status_key = flow_status_type.status_key
   flow_score = flow_score or 0

   if(tonumber(status_info) ~= nil) then
      tprint("Invalid status_info")
      tprint(debug.traceback())
      return
   end

   if(flow_status_type and status_info and ids_utils and
      status_key == flow_consts.status_types.status_external_alert.status_key and
      status_info.alert_type_params and (status_info.alert_type_params.source == "suricata")) then
      local fs, cs, ss = ids_utils.computeScore(status_info.alert_type_params)
      flow_score = fs
      cli_score = cs
      srv_score = ss
   end

   -- NOTE: The "flow_status_type.status_key < alerted_status.status_key" check must
   -- correspond to the Flow::getPredominantStatus logic in order to determine
   -- the same predominant status
   if((not alerted_status) or (flow_score > alerted_status_score) or
	 ((flow_score == alerted_status_score) and (flow_status_type.status_key < alerted_status.status_key))) then
      -- The new alerted status as an higher score
      alerted_status = flow_status_type
      alert_type_params = status_info["alert_type_params"] or {}
      alerted_status_score = flow_score
      alerted_user_script = cur_user_script
   end

   flow.setStatus(flow_status_type, flow_score, cli_score, srv_score)
end

-- #################################################################

-- NOTE: overrides the C flow.setStatus (now saved in c_flow_set_status)
function flow.setStatus(flow_status_type, flow_score, cli_score, srv_score)
   local status_key = flow_status_type.status_key

   if(not flow.isStatusSet(status_key)) then
      flow_score = math.min(math.max(flow_score or 0, 0), max_score)
      cli_score = math.min(math.max(cli_score or 0, 0), max_score)
      srv_score = math.min(math.max(srv_score or 0, 0), max_score)

      c_flow_set_status(status_key, flow_score, cli_score, srv_score, cur_user_script.key)
      return(true)
   end

   return(false)
end

-- #################################################################

-- NOTE: overrides the C flow.clearStatus (now saved in c_flow_clear_status)
function flow.clearStatus(flow_status_type)
   local status_key = flow_status_type.status_key

   if c_flow_clear_status(status_key) then
      -- The status has actually changed
      if do_trace then
	 trace_f(string.format("flow.clearStatus: predominant status changed to %d", flow.getPredominantStatus()))
      end
   end
end

-- #################################################################

-- Given an L4 protocol, we must call both the hooks registered for that protocol and
-- the hooks registered for any L4 protocol (id 255)
function protocolDetected(l4_proto, master_id, app_id)
   return call_modules(l4_proto, master_id, app_id, "protocolDetected")
end

-- #################################################################

function statusChanged(l4_proto, master_id, app_id)
   return call_modules(l4_proto, master_id, app_id, "statusChanged")
end

-- #################################################################

function flowEnd(l4_proto, master_id, app_id)
   return call_modules(l4_proto, master_id, app_id, "flowEnd")
end

-- #################################################################

function periodicUpdate(l4_proto, master_id, app_id, update_ctr)
   return call_modules(l4_proto, master_id, app_id, "periodicUpdate", update_ctr)
end
