# Mundo Proxy 本地安装脚本

Mundo Connect 专用安装脚本，项目主页：https://github.com/Mundo-Connect

脚本源码使用 GPL v3 授权。这里不下载 release，安装时请把已编译好的 `mundoproxy` 和 `install.sh` 放在同一个目录。

## 使用

```bash
chmod +x install.sh mundoproxy
sudo ./install.sh
```

安装后使用：

```bash
mp
mp info
mp config
mp restart
mp status
mp log
mp error-log
mp uninstall
```

配置路径：

```text
/etc/mundoproxy/config.json
```

URI 路径：

```text
/etc/mundoproxy/client.uri
/etc/mundoproxy/client-ech.uri
```

MundoCA 证书文件路径：

```text
/etc/mundoproxy/mundo-ca/root-ca-certificate.b64
/etc/mundoproxy/mundo-ca/client-certificate.b64
/etc/mundoproxy/mundo-ca/client-public-key.b64
/etc/mundoproxy/mundo-ca/client-keypair.b64
```

## 协议输入

输入格式是 `协议+传输`。只输入传输时，默认使用 `mx` 协议。直接回车默认 `mx+mundordp`。

`mx` 支持：

- `mx+mc1`
- `mx+mundordp`
- `mx+xhttp`
- `mx+grpc`
- `mx+ws`

其他协议只支持 `mc1` 和 `mundordp`：

- `trojan+mc1`
- `trojan+mundordp`
- `vless+mc1`
- `vless+mundordp`
- `vmess+mc1`
- `vmess+mundordp`
- `anytls+mc1`
- `anytls+mundordp`

`mx+mc1`、`mx+xhttp`、`mx+ws` 会同时生成普通 URI 和 ECH URI。

`mc1`、`xhttp`、`ws` 支持 CDN。配置时可以选择填写 CDN 优选地址；启用后 URI 使用优选地址连接，SNI/Host 仍使用原域名。

## 认证方式

配置时会先选择是否启用 MundoCA 证书式认证，然后再填写服务器域名。

默认不启用 MundoCA，继续使用原有 UUID、token 或 password 认证方式。

启用 MundoCA 后，节点配置写入 `streamSettings.*Settings.mundoCA.caCertificate`，节点侧只校验证书，不再依赖 UUID、token 或 password 作为用户认证。URI 会携带客户端证书参数 `mundoCA`，客户端私钥由客户端本地保存的密钥对提供。

启用 MundoCA 时可以选择一键生成 Root CA、客户端 SM2 公私钥和客户端证书。脚本首次生成时会输出完整客户端密钥对：

```text
Base64(privateKey[32] || publicKey[65])
```

其中 `privateKey` 是 32 字节 SM2 私钥，`publicKey` 是 65 字节非压缩 SM2 公钥，首字节为 `0x04`。请在第一次输出时妥善保存该密钥对，并导入客户端。

也可以选择手动填写客户端公钥。手动公钥必须是标准 Base64 编码的 65 字节非压缩 SM2 公钥，脚本会使用该公钥签发客户端证书；客户端私钥需要由客户端本地保存。

Root CA 证书会自动生成并保存在 `/etc/mundoproxy/mundo-ca/root-ca-certificate.b64`，客户端证书保存在 `/etc/mundoproxy/mundo-ca/client-certificate.b64`。私钥和密钥对文件会使用 `600` 权限保存。

## 证书

服务器地址可以留空，默认使用 `apple.com` 并生成自签名证书。

填写域名时，可以选择用 certbot 申请证书，默认不申请，使用自签名证书。

certbot 使用 standalone 模式，需要服务器 80 端口可用。申请失败会自动改用自签名证书。

填写 IPv4 或 IPv6 地址时直接使用自签名证书，URI 不写 SNI/Host。

## 服务

Debian/RHEL 使用 systemd，Alpine 使用 OpenRC。

安装后默认开启开机启动。可以在 `mp` 菜单里开启或关闭，也可以使用：

```bash
mp enable-autostart
mp disable-autostart
```

## Nginx 反代

默认不启用反代。

启用反代后，Mundo Proxy 监听 `127.0.0.1:后端端口`，Nginx 对外监听端口并转发。`mundordp` 不使用 Nginx 反代。
