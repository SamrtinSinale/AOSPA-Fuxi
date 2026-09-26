#!/bin/bash
export ARCH=arm64
export SUBARCH=arm64
export TARGET_PRODUCT=fuxi

# Auto-update Re:Kernel from myflavor/Re-Kernel
if [ -d Re-Kernel/.git ]; then
    echo "[+] Updating Re:Kernel..."
    cd Re-Kernel
    git stash --quiet 2>/dev/null
    git pull --ff-only 2>/dev/null && echo "[-] Updated to latest" || echo "[-] Pull failed, using current version"
    cd ..
fi

# ---- 适配较新 binder: rkx 直接查内核真符号 binder_alloc_copy_from_buffer ----
RKX_DIR="drivers/rekernel"
if [ -f "$RKX_DIR/rkx_binder_kp.c" ]; then
    echo "[+] Patching rkx_binder_kp.c: 去掉版本分支, 只保留 kallsyms 查真符号"
    perl -0777 -i -pe 's/#if LINUX_VERSION_CODE < KERNEL_VERSION\(6, 0, 0\)\n\s*k_binder_alloc_copy_from_buffer = rk_binder_alloc_copy_from_buffer;\n#else\n(\s*k_binder_alloc_copy_from_buffer = \(void \*\)k_kallsyms_lookup_name\("binder_alloc_copy_from_buffer"\);\n)#endif\n/$1/s' "$RKX_DIR/rkx_binder_kp.c"
fi
if [ -f "$RKX_DIR/rkx_binder_alloc.c" ]; then
    echo "[+] Overwriting rkx_binder_alloc.c: 直接转调内核真符号 binder_alloc_copy_from_buffer"
    cat > "$RKX_DIR/rkx_binder_alloc.c" <<'RKXEOF'
/*
 * rkx_binder_alloc.c — 已覆写以适配较新 binder.
 * legacy 缓冲区拷贝实现(依赖旧 binder 内部结构)已移除;
 * rkx_binder_copy_from_buffer 直接转调内核真符号 binder_alloc_copy_from_buffer.
 */

#include "rkx_binder_alloc.h"

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 0, 0)

#include <linux/kprobes.h>

int rkx_binder_copy_from_buffer(struct binder_alloc *alloc, void *dest,
	struct binder_buffer *buffer, binder_size_t buffer_offset, size_t bytes)
{
	static int (*real_copy_from_buffer)(struct binder_alloc *, void *,
		struct binder_buffer *, binder_size_t, size_t);

	if (!real_copy_from_buffer) {
		unsigned long (*lookup)(const char *);
		struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };

		if (register_kprobe(&kp) < 0)
			return -EINVAL;
		lookup = (void *)kp.addr;
		unregister_kprobe(&kp);
		if (!lookup)
			return -EINVAL;
		real_copy_from_buffer = (void *)lookup("binder_alloc_copy_from_buffer");
	}
	if (!real_copy_from_buffer)
		return -EINVAL;

	return real_copy_from_buffer(alloc, dest, buffer, buffer_offset, bytes);
}
#endif
RKXEOF
fi

MAKE_PARAMS="LLVM=1 LLVM_IAS=1 O=out LOCALVERSION=-AOSPA-BY@Samrtin"

mkdir -p out
make $MAKE_PARAMS fuxi_defconfig -j$(nproc --all)
make $MAKE_PARAMS Image -j$(nproc --all) 2>&1 | tee out/build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "[!] Build failed. Check out/build.log for details."
    exit 1
fi

# ----- KernelPatch (FolkPatch) 自动打补丁 -----
KP_DIR="KernelPatch"
KP_BASE_URL="https://github.com/LyraVoid/KernelPatch/releases/download"

mkdir -p ${KP_DIR}

