import {
  defaultVMessSetting,
  DNSProxyType,
  DNSProxyTypeToString,
  IPProxyType,
  IPProxyTypeToString,
  VMessSetting
} from "./Base"
import { PersistenceV2 } from "@kit.ArkUI"

@ComponentV2
export struct Setting {
  @Local setting: VMessSetting = PersistenceV2.connect(VMessSetting, "GlobalSetting", () => defaultVMessSetting())!

  build() {
    NavDestination() {
      Column() {
        Column() {
          Row() {
            Text("域名列表下载地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.setting.domainListURL })
              .width("50%")
              .onChange(text => {
                this.setting.domainListURL = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("通过代理下载域名列表")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Column() {
              Toggle({ type: ToggleType.Switch, isOn: this.setting.downloadDomainListViaProxy })
                .onChange((isOn) => {
                  this.setting.downloadDomainListViaProxy = isOn
                })
            }
            .alignItems(HorizontalAlign.End)
            .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("IP 列表下载地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.setting.ipListURL })
              .width("50%")
              .onChange(text => {
                this.setting.ipListURL = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("通过代理下载 IP 列表")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Column() {
              Toggle({ type: ToggleType.Switch, isOn: this.setting.downloadIPListViaProxy })
                .onChange((isOn) => {
                  this.setting.downloadIPListViaProxy = isOn
                })
            }
            .alignItems(HorizontalAlign.End)
            .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("域名黑名单（每行一个）")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextArea({ text: this.setting.domainBlackList })
              .width("50%")
              .height(80)
              .onChange(text => {
                this.setting.domainBlackList = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("IP 黑名单（每行一个）")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextArea({ text: this.setting.ipBlackList })
              .width("50%")
              .height(80)
              .onChange(text => {
                this.setting.ipBlackList = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("直连的 DNS 服务器地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.setting.directDNS })
              .width("50%")
              .onChange(text => {
                this.setting.directDNS = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("代理的 DNS 服务器地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.setting.proxyDNS })
              .width("50%")
              .onChange(text => {
                this.setting.proxyDNS = text
              })
          }
          .margin({ bottom: 5 })

          Row() {
            Text("域名解析设置")
              .width("30%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Button(DNSProxyTypeToString(this.setting.dnsProxyType))
              .fontSize(12)
              .bindMenu([
                {
                  value: DNSProxyTypeToString(DNSProxyType.ProxyWhichInDomainList),
                  action: () => {
                    this.setting.dnsProxyType = DNSProxyType.ProxyWhichInDomainList
                  }
                },
                {
                  value: DNSProxyTypeToString(DNSProxyType.ProxyWhichNotInDomainList),
                  action: () => {
                    this.setting.dnsProxyType = DNSProxyType.ProxyWhichNotInDomainList
                  }
                },
                {
                  value: DNSProxyTypeToString(DNSProxyType.ProxyAll),
                  action: () => {
                    this.setting.dnsProxyType = DNSProxyType.ProxyAll
                  }
                },
                {
                  value: DNSProxyTypeToString(DNSProxyType.ProxyNone),
                  action: () => {
                    this.setting.dnsProxyType = DNSProxyType.ProxyNone
                  }
                }
              ])
              .width("70%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("访问设置")
              .width("30%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })

            Button(IPProxyTypeToString(this.setting.ipProxyType))
              .fontSize(12)
              .bindMenu([
                {
                  value: IPProxyTypeToString(IPProxyType.ProxyWhichInIPList),
                  action: () => {
                    this.setting.ipProxyType = IPProxyType.ProxyWhichInIPList
                  }
                },
                {
                  value: IPProxyTypeToString(IPProxyType.ProxyWhichNotInIPList),
                  action: () => {
                    this.setting.ipProxyType = IPProxyType.ProxyWhichNotInIPList
                  }
                },
                {
                  value: IPProxyTypeToString(IPProxyType.ProxyAll),
                  action: () => {
                    this.setting.ipProxyType = IPProxyType.ProxyAll
                  }
                },
                {
                  value: IPProxyTypeToString(IPProxyType.ProxyNone),
                  action: () => {
                    this.setting.ipProxyType = IPProxyType.ProxyNone
                  }
                }
              ])
              .width("70%")
          }
          .margin({ bottom: 5 })
        }
      }
    }
    .title("设置")
  }
}