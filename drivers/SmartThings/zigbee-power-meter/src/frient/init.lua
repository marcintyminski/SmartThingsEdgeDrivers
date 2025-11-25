-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local zigbee_constants = require "st.zigbee.constants"
local capabilities = require "st.capabilities"
local cluster_base = require "st.zigbee.cluster_base"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"

local clusters = require "st.zigbee.zcl.clusters"
local SimpleMetering = clusters.SimpleMetering
local PowerConfiguration = clusters.PowerConfiguration

-- KK: local energyMeter_defaults = require "st.zigbee.defaults.energyMeter_defaults"

local data_types = require "st.zigbee.data_types"

local log = require "log"
local DEVELCO_MANUFACTURER_CODE = 0x1015

local ZIGBEE_POWER_METER_FINGERPRINTS = {
  { model = "ZHEMI101", preferences = true, battery = true, MIN_BAT = 3.4 , MAX_BAT = 4.5 },
  { model = "EMIZB-132", preferences = false, battery = false },
  { model = "EMIZB-141", preferences = true, battery = true, MIN_BAT = 2.3 , MAX_BAT = 3.0 },
  { model = "EMIZB-151", preferences = false, battery = false }
}

local ATTRIBUTES = {
    {
        cluster = SimpleMetering.ID,
        attribute = SimpleMetering.attributes.CurrentSummationDelivered.ID,
        minimum_interval = 5,
        maximum_interval = 3600,
        data_type = data_types.Uint48,
        reportable_change = 1
    },
    {
        cluster = SimpleMetering.ID,
        attribute = SimpleMetering.attributes.InstantaneousDemand.ID,
        minimum_interval = 5,
        maximum_interval = 3600,
        data_type = data_types.Int24,
        reportable_change = 1
    }
}

local is_frient_power_meter = function(opts, driver, device)
    for _, fingerprint in ipairs(ZIGBEE_POWER_METER_FINGERPRINTS) do
        if device:get_model() == fingerprint.model then
            return true
        end
    end

    return false
end

local device_init = function(self, device)
    for _, fingerprint in ipairs(ZIGBEE_POWER_METER_FINGERPRINTS) do
        -- KK: added additional condition
        if device:get_model() == fingerprint.model and fingerprint.battery then
            battery_defaults.build_linear_voltage_init(fingerprint.MIN_BAT, fingerprint.MAX_BAT)(self, device)
        end
    end
    for _, attribute in ipairs(ATTRIBUTES) do
        device:add_configured_attribute(attribute)
        -- KK removed: device:add_monitored_attribute(attribute)
    end
end

local do_refresh = function(self, device)
    device:refresh()
    -- KK: device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
    -- KK: device:send(SimpleMetering.attributes.InstantaneousDemand:read(device))
    if device:supports_capability(device, capabilities.battery) then
        device:send(PowerConfiguration.attributes.BatteryVoltage:read(device))
    end
end

local do_configure = function(self, device)
    device:refresh()
    device:configure()

    if device:supports_capability(device, capabilities.battery) then
        device:send(PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, 30, 21600, 1))
    end
    for _, fingerprint in ipairs(ZIGBEE_POWER_METER_FINGERPRINTS) do
        -- KK: added additional condition
        if device:get_model() == fingerprint.model and fingerprint.preferences then
            local pulseConfiguration = tonumber(device.preferences.pulseConfiguration) or 1000
            -- KK: log.debug("Writing pulse configuration to: " .. pulseConfiguration)
            device:send(cluster_base.write_manufacturer_specific_attribute(device, SimpleMetering.ID, 0x0300, DEVELCO_MANUFACTURER_CODE, data_types.Uint16, pulseConfiguration):to_endpoint(0x02))

            local currentSummation = tonumber(device.preferences.currentSummation) or 0
            -- KK: log.debug("Writing initial current summation to: " .. currentSummation)
            device:send(cluster_base.write_manufacturer_specific_attribute(device, SimpleMetering.ID, 0x0301, DEVELCO_MANUFACTURER_CODE, data_types.Uint48, currentSummation):to_endpoint(0x02))
        end
    end

    -- Divisor and multipler for PowerMeter
    device:send(SimpleMetering.attributes.Divisor:read(device))
    device:send(SimpleMetering.attributes.Multiplier:read(device))

    device.thread:call_with_delay(5, function()
      do_refresh(self, device)
    end)
end

local function info_changed(driver, device, event, args)
    log.trace("Configuring sensor:"..event)
    for name, value in pairs(device.preferences) do
        if (device.preferences[name] ~= nil and args.old_st_store.preferences[name] ~= device.preferences[name]) then
            if (name == "pulseConfiguration") then
                local pulseConfiguration = tonumber(device.preferences.pulseConfiguration)
                -- KK: log.debug("Configuring pulseConfiguration: "..pulseConfiguration)
                device:send(cluster_base.write_manufacturer_specific_attribute(device, SimpleMetering.ID, 0x0300, DEVELCO_MANUFACTURER_CODE, data_types.Uint16, pulseConfiguration):to_endpoint(0x02))
            end
            if (name == "currentSummation") then
                local currentSummation = tonumber(device.preferences.currentSummation)
                -- KK: log.debug("Configuring currentSummation: "..currentSummation)
                device:send(cluster_base.write_manufacturer_specific_attribute(device, SimpleMetering.ID, 0x0301, DEVELCO_MANUFACTURER_CODE, data_types.Uint48, currentSummation):to_endpoint(0x02))
            end
        end
    end
    device.thread:call_with_delay(5, function()
        do_refresh(driver, device)
    end)
