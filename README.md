# SteinsGate

**A Lightweight VPN Client for HarmonyOS 5.0**

***Powered by Cangjie Programming Language***

Secure your network traffic with a modern VPN solution supporting VMESS protocols, designed specifically for HarmonyOS devices.

# Key Features
- **Lightweight Core**
- **Full Protocol Support:** TCP/UDP traffic proxying with VMESS encryption
- **DNS Protection:** Secure DNS queries through encrypted tunnels

# App Preview
![s1](/images/screen-1.jpeg "Screen-1")

# Building Instructions
## Prerequisites
- DevEco Studio 5.0.3
- HarmonyOS 5.0

## Configuration
Modify module.json in your SDK directory:
```json
// Path: ${DevEco Studio Installation Path}/sdk/default/hms/toolchains/modulecheck/module.json
// Path on Windows: C:\Program Files\Huawei\DevEco Studio\sdk\default\hms\toolchains\modulecheck\module.json
"type": {
  "description": "Indicates the type of the extension.",
  "type": "string",
  "enum": [
    "vpn",  // Add this entry
    "form",
    "workScheduler",
    ...
  ]
}
```
## Build Process
Click `Build` or `Run`  in your DevEco Studio.

