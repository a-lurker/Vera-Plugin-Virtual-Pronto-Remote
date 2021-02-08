-- a-lurker, copyright, 19 Dec 2020. Updated 7 Feb 2021.
-- Setup virtual remotes via a JSON file.

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


    This plugin implements a few IR protocols (IRP) based on the info in the IRP site here.
    There's about 130 protocols to look at:  http://www.hifi-remote.com/wiki/index.php/DecodeIR
    The site also explains the IRP notation that can be seen in the occasional comment further below:
        http://www.hifi-remote.com/wiki/index.php/IRP_Notation

    Search for IR codes here:
       http://www.remotecentral.com/cgi-bin/codes/
       http://irdb.tk/find/

    IR protocols implemented:
        DENON      - Denon, Sharp
        JVC        - similar to Mitsubishi
        KASEIKYO   - Lsrge fsmily: Denon, JVC, Panasonic & other Japanese manufacturers
        MITSUBISHI - similar to JVC
        NEC        - Canon, Harman/Kardon, Hitachi, JVC, NEC, Onkyo, Pioneer, Sharp, Toshiba, Yamaha, and many other Japanese manufacturers
        RC5        - Philips and other manufacturers in Europe
        RC6        - Microsoft Media Center MCE, Sky TV, etc
        SAMSUNG    - Samsung
        SIRCS      - Sony12,15,20

    Raw style formats:
        GC100      - Global Caché IR code format
        PRONTO     - yes: you can even send your old pronto codes
        RAW        - string of mark/spaces in microseconds
]]

local PLUGIN_NAME     = 'VirtualProntoRemote'
local PLUGIN_SID      = 'urn:a-lurker-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.52'
local THIS_LUL_DEVICE = nil

local PLUGIN_URL_ID   = 'al_ir_code_info'

local m_testing       = false
local m_mceToggle     = false
local m_json          = nil
local m_remoteList    = nil
local m_IRclk         = nil
local m_basicTimeUnitDivisor = nil

--[[
    JSON file:

    Note that the "Fnc" objects in the json file are extended to contain: CmdBytes & CmdOBC & LogInfo
    together with potentially other variables eg:

      "Mute" : {
         "Fnc" : "0x30",
         "Note" : "Toggle"
      },

    so the above button function would have this info added to it:
      Mute.CmdOBC   = {obcD=x, obcS=y, obcF=z}      -- original button code: Device, Subdevice, Function
      Mute.CmdBytes = {byteD=a, byteS=b, byteF=c}   -- misc arbitary bytes set up and used based on the protocol
      Mute.LogInfo  = a string of log info re: the IR key function

    Also x.Encoding.Repeats is set to "0", if it's not present in the json file
    Also x.Encoding.LSBfirst is set to true, if it's not present in the json file
]]

-- set up the Kaseikyo Kaseikyo
local m_kFamily = {
    ['PANASONIC']    = {m=2,   n=32},    -- tested OK
    ['PANASONIC2']   = {m=2,   n=32},    -- may work; depends on the contents of byte 'X'. Used mainly by projectors??
    ['DENON-K']      = {m=84,  n=50},    -- will probably work
    ['JVC-48']       = {m=3,   n=1},     -- may work
    ['JVC-56']       = {m=3,   n=1},     -- may work; depends on the contents of byte 'X'
    ['KASEIKYO']     = {m=8,   n=8},     -- may work
    ['KASEIKYO56']   = {m=8,   n=8},     -- may work; depends on the contents of byte 'X'
    ['FUJITSU']      = {m=20,  n=99},    -- will not function without further coding of ir code data mapping
    ['FUJITSU-56']   = {m=20,  n=99},    -- will not function without further coding of ir code data mapping
    ['MITSUBISHI-K'] = {m=35,  n=203},   -- will not function without further coding of ir code data mapping
    ['SHARPDVD']     = {m=170, n=90},    -- will not function without further coding of ir code data mapping
    ['TEAC-K']       = {m=67,  n=83}     -- will not function without further coding of ir code data mapping
}

local m_rc6Family = {
    ['MCE']        = true,
    ['RC6']        = true,
    ['RC6-0-16']   = true,
    ['RC6-6-20']   = true,
    ['RC6-6-32']   = true
}

-- Don't change this, it won't do anything. Use the DebugEnabled flag instead
local DEBUG_MODE = true

local function debug(textParm, logLevel)
    if DEBUG_MODE then
        local text = ''
        local theType = type(textParm)
        if (theType == 'string') then
            text = textParm
        else
            text = 'type = '..theType..', value = '..tostring(textParm)
        end
        luup.log(PLUGIN_NAME..' debug: '..text,50)

    elseif (logLevel) then
        local text = ''
        if (type(textParm) == 'string') then text = textParm end
        luup.log(PLUGIN_NAME..' debug: '..text, logLevel)
    end
end

-- If non existent, create the variable. Update
-- the variable, only if it needs to be updated
local function updateVariable(varK, varV, sid, id)
    if (sid == nil) then sid = PLUGIN_SID      end
    if (id  == nil) then  id = THIS_LUL_DEVICE end

    if (varV == nil) then
        if (varK == nil) then
            luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable was supplied with nil values', 1)
        else
            luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable '..tostring(varK)..' was supplied with a nil value', 1)
        end
        return
    end

    local newValue = tostring(varV)
    debug(newValue..' --> '..varK)

    local currentValue = luup.variable_get(sid, varK, id)
    if (((currentValue ~= newValue) or (currentValue == nil)) and (not m_testing)) then
        luup.variable_set(sid, varK, newValue, id)
        -- debug(sid,varK,newValue,id)
    end
end

-- If possible, get a JSON parser. If none available, returns nil. Note that typically UI5 may not have a parser available.
local function loadJsonModule()
    local jsonModules = {
        'rapidjson',            -- how many json libs are there?
        'cjson',                -- openLuup?
        'dkjson',               -- UI7 firmware
        'openLuup.json',        -- https://community.getvera.com/t/pure-lua-json-library-akb-json/185273
        'akb-json',             -- https://community.getvera.com/t/pure-lua-json-library-akb-json/185273
        'json',                 -- OWServer plugin
        'json-dm2',             -- dataMine plugin
        'dropbox_json_parser',  -- dropbox plugin
        'hue_json',             -- hue plugin
        'L_ALTUIjson',          -- AltUI plugin
    }

    local ptr  = nil
    local json = nil
    for n = 1, #jsonModules do
        -- require does not load the module, if it's already loaded
        -- Vera has overloaded require to suit their requirements, so it works differently from openLuup
        -- openLuup:
        --    ok:     returns true or false indicating if the module was loaded successfully or not
        --    result: contains the ptr to the module or an error string showing the path(s) searched for the module
        -- Vera:
        --    ok:     returns true or false indicating the require function executed but require may have or may not have loaded the module
        --    result: contains the ptr to the module or an error string showing the path(s) searched for the module
        --    log:    log reports 'luup_require can't find xyz.json'
        local ok, result = pcall(require, jsonModules[n])
        ptr = package.loaded[jsonModules[n]]
        if (ptr) then
            json = ptr
            debug('Using: '..jsonModules[n])
            break
        end
    end
    if (not json) then debug('No JSON library found',50) return json end
    return json
end

-- Round towards 0 with precision
local function round(num, idp)
    local mult = 10^(idp or 0)
    if (num >= 0) then return math.floor(num * mult + 0.5) / mult
    else return math.ceil(num * mult - 0.5) / mult end
end

-- Bitwise xor
-- https://stackoverflow.com/questions/5977654/how-do-i-use-the-bitwise-operator-xor-in-lua
local function bitXOR(a,b)
    local p,c=1,0
    while a>0 and b>0 do
        local ra,rb=a%2,b%2
        if ra~=rb then c=c+p end
        a,b,p=(a-ra)/2,(b-rb)/2,p*2
    end
    if a<b then a=b end
    while a>0 do
        local ra=a%2
        if ra>0 then c=c+p end
        a,p=(a-ra)/2,p*2
    end
    return c
end

-- Gets the bits and reverses them - ie change endian type. Defaults to
-- a single byte number. You can specify the number of bits to reverse.
-- Returns the bits in reverse order.
local function reverseBits(input, activeBits)
    activeBits = activeBits or 8
    local bit = 2^(activeBits-1)
    local output = 0
    for i=1,activeBits do
        if (input % 2 == 0) then -- bit low
        else -- bit high
            input = input-1
            output = output+bit
        end
         -- shift right
        input = input/2
        bit   = bit/2
    end
    return output
end

-- Get the codes from the json file. If the codes are compressed then decompress them.
-- For test purposes only, we can also load a library containing test vectors.
function loadCodes(vprValidate)
    local remoteList = {}

    local fn          = 'vprRemoteCodes.json'
    local source      = '/etc/cmh-ludl/'..fn
    local destination = '/tmp/'..fn

    -- got the compressed version?
    local jsonFile = io.open(source..'.lzo', 'r')
    if (jsonFile) then
        jsonFile:close()
        os.execute ('pluto-lzo d '..source..'.lzo '..destination)
        source = destination
    end

    local remoteListStr = ''
    if (not vprValidate) then
        local jsonFile = io.open(source, 'r')
        if (jsonFile) then
            remoteListStr = jsonFile:read('*a')
            jsonFile:close()
            debug(source..' found OK.',50)
        else
            debug(source..' not found.',50)
        end
    else
        debug('Have loaded protocol validation information ready for validation process.')
        remoteListStr = vprValidate.protocolTestInfo
    end

    -- this decode is time intensive: recommnedn using cjson, rather than dkjson
    remoteList = m_json.decode(remoteListStr)
    if (not remoteList) then
        debug('JSON decode error: remoteList is nil',50)
        remoteList = {}
    end

    return remoteList
end

-- IRP code validation (Device, Subdevice) in json file, etc
local function validateDeviceInfo(remoteName, srcD, srcS)
    local ok = true
    if ((srcD == nil) or (srcS == nil)) then ok = false debug('json: '..remoteName..': "Device" or "Subdevice" is not a number',50) end
    if ((srcD <  0)   or (srcD > 0xff)) then ok = false debug('json: '..remoteName..': "Device" value is out of range.',50) end
    if ((srcS < -1)   or (srcS > 0xff)) then ok = false debug('json: '..remoteName..': "Subdevice" value is out of range.',50) end
    return ok
