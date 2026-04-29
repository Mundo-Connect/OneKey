# Mundo Proxy 一键本地部署脚本

这个目录是 Mundo Connect 专用的 Mundo Proxy 内核安装脚本。

项目主页：https://github.com/Mundo-Connect

脚本本身基于 GPL v3 授权。这里不做在线 release 检索，也不会从 GitHub 下载内核；安装时默认当前目录已经放好了静态编译的 `mundoproxy` 内核文件。

## 功能

- 本地解压部署：`install.sh` 和已编译的 `mundoproxy` 放在同一个目录后直接安装。
- 安装后输入 `mp` 会打开管理脚本；`mundoproxy` 是内核二进制命令。
- 支持一键安装基础依赖、生成配置、启动/停止/重启服务、查看日志、卸载删除。
- 安装过程会把内核安装到 `/usr/local/bin/mundoproxy`，同时在 `/etc/mundoproxy/bin/mundoproxy` 保留一份本地副本；安装脚本会放到 `/etc/mundoproxy/bin/install.sh`，管理快捷指令会安装到 `/usr/local/bin/mp`。
- 证书不可用或未配置受信任证书时，会自动生成自签名证书，不会因为证书申请失败中断安装。
- 支持 Debian、RHEL、Alpine 一键安装依赖。Debian 使用 `apt`，RHEL 使用 `dnf` 或 `yum`，Alpine 使用 `apk`。
- 可选安装 Nginx 反代。默认不反代；只有非 RDP 传输且用户选择反代时，脚本才会安装 Nginx 并生成 `/etc/nginx/conf.d/mundoproxy.conf`。

## 协议

默认协议是 Mundo X，也就是配置里的 `mx`。

推荐组合是：

- Mundo X + Mundo Connect 1 (`mx+mc1`)
- Mundo X + Mundo Connect RDP Protocol (`mx+mundordp`)

可选传输协议：

- Mundo Connect 1 (`mc1`)
- Mundo Connect RDP Protocol (`mundordp`)
- XHTTP (`xhttp`)
- gRPC (`grpc`)
- WebSocket (`ws`)

其中 `mx+WebSocket`、`mx+mc1`、`mx+xhttp` 可以过 CDN。脚本会为这三种组合提供 `Mundo Connect + ECH` 模式，生成 URI 时只额外加入 `echMode=always`；普通 `Mundo Connect` 模式会写入 `echMode=off`。

其他协议例如 Trojan、VLESS、VMess、AnyTLS 不是这个安装脚本的推荐路径；如果手动使用，只建议搭配 Mundo Connect 1 或 Mundo Connect RDP Protocol，不建议使用其他传输。

## Nginx 反代

默认情况下，Mundo Proxy 直接监听对外端口。

如果启用反代，Mundo Proxy 只监听 `127.0.0.1:内部端口`，Nginx 监听对外端口并转发到内核。反代只支持非 `mundordp` 传输。

Mundo Connect 1 默认会启用 H3；但 Nginx 反代不能承载这个路径，所以反代模式会自动把 Mundo Connect 1 设置为 H2，并关闭 H3 上传。

## 使用

把编译好的内核和脚本放在同一个目录：

```bash
chmod +x install.sh mundoproxy
sudo ./install.sh
```

安装完成后：

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

生成的服务端配置在：

```text
/etc/mundoproxy/config.json
```

生成的客户端导入 URI 在：

```text
/etc/mundoproxy/client.uri
```

## 证书行为

如果输入的是域名，脚本会用该域名生成自签名证书。

如果输入的是 IP，或没有可用域名，脚本会生成一个看起来像普通电脑名的随机自签名证书，并提示当前使用的是自签名证书。

Mundo Connect RDP Protocol 会优先使用当前 TLS 证书配置；如果证书不适合 RDP 的 RSA/TLS 行为，内核会回退到自动生成证书。
