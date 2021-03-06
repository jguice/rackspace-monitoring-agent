--[[
Copyright 2012 Rackspace

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
--]]
local BaseCheck = require('./base').BaseCheck
local CheckResult = require('./base').CheckResult
local fs = require('fs')
local os = require('os')
local misc = require('/base/util/misc')

local table = require('table')
local units = {
  rx_bytes = 'bytes',
  rx_dropped = 'packets',
  rx_errors = 'errors',
  rx_frame = 'frames',
  rx_overruns = 'overruns',
  rx_packets = 'packets',
  tx_bytes = 'bytes',
  tx_carrier = 'errors',
  tx_collisions = 'collisions',
  tx_dropped = 'packets',
  tx_errors = 'errors',
  tx_overruns = 'overruns',
  tx_packets = 'packets',
  link_state = 'link_state'
}

local NetworkCheck = BaseCheck:extend()

function NetworkCheck:initialize(params)
  BaseCheck.initialize(self, params)
  self.interface_name = params.details and params.details.target
end

function NetworkCheck:getType()
  return 'agent.network'
end

function NetworkCheck:getTargets(callback)
  local s = sigar:new()
  local netifs = s:netifs()
  local targets = {}
  for i=1, #netifs do
    local info = netifs[i]:info()
    table.insert(targets, info.name)
  end
  callback(nil, targets)
end

-- Dimension is is the interface name, e.g. eth0, lo0, etc

function NetworkCheck:run(callback)
  -- Perform Check
  local s = sigar:new()
  local netifs = s:netifs()
  local checkResult = CheckResult:new(self, {})
  local usage

  if not self.interface_name then
    checkResult:setError('Missing target parameter; give me an interface.')
    return callback(checkResult)
  end

  local interface = nil
  for i=1, #netifs do
    local name = netifs[i]:info().name
    if name == self.interface_name then
      interface = netifs[i]
      break
    end
  end

  if not interface then
    checkResult:setError('No such interface: ' .. self.interface_name)
  else
    local usage = interface:usage()
    for key, value in pairs(usage) do
      checkResult:addMetric(key, nil, 'gauge', value, units[key])
    end
  end

  -- Get link state
  self:getLinkState(function(linkState)
    checkResult:addMetric('link_state', nil, 'string', linkState, units['link_state'])
    -- Return Result
    self._lastResult = checkResult
    callback(checkResult)
  end)
end

function NetworkCheck:getLinkState(callback)
  local linkState = 'unknown'
  local cfname = '/sys/class/net/' .. self.interface_name .. '/carrier'

  -- Linux
  if os.type() == 'Linux' then
    fs.readFile(cfname, function(err, cstate)
      if not err then
        local tcstate = misc.trim(cstate)
        if tcstate == '1' then
          linkState = 'up'
        elseif tcstate == '0' then
          linkState = 'down'
        end
      end
      callback(linkState)
    end)
  -- Other OSes (for now)
  else
    callback(linkState)
  end
end

local exports = {}
exports.NetworkCheck = NetworkCheck
return exports