end

-- IRP code validation (Function) in json file, etc
local function validateFunctionInfo(remoteName, theFunction, funcMaxSize)
    local ok = true
    local srcF = tonumber(theFunction)
    if (srcF == nil)                        then ok = false debug('json: '..remoteName..': Fnc is not a number',50) end
    if ((srcF < 0) or (srcF > funcMaxSize)) then ok = false debug('json: '..remoteName..': Fnc value is out of range.',50) end
    return ok, srcF
end

-- Validation of json file info, etc
local function validateEndian(remote, remoteName)
    local endian = remote.Encoding.LSBfirst
    local littleEndian = true   -- the data in the json file is written with the least significant bit first
    if (type(endian) == 'boolean') then
        littleEndian = endian
    else
        debug (remoteName..': LSBfirst is not a boolean - defaulting LSBfirst to true',50)
        remote.Encoding.LSBfirst = littleEndian
    end
    return littleEndian
end

-- If the user wants, the Device, Subdevice & Function values can be in reverse
-- order in the JSON file. We can correct the order here ready for use. Some
-- values are not 8 bits long, so they need to be reversed based on the bits
-- they actually occupy.
local function adjustEndianness(littleEndian, srcData, activeBits)
    -- activeBits defaults to 8 in reverseBits() if not supplied
    if (not littleEndian) then srcData = reverseBits(srcData, activeBits) end
    return srcData
end

local function gc100Check(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    for _,btn in pairs(remote.Functions) do
        if (type(btn.Fnc) ~= 'table') then ok = false debug('json: '..remoteName..': "Fnc" is not an array',50) break end

        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {bytes=btn.Fnc}
    end
    return ok
end

local function kaseikyoCheck(remoteName, remote, protocol, srcD, srcS)
    local ok = true

    -- LSB is transmitted first
    -- flag these protocols as being part of the Kaseikyo family
    remote.Encoding.Kaseikyo = true

    -- set up the manufacturer's id codes
    local m = m_kFamily[protocol].m
    local n = m_kFamily[protocol].n

    local src_D_S_Bits = 8
    local src_F_Bits   = 8
    local src_F_max    = 0xff
    if (protocol == 'DENON-K') then  -- Device and Subdevice are only 4 bits
        if (srcD > 0x0f) then debug('json: '..remoteName..': Device value is out of range.',   50) return false end
        if (srcS > 0x0f) then debug('json: '..remoteName..': Subdevice value is out of range.',50) return false end
        src_D_S_Bits = 4
        src_F_Bits   = 12
        src_F_max    = 0xfff
    end

    local srcF,obcD,obcS,obcF
    local littleEndian = validateEndian(remote, remoteName)
    obcD = adjustEndianness(littleEndian, srcD, src_D_S_Bits)
    obcS = adjustEndianness(littleEndian, srcS, src_D_S_Bits)

    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, src_F_max)
        if (not ok) then break end

        obcF = adjustEndianness(littleEndian, srcF, src_F_Bits)

        btn.CmdOBC = {obcD=obcD, obcS=obcS, obcF=obcF}
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {oemIdM=m, oemIdN=n, byteD=obcD, byteS=obcS, byteF=obcF}
    end
    return ok
end

local function prontoCheck(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    for _,btn in pairs(remote.Functions) do
        if (type(btn.Fnc) ~= 'string') then ok = false debug('json: '..remoteName..': "Fnc" is not a string',50) break end

        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {prontoCode=btn.Fnc}
    end
    return ok
end

local function rawCheck(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    for _,btn in pairs(remote.Functions) do
        if (type(btn.Fnc) ~= 'table')  then ok = false debug('json: '..remoteName..': "Fnc" is not an array', 50) break end
        if (tonumber(btn.Freq) == nil) then ok = false debug('json: '..remoteName..': "Freq" is not a number',50) break end

        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {bytes=btn.Fnc, Freq=btn.Freq}
    end
    return ok
end

local function rc5Check(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    local srcF

    -- MSB is transmitted first
    if (srcD > 0x1f) then debug('json: '..remoteName..': Device value is out of range.',50) return false end

    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, 0x3f)
        if (not ok) then break end

        btn.CmdOBC = {obcD=srcD, obcS=srcS, obcF=srcF}   -- srcS should be -1
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {byteD=srcD, byteF=srcF}   -- srcS = -1 = not used
    end
    return ok
end

local function rc6Check(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    local srcF

    if (((protocol == 'RC6-6-32') or (protocol == 'MCE')) and (srcD > 0x7f)) then debug('json: '..remoteName..': Device value is out of range.',50) return false end
    if ((protocol == 'RC6-6-20') and (srcS > 0x0f)) then debug('json: '..remoteName..': Subdevice value is out of range.',50) return false end

    -- MSB is transmitted first
    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, 0xff)
        if (not ok) then break end

        btn.CmdOBC = {obcD=srcD, obcS=srcS, obcF=srcF}   -- srcS is typically: -1, 12 or 15
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {byteD=srcD, byteS=srcS, byteF=srcF}
    end
    return ok
end

local function rcaCheck(remoteName, remote, protocol, srcD, srcS)
    local ok = true
    local srcF

    -- MSB is transmitted first
    if (srcD > 0x0f) then debug('json: '..remoteName..': Device value is out of range.',50) return false end

    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, 0xff)
        if (not ok) then break end

        btn.CmdOBC = {obcD=srcD, obcS=srcS, obcF=srcF}   -- srcS should be -1
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {byteD=srcD, byteF=srcF}
    end
    return ok
end

--[[
        SONY12, SONY15, SONY20
        12-bit version, 7 function bits, 5 device bits
        15-bit version, 7 function bits, 8 device bits
        20-bit version, 7 function bits, 5 device bits, 8 device extension bits

                                         Device    address ext function
                                             5/8             8        7
                                           srcD         srcS    srcF
        TV  power on: Protocol Sony12, device  1, subdevice -1,  OBC 46
        TV  Power on: Protocol Sony15, device 84, subdevice -1,  OBC 46
        DVD power on: Protocol Sony20, device 26, subdevice 73,  OBC 46
]]
local function sonyCheck(remoteName, remote, protocol, srcD, srcS)
    local ok = true

    -- LSB is transmitted first
    local littleEndian = validateEndian(remote, remoteName)

    local src_DLen = 5
    if (protocol == 'SONY15') then
        src_DLen = 8
    else
        if (srcD > 0x1f) then debug('json: '..remoteName..': Device value is out of range.',50) return false end
    end

    local srcF,obcD,obcS,obcF,byteE
    obcD = adjustEndianness(littleEndian, srcD, src_DLen)

    -- if "Subdevice" is NOT minus one, then this becomes the extension information
    local byteE = 0
    if (srcS == -1) then
        obcS   = srcS
        byteE = 0x00
    else
        obcS = adjustEndianness(littleEndian, srcS)
        byteE = obcS
    end

    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, 0xff)
        if (not ok) then break end

        obcF = adjustEndianness(littleEndian, srcF, 7)

        btn.CmdOBC = {obcD=obcD, obcS=obcS, obcF=obcF}
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {byteF=obcF, byteD=obcD, byteE=byteE}
    end
    return ok
end

local function necVariantsCheck(remoteName, remote, protocol, srcD, srcS)
    -- default: DENON, NEC2, NECx2, (also NEC1, NECx1 with no long press), PIONEER, SHARP - also Mitsubishi & Sharp
    local ok = true

    -- LSB is transmitted first
    local srcF,obcD,obcS,obcF
    local littleEndian = validateEndian(remote, remoteName)

    if ((protocol == 'DENON') or (protocol == 'SHARP')) then
        if (srcD > 0x1f) then debug('json: '..remoteName..': Device value is out of range.',50) return false end
        obcD = adjustEndianness(littleEndian, srcD, 5)
    else
        obcD = adjustEndianness(littleEndian, srcD)
    end

    -- if "Subdevice" is minus one, then this just flags that "Subdevice" is not
    -- used and should be set to the complement of "Device" in the sent code.
    local byteS = 0
    if (srcS == -1) then
        obcS  = srcS
        byteS = 0xff-srcD
    else
        obcS = adjustEndianness(littleEndian, srcS)
        byteS = obcS
    end

    for _,btn in pairs(remote.Functions) do
        ok, srcF = validateFunctionInfo(remoteName, btn.Fnc, 0xff)
        if (not ok) then break end

        obcF = adjustEndianness(littleEndian, srcF)

        btn.CmdOBC = {obcD=obcD, obcS=obcS, obcF=obcF}
        -- this is the info used to make the Pronto Codes
        btn.CmdBytes = {byteD=obcD, byteS=byteS, byteF=obcF}
    end
    return ok
end

