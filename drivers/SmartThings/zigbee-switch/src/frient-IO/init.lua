-- Copyright 2025 SmartThings
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

local log   = require "log"
local utils = require "st.utils"

-- Zigbee Spec Utils
local constants           = require "st.zigbee.constants"
local messages            = require "st.zigbee.messages"
local zdo_messages        = require "st.zigbee.zdo"
local bind_request        = require "st.zigbee.zdo.bind_request"
local unbind_request      = require "frient-IO.unbind_request"
local cluster_base        = require "st.zigbee.cluster_base"
local data_types          = require "st.zigbee.data_types"
local zcl_global_commands = require "st.zigbee.zcl.global_commands"
local switch_defaults     = require "st.zigbee.defaults.switch_defaults"
local Status              = require "st.zigbee.generated.types.ZclStatus"

local clusters     = require "st.zigbee.zcl.clusters"
local BasicInput   = clusters.BasicInput
local OnOff        = clusters.OnOff
local OnOffControl = OnOff.types.OnOffControl

-- Capabilities
local capabilities = require "st.capabilities"
local Switch       = capabilities.switch

local configurationMap = require "configurations"

local COMPONENTS = {
    INPUT_1  = "input1",
    INPUT_2  = "input2",
    INPUT_3  = "input3",
    INPUT_4  = "input4",
    OUTPUT_1 = "output1",
    OUTPUT_2 = "output2"
}

local ZIGBEE_BRIDGE_FINGERPRINTS = {
    { manufacturer = "frient A/S", model = "IOMZB-110" }
}

local ZIGBEE_ENDPOINTS = {
    INPUT_1  = 0x70,
    INPUT_2  = 0x71,
    INPUT_3  = 0x72,
    INPUT_4  = 0x73,
    OUTPUT_1 = 0x74,
    OUTPUT_2 = 0x75
}

local ZIGBEE_MFG_CODES = {
    Develco = 0x1015
}

local ZIGBEE_MFG_ATTRIBUTES = {
    client = {
        OnWithTimeOff_OnTime = {
            ID = 0x8000,
            data_type = data_types.Uint16
        },
        OnWithTimeOff_OffWaitTime = {
            ID = 0x8001,
            data_type = data_types.Uint16
        }
    },
    server = { IASActivation = {
        ID = 0x8000,
        data_type = data_types.Uint16
    } }
}

local function write_client_manufacturer_specific_attribute(device, cluster_id, attr_id, mfg_specific_code, data_type,
                                                            payload)
    local message = cluster_base.write_manufacturer_specific_attribute(device, cluster_id, attr_id, mfg_specific_code,
        data_type, payload)

    message.body.zcl_header.frame_ctrl:set_direction_client()
    return message
end

local function write_basic_input_polarity_attr(device, ep_id, payload)
    local value = data_types.validate_or_build_type(payload and 1 or 0,
        BasicInput.attributes.Polarity.base_type,
        "payload")
    device:send(cluster_base.write_attribute(device, data_types.ClusterId(BasicInput.ID),
        data_types.AttributeId(BasicInput.attributes.Polarity.ID),
        value):to_endpoint(ep_id))
end

local function build_bind_request(device, src_cluster, src_ep_id, dest_ep_id)
    local addr_header = messages.AddressHeader(constants.HUB.ADDR, constants.HUB.ENDPOINT, device:get_short_address(),
        device.fingerprinted_endpoint_id, constants.ZDO_PROFILE_ID, bind_request.BindRequest.ID)

    local bind_req = bind_request.BindRequest(device.zigbee_eui, src_ep_id,
        src_cluster,
        bind_request.ADDRESS_MODE_64_BIT, device.zigbee_eui, dest_ep_id)
    local message_body = zdo_messages.ZdoMessageBody({
        zdo_body = bind_req
    })
    local bind_cmd = messages.ZigbeeMessageTx({
        address_header = addr_header,
        body = message_body
    })
    return bind_cmd
end

local function build_unbind_request(device, src_cluster, src_ep_id, dest_ep_id)
    local addr_header = messages.AddressHeader(constants.HUB.ADDR, constants.HUB.ENDPOINT, device:get_short_address(),
        device.fingerprinted_endpoint_id, constants.ZDO_PROFILE_ID, unbind_request.UNBIND_REQUEST_CLUSTER_ID)

    local unbind_req = unbind_request.UnbindRequest(device.zigbee_eui, src_ep_id,
        src_cluster,
        unbind_request.ADDRESS_MODE_64_BIT, device.zigbee_eui, dest_ep_id)
    local message_body = zdo_messages.ZdoMessageBody({
        zdo_body = unbind_req
    })
    local bind_cmd = messages.ZigbeeMessageTx({
        address_header = addr_header,
        body = message_body
    })
    return bind_cmd
