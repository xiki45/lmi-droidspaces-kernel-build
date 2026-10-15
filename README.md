# lmi 内核编译指南（Voyager Kernel + Droidspaces）

> 目标设备：Redmi K30 Pro / POCO F2 Pro（**lmi**，SM8250）
> 目标：编出带 Droidspaces 支持（PID/IPC namespace）的内核，卡刷后用 `droidspaces check` 全绿

---

## 0. 背景（为什么要重编）

设备当前内核 `4.19.273-VK-X` 缺 `CONFIG_PID_NS` + `CONFIG_IPC_NS`，Droidspaces 起不来。
该内核源码 = **`CrackerCat/Kernel_Xiaomi_sm8250_S`**（Voyager Kernel，branch `staging`，4.19）。
lmi 是 **4.19 non-GKI**，按 Droidspaces 官方文档：**加配置 + 打 2 个 non-GKI 补丁**即可，无需 kABI 补丁。

### ⚠️ 源码自带的三个坑（必须处理）

| # | 坑 | 现象 | 解法 |
|---|----|------|------|
| 1 | **`build-kernel.sh` 大小写 bug** | 传 `MIUI` 打印完 "Found args configuration" 就静默退出 | 用小写：`bash build-kernel.sh lmi miui` |
| 2 | **`mm/swap.c` 被 revert 坏了** | `mm/swap.c:70: error: implicit declaration of page_off_lru` 等 16 个错 | 换回父提交的 `mm/swap.c` |
| 3 | **KernelSU 符号未定义** | `ld.lld: error: undefined symbol: ksu_handle_faccessat / ksu_handle_vfs_read / ksu_handle_stat / ksu_handle_execveat` | 源码含未加保护的 `ksu_handle_*` 调用但未启用 KSU 驱动 |

**三个坑一次解决**：检出 **`0960053c206a18c2ee7b6784b8fdad4ac0134e7a`** —— 它是：
- `76f5081fb1`（破坏 swap.c 的 revert）的**父提交** → swap.c 正确
- 早于所有 KernelSU 提交 → 无 `ksu_handle_*` 残留

> 构建脚本会自动执行这个 checkout。

---

## 方案 A：GitHub Actions 云编译（推荐）

无需本地环境，产物为可卡刷的 AnyKernel3 zip。

### 仓库结构
```
.
├── .github/workflows/build.yml     # 工作流（需手动创建，见下）
├── build-workflow.yml              # 工作流内容（根目录副本，方便复制）
├── scripts/apply_droidspaces.sh    # 一键 checkout 基线 + 改配置 + 打补丁
└── README.md
```

### 触发
仓库 → Actions → **Build lmi kernel (Voyager + Droidspaces)** → **Run workflow**

### 工作流做了什么
1. 装依赖（含 `python-is-python3`、`libxml2`）
2. 下载 clang 14：`ZyCromerZ/Clang` 的 `14.0.6-20261011`
3. 克隆 `CrackerCat/Kernel_Xiaomi_sm8250_S`（depth=1，staging）
4. 跑 `scripts/apply_droidspaces.sh`：
   - **checkout `0960053c20`**（一次性解决坑 2 + 坑 3）
   - 校验 `mm/swap.c` 与 `fs/*` 干净
   - 打 2 个官方 non-GKI 补丁
   - 写 `PID_NS/IPC_NS/SYSVIPC/POSIX_MQUEUE/USER_NS/DEVTMPFS/...` 到 defconfig
   - 注入 `overwrite_config()` 钩子（双保险）
   - 设置 `CLANG_PATH`
5. `bash build-kernel.sh lmi miui`（小写，绕坑 1）
6. 上传 zip 为 Artifact **并**发 Release

### 产物位置
- Actions run 页面 → Artifacts → `voyager-lmi-droidspaces`
- 或 Releases → `build-<n>` → `Voyager-LMI-*.zip`

耗时约 **30–60 分钟**。公开仓库的 Actions 免费额度不受限。

---

## 方案 B：本地 WSL2 编译

### 依赖
```bash
sudo apt update
sudo apt install -y build-essential git curl wget bison flex zip bc cpio \
  libssl-dev ccache python3 python-is-python3 rsync libxml2 libzstd1 zlib1g
```

### 工具链（clang 14）
```bash
mkdir -p ~/gclang && cd ~/gclang
wget https://github.com/ZyCromerZ/Clang/releases/download/14.0.6-20261011-release/Clang-14.0.6-20261011.tar.gz
mkdir -p clang14 && tar xzf Clang-14.0.6-20261011.tar.gz -C clang14
# CLANG_PATH = $HOME/gclang/clang14
```

