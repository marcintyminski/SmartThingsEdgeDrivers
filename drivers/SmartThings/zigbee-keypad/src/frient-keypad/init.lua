-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"
local log = require "log"

local PowerConfiguration = clusters.PowerConfiguration
local IASACE = clusters.IASACE
local SecuritySystem = capabilities.securitySystem
local IASZone = clusters.IASZone
local tamperAlert = capabilities.tamperAlert

local ArmMode = IASACE.types.ArmMode
local ArmNotification = IASACE.types.ArmNotification
local PanelStatus = IASACE.types.IasacePanelStatus
local AudibleNotification = IASACE.types.IasaceAudibleNotification
local AlarmStatus = IASACE.types.IasaceAlarmStatus

local BATTERY_INIT = battery_defaults.build_linear_voltage_init(4.0, 6.0)

local SECURITY_STATUS_EVENTS = {
  armedAway = SecuritySystem.securitySystemStatus.armedAway,
  armedStay = SecuritySystem.securitySystemStatus.armedStay,
  disarmed = SecuritySystem.securitySystemStatus.disarmed,
}

local ARM_MODE_TO_STATUS = {
  [ArmMode.DISARM] = "disarmed",
  [ArmMode.ARM_DAY_HOME_ZONES_ONLY] = "armedStay",
  [ArmMode.ARM_NIGHT_SLEEP_ZONES_ONLY] = "armedStay",
  [ArmMode.ARM_ALL_ZONES] = "armedAway",
}

local ARM_MODE_TO_NOTIFICATION = {
  [ArmMode.DISARM] = ArmNotification.ALL_ZONES_DISARMED,
  [ArmMode.ARM_DAY_HOME_ZONES_ONLY] = ArmNotification.ONLY_DAY_HOME_ZONES_ARMED,
  [ArmMode.ARM_NIGHT_SLEEP_ZONES_ONLY] = ArmNotification.ONLY_NIGHT_SLEEP_ZONES_ARMED,
  [ArmMode.ARM_ALL_ZONES] = ArmNotification.ALL_ZONES_ARMED,
}

local STATUS_TO_PANEL = {
  armedAway = PanelStatus.ARMED_AWAY,
  armedStay = PanelStatus.ARMED_STAY,
  disarmed = PanelStatus.PANEL_DISARMED_READY_TO_ARM,
}

local function emit_supported(device)
  device:emit_event(SecuritySystem.supportedSecuritySystemStatuses({ "armedAway", "armedStay", "disarmed" }, { visibility = { displayed = false } }))
  device:emit_event(SecuritySystem.supportedSecuritySystemCommands({ "armAway", "armStay", "disarm" }, { visibility = { displayed = false } }))
end