-- Check the values in a single remote are OK and manipulate the data a little further, to suit the associated protocol.
local function validateAndMassageCode(remoteName, remote)
    local ok = true
    if (type(remoteName)               ~= 'string') then debug('json: remote name is not a string',50) return false end
    -- test purposes only
    -- print('Checking: '..remoteName)
    if (type(remote.Model)             ~= 'string') then debug('json: '..remoteName..': Model is not a string',50)    return false end
    if (type(remote.Encoding)          ~= 'table' ) then debug('json: '..remoteName..': Encoding is not a table',50)  return false end
    if (type(remote.Encoding.Protocol) ~= 'string') then debug('json: '..remoteName..': Protocol is not a string',50) return false end
    local protocol = remote.Encoding.Protocol:upper()

    local repeats = tonumber(remote.Encoding.Repeats)

    if ((repeats == nil) or (repeats < 0) or (repeats > 5)) then
        remote.Encoding.Repeats = "0"
    end

    local srcD = tonumber(remote.Encoding.Device)
    local srcS = tonumber(remote.Encoding.Subdevice)
    if (not((protocol == 'GC100') or (protocol == 'PRONTO') or (protocol == 'RAW'))) then
        ok = validateDeviceInfo(remoteName, srcD, srcS)
        if (not ok) then return ok end
    end

    local case = protocol
    -- test purposes only
    -- print('Validating: '..remoteName..': '..case)
    if (m_kFamily  [protocol]) then case = 'KFAMILY'   end
    if (m_rc6Family[protocol]) then case = 'RC6FAMILY' end

    -- Set up a jump table for each protocol in the routines shown above
    local checkActions = {
        ['DENON']      = necVariantsCheck,
        ['GC100']      = gc100Check,
        ['JVC']        = necVariantsCheck,
        ['KFAMILY']    = kaseikyoCheck,   -- there are more IRP protocols contained in the Kaseikyo family. Refer to m_kFamily.
        ['MITSUBISHI'] = necVariantsCheck,
        ['PRONTO']     = prontoCheck,
        ['RAW']        = rawCheck,
        ["RC5"]        = rc5Check,
        ['RC6FAMILY']  = rc6Check,
        ['RCA']        = rcaCheck,
        ['SHARP']      = necVariantsCheck,
        ['SONY12']     = sonyCheck,
        ['SONY15']     = sonyCheck,
        ['SONY20']     = sonyCheck
    }

    if (checkActions[case]) then -- execute the function that does the work
        ok = checkActions[case](remoteName, remote, protocol, srcD, srcS)
    else -- default: NEC, LG, PIONEER, SHARP, SAMSUNG, etc
        ok = necVariantsCheck(remoteName, remote, protocol, srcD, srcS)
    end
    return ok
end

-- Check the json file values are OK and manipulate the data a little further, to suit the associated protocol.
local function validateAndMassageCodes(remoteList)
    local ok = true
    for remoteName,remote in pairs(remoteList) do
        ok = validateAndMassageCode(remoteName,remote)
        if (not ok) then break end
    end
    return ok
end

-- Work out the true IR clock rate and the integer divisor to use.
local function setClockRate(IRclkFrequency, basicTimeUnitDivisor)
    if (type(IRclkFrequency) ~= 'number') then
        debug('IR clock frequency is not a number - using 38 kHz')
        IRclkFrequency = 38000
    end

    if (basicTimeUnitDivisor == nil) then
        debug('Basic TimeUnit Divisor is nil - using 21')
        basicTimeUnitDivisor = 21
    end

    local _,frac = math.modf(basicTimeUnitDivisor)
    if ((basicTimeUnitDivisor == nil) or (frac ~= 0)) then
        debug('Basic TimeUnit Divisor is not an integer - 21')
        basicTimeUnitDivisor = 21
    end

    -- The Pronto apparently used a Motorola DragonBall MC68328PV16VA
    -- The calculations are the same as or similar to these (but not proven definitively):
    -- An inexpensive 32,768 Hz crystal is frequency multiplied by an onboard PLL with the default multiplier of 2024:
    -- 32,768 * 2024 = 66,322,432 Hz
    -- This is divided internally to make SYSCLK:
    -- 66,322,432 / 4 = 16,580,608 Hz
    -- The smallest prescaler divider for the PWM clock is 4:
    -- 16,580,608 / 4 = 4,145,152 Hz
    -- 1/4,145,152 = 0.241246 usec period
    -- This same constant is used here: http://www.remotecentral.com/features/irdisp2.htm
    -- So:  1e6 / 0.241246 = 4,145,146 Hz, which is virtually identical (within 6 Hz) to what has been calculated above.
    local PRONTO_CLK = 4145152.0 -- Hz

    -- The CPU hardware divides by integers, so we find the nearest divisor
    -- that can most accurately produce the IR frequency requested. Example:
    -- If 38,000 kHz is requested, the nearest integer divisor becomes 109
    -- As:  4145146.0 / 109 = 38,028.8623853 kHz
    -- 109 dec = 6D hex and this hex division value is seen in (for example) the NEC codes
    local prontoDivisor = round(PRONTO_CLK/IRclkFrequency)

    -- set the true frequency in the global variable
    m_IRclk = PRONTO_CLK/prontoDivisor
    m_basicTimeUnitDivisor = basicTimeUnitDivisor
    local basicTimeUnit = (m_basicTimeUnitDivisor * 1e3) / m_IRclk

    -- test purposes only
    if (m_testing) then
        -- print(string.format('Target Hz: %.0f, actual Hz: %.3f, freq ratio: %.3f, divisor: %i, basic time unit msec: %.3f, basic time unit divisor: %i', IRclkFrequency, m_IRclk, (m_IRclk/IRclkFrequency), prontoDivisor, basicTimeUnit, m_basicTimeUnitDivisor))
    end

    return string.format('%04X',prontoDivisor)
end