### 应用改动（与 Actions 等价）
```bash
git clone --depth=1 -b staging https://github.com/CrackerCat/Kernel_Xiaomi_sm8250_S kernel
bash scripts/apply_droidspaces.sh "$PWD/kernel" "$HOME/gclang/clang14"
```

### 编译
```bash
cd kernel
bash build-kernel.sh lmi miui      # ← 必须小写 miui
```
产物：`anykernel/out/Voyager-LMI-*.zip`

---

## 刷入设备

**两种方式都行**（boot 分区运行时不被占用，所以开机状态也能写）：

### 方式 1：recovery 卡刷（有 TWRP 时）
TWRP → Install → 选 `Voyager-LMI-*.zip` → 滑动确认

### 方式 2：开机状态刷（无需 TWRP）
- 用内核刷入器 App：Franco Kernel Manager / EX Kernel Manager / Horizon Kernel Flasher
- 或 root shell 手动跑 AnyKernel3：
```bash
su
cd /data/local/tmp && rm -rf ak3 && mkdir ak3 && cd ak3
unzip -o /sdcard/Voyager-LMI-*.zip
sh META-INF/com/google/android/update-binary 3 1 /sdcard/Voyager-LMI-*.zip
```

**写入分区**（AnyKernel3 自动处理，无需手动选）：
| 分区 | 路径 |
|---|---|
| **boot** | `/dev/block/bootdevice/by-name/boot` |
| **dtbo** | `/dev/block/bootdevice/by-name/dtbo` |

### ⚠️ 刷前必须备份
```bash
su -c "dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot_backup.img"
su -c "dd if=/dev/block/bootdevice/by-name/dtbo of=/sdcard/dtbo_backup.img"
```
刷坏 bootloop 时用 fastboot 救：
```
fastboot flash boot boot_backup.img
fastboot flash dtbo dtbo_backup.img
```

## 验证
```bash
su -c "/data/local/Droidspaces/bin/droidspaces check"
# 目标：PID namespace / IPC namespace 由 ✗ 变 ✓
```

---

## 配置速查（本次新增）

```
CONFIG_SYSVIPC=y            CONFIG_POSIX_MQUEUE=y
CONFIG_PID_NS=y  ★          CONFIG_IPC_NS=y  ★
CONFIG_NAMESPACES=y         CONFIG_UTS_NS=y
CONFIG_SECCOMP=y            CONFIG_SECCOMP_FILTER=y
CONFIG_DEVTMPFS=y           CONFIG_USER_NS=y
CONFIG_MACVLAN=y            CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_POSIX_ACL=y    CONFIG_TMPFS_XATTR=y
CONFIG_CGROUP_DEVICE=y      CONFIG_CGROUP_PIDS=y
CONFIG_CFS_BANDWIDTH=y      CONFIG_CGROUP_NET_PRIO=y
CONFIG_BRIDGE_NETFILTER=y   CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NF_TABLES=y
# CONFIG_ANDROID_PARANOID_NETWORK is not set
```

---

## 排错速查

| 报错 | 原因 | 解法 |
|------|------|------|
| `Found args configuration...` 后无输出 | 坑 1：大小写 | 用 `lmi miui` |
| `error: index file .git/objects/pack/._pack-*.idx is too small` | macOS `._*` 垃圾文件 | `find . -name '._*' -type f -delete` |
| `ld.lld: libxml2.so.2: cannot open shared object` | 缺库 | `sudo apt install -y libxml2` |
| `/bin/sh: 1: python: not found` | 无 `python` | `sudo apt install -y python-is-python3` |
| `mm/swap.c: implicit declaration of page_off_lru` | 坑 2 | checkout `0960053c20` |
| `undefined symbol: ksu_handle_*` | 坑 3 | checkout `0960053c20` |
| `There is no kernel for your OS in this zip!` | AK3 按 `ro.build.flavor` 选包失败 | 加 flavor 规则 |

---

## 关键链接

- 内核源码：https://github.com/CrackerCat/Kernel_Xiaomi_sm8250_S （branch `staging`）
- 可编译基线 commit：`0960053c206a18c2ee7b6784b8fdad4ac0134e7a`
- Droidspaces 内核配置指南：https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md
- clang 14.0.6：https://github.com/ZyCromerZ/Clang/releases/tag/14.0.6-20261011-release
- lmi recovery（SKKK TWRP）：https://sourceforge.net/projects/recovery-for-xiaomi-devices/files/lmi/