end

local function component_to_endpoint(device, component_id)
    if component_id == COMPONENTS.INPUT_1 then
        return ZIGBEE_ENDPOINTS.INPUT_1
    elseif component_id == COMPONENTS.INPUT_2 then
        return ZIGBEE_ENDPOINTS.INPUT_2
    elseif component_id == COMPONENTS.INPUT_3 then
        return ZIGBEE_ENDPOINTS.INPUT_3
    elseif component_id == COMPONENTS.INPUT_4 then
        return ZIGBEE_ENDPOINTS.INPUT_4
    elseif component_id == COMPONENTS.OUTPUT_1 then
        return ZIGBEE_ENDPOINTS.OUTPUT_1
    elseif component_id == COMPONENTS.OUTPUT_2 then
        return ZIGBEE_ENDPOINTS.OUTPUT_2
    else
        return device.fingerprinted_endpoint_id
    end
end

local function endpoint_to_component(device, ep)
    local ep_id = type(ep) == "table" and ep.value or ep
    if ep_id == ZIGBEE_ENDPOINTS.INPUT_1 then
        return COMPONENTS.INPUT_1
    elseif ep_id == ZIGBEE_ENDPOINTS.INPUT_2 then
        return COMPONENTS.INPUT_2
    elseif ep_id == ZIGBEE_ENDPOINTS.INPUT_3 then
        return COMPONENTS.INPUT_3
    elseif ep_id == ZIGBEE_ENDPOINTS.INPUT_4 then
        return COMPONENTS.INPUT_4
    elseif ep_id == ZIGBEE_ENDPOINTS.OUTPUT_1 then
        return COMPONENTS.OUTPUT_1
    elseif ep_id == ZIGBEE_ENDPOINTS.OUTPUT_2 then
        return COMPONENTS.OUTPUT_2
    else
        return "main"
    end
end

local function init_handler(self, device)
    device:set_component_to_endpoint_fn(component_to_endpoint)
    device:set_endpoint_to_component_fn(endpoint_to_component)

    -- Output 1
    device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.data_type,
        device.preferences.configOnTime1):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_1))
    device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.data_type,
        device.preferences.configOffWaitTime1):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_1))

    -- Output 2
    device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.data_type,
        device.preferences.configOnTime2 or 0):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_2))
    device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.data_type,
        device.preferences.configOffWaitTime2 or 0):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_2))

    -- Input 1
    write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_1, device.preferences.reversePolarity1)

    device:send(device.preferences.controlOutput11
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_1)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_1))

    device:send(device.preferences.controlOutput21
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_2)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_2))

    device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
        device.preferences.iasActivation1 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_1))

    -- Input 2
    write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_2, device.preferences.reversePolarity2)

    device:send(device.preferences.controlOutput12
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_1)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_1))

    device:send(device.preferences.controlOutput22
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_2)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_2))

    device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
        device.preferences.iasActivation2 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_2))

    -- Input 3
    write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_3, device.preferences.reversePolarity3)

    device:send(device.preferences.controlOutput13
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_1)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_1))

    device:send(device.preferences.controlOutput23
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_2)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_2))

    device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
        device.preferences.iasActivation3 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_3))

    -- Input 4
    write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_4, device.preferences.reversePolarity4)

    device:send(device.preferences.controlOutput14
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_1)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_1))

    device:send(device.preferences.controlOutput24
        and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_2)
        or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_2))

    device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
        ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
        device.preferences.iasActivation4 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_4))
end

local function configure_handler(self, device)
    local configuration = configurationMap.get_device_configuration(device)
    if configuration ~= nil then
        for _, attribute in ipairs(configuration) do
            if attribute.configurable ~= false then
                device:add_configured_attribute(attribute)
            end
            if attribute.monitored ~= false then
                device:add_monitored_attribute(attribute)
            end
        end
    end
    device:configure()
end