local function emit_status_event(device, status, extra_data)
  local event_factory = SECURITY_STATUS_EVENTS[status] or SecuritySystem.securitySystemStatus.disarmed
  local event = event_factory({ state_change = true })
  if extra_data ~= nil then
    device.log.info(string.format("securitySystemStatus extra data ignored (keys=%s)", table.concat((function()
      local keys = {}
      for k, _ in pairs(extra_data) do
        keys[#keys + 1] = tostring(k)
      end
      return keys
    end)(), ",")))
  end
  device.log.info(string.format("Emitting securitySystemStatus=%s", status))
  device:emit_event(event)
end

local function get_current_status(device)
  return device:get_latest_state("main", SecuritySystem.ID, SecuritySystem.securitySystemStatus.NAME) or "disarmed"
end

local function send_panel_status(device, status)
  local panel_status = STATUS_TO_PANEL[status] or PanelStatus.PANEL_DISARMED_READY_TO_ARM
  device:send(IASACE.client.commands.PanelStatusChanged(
    device,
    panel_status,
    0x00,
    AudibleNotification.MUTE,
    AlarmStatus.NO_ALARM
  ))
end

local function handle_arm_command(driver, device, zb_rx)
  local cmd = zb_rx.body.zcl_body
  local pin = cmd.arm_disarm_code.value
  local pin_len = pin ~= nil and string.len(pin) or 0
  log.info(string.format("IAS ACE Arm received (mode=%s, pin_len=%d)", tostring(cmd.arm_mode.value), pin_len))

  local status = ARM_MODE_TO_STATUS[cmd.arm_mode.value]
  if status == nil then
    log.warn("IAS ACE Arm received with unsupported arm mode")
    return
  end

  local data = { source = "keypad" }
  if pin ~= nil and pin ~= "" then
    data.pin = pin
  end

  emit_status_event(device, status, data)
  device:send(IASACE.client.commands.ArmResponse(
    device,
    ARM_MODE_TO_NOTIFICATION[cmd.arm_mode.value] or ArmNotification.ALL_ZONES_DISARMED
  ))
end

local function handle_get_panel_status(driver, device, zb_rx)
  local status = get_current_status(device)
  device:send(IASACE.client.commands.GetPanelStatusResponse(
    device,
    STATUS_TO_PANEL[status] or PanelStatus.PANEL_DISARMED_READY_TO_ARM,
    0x00,
    AudibleNotification.MUTE,
    AlarmStatus.NO_ALARM
  ))
end

local function handle_arm_away(driver, device, command)
  emit_status_event(device, "armedAway", { source = "app" })
  send_panel_status(device, "armedAway")
end

local function handle_arm_stay(driver, device, command)
  emit_status_event(device, "armedStay", { source = "app" })
  send_panel_status(device, "armedStay")
end

local function handle_disarm(driver, device, command)
  emit_status_event(device, "disarmed", { source = "app" })
  send_panel_status(device, "disarmed")
end

local function refresh(driver, device, command)
  device:send(PowerConfiguration.attributes.BatteryVoltage:read(device))
  send_panel_status(device, get_current_status(device))
end

local function device_added(driver, device)
  emit_supported(device)
  if device:get_latest_state("main", SecuritySystem.ID, SecuritySystem.securitySystemStatus.NAME) == nil then
    emit_status_event(device, "disarmed", { source = "driver" })
  end
end

local function do_configure(self, device)
  device:send(device_management.build_bind_request(device, IASACE.ID, self.environment_info.hub_zigbee_eui))
  device:send(device_management.build_bind_request(device, PowerConfiguration.ID, self.environment_info.hub_zigbee_eui))
  device:send(PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, 30, 21600, 1))
end

local function device_init(driver, device)
  BATTERY_INIT(driver, device)
  emit_supported(device)
end

local function generate_event_from_zone_status(driver, device, zone_status, zigbee_message)
  if zone_status:is_tamper_set() then
    device:emit_event(tamperAlert.tamper.detected())
  else
    device:emit_event(tamperAlert.tamper.clear())
  end
end

local function ias_zone_status_attr_handler(driver, device, zone_status, zb_rx)
  generate_event_from_zone_status(driver, device, zone_status, zb_rx)
end

local function ias_zone_status_change_handler(driver, device, zb_rx)
  local zone_status = zb_rx.body.zcl_body.zone_status
  generate_event_from_zone_status(driver, device, zone_status, zb_rx)
end

local frient_keypad = {
  NAME = "frient Keypad",
  lifecycle_handlers = {
    added = device_added,
    doConfigure = do_configure,
    init = device_init,
  },
  zigbee_handlers = {
    cluster = {
      [IASACE.ID] = {
        [IASACE.server.commands.Arm.ID] = handle_arm_command,
        [IASACE.server.commands.GetPanelStatus.ID] = handle_get_panel_status,
      },
      [IASZone.ID] = {
        [IASZone.client.commands.ZoneStatusChangeNotification.ID] = ias_zone_status_change_handler
      }
    },
    attr = {
      [IASZone.ID] = {
        [IASZone.attributes.ZoneStatus.ID] = ias_zone_status_attr_handler
      },
    }
  },
  capability_handlers = {
    [SecuritySystem.ID] = {
      [SecuritySystem.commands.armAway.NAME] = handle_arm_away,
      [SecuritySystem.commands.armStay.NAME] = handle_arm_stay,
      [SecuritySystem.commands.disarm.NAME] = handle_disarm,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
  can_handle = require("frient-keypad.can_handle"),
}

return frient_keypad
