@Component
export struct Setting {
  @StorageLink("domainListURL") domainListURL: string =
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
  @StorageLink("ipListURL") ipListURL: string =
    "https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute.txt"
  @StorageLink("downloadDomainListViaProxy") downloadDomainListViaProxy: boolean = true
  @StorageLink("downloadIPListViaProxy") downloadIPListViaProxy: boolean = true
  @StorageLink("domainBlackList") domainBlackList: string =
    "browsercfg-drcn.cloud.dbankcloud.cn\nbrowserr-drcn.dbankcdn.cn\nmetrics1-drcn.dt.dbankcloud.cn"
  @StorageLink("ipBlackList") ipBlackList: string = ""
  @StorageLink("directDNS") directDNS: string = "114.114.114.114"
  @StorageLink("proxyDNS") proxyDNS: string = "8.8.8.8"
  @StorageLink("dnsSetting") dnsSetting: string = "通过代理解析域名列表中的域名"
  @StorageLink("ipSetting") ipSetting: string = "通过代理访问不在 IP 列表中的 IP"

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
            TextInput({ text: this.domainListURL })
              .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("通过代理下载域名列表")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Column() {
              Toggle({ type: ToggleType.Switch, isOn: this.downloadDomainListViaProxy })
                .onChange((isOn) => {
                  this.downloadDomainListViaProxy = isOn
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
            TextInput({ text: this.ipListURL })
              .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("通过代理下载 IP 列表")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Column() {
              Toggle({ type: ToggleType.Switch, isOn: this.downloadIPListViaProxy })
                .onChange((isOn) => {
                  this.downloadIPListViaProxy = isOn
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
            TextArea({ text: this.domainBlackList })
              .width("50%")
              .height(80)
          }
          .margin({ bottom: 5 })

          Row() {
            Text("IP 黑名单（每行一个）")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextArea({ text: this.ipBlackList })
              .width("50%")
              .height(80)
          }
          .margin({ bottom: 5 })

          Row() {
            Text("直连的 DNS 服务器地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.directDNS })
              .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("代理的 DNS 服务器地址")
              .width("50%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            TextInput({ text: this.proxyDNS })
              .width("50%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("域名解析设置")
              .width("30%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })
            Button(this.dnsSetting)
              .bindMenu([
                {
                  value: "通过代理解析域名列表中的域名",
                  action: () => {
                  }
                },
                {
                  value: "通过代理解析不在域名列表中的域名",
                  action: () => {
                  }
                },
                {
                  value: "通过代理解析所有域名",
                  action: () => {
                  }
                },
                {
                  value: "不使用代理解析所有域名",
                  action: () => {
                  }
                }
              ])
              .width("70%")
          }
          .margin({ bottom: 5 })

          Row() {
            Text("链接设置")
              .width("30%")
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Start)
              .padding({ left: 5 })

            Button(this.ipSetting)
              .bindMenu([
                {
                  value: "通过代理访问 IP 列表中的 IP",
                  action: () => {
                  }
                },
                {
                  value: "通过代理访问不在 IP 列表中的 IP",
                  action: () => {
                  }
                },
                {
                  value: "通过代理访问所有 IP",
                  action: () => {
                  }
                },
                {
                  value: "不使用代理访问所有 IP",
                  action: () => {
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