-- Transform each data bit to a bi-phase space/pulse or pulse/space pair.
local function biphase(manchesterTab, binTab, activeBits, input, logicOneIsOneZero)
    -- start as RC5
    local high = '01'
    local low  = '10'
    if (logicOneIsOneZero) then -- RC6 or Motorola
        high = '10'
        low  = '01'
    end

    local bitStr = ''
    local bit = 2^(activeBits-1)
    local idx = #manchesterTab
    for i=1,activeBits do
        idx = idx+1
        if (input >= bit) then
            bitStr = bitStr..'1'
            manchesterTab[idx] = high
            input = input-bit
        else
            bitStr = bitStr..'0'
            manchesterTab[idx] = low
        end
        bit = bit/2
    end
    binTab[#binTab+1] = bitStr
end

-- Make pronto code pulse space pairs from the Manchester string
local function convertManchesterToPronto(irCodeTab, manchesterStr, weirdBiphaseForRC6)
    local cyclesOneUnit     = m_basicTimeUnitDivisor
    local cyclesTwoUnits    = m_basicTimeUnitDivisor * 2
    local cyclesThreeUnits  = m_basicTimeUnitDivisor * 3

    local cyclesOneUnitH    = string.format('%04X',cyclesOneUnit)
    local cyclesTwoUnitsH   = string.format('%04X',cyclesTwoUnits)
    local cyclesThreeUnitsH = string.format('%04X',cyclesThreeUnits)

    local totalCycles = 0

    -- The RC5 code always starts with '01...' and RC6/Motorola with '10...' and pronto with a high
    -- So for RC5 we need to skip the first zero as pronto assumes the first is a high not a low
    local i=1
    if (manchesterStr:sub(i,i) == '0') then
        i = 2
        totalCycles = cyclesOneUnit
    end

    local cyclesLogicChangesH = cyclesTwoUnitsH
    local cyclesLogicChanges  = cyclesTwoUnits
    local cyclesLogicSameH    = cyclesOneUnitH
    local cyclesLogicSame     = cyclesOneUnit
    repeat
        if (weirdBiphaseForRC6) then
            if (i == 8) then -- value will either be one or three units
                cyclesLogicChangesH = cyclesThreeUnitsH
                cyclesLogicChanges  = cyclesThreeUnits
            elseif (i == 9) then -- if 9 is not skipped it will always be two units
                cyclesLogicSameH    = cyclesTwoUnitsH
                cyclesLogicSame     = cyclesTwoUnits
            elseif (i == 10) then -- value will either be three or two units
                cyclesLogicChangesH = cyclesThreeUnitsH
                cyclesLogicChanges  = cyclesThreeUnits
            elseif ((i == 11) or (i == 12)) then -- back to status quo (need 12 as we may have skipped 11)
                cyclesLogicChangesH = cyclesTwoUnitsH
                cyclesLogicChanges  = cyclesTwoUnits
                cyclesLogicSameH    = cyclesOneUnitH
                cyclesLogicSame     = cyclesOneUnit
            end
        end

        -- test if biphase section is '00' (ie a change from logic high to low) or '11'  (ie a change from logic low to high)
        if (manchesterStr:sub(i,i) == manchesterStr:sub(i+1,i+1)) then
            -- need a double length mark or space
            irCodeTab[#irCodeTab+1] = cyclesLogicChangesH
            totalCycles = totalCycles + cyclesLogicChanges
            i = i+2   -- biphase bits merge; do skip
        else    -- '...01010101...' (all logic lows) or '...10101010...'  (all logic highs)
            -- need a single length mark or space
            irCodeTab[#irCodeTab+1] = cyclesLogicSameH
            totalCycles = totalCycles + cyclesLogicSame
            i = i+1
        end
    until (i >= manchesterStr:len())

    if (#irCodeTab % 2 == 0) then -- even length. last biphase bit is a pronto low
        irCodeTab[#irCodeTab+1] = cyclesOneUnitH  -- insert a high to finish off with the lead out
        totalCycles = totalCycles + cyclesOneUnit
    end

    return totalCycles
end

-- Make a single burst. Typically used for the lead in by most protcols.
local function makeBurst(irCodeTab, unitMark, unitSpace)
    local cyclesMark  = unitMark  * m_basicTimeUnitDivisor
    local cyclesSpace = unitSpace * m_basicTimeUnitDivisor

    local cyclesMarkH  = string.format('%04X',cyclesMark)
    local cyclesSpaceH = string.format('%04X',cyclesSpace)

    irCodeTab[#irCodeTab+1] = cyclesMarkH
    irCodeTab[#irCodeTab+1] = cyclesSpaceH

    return cyclesMark + cyclesSpace
end

-- Precalculate the burst information: pronto hex and cycle counts
local function setTimingValues(burstTiming,t1,t2,t3,t4)
    burstTiming[1] = string.format('%04X',t1 * m_basicTimeUnitDivisor)
    burstTiming[2] = string.format('%04X',t2 * m_basicTimeUnitDivisor)
    burstTiming[3] = string.format('%04X',t3 * m_basicTimeUnitDivisor)
    burstTiming[4] = string.format('%04X',t4 * m_basicTimeUnitDivisor)

    burstTiming[5] = (t1 * m_basicTimeUnitDivisor) + (t2 * m_basicTimeUnitDivisor)
    burstTiming[6] = (t3 * m_basicTimeUnitDivisor) + (t4 * m_basicTimeUnitDivisor)
end

-- Using a form of pulse distance/width modulation.
-- MSB is transmitted first: not as common as LSB first
-- Examples:
--         Low  High
-- NEC:   <1,-1|1,-3>
-- DENON: <1,-3|1,-7>
local function makePDMBursts_MSB(irCodeTab, binTab, activeBits, input, burstTiming)
    local cyclesLowMarkH   = burstTiming[1]
    local cyclesLowSpaceH  = burstTiming[2]
    local cyclesHighMarkH  = burstTiming[3]
    local cyclesHighSpaceH = burstTiming[4]

    local cyclesLow  = burstTiming[5]
    local cyclesHigh = burstTiming[6]
    local totalCycles = 0
    local bitStr = ''
    local bit = 2^(activeBits-1)
    local idx = #irCodeTab

    -- msb first
    for i=1,activeBits do
        idx = idx+1
        if (input < bit) then -- bit is low
            bitStr = bitStr..'0'

            irCodeTab[idx] = cyclesLowMarkH
            idx = idx+1
            irCodeTab[idx] = cyclesLowSpaceH
            totalCycles = totalCycles + cyclesLow

        else -- bit is high
            bitStr = bitStr..'1'
            irCodeTab[idx] = cyclesHighMarkH
            idx = idx+1

            irCodeTab[idx] = cyclesHighSpaceH
            totalCycles = totalCycles + cyclesHigh

            input = input-bit
        end
        bit = bit/2
    end
    -- used for logging binary info to the web page
    binTab[#binTab+1] = bitStr
    -- used to calculate space information for fixed frame length protocols eg NEC
    return totalCycles
end

-- Using a form of pulse distance/width modulation.
-- LSB is transmitted first: most likely scenario
-- Examples:
--         Low  High
-- NEC:   <1,-1|1,-3>
-- DENON: <1,-3|1,-7>
local function makePDMBursts_LSB(irCodeTab, binTab, activeBits, input, burstTiming)
    local cyclesLowMarkH   = burstTiming[1]
    local cyclesLowSpaceH  = burstTiming[2]
    local cyclesHighMarkH  = burstTiming[3]
    local cyclesHighSpaceH = burstTiming[4]

    local cyclesLow  = burstTiming[5]
    local cyclesHigh = burstTiming[6]
    local totalCycles = 0
    local bitStr = ''
    local bit = 2^(activeBits-1)
    local idx = #irCodeTab

    -- lsb first
    for i=1,activeBits do
        idx = idx+1
        if (input % 2 == 0) then -- bit low
            bitStr = bitStr..'0'

            irCodeTab[idx] = cyclesLowMarkH
            idx = idx+1
            irCodeTab[idx] = cyclesLowSpaceH
            totalCycles = totalCycles + cyclesLow
        else -- bit high
            bitStr = bitStr..'1'
            irCodeTab[idx] = cyclesHighMarkH
            idx = idx+1

            irCodeTab[idx] = cyclesHighSpaceH
            totalCycles = totalCycles + cyclesHigh

            input = input-1
        end
        bit   = bit/2
        input = input/2
    end
    -- used for logging binary info to the web page
    binTab[#binTab+1] = bitStr
    -- used to calculate space information for fixed frame length protocols eg NEC
    return totalCycles
end

-- GC100: The first three values are: clock rate, repeat & offset. Next is a string of
-- integers in basic time units. The first is a pulse, the second a space, etc .....  It
-- would typically contain: lead in, the data and lead out to make up the total frame length.
-- GC100 is basically a pronto code expressed in decimal, instead of hex.
-- See:
--    Global Caché: GC-100 API Specification - page 11
--    www.globalcache.com/files/docs/API-iTach.pdf
local function gc100(irCodeTab, dummy, code)
    -- set the frequency used for the GC100 protocol
    local clkRate = setClockRate(code.bytes[1], 1) -- where 1 is a dummy value

    -- skip repeat & offset at code.bytes[2], code.bytes[3]
    local idx = 1
    for i=4, #code.bytes do
        irCodeTab[idx] = string.format('%04X',code.bytes[i])
        idx = idx+1
    end

    return clkRate
end

--[[
    Kaseikyo family:
    Example - PANASONIC: {37k,432}<1,-1|1,-3>(8,-4,2:8,32:8,D:8,S:8,F:8,(D^S^F):8,1,-173)+

    0_______   1_______   2______    3_______   4_______   5
    01234567   01234567   01234567   01234567   01234567   01234567
    01000000   00000100   Dev____    Sub Dev    Fun____    XOR(bytes 2,3,4)

    PANASONIC:  {37k,432}<1,-1|1,-3>(8,-4,  2:8,32:8, D:8,     S:8, F:8,  (D^S^F):8
    DENON-K:    {37k,432}<1,-1,1,-3>(8,-4, 84:8,50:8, 0:4,D:4, S:4, F:12,((D*16)^S^(F*16)^(F:8:4)):8,1,-173)+

    DENON-K: note that it's not overly clear how DENON-K is really laid out. But here we assume the following:
    Device is aka "Genre 1", Subdevice is aka "Genre 2".
    The 12 bits of F are divided into 10 bits of "Data" and the top two bits as "ID".
    So: 4 'Genre 1' bits + 4 'Genre 2' bits + 10 'command' bits + 2 'id' bits + 8 'parity'

    Some codes to try:   http://www.remotecentral.com/cgi-bin/mboard/rc-custom/thread.cgi?22355
    And http://files.remotecentral.com/view/96-264-1/denon_pronto_hex_generator.html

]]
local function kaseikyo(irCodeTab, binTab, code, protocol)
    local clkRate = 0
    if (protocol == 'SHARPDVD') then
        clkRate = setClockRate(38000, 15)
    else
        clkRate = setClockRate(36700, 16)
    end

    local fujitsuProtocols = ((protocol == 'FUJITSU') or (protocol == 'FUJITSU-56'))

    makeBurst(irCodeTab, 8, 4)

    local burstTiming = {}
    setTimingValues(burstTiming, 1, 1, 1, 3)

    -- do bytes 0 & 1 that contain the manufacturer info
    makePDMBursts_LSB(irCodeTab, binTab, 8, code.oemIdM, burstTiming)   -- OEM ID M
    makePDMBursts_LSB(irCodeTab, binTab, 8, code.oemIdN, burstTiming)   -- OEM ID N

    local byte2, byte3, byte4, bytex = code.byteD, code.byteS, code.byteF, 0x00

    if (protocol == 'DENON-K') then  -- D and S are only 4 bits and F is 12 bits
        -- data needs to be shoved around to get it right:
        -- [d3,d2,d1,d0,0,0,0,0], [f3,f2,f1,f0,s3,s2,s1,s0], [f11,f10,f9,f8,f7,f6,f5,f4]

        -- when sent the above becomes:
        -- [0,0,0,0,d0,d1,d2,d3], [s0,s1,s2,s3,f0,f1,f2,f3], [f4,f5,f6,f7,f8,f9,f10,f11]

        byte2 = code.byteD * 16                     -- shift left 4 bits
        local int, frac = math.modf(code.byteF/16)  -- split F into 8:4 bits
        byte3 = (frac * 16 * 16) + code.byteS       -- restore F lsb 4 bits and shift it left 4 bits; add in S
        byte4 = int                                  -- most significant 8 bits of F

        makePDMBursts_LSB(irCodeTab, binTab,  4,        0x0, burstTiming)
        makePDMBursts_LSB(irCodeTab, binTab,  4, code.byteD, burstTiming)
        makePDMBursts_LSB(irCodeTab, binTab,  4, code.byteS, burstTiming)
        makePDMBursts_LSB(irCodeTab, binTab, 12, code.byteF, burstTiming)
    else
        if (fujitsuProtocols) then
            -- have an extra byte here, whose contents have not been coded so far! Assume 0x00
            makePDMBursts_LSB(irCodeTab, binTab, 8, 0x00, burstTiming)
        end

        makePDMBursts_LSB(irCodeTab, binTab, 8, byte2, burstTiming)
        makePDMBursts_LSB(irCodeTab, binTab, 8, byte3, burstTiming)

        -- have we got the extra 'X' byte?
        if ((protocol == 'PANASONIC2') or (protocol == 'JVC-56') or (protocol == 'FUJITSU-56') or (protocol == 'KASEIKYO56')) then
            -- has an extra byte 'X' here, whose contents have not been coded so far
            makePDMBursts_LSB(irCodeTab, binTab, 8, bytex, burstTiming)
        end

        makePDMBursts_LSB(irCodeTab, binTab, 8, byte4, burstTiming)
    end

    if (fujitsuProtocols) then
        -- Fujitsu doesn't use a checksum. Just make the final burst.
        makeBurst(irCodeTab, 1, 110)
    else
        -- the checksum is just the xor of bytes 2,3 & 4
        local checksum = bitXOR(bitXOR(bitXOR(byte2,byte3),byte4),bytex)
        makePDMBursts_LSB(irCodeTab, binTab, 8, checksum, burstTiming)   -- xor of bytes 2,3,4

        makeBurst(irCodeTab, 1, 173)
    end

    return clkRate
end

--[[
    DENON:  {38k,264}<1,-3|1,-7>(D:5,F:8,0:2,1,-165,D:5,~F:8,3:2,1,-165)+
    SHARP:  {38k,264}<1,-3|1,-7>(D:5,F:8,1:2,1,-165,D:5,~F:8,2:2,1,-165)+
       1 =  0x0a =   1*10/38 = 0.263
       3 =  0x1e =   3*10/38 = 0.79
       7 =  0x46 =   7*10/38 = 1.842
     165 = 0x672 = 165*10/38 = 43.42
]]
local function denonSharp(irCodeTab, binTab, code, protocol)
    local clkRate = setClockRate(38000,10)

    local byteFC = 0xff-code.byteF

    -- make the 1st lot of the two extension bits - they are the inverse of each other: see further below
    local twoBits = 0x00   -- DENON
    if (protocol == 'SHARP') then twoBits = 0x01 end  -- note: these bits are reversed when sent, ie they become 0x02

    -- make the the 2nd lot of the two extension bits - they are the inverse of the 1st lot: see above
    local twoBitsInv = 0x03 - twoBits

    local burstTiming = {}
    setTimingValues(burstTiming, 1, 3, 1, 7)

    makePDMBursts_LSB(irCodeTab, binTab, 5, code.byteD,  burstTiming)   -- device
    makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteF,  burstTiming)   -- function
    makePDMBursts_LSB(irCodeTab, binTab, 2, twoBits,     burstTiming)   -- 2 extension bits

    -- Both DENON & SHARP:  0.263 = 1*10/38000,  43.42 = 165*10/38000
    makeBurst(irCodeTab, 1, 165)

    makePDMBursts_LSB(irCodeTab, binTab, 5, code.byteD,  burstTiming)   -- device
    makePDMBursts_LSB(irCodeTab, binTab, 8,     byteFC,  burstTiming)   -- function complement
    makePDMBursts_LSB(irCodeTab, binTab, 2, twoBitsInv,  burstTiming)   -- 2 extension bits complemented

    makeBurst(irCodeTab, 1, 165)

    return clkRate
end

-- Mitsubishi: IRP notation: {32.6k,300}<1,-3|1,-7>       (D:8,F:8,1,-80)+
-- JVC:        IRP notation: {38k,  525}<1,-1|1,-3>(16,-8,(D:8,F:8,1,-45)+)
local function mitsubishiJVC(irCodeTab, binTab, code, protocol)
    local clkRate = 0
    local burstTiming = {}
    if (protocol == 'MITSUBISHI') then
        clkRate = setClockRate(32600,10)

        local burstTiming = {}
        setTimingValues(burstTiming, 1, 3, 1, 7)

        makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteD,  burstTiming)   -- device
        makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteF,  burstTiming)   -- function

        makeBurst(irCodeTab, 1, 80)
    else   -- JVC
        clkRate = setClockRate(38000,20)

        -- Note: this burst is only sent first time round.
        -- The any repeats must leave it out thereafter.
        -- See the repeat handling in convertCodeToPronto()
        makeBurst(irCodeTab, 16, 8)

        local burstTiming = {}
        setTimingValues(burstTiming, 1, 1, 1, 3)

        makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteD,  burstTiming)   -- device
        makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteF,  burstTiming)   -- function

        makeBurst(irCodeTab, 1, 45)
    end
    return clkRate
end

--[[
    NEC2:    {38.0k,564}<1,-1|1,-3>(16,-8,D:8,S:8,F:8,~F:8,1,^108m)+   (LG)
    NECx2:   {38.0k,564}<1,-1|1,-3>( 8,-8,D:8,S:8,F:8,~F:8,1,^108m)+   (SAMSUNG)
    PIONEER: {40  k,564}<1,-1|1,-3>(16,-8,D:8,S:8,F:8,~F:8,1,^108m)+

    "Protocol NECx2, device 7, subdevice 7, OBC 152". It's up to you to know that you have to:
    bit-reverse the device number '07' to get 'E0'
    bit-reverse the subdevice number (also '07') to get 'E0'
    convert 152 to hexadecimal and reverse the bits to get '19'
    calculate the last two digits as ( 0xFF - the bit-reversed OBC ), 0xFF - 0x19 = 0xE6, giving the final 8 bits 'E6'

    http://www.sbprojects.net/knowledge/ir/nec.php

    NEC code timing characteristics:
    LSB is transmitted first
    Frame length is supposedly 108 mSec (sometimes spec'ed as 100 or 110 msec)
    Lead in:  9ms mark then 4.5ms space (Samsung uses 4.5ms mark)
    logic 1:  560uS mark then 1690uS space
    logic 0:  560uS mark then 560uS space
    Lead out: 560uS mark
    Lead out: the remaining time to make up the 110 mSec frame length (sometimes spec'ed as 100 or 110 msec)

    Payload: in the real world you will find bytes specified in big and little endian format
        byte 0 = address
        byte 1 = originally byte 0 complemented but in subsequent times, used as an extended address byte
        byte 2 = function
        byte 3 = byte 2 complemented - may be used as extended data but I've never seen this
                 Note: sometimes byte 3 is spec'ed instead of byte 2

    Repeat: in this code we don't do this; as you can just repeat the actual code but:
        The repeat code is a 9ms burst followed by a 2.25ms space and a 560µs burst.

    Pioneer:
    http://www.adrian-kingston.com/IRFormatPioneer.htm
    https://www.pioneerelectronics.com/PUSA/Support/Home-Entertainment-Custom-Install/IR+Codes/A+V+Receivers


    Samsung:
    https://github.com/lepiaf/IR-Remote-Code
    http://www.remotecentral.com/cgi-bin/mboard/rc-discrete/thread.cgi?5780
    https://stackoverflow.com/questions/60718588/understanding-ir-codes-for-samsung-tv

    Note the caret in the notation near the end:   ...^108m
    This means we have a frame length of 108msec and we need to adjust the last burst
    depending on the varying data length to ensure the frame length is always 108 msec.

    Note that originally a 455 kHz resonator (a typical radio receiver's "intermediate" frequency) was often used:
    455 kHz was divided by 12 giving:  37.916667 kHz
]]
local function necVariants(irCodeTab, binTab, code, protocol)
    -- for non Pioneer protocols just set the frequency
    local clkRate = setClockRate(38000,21)   -- value should be 0x6d

    -- for Pioneer; all the times just get scaled up by the different clock rate of 40 kHz
    if (protocol == 'PIONEER') then
        clkRate = setClockRate(40000,21)   -- the pronto code is now set for 40 kHz. Value should be 0x68
        setClockRate(38000,21)             -- but all the calcs are done as if it were for 38 kHz
    end

    -- make the complement. It used for error checking by the IR RX device.
    local byteFC = 0xff-code.byteF

    local cyclesLeadIn = 0
    if ((protocol == 'NECX1') or (protocol == 'NECX2')) then
        cyclesLeadIn = makeBurst(irCodeTab, 8, 8)
    else   -- default to NEC2
        cyclesLeadIn = makeBurst(irCodeTab, 16, 8)
    end

    local burstTiming = {}
    setTimingValues(burstTiming, 1, 1, 1, 3)

    local cyc0 = makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteD,  burstTiming)   -- device
    local cyc1 = makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteS,  burstTiming)   -- subdevice or complement
    local cyc2 = makePDMBursts_LSB(irCodeTab, binTab, 8, code.byteF,  burstTiming)   -- function
    local cyc3 = makePDMBursts_LSB(irCodeTab, binTab, 8,      byteFC, burstTiming)   -- function complement

    -- lead out mark that is always stuck on the end (unlike Sony that doesn't)
    -- Note the 1 in the notation:   ...1,^108m)+
    local cycles560  = m_basicTimeUnitDivisor
    local cycles560h = string.format('%04X',cycles560)
    irCodeTab[#irCodeTab+1] = cycles560h

    -- make a lead out space that will ensure the frame length remains constant
    local cyclesFrameLen = round(m_IRclk * 108.0 * 1.0e-3)   -- frame length: start to next start
    local cyclesLeadOut = cyclesFrameLen - cyclesLeadIn - cyc0 - cyc1 - cyc2 - cyc3 - cycles560
    irCodeTab[#irCodeTab+1] = string.format('%04X', cyclesLeadOut) -- lead out space

    return clkRate
end

-- RAW is a string of integers in usec. The first is a pulse, the second a space, etc .....
-- It would typically contain: lead in, the data and lead out to make up the total frame length.
local function raw(irCodeTab, dummy, code)
    -- set the frequency used for the RAW protocol
    local clkRate = setClockRate(tonumber(code.Freq), 1) -- where 1 is a dummy value

    local cycles = 0
    for i=1, #code.bytes do
        -- raw may use plus and minus to indicate mark and space values
        -- if the sign is  present, we filter them out with the abs maths function
        cycles = round(m_IRclk * math.abs(code.bytes[i]) * 1.0e-6)
        irCodeTab[i] = string.format('%04X',cycles)
    end

    return clkRate
end

--[[
    Note the current toggle bit handling may be insufficient for correct operation.

    RC5: {36k,msb,889}<1,-1|-1,1>(1,~F:1:6,T:1,D:5,F:6,^114m)+

    RC5 is a 14 bit sequence if including the start bit:
    The most significant bit is sent first (NEC and many others do the opposite)
    1st start bit - always high
    2nd start bit always high unless used as a "field" bit instead
    3rd a toggle bit - set to low (it toggles its value on each key press. Not by this code however)
    5 bit device address
    6 bit function number (using the "field" bit 7 bit functions can be produced. Not by this code however)
    Carrier is 36 kHz
    1 – 889us space followed by an 889us pulse burst = 64 cycles at 36kHz
    0 – 889us pulse burst followed by an 889us space = 64 cycles at 36kHz
    Frame size start to next start = 113.778 msec = 4096 cycles at 36 kHz

    Refer to these links for RC5 decoding:
    https://www.clearwater.com.au/code/rc5
    http://www.pcbheaven.com/userpages/The_Philips_RC5_Protocol/?topic=worklog&p=1

    RC5:  1 is a low to high transition; 0 is a high to low transition (RC6 is the reverse)

              | Start | Field | Toggle|  D4   |  D3   |  D2   |  D1   |  D0   |  F5   |  F4   |  F3   |  F2   |  F1   |  F0   |
              |   1   |   1   |   1   |   0   |   1   |   0   |   0   |   0   |   0   |   0   |   1   |   0   |   0   |   0   |
              +   +---+   +---+   +---+---+   +   +---+---+   +---+   +---+   +---+   +---+       +---+---+   +---+   +---+   +
                  |   |   |   |   |       |       |       |   |   |   |   |   |   |   |   |       |       |   |   |   |   |
                  |   |   |   |   |       |       |       |   |   |   |   |   |   |   |   |       |       |   |   |   |   |
                  |   |   |   |   |       |       |       |   |   |   |   |   |   |   |   |       |       |   |   |   |   |
    >---------+---+   +---+   +---+   +   +---+---+   +   +---+   +---+   +---+   +---+   +---+---+   +   +---+   +---+   +---+---------->
                0   1   0   1   0   1   1   0   0   1   1   0   1   0   1   0   1   0   1   0   0   1   1   0   1   0   1   0

    Frame length: 4096/36000 = 113.778 msec
    Bits: (32*(2*(3+5+6))/36000 = 24.889 msec = 896 cycles
    Lead out: 113.778-24.889 = 88.889 msec = 3200 cycles = 0xC80 or 0xCA0 if last bit is low, giving a biphase space at the end
]]
local function rc5(irCodeTab, binTab, code)
    local clkRate = setClockRate(36000,32)

    local manchesterTab = {'01'}  -- start 1 = high
    manchesterTab[2] = '01'       -- start 2 = high
    manchesterTab[3] = '10'       -- toggle bit set to zero (do we need to control this?)

    biphase(manchesterTab, binTab, 5, code.byteD, false)
    biphase(manchesterTab, binTab, 6, code.byteF, false)

    local manchesterStr = table.concat(manchesterTab,'')
    debug('Manchester code: '..manchesterStr)

    local cyc0 = convertManchesterToPronto(irCodeTab, manchesterStr, false)
    local cyclesFrameLen = round(m_IRclk * 113.778e-3)

    local cyclesLeadOut = cyclesFrameLen - cyc0
    irCodeTab[#irCodeTab+1] = string.format('%04X', cyclesLeadOut) -- lead out space

    return clkRate
end

--[[
    Note the current toggle bit handling may be insufficient for correct operation.

    RC6: {36k,444,msb}<-1,1|1,-1>(6,-2,1:1,0:3,<-2,2|2,-2>(T:1),D:8,F:8,^107m)+

    Carrier is 36 kHz
    1 – 444us pulse burst followed by an 444us space = 32 cycles at 36kHz
    0 – 444us space followed by an 444us pulse burst = 32 cycles at 36kHz

    RC6 (RC6-0-16) is a 16 bit sequence
    RC6-6-20 (Sky TV) is a 20 bit sequence
    RC6-6-32 (MCE) is a 32 bit sequence
    The most significant bit is sent first (NEC and many others do the opposite)

    Lead in pulse: 6 unit mark, 2 unit space = 2.667 + 0.889 = 3.556 msec
    Start bit: biphase - always set to 1 - effectively part of the lead in

    3 mode bits: "RC6": mode = 000b;   RC6-6-20: mode = 110b  ie 6 dec
    Toggle bit - set to low (it toggles its value on each key press. Not by this code however)
    The toggle bit is weird in that it is double the period of a normal bit ie 889us/889us

    Next:
    Normal RC6:  16 bit operation
    8 address bits
    8 function bits

    MCE:   32 bit operation (Microsoft Windows Media Center)
        The device byte may be split into a non stand toggle bit (msb) and 7 device bits.
        The weird trailer/toggle bit is always set to zero.
    8 OEM 1 bits   <-- makes a 36 bit code: MCE = 128 = 80h
    8 OEM 2 bits   <-- makes a 36 bit code: MCE =  15 = 0fh
    1 non standard toggle bit
    7 address bits
    8 function bits

    Sky TV:   20 bit operation
    8 address bits
    4 S bits - possibly equal to 1100 = 0x0c
    8 function bits

    srcS is typically: -1, 12 or 15

    Refer to these links for RC6 decoding:
    http://www.snrelectronicsblog.com/8051/rc-6-protocol-and-interfacing-with-microcontroller/
    http://www.pcbheaven.com/userpages/The_Philips_RC6_Protocol/

    RC6:  1 is a high to low transition; 0 is a low to high transition (RC5 is the reverse)

    Two of eight possible Toggle bit sequences; as general examples:

    Toggle low:
              | Start |  M2   |  M1   |  M0   | double T bit  |  D7   |  Dx   |  D0   |  F7   |  Fx   |  F0   |
              |   1   |   0   |   0   |   0   |       0           0   |   0   |   0   |   1   |   0   |   1   |
              +---+   +   +---+   +---+   +---+       +-------+   +---+   +...+   +---+---+       +...+---+   +
              |   |       |   |   |   |   |   |       |       |   |   |   |   |   |       |       |       |
              | 1 | 2   3 | 4 | 5 | 6 | 7 | 8 |   9   |   10  | 11| 12|   |   |   |       |       |       |
      Leadin  |   |       |   |   |   |   |   |       |       |   |   |   |   |   |       |       |       |
    >---------+   +---+---+   +---+   +---+   +-------+       +---+   +---+   +---+   +   +---+---+   +   +---+-------------->
                1   0   0   1   0   1   0   1     0       1     0   1   0   x   0   1   1   0   0   x   1   0
                1   0   0   1   0   1   0   1     0       1     10101010100110101010101001011010
    Toggle high:
              | Start |  M2   |  M1   |  M0   | double T bit  |  D7   |  Dx   |  D0   |  F7   |  Fx   |  F0   |
              |   1   |   0   |   0   |   0   |       1           0   |   0   |   0   |   1   |   0   |   1   |
              +---+   +   +---+   +---+   +---+-------+       +   +---+   +...+   +---+---+       +...+---+   +
              |   |       |   |   |   |   |           |           |   |   |   |   |       |       |       |
              |   |       |   |   |   |   |           |           |   |   |   |   |       |       |       |
      Leadin  |   |       |   |   |   |   |           |           |   |   |   |   |       |       |       |
    >---------+   +---+---+   +---+   +---+   +       +-------+---+   +---+   +---+   +   +---+---+   +   +---+-------------->
                1   0   0   1   0   1   0   1     1       0     0   1   0   x   0   1   1   0   0   x   1   0

    Frame length: (4096-256)/36000 = 106.667 msec   <-- this a bit of guess
    Bits: (16*(6+2+2*(1+3+(2*1)+8+8))/36000 = 23.111 msec = 832 cycles
    Lead out: 106.667-23.111 = 83.556 msec = 3008 cycles = 0xBC0
]]

local function rc6(irCodeTab, binTab, code, protocol)
    local clkRate = setClockRate(36000,16)

    local cyclesLeadIn = makeBurst(irCodeTab, 6, 2)

    local manchesterTab = {'10'}  -- start 1 = high
    binTab[1] = '1'

    if ((protocol == 'RC6') or (protocol == 'RC6-0-16')) then
        manchesterTab[2] = '010101'   -- mode = 000b
        binTab[2] = '000'
    else   -- RC6-6-20 or RC6-6-32 (MCE)
        manchesterTab[2] = '101001'   -- mode = 110b
        binTab[2] = '110'
    end

    -- (double width) toggle bit set to zero (do we need to control this?)
    manchesterTab[3] = '01'
    binTab[3] = '0'

    -- srcS is typically: -1, 12 or 15
    local logicOneIsOneZero = true
    if ((protocol == 'RC6') or (protocol == 'RC6-0-16')) then
        biphase(manchesterTab, binTab, 8, code.byteD, logicOneIsOneZero)
        biphase(manchesterTab, binTab, 8, code.byteF, logicOneIsOneZero)
    elseif (protocol == 'RC6-6-20') then
        -- https://www.ofitselfso.com/IRSky/SkyPlusIRRemoteCodes.txt
        local skyTV = code.byteS   -- 0x0c   rough guess!!!
        biphase(manchesterTab, binTab, 8, code.byteD, logicOneIsOneZero)
        biphase(manchesterTab, binTab, 4,      skyTV, logicOneIsOneZero)
        biphase(manchesterTab, binTab, 8, code.byteF, logicOneIsOneZero)
    elseif ((protocol == 'RC6-6-32') or (protocol == 'MCE')) then
        -- https://programtalk.com/vs2/?source=python/4060/EventGhost/eg/Classes/IrDecoder/Rc6.py
        -- https://docs.microsoft.com/en-us/previous-versions/ms867196(v=msdn.10)?redirectedfrom=MSDN
        local oem1 = 0x80
        local oem2 = code.byteS   -- typically 0x0f
        biphase(manchesterTab, binTab, 8,       oem1, logicOneIsOneZero)
        biphase(manchesterTab, binTab, 8,       oem2, logicOneIsOneZero)

        -- If the same code is sent twice in a row, then the toggle bit must be used.
        -- Alternatively you can send the code and then send a code that does nothing.
        local byte4 = code.byteD  -- bit 7 is set to zero
        if (m_mceToggle) then byte4 = code.byteD + 0x80 end  -- bit 7 is set to one
        m_mceToggle = not m_mceToggle

        biphase(manchesterTab, binTab, 8,      byte4, logicOneIsOneZero)
        biphase(manchesterTab, binTab, 8, code.byteF, logicOneIsOneZero)
    else
        debug('Unknown RC6 type')
    end

    local manchesterStr = table.concat(manchesterTab,'')
    debug('Manchester code: '..manchesterStr)

    local cyc0 = convertManchesterToPronto(irCodeTab, manchesterStr, true)
    local cyclesFrameLen = round(m_IRclk * 106.667e-3)
    local cyclesLeadOut = cyclesFrameLen - cyclesLeadIn - cyc0
    irCodeTab[#irCodeTab+1] = string.format('%04X', cyclesLeadOut) -- lead out space

    return clkRate
end

--[[
    RCA: {58k,460,msb}<1,-2|1,-4>(8,-8,D:4,F:8,~D:4,~F:8,1,-16)+

    The most significant bit is sent first (NEC and many others do the opposite)
    12-bit protocol
    4-bit address and 8-bit command length (12-bit protocol)
    Pulse distance modulation
    Carrier frequency of 56kHz
    Bit time of 1.5ms or 2.5ms:  (0.5+1.0) and (0.5+2.0)
    Complement of code sent out after real code for reliability
    The clock frequency spec is a bit vague: 56kHz to 58 kHz. Vishay Telefunken ICs use 56.7 kHz

    https://www.sbprojects.net/knowledge/ir/rca.php
]]
local function rca(irCodeTab, binTab, code)
    local clkRate = setClockRate(56700,28)   -- frequency as per Vishay Telefunken

    -- make the complements
    local byteDC = 0x0f-code.byteD   -- only 4 active bits
    local byteFC = 0xff-code.byteF   -- only 8 active bits

    makeBurst(irCodeTab, 8, 8)

    local burstTiming = {}
    setTimingValues(burstTiming, 1, 2, 1, 4)

    makePDMBursts_MSB(irCodeTab, binTab, 4, code.byteD,  burstTiming)   -- device
    makePDMBursts_MSB(irCodeTab, binTab, 8, code.byteF,  burstTiming)   -- function
    makePDMBursts_MSB(irCodeTab, binTab, 4,      byteDC, burstTiming)   -- device complement
    makePDMBursts_MSB(irCodeTab, binTab, 8,      byteFC, burstTiming)   -- function complement

    makeBurst(irCodeTab, 1, 16)

    return clkRate
end

--[[
    SONY12: {40k,600}<1,-1|2,-1>(4,-1,F:7,D:5,^45m)+
    SONY15: {40k,600}<1,-1|2,-1>(4,-1,F:7,D:8,^45m)+
    SONY20: {40k,600}<1,-1|2,-1>(4,-1,F:7,D:5,S:8,^45m)+

    http://www.righto.com/2010/03/understanding-sony-ir-remote-codes-lirc.html
    http://www.hifi-remote.com/sony/
    https://www.sbprojects.net/knowledge/ir/sirc.php

    LSB is transmitted first
    12-bit version: 7 function bits, 5 address bits
    15-bit version: 7 function bits, 8 address bits
    20-bit version: 7 function bits, 5 address bits, 8 extended bits
    Pulse distance modulation
    Carrier frequency of 40kHz
    Bit time of 1.2ms or 0.6ms
    The very last bit always ends in space, so it must be absorbed into the leadout
    Sony IR codes need to be sent twice or in some cases three times.
]]
local function sony(irCodeTab, binTab, code, protocol)
    local clkRate = setClockRate(40000,24)

    local cyclesLeadIn = makeBurst(irCodeTab, 4, 1)

    -- default to SONY12
    local b0Len = 7
    local b1Len = 5
    local b2Len = 0
    if     (protocol == 'SONY15') then b1Len = 8
    elseif (protocol == 'SONY20') then b2Len = 8 end

    -- do the code expansion into the modulation method
    local burstTiming = {}
    setTimingValues(burstTiming, 1, 1, 2, 1)

    local cyc0 = makePDMBursts_LSB(irCodeTab, binTab, b0Len, code.byteF, burstTiming)   -- function
    local cyc1 = makePDMBursts_LSB(irCodeTab, binTab, b1Len, code.byteD, burstTiming)   -- device address
    local cyc2 = 0
    if (b2Len ~= 0) then cyc2 = makePDMBursts_LSB(irCodeTab, binTab, b2Len, code.byteE, burstTiming) end  -- device address ext

    local cycles600 = m_basicTimeUnitDivisor

    local cyclesFrameLen = round(m_IRclk * 45.0 * 1.0e-3)   -- frame length: start to next start
    local cyclesLeadOut = cyclesFrameLen - cyclesLeadIn - cyc0 - cyc1 - cyc2 + cycles600  -- plus the last absorbed 600 usec leadout space
    irCodeTab[#irCodeTab] = string.format('%04X', cyclesLeadOut)  -- the last data bit space is absorbed into the lead out space

    return clkRate
end

-- A service in the implementation file
-- Generates the Proto Code for the various formats.
-- Pronto code format info:   http://www.remotecentral.com/features/irdisp2.htm
-- Protocol information:   http://www.hifi-remote.com/wiki/index.php/DecodeIR
local function convertCodeToPronto(protocol, code, repeats)
    if (type(protocol) ~= 'string') then debug ('protocol is not a string',50) return end
    protocol = protocol:upper()

    -- 0 is no repeats, 1 = repeat once, etc
    if ((repeats == nil) or (repeats == '')) then repeats = 0 end
    repeats = tonumber(repeats)

    local irCodeTab = {}
    local binTab = {}
    local clkRate = ''

    if (protocol == 'PRONTO') then return code.prontoCode end -- easy one - we're done already

    -- set up a jump table for each protocol
    local case = protocol
    --if (code.oemIdM) then case = 'KFAMILY' end   -- only kaseikyo has the variable oemIdM
    if (m_kFamily  [protocol]) then case = 'KFAMILY'   end
    if (m_rc6Family[protocol]) then case = 'RC6FAMILY' end

    local action = {
        ['DENON']      = denonSharp,
        ['GC100']      = gc100,
        ['JVC']        = mitsubishiJVC,
        ['KFAMILY']    = kaseikyo,   -- there are more IRP protocols contained in the Kaseikyo family. Refer to m_kFamily.
        ['MITSUBISHI'] = mitsubishiJVC,
        ['RAW']        = raw,
        ['RC5']        = rc5,
        ['RC6FAMILY']  = rc6,
        ['RCA']        = rca,
        ['SHARP']      = denonSharp,
        ['SONY12']     = sony,
        ['SONY15']     = sony,
        ['SONY20']     = sony
    } -- default: NEC, LG, PIONEER, SHARP, SAMSUNG, etc

    if (action[case]) then -- execute the function that does the work
        clkRate = action[case](irCodeTab, binTab, code, protocol)
    else -- default:
        clkRate = necVariants(irCodeTab, binTab, code, protocol)
    end

    if (#irCodeTab % 2 ~= 0) then
        debug('Coding error in protocol '..protocol..': IR code is an odd length. It should be all pairs.',50)
    end

    -- convert the binary info to hex info - we'll log both representations for the web page
    local hexTab = {}
    for i=1, #binTab do
        hexTab[i] = string.format('0x%02X', tonumber(binTab[i],2))
    end

    -- tag the binary log info onto the function code
    code.LogInfo = table.concat(hexTab,', ')..',  '..table.concat(binTab,', ')
    debug('Binary code: '..code.LogInfo)

    -- all table entries are 4 digit hexadecimal strings
    local pcTab = {}

    -- start preamble - first thing to do: indicate code is learned ie raw info
    pcTab[1] = '0000'

    pcTab[2] = clkRate

    -- The first  sequence is the IR code for sending a code only once
    -- The second sequence is the IR code to be used when it is sent repeatedly
    -- If a sequence is not required, it is set to '0000'
    -- If two sequences are used; they may or may not be the same code

    -- number of burst pairs in sequence #1
    -- set to none: sequence #1 is blank; codes are considered repeatable
    pcTab[3] = '0000'

    -- number of burst pairs in sequence #2
    -- As an example the NEC codes are of fixed length and would equal:
    -- leadin + address + data + leadout = 1+8+8+8+8+1 = 34dec = 22hex

    -- Set the count of the number of burst pairs created. We'll fill it in, a bit later.
    pcTab[4] = 'Dummy'

    -- Copy the IR code into the Pronto Code as many repeat times as required.
    -- Skip the pronto code intro and start copying in the generated IR code.
    local j = 5
    for z=0, repeats do
        local start = 1

        -- JVC only has its lead in burst sent once, any repeats must leave it out.
        if ((z >= 1) and (protocol == 'JVC')) then  -- skip burst pair
            start = 3
        end

        for i = start, #irCodeTab do
            pcTab[j] = irCodeTab[i]
            j =  j+1
        end
    end

    -- set the count of the number of burst pairs created
    pcTab[4] = string.format('%04X', math.modf((#pcTab-4)/2))

    -- return the pronto code
    return table.concat(pcTab,' ')
end

-- A service in the implementation file
-- Get the remote code loaded from the json file, convert to a Pronto code and send it
local function sendRemoteCode(remoteIdx, functionIdx)
    if ((type(remoteIdx)  ~= 'string') or (type(functionIdx) ~= 'string')) then
        debug('sendRemoteCode() parameters are not all strings',50) return end

    local remote = m_remoteList[remoteIdx]
    if (not remote) then debug ('Remote name "'..remoteIdx..'" not found.',50) return end

    local fnc = remote.Functions[functionIdx]
    if (not fnc) then debug ('Function key name "'..functionIdx..'" not found in "'..remoteIdx..'".',50) return end

    -- original button code/function
    local btnCode = string.format('%i %i %i', fnc.CmdOBC.obcD, fnc.CmdOBC.obcS, fnc.CmdOBC.obcF)

    local protocol = remote.Encoding.Protocol
    local repeats  = remote.Encoding.Repeats
    debug('Protocol: '..protocol..', Button code: '..btnCode..', Function: '..functionIdx..', Remote: '..remoteIdx..', Repeats: '..repeats,50)

    local prontoCode = convertCodeToPronto(protocol, fnc.CmdBytes, repeats)
    if (prontoCode == nil) then
        debug('IR code is invalid - no prontoCode was produced', 50)
        return
    end

    local device = tonumber(remote.IRemitter.Device)
    if (device == nil) then
        debug('Device ID is invalid', 50)
        return
    end
    debug('IR transmitter being used is Device '..device,50)
    debug('Sending prontoCode: '..prontoCode, 50)

    -- handle different services used by the various plugins
    local serviceIdx = remote.IRemitter.ServiceIdx
    if     (serviceIdx == '1') then   -- eg GC100
        luup.call_action('urn:micasaverde-com:serviceId:IrTransmitter1', 'SendProntoCode', {ProntoCode=prontoCode}, device)
    elseif (serviceIdx == '2') then   -- BroadLink remotes
        luup.call_action('urn:a-lurker-com:serviceId:IrTransmitter1', 'SendProntoCode', {ProntoCode=prontoCode}, device)
    elseif (serviceIdx == '3') then   -- Kira remotes
        -- uses UDP. needs an ip address and an ip port plus conversion of Pronto to Kira IR code
        -- the Kira plugin names codes, so it can't just send a pronto or Kira IR code
        -- luup.call_action("urn:dcineco-com:serviceId:KiraTx1","SendIRCode",{IRCodeName="nameofcode",Count=3,Delay=50}, device)
        debug('Kira: not implemented', 50)
    elseif (serviceIdx == '4') then   -- Tasmota
        -- https://tasmota.github.io/docs/IRSend-RAW-Encoding/#irsend-for-raw-ir
        -- needs a URL and it can't send Pronto but does have its own Raw and a compressed Raw
        -- eg http://DeviceIPadress/cm?cmnd=IRsend{...}
        debug('Tasmota: not implemented', 50)
    else
        debug('IR transmitter service index is unknown', 50)
    end
 end

-- A service in the implementation file
-- Send an IRP code specified by the user
local function sendIRPCode(protocol, device, subdevice, fnc, repeats, irDevice, irServiceIdx)
    if ((type(irDevice)     ~= 'string') or
        (type(irServiceIdx) ~= 'string') or
        (type(protocol)     ~= 'string') or
        (type(device)       ~= 'string') or
        (type(subdevice)    ~= 'string') or
        (type(fnc)          ~= 'string')) then
        debug('sendIRPCode() parameters are not all strings',50) return end

    if ((repeats == nil) or (type(irRfCode) ~= 'string')) then repeats = '0' end

    local remoteName   = 'Send an IRP Code'
    local userFunction = "<--- the IRP code"
    local remote = {
        IRemitter = {Device = irDevice, ServiceIdx = irServiceIdx},
        Model     = 'Send: '..protocol..', '..device..', '..subdevice..', '..fnc,
        Encoding  = {
            Protocol  = protocol,
            Device    = device,
            Subdevice = subdevice,
            LSBfirst  = true,
            Repeats   = repeats
        },
        Functions = {
            [userFunction] = {Fnc = fnc, Note = '<--- the IRP code binary'}
        }
    }
    -- Check the IRP code makes some sort of sense. Set up data the IR code will need to use.
    local ok = validateAndMassageCode(remoteName,remote)
    if (not ok) then debug('Your IR code could not be validated - try again!',50) end

    -- Add it in or update it, in the list of remotes. It will appear on the web page.
    m_remoteList[remoteName] = remote

    sendRemoteCode(remoteName, userFunction)
end

-- Get a HTML string containing the remote(s) details, derived from and contained in the json file
local function listCodes(remoteList)
    local idx = 1
    local strTab = {}

    -- sort by the remote names
    local sortedRemotes = {}
    for remoteName in pairs(remoteList) do table.insert(sortedRemotes, remoteName) end
    table.sort(sortedRemotes)

    for i=1, #sortedRemotes do
        local remoteName = sortedRemotes[i]
        local remote = remoteList[remoteName]
        strTab[idx] = '\n\n'..'Remote:        '..remoteName            idx = idx+1
        strTab[idx] = 'IR Device:     '..remote.IRemitter.Device       idx = idx+1
        strTab[idx] = 'IR ServiceIdx: '..remote.IRemitter.ServiceIdx   idx = idx+1
        strTab[idx] = 'Model:         '..remote.Model                  idx = idx+1
        strTab[idx] = 'Protocol:      '..remote.Encoding.Protocol      idx = idx+1
        strTab[idx] = 'Repeats:       '..remote.Encoding.Repeats       idx = idx+1

        -- sort by function keys
        local sortedFncKeys = {}
        for k in pairs(remote.Functions) do table.insert(sortedFncKeys, k) end
        table.sort(sortedFncKeys)

        local firstFnc = remote.Functions[sortedFncKeys[1]]

        -- see if the protocol has been flagged as being part of the Kaseikyo family
        if (remote.Encoding.Kaseikyo) then
            local oemIdM = firstFnc.CmdBytes.oemIdM
            local oemIdN = firstFnc.CmdBytes.oemIdN
            strTab[idx] = string.format('OEM ID: %i %i',oemIdM,oemIdN)  idx = idx+1
        end

        local str = 'The Device, Subdevice and Function values in the actual json file are considered to be in '
        if (remote.Encoding.LSBfirst) then
            strTab[idx] = str..'LSB to MSB order'
        else
            strTab[idx] = str..'MSB to LSB order'
        end
        idx = idx+1

        local note = ''
        local protocol = remote.Encoding.Protocol:upper()

        -- these are arrays of various styles of burst info, not IRP button codes
        if ((protocol == 'GC100') or (protocol == 'PRONTO') or (protocol == 'RAW')) then
            for i=1, #sortedFncKeys do
                local functionName = sortedFncKeys[i]
                local fnc  = remote.Functions[functionName]
                local freq = fnc.Freq
                if (not freq) then freq = '' end  -- GC100 doesn't have a Freq variable
                note = fnc.Note
                strTab[idx] = string.format('  ?   ?   ?    Array%7s   %-12s%s',freq,functionName,note)
                idx = idx+1
            end
        else
            -- original button code/function
            local btnCode = string.format('%3i %3i ', firstFnc.CmdOBC.obcD, firstFnc.CmdOBC.obcS)

            -- This loop can be time intensive. Only get the log info if necessary. It would
            -- be good if the whole web page could be generated just once but it can't be,
            -- because sendIRPCode() may change and we need to generate new logging info for it.
            for i=1, #sortedFncKeys do
                local functionName = sortedFncKeys[i]
                local fnc = remote.Functions[functionName]
                local obcF = fnc.CmdOBC.obcF

                -- generate the binary info, so we can log it to the web page
                local logInfo = fnc.CmdBytes.LogInfo
                if (not logInfo) then
                    -- not interested in any repeats here, so set to no repeats
                    convertCodeToPronto(protocol, fnc.CmdBytes, 0)
                    logInfo = fnc.CmdBytes.LogInfo
                end
                note = fnc.Note
                strTab[idx] = string.format('%s%3i    %-22s%s   %s',btnCode,obcF,functionName,logInfo,note)
                idx = idx+1
            end
        end
    end
    return table.concat(strTab,'\n')
end

-- Proforma header for the web page
local function htmlHeader()
return [[<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8"/>]]
end

-- Web page used to report the remote control IR codes.
local function htmlIntroPage()
    local title  = 'JSON IR codes'
    local header = PLUGIN_NAME..':&nbsp;&nbsp;plugin version:&nbsp;&nbsp;'..PLUGIN_VERSION

    local strTab = {
    htmlHeader(),
    '<title>'..title..'</title>',
    '</head>\n',
    '<body>',
    '<h3>'..header..'</h3>',
    '<div>',
    '<br/>',
    'IR codes maybe in little endian order (eg as per <a href="http://irdb.tk/">IRDB</a>) or big endian (eg as read off an oscilloscope):',
    '<pre>',
    listCodes(m_remoteList),
   '</pre>',
    '</div>',
    '</body>',
    '</html>\n'
    }
    return table.concat(strTab,'\n'), 'text/html'
end

-- Entry point for all html page requests and all ajax function calls
-- http://vera_ip_address/port_3480/data_request?id=lr_al_ir_code_info
function requestMain()
    return htmlIntroPage()
end

-- For testing puposes only.
-- Compares generated results against known results. Lets
-- us know (hopefully) if the plugin is working correctly.
function checkPlugin()
    -- WARNING: The 'required' stuff is all cached. Here we force
    -- a cache reload of vprValidate.lua to ensure we are always
    -- working with the latest copy of vprValidate.lua
    package.loaded.vprValidate = nil
    local vprValidate = require('vprValidate')

    if (not vprValidate) then debug ('vprValidate library not found') return end

    local remoteList = loadCodes(vprValidate)
    local ok = validateAndMassageCodes(remoteList)

    -- sort by the remote names
    local sortedRemotes = {}
    for k in pairs(remoteList) do table.insert(sortedRemotes, k) end
    table.sort(sortedRemotes)

    for _, remoteName in ipairs(sortedRemotes) do
        local remoteInfo = remoteList[remoteName]
        local testResult = vprValidate.validTestResults[remoteName]
        if (testResult) then
            local func = testResult.Fnc
            if (remoteInfo.Functions[func]) then
            local prontoCode = convertCodeToPronto(
                remoteInfo.Encoding.Protocol,
                remoteInfo.Functions[func].CmdBytes,
                remoteInfo.Encoding.Repeats)

                local msg = 'Pronto Code check for "'..remoteName..'" Protocol: '..remoteInfo.Encoding.Protocol
                if (prontoCode == testResult.pcResult) then
                    print(msg..' tests OK')
                else
                    print(msg..' failed')
                    if (prontoCode == nil) then
                        print('prontoCode is nil: it may not be constructed of pairs')
                    else
                        print('Incorrect: '..prontoCode)
                    end
                    print('Correct:   '..testResult.pcResult)
                end

             else
                print('The test function key name "'..func..'" not found in "'..remoteName..'" in remoteList')
            end
        else
            print('"'..remoteName..'" is not listed in vprValidate.validTestResults')
        end
    end
end

-- Start up the plugin
-- Refer to: I_VirtualProntoRemote1.xml
-- <startup>luaStartUp</startup>
function luaStartUp(lul_device)
    THIS_LUL_DEVICE = lul_device

    -- set up some defaults:
    updateVariable('PluginVersion', PLUGIN_VERSION)

    -- set up some defaults:
    local debugEnabled = luup.variable_get(PLUGIN_SID, 'DebugEnabled', THIS_LUL_DEVICE)
    if not((debugEnabled == '0') or (debugEnabled == '1')) then
        debugEnabled = '0'
        updateVariable('DebugEnabled', debugEnabled)
    end
    DEBUG_MODE = (debugEnabled == '1')
    if (m_testing) then DEBUG_MODE = true end

    m_json = loadJsonModule()
    if (m_json == nil) then
       luup.task("No JSON library found", 2, string.format("%s[%d]", luup.devices[THIS_LUL_DEVICE].description, THIS_LUL_DEVICE), -1)
       return false, 'No JSON library found.', PLUGIN_NAME
    end

    m_remoteList = loadCodes(nil)
    local ok = validateAndMassageCodes(m_remoteList)
    if (not ok) then
        luup.task("Error: probably in JSON file. Check log.", 2, string.format("%s[%d]", luup.devices[THIS_LUL_DEVICE].description, THIS_LUL_DEVICE), -1)
       return false, 'Error: probably in JSON file. Check log.', PLUGIN_NAME
    end

    if (m_testing) then
        checkPlugin()
    else
        -- registers a handler for the plugins's web page
        luup.register_handler('requestMain', PLUGIN_URL_ID)
    end

    -- on success
    return true, 'All OK', PLUGIN_NAME
end

