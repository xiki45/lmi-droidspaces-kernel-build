#!/bin/bash
# ============================================================
# Droidspaces build helper for lmi (Voyager Kernel 4.19 / sm8250)
# 用法: bash scripts/apply_droidspaces.sh <kernel_dir> [clang_dir]
# ============================================================
set -euo pipefail

KDIR="${1:?usage: apply_droidspaces.sh <kernel_dir> [clang_dir]}"
CLANG_DIR="${2:-$HOME/gclang/clang14}"

cd "$KDIR"

echo "==== [1/5] 修复仓库 BUG: 换回 MGLRU 一致的 mm/swap.c ===="
# 上游 commit 76f5081fb1 revert 了 mm/swap.c 的 MGLRU 适配，导致与 mm_inline.h 接口不一致
# 父提交 0960053c20 的 mm/swap.c 才是正确的
curl -fsSL "https://raw.githubusercontent.com/CrackerCat/Kernel_Xiaomi_sm8250_S/0960053c206a18c2ee7b6784b8fdad4ac0134e7a/mm/swap.c" -o mm/swap.c
if grep -q page_off_lru mm/swap.c; then
  echo "ERROR: mm/swap.c 仍包含 page_off_lru（替换失败）"; exit 1
fi
echo "OK: page_off_lru 计数 = $(grep -c page_off_lru mm/swap.c || true)"

echo "==== [2/5] 应用 Droidspaces 官方 non-GKI 补丁 ===="
curl -fsSL "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/01.fix_kernel_panic_in_xt_qtaguid.patch" -o /tmp/ds1.patch
curl -fsSL "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" -o /tmp/ds2.patch
patch -p1 --forward -r - < /tmp/ds1.patch || echo "warn: patch 01 未干净应用"
patch -p1 --forward -r - < /tmp/ds2.patch || echo "warn: patch 02 未干净应用"

echo "==== [3/5] 写入 Droidspaces 内核配置 ===="
python3 - <<'PY'
ENABLE = [
 "CONFIG_SYSVIPC", "CONFIG_POSIX_MQUEUE", "CONFIG_PID_NS", "CONFIG_IPC_NS",
 "CONFIG_NAMESPACES", "CONFIG_UTS_NS", "CONFIG_SECCOMP", "CONFIG_SECCOMP_FILTER",
 "CONFIG_DEVTMPFS", "CONFIG_USER_NS", "CONFIG_MACVLAN", "CONFIG_OVERLAY_FS",
 "CONFIG_TMPFS_POSIX_ACL", "CONFIG_TMPFS_XATTR",
 "CONFIG_CGROUP_DEVICE", "CONFIG_CGROUP_PIDS", "CONFIG_CFS_BANDWIDTH", "CONFIG_CGROUP_NET_PRIO",
 "CONFIG_BRIDGE_NETFILTER", "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE", "CONFIG_NF_TABLES",
]
DISABLE = ["CONFIG_ANDROID_PARANOID_NETWORK"]
TARGETS = [
 "arch/arm64/configs/vendor/output/lmi_defconfig",
 "arch/arm64/configs/lmi-stock_defconfig",
]
for path in TARGETS:
    lines = open(path).read().split("\n")

    def setopt(name, want):
        val = ("%s=y" % name) if want else ("# %s is not set" % name)
        for i, ln in enumerate(lines):
            if ln.strip() in (("%s=y" % name), ("# %s is not set" % name)):
                lines[i] = val
                return
        lines.append(val)

    for c in ENABLE:
        setopt(c, True)
    for c in DISABLE:
        setopt(c, False)
    open(path, "w").write("\n".join(lines))
    print("patched:", path)
PY

echo "==== [4/5] 注入 overwrite_config 钩子（双保险）===="
python3 - <<'PY'
p = "build_config/build.args.MIUI"
s = open(p).read()
anchor = "\t\t-e\tMIGT_ENERGY_MODEL\t\\\n"
opts = ["SYSVIPC", "POSIX_MQUEUE", "PID_NS", "IPC_NS", "USER_NS", "DEVTMPFS", "MACVLAN", "CGROUP_PIDS", "CFS_BANDWIDTH"]
add = "".join("\t\t-e\t%s\t\t\t\\\n" % o for o in opts)
add += "\t\t-d\tANDROID_PARANOID_NETWORK\t\\\n"
if "SYSVIPC" in s:
    print("hook 已存在，跳过")
elif anchor in s:
    open(p, "w").write(s.replace(anchor, anchor + add))
    print("hook 已注入")
else:
    print("WARN: 未找到锚点，跳过 hook 注入")
PY

echo "==== [5/5] 设置 CLANG_PATH ===="
sed -i "s|^CLANG_PATH=.*|CLANG_PATH=${CLANG_DIR}|" build_config/build.args.MIUI

echo "==== 校验 ===="
grep -E "^CONFIG_(PID_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE)=y" arch/arm64/configs/vendor/output/lmi_defconfig || true
grep '^CLANG_PATH' build_config/build.args.MIUI
echo "==== 全部完成 ===="
