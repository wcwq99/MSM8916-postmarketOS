# MSM8916 postmarketOS 多板型镜像

[![Validate device trees](https://github.com/baiyunquan/MSM8916-postmarketOS/actions/workflows/validate.yml/badge.svg)](https://github.com/baiyunquan/MSM8916-postmarketOS/actions/workflows/validate.yml)

本仓库把 `debian-dtbs` 中的 MSM8916 设备树移植到 `postmarketOS` 的
`linux-postmarketos-qcom-msm8916` 内核构建流程中。最终只生成一套 split
boot/root 镜像，boot 分区同时携带 19 款 DTB；具体型号通过
`/boot/extlinux/extlinux.conf` 中的 `fdt` 行选择。

当前验收范围是 CI、19 款 DTB 编译/结构检查、boot 镜像内容检查和校验和检查。
除 postmarketOS 原生支持的板型外，尚未宣称已完成真机启动、调制解调器、Wi-Fi、
LED、按键、屏幕或充电功能验证。

## 设计与来源

- `pmos-example` 固定到已成功生成 modem-ready postmarketOS 构件的提交，用作
  pmbootstrap、固件和 lk1st/qhypstub 构建参考。
- `debian-dtbs` 固定到包含完整 19 款板型清单的提交，提供 14 个可重编译 DTS
  以及 2 个仅有二进制形式的 DTB。
- `thwc-ufi001c`、`thwc-uf896`、`yiming-uz801v3` 直接使用固定内核标签
  `v6.12.1-msm8916` 中的原生设备树。
- SP970 的旧 UART pinctrl 引用、MiFi 的 `id-gpios` 属性和 MF32 的 LED/USB
  引用在 staging 时通过最小兼容补丁适配到该内核标签；参考 submodule 不被修改。
- `patches/pmaports-device-zhihe-nonfree.patch` 把固定版 pmaports 里
  `device-zhihe-generic` 的元数据对齐到上游 `e5536561`。只有内核在本地编译，其余
  包都来自滚动的 edge 二进制镜像，而 pmbootstrap 依据本地 APKBUILD 决定要装哪些
  包；上游删掉 `-nonfree-firmware` 子包后，不打这个补丁 apk 就会因为镜像里已经
  没有该包而报 `unable to select packages`。两个固件包已被上游提升为主包依赖，
  功能不受影响。

构建固定使用以下上游版本，避免 GitHub Actions 每次跟随上游 `main` 漂移：

| 组件 | 固定版本 |
|---|---|
| pmbootstrap | `b2bf3539cd92acce4ab187167581168e845f3e7e` |
| pmaports | `1ce58c5ae1b7573c6471959c4ab406391eefb103` |
| MSM8916 内核 | `v6.12.1-msm8916` |
| pmOS 参考 | `fe4289d03aaf95fd2325e81b12ff02b55b70e868` |
| Debian DT 参考 | `ef731fa31eefdf5730f87e31d9aecafe61159ed2` |

## 支持的板型

默认选择 `thwc-ufi003`。完整映射也会写入 boot 镜像根目录的
`/boards.conf`，并随发布包保存为 `boards.conf`。

| 板型 ID | DTB | 来源 |
|---|---|---|
| `fy-mf800` | `msm8916-fy-mf800.dtb` | Debian 二进制 DTB |
| `generic-m9s` | `msm8916-generic-m9s.dtb` | Debian DTS |
| `generic-mf68e` | `msm8916-generic-mf68e.dtb` | Debian DTS |
| `generic-uf02` | `msm8916-generic-uf02.dtb` | Debian DTS |
| `gexing-sp970` | `msm8916-gexing-sp970.dtb` | Debian DTS |
| `gexing-sp970v10` | `msm8916-gexing-sp970v10.dtb` | Debian DTS |
| `gexing-sp970v11` | `msm8916-gexing-sp970v11.dtb` | Debian DTS |
| `jz01-45-v33` | `msm8916-jz01-45-v33.dtb` | Debian 二进制 DTB |
| `thwc-jz02v10` | `msm8916-thwc-jz02v10.dtb` | Debian DTS |
| `thwc-qrzl903` | `msm8916-thwc-qrzl903.dtb` | Debian DTS |
| `thwc-uf896` | `msm8916-thwc-uf896.dtb` | 内核原生 |
| `thwc-ufi001b` | `msm8916-thwc-ufi001b.dtb` | Debian DTS |
| `thwc-ufi001c` | `msm8916-thwc-ufi001c.dtb` | 内核原生 |
| `thwc-ufi003` | `msm8916-thwc-ufi003.dtb` | Debian DTS |
| `thwc-ufi103s` | `msm8916-thwc-ufi103s.dtb` | Debian DTS |
| `thwc-w001` | `msm8916-thwc-w001.dtb` | Debian DTS |
| `ufi-mf32` | `msm8916-ufi-mf32.dtb` | Debian DTS |
| `xinxun-wf2` | `msm8916-xinxun-wf2.dtb` | Debian DTS |
| `yiming-uz801v3` | `msm8916-yiming-uz801v3.dtb` | 内核原生 |

## 构建与发布

在 GitHub 仓库的 **Actions → Build postmarketOS multi-board image → Run
workflow** 手动触发完整构建，runner 固定为 `ubuntu-24.04`（原因见
[本地 x86 构建](#本地-x86-构建)）。同一套流程也可以用
`scripts/build-local.sh` 在本地跑。工作流会：

1. 检出所有固定 submodule；
2. 为 pmaports 内核包加入 19 款 DTB 并从源码重建内核；
3. 生成带 ModemManager/QMI/QRTR 的 console postmarketOS split 镜像；
4. 把 extlinux 默认 `fdt` 改为 `/dtbs/qcom/msm8916-thwc-ufi003.dtb`；
5. 检查 boot 镜像内 19 个 DTB 的 `compatible`，生成 `SHA256SUMS`；
6. 同时上传 Actions Artifact，并创建预发布 GitHub Release。

发布包 `postmarketos-msm8916-multiboard.tar.gz` 的主要内容：

```text
boards.conf
SHA256SUMS
source-versions.txt
dtbs/                              # 19 个经过检查的 DTB
bootloaders/
  hyp.mbn
  tz.mbn
  aboot-thwc-ufi001c.mbn
  aboot-thwc-uf896.mbn
  aboot-yiming-uz801v3.mbn
export/
  zhihe-generic-boot.img           # ext2 /boot，包含全部 19 个 DTB
  zhihe-generic-root.img           # btrfs rootfs
  boot.img
  initramfs
  vmlinuz
```

镜像默认账户为 `user`，初始密码为 `147147`。首次启动后应立即修改密码。

## 选择设备树

首次刷写前，建议在 Linux 主机上修改 boot 镜像：

```sh
sudo mkdir -p /mnt/pmos-boot
sudo mount -o loop export/zhihe-generic-boot.img /mnt/pmos-boot
sudo sed -i \
  's#^[[:space:]]*fdt .*#\tfdt /dtbs/qcom/msm8916-gexing-sp970v11.dtb#' \
  /mnt/pmos-boot/extlinux/extlinux.conf
sudo umount /mnt/pmos-boot
```

把示例 DTB 文件名替换为上表对应项。系统已经可以启动时，也可以直接修改
`/boot/extlinux/extlinux.conf`，然后重启。选择错误的 DTB 可能导致无法启动或外设
工作异常。

## 刷写注意事项

刷写 bootloader、分区表、`tz` 或 `hyp` 有变砖风险。开始前至少完成整机 EDL
备份，并阅读 postmarketOS 的
[Zhihe 系列设备页面](https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe))。
上游特别警告不要把 DragonBoard 的 `tz` 与原厂 `hyp` 混用，也不再建议无差别
替换 `rpm`/`sbl1`。

此发布包中的系统镜像是多板型的，但 lk1st 并非自动识别全部 19 款硬件。只提供
上游明确存在设备节点的 UFI001C、UF896、UZ801 V3 三个 aboot 变体；其他板型
应保留已知可用的 bootloader，或在真机确认兼容关系后选择最接近的变体。

官方推荐的 split 方案是把 `zhihe-generic-boot.img` 写入可用的 boot/cache
分区，把转换为 Android sparse 格式的 root 镜像写入 system 或 userdata。具体分区
因设备而异，仓库不会自动执行刷写。

## 本地 x86 构建

`scripts/build-local.sh` 在本地 x86_64 主机上复刻整条 CI 流程：同样的固定上游、
同样的步骤顺序、同样的产物，aarch64 rootfs 通过 qemu-user-static 模拟组装。

### 主机要求

**QEMU 必须 ≥ 8。** Ubuntu 22.04 自带的 qemu-user-static 6.2 会让 aarch64 的
`postmarketos-mkinitfs`（Go 二进制）在 binfmt 模拟下直接崩溃，这正是托管 CI 长期
构建失败的原因。Debian 13 和 Ubuntu 24.04 均满足要求。脚本会读取 binfmt_misc
实际注册的解释器并校验版本，而不是看 `PATH` 里恰好排在前面的那个。

以普通用户运行，需要 sudo 权限；pmbootstrap 拒绝以 root 身份运行。

```sh
sudo apt-get install -y \
  binfmt-support binutils-aarch64-linux-gnu btrfs-progs build-essential \
  device-tree-compiler e2fsprogs gcc-arm-none-eabi git kpartx multipath-tools \
  openssl parted python3 python3-cryptography qemu-user-static rsync tar unzip \
  util-linux
```

### 运行

```sh
scripts/build-local.sh              # 产物写入 ./artifacts
scripts/build-local.sh /srv/out     # 或指定输出目录
```

可用环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `MSM8916_STATE_DIR` | `~/.cache/msm8916-pmos` | pmbootstrap 源码、pmaports、work 目录与 export 的存放位置 |
| `JOBS` | `nproc` | 编译并行度 |
| `PMB_WORK` / `PMB_APORTS` / `PMB_EXPORT` | 见上 | 单独覆盖某个路径 |
| `PMBOOTSTRAP_REV` / `PMAPORTS_REV` | 见「设计与来源」 | 仅在有评审的依赖升级时覆盖 |

state 目录可复用以省去重复下载，脚本每次都会把 pmbootstrap 和 pmaports 强制
重置回固定版本再重新应用 overlay，所以复用不会造成状态漂移。删除该目录即可完全
重来。

首次完整构建的主要耗时在内核编译（CI 上约 35–55 分钟）。

### 失败时怎么看日志

pmbootstrap 只把摘要打到终端，真正的错误写在 `$PMB_WORK/log.txt`。脚本失败时会
自动打印崩溃行和最后 500 行。

#### 2026-07-26 完整构建失败复盘

GitHub Actions run
[`30212747772`](https://github.com/baiyunquan/MSM8916-postmarketOS/actions/runs/30212747772)
在提交 `e36c8e5` 上完成了内核和 19 款 DTB 编译、split rootfs/boot 镜像生成以及
bootloader 构建，最终失败在 **Configure and verify the multi-board boot image**。
因此这一次并不是 QEMU/mkinitfs 崩溃、内核编译错误、已删除的 nonfree 子包或
bootloader 构建错误。

失败脚本把所有 `debugfs` 输出重定向到了 `/dev/null`，多个裸断言也没有错误说明，
Actions 日志最终只留下 `exit code 1`；旧 run 究竟触发了哪一个断言已无法从留存日志
恢复。后续诊断 run `30320893039` 证明实际 boot 镜像中存在 extlinux、内核和目标
DTB，也让 helper 自身的路径/变量错误可以被准确定位，不再把镜像内容缺失当作未经
证实的结论。

本仓库现在像固定的 `pmos-example/configs/extlinux.conf` 一样显式管理三个关键指令：
`linux /vmlinuz`、默认 UFI001C `fdt` 和指向 `pmOS_root` 文件系统标签的 `append`。
无论滚动包生成零个、一个还是多个启动项，都会替换成这个单一入口，并在写回后重新
导出验证；任何失败都会输出具体命令、文件路径以及 boot 镜像的相关目录清单。

这个问题也是“固定源码、滚动二进制”边界的另一种表现：该 run 使用固定 pmaports
里的 `device-zhihe-generic 7-r0` 元数据，但 edge 镜像实际安装了 `8-r0`。版本漂移
本身可以接受，不能再把滚动包生成某个 boot 文件的行为当成不变契约。仓库只依赖
固定的内核源码构建结果，并对最终 boot 镜像需要的 extlinux 和 19 款 DTB 结构负责。

这些检查只能证明 ext2 文件系统、extlinux 路径、root 参数、DTB 数量及 compatible
映射在构件中正确，不能证明任何板型已经真机启动或外设可用。

**不要用 `pmbootstrap log`**：它的实现是 `tail -F`，永远不会返回。CI 上曾因此白白
挂死两个完整的 6 小时任务。

内核源码 tarball 由 chroot 内的 busybox wget 从 github.com 拉取且不会重试，脚本已
对这一步加了 3 次重试——`codeload.github.com` 的偶发 DNS 失败曾直接打断一次构建。

## 设备树验证

Ubuntu/WSL 中可对固定内核源码执行全部 DTB 编译检查：

```sh
git clone --depth=1 --branch v6.12.1-msm8916 \
  https://github.com/msm8916-mainline/linux.git /tmp/linux-msm8916
bash scripts/validate-dtbs.sh /tmp/linux-msm8916 /tmp/validated-dtbs
```

完整镜像构建请用 `scripts/build-local.sh` 或仓库 workflow；两者都会额外验证 ext2
boot 镜像内部的 DTB 数量、`compatible`、extlinux 路径以及发布包校验和。

## 许可证

根仓库的原创脚本和文档采用 MIT 许可证。submodule 保留各自许可证；设备树源码及
相关兼容补丁遵循文件中的 `GPL-2.0-only` 声明。两个预编译 DTB 原样来自固定的
`debian-dtbs` 提交，其可审查性和跨内核兼容性低于源码构建的 DTB。
