require ('misc')
local pprint = require ('pprint')

--[[
--  STA: regmon, tcpdump, cpusage
--  AP: regmon, tcpdump, cpusage, rc_stats per station
--]]

pprint = require('pprint')

Measurement = { rpc_node = nil
              , node_name = nil
              , node_mac = nil
              , node_mac_br = nil
              , opposite_macs = nil
              , opposite_macs_br = nil
              , regmon_stats = nil
              , tcpdump_pcaps = nil
              , cpusage_stats = nil
              , rc_stats = nil
              , rc_stats_enabled = nil
              , iperf_s_outs = nil
              , iperf_c_outs = nil
              , stations = nil
              , output_dir = nil
              }

function Measurement:new (o)
    local o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Measurement:create ( name, mac, opposite_macs, rpc, output_dir )
    local o = Measurement:new( { rpc_node = rpc
                               , node_name = name
                               , node_mac = mac
                               , node_mac_br = nil
                               , opposite_macs = opposite_macs
                               , opposite_macs_br = nil
                               , regmon_stats = {}
                               , tcpdump_pcaps = {}
                               , cpusage_stats = {}
                               , rc_stats = {}
                               , rc_stats_enabled = false
                               , iperf_s_outs = {}
                               , iperf_c_outs = {}
                               , output_dir = output_dir
                               } )
    return o
end

