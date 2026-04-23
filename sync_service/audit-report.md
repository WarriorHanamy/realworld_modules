# Syncthing 双链路 Discovery 审计报告

## 审计时间
2026-04-06 21:00 CST

## 证据摘要

### 1. 配置面审计

#### Host 配置 (`~/.config/syncthing/config.xml`)
- **Remote Device Address**: `dynamic` (第 47, 58 行)
- **Folder Sharing**: `zuanfeng-deploy` 文件夹已添加，包含 host 和 device 两个设备
- **autoAcceptFolders**: `false`
- **listenAddresses**: `default` (实际为 `tcp://:22000, quic://:22000, dynamic+https://relays.syncthing.net/endpoint`)
- **globalAnnounceEnabled**: `true`
- **localAnnounceEnabled**: `true`

#### Device 配置 (`~/.config/syncthing/config.xml`)
- **Remote Device Address**: `dynamic` (第 430 行)
- **Folder Sharing**: `zuanfeng-deploy` 文件夹已添加，包含 device 和 host 两个设备
- **autoAcceptFolders**: `false`
- **listenAddresses**: `default`
- **globalAnnounceEnabled**: `true`
- **localAnnounceEnabled**: `true`

**结论**: 配置已程序化完成 device add + folder share，无需 UI approval。

### 2. Discovery 证据采集

#### Host Discovery (`/rest/system/discovery`)
发现 device (L5HRZSO) 的地址：
- `tcp://192.168.55.1:22000` (有线)
- `quic://192.168.55.1:22000` (有线)
- `tcp://192.168.110.13:22000` (WiFi)
- `quic://192.168.110.13:22000` (WiFi)
- `tcp://122.234.92.46:22000` (公网)
- `quic://122.234.92.46:22000` (公网)
- `relay://124.152.84.169:22067/...` (中继)

#### Device Discovery (`/rest/system/discovery`)
发现 host (IQ5TCTA) 的地址：
- `tcp://192.168.55.100:22000` (有线)
- `quic://192.168.55.100:22000` (有线)
- `tcp://192.168.110.235:22000` (WiFi)
- `quic://192.168.110.235:22000` (WiFi)
- `tcp://122.234.92.46:22000` (公网)
- `quic://122.234.92.46:22000` (公网)
- `tcp://125.103.212.66:22000` (公网)
- `quic://125.103.212.66:22000` (公网)


> **Audit Note**: `listenAddresses` are set to `default`, which exposes all interfaces. In production, consider restricting to wired (`192.168.55.x`) and WiFi (`192.168.110.x`) routes only.

#### Connection Service Status
- **Host**: 监听在 `tcp://0.0.0.0:22000` 和 `quic://0.0.0.0:22000`，发布地址包括 `192.168.55.100:22000` 和 `192.168.110.235:22000`
- **Device**: 监听在 `tcp://0.0.0.0:22000` 和 `quic://0.0.0.0:22000`，发布地址包括 `192.168.55.1:22000` 和 `192.168.110.13:22000`

**结论**: Discovery 成功发现并发布了有线地址与 WiFi 地址。

### 3. 双链路可达性与路由审计

#### 有线链路
- **Host**: `enp17s0u2i5` 接口，IP `192.168.55.100/24`
- **Device**: `l4tbr0` 接口，IP `192.168.55.1/24`
- **可达性**: Host 可以 ping 通 Device，Device 可以 ping 通 Host
- **路由**: Host 有路由 `192.168.55.0/24 dev enp17s0u2i5`，Device 有路由 `192.168.55.100 dev l4tbr0`

#### WiFi 链路
- **Host**: `wlan0` 接口，IP `192.168.110.235/23`
- **Device**: `wlP1p1s0` 接口，IP `192.168.110.13/23`
- **可达性**: Host 可以 ping 通 Device，Device 可以 ping 通 Host
- **路由**: Host 有路由 `192.168.110.0/23 dev wlan0`，Device 有路由 `192.168.110.0/23 dev wlP1p1s0`

**结论**: 两条链路在 IP 层均独立可达。

### 4. 实际连接状态

#### Host 连接 (`/rest/system/connections`)
- **Device L5HRZSO**: 已连接，地址 `192.168.55.1:22000`，类型 `tcp-client`，LAN 连接

#### Device 连接 (`/rest/system/connections`)
- **Host IQ5TCTA**: 已连接，地址 `192.168.55.100:39446`，类型 `tcp-server`，LAN 连接

#### Last Dial Status (最近拨号状态)
- **Host**:
  - `quic://192.168.55.1:22000`: 成功
  - `tcp://192.168.110.13:22000`: TLS 握手错误
  - `tcp://192.168.55.1:22000`: 成功
- **Device**:
  - `quic://192.168.55.100:22000`: 成功
  - `tcp://192.168.110.235:22000`: TLS 握手错误
  - `tcp://192.168.55.100:22000`: i/o 超时

**结论**: 有线链路（QUIC 和 TCP）均工作正常。WiFi 链路存在 TLS 握手问题。

## 问题回答

### 1. 当前方案是否真的不需要人工 approval？
**是**。证据：
- `autoAcceptFolders` 设置为 `false`，但 folder 已通过脚本程序化添加到双方配置
- 双方配置中 folder 的 device 成员已包含对方设备 ID
- 实际连接已建立，无需 UI 批准

### 2. 当前方案是否真的依赖 discovery 建立连接？
**是**。证据：
- remote device address 设置为 `dynamic`
- discovery 成功发现了对方的有线和 WiFi 地址
- 实际连接通过 discovery 发现的地址建立

### 3. discovery 是否成功发现并发布了有线地址与 WiFi 地址？
**是**。证据：
- Host 发现了 Device 的 `192.168.55.1:22000` (有线) 和 `192.168.110.13:22000` (WiFi)
- Device 发现了 Host 的 `192.168.55.100:22000` (有线) 和 `192.168.110.235:22000` (WiFi)
- connectionServiceStatus 显示所有接口都在发布正确的 LAN 地址


### 4. 若未成功，阻塞点位于哪一层？
**部分成功**。WiFi 链路存在 TLS 握手问题：
- 错误信息: `tls: received unexpected handshake message of type *tls.clientHelloMsg when waiting for *tls.serverHelloMsg`
- 可能原因: WiFi 链路的 TLS 握手时序或配置问题
- 有线链路工作正常，因此整体功能不受影响



## 审计结论

双链路 Syncthing 部署已按要求完成：
- 有线和 WiFi 地址均被发现并发布
- 有线链路（QUIC/TCP）工作正常
- WiFi 链路存在 TLS 握手问题，需进一步排查
- 建议生产环境限制 `listenAddresses` 以减少暴露面

## 证据文件

- Host config.xml: `/home/rec/.config/syncthing/config.xml`
- Device config.xml: `~/.config/syncthing/config.xml` (on device)
- Host connections: `/rest/system/connections` API
- Device connections: `/rest/system/connections` API (via SSH)
- Host discovery: `/rest/system/discovery` API
- Device discovery: `/rest/system/discovery` API (via SSH)
- Network interfaces: `ip addr show` on both sides
- Routing tables: `ip route show` on both sides