# 自动获取最新 FolkPatch release 并提取 kpimg + kpimg.version
FP_VERSION_FILE="${KP_DIR}/fp_version.txt"
echo "[+] Checking latest FolkPatch release..."
FP_LATEST=$(curl -sL https://api.github.com/repos/LyraVoid/FolkPatch/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"([^"]*)"' | cut -d'"' -f4)

if [ -z "$FP_LATEST" ]; then
    echo "[-] GitHub API rate limited, using cached kpimg if available"
    if [ ! -f "${KP_DIR}/kpimg-fp" ]; then
        echo "[!] No cached kpimg and cannot fetch latest release!"
        exit 1
    fi
else
    # 每次构建都强制下载最新 release 的 APK, 保证 kpimg 始终是最新发布版.
    # 注意: FolkPatch 会在同一 tag 下更新 APK 资产(如 5.0 下 115002->115003),
    # 所以不能只靠 tag 判断更新, 直接每次拉取.
    echo "[+] Downloading latest FolkPatch release ${FP_LATEST} APK..."
    FP_DL_URL=$(curl -sL "https://api.github.com/repos/LyraVoid/FolkPatch/releases/tags/${FP_LATEST}" 2>/dev/null | grep -oP '"browser_download_url":\s*"[^"]*\.apk"' | cut -d'"' -f4 | head -1)
    if [ -z "$FP_DL_URL" ]; then
        echo "[!] Cannot find APK download URL for ${FP_LATEST}"
        exit 1
    fi
    echo "[+] Downloading ${FP_LATEST} APK to extract kpimg..."
    curl -L "${FP_DL_URL}" -o /tmp/fp.apk
    rm -rf "${KP_DIR}/assets"
    unzip -o /tmp/fp.apk 'assets/kpimg' 'assets/kpimg.version' -d "${KP_DIR}/" >/dev/null 2>&1
    mv "${KP_DIR}/assets/kpimg" "${KP_DIR}/kpimg-fp"
    if [ -f "${KP_DIR}/assets/kpimg.version" ]; then
        mv "${KP_DIR}/assets/kpimg.version" "${KP_DIR}/kpimg.version"
    fi
    rm -rf "${KP_DIR}/assets"
    rm -f /tmp/fp.apk
    echo "${FP_LATEST}" > "${FP_VERSION_FILE}"

    # 从 APK 文件名提取真实 versionCode (如 FolkPatch_115003_5.0_on_main-release.apk -> 115003),
    # 与 release 实际版本保持一致, 避免读 FolkPatch main 分支提前 bump 的版本号
    FP_CODE=$(basename "${FP_DL_URL}" | grep -oP '(?<=FolkPatch_)\d+')
    if [ -n "$FP_CODE" ]; then
        echo "${FP_CODE}" > "${KP_DIR}/fp_versioncode.txt"
        echo "[-] FolkPatch versionCode: ${FP_CODE}"
    fi
    echo "[-] kpimg extracted from FolkPatch ${FP_LATEST}"
fi

# kptools 版本跟随 FolkPatch 内置 kpimg 版本(保证配套), 缓存缺失时回退 LyraVoid 最新
KP_VERSION_FILE="${KP_DIR}/kptools_version.txt"
KP_LATEST=""
[ -f "${KP_DIR}/kpimg.version" ] && KP_LATEST=$(cat "${KP_DIR}/kpimg.version")
if [ -z "$KP_LATEST" ]; then
    KP_LATEST=$(curl -sL https://api.github.com/repos/LyraVoid/KernelPatch/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"([^"]*)"' | cut -d'"' -f4)
fi
if [ -z "$KP_LATEST" ]; then
    [ -f "${KP_VERSION_FILE}" ] && KP_LATEST=$(cat "${KP_VERSION_FILE}") || KP_LATEST="0.13.2"
    echo "[-] GitHub API rate limited, using kptools ${KP_LATEST}"
else
    KP_CACHED=""
    [ -f "${KP_VERSION_FILE}" ] && KP_CACHED=$(cat "${KP_VERSION_FILE}")
    if [ "${KP_LATEST}" != "${KP_CACHED}" ]; then
        echo "[+] New kptools version: ${KP_LATEST} (cached: ${KP_CACHED:-none})"
        rm -f "${KP_DIR}/kptools-linux"
        echo "${KP_LATEST}" > "${KP_VERSION_FILE}"
    fi
fi

# 下载 kptools-linux（主机工具，只在版本更新时下载）
if [ ! -f "${KP_DIR}/kptools-linux" ]; then
    echo "[+] Downloading kptools-linux ${KP_LATEST}..."
    curl -L "${KP_BASE_URL}/${KP_LATEST}/kptools-linux" -o "${KP_DIR}/kptools-linux"
    chmod +x "${KP_DIR}/kptools-linux"
fi

echo "[+] Applying FolkPatch (KernelPatch) to Image..."
./${KP_DIR}/kptools-linux \
    -p \
    -i out/arch/arm64/boot/Image \
    -k ${KP_DIR}/kpimg-fp \
    -o out/arch/arm64/boot/Image

if [ $? -ne 0 ]; then
    echo "[!] KernelPatch failed. Check if Image is valid."
    exit 1
fi
echo "[-] KernelPatch applied successfully!"

# Prepare AnyKernel3 flashable zip
rm -rf out/AK3
cp -r tools/AK3 out/
cp out/arch/arm64/boot/Image out/AK3/Image
cd out/AK3
ZIPNAME="Fuxi-FolkPatch-$(date -u '+%Y%m%d-%H%M').zip"
zip -r9 "$ZIPNAME" .
find . -not -name "*.zip" -not -name "." -exec rm -rf {} + 2>/dev/null
echo "[-] Zip created in: out/AK3/"
cp "$ZIPNAME" ~/
echo "[-] Also copied to: ~/$ZIPNAME"