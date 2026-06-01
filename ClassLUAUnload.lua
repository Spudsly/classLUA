local mq = require('mq')

local classMap = {
    WAR = "war", ROG = "rog", MNK = "mnk", BER = "ber",
    RNG = "rng", SHD = "sk",  CLR = "clr", DRU = "dru",
    SHM = "shm", ENC = "enc", BRD = "brd", PAL = "pal",
    NEC = "nec", MAG = "mag", WIZ = "wiz", BST = "bst",
}

local shortName = mq.TLO.Me.Class.ShortName()
local fileKey = shortName and shortName:upper() or ""
local fileName = classMap[fileKey]

if fileName then
    local path = string.format("classLUA/%s.lua", fileName)
    print(string.format("Unloading class script: %s", path))
    mq.cmdf('/lua stop %s', path)
else
    print(string.format("Unknown class: %s", tostring(shortName)))
end