local function info_changed_handler(self, device, event, args)
    -- Output 1
    if args.old_st_store.preferences.configOnTime1 ~= device.preferences.configOnTime1 then
        device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.data_type,
            device.preferences.configOnTime1):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    if args.old_st_store.preferences.configOffWaitTime1 ~= device.preferences.configOffWaitTime1 then
        device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.data_type,
            device.preferences.configOffWaitTime1):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    -- Output 2
    if args.old_st_store.preferences.configOnTime2 ~= device.preferences.configOnTime2 then
        device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OnTime.data_type,
            device.preferences.configOnTime2):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    if args.old_st_store.preferences.configOffWaitTime2 ~= device.preferences.configOffWaitTime2 then
        device:send(write_client_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.client.OnWithTimeOff_OffWaitTime.data_type,
            device.preferences.configOffWaitTime2):to_endpoint(ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    -- Input 1
    if args.old_st_store.preferences.reversePolarity1 ~= device.preferences.reversePolarity1 then
        write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_1, device.preferences.reversePolarity1)
    end

    if args.old_st_store.preferences.controlOutput11 ~= device.preferences.controlOutput11 then
        device:send(device.preferences.controlOutput11
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_1)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    if args.old_st_store.preferences.controlOutput21 ~= device.preferences.controlOutput21 then
        device:send(device.preferences.controlOutput21
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_2)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_1, ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    if args.old_st_store.preferences.iasActivation1 ~= device.preferences.iasActivation1 then
        device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
            device.preferences.iasActivation1 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_1))
    end

    -- Input 2
    if args.old_st_store.preferences.reversePolarity2 ~= device.preferences.reversePolarity2 then
        write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_2, device.preferences.reversePolarity2)
    end

    if args.old_st_store.preferences.controlOutput12 ~= device.preferences.controlOutput12 then
        device:send(device.preferences.controlOutput12
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_1)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    if args.old_st_store.preferences.controlOutput22 ~= device.preferences.controlOutput22 then
        device:send(device.preferences.controlOutput22
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_2)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_2, ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    if args.old_st_store.preferences.iasActivation2 ~= device.preferences.iasActivation2 then
        device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
            device.preferences.iasActivation2 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_2))
    end

    -- Input 3
    if args.old_st_store.preferences.reversePolarity3 ~= device.preferences.reversePolarity3 then
        write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_3, device.preferences.reversePolarity3)
    end

    if args.old_st_store.preferences.controlOutput13 ~= device.preferences.controlOutput13 then
        device:send(device.preferences.controlOutput13
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_1)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    if args.old_st_store.preferences.controlOutput23 ~= device.preferences.controlOutput23 then
        device:send(device.preferences.controlOutput23
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_2)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_3, ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    if args.old_st_store.preferences.iasActivation3 ~= device.preferences.iasActivation3 then
        device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
            device.preferences.iasActivation3 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_3))
    end

    -- Input 4
    if args.old_st_store.preferences.reversePolarity4 ~= device.preferences.reversePolarity4 then
        write_basic_input_polarity_attr(device, ZIGBEE_ENDPOINTS.INPUT_4, device.preferences.reversePolarity4)
    end

    if args.old_st_store.preferences.controlOutput14 ~= device.preferences.controlOutput14 then
        device:send(device.preferences.controlOutput14
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_1)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_1))
    end

    if args.old_st_store.preferences.controlOutput24 ~= device.preferences.controlOutput24 then
        device:send(device.preferences.controlOutput24
            and build_bind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_2)
            or build_unbind_request(device, BasicInput.ID, ZIGBEE_ENDPOINTS.INPUT_4, ZIGBEE_ENDPOINTS.OUTPUT_2))
    end

    if args.old_st_store.preferences.iasActivation4 ~= device.preferences.iasActivation4 then
        device:send(cluster_base.write_manufacturer_specific_attribute(device, BasicInput.ID,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.ID, ZIGBEE_MFG_CODES.Develco,
            ZIGBEE_MFG_ATTRIBUTES.server.IASActivation.data_type,
            device.preferences.iasActivation4 == "disabled" and 0xffff or 0x0001):to_endpoint(ZIGBEE_ENDPOINTS.INPUT_4))
    end
end

local function present_value_attr_handler(driver, device, value, zb_message)
    local ep_id = zb_message.address_header.src_endpoint
    device:emit_event_for_endpoint(ep_id, value.value and Switch.switch.on() or Switch.switch.off())
end

