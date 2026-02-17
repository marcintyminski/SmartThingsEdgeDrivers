-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local function frient_keypad_can_handle(opts, driver, device, ...)
  if device:get_manufacturer() == "frient A/S" and device:get_model() == "KEPZB-110" then
    return true, require("frient-keypad")
  end
  return false
end

return frient_keypad_can_handle
