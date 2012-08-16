local BaseCheck = require('./base').BaseCheck
local CheckResult = require('./base').CheckResult
local Metric = require('./base').Metric
local logging = require('logging')
local timer = require('timer')
local math = require('math')
local async = require('async')
local sctx = require('../sigar').ctx

local CpuCheck = BaseCheck:extend()

local SAMPLE_RATE = 5000 -- Milliseconds of sample on initial run

local SIGAR_METRICS = {
  'user',
  'sys',
  'idle',
  'wait',
  'irq',
  'stolen'
}
local AGGREGATE_METRICS = {
  'user_percent',
  'sys_percent',
  'idle_percent',
  'wait_percent',
  'irq_percent',
  'stolen_percent',
}

local function metricCpuKey(index)
  return 'cpu' .. index
end

local function metricPercentKey(sigarMetric)
  return sigarMetric .. '_percent'
end

local function metricAverageKey(sigarMetric)
  return sigarMetric .. '_average'
end

function CpuCheck:initialize(params)
  BaseCheck.initialize(self, 'agent.cpu', params)
  -- store the previous cpuinfo so we can aggregate percent differences
  self._previousCpuinfo = nil
end

function CpuCheck:_getCpuInfo()
  local cpuinfo = sctx:cpus()
  local results = {}

  for i=1, #cpuinfo do
    local data = cpuinfo[i]:data()

    -- store sigar metrics
    results[i] = {}
    for _, v in pairs(SIGAR_METRICS) do
      results[i][v] = data[v]
    end
  end

  return results
end

function CpuCheck:_aggregateMetrics(cpuinfo, callback)
  local diffcpuinfo = {}
  local percentages = {}
  local metrics = {}
  local total = 0

  -- calculate the delta between two runs
  for i=1, #cpuinfo do
    diffcpuinfo[i] = {}
    for _, v in pairs(SIGAR_METRICS) do
      diffcpuinfo[i][v] = cpuinfo[i][v] - self._previousCpuinfo[i][v]
    end
  end

  -- calculate CPU usage percentages across all cpus
  for i=1, #cpuinfo do
    local total = diffcpuinfo[i]['user'] + diffcpuinfo[i]['sys'] + diffcpuinfo[i]['idle'] +
      diffcpuinfo[i]['wait'] + diffcpuinfo[i]['irq'] + diffcpuinfo[i]['stolen']

    percentages[i] = {}
    percentages[i]['total'] = total
    for _, v in pairs(SIGAR_METRICS) do
      local percent, key
      percent = (diffcpuinfo[i][v] / total) * 100
      key = metricPercentKey(v)
      percentages[i][key] = percent
      cpuinfo[i][key] = percent
    end
  end

  -- average all the cpu state percentages across all cpus
  for _, key in pairs(AGGREGATE_METRICS) do
    total = 0
    for i=1, #cpuinfo do
      total = total + percentages[i][key]
    end
    local average = total / #cpuinfo
    metrics[metricAverageKey(key)] = average
  end

  -- calculate CPU usage percentage averages across all CPUs
  for i=1, #cpuinfo do
    local current_cpu_total = 0
    for _, v in pairs(AGGREGATE_METRICS) do
      if v ~= metricPercentKey('idle') then -- discard idle percentage
        current_cpu_total = current_cpu_total + percentages[i][v]
      end
    end
    total = total + current_cpu_total
    percentages[i]['current_cpu_usage'] = current_cpu_total
  end
  metrics['average_usage'] = total / #cpuinfo

  -- find cpu with minimum and maximum usage usage
  local cpu_max_index = 0
  local cpu_min_index = 0
  local cpu_max_usage = 0
  local cpu_min_usage = 100
  for i=1, #cpuinfo do
    local usage = percentages[i]['current_cpu_usage']
    if math.max(usage, cpu_max_usage) == usage then
      cpu_max_usage = usage
      cpu_max_index = i - 1
    end
    if math.min(usage, cpu_min_usage) == usage then
      cpu_min_usage = usage
      cpu_min_index = i - 1
    end
  end
  metrics['max_cpu_usage'] = cpu_max_usage
  metrics['max_cpu_usage_name'] = metricCpuKey(cpu_max_index)
  metrics['min_cpu_usage'] = cpu_min_usage
  metrics['min_cpu_usage_name'] = metricCpuKey(cpu_min_index)

  -- store run for next time
  self._previousCpuinfo = cpuinfo

  callback(nil, metrics)
end

function CpuCheck:run(callback)
  -- Perform Check
  local checkResult = CheckResult:new(self, {})

  async.waterfall({
    function(callback)
      -- check if this is _not_ our first run
      if self._previousCpuinfo ~= nil then
        callback(nil, self:_getCpuInfo())
        return
      end
      -- this is our first run
      timer.setTimeout(SAMPLE_RATE, function()
        -- store the cpu info, then spawn a timer to wait
        self._previousCpuinfo = self:_getCpuInfo()
        timer.setTimeout(SAMPLE_RATE, function()
          callback(nil, self:_getCpuInfo())
        end)
      end)
    end,
    -- attach cpu average metrics
    function(cpuinfo, callback)
      self:_aggregateMetrics(cpuinfo, function(err, metrics)
        callback(err, cpuinfo, metrics)
      end)
    end,
    -- add metrics to checkResult
    function(cpuinfo, metrics, callback)
      -- attach cpu metrics
      for i=1, #cpuinfo do
        for key, value in pairs(cpuinfo[i]) do
          local index = i - 1
          checkResult:addMetric(key, metricCpuKey(index), nil, value)
        end
      end
      -- attach percentages and averages
      for key, value in pairs(metrics) do
        checkResult:addMetric(key, 'cpu', nil, value)
      end
      callback()
    end
  }, function()
    -- Return Result
    self._lastResult = checkResult
    callback(checkResult)
  end)
end

local exports = {}
exports.CpuCheck = CpuCheck
return exports