local function on_off_default_response_handler(driver, device, zb_rx)
    local status = zb_rx.body.zcl_body.status.value

    if status == Status.SUCCESS then
        local cmd = zb_rx.body.zcl_body.cmd.value
        local event = nil

        if cmd == OnOff.server.commands.On.ID then
            event = Switch.switch.on()
        elseif cmd == OnOff.server.commands.OnWithTimedOff.ID then
            device:send(cluster_base.read_attribute(device, data_types.ClusterId(OnOff.ID),
                data_types.AttributeId(OnOff.attributes.OnOff.ID)):to_endpoint(zb_rx.address_header.src_endpoint.value))
        elseif cmd == OnOff.server.commands.Off.ID then
            event = Switch.switch.off()
        end

        if event ~= nil then
            device:emit_event_for_endpoint(zb_rx.address_header.src_endpoint.value, event)
        end
    end
end

local function switch_on_handler(driver, device, command)
    local num = command.component:match("output(%d)")
    if num then
        --switch_defaults.on(driver, device, command)
        local configOnTime = device.preferences["configOnTime" .. tonumber(num)]
        local configOffWaitTime = device.preferences["configOffWaitTime" .. tonumber(num)]

        if configOnTime == 0 --[[ and configOffWaitTime == 0 ]] then
            switch_defaults.on(driver, device, command)
        else
            device:send_to_component(command.component,
                OnOff.server.commands.OnWithTimedOff(device,
                    OnOffControl(0), configOnTime,
                    configOffWaitTime))
        end
    end
    num = command.component:match("input(%d)")
    if num then
        log.debug("switch_on_handler", utils.stringify_table(command, "command", false))
        local component = device.profile.components[command.component]
        local value = device:get_latest_state(command.component, Switch.ID, Switch.switch.NAME)
        if value == "on" then
            device:emit_component_event(component,
                Switch.switch.on({ state_change = true, visibility = { displayed = false } }))
        elseif value == "off" then
            device:emit_component_event(component,
                Switch.switch.off({ state_change = true, visibility = { displayed = false } }))
        end
    end
end

local function switch_off_handler(driver, device, command)
    local num = command.component:match("output(%d)")
    if num then
        --return switch_defaults.off(driver, device, command)
        local configOnTime = device.preferences["configOnTime" .. tonumber(num)]
        local configOffWaitTime = device.preferences["configOffWaitTime" .. tonumber(num)]

        log.debug("off", configOnTime, configOffWaitTime)
        if configOnTime == 0 --[[  and configOffWaitTime == 0 ]] then
            switch_defaults.off(driver, device, command)
        else
            device:send_to_component(command.component,
                OnOff.server.commands.OnWithTimedOff(device,
                    OnOffControl(0), configOnTime,
                    configOffWaitTime))
        end
    end
    num = command.component:match("input(%d)")
    if num then
        log.debug("switch_on_handler", utils.stringify_table(command, "command", false))
        local component = device.profile.components[command.component]
        local value = device:get_latest_state(command.component, Switch.ID, Switch.switch.NAME)
        if value == "on" then
            device:emit_component_event(component,
                Switch.switch.on({ state_change = true, visibility = { displayed = false } }))
        elseif value == "off" then
            device:emit_component_event(component,
                Switch.switch.off({ state_change = true, visibility = { displayed = false } }))
        end
    end
end

local frient_bridge_handler = {
    NAME = "frient bridge handler",
    zigbee_handlers = {
        global = {
            [OnOff.ID] = {
                [zcl_global_commands.DEFAULT_RESPONSE_ID] = on_off_default_response_handler
            }
        },
        cluster = {},
        attr = {
            [BasicInput.ID] = {
                [BasicInput.attributes.PresentValue.ID] = present_value_attr_handler
            }
        },
        zdo = {}
    },
    capability_handlers = {
        [Switch.ID] = {
            [Switch.commands.on.NAME] = switch_on_handler,
            [Switch.commands.off.NAME] = switch_off_handler
        }
    },
    lifecycle_handlers = {
        init = init_handler,
        doConfigure = configure_handler,
        infoChanged = info_changed_handler
    },
    can_handle = function(opts, driver, device, ...)
        for _, fingerprint in ipairs(ZIGBEE_BRIDGE_FINGERPRINTS) do
            if device:get_manufacturer() == fingerprint.manufacturer and device:get_model() == fingerprint.model then
                local subdriver = require("frient-IO")
                return true, subdriver
            end
        end
    end
}

return frient_bridge_handler
