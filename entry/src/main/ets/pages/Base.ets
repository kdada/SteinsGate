@ObservedV2
export class VMessAuthData {
  public index: number = 0
  public alias: string = ""
  public address: string = ""
  public port: string = ""
  public id: string = ""
}

@ObservedV2
export class VMessSetting {
  @Trace domainListURL = ""
  @Trace ipListURL = ""
  @Trace downloadDomainListViaProxy = false
  @Trace downloadIPListViaProxy = false
  @Trace domainBlackList = ""
  @Trace ipBlackList = ""
  @Trace directDNS = ""
  @Trace proxyDNS = ""
  @Trace dnsProxyType = DNSProxyType.ProxyUnknown
  @Trace ipProxyType = IPProxyType.ProxyUnknown
}

export function defaultVMessSetting(): VMessSetting {
  let setting = new VMessSetting()
  setting.domainListURL = "https=//raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
  setting.ipListURL = "https=//raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute.txt"
  setting.downloadDomainListViaProxy = true
  setting.downloadIPListViaProxy = true
  setting.domainBlackList =
    "browsercfg-drcn.cloud.dbankcloud.cn\nbrowserr-drcn.dbankcdn.cn\nmetrics1-drcn.dt.dbankcloud.cn"
  setting.ipBlackList = ""
  setting.directDNS = "114.114.114.114"
  setting.proxyDNS = "8.8.8.8"
  setting.dnsProxyType = DNSProxyType.ProxyWhichInDomainList
  setting.ipProxyType = IPProxyType.ProxyWhichNotInIPList
  return setting
}

export enum DNSProxyType {
  ProxyUnknown = 0,
  ProxyWhichInDomainList = 1,
  ProxyWhichNotInDomainList = 2,
  ProxyAll = 3,
  ProxyNone = 4,
}

export function DNSProxyTypeToString(dnsProxyType: DNSProxyType): string {
  switch (dnsProxyType) {
    case DNSProxyType.ProxyWhichInDomainList:
      return "通过代理解析域名列表中的域名"
    case DNSProxyType.ProxyWhichNotInDomainList:
      return "通过代理解析不在域名列表中的域名"
    case DNSProxyType.ProxyAll:
      return "通过代理解析所有域名"
    case DNSProxyType.ProxyNone:
      return "不使用代理解析所有域名"
  }
  return "未设置"
}

export enum IPProxyType {
  ProxyUnknown = 0,
  ProxyWhichInIPList = 1,
  ProxyWhichNotInIPList = 2,
  ProxyAll = 3,
  ProxyNone = 4,
}

export function IPProxyTypeToString(ipProxyType: IPProxyType): string {
  switch (ipProxyType) {
    case IPProxyType.ProxyWhichInIPList:
      return "通过代理访问 IP 列表中的 IP"
    case IPProxyType.ProxyWhichNotInIPList:
      return "通过代理访问不在 IP 列表中的 IP"
    case IPProxyType.ProxyAll:
      return "通过代理访问所有 IP"
    case IPProxyType.ProxyNone:
      return "不使用代理访问所有 IP"
  }
  return "未设置"
}