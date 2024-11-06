/**
 * Created on 2024/11/6
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog

extend IPPacket {
    func icmpType(): UInt8 {
        return data[headerLength()]
    }

    func icmpCode(): UInt8 {
        return data[headerLength() + 1]
    }

    func icmpId(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset + 4]) << 8) + UInt16(data[headerOffset + 5])
    }

    @OverflowWrapping
    func setIcmpId(id: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 4] = UInt8(id >> 8)
        data[headerOffset + 5] = UInt8(id)
    }

    @OverflowWrapping
    func resumIcmp() {
        let headerOffset = headerLength()
        data[headerOffset + 2] = 0
        data[headerOffset + 3] = 0
        let result = sumWithPseudoIPHeader(payload())
        data[headerOffset + 2] = UInt8(result >> 8)
        data[headerOffset + 3] = UInt8(result)
    }
}

public class IcmpStack <: IPProtocolStack {
    public override func protocol(): UInt8 {
        return 0x1
    }

    public override func pop(packet: IPPacket) {
        //Hilog.debug(0, "debugTun",
        //    "ICMP: Size: ${packet.length()} From ${packet.srcIPString()} To ${packet.destIPString()}")
        packet.release()
    }
}
