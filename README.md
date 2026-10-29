# 自建代理部署与客户端配置

本方案使用 Linux VPS 上的 Xray（VLESS + REALITY + Vision），搭配本机 Clash Verge Rev / Mihomo。安装脚本为同目录的 `setup-xray.sh`。不需要购买域名或申请证书。

本文和脚本提供配置模板与自动部署流程；是否可用仍取决于 VPS 网络、公网端口、安全组、客户端权限及版本，安装成功不代表已完成外部连通性测试。

## 1. 服务器准备

- 推荐干净的 Debian 12+ 或 Ubuntu 22.04+，使用 systemd，具备 root/sudo 权限及公网 IPv4；脚本也接受公网 IPv6，但本地必须能访问该 IPv6。
- 建议至少 1 核、1GB 内存，保证磁盘空间足够运行 Docker。512MB 可能较紧张。
- 服务器必须能访问系统软件源、GHCR 镜像仓库和选定的 REALITY 目标网站。
- 云控制台安全组放行入站 TCP 443（自定义端口时放行对应端口）。不需要为此方案开放公网 UDP 443；客户端 UDP 经 VLESS 连接传输。
- 443 不应被现有 Nginx、Apache 或其他进程占用。已有网站时选择其他端口，例如 8443。
- 准备 SSH 密钥登录，保留 SSH 的端口放行。脚本不会修改 SSH，也不会启用、清空防火墙。

选购 VPS 时看本地运营商实际延迟、丢包、晚高峰吞吐、月流量和退款政策。先短期试用，不以“家宽”“双 ISP”或某个欺诈分保证 AI 平台可用。出口 IP、服务支持地区和账号状态均可能影响访问结果。套餐价格、线路和费用以服务商当时公布的信息为准。

## 2. 一键部署

先在本机把脚本上传到服务器（替换地址、用户名；有自定义 SSH 端口时添加 scp 的 `-P` 参数）：

```bash
scp ./setup-xray.sh user@你的服务器公网IP:~/setup-xray.sh
ssh user@你的服务器公网IP
```

进入服务器后执行，填写 VPS **真实公网 IP**，不要把中文占位符直接复制执行：

```bash
sudo bash ~/setup-xray.sh --server-ip 你的服务器公网IP
```

如需自定义监听端口或伪装目标：

```bash
sudo bash ~/setup-xray.sh \
  --server-ip 你的服务器公网IP \
  --port 8443 \
  --sni www.apple.com
```

SNI 是 REALITY 目标网站名，不是需要你持有的域名。默认 `www.apple.com` 只是候选目标；脚本从 VPS 检查其 TLS 1.3 / HTTP/2 HTTPS 访问，失败则中止。这个检查不能代替实际 REALITY 握手测试；若默认目标不适合服务器线路，应选择符合 Xray 要求且从 VPS 可达的目标重新安装。不要使用证书不匹配的随意域名。

脚本会：

1. 检查 Linux、root 权限、端口和安装目录，安装 curl、Python、OpenSSL 等依赖；缺少 Docker 时安装发行版 `docker.io`，启动并设置 Docker 开机运行。
2. 拉取 Xray 镜像，将本次安装固定到镜像 digest。默认首次获取 `latest`；如需可复现的版本，使用 `--image ghcr.io/xtls/xray-core:指定版本标签` 或明确的 digest。
3. 自动生成 UUID、X25519 密钥和随机 short ID，不在终端打印密钥。
4. 生成配置并运行 Xray 自带的配置校验，随后只读挂载服务端配置启动容器，检查进程和监听端口。
5. 若 UFW / firewalld 已在运行，为其添加指定 TCP 端口规则；云安全组、自定义 nftables/iptables 等规则仍需自行放行。

服务端文件：

| 路径 | 用途 |
| --- | --- |
| `/etc/xray-reality/config.json` | 服务端配置，包含私钥 |
| `/etc/xray-reality/client.yaml` | 已填好节点凭据的 Mihomo 客户端配置 |
| `/etc/xray-reality/image.txt` | 本次实际使用的镜像 digest |