function read_keys ( input_dir )
    local fname = input_dir .. "/experiment_order.txt"
    if ( isFile ( fname ) ) then
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            local content = file:read ("*a")
            if ( content ~= nil ) then
                local keys = split ( content, "\n" )
                if ( keys [ #keys ] == "" ) then
                    keys [ #keys ] = nil
                end
                return keys
            end
        end
    end
    return nil
end

function read_stations ( input_dir )
    local fname = input_dir .. "/stations.txt"
    if ( isFile ( fname ) ) then
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            local content  = file:read ( "*a" )
            if ( content ~= nil ) then
                local stations = split ( content, "\n" )
                if ( stations [ #stations ] == "" ) then
                    stations [ #stations ] = nil
                end
                return stations
            end
        end
    end
    return nil
end

function Measurement.parse ( name, input_dir, key )

    function parse_measurement ( measurement, name, input_dir, key )
        -- load single measurement
        if ( key ~= nil ) then
            measurement.tcpdump_pcaps [ key ] = ""
            measurement.regmon_stats [ key ] = ""
            measurement.cpusage_stats [ key ] = ""
            local stations = read_stations ( input_dir )
            for _, station in ipairs ( stations ) do
                if ( measurement.rc_stats [ station ] == nil ) then
                    measurement.rc_stats [ station ] = {}
                end
                measurement.rc_stats [ station ] [ key ] = ""
            end
            measurement.iperf_s_outs [ key ] = ""
            measurement.iperf_c_outs [ key ] = ""
        end
    end

    local measurement = Measurement:create ( name, nil, nil, nil, input_dir )
    measurement.tcpdump_pcaps = {}
    if ( key ~= nil ) then
        parse_measurement ( measurement, name, input_dir, key )
        measurement:read ()
    else
        local keys = read_keys ( input_dir )
        if ( keys ~= nil ) then
        for _, key in ipairs ( keys ) do
                parse_measurement ( measurement, name, input_dir, key )
            end
        end
        measurement:read ()
    end
    return measurement
end

function Measurement:read ()
    if ( self.output_dir == nil ) then
        return false, "output dir unset"
    end

    local base_dir = self.output_dir .. "/" .. self.node_name

    -- mac
    local fname = base_dir .. "/mac.txt"
    local file = io.open ( fname )
    if ( file ~= nil ) then
        self.node_mac = file:read ( "*a" )
        if ( self.node_mac ~= nil ) then
            self.node_mac = string.sub ( self.node_mac, 1, string.len ( self.node_mac) - 1 )
        end
        file:close()
    end
    -- mac for bridged setups ( tshark filters by bridge mac )
    local fname = base_dir .. "/mac_br.txt"
    if ( isFile ( fname ) ) then
        local file = io.open ( fname )
        if ( file ~= nil ) then
            self.node_mac_br = file:read ( "*a" )
            if ( self.node_mac_br ~= nil ) then
                self.node_mac_br = string.sub ( self.node_mac_br, 1, string.len ( self.node_mac_br) - 1 )
            end
            file:close()
        end
    end

    -- opposite macs
    local fname = base_dir .. "/opposite_macs.txt"
    local file = io.open ( fname )
    if ( file ~= nil ) then
        local content = file:read ( "*a" )
        if ( content ~= nil ) then
            self.opposite_macs = split ( content, "\n" )
            table.remove ( self.opposite_macs, #self.opposite_macs )
        end
        file:close()
    end
    -- opposite macs for bridged setups ( tshark filters by bridge mac )
    local fname = base_dir .. "/opposite_macs_br.txt"
    if ( isFile ( fname ) == true ) then
        local file = io.open ( fname )
        if ( file ~= nil ) then
            local content = file:read ( "*a" )
            if ( content ~= nil ) then
                self.opposite_macs_br = split ( content, "\n" )
                table.remove ( self.opposite_macs_br, #self.opposite_macs )
            end
            file:close()
        end
    end

    -- regmon stats
    for key, stats in pairs ( self.regmon_stats ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-regmon_stats.txt"
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            stats = file:read ( "*a" )
            self.regmon_stats [ key ] = stats
            file:close ()
        end
    end

    -- cpusage stats
    for key, stats in pairs ( self.cpusage_stats ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-cpusage_stats.txt"
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            stats = file:read ( "*a" )
            self.cpusage_stats [ key ] = stats
            file:close ()
        end
    end

    -- tcpdump pcap
    for key, stats in pairs ( self.tcpdump_pcaps ) do
        local fname = self.output_dir .. "/" .. self.node_name 
                    .. "/" .. self.node_name .. "-" .. key .. ".pcap"
        local file = io.open(fname, "rb")
        if ( file ~= nil ) then
            stats = file:read ("*a")
            self.tcpdump_pcaps [ key ] = stats
            file:close()
        else
            self.tcpdump_pcaps [ key ] = ""
        end
    end

    -- rc_stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            if ( self.rc_stats ~= nil and self.rc_stats [ station ] ~= nil ) then
                for key, stats in pairs ( self.rc_stats [ station ] ) do
                    local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-rc_stats-"
                            .. station .. ".txt"
                    local file = io.open(fname, "r")
                    if ( file ~= nil ) then
                        stats = file:read ( "*a" )
                        self.rc_stats [ station ] [ key ] = stats
                        file:close ()
                    end
                end
            end
        end
    end

    -- iperf server out
    for key, stats in pairs ( self.iperf_s_outs ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-iperf-server.txt"
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            stats = file:read ( "*a" )
            self.iperf_s_outs [ key ] = stats
            file:close ()
        end
    end

    -- iperf server out
    for key, stats in pairs ( self.iperf_c_outs ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-iperf-client.txt"
        local file = io.open ( fname, "r" )
        if ( file ~= nil ) then
            stats = file:read ( "*a" )
            self.iperf_c_outs [ key ] = stats
            file:close ()
        end
    end

    return true, nil
end

function Measurement:write ()
    if ( self.output_dir == nil ) then
        return false, "output dir unset"
    end

    local base_dir = self.output_dir .. "/" .. self.node_name

    local status, err = lfs.mkdir ( base_dir )
    if ( status == false ) then 
        return false, err
    end

    -- mac 
    if ( self.node_mac ~= nil ) then
        local fname = base_dir .. "/mac.txt"
        local file = io.open ( fname, "w" )
        if ( file ~= nil ) then
            file:write ( self.node_mac .. '\n' )
            file:close()
        end
    end
    if ( self.node_mac_br ~= nil ) then
        local fname = base_dir .. "/mac_br.txt"
        local file = io.open ( fname, "w" )
        if ( file ~= nil ) then
            file:write ( self.node_mac_br .. '\n' )
            file:close()
        end
    end

    -- opposite macs
    if ( self.opposite_macs ~= nil ) then
        local fname = base_dir .. "/opposite_macs.txt"
        local file = io.open ( fname, "w" )
        if ( file ~= nil ) then
            for _, mac in ipairs ( self.opposite_macs ) do
                file:write ( mac .. '\n' )
            end
            file:close()
        end
    end
    if ( self.opposite_macs_br ~= nil ) then
        local fname = base_dir .. "/opposite_macs_br.txt"
        local file = io.open ( fname, "w" )
        if ( file ~= nil ) then
            for _, mac in ipairs ( self.opposite_macs_br ) do
                file:write ( mac .. '\n' )
            end
            file:close()
        end
    end

    -- regmon stats
    for key, stats in pairs ( self.regmon_stats ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-regmon_stats.txt"
        local file = io.open ( fname, "w" )
        file:write ( stats )
        file:close ()
    end

    -- cpusage stats
    for key, stats in pairs ( self.cpusage_stats ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key  .. "-cpusage_stats.txt"
        local file = io.open ( fname, "w" )
        file:write ( stats )
        file:close ()
    end
    
    -- tcpdump pcap
    for key, stats in pairs ( self.tcpdump_pcaps ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. ".pcap"
        local file = io.open ( fname, "w")
        if ( file ~= nil )  then
            file:write ( stats )
            file:close()
        end
    end
    
    -- rc_stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            if ( self.rc_stats ~= nil and self.rc_stats [ station ] ~= nil ) then
                for key, stats in pairs ( self.rc_stats [ station ] ) do
                    local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-rc_stats-"
                            .. station .. ".txt"
                    local file = io.open ( fname, "w" )
                    file:write ( stats )
                    file:close ()
                end
            end
        end
    end

    -- iperf server out
    for key, stats in pairs ( self.iperf_s_outs ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-iperf_server.txt"
        local file = io.open ( fname, "w")
        if ( file ~= nil )  then
            file:write ( stats )
            file:close()
        end
    end

    -- iperf client out
    for key, stats in pairs ( self.iperf_c_outs ) do
        local fname = base_dir .. "/" .. self.node_name .. "-" .. key .. "-iperf_client.txt"
        local file = io.open ( fname, "w")
        if ( file ~= nil )  then
            file:write ( stats )
            file:close()
        end
    end

    return true
end

function Measurement:__tostring () 
    local out = "Measurement\n==========\n"
    out = out .. self.node_name .. "\n"
    out = out .. ( self.node_mac or "no mac set" ) .. "\n"
    out = out .. ( self.node_mac_br or "no mac (bridged) set" ) .. "\n"
    -- regmon stats
    out = out .. "regmon: " .. table_size ( self.regmon_stats ) .. " stats\n"
    local key
    local stat
    for key, stat in pairs ( self.regmon_stats ) do
        out = out .. "regmon-" .. key .. ": " .. string.len(stat) .. " bytes\n"
        --print (stat)
    end
    -- cpusage stats
    out = out .. "cpusage: " .. table_size ( self.cpusage_stats ) .. " stats\n"
    for key, stat in pairs ( self.cpusage_stats ) do
        out = out .. "cpusage_stats-" .. key .. ": " .. string.len(stat) .. " bytes\n"
        for _, str in ipairs ( split ( stat, "\n" ) ) do
    --        local cpustat = parse_cpusage ( str )
    --        print (cpustat)
        end
    end
    -- tcpdump pcap
    -- -- pcap.DLT = { EN10MB=DLT_EN10MB, [DLT_EN10MB] = "EN10MB", ... }
    out = out .. "pcaps: " .. table_size ( self.tcpdump_pcaps ) .. " stats\n"
    for key, stats in pairs ( self.tcpdump_pcaps ) do
        out = out .. "tcpdump_pcap-" .. key .. ": " .. string.len ( stats ) .. " bytes\n"
    end
    -- rc_stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            out = out .. "rc_stats:" .. table_size ( self.rc_stats [ station ] ) .. " stats\n"
            if ( self.rc_stats ~= nil and self.rc_stats [ station ] ~= nil) then
                for key, stat in pairs ( self.rc_stats [ station ] ) do
                    out = out .. "rc_stats-" .. station .. "-" .. key .. ": " .. string.len ( stat ) .. " bytes\n"
                    -- if (stat ~= nil) then print (stat) end
                end
            end
        end
    end
    -- iperf server out
    for key, stat in pairs ( self.iperf_s_outs ) do
        out = out .. "iperf-server-" .. key .. ": " .. stat .. "\n"
    end
    -- iperf client out
    for key, stat in pairs ( self.iperf_c_outs ) do
        out = out .. "iperf-client-" .. key .. ": " .. stat .. "\n"
    end

    return out 
end

function Measurement:enable_rc_stats ( stations )
    if ( stations == nil or stations == {} ) then
        self.rc_stats_enabled = false
        return
    end
    self.rc_stats_enabled = true
    self.stations = stations
    for _, station in ipairs ( stations ) do
        self.rc_stats [ station ] = {}
    end
end

function Measurement:start ( phy, key )
    -- regmon 
    local regmon_pid = self.rpc_node.start_regmon_stats ( phy )
    -- cpusage
    local cpusage_pid = self.rpc_node.start_cpusage ( phy )
    -- tcpdump
    local tcpdump_fname = "/tmp/" .. self.node_name .. "-" .. key .. ".pcap"
    local tcpdump_pid = self.rpc_node.start_tcpdump ( phy, tcpdump_fname )
    -- rc stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            local rc_stats_pid = self.rpc_node.start_rc_stats ( phy, station )
        end
    end
    return true
end

function Measurement:stop ( phy, key )
    -- regmon 
    local exit_code = self.rpc_node.stop_regmon_stats ( phy )
    -- cpusage
    local exit_code = self.rpc_node.stop_cpusage ( phy )
    -- tcpdump
    local exit_code = self.rpc_node.stop_tcpdump ( phy )
    -- rc_stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            local exit_code = self.rpc_node.stop_rc_stats ( phy, station )
        end
    end
end

function Measurement:fetch ( phy, key )
    -- regmon
    self.regmon_stats [ key ] = self.rpc_node.get_regmon_stats ( phy )
    -- cpusage
    self.cpusage_stats [ key ] = self.rpc_node.get_cpusage ( phy )
    -- tcpdump
    local tcpdump_fname = "/tmp/" .. self.node_name .."-" .. key .. ".pcap"
    self.tcpdump_pcaps[ key ] = self.rpc_node.get_tcpdump_offline ( phy, tcpdump_fname )
    
    -- rc_stats
    if ( self.rc_stats_enabled == true ) then
        for _, station in ipairs ( self.stations ) do
            local stats = self.rpc_node.get_rc_stats ( phy, station )
            self.rc_stats [ station ] [ key ] = stats 
        end
    end

    -- iperf server out
    -- iperf client out
    -- already done by wait_iperf_c and stop_iperf_s
end

function Measurement.resume ( output_dir )
    local keys = nil
    for _, name in ipairs ( ( scandir ( output_dir ) ) ) do
        if ( name ~= "." and name ~= ".."  and isDir ( output_dir .. "/" .. name )
             and Config.find_node ( name, nodes ) ~= nil ) then
            local measurement = Measurement.parse ( name, output_dir )
            for key, pcap in pairs ( measurement.tcpdump_pcaps ) do
                if ( pcap == nil or pcap == "" ) then
                    if ( keys == nil ) then
                        keys = {}
                        keys [1] = {}
                    end
                    if ( Misc.index_of ( key, keys [1] ) == nil ) then
                        keys [1] [ #keys [1] + 1 ] = key
                    end
                end
            end
        end
    end
    return keys
end
