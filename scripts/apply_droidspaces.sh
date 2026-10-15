#!/bin/bash
# ============================================================
# Droidspaces build helper for lmi (Voyager Kernel 4.19 / sm8250)
# 用法: bash scripts/apply_droidspaces.sh <kernel_dir> [clang_dir]
# ============================================================
set -euo pipefail

KDIR="${1:?usage: apply_droidspaces.sh <kernel_dir> [clang_dir]}"
CLANG_DIR="${2:-$HOME/gclang/clang14}"

cd "$KDIR"

GOOD_COMMIT="0960053c206a18c2ee7b6784b8fdad4ac0134e7a"

echo "==== [1/7] 检出可编译的基线 commit ===="
echo "原因: staging HEAD 有三个致命问题"
echo "  ① commit 76f5081fb1 revert 了 mm/swap.c 的 MGLRU 适配 → 与 mm_inline.h 接口不一致"
echo "  ② commit bb85db53a5/89ed53f357/78341e1a74 引入未保护的 ksu_handle_* 调用 → 未启用 KSU 时链接失败"
echo "  ③ anykernel.sh 按 ro.build.flavor 选包，本机 flavor(missi_phone_cn_only64) 不匹配 → 刷入中止"
echo "  => ①② 用 $GOOD_COMMIT 解决；③ 在下面第 3 步处理"
if ! git fetch --depth=1 origin "$GOOD_COMMIT" 2>/dev/null; then
  echo "  (直接 fetch sha 失败，改用 unshallow)"
  git fetch --unshallow origin staging
fi
git checkout "$GOOD_COMMIT" 2>/dev/null || git checkout FETCH_HEAD
echo "  当前 HEAD: $(git rev-parse --short HEAD)"

echo "==== [2/7] 校验基线一致性 ===="
if [ "$(grep -c page_off_lru mm/swap.c || true)" != "0" ]; then
  echo "ERROR: mm/swap.c 仍是坏的版本"; exit 1
fi
echo "  OK: mm/swap.c 一致 (page_off_lru = 0)"
for f in fs/open.c fs/read_write.c fs/stat.c fs/exec.c; do
  if [ "$(grep -c ksu_handle "$f" || true)" != "0" ]; then
    echo "ERROR: $f 仍含 ksu_handle 调用"; exit 1
  fi
done
echo "  OK: fs/* 无 ksu_handle 残留"

echo "==== [3/7] 预置 AnyKernel3 并修正 flavor 匹配 ===="
# build-kernel.sh 仅在 anykernel/ 不存在时才 clone，所以这里预置即可覆盖其内容
if [ ! -d anykernel ]; then
  git clone --depth=1 -b kona https://github.com/TheVoyager0777/AnyKernel3.git anykernel
fi
python3 - <<'PY'
p = "anykernel/anykernel.sh"
s = open(p).read()
start = s.find('case "$userflavor" in')
end = s.find('esac;', start)
if start != -1 and end != -1:
    s = s[:start] + 'case "$userflavor" in\n    *) os="miui"; os_string="MIUI ROM";;\n' + s[end:]
    open(p, "w").write(s)
    print("  anykernel.sh: flavor 匹配 -> 强制 miui（本 zip 只含 miui 内核）")
else:
    print("  WARN: 未找到 case 块，跳过")
PY

echo "==== [4/7] 应用 Droidspaces 官方 non-GKI 补丁 ===="
curl -fsSL "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/01.fix_kernel_panic_in_xt_qtaguid.patch" -o /tmp/ds1.patch
curl -fsSL "https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/non-GKI/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" -o /tmp/ds2.patch
patch -p1 --forward -r - < /tmp/ds1.patch || echo "  warn: patch 01 未干净应用"
patch -p1 --forward -r - < /tmp/ds2.patch || echo "  warn: patch 02 未干净应用"

echo "==== [5/7] 写入 Droidspaces 内核配置 ===="
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
    print("  patched:", path)
PY

echo "==== [6/7] 注入 overwrite_config 钩子（双保险）===="
python3 - <<'PY'
p = "build_config/build.args.MIUI"
s = open(p).read()
anchor = "\t\t-e\tMIGT_ENERGY_MODEL\t\\\n"
opts = ["SYSVIPC", "POSIX_MQUEUE", "PID_NS", "IPC_NS", "USER_NS", "DEVTMPFS", "MACVLAN", "CGROUP_PIDS", "CFS_BANDWIDTH"]
add = "".join("\t\t-e\t%s\t\t\t\\\n" % o for o in opts)
add += "\t\t-d\tANDROID_PARANOID_NETWORK\t\\\n"
if "SYSVIPC" in s:
    print("  hook 已存在，跳过")
elif anchor in s:
    open(p, "w").write(s.replace(anchor, anchor + add))
    print("  hook 已注入")
else:
    print("  WARN: 未找到锚点，跳过 hook 注入")
PY

echo "==== [7/7] 设置 CLANG_PATH ===="
sed -i "s|^CLANG_PATH=.*|CLANG_PATH=${CLANG_DIR}|" build_config/build.args.MIUI

echo "==== 最终校验 ===="
grep -E "^CONFIG_(PID_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE)=y" arch/arm64/configs/vendor/output/lmi_defconfig || true
grep '^CLANG_PATH' build_config/build.args.MIUI
sed -n '33,37p' anykernel/anykernel.sh
echo "==== 全部完成 ===="
