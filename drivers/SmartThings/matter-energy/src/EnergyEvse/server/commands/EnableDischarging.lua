local data_types = require "st.matter.data_types"
local TLVParser = require "st.matter.TLV.TLVParser"
local amperage_maType = require "st.matter.data_types.Int64"

local EnableDischarging = {}

EnableDischarging.NAME = "EnableDischarging"
EnableDischarging.ID = 0x0003
EnableDischarging.field_defs = {
  {
    name = "discharging_enabled_until",
    field_id = 0,
    optional = false,
    nullable = true,
    data_type = data_types.Uint32,
  },
  {
    name = "maximum_discharge_current",
    field_id = 1,
    optional = false,
    nullable = false,
    data_type = amperage_maType,
  },
}

function EnableDischarging:build_test_command_response(device, endpoint_id, status)
  return self._cluster:build_test_command_response(
    device,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    nil, --tlv
    status
  )
end

function EnableDischarging:init(device, endpoint_id, discharging_enabled_until, maximum_discharge_current)
  local out = {}
  local args = {discharging_enabled_until, maximum_discharge_current}
  if #args > #self.field_defs then
    error(self.NAME .. " received too many arguments")
  end
  for i,v in ipairs(self.field_defs) do
    if v.optional and args[i] == nil then
      out[v.name] = nil
    elseif v.nullable and args[i] == nil then
      out[v.name] = data_types.validate_or_build_type(args[i], data_types.Null, v.name)
      out[v.name].field_id = v.field_id
    elseif not v.optional and args[i] == nil then
      out[v.name] = data_types.validate_or_build_type(v.default, v.data_type, v.name)
      out[v.name].field_id = v.field_id
    else
      out[v.name] = data_types.validate_or_build_type(args[i], v.data_type, v.name)
      out[v.name].field_id = v.field_id
    end
  end
  setmetatable(out, {
    __index = EnableDischarging,
    __tostring = EnableDischarging.pretty_print
  })
  return self._cluster:build_cluster_command(
    device,
    out,
    endpoint_id,
    self._cluster.ID,
    self.ID,
    true
  )
end

function EnableDischarging:set_parent_cluster(cluster)
  self._cluster = cluster
  return self
end

function EnableDischarging:augment_type(base_type_obj)
  local elems = {}
  for _, v in ipairs(base_type_obj.elements) do
    for _, field_def in ipairs(self.field_defs) do
      if field_def.field_id == v.field_id and
         field_def.is_nullable and
         (v.value == nil and v.elements == nil) then
        elems[field_def.name] = data_types.validate_or_build_type(v, data_types.Null, field_def.field_name)
      elseif field_def.field_id == v.field_id and not
        (field_def.is_optional and v.value == nil) then
        elems[field_def.name] = data_types.validate_or_build_type(v, field_def.data_type, field_def.field_name)
      end
    end
  end
  base_type_obj.elements = elems
end

function EnableDischarging:deserialize(tlv_buf)
  return TLVParser.decode_tlv(tlv_buf)
end

setmetatable(EnableDischarging, {__call = EnableDischarging.init})

return EnableDischarging
