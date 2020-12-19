-- a-lurker, copyright, 19 Dec 2020
-- Example button code searcher. Ver 0.51

--[[
    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    version 3 (GPLv3) as published by the Free Software Foundation;

    In addition to the GPLv3 License, this software is only for private
    or home usage. Commercial utilisation is not authorized.

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    WARNING: doing a scan like this may invoke a factory reset of the device
    being scanned!
    
    Note this code will not work in the Vera or AltUI Lua test windows but
    will work in the openLuup test windows. It's apparently a problem with
    using luup.call_delay() in these test windows.
    

    Example search code:
    In this example we send a Pioneer function introduction code and then
    try all the function codes between 25 and 36 inclusive.

    eg:
    Send intro function code:  Pioneer, 165, -1, 89
    Then send actual function code: Pioneer, 165, -1, 25 <-- 25 to 36
    Then increment function code til ten.

    Pioneer:
    http://www.adrian-kingston.com/IRFormatPioneer.htm
    https://www.pioneerelectronics.com/PUSA/Support/Home-Entertainment-Custom-Install/IR+Codes/A+V+Receivers

    Searchs for less complicated devices only require the second luup.call_action
]]

-- There is a 6 second delay between the IR codes being sent (or IR code pairs in this case).
-- Set these two values to start and end of the function numbers to be scanned.
local m_count    = 25
local m_endCount = 36

function searchForCodes()
    luup.log('Doing: '..tostring(m_count),50)

    -- enter this plugin's id here
    local deviceID = 196
    
    -- and the IR transmitter plugin id - it's a string
    local broadLinkDeviceID = '164'

    local protocol = 'PIONEER'

    -- Send the prefix code used by Pioneer to extend some of its codes.
    -- Only Pioneer appears to use extension codes like this. Other
    -- protcols don't need this step. They just need the next send.
    local fncExt = '86'
    luup.log('Sending Pioneer extension code:', 50)
    luup.call_action('urn:a-lurker-com:serviceId:VirtualProntoRemote1', 'SendIRPCode', {
        Protocol     = protocol,
        Device       = '165',
        Subdevice    = '-1',
        Function     = fncExt,
        Repeats      = '0',
        IRdevice     = broadLinkDeviceID,
        IRserviceIdx = '2'
        }, deviceID)

    -- Send the IR codes, in this example, numbered from 25 to 36
    luup.log('Sending Pioneer exploratory code number: '..tostring(m_count), 50)
    luup.call_action('urn:a-lurker-com:serviceId:VirtualProntoRemote1', 'SendIRPCode', {
        Protocol     = protocol,
        Device       = '165',
        Subdevice    = '-1',
        Function     = tostring(m_count),
        Repeats      = '0',
        IRdevice     = broadLinkDeviceID,
        IRserviceIdx = '2'
        }, deviceID)

    m_count = m_count+1
    if (m_count > m_endCount) then return end

    local INTERVAL_SECS = 6
    luup.call_delay('searchForCodes', INTERVAL_SECS)
end

searchForCodes()

return true