目录权限为 700，文件权限为 600。为读取 root 所有的私钥文件，容器显式使用 UID 0，移除全部 capabilities 后仅保留低端口绑定能力，并启用 no-new-privileges。容器名为 `xray-reality`，使用 Linux host 网络、崩溃/重启后自动恢复，并限制 Docker 日志大小。不要公开这些配置，也不要上传到不可信订阅转换网站。

脚本为**首次部署**设计：检测到已有目录或同名容器会中止，不会重新生成凭据覆盖现有用户。它会安装软件、拉取镜像、启用 Docker，并可能添加已启用防火墙的端口规则；这些系统变更不会在失败后自动撤销。

## 3. 取回并导入客户端配置

在服务器上将客户端配置复制给 SSH 用户，替换 `user` 为真实用户；如果以 root SSH 登录，可直接下载原文件，省略这一步：

```bash
sudo install -m 600 -o user -g "$(id -gn user)" \
  /etc/xray-reality/client.yaml /home/user/client.yaml
```

上述示例假设用户家目录为 `/home/user`，若不同请使用实际路径。在**本机**执行：

```bash
scp user@你的服务器公网IP:~/client.yaml ./client.yaml
```

在 Clash Verge Rev 中新建或导入 Local 配置，使用下载的 `client.yaml`，激活该配置。确保使用支持 VLESS REALITY 的 Mihomo 内核。

- 使用 Rule 模式，PROXY 组固定选择 VPS。
- 启用客户端所需的服务模式/管理员权限，再开启 TUN。配置内已经提供 TUN、自动路由、严格路由和 UDP/TCP 53 DNS 劫持；界面全局设置可能覆盖本地配置，应查看最终运行配置。
- 本机 `7890` 是 mixed HTTP/SOCKS 端口。若已被占用，修改 `mixed-port` 并同步终端环境变量。
- TUN 正常工作后可以关闭系统代理；同时启用并非必然冲突，按实际应用测试。
- 浏览器独立的安全 DNS、其他 VPN、虚拟机和容器网络可能影响接管效果。TUN 不等于绝对无泄露，也不保证代理停止后自动断网。

生成配置不使用远程 rule-provider 或 GEOSITE/GEOIP 数据库，避免失效链接和首次下载依赖。分流行为是：

- 回环、常见私网地址以及 `.local`、`.lan` 直连。
- 常见 AI 域名显式走 PROXY。
- `.cn` 及列出的百度、腾讯、淘宝、天猫、支付宝、京东、哔哩哔哩域名直连。
- **其余全部走 PROXY**，包括 GitHub 和 Docker 等服务。此配置不是覆盖所有国内网站的地理分流，未列出的国内网站也会消耗 VPS 流量。需要其他直连域名时，在 `MATCH,PROXY` 之前追加 `DOMAIN-SUFFIX,域名,DIRECT`。

DNS 使用 fake-ip。`dns.direct-nameserver` 为直连出口解析域名，使用 `223.5.5.5#DIRECT` 和 `119.29.29.29#DIRECT`，使直连网站的解析不依赖 VPS。默认 `dns.nameserver` 使用带 `#PROXY` 的 Cloudflare/Google DoH，通过 VPS 查询。`default-nameserver` 用于解析 DNS 服务器自身的域名，不是直连网站的通用备用 DNS。当前无需额外配置 `nameserver-policy`；需要为特定域名指定解析器时再添加。

要追加国内网站直连，在客户端 YAML 的 `rules:` 中、末尾 `MATCH,PROXY` **之前**添加规则，例如：

```yaml
  - DOMAIN-SUFFIX,douban.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - MATCH,PROXY
```

`DOMAIN-SUFFIX` 同时匹配域名本身及其子域名。保存并在 Clash Verge Rev 中重新加载配置，保持 Rule 模式；这些网站的连接走 DIRECT，直连出口的域名解析使用 `direct-nameserver`，不经过 VPS。网站若依赖其他资源域名，需要按连接面板的实际记录补充规则。脚本更新只影响后续生成的配置；已安装用户需在现有 `client.yaml` 的 `dns:` 下补充：