end

--[[

local function simple_metering_divisor_handler(driver, device, divisor, zb_rx)
    if not zb_rx.body.zcl_header.frame_ctrl:is_mfg_specific_set() then
        log.debug(divisor.value)
        local raw_value = divisor.value

        if raw_value == 0 then
            log.warn_with({ hub_logs = true }, "Simple metering divisor is 0; using 1 to avoid division by zero")
            raw_value = 1
        end

        device:set_field(zigbee_constants.SIMPLE_METERING_DIVISOR_KEY, raw_value, { persist = true })
    end
end

local function simple_metering_multiplier_handler(driver, device, multiplier, zb_rx)
    if not zb_rx.body.zcl_header.frame_ctrl:is_mfg_specific_set() then
        log.debug(multiplier.value)
        local raw_value = multiplier.value
        device:set_field(zigbee_constants.SIMPLE_METERING_MULTIPLIER_KEY, raw_value, { persist = true })
    end
end]]

local function instantaneous_demand_handler(driver, device, value, zb_rx)
    local raw_value = value.value
    --- demand = demand received * Multipler/Divisor
    local multiplier = device:get_field(zigbee_constants.SIMPLE_METERING_MULTIPLIER_KEY) or 1
    local divisor = device:get_field(zigbee_constants.SIMPLE_METERING_DIVISOR_KEY) or 1
    if raw_value < -8388607 or raw_value >= 8388607 then
        raw_value = 0
    end

    raw_value = raw_value * multiplier / divisor * 1000

    local raw_value_watts = raw_value
    device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.powerMeter.power({ value = raw_value_watts, unit = "W" }, { visibility = { displayed = true }}))
end

local function energy_meter_handler(driver, device, value, zb_rx)
    local raw_energy_register = value.value
    log.trace("raw_value (register): " .. raw_energy_register)

    if raw_energy_register < 0 or raw_energy_register >= 0xFFFFFFFFFFFF then
        raw_energy_register = 0
    end

    local multiplier = device:get_field(zigbee_constants.SIMPLE_METERING_MULTIPLIER_KEY) or 1
    local divisor = device:get_field(zigbee_constants.SIMPLE_METERING_DIVISOR_KEY) or 1

    if divisor == 0 then
        log.warn_with({ hub_logs = true }, "Simple metering divisor is 0; using 1 to avoid division by zero")
        divisor = 1
    end

    log.trace(string.format("multiplier: %s", multiplier))
    log.trace(string.format("divisor: %s", divisor))

    local scaled_kwh = (raw_energy_register * multiplier) / divisor
    log.trace("scaled energy (kWh): " .. scaled_kwh)

    local offset = device:get_field(zigbee_constants.ENERGY_METER_OFFSET) or 0
    log.trace("offset: " .. offset)
    if scaled_kwh < offset then
        offset = 0
        device:set_field(zigbee_constants.ENERGY_METER_OFFSET, offset, { persist = true })
        log.trace("offset reset to 0")
    end

    local net_kwh = scaled_kwh - offset
    log.trace("net energy (kWh): " .. net_kwh)

    local net_wh = net_kwh * 1000 -- convert to Wh for capability expectations
    log.trace("net energy (Wh): " .. net_wh)

    local delta_energy = 0.0
    local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
    if current_power_consumption ~= nil then
        delta_energy = math.max(net_wh - current_power_consumption.energy, 0.0)
    end

    device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.powerConsumptionReport.powerConsumption({ energy = net_wh, deltaEnergy = delta_energy }, { visibility = { displayed = true } }))
    device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.energyMeter.energy({ value = net_wh, unit = "Wh" }, { visibility = { displayed = true } }))
end

local frient_power_meter_handler = {
    NAME = "frient power meter handler",
    lifecycle_handlers = {
        init = device_init,
        doConfigure = do_configure,
        infoChanged = info_changed
    },
    capability_handlers = {
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = do_refresh
        }
    },
    zigbee_handlers = {
        cluster = {
        },
        attr = {
            [SimpleMetering.ID] = {
                [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_meter_handler,
                [SimpleMetering.attributes.InstantaneousDemand.ID] = instantaneous_demand_handler,
                -- that's already handled by the framework
                -- KK -- [SimpleMetering.attributes.Multiplier.ID] = simple_metering_multiplier_handler,
                -- KK -- [SimpleMetering.attributes.Divisor.ID] = simple_metering_divisor_handler
            }
        }
    },
    sub_drivers = {
        require("frient/EMIZB-151")
    },
    can_handle = is_frient_power_meter
}

return frient_power_meter_handler