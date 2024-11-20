import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { ComponentContent, PersistenceV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { Setting } from './Setting';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { defaultVMessSetting, VMessAuthData, VMessSetting } from './Base';
import { Detail } from './Detail';
import { kvManager } from '../entryability/EntryAbility';
import { distributedKVStore } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';

class PromptParams<T> {
  private ctx?: UIContext
  private content?: ComponentContent<PromptParams<T>>
  public data: T

  constructor(ctx: UIContext, builder: WrappedBuilder<[PromptParams<T>]>, data: T) {
    this.ctx = ctx
    this.content = new ComponentContent(this.ctx, builder, this);
    this.data = data
  }

  open() {
    this.ctx?.getPromptAction().openCustomDialog(this.content, new Object(this))
  }

  close() {
    this.ctx?.getPromptAction().closeCustomDialog(this.content)
  }
}

class VMessParams {
  public data: string = ""
  public index?: Index

  constructor(index: Index) {
    this.index = index
  }
}

@Builder
function buildVMessInput(params: PromptParams<VMessParams>) {
  Row() {
    Column() {
      Text("输入 VMess 链接")
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
      Text("仅支持 TCP 模式且服务端关闭强制 AEAD 认证")
        .fontSize(12)
        .fontWeight(FontWeight.Normal)
        .margin({ bottom: 20 })
      TextArea({ placeholder: "vmess://base64EncodingData" })
        .margin({ bottom: 20 })
        .height(50)
        .onChange((value) => {
          params.data.data = value
        })
      Row() {
        Button('取消').onClick(() => {
          params.close()
        })
        Button('确认').onClick(() => {
          params.data.index?.addVMessItem(params.data.data)
          params.close()
        })
      }.width("50%")
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .backgroundColor("#F0F0F0")
    .padding(10)
    .border({ radius: 5 })
  }
  .alignItems(VerticalAlign.Center)
  .width("90%")
}

@Entry
@ComponentV2
struct Index {
  @Local items: Array<VMessAuthData> = [];
  @Provider("pageStack") pageStack: NavPathStack = new NavPathStack();
  @Local selectedItem?: VMessAuthData = undefined;
  @Local started: boolean = false
  @Local setting: VMessSetting = PersistenceV2.connect(VMessSetting, "GlobalSetting", () => defaultVMessSetting())!
  private next: number = 0
  private want: Want = {
    deviceId: "",
    bundleName: "com.kilodim.steinsgate",
    abilityName: "SteinsGateAbility",
  };
  private kvStore?: distributedKVStore.DeviceKVStore = undefined;

  aboutToAppear(): void {
    kvManager.getKVStore("authdata", {
      createIfMissing: true,
      securityLevel: distributedKVStore.SecurityLevel.S2,
    }, (err: Error, store: distributedKVStore.DeviceKVStore) => {
      if (err) {
        hilog.error(0x0001, '[KV Sample]',
          `Failed to get KVStore. Code: ${err.name}, message: ${err.message}`);
        return;
      }
      this.kvStore = store
      this.kvStore.getEntries("/data/auth/", (err, data) => {
        for (let i = 0; i < data.length; i++) {
          let element = data[i];
          let authdata = JSON.parse(element.value.value as string) as VMessAuthData
          this.items.push(authdata)
          if (authdata.index >= this.next) {
            this.next = authdata.index + 1
          }
        }
        this.items.sort((a, b) => a.index - b.index)
      })
    })

  }

  @Builder
  pagesMap(name: string, param: object) {
    if (name == 'Setting') {
      Setting()
    } else if (name == 'Detail') {
      Detail({
        item: (param as VMessAuthData), changeAlias: (str) => {
          for (let index = 0; index < this.items.length; index++) {
            const element = this.items[index];
            if (element.index != (param as VMessAuthData).index) {
              continue
            }
            let newData = new VMessAuthData()
            newData.index = element.index
            newData.alias = str
            newData.address = element.address
            newData.port = element.port
            newData.id = element.id
            if (this.kvStore) {
              let authString = JSON.stringify(newData)
              this.kvStore.put(`/data/auth/${newData.index}`, authString)
            }
            this.items[index] = newData
            break
          }
        }
      })
    }
  }

  @Builder
  additionalButtons(idx: number) {
    Row() {
      Button() {
        SymbolGlyph($r("sys.symbol.checkmark"))
          .fontSize(35)
          .fontColor(["#FFFFFF"])
      }
      .backgroundColor("#00FF00")
      .type(ButtonType.Normal)
      .width(60)
      .height("100%")
      .onClick((event) => {
        for (let i = 0; i < this.items.length; i++) {
          if (idx == this.items[i].index) {
            this.selectedItem = this.items[i]
            break
          }
        }
      })

      Button() {
        SymbolGlyph($r("sys.symbol.trash"))
          .fontSize(35)
          .fontColor(["#FFFFFF"])
      }
      .backgroundColor("#FF0000")
      .type(ButtonType.Normal)
      .width(60)
      .height("100%")
      .onClick((event) => {
        let item: VMessAuthData | undefined = undefined
        let index = 0
        for (let i = 0; i < this.items.length; i++) {
          if (idx == this.items[i].index) {
            item = this.items[i]
            index = i
            break
          }
        }
        if (!item) {
          return
        }
        this.kvStore?.delete(`/data/auth/${item.index}`)
        this.items.splice(index, 1)
      })
    }
  }

  build() {
    Column() {
      Navigation(this.pageStack) {
        RelativeContainer() {
          List() {
            ForEach(this.items, (item: VMessAuthData) => {
              ListItem() {
                Row() {
                  Column() {
                    Text((this.selectedItem && item.index == this.selectedItem.index) ? `[*]` + item.alias :
                    item.alias)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                    Text(item.address + ":" + item.port)
                      .fontSize(10)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width("90%")
                  .margin({ left: "5%" })
                }
                .margin(10)
                .width("100%")
                .onClick(() => this.pageStack.pushPathByName("Detail", item))
              }
              .swipeAction({ end: this.additionalButtons(item.index) })
              .borderColor("#F0F0F0")
              .borderWidth({ bottom: 1 })
            }, (item: VMessAuthData) => `${item.alias}-${item.index}`)
          }
          .alignRules({
            "top": { "anchor": "__container__", "align": VerticalAlign.Top },
            "left": { "anchor": "__container__", "align": HorizontalAlign.Start },
            "right": { "anchor": "__container__", "align": HorizontalAlign.End },
            "bottom": { "anchor": "__container__", "align": VerticalAlign.Bottom },
          })

          Row() {
            Button({ type: ButtonType.Circle, stateEffect: false }) {
              SymbolGlyph($r(this.started ? "sys.symbol.paperplane_fill" : "sys.symbol.paperplane"))
                .fontSize(30)
                .fontColor(["#FFFFFF"])
            }
            .onClick(() => {
              if (this.items.length <= 0) {
                this.getUIContext().getPromptAction().showToast({
                  message: `请先添加 VMess 配置`
                })
                return
              }
              if (!this.selectedItem) {
                this.getUIContext().getPromptAction().showToast({
                  message: `请先选择一个 VMess 配置（左滑配置，点击 ✔ 按钮）`
                })
                return
              }
              if (!this.started) {
                let config: Record<string, Object> = {
                  "domainListURL": this.setting.domainListURL,
                  "ipListURL": this.setting.ipListURL,
                  "downloadDomainListViaProxy": this.setting.downloadDomainListViaProxy,
                  "downloadIPListViaProxy": this.setting.downloadIPListViaProxy,
                  "domainBlackList": this.setting.domainBlackList,
                  "ipBlackList": this.setting.ipBlackList,
                  "directDNS": this.setting.directDNS,
                  "proxyDNS": this.setting.proxyDNS,
                  "dnsProxyType": this.setting.dnsProxyType,
                  "ipProxyType": this.setting.ipProxyType,

                  "server": this.selectedItem!.address,
                  "port": this.selectedItem!.port,
                  "id": this.selectedItem!.id,
                }
                let configData = JSON.stringify(config)
                let path = this.getUIContext().getHostContext()!.filesDir + "/config.json"
                let file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
                fs.writeSync(file.fd, configData)
                fs.closeSync(file.fd)
                vpnExtension.startVpnExtensionAbility(this.want);
              } else {
                vpnExtension.stopVpnExtensionAbility(this.want);
              }
              this.started = !this.started
            })
            .width('70%')
            .fontSize(20)
            .margin(16)
            .width(50)
            .height(50)
          }
          .alignRules({
            "right": { "anchor": "__container__", "align": HorizontalAlign.End },
            "bottom": { "anchor": "__container__", "align": VerticalAlign.Bottom },
          })
          .width(100)
          .height(100)
        }
      }
      .navDestination(this.pagesMap)
      .menus([
        {
          value: "add",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
          action: () => this.onAddButtonPressed()
        },
        {
          value: "scan",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.line_viewfinder')),
          action: () => this.onScanButtonPressed()
        },
        {
          value: "setting",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
          action: () => this.pageStack.pushPathByName("Setting", undefined)
        },
      ])
      .title($r("app.string.EntryAbility_label"))
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .mode(NavigationMode.Auto)
    }
  }

  addVMessItem(data: string) {
    let protocolHeader = "vmess://"
    if (!data.startsWith(protocolHeader)) {
      this.getUIContext().getPromptAction().showToast({
        message: `协议连接必须以 vmess:// 开头`
      })
      return
    }
    try {
      let body = data.slice(protocolHeader.length)
      let base64 = new util.Base64Helper()
      let decodedData = base64.decodeSync(body)
      let decoder = new util.TextDecoder()
      let vmessData = decoder.decodeToString(decodedData)
      let vmessObject = JSON.parse(vmessData) as Record<string, string>
      let version = vmessObject["v"]
      if (version != "2") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持 v2 版本的 VMess 配置，当前版本为 ${version}`
        })
        return
      }

      let alias = vmessObject["ps"]
      let ipOrDomain = vmessObject["add"]
      let port = vmessObject["port"]
      let id = vmessObject["id"]
      let alterId = vmessObject["aid"]
      let net = vmessObject["net"]

      if (alterId != "0") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持 alterId 为 0 的 VMess 配置，当前 alterId 为 ${alterId}`
        })
        return
      }
      if (net != "tcp") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持通过 TCP 连接 VMess 服务器，当前配置为 ${net}`
        })
        return
      }
      let authdata: VMessAuthData = {
        index: this.next++,
        alias: alias,
        address: ipOrDomain,
        port: port,
        id: id,
      }
      if (this.kvStore) {
        let authString = JSON.stringify(authdata)
        this.kvStore.put(`/data/auth/${authdata.index}`, authString)
      }
      this.items.push(authdata)
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({
        message: `无法解析 vmess 链接内容，请确认链接内容是否为 JSON`
      })
    }
  }

  onAddButtonPressed() {
    let params = new PromptParams(this.getUIContext(), wrapBuilder(buildVMessInput), new VMessParams(this))
    params.open()
  }

  onScanButtonPressed() {
    let options: scanBarcode.ScanOptions =
      { scanTypes: [scanCore.ScanType.ALL], enableMultiMode: true, enableAlbum: true };
    try {
      scanBarcode.startScanForResult(getContext(this), options).then((result: scanBarcode.ScanResult) => {
        this.addVMessItem(result.originalValue)
      });
    } catch (error) {
    }
  }
}