```yaml
  direct-nameserver:
    - '223.5.5.5#DIRECT'
    - '119.29.29.29#DIRECT'
```

无需为此重新运行安装脚本。顶层 `ipv6: false` 关闭 Mihomo 的相应 IPv6 行为，不等于关闭操作系统 IPv6；有严格 IPv6 隐私需求时，应另行检查系统网络配置和实际出口。

### iPhone / Shadowrocket（小火箭）导入

在本机以下载的 `client.yaml` 为输入，生成 VLESS 分享链接和二维码，无需重新部署服务器：

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements-shadowrocket.txt
python3 export-shadowrocket.py client.yaml --qr shadowrocket.png
```

输出 `shadowrocket.txt`（一条 `vless://` 链接）和 `shadowrocket.png`（同一链接的二维码），默认权限为 600。脚本不会覆盖已有文件；重新生成前移走旧输出或使用 `--output` / `--qr` 指定新路径。只需要链接时省略 `--qr`。有多个 VLESS 节点时，添加 `--name VPS` 选择节点。

在电脑上打开二维码，用 iPhone 上小火箭的扫码入口扫描；也可以把链接安全传给自己的 iPhone，复制后使用小火箭的剪贴板导入入口。选择导入的节点、开启连接并允许 iOS 添加 VPN 配置，再测试实际出口。

