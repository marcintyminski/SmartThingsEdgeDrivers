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

local device_management = require "st.zigbee.device_management"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local data_types = require "st.zigbee.data_types"
local capabilities = require "st.capabilities"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local PollControl = zcl_clusters.PollControl
local IASZone = zcl_clusters.IASZone
local PowerConfiguration = zcl_clusters.PowerConfiguration
local TemperatureMeasurement = zcl_clusters.TemperatureMeasurement
local battery_defaults = require "st.zigbee.defaults.battery_defaults"

local temperature_measurement_defaults = {
  MIN_TEMP = "MIN_TEMP",
  MAX_TEMP = "MAX_TEMP"
}

local CHECK_IN_INTERVAL = 6480
local LONG_POLL_INTERVAL = 1200
local SHORT_POLL_INTERVAL = 2
local FAST_POLL_TIMEOUT = 40

local generate_event_from_zone_status = function(driver, device, zone_status, zb_rx)
  local event

  if zone_status:is_alarm1_set() or zone_status:is_alarm2_set() then
    event = capabilities.soundSensor.sound.detected()
  elseif not zone_status:is_tamper_set() then
    event = capabilities.soundSensor.sound.not_detected()
  else
    device:send(PowerConfiguration.attributes.BatteryVoltage:read(device))
  end

  if event ~= nil then
    device:emit_event(event)
  end
end

local ias_zone_status_attr_handler = function(driver, device, zone_status, zb_rx)
  generate_event_from_zone_status(driver, device, zone_status, zb_rx)
end

local ias_zone_status_change_handler = function(driver, device, zb_rx)
  generate_event_from_zone_status(driver, device, zb_rx.body.zcl_body.zone_status, zb_rx)
end

local temperature_measurement_min_max_attr_handler = function(minOrMax)
  return function(driver, device, value, zb_rx)
    local raw_temp = value.value
    local celc_temp = raw_temp / 100.0
    local temp_scale = "C"

    device:set_field(string.format("%s", minOrMax), celc_temp)

    local min = device:get_field(temperature_measurement_defaults.MIN_TEMP)
    local max = device:get_field(temperature_measurement_defaults.MAX_TEMP)

    if min ~= nil and max ~= nil then
      if min < max then
        device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, capabilities.temperatureMeasurement.temperatureRange({ value = { minimum = min, maximum = max }, unit = temp_scale }))
        device:set_field(temperature_measurement_defaults.MIN_TEMP, nil)
        device:set_field(temperature_measurement_defaults.MAX_TEMP, nil)
      else
        device.log.warn_with({hub_logs = true}, string.format("Device reported a min temperature %d that is not lower than the reported max temperature %d", min, max))
      end
    end
  end
end

local do_configure = function(self, device)
  device_management.write_ias_cie_address(device, self.environment_info.hub_zigbee_eui)
  device:send(IASZone.server.commands.ZoneEnrollResponse(device, 0x00, 0x00)) -- ZoneEnroll Response should be called first in case of this device.
  device:configure()
  device:send(device_management.build_bind_request(device, PollControl.ID, self.environment_info.hub_zigbee_eui))
  device:send(PollControl.attributes.CheckInInterval:configure_reporting(device, 0, 3600, 0))
  device:refresh()
  device:send(PollControl.server.commands.SetLongPollInterval(device, data_types.Uint32(LONG_POLL_INTERVAL)))
  device:send(PollControl.server.commands.SetShortPollInterval(device, data_types.Uint16(SHORT_POLL_INTERVAL)))
  device:send(PollControl.attributes.FastPollTimeout:write(device, data_types.Uint16(FAST_POLL_TIMEOUT)))
  device:send(PollControl.attributes.CheckInInterval:write(device, data_types.Uint32(CHECK_IN_INTERVAL)))
end

local added_handler = function(self, device)
  device:emit_event(capabilities.soundSensor.sound.not_detected())
  device:send(TemperatureMeasurement.attributes.MinMeasuredValue:read(device))
  device:send(TemperatureMeasurement.attributes.MaxMeasuredValue:read(device))
end

local zigbee_sound_sensor_driver_template = {
  supported_capabilities = {
    capabilities.battery,
    capabilities.soundSensor,
    capabilities.temperatureMeasurement
  },
  zigbee_handlers = {
    attr = {
      [IASZone.ID] = {
        [IASZone.attributes.ZoneStatus.ID] = ias_zone_status_attr_handler
      },
      [TemperatureMeasurement.ID] = {
        [TemperatureMeasurement.attributes.MinMeasuredValue.ID] = temperature_measurement_min_max_attr_handler(temperature_measurement_defaults.MIN_TEMP),
        [TemperatureMeasurement.attributes.MaxMeasuredValue.ID] = temperature_measurement_min_max_attr_handler(temperature_measurement_defaults.MAX_TEMP),
      }
    },
    cluster = {
      [IASZone.ID] = {
        [IASZone.client.commands.ZoneStatusChangeNotification.ID] = ias_zone_status_change_handler
      }
    }
  },
  lifecycle_handlers = {
    added = added_handler,
    doConfigure = do_configure,
    init = battery_defaults.build_linear_voltage_init(2.2, 3.0)
  },
  health_check = false,
}

defaults.register_for_default_handlers(zigbee_sound_sensor_driver_template,
  zigbee_sound_sensor_driver_template.supported_capabilities, {native_capability_attrs_enabled = true})
local zigbee_sound_sensor = ZigbeeDriver("zigbee-sound-sensor", zigbee_sound_sensor_driver_template)
zigbee_sound_sensor:run()