脚本仅支持本项目的 VLESS + REALITY + TCP 节点。链接字段依据 [Xray VLESS 分享链接提案](https://github.com/XTLS/Xray-core/discussions/716)，映射地址、端口、UUID、SNI、指纹、公钥、short ID 和 Vision flow。**仅导出节点，不包含 Mihomo 分流规则、DNS、TUN 设置**；这些需在小火箭内单独设置。链接和二维码都含节点凭据，不要公开或上传在线二维码工具。

`support-x25519mlkem768` 是 Mihomo 配置项，脚本不会把它作为未经确认的小火箭链接参数。请使用支持所需 REALITY 握手的小火箭版本；导入成功并不代表握手成功。如果电脑可用但手机认证失败，检查小火箭版本及握手兼容性，并结合服务端日志排查（见 Q3）。

## 4. 验证是否正常工作

服务器：

```bash
sudo docker ps --filter name=xray-reality
sudo docker logs --tail 100 xray-reality
sudo ss -ltnp
```

确认容器持续运行，指定端口监听，日志没有配置或握手错误。脚本内已经执行配置检查，也可手动复查：

```bash
sudo bash -c 'docker run --rm --user 0:0 \
  -v /etc/xray-reality/config.json:/etc/xray/config.json:ro \
  "$(cat /etc/xray-reality/image.txt)" run -test -c /etc/xray/config.json'
```

本机先测试显式代理（不依赖 TUN）：

```bash
curl --fail --show-error --max-time 20 \
  --proxy http://127.0.0.1:7890 https://www.cloudflare.com/cdn-cgi/trace
```

输出的 `ip=` 应为 VPS 的出口 IP（有 NAT 时不一定等于填写的入站 IP）。再在 TUN 开启且终端未设置其他代理环境变量时执行不带 `--proxy` 的同一请求，确认也走 VPS，并在客户端连接面板查看规则命中。

如果显式代理能通而 TUN 不通，优先检查客户端权限、配置合并和路由；如果两者都不通，检查安全组、防火墙、UUID、公钥、short ID、SNI、系统时间和服务器日志。网页返回 403 不一定是代理故障；先区分隧道连接失败和目标平台拒绝访问。

Docker daemon、容器、远端 SSH 进程等可能需要自己的代理配置，不能仅凭本机 curl 成功就认定全部工具已经接管。普通终端工具还可显式设置：

```bash
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
export ALL_PROXY=socks5h://127.0.0.1:7890
export NO_PROXY=localhost,127.0.0.1,::1
```

环境变量是否被采用取决于应用；HTTP 代理请求仍由 Mihomo 规则分流。

## 5. 重启、失败恢复与卸载

修改服务端配置前先备份，校验通过后重启：

```bash
sudo docker restart xray-reality
```

如果脚本在目录创建前失败，排除网络或端口问题后可重新运行。目录创建后失败，先检查保留下来的文件和日志，不要直接删除凭据；若容器已经存在，使用上面的诊断命令。只有确定要放弃当前安装并重新生成全部凭据时，才执行以下卸载步骤。

**以下命令会删除容器和全部节点凭据，旧客户端将失效：**

```bash
sudo docker rm -f xray-reality
sudo rm -rf /etc/xray-reality
```

如已将临时 `client.yaml` 复制到 SSH 用户目录，用完后删除该临时副本。卸载不会移除 Docker、镜像或防火墙规则；根据需要单独清理。更新 Xray 前备份配置并在新版本上校验，不要为升级直接重跑首次安装脚本。

## 6. 常见问题（QA）

### Q1：本机无法连接服务器的 443 端口怎么办？

在本机 macOS 终端测试 TCP 连通性（将示例 IP 替换成自己的服务器公网 IP）：

```bash
nc -zv -G 3 192.220.37.170 443
```

Linux 上可使用 `nc -zv -w 3 你的服务器公网IP 443`。如果连接超时或被拒绝，先确认服务器上的 `xray-reality` 正常运行、443 正在监听，并检查云安全组和服务器防火墙。单次连接失败不能直接认定是运营商拦截；本地电信等运营商线路也可能存在端口过滤，可换手机热点等网络交叉测试。

确认放行且服务正常后，若当前线路仍无法连接 443，可尝试改为 8443 等未占用端口。首次安装时直接使用第 2 节的 `--port 8443` 参数；已经安装的实例按以下步骤修改，不要重新运行首次安装脚本：

1. 在云安全组和已启用的服务器防火墙中放行入站 TCP 8443，确认该端口没有被其他服务占用。
2. 在服务器上备份并编辑服务端配置：

   ```bash
   sudo cp -p /etc/xray-reality/config.json /etc/xray-reality/config.json.bak
   sudo nano /etc/xray-reality/config.json
   ```

   将 `inbounds` 中对应 VLESS 入站的 `port` 从 `443` 改为 `8443`。保留 `realitySettings.target` 中目标网站的 `:443`，它是伪装目标端口。

3. 使用第 4 节的 `run -test` 命令校验配置；通过后重启并确认新端口监听：

   ```bash
   sudo docker restart xray-reality
   sudo docker logs --tail 50 xray-reality
   sudo ss -ltnp 'sport = :8443'
   ```

   当前容器使用 `--network host`，监听端口由 Xray 配置决定，无需修改 Docker 的 `-p` 映射。编辑时保留原配置文件路径；如果编辑器保存时替换了文件，导致容器仍读取旧配置，应先停止容器再启动以重新挂载文件：`sudo docker stop xray-reality`，然后执行 `sudo docker start xray-reality`。

4. 将本机 Mihomo 配置中 `proxies` 下 VPS 节点的 `port` 同步改为 `8443`，保存并重新加载配置。服务器保存的 `/etc/xray-reality/client.yaml` 也应同步修改，方便后续下载；本机的 `mixed-port: 7890` 保持不变。
5. 在本机执行 `nc -zv -G 3 你的服务器公网IP 8443`，连通后再按第 4 节测试代理。确认新端口可用后，可以移除旧的 443 放行规则（若没有其他服务使用它）。TCP 连通只说明端口可达，还需验证 REALITY 握手及实际代理访问。

### Q2：服务器购买后，安全组需要开放哪些端口？

在云服务商控制台找到绑定到该服务器的安全组或云防火墙，添加允许入站的规则：

| 用途 | 协议 | 目标端口 | 来源 |
| --- | --- | --- | --- |
| SSH 管理 | TCP | 实际 SSH 端口，通常为 22 | 自己的管理公网 IP 或网段 |
| Xray 代理 | TCP | 默认 443，改端口后如 8443 | 需要连接代理的客户端公网 IP 或网段 |

若客户端公网 IP 经常变化，需相应更新来源范围；需要任意 IPv4 客户端连接时可设为 `0.0.0.0/0`。使用 IPv6 时还要配置对应的 IPv6 来源规则。注意不要在修改规则时移除当前 SSH 登录所需的权限。

脚本只能为已运行的 UFW / firewalld 添加端口规则，**不会自动配置云安全组**。云安全组和服务器防火墙都必须放行实际监听端口。此方案不需要对公网开放客户端本地的 7890 端口，也不需要额外开放公网 UDP 443/8443。

### Q3：端口可达，但 Clash 提示 `REALITY authentication failed` 怎么办？

`nc` 成功只说明 TCP 端口可达，不代表 REALITY 握手成功。若 Clash 日志出现：

```text
connect error: REALITY authentication failed
```

同时 Xray 出现：

```text
REALITY: processed invalid connection ... authentication failed or validation criteria not met
```

先核对两端实际运行配置的公私钥对应关系、short ID、SNI、UUID、端口及系统时间。如果这些均正确，还需要检查 Mihomo 与新版 Xray 的 REALITY 握手兼容性。

本项目实际排查中，**Xray 26.10.21 + Mihomo v1.19.32** 在服务端设置 `minClientVer` 后仍认证失败；保留该设置，并在客户端开启 `support-x25519mlkem768` 后连接成功。当前脚本会同时生成以下两项：

- 服务端 `config.json`：在 `inbounds[].streamSettings.realitySettings` 下设置 `"minClientVer": "1.8.2"`。Mihomo v1.19.32 的 REALITY 握手版本标识为 `1.8.2`，与其发布版本号不同；此设置调整版本门槛，仍保留密钥和 short ID 校验。
- 客户端 `client.yaml`：在 VPS 节点的 `reality-opts` 下设置 `support-x25519mlkem768: true`，启用 X25519-MLKEM768 密钥交换，并保留 `client-fingerprint: chrome`。

已有安装无需重新运行脚本，手动补充上述字段即可。客户端配置位置示例（保留自己的公钥和 short ID）：

```yaml
    client-fingerprint: chrome
    reality-opts:
      public-key: "原有公钥"
      short-id: "原有 short ID"
      support-x25519mlkem768: true
```

服务端修改前先备份，增加 `minClientVer` 后使用第 4 节的 `run -test` 命令校验；通过后执行 `sudo docker stop xray-reality`，再执行 `sudo docker start xray-reality`，确保重新挂载配置。客户端保存后重新加载配置并重启内核，确认 PROXY 选择 VPS，再测试：

```bash
curl -v --max-time 15 \
  --proxy http://127.0.0.1:7890 \
  https://1.1.1.1/cdn-cgi/trace
```

返回 `ip=` 且为 VPS 出口说明该次代理请求成功。若仍失败，将 Clash 的日志等级临时设为 Debug，查看同一次请求的客户端和服务端日志；排查结束后恢复常规日志等级。这是上述版本组合的实际解决记录，不保证涵盖所有 REALITY 认证失败原因。

相关依据：[Mihomo v1.19.32 REALITY 实现](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/component/tls/reality.go)、[Mihomo TLS / REALITY 配置说明](https://wiki.metacubex.one/config/proxies/tls/)、[客户端版本兼容问题记录](https://github.com/MetaCubeX/mihomo/issues/3039)。

参考：[Xray REALITY 文档](https://xtls.github.io/en/config/transports/reality.html)、[Mihomo TUN 文档](https://wiki.metacubex.one/config/inbound/tun/)、[Mihomo 规则集文档](https://wiki.metacubex.one/config/rule-providers/)。